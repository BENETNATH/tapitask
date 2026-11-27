import "dart:async";
import "dart:convert";

import "package:drift/drift.dart";
import "package:flutter/foundation.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:web_socket_channel/web_socket_channel.dart";

import "api_client.dart";
import "database.dart";

/// Delta sync + outbox. Local SQLite is the source of truth for the UI;
/// the server is reconciled in the background (last-write-wins by updated_at).
///
/// Robustesse :
/// - pousse les listes créées offline (`list.create`) et les items dirty
/// - EVENTS PAR CHUNKS (max 500) : une grosse session offline ne bloque
///   jamais sur la limite serveur de 1000 events
/// - PURGE DES REJETS : le serveur rapporte les events qu'il ne peut pas
///   appliquer (liste supprimée, accès perdu) ; on les retire de l'outbox
///   au lieu de les réessayer à l'infini (outbox empoisonné)
/// - DEBOUNCE : syncSoon() coalesce les syncs demandés par les actions
///   utilisateur (cocher N items = 1 seul POST au lieu de N)
/// - reconnexion WebSocket automatique (backoff exponentiel, max 5 min)
/// - le retry d'outbox tourne TOUJOURS (60 s), même avec le poll désactivé
class SyncService {
  final ApiClient api;
  final AppDb db;
  final void Function()? onChanged;
  final Future<void> Function()? onSynced;
  bool _running = false;
  int pollSeconds = 30;
  WebSocketChannel? _ws;
  StreamSubscription? _wsSub;
  Timer? _outboxTimer;
  Timer? _pollTimer;
  Timer? _reconnectTimer;
  Timer? _debounceTimer;
  int _wsFailures = 0;
  bool _disposed = false;

  static const _chunkSize = 500;

  SyncService({required this.api, required this.db, this.onChanged, this.onSynced});

  bool get connected => _ws != null;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    pollSeconds = prefs.getInt("sync_interval_seconds") ?? 30;
    await fullSync();
    await listenRealtime();
    _startTimers();
  }

  void _startTimers() {
    // Two INDEPENDENT timers: the outbox retry (always active, even when
    // polling is disabled — otherwise offline edits would never leave the
    // device) and the poll. Each has its own handle so dispose() cancels
    // both; no orphan timer survives disposal.
    _outboxTimer?.cancel();
    _outboxTimer = Timer.periodic(
        const Duration(seconds: 60), (_) => _retryOutboxIfDirty());
    _pollTimer?.cancel();
    if (pollSeconds > 0) {
      _pollTimer = Timer.periodic(
          Duration(seconds: pollSeconds), (_) => _retryOutboxIfDirty());
    }
  }

  /// Apply a polling delay (server-synced user setting). Also kept in local
  /// prefs as an offline fallback before the first profile load.
  Future<void> applyPollInterval(int seconds) async {
    pollSeconds = seconds;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt("sync_interval_seconds", seconds);
    _startTimers();
  }

  /// Debounced sync for user actions: multiple actions within 1.5 s
  /// (checking several items, a drag-reorder…) produce ONE network sync.
  void syncSoon() {
    if (_disposed) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 1500), () {
      if (!_disposed) fullSync();
    });
  }

  /// Retry loop: if anything is still dirty, push it again.
  Future<void> _retryOutboxIfDirty() async {
    if (_disposed) return;
    try {
      final dirtyItems = await db.dirtyItems();
      final dirtyLists = await db.dirtyLists();
      if (dirtyItems.isNotEmpty || dirtyLists.isNotEmpty) {
        await fullSync();
      }
    } catch (e) {
      debugPrint("tapitask: sync retry-outbox check failed: $e");
    }
  }

  Future<void> fullSync() async {
    if (_disposed) return;
    if (!api.isConfigured || api.accessToken == null) return;
    if (_running) return;
    _running = true;
    try {
      await _pushOutbox();
      await _pull(since: await _lastSync());
    } catch (_) {
      // offline: the retry timer will try again
    } finally {
      _running = false;
    }
    await onSynced?.call();
  }

  Future<String?> _lastSync() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString("last_sync");
  }

  Future<void> _saveLastSync(DateTime value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("last_sync", value.toUtc().toIso8601String());
  }

  /// POST /sync with chunked events; returns the accumulated rejected ids.
  Future<List<String>> _postEvents(List<Map<String, dynamic>> events) async {
    final rejected = <String>[];
    // C2.9 : `since` dans le push — sans, le serveur calcule et renvoie
    // toute la base, immédiatement jetée avant le _pull.
    final since = await _lastSync();
    for (var i = 0; i < events.length; i += _chunkSize) {
      final chunk = events.sublist(
          i, (i + _chunkSize) > events.length ? events.length : i + _chunkSize);
      final body = <String, dynamic>{"events": chunk};
      if (since != null) body["since"] = since;
      final result = await api.post("/sync", body);
      final rej = result["rejected"];
      if (rej is List) {
        rejected.addAll(rej.map((e) => e.toString()));
      }
    }
    return rejected;
  }

  Future<void> _pushOutbox() async {
    // 1. Lists created / renamed / deleted offline (never local-only ones)
    final localOnly = await db.localOnlyListIds();
    final listEvents = <Map<String, dynamic>>[];
    final dirtyLists = await db.dirtyLists();
    for (final list in dirtyLists) {
      if (localOnly.contains(list.id)) {
        await db.clearListDirty(list.id);
        continue;
      }
      listEvents.add({
        "kind": list.deleted ? "list.delete" : "list.create",
        "id": list.id,
        "list_id": list.id,
        "label": list.title,
        "color": list.color,
        "folder": list.folder,
        "updated_at": list.updatedAt.toUtc().toIso8601String(),
      });
    }
    if (listEvents.isNotEmpty) {
      await _postEvents(listEvents);
      // Les listes poussées quittent l'outbox : le serveur les a soit
      // appliquées soit rapportées dans `rejected` (supprimée côté serveur,
      // accès perdu) — dans les deux cas réessayer bloquerait l'outbox à
      // jamais. Une liste rejetée reste locale, simplement locale.
      // 2.2 (prod3) : ne nettoyer que si la liste n'a pas été modifiée
      // PENDANT le POST (updatedAt courant <= updatedAt capturé) — sinon
      // le renommage cocherait propre sans jamais être poussé.
      for (final list in dirtyLists) {
        final now = await (db.select(db.localLists)
                ..where((l) => l.id.equals(list.id)))
            .getSingleOrNull();
        if (now == null || !now.updatedAt.isAfter(list.updatedAt)) {
          await db.clearListDirty(list.id);
        }
      }
    }
    // 2. Dirty items (never those of local-only lists)
    final dirty = (await db.dirtyItems())
        .where((i) => !localOnly.contains(i.listId))
        .toList();
    if (dirty.isNotEmpty) {
      final events = dirty
          .map((i) => {
                "kind": i.deleted ? "item.delete" : "item.upsert",
                "id": i.id,
                "list_id": i.listId,
                "label": i.label,
                "done": i.done,
                "completed_at": i.completedAt?.toUtc().toIso8601String(),
                "position": i.position,
                "parent_id": i.parentId,
                "recurrence": i.recurrence,
                "due_date": i.dueDate?.toUtc().toIso8601String(),
                "due_day": i.dueDay,
                "notes": i.notes,
                "assignee_id": i.assigneeId,
                "updated_at": i.updatedAt.toUtc().toIso8601String(),
                "deleted": i.deleted,
              })
          .toList();
      final rejected = await _postEvents(events);
      // Rejected items leave the outbox (the server will never accept them).
      final rejectedIds =
          dirty.where((i) => rejected.contains(i.id)).map((i) => i.id).toList();
      if (rejectedIds.isNotEmpty) {
        await db.clearDirty(rejectedIds);
      }
      // 2.2 (prod3) : une mutation locale PENDANT le POST /sync fait monter
      // updatedAt → l'item ne doit PAS être marqué propre (le push n'a pas
      // vu cette version). On ne nettoie que si updatedAt courant <=
      // updatedAt capturé au départ (query par id).
      final stillPushed = <String>[];
      for (final item in dirty.where((i) => !rejected.contains(i.id))) {
        final now = await (db.select(db.localItems)
                ..where((i) => i.id.equals(item.id)))
            .getSingleOrNull();
        if (now == null || !now.updatedAt.isAfter(item.updatedAt)) {
          stillPushed.add(item.id);
        }
      }
      if (stillPushed.isNotEmpty) {
        await db.clearDirty(stillPushed);
      }
    }
  }

  Future<void> _pull({String? since}) async {
    final body = <String, dynamic>{};
    if (since != null) body["since"] = since;
    final result = await api.post("/sync", body);
    final changes = result["changes"] as List<dynamic>;
    final localOnly = await db.localOnlyListIds();
    DateTime? newest;
    for (final change in changes) {
      final c = change as Map<String, dynamic>;
      final changedAt = DateTime.tryParse(c["updated_at"] ?? "");
      if (changedAt != null &&
          (newest == null || changedAt.isAfter(newest))) {
        newest = changedAt;
      }
      if (localOnly.contains(c["list_id"] ?? c["id"])) continue;
      if (c["kind"] == "list.sync" || c["kind"] == "list.rename") {
        final existing = await (db.select(db.localLists)
              ..where((l) => l.id.equals(c["id"])))
            .getSingleOrNull();
        if (existing != null && existing.localOnly) continue;
      }
      if (c["kind"] == "list.delete") {
        await db.applyRemoteListDeletion(
            c["id"], DateTime.parse(c["updated_at"]));
      } else if (c["kind"] == "list.sync" || c["kind"] == "list.rename") {
        await db.upsertList(LocalListsCompanion(
          id: Value(c["id"]),
          title: Value(c["label"] ?? ""),
          ownerId: const Value(""),
          updatedAt: Value(DateTime.parse(c["updated_at"])),
          deleted: const Value(false),
          color: Value(c["color"] as String?),
          folder: Value(c["folder"] as String?),
        ));
      } else {
        await db.applyRemoteItem(LocalItemsCompanion(
          id: Value(c["id"]),
          listId: Value(c["list_id"]),
          parentId: Value(c["parent_id"]),
          label: Value(c["label"] ?? ""),
          done: Value(c["done"] ?? false),
          completedAt: c["done"] != true
              ? const Value(null)
              : c.containsKey("completed_at")
                  ? Value(DateTime.tryParse(c["completed_at"] as String? ?? ""))
                  : const Value.absent(),
          position: Value(c["position"] ?? 0),
          recurrence: Value(c["recurrence"] ?? "none"),
          dueDate: Value(
              c["due_date"] != null ? DateTime.parse(c["due_date"]) : null),
          dueDay: c.containsKey("due_day") ? Value(c["due_day"] as String?) : const Value.absent(),
          notes: Value(c["notes"] as String?),
          assigneeId: Value(c["assignee_id"] as String?),
          updatedAt: Value(DateTime.parse(c["updated_at"])),
          deleted: Value(c["deleted"] ?? false),
          dirty: const Value(false),
        ));
      }
    }
    // 1.5 (prod3) : ancrer le curseur delta sur l'horloge SERVEUR, pas sur
    // `newest`. Avec la tolérance d'horloge serveur (+5 s), un item poussé
    // à server_now+4 s ferait sauter définitivement les items créés entre
    // server_now et server_now+4 s. Le pull est idempotent (LWW) → reculer
    // de 5 s est sans risque. `newest` ne sert que si `server_time` est
    // absent de la réponse (fallback).
    final serverTime = DateTime.tryParse(result["server_time"] ?? "");
    if (serverTime != null) {
      await _saveLastSync(serverTime.subtract(const Duration(seconds: 5)));
    } else if (newest != null) {
      await _saveLastSync(newest);
    }
    onChanged?.call();
  }

  /// 1.4 (prod3) : fermer le WebSocket sans reconnexion (session expirée) —
  /// le canal est ré-ouvert au prochain listenRealtime() (post-login).
  Future<void> stopRealtime() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _wsSub?.cancel();
    _wsSub = null;
    _ws?.sink.close();
    _ws = null;
  }

  Future<void> listenRealtime() async {
    if (_disposed || !api.isConfigured || api.accessToken == null) return;
    // 1.4 (prod3) : fermer l'ancien canal AVANT d'en ouvrir un nouveau —
    // sinon _ws/_wsSub sont écrasés (socket orpheline) et les reconnects
    // s'empilent (doublons de _reconnectTimer).
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _wsSub?.cancel();
    _wsSub = null;
    _ws?.sink.close();
    _ws = null;
    try {
      final wsUrl = api.baseUrl.replaceFirst("http", "ws");
      _ws = WebSocketChannel.connect(Uri.parse("$wsUrl/ws"));
      // Échec de connexion : [ready] complète en erreur — sans listener,
      // c'est une erreur non gérée (le stream s'occupe déjà du cas
      // connecté-puis-coupé via onError). Succès : SEUL point où le
      // compteur d'échecs doit repartir à zéro (sinon le backoff
      // exponentiel ne progresse jamais, cf. audit 2026-11-27).
      _ws!.ready.then((_) {
        _wsFailures = 0;
      }).catchError((_) {
        _scheduleReconnect();
      });
      // Auth by FIRST MESSAGE (the token never travels in the query string,
      // where reverse-proxy access logs would capture it).
      _ws!.sink.add(jsonEncode({"token": api.accessToken}));
      _wsSub = _ws!.stream.listen(
        (message) async {
          Map<String, dynamic> data;
          try {
            // 1.4 (prod3) : un message corrompu ne doit pas tuer le
            // listener (le WS resterait sourd).
            data = jsonDecode(message as String) as Map<String, dynamic>;
          } catch (_) {
            return;
          }
          if (data["kind"] == "ping") return;
          // Debounced: a burst of pushes (or our own echo) triggers
          // ONE pull instead of one per message.
          syncSoon();
        },
        onDone: _scheduleReconnect,
        onError: (_) => _scheduleReconnect(),
      );
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_disposed || _reconnectTimer?.isActive == true) return;
    _ws = null;
    _wsFailures++;
    // exponential backoff, capped at 5 minutes
    final delay = Duration(
        seconds: (2 << (_wsFailures > 7 ? 7 : _wsFailures) > 300)
            ? 300
            : 2 << (_wsFailures > 7 ? 7 : _wsFailures));
    _reconnectTimer = Timer(delay, listenRealtime);
  }

  void dispose() {
    _disposed = true;
    _outboxTimer?.cancel();
    _pollTimer?.cancel();
    _reconnectTimer?.cancel();
    _debounceTimer?.cancel();
    _wsSub?.cancel();
    _ws?.sink.close();
    _ws = null;
  }
}

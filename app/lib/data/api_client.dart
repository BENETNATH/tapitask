import "dart:convert";

import "package:flutter/foundation.dart";
import "package:flutter_secure_storage/flutter_secure_storage.dart";
import "package:http/http.dart" as http;
import "package:shared_preferences/shared_preferences.dart";

class ApiException implements Exception {
  final int status;
  final String message;
  ApiException(this.status, this.message);
  @override
  String toString() => "ApiException($status): $message";
}

/// C1.7 : register 202 « email à vérifier » — pas un faux succès : pas de
/// token, l'utilisateur doit vérifier son email avant de se connecter.
class EmailVerificationRequired implements Exception {
  const EmailVerificationRequired();
  @override
  String toString() => "Email verification required";
}

class ApiClient {
  String baseUrl;
  String? accessToken;
  String? refreshTokenValue;
  /// C2.1 (A3) : secure storage indisponible (web http:// hors secure
  /// context, restauration Android sans Keystore) → tokens en mémoire seule.
  bool secureStorageUnavailable = false;
  /// C2.7 : notifié quand la session est définitivement expirée (refresh
  /// 401) : l'app bascule en état déconnecté.
  VoidCallback? onSessionExpired;

  /// C1.6 : timeout global — un serveur muet ne doit jamais bloquer l'app.
  final Duration timeout;
  final http.Client _http;

  ApiClient(this.baseUrl,
      {http.Client? client, this.timeout = const Duration(seconds: 15)})
      : _http = client ?? http.Client();

  // Injecté dans les tests (le const original ne peut pas être mocké).
  static FlutterSecureStorage secureStorage = const FlutterSecureStorage();

  static Future<String?> _loadToken(SharedPreferences prefs,
      {required String key}) async {
    final plain = prefs.getString(key);
    if (plain != null) {
      // M5 (prod4) : une valeur claire VIDE n'est pas migrée (sinon ""
      // serait écrit en secure storage et `accessToken != null` avec un
      // token vide) — elle est juste supprimée.
      if (plain.isEmpty) {
        await prefs.remove(key);
        return null;
      }
      // Migration : valeur claire trouvée → secure storage, puis suppression.
      await secureStorage.write(key: key, value: plain);
      await prefs.remove(key);
      return plain;
    }
    final value = await secureStorage.read(key: key);
    // C1.7 : "" persisté avant le fix ≡ absent.
    return (value == null || value.isEmpty) ? null : value;
  }

  static Future<ApiClient> load() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString("server_url") ?? "";
    final client = ApiClient(url);
    try {
      client.accessToken = await _loadToken(prefs, key: "access_token");
      client.refreshTokenValue = await _loadToken(prefs, key: "refresh_token");
    } catch (e) {
      // C2.1 (A3) : les tokens restent en mémoire (null ici) ; l'app
      // démarre normalement — le stockage est réessayé à la prochaine persist.
      client.secureStorageUnavailable = true;
      debugPrint("tapitask: secure storage unavailable, tokens in-memory: $e");
    }
    return client;
  }

  Future<void> persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("server_url", baseUrl);
    try {
      // C1.7 : null → retrait de la clé (et non écriture de "").
      if (accessToken == null) {
        await secureStorage.delete(key: "access_token");
      } else {
        await secureStorage.write(key: "access_token", value: accessToken!);
      }
      if (refreshTokenValue == null) {
        await secureStorage.delete(key: "refresh_token");
      } else {
        await secureStorage.write(key: "refresh_token", value: refreshTokenValue!);
      }
    } catch (e) {
      secureStorageUnavailable = true;
      debugPrint("tapitask: secure storage unavailable, tokens in-memory: $e");
    }
  }

  bool get isConfigured => baseUrl.isNotEmpty;

  /// S2 (prod4) : logout volontaire — le serveur révoque le refresh token
  /// (best effort : hors-ligne, la purge locale fait quand même son
  /// travail, l'endpoint révoquera… rien, le token est déjà local purgé).
  Future<void> logout() async {
    final token = refreshTokenValue;
    if (token == null || token.isEmpty) return;
    try {
      await _http.post(Uri.parse("$baseUrl/auth/logout"),
          headers: {"Content-Type": "application/json"},
          body: jsonEncode({"refresh_token": token})).timeout(timeout);
    } catch (_) {}
  }

  Future<void> register(String email, String password) async {
    await _auth("/auth/register", {"email": email, "password": password});
  }

  Future<void> login(String email, String password,
      {String? totpCode}) async {
    await _auth("/auth/login", {
      "email": email,
      "password": password,
      if (totpCode != null) "totp_code": totpCode,
    });
  }

  Future<void> _auth(String path, Map<String, dynamic> body) async {
    final r = await _post(path, body, auth: false);
    final token = r["access_token"];
    if (token == null || token.toString().isEmpty) {
      // C1.7 : 202 « email à vérifier » → état typé, pas accessToken = null.
      throw const EmailVerificationRequired();
    }
    accessToken = token.toString();
    final refresh = r["refresh_token"];
    refreshTokenValue = refresh?.toString();
    await persist();
  }

  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body) =>
      _post(path, body, auth: true);

  /// Exécute [call] ; si la réponse est 401 et qu'un refresh réussit,
  /// relance UNE SEULE fois (3.7 prod3 : un 2e 401 après refresh se
  /// propage, pas de boucle infinie). [retryOn401] = false pour les
  /// appels non authentifiés (ex. /auth/login via _post(auth: false)).
  Future<http.Response> _withRetry(
    Future<http.Response> Function() call, {
    bool retryOn401 = true,
  }) async {
    final r = await call();
    if (retryOn401 && r.statusCode == 401 && await _tryRefresh()) {
      return call();
    }
    return r;
  }

  Future<Map<String, dynamic>> patch(
      String path, Map<String, dynamic> body) async {
    final r = await _withRetry(() => _http.patch(Uri.parse("$baseUrl$path"),
        headers: {
          "Authorization": "Bearer $accessToken",
          "Content-Type": "application/json"
        },
        body: jsonEncode(body)).timeout(timeout));
    _check(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Demande de changement d'email (step-up mot de passe + 2FA éventuel).
  Future<void> changeEmail(String newEmail, String password,
      {String? totpCode}) async {
    await post("/auth/change-email", {
      "new_email": newEmail,
      "password": password,
      if (totpCode != null) "totp_code": totpCode,
    });
  }

  /// Colle le code de vérification d'un changement d'email en attente.
  Future<void> verifyEmail(String token) async {
    await post("/auth/verify-email", {"token": token});
  }

  Future<void> delete(String path) async {
    final r = await _withRetry(() => _http.delete(Uri.parse("$baseUrl$path"),
        headers: {"Authorization": "Bearer $accessToken"}).timeout(timeout));
    _check(r);
  }

  Future<Map<String, dynamic>> get(String path) async {
    final r = await _withRetry(() => _http.get(Uri.parse("$baseUrl$path"),
        headers: {"Authorization": "Bearer $accessToken"}).timeout(timeout));
    _check(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// D-7 (spec 2026-11-25) : corps BRUT d'un export (JSON/markdown/CSV) —
  /// pas de décodage JSON, le texte est sauvé tel quel.
  Future<String> getRaw(String path) async {
    final r = await _withRetry(() => _http.get(Uri.parse("$baseUrl$path"),
        headers: {"Authorization": "Bearer $accessToken"}).timeout(timeout));
    _check(r);
    return r.body;
  }

  /// D-7 : POST /import — corps brut (export JSON tapitask OU markdown
  /// Obsidian ; le serveur détecte). [name] = nom du fichier (titre d'une
  /// liste markdown sans H1). Renvoie le corps de la réponse (listes créées).
  Future<Map<String, dynamic>> importFile(String body, {String? name}) async {
    var uri = Uri.parse("$baseUrl/import");
    if (name != null) {
      uri = uri.replace(queryParameters: {"name": name});
    }
    final r = await _withRetry(() => _http.post(uri,
        headers: {
          "Authorization": "Bearer $accessToken",
          "Content-Type": "application/octet-stream"
        },
        body: body).timeout(timeout));
    _check(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<List<dynamic>> getList(String path) async {
    final r = await _withRetry(() => _http.get(Uri.parse("$baseUrl$path"),
        headers: {"Authorization": "Bearer $accessToken"}).timeout(timeout));
    _check(r);
    return jsonDecode(r.body) as List<dynamic>;
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body,
      {required bool auth}) async {
    final headers = {"Content-Type": "application/json"};
    if (auth) headers["Authorization"] = "Bearer $accessToken";
    final r = await _withRetry(
        () => _http.post(Uri.parse("$baseUrl$path"),
            headers: headers, body: jsonEncode(body)).timeout(timeout),
        retryOn401: auth);
    _check(r);
    // 204 sans corps (ex. verify-email) : pas de JSON à décoder.
    return r.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// C2.7 : single-flight — un 401 qui arrive pendant un refresh attend le
  /// MÊME Future (relancer /auth/refresh utiliserait le token déjà roté).
  Future<bool> _tryRefresh() async {
    if (refreshTokenValue == null || refreshTokenValue!.isEmpty) return false;
    final inFlight = _refreshInFlight;
    if (inFlight != null) return inFlight;
    final future = _doRefresh();
    _refreshInFlight = future;
    try {
      return await future;
    } finally {
      _refreshInFlight = null;
    }
  }

  Future<bool> _doRefresh() async {
    try {
      final r = await _http.post(Uri.parse("$baseUrl/auth/refresh"),
          headers: {"Content-Type": "application/json"},
          body: jsonEncode({"refresh_token": refreshTokenValue})).timeout(timeout);
      if (r.statusCode == 401) {
        // C2.7 : expiration définitive — les deux tokens sont nuls, le
        // retrait est persisté et l'app est notifiée (état déconnecté ;
        // le WebSocket s'arrête car accessToken == null).
        accessToken = null;
        refreshTokenValue = null;
        await persist();
        onSessionExpired?.call();
        return false;
      }
      if (r.statusCode != 200) return false;
      // Rotation atomique (lot T) : les deux tokens sont mis à jour
      // AVANT la persist.
      final data = jsonDecode(r.body) as Map<String, dynamic>;
      accessToken = data["access_token"];
      refreshTokenValue = data["refresh_token"];
      await persist();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool>? _refreshInFlight;

  /// Ferme le client HTTP (tests : pas de fuite d'HttpClient au teardown).
  void close() => _http.close();

  void _check(http.Response r) {
    if (r.statusCode >= 400) {
      var message = r.body;
      try {
        final data = jsonDecode(r.body);
        if (data is Map && data.containsKey("detail")) {
          message = data["detail"].toString();
        }
      } catch (_) {}
      throw ApiException(r.statusCode, message);
    }
  }
}

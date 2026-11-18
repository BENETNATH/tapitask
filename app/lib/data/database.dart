import "package:drift/drift.dart";

import "connection/connection.dart";

part "database.g.dart";

class LocalLists extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get ownerId => text()();
  TextColumn get role => text().withDefault(const Constant("owner"))();
  DateTimeColumn get updatedAt => dateTime()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  BoolColumn get pinned => boolean().withDefault(const Constant(false))();
  BoolColumn get dirty => boolean().withDefault(const Constant(false))();
  TextColumn get color => text().nullable()();
  TextColumn get folder => text().nullable()();
  BoolColumn get localOnly => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

class LocalItems extends Table {
  TextColumn get id => text()();
  TextColumn get listId => text()();
  TextColumn get parentId => text().nullable()();
  TextColumn get label => text()();
  BoolColumn get done => boolean().withDefault(const Constant(false))();
  IntColumn get position => integer().withDefault(const Constant(0))();
  TextColumn get recurrence => text().withDefault(const Constant("none"))();
  DateTimeColumn get dueDate => dateTime().nullable()();
  TextColumn get notes => text().nullable()();
  TextColumn get assigneeId => text().nullable()();
  DateTimeColumn get updatedAt => dateTime()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  BoolColumn get dirty => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [LocalLists, LocalItems])
class AppDb extends _$AppDb {
  AppDb() : super(openConnection());

  AppDb.forTesting(super.e);

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.addColumn(localItems, localItems.parentId);
            await m.addColumn(localItems, localItems.recurrence);
            await m.addColumn(localItems, localItems.dueDate);
            await m.addColumn(localLists, localLists.dirty);
          }
          if (from < 3) {
            await m.addColumn(localLists, localLists.color);
            await m.addColumn(localLists, localLists.localOnly);
          }
          if (from < 4) {
            await m.addColumn(localLists, localLists.folder);
            await m.addColumn(localItems, localItems.notes);
            await m.addColumn(localItems, localItems.assigneeId);
          }
        },
      );

  // ---- Lists ----

  Future<List<LocalList>> visibleLists() {
    final q = select(localLists)..where((l) => l.deleted.equals(false));
    q.orderBy([(l) => OrderingTerm.desc(l.updatedAt)]);
    return q.get();
  }

  /// Reactive variants (drift watch()): the UI never re-queries manually,
  /// no flash of empty content between a setState and the DB answer.
  Stream<List<LocalList>> watchVisibleLists() {
    final q = select(localLists)..where((l) => l.deleted.equals(false));
    q.orderBy([(l) => OrderingTerm.desc(l.updatedAt)]);
    return q.watch();
  }

  Stream<List<LocalList>> watchPinnedLists() =>
      (select(localLists)
            ..where((l) => l.deleted.equals(false) & l.pinned.equals(true)))
          .watch();

  Stream<List<LocalItem>> watchItemsOf(String listId) {
    final q = select(localItems)
      ..where((i) =>
          i.listId.equals(listId) &
          i.deleted.equals(false));
    q.orderBy([
      (i) => OrderingTerm(expression: i.done, mode: OrderingMode.asc),
      (i) => OrderingTerm.asc(i.position)
    ]);
    return q.watch();
  }

  Stream<List<LocalItem>> watchDueItems() {
    final now = DateTime.now();
    final endOfDay =
        DateTime(now.year, now.month, now.day).add(const Duration(days: 1));
    final q = select(localItems).join([
      innerJoin(localLists, localLists.id.equalsExp(localItems.listId)),
    ]);
    q.where(localItems.deleted.equals(false) &
        localItems.done.equals(false) &
        localItems.dueDate.isSmallerOrEqualValue(endOfDay) &
        localLists.localOnly.equals(false) &
        localLists.deleted.equals(false));
    q.orderBy([OrderingTerm.asc(localItems.dueDate)]);
    return q.watch().map(
        (rows) => rows.map((r) => r.readTable(localItems)).toList());
  }

  Stream<List<LocalItem>> watchAllUncheckedItems() {
    final q = select(localItems).join([
      innerJoin(localLists, localLists.id.equalsExp(localItems.listId)),
    ]);
    q.where(localItems.deleted.equals(false) &
        localItems.done.equals(false) &
        localLists.localOnly.equals(false) &
        localLists.deleted.equals(false));
    q.orderBy([
      OrderingTerm.asc(localLists.title),
      OrderingTerm.asc(localItems.position),
    ]);
    return q.watch().map(
        (rows) => rows.map((r) => r.readTable(localItems)).toList());
  }

  Future<List<LocalList>> pinnedLists() =>
      (select(localLists)
            ..where((l) => l.deleted.equals(false) & l.pinned.equals(true)))
          .get();

  Future<Set<String>> localOnlyListIds() async {
    final rows = await (select(localLists)
          ..where((l) => l.localOnly.equals(true) & l.deleted.equals(false)))
        .get();
    return rows.map((l) => l.id).toSet();
  }

  Future<List<LocalList>> dirtyLists() =>
      (select(localLists)..where((l) => l.dirty.equals(true))).get();

  Future<void> upsertList(LocalListsCompanion entry) async {
    await into(localLists).insertOnConflictUpdate(entry);
  }

  Future<void> renameList(String id, String title, DateTime now) async {
    await (update(localLists)..where((l) => l.id.equals(id))).write(
      LocalListsCompanion(
          title: Value(title), updatedAt: Value(now), dirty: const Value(true)),
    );
  }

  Future<void> deleteList(String id, DateTime now) async {
    await (update(localLists)..where((l) => l.id.equals(id))).write(
      LocalListsCompanion(
          deleted: const Value(true), updatedAt: Value(now), dirty: const Value(true)),
    );
  }

  /// Mark a list deleted after a server-side deletion (no outbox echo).
  Future<void> applyRemoteListDeletion(String id, DateTime now) async {
    await (update(localLists)..where((l) => l.id.equals(id))).write(
      LocalListsCompanion(
          deleted: const Value(true),
          updatedAt: Value(now),
          dirty: const Value(false)),
    );
  }

  /// Single list by id, or null (try/getSingle/catch → null partagé par
  /// list/today/todo-all, spec lot T, T9).
  Future<LocalList?> getList(String id) async {
    try {
      return await (select(localLists)..where((l) => l.id.equals(id)))
          .getSingle();
    } catch (_) {
      return null;
    }
  }

  // ---- Items ----

  Future<List<LocalItem>> itemsOf(String listId) {
    final q = select(localItems)
      ..where((i) => i.listId.equals(listId) & i.deleted.equals(false));
    q.orderBy([
      (i) => OrderingTerm(expression: i.done, mode: OrderingMode.asc),
      (i) => OrderingTerm.asc(i.position)
    ]);
    return q.get();
  }

  Future<List<LocalItem>> uncheckedItemsOf(String listId) {
    final q = select(localItems)
      ..where((i) =>
          i.listId.equals(listId) &
          i.deleted.equals(false) &
          i.done.equals(false));
    q.orderBy([(i) => OrderingTerm.asc(i.position)]);
    return q.get();
  }

  /// Global search across every visible list.
  Future<List<LocalItem>> search(String query) {
    final q = select(localItems)
      ..where((i) =>
          i.deleted.equals(false) &
          i.label.lower().like("%${query.toLowerCase()}%"));
    q.orderBy([(i) => OrderingTerm.asc(i.updatedAt)]);
    q.limit(50);
    return q.get();
  }

  Future<void> addItem(String id, String listId, String label, int position,
      DateTime now,
      {String? parentId, String recurrence = "none", DateTime? dueDate,
      String? notes, String? assigneeId}) async {
    await into(localItems).insertOnConflictUpdate(LocalItemsCompanion(
      id: Value(id),
      listId: Value(listId),
      parentId: Value(parentId),
      label: Value(label),
      position: Value(position),
      recurrence: Value(recurrence),
      dueDate: Value(dueDate),
      notes: Value(notes),
      assigneeId: Value(assigneeId),
      updatedAt: Value(now),
      dirty: const Value(true),
    ));
  }

  Future<void> setDone(String id, bool done, DateTime now) async {
    await (update(localItems)..where((i) => i.id.equals(id))).write(
      LocalItemsCompanion(
          done: Value(done), updatedAt: Value(now), dirty: const Value(true)),
    );
  }

  Future<void> setItemDetails(String id, DateTime now,
      {String? notes, DateTime? dueDate, bool clearDue = false}) async {
    await (update(localItems)..where((i) => i.id.equals(id))).write(
      LocalItemsCompanion(
        notes: Value(notes),
        dueDate: clearDue ? const Value(null) : Value(dueDate),
        updatedAt: Value(now),
        dirty: const Value(true),
      ),
    );
  }

  /// Items due today or overdue, across every synced list.
  /// [endOfDay] is exclusive: defaults to the start of tomorrow.
  Future<List<LocalItem>> dueItems([DateTime? endOfDay]) async {
    final now = DateTime.now();
    endOfDay ??= DateTime(now.year, now.month, now.day)
        .add(const Duration(days: 1));
    final q = select(localItems).join([
      innerJoin(localLists,
          localLists.id.equalsExp(localItems.listId)),
    ]);
    q.where(localItems.deleted.equals(false) &
        localItems.done.equals(false) &
        localItems.dueDate.isSmallerOrEqualValue(endOfDay) &
        localLists.localOnly.equals(false) &
        localLists.deleted.equals(false));
    q.orderBy([OrderingTerm.asc(localItems.dueDate)]);
    final rows = await q.get();
    return rows.map((r) => r.readTable(localItems)).toList();
  }

  Future<void> reorder(String id, int position, DateTime now) async {
    await (update(localItems)..where((i) => i.id.equals(id))).write(
      LocalItemsCompanion(
          position: Value(position),
          updatedAt: Value(now),
          dirty: const Value(true)),
    );
  }

  Future<void> deleteItem(String id, DateTime now) async {
    await (update(localItems)..where((i) => i.id.equals(id))).write(
      LocalItemsCompanion(
          deleted: const Value(true),
          updatedAt: Value(now),
          dirty: const Value(true)),
    );
    // sub-tasks follow their parent
    await (update(localItems)..where((i) => i.parentId.equals(id))).write(
      LocalItemsCompanion(
          deleted: const Value(true),
          updatedAt: Value(now),
          dirty: const Value(true)),
    );
  }

  /// Undo a deletion: restore the item and its children.
  Future<void> restoreItem(String id, DateTime now) async {
    await (update(localItems)..where((i) => i.id.equals(id))).write(
      LocalItemsCompanion(
          deleted: const Value(false),
          updatedAt: Value(now),
          dirty: const Value(true)),
    );
    await (update(localItems)..where((i) => i.parentId.equals(id))).write(
      LocalItemsCompanion(
          deleted: const Value(false),
          updatedAt: Value(now),
          dirty: const Value(true)),
    );
  }

  Future<void> purgeDone(String listId, DateTime now) async {
    await (update(localItems)
          ..where((i) =>
              i.listId.equals(listId) &
              i.deleted.equals(false) &
              i.done.equals(true)))
        .write(LocalItemsCompanion(
            deleted: const Value(true),
            updatedAt: Value(now),
            dirty: const Value(true)));
  }

  Future<List<LocalItem>> dirtyItems() =>
      (select(localItems)..where((i) => i.dirty.equals(true))).get();

  Future<void> clearDirty(List<String> ids) async {
    await (update(localItems)..where((i) => i.id.isIn(ids)))
        .write(const LocalItemsCompanion(dirty: Value(false)));
  }

  Future<void> clearListDirty(String id) async {
    await (update(localLists)..where((l) => l.id.equals(id)))
        .write(const LocalListsCompanion(dirty: Value(false)));
  }

  Future<void> applyRemoteItem(LocalItemsCompanion entry) async {
    final id = entry.id.value;
    final existing = await (select(localItems)..where((i) => i.id.equals(id)))
        .getSingleOrNull();
    // Last-write-wins: ignore stale remote changes on dirty local rows.
    if (existing != null && existing.dirty) return;
    await into(localItems).insertOnConflictUpdate(entry);
  }

  Future<int> nextPosition(String listId) async {
    final rows = await (select(localItems)
          ..where((i) => i.listId.equals(listId)))
        .get();
    if (rows.isEmpty) return 0;
    return rows.map((r) => r.position).reduce((a, b) => a > b ? a : b) + 1;
  }
}

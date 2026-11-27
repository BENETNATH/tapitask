import "package:drift/drift.dart" hide isNull;
import "package:drift/native.dart";
import "package:flutter_test/flutter_test.dart";

import "package:tapitask/data/database.dart";

void main() {
  late AppDb db;

  setUp(() {
    db = AppDb.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test("ajout et lecture d'items, ordre par position et done", () async {
    final now = DateTime.now().toUtc();
    await db.upsertList(LocalListsCompanion.insert(
      id: "list-1",
      title: "Courses",
      ownerId: "",
      updatedAt: now,
    ));
    await db.addItem("i1", "list-1", "Lait", 0, now);
    await db.addItem("i2", "list-1", "Pain", 1, now);
    await db.addItem("i3", "list-1", "Beurre", 2, now);
    await db.setDone("i2", true, now);

    final items = await db.itemsOf("list-1");
    expect(items.length, 3);
    expect(items.first.label, "Lait");
    expect(items.map((i) => i.done), contains(true));

    final unchecked = await db.uncheckedItemsOf("list-1");
    expect(unchecked.map((i) => i.label), ["Lait", "Beurre"]);
  });

  test("sous-taches : parentId conserve la hierarchie", () async {
    final now = DateTime.now().toUtc();
    await db.upsertList(LocalListsCompanion.insert(
      id: "list-2",
      title: "Projet",
      ownerId: "",
      updatedAt: now,
    ));
    await db.addItem("parent", "list-2", "Tache principale", 0, now);
    await db.addItem("child", "list-2", "Sous-tache", 0, now,
        parentId: "parent");

    final all = await db.itemsOf("list-2");
    final child = all.firstWhere((i) => i.id == "child");
    expect(child.parentId, "parent");
  });

  test("recherche globale insensible a la casse", () async {
    final now = DateTime.now().toUtc();
    await db.upsertList(LocalListsCompanion.insert(
      id: "list-3",
      title: "Maison",
      ownerId: "",
      updatedAt: now,
    ));
    await db.addItem("x1", "list-3", "Appeler le plombier", 0, now);
    await db.addItem("x2", "list-3", "Tondre la pelouse", 1, now);

    final hits = await db.search("PLOMB");
    expect(hits.length, 1);
    expect(hits.single.label, "Appeler le plombier");
  });

  test("renommer une liste la marque dirty", () async {
    final now = DateTime.now().toUtc();
    await db.upsertList(LocalListsCompanion.insert(
      id: "list-r",
      title: "Ancien",
      ownerId: "",
      updatedAt: now,
    ));
    await db.renameList("list-r", "Nouveau", now);
    final dirty = await db.dirtyLists();
    expect(dirty.map((l) => l.id), contains("list-r"));
    final visible = await db.visibleLists();
    expect(visible.firstWhere((l) => l.id == "list-r").title, "Nouveau");
  });

  test("suppression locale de liste + application d'une suppression serveur", () async {
    final now = DateTime.now().toUtc();
    await db.upsertList(LocalListsCompanion.insert(
      id: "list-d",
      title: "A supprimer",
      ownerId: "",
      updatedAt: now,
    ));
    await db.deleteList("list-d", now);
    expect((await db.visibleLists()).where((l) => l.id == "list-d"), isEmpty);
    expect((await db.dirtyLists()).map((l) => l.id), contains("list-d"));

    // remote deletion: not dirty, no echo
    await db.upsertList(LocalListsCompanion.insert(
      id: "list-rd",
      title: "Serveur",
      ownerId: "",
      updatedAt: now,
    ));
    await db.applyRemoteListDeletion("list-rd", now);
    expect((await db.visibleLists()).where((l) => l.id == "list-rd"), isEmpty);
    expect((await db.dirtyLists()).map((l) => l.id), isNot(contains("list-rd")));
  });

  test("echeances : setItemDetails et requete dueItems", () async {
    final now = DateTime.now().toUtc();
    await db.upsertList(LocalListsCompanion.insert(
      id: "list-due",
      title: "Echeances",
      ownerId: "",
      updatedAt: now,
    ));
    await db.upsertList(LocalListsCompanion.insert(
      id: "list-local",
      title: "Locale",
      ownerId: "",
      updatedAt: now,
    ));
    await (db.update(db.localLists)..where((l) => l.id.equals("list-local")))
        .write(const LocalListsCompanion(localOnly: Value(true)));

    await db.addItem("d1", "list-due", "Urgent", 0, now,
        dueDate: DateTime.now().subtract(const Duration(days: 1)));
    await db.addItem("d2", "list-due", "Aujourd'hui", 1, now,
        dueDate: DateTime.now());
    await db.addItem("d3", "list-due", "Demain", 2, now,
        dueDate: DateTime.now().add(const Duration(days: 1)));
    await db.addItem("d4", "list-local", "Local ignore", 0, now,
        dueDate: DateTime.now());

    final due = await db.dueItems();
    expect(due.map((i) => i.id), containsAll(["d1", "d2"]));
    expect(due.map((i) => i.id), isNot(contains("d3")));
    expect(due.map((i) => i.id), isNot(contains("d4")));
  });

  test("all-day due dates use the calendar day and survive notes edits", () async {
    final day = DateTime(2026, 11, 23, 18);
    final tomorrow = DateTime(2026, 11, 24);
    await db.upsertList(LocalListsCompanion.insert(id: "all-day", title: "List",
        ownerId: "", updatedAt: day));
    await db.addItem("all-day-task", "all-day", "Task", 0, day,
        dueDay: "2026-11-23", dueDate: DateTime(2026, 11, 24, 5));
    await db.addItem("tomorrow", "all-day", "Tomorrow", 1, day,
        dueDay: "2026-11-24", dueDate: DateTime(2026, 11, 23, 23));
    await db.setItemDetails("all-day-task", day, notes: "https://example.com");
    final item = (await db.dueItems(tomorrow)).single;
    expect(item.localDue, DateTime(2026, 11, 23));
    expect(item.overdueAt(day), isFalse);
    expect(item.overdueAt(tomorrow), isTrue);
    await db.setItemDetails(item.id, day, clearDue: true);
    final cleared = (await db.getItem(item.id))!;
    expect(cleared.localDue, isNull);
    expect(cleared.notes, "https://example.com");
  });

  test("dossier et couleur sur les listes", () async {
    final now = DateTime.now().toUtc();
    await db.upsertList(LocalListsCompanion.insert(
      id: "list-folder",
      title: "Dans un dossier",
      ownerId: "",
      updatedAt: now,
    ));
    await (db.update(db.localLists)..where((l) => l.id.equals("list-folder")))
        .write(const LocalListsCompanion(folder: Value("Perso")));
    final lists = await db.visibleLists();
    final target = lists.firstWhere((l) => l.id == "list-folder");
    expect(target.folder, "Perso");
  });

  test("getList: id inconnu → null ; panne DB réelle → erreur propagée",
      () async {
    final now = DateTime.now().toUtc();
    final db2 = AppDb.forTesting(NativeDatabase.memory());
    await db2.upsertList(LocalListsCompanion.insert(
      id: "list-gl",
      title: "Cible",
      ownerId: "",
      updatedAt: now,
    ));
    expect(await db2.getList("list-gl"), isA<LocalList>(),
        reason: "getList: une liste existante est trouvée");
    expect(await db2.getList("inexistant"), isNull,
        reason: "getList: un id inconnu renvoie null, pas d'exception");
    await db2.close();
    await expectLater(db2.getList("list-gl"), throwsA(isA<StateError>()),
        reason: "panne DB réelle (base fermée) : l'erreur se propage, "
            "pas avalée en null");
  });

  test("items supprimes sont exclus, dirty suit les changements", () async {
    final now = DateTime.now().toUtc();
    await db.upsertList(LocalListsCompanion.insert(
      id: "list-4",
      title: "Test",
      ownerId: "",
      updatedAt: now,
    ));
    await db.addItem("y1", "list-4", "A faire", 0, now);
    await db.deleteItem("y1", now);

    expect(await db.itemsOf("list-4"), isEmpty);
    final dirty = await db.dirtyItems();
    expect(dirty.map((i) => i.id), ["y1"]);
  });
}

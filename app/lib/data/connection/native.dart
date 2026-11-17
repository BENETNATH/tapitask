import "dart:io";

import "package:drift/drift.dart";
import "package:drift/native.dart";
import "package:path/path.dart" as p;
import "package:path_provider/path_provider.dart";

/// VM / Android / desktop: file-backed SQLite via FFI.
QueryExecutor openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, "tapitask.sqlite"));
    // WAL + busy_timeout: the main window and the tray flyout hold two
    // separate connections on the SAME file — without these pragmas a
    // concurrent write raises SQLITE_BUSY (silently swallowed upstream).
    return NativeDatabase.createInBackground(
      file,
      setup: (rawDb) {
        rawDb.execute("PRAGMA journal_mode=WAL;");
        rawDb.execute("PRAGMA busy_timeout=5000;");
        rawDb.execute("PRAGMA foreign_keys=ON;");
      },
    );
  });
}

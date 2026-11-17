import "package:drift/drift.dart";
import "package:drift/wasm.dart";
import "package:flutter/foundation.dart";

/// Web: SQLite compiled to WASM (assets: web/sqlite3.wasm, web/drift_worker.js).
/// Persistence is automatic: FileSystem Access API, IndexedDB or in-memory
/// depending on the browser.
QueryExecutor openConnection() {
  return DatabaseConnection.delayed(Future(() async {
    final result = await WasmDatabase.open(
      databaseName: "tapitask",
      sqlite3Uri: Uri.parse("sqlite3.wasm"),
      driftWorkerUri: Uri.parse("drift_worker.js"),
    );
    if (result.missingFeatures.isNotEmpty) {
      debugPrint("WasmDatabase: ${result.chosenImplementation} "
          "(missing: ${result.missingFeatures})");
    }
    return result.resolvedExecutor;
  }));
}

import "package:drift/drift.dart";

/// Fallback for platforms without a database backend: fails loudly if the
/// conditional import ever resolves here.
QueryExecutor openConnection() => throw UnimplementedError();

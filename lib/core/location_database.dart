import 'package:sqflite/sqflite.dart';

import '../features/tracking/location_record.dart';

Future<Database> openLocationDatabase(
  String path, {
  DatabaseFactory? factory,
}) => (factory ?? databaseFactory).openDatabase(
  path,
  options: OpenDatabaseOptions(
    version: 1,
    onCreate: (db, _) async {
      await db.execute('''
        CREATE TABLE locations (
          id TEXT PRIMARY KEY,
          latitude REAL NOT NULL,
          longitude REAL NOT NULL,
          timestamp INTEGER NOT NULL,
          simulated INTEGER NOT NULL,
          syncStatus TEXT NOT NULL DEFAULT 'pending',
          retryCount INTEGER NOT NULL DEFAULT 0,
          retryAt INTEGER NOT NULL DEFAULT 0
        )
      ''');
      await db.execute(
        'CREATE INDEX locations_due ON locations(syncStatus, retryAt)',
      );
      await db.execute(
        'CREATE INDEX locations_time ON locations(timestamp DESC, id DESC)',
      );
    },
  ),
);

class LocationStore {
  LocationStore(this.db);

  final Database db;

  Future<void> save(Iterable<LocationRecord> records) async {
    final batch = db.batch();
    for (final record in records) {
      batch.insert(
        'locations',
        record.toPayload(),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<({List<LocationRecord> history, Map<SyncStatus, int> counts})>
  snapshot() => db.transaction((tx) async {
    final history = await tx.query(
      'locations',
      orderBy: 'timestamp DESC, id DESC',
      limit: 200,
    );
    final counts = await tx.rawQuery(
      'SELECT syncStatus, COUNT(*) AS count FROM locations GROUP BY syncStatus',
    );
    return (
      history: history.map(LocationRecord.fromRow).toList(growable: false),
      counts: {
        for (final row in counts)
          SyncStatus.values.byName(row['syncStatus'] as String):
              row['count'] as int,
      },
    );
  });

  Future<List<Map<String, Object?>>> due(DateTime now) => db.query(
    'locations',
    where: "syncStatus = 'pending' AND retryAt <= ?",
    whereArgs: [now.millisecondsSinceEpoch],
    orderBy: 'retryAt, timestamp, id',
    limit: 50,
  );

  Future<DateTime?> nextRetry() async {
    final rows = await db.rawQuery(
      "SELECT MIN(retryAt) AS next FROM locations WHERE syncStatus = 'pending'",
    );
    final next = rows.single['next'] as int?;
    return next == null ? null : DateTime.fromMillisecondsSinceEpoch(next);
  }

  Future<void> update(String id, Map<String, Object> values) async {
    await db.update(
      'locations',
      values,
      where: "id = ? AND syncStatus = 'pending'",
      whereArgs: [id],
    );
  }

  Future<void> retryFailed() async {
    await db.update('locations', {
      'syncStatus': 'pending',
      'retryCount': 0,
      'retryAt': 0,
    }, where: "syncStatus = 'failed'");
  }
}

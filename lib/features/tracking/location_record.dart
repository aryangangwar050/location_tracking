enum SyncStatus { pending, synced, failed }

class LocationRecord {
  const LocationRecord({
    required this.id,
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    this.simulated = false,
    this.status = SyncStatus.pending,
  });

  factory LocationRecord.fromRow(Map<Object?, Object?> row) => LocationRecord(
    id: row['id'] as String,
    latitude: (row['latitude'] as num).toDouble(),
    longitude: (row['longitude'] as num).toDouble(),
    timestamp: DateTime.fromMillisecondsSinceEpoch(
      row['timestamp'] as int,
      isUtc: true,
    ),
    simulated: row['simulated'] == 1,
    status: SyncStatus.values.byName(row['syncStatus'] as String? ?? 'pending'),
  );

  final String id;
  final double latitude;
  final double longitude;
  final DateTime timestamp;
  final bool simulated;
  final SyncStatus status;

  Map<String, Object> toPayload() => {
    'id': id,
    'latitude': latitude,
    'longitude': longitude,
    'timestamp': timestamp.millisecondsSinceEpoch,
    'simulated': simulated ? 1 : 0,
  };
}

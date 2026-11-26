import '../../core/location_api.dart';
import '../../core/location_database.dart';
import 'location_record.dart';

class TrackingRepository {
  TrackingRepository(this.store, this.api, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final LocationStore store;
  final LocationApi api;
  final DateTime Function() _clock;
  static const maxAttempts = 5;
  bool _running = false;

  Future<Duration?> synchronize(bool Function() online) async {
    if (_running || !online()) return null;
    _running = true;
    try {
      if ((await store.due(_clock())).isEmpty) {
        return _delayUntilNext();
      }
      if (!online()) return null;
      if (!await api.reachable()) return const Duration(seconds: 15);
      while (online()) {
        final batch = await store.due(_clock());
        if (batch.isEmpty) return _delayUntilNext();
        for (final row in batch) {
          if (!online()) return null;
          final record = LocationRecord.fromRow(row);
          if (await api.upload(record)) {
            await store.update(record.id, {
              'syncStatus': 'synced',
              'retryAt': 0,
            });
          } else {
            final attempts = (row['retryCount'] as int) + 1;
            final delay = Duration(seconds: 5 * (1 << (attempts - 1)));
            await store.update(record.id, {
              'syncStatus': attempts >= maxAttempts ? 'failed' : 'pending',
              'retryCount': attempts,
              'retryAt': _clock().add(delay).millisecondsSinceEpoch,
            });
          }
        }
      }
      return null;
    } finally {
      _running = false;
    }
  }

  Future<Duration?> _delayUntilNext() async {
    final next = await store.nextRetry();
    if (next == null) return null;
    final delay = next.difference(_clock());
    return delay.isNegative ? Duration.zero : delay;
  }
}

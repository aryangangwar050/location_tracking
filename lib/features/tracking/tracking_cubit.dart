import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../core/location_api.dart';
import '../../core/native_tracking.dart';
import 'location_record.dart';
import 'tracking_repository.dart';

typedef Session = ({bool active, bool authorized, String error});
typedef History = ({List<LocationRecord> history, Map<SyncStatus, int> counts});

typedef TrackingState = ({
  Session gps,
  History data,
  bool simulated,
  bool simulationActive,
  bool network,
  bool offline,
  bool busy,
  bool syncing,
  bool failUploads,
  String error,
});

class TrackingCubit extends Cubit<TrackingState> {
  TrackingCubit(this.native, this.repository, this.mock, this.connectivity)
    : super((
        gps: (active: false, authorized: false, error: ''),
        data: (history: const [], counts: const {}),
        simulated: false,
        simulationActive: false,
        network: false,
        offline: false,
        busy: false,
        syncing: false,
        failUploads: false,
        error: '',
      ));

  final NativeTracking native;
  final TrackingRepository repository;
  final MockLocationServer? mock;
  final Connectivity connectivity;
  StreamSubscription<Map<Object?, Object?>>? _events;
  StreamSubscription<List<ConnectivityResult>>? _network;
  Timer? _simulation;
  Future<void>? _simulationWrite;
  Timer? _retry;
  Future<void>? _refreshingNative;
  Future<void>? _syncing;
  bool _refreshAgain = false;
  bool _syncAgain = false;
  bool _closing = false;
  int _networkVersion = 0;
  int _nativeVersion = 0;

  bool get _online => !_closing && state.network && !state.offline;

  void _update({
    Session? gps,
    History? data,
    bool? simulated,
    bool? simulationActive,
    bool? network,
    bool? offline,
    bool? busy,
    bool? syncing,
    bool? failUploads,
    String? error,
  }) {
    if (_closing) return;
    emit((
      gps: gps ?? state.gps,
      data: data ?? state.data,
      simulated: simulated ?? state.simulated,
      simulationActive: simulationActive ?? state.simulationActive,
      network: network ?? state.network,
      offline: offline ?? state.offline,
      busy: busy ?? state.busy,
      syncing: syncing ?? state.syncing,
      failUploads: failUploads ?? state.failUploads,
      error: error ?? state.error,
    ));
  }

  void initialize() {
    if (_closing || _events != null) return;
    _events = native.events.listen((event) {
      if (event['location'] == null) {
        _nativeVersion++;
        _applyNativeState(event);
      }
      unawaited(refreshNative());
    }, onError: (Object error) => _report(error));
    _network = connectivity.onConnectivityChanged.listen((results) {
      _networkVersion++;
      _applyNetwork(results);
    }, onError: (Object error) => _report(error));
    unawaited(resume());
  }

  Future<void> resume() async {
    if (_closing) return;
    final nativeVersion = _nativeVersion;
    final version = _networkVersion;
    await Future.wait([
      _guard(() async {
        final results = await connectivity.checkConnectivity();
        if (version == _networkVersion && !_closing) _applyNetwork(results);
      }),
      _guard(() async {
        final current = await native.state();
        if (nativeVersion == _nativeVersion) _applyNativeState(current);
      }),
      refreshNative(),
    ]);
    _kickSync();
  }

  void _applyNativeState(Map<Object?, Object?> row) => _update(
    gps: (
      active: row['active'] == true,
      authorized: row['authorized'] == true,
      error: row['error'] as String? ?? '',
    ),
  );

  void _applyNetwork(List<ConnectivityResult> results) {
    _update(
      network: results.any((result) => result != ConnectivityResult.none),
    );
    _kickSync();
  }

  Future<void> refreshNative() {
    if (_closing) return Future.value();
    _refreshAgain = true;
    return _refreshingNative ??= _drainNative().whenComplete(() {
      _refreshingNative = null;
      if (_refreshAgain && !_closing) unawaited(refreshNative());
    });
  }

  Future<void> _drainNative() async {
    while (_refreshAgain && !_closing) {
      _refreshAgain = false;
      await _guard(() async {
        while (!_closing) {
          final fixes = await native.read();
          if (fixes.isEmpty) break;
          await repository.store.save(fixes);
          await native.acknowledge(fixes.map((fix) => fix.id).toList());
        }
      });
      await _guard(_refreshHistory);
      _kickSync();
    }
  }

  Future<void> _refreshHistory() async {
    _update(data: await repository.store.snapshot());
  }

  void _kickSync() {
    _retry?.cancel();
    if (!_online) return;
    _syncAgain = true;
    _syncing ??= _runSync().whenComplete(() {
      _syncing = null;
      if (_syncAgain && _online) _kickSync();
    });
  }

  Future<void> _runSync() async {
    _update(syncing: true);
    try {
      while (_syncAgain && _online) {
        _syncAgain = false;
        Duration? delay;
        try {
          delay = await repository.synchronize(() => _online);
          await _refreshHistory();
        } catch (error) {
          _report(error);
          delay = const Duration(seconds: 15);
        }
        if (delay != null && _online && !_syncAgain) {
          _retry = Timer(delay, _kickSync);
        }
      }
    } finally {
      _update(syncing: false);
    }
  }

  Future<void> start() async {
    if (active) return;
    await _control(() async {
      if (state.simulated) {
        var recorded = false;
        final write = _guard(() async {
          await _recordSimulation();
          recorded = true;
        });
        _simulationWrite = write;
        await write;
        _simulationWrite = null;
        if (_closing || !recorded) return;
        _update(simulationActive: true);
        _scheduleSimulation();
      } else {
        await native.start();
        final version = _nativeVersion;
        final current = await native.state();
        if (version == _nativeVersion) _applyNativeState(current);
      }
    });
  }

  Future<void> stop() async {
    if (!active) return;
    await _control(() async {
      if (state.simulated) {
        _simulation?.cancel();
        _update(simulationActive: false);
        await _simulationWrite;
      } else {
        await native.stop();
      }
    });
  }

  bool get active => state.gps.active || state.simulationActive;

  void _scheduleSimulation() {
    if (_closing || !state.simulationActive) return;
    _simulation = Timer(const Duration(seconds: 5), () async {
      final write = _guard(_recordSimulation);
      _simulationWrite = write;
      await write;
      _simulationWrite = null;
      _scheduleSimulation();
    });
  }

  void setSimulated(bool value) {
    if (!active && !state.busy) _update(simulated: value, error: '');
  }

  void setOffline(bool value) {
    _update(offline: value);
    _kickSync();
  }

  void setFailUploads(bool value) {
    mock?.failUploads = value;
    _update(failUploads: value);
    _kickSync();
  }

  Future<void> retryFailed() => _guard(() async {
    await repository.store.retryFailed();
    await _refreshHistory();
    _kickSync();
  });

  int _simulationStep = 0;

  Future<void> _recordSimulation() async {
    final step = _simulationStep++;
    await repository.store.save([
      LocationRecord(
        id: const Uuid().v4(),
        latitude: 12.9716 + step * 0.0001,
        longitude: 77.5946 + step * 0.0001,
        timestamp: DateTime.now(),
        simulated: true,
      ),
    ]);
    await _refreshHistory();
    _kickSync();
  }

  Future<void> _control(Future<void> Function() action) async {
    if (_closing || state.busy) return;
    _update(busy: true, error: '');
    await _guard(action);
    _update(busy: false);
  }

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      _report(error);
    }
  }

  void _report(Object error) {
    if (kDebugMode) debugPrint('Driver Tracking: ${error.runtimeType}');
    _update(
      error: error is PlatformException
          ? error.message ?? 'Native tracking is unavailable.'
          : 'A tracking or synchronization operation failed.',
    );
  }

  @override
  Future<void> close() async {
    _closing = true;
    _retry?.cancel();
    _simulation?.cancel();
    await _network?.cancel();
    await _events?.cancel();
    await _simulationWrite;
    await _refreshingNative;
    await _syncing;
    repository.api.client.close();
    await super.close();
  }
}

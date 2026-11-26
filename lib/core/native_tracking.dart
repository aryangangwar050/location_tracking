import 'package:flutter/services.dart';

import '../features/tracking/location_record.dart';

class NativeTracking {
  static const _methods = MethodChannel('driver_tracking/methods');
  static const _events = EventChannel('driver_tracking/events');

  Stream<Map<Object?, Object?>> get events =>
      _events.receiveBroadcastStream().cast<Map<Object?, Object?>>();

  Future<Map<Object?, Object?>> state() async =>
      await _methods.invokeMapMethod<Object?, Object?>('state') ?? {};

  Future<void> start() => _methods.invokeMethod<void>('start');

  Future<void> stop() => _methods.invokeMethod<void>('stop');

  Future<List<LocationRecord>> read() async {
    final rows = await _methods.invokeListMethod<Map<Object?, Object?>>('read');
    return (rows ?? []).map(LocationRecord.fromRow).toList(growable: false);
  }

  Future<void> acknowledge(List<String> ids) =>
      _methods.invokeMethod<void>('ack', ids);
}

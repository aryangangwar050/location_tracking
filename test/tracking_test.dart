import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:location_tracking/core/location_api.dart';
import 'package:location_tracking/core/location_database.dart';
import 'package:location_tracking/core/native_tracking.dart';
import 'package:location_tracking/features/tracking/location_record.dart';
import 'package:location_tracking/features/tracking/tracking_cubit.dart';
import 'package:location_tracking/features/tracking/tracking_repository.dart';
import 'package:location_tracking/main.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  final record = LocationRecord(
    id: 'f868d080-2a97-41f8-8949-714f6f521132',
    latitude: 12.97,
    longitude: 77.59,
    timestamp: DateTime.utc(2026, 1, 1),
  );

  late Directory directory;
  late Database local;
  late Database remote;
  late LocationStore store;
  late MockLocationServer server;
  late LocationApi api;
  late DateTime now;
  late TrackingRepository repository;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('driver-tracking-test');
    local = await openLocationDatabase(
      '${directory.path}/locations.db',
      factory: databaseFactoryFfi,
    );
    remote = await databaseFactoryFfi.openDatabase(
      '${directory.path}/remote.db',
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) => db.execute(
          'CREATE TABLE receipts (id TEXT PRIMARY KEY, payload TEXT NOT NULL)',
        ),
      ),
    );
    store = LocationStore(local);
    server = MockLocationServer(remote);
    api = LocationApi(server.createClient(), Uri.https('test.invalid'));
    now = DateTime.utc(2026, 1, 1);
    repository = TrackingRepository(store, api, clock: () => now);
  });

  tearDown(() async {
    api.client.close();
    await local.close();
    await remote.close();
    await directory.delete(recursive: true);
  });

  test(
    'offline fixes survive reopening and synchronize once on reconnect',
    () async {
      await store.save([record, record]);
      await repository.synchronize(() => false);
      expect(await remote.query('receipts'), isEmpty);

      await local.close();
      local = await openLocationDatabase(
        '${directory.path}/locations.db',
        factory: databaseFactoryFfi,
      );
      store = LocationStore(local);
      expect((await store.snapshot()).counts, {SyncStatus.pending: 1});

      repository = TrackingRepository(store, api, clock: () => now);
      await repository.synchronize(() => true);
      await store.save([record]);
      server.failUploads = true;
      await repository.synchronize(() => true);
      expect((await store.snapshot()).counts, {SyncStatus.synced: 1});
      expect(await api.upload(record), isTrue);
      expect(await remote.query('receipts'), hasLength(1));
    },
  );

  test('partial failure backs off and stops after five attempts', () async {
    final accepted = LocationRecord(
      id: 'f868d080-2a97-41f8-8949-714f6f521133',
      latitude: record.latitude,
      longitude: record.longitude,
      timestamp: record.timestamp,
    );
    await api.upload(accepted);
    await store.save([record, accepted]);
    server.failUploads = true;

    for (final seconds in [5, 10, 20, 40]) {
      expect(
        await repository.synchronize(() => true),
        Duration(seconds: seconds),
      );
      expect(
        await repository.synchronize(() => true),
        Duration(seconds: seconds),
      );
      now = now.add(Duration(seconds: seconds));
    }
    expect(await repository.synchronize(() => true), isNull);
    expect((await store.snapshot()).counts, {
      SyncStatus.synced: 1,
      SyncStatus.failed: 1,
    });
    expect(
      (await local.query(
        'locations',
        where: 'id = ?',
        whereArgs: [record.id],
      )).single['retryCount'],
      5,
    );

    server.failUploads = false;
    await store.retryFailed();
    await repository.synchronize(() => true);
    expect((await store.snapshot()).counts, {SyncStatus.synced: 2});
  });

  test('a lost response after acceptance reuses the UUID on retry', () async {
    final transport = api.client;
    final keys = <String?>[];
    final client = MockClient((request) async {
      final response = await _forward(transport, request);
      if (request.method == 'POST') {
        keys.add(request.headers['idempotency-key']);
        if (keys.length == 1) {
          expect(response.statusCode, 201);
          throw http.ClientException(
            'Connection closed before acknowledgement',
          );
        }
        expect(response.statusCode, 200);
      }
      return response;
    });
    addTearDown(client.close);
    final flakyApi = LocationApi(client, api.baseUrl);
    await store.save([record]);
    repository = TrackingRepository(store, flakyApi, clock: () => now);

    expect(
      await repository.synchronize(() => true),
      const Duration(seconds: 5),
    );
    expect((await store.snapshot()).counts, {SyncStatus.pending: 1});
    expect(await remote.query('receipts'), hasLength(1));

    await local.close();
    local = await openLocationDatabase(
      '${directory.path}/locations.db',
      factory: databaseFactoryFfi,
    );
    store = LocationStore(local);
    repository = TrackingRepository(store, flakyApi, clock: () => now);
    now = now.add(const Duration(seconds: 5));

    await repository.synchronize(() => true);
    await repository.synchronize(() => true);
    expect(keys, [record.id, record.id]);
    expect((await store.snapshot()).counts, {SyncStatus.synced: 1});
    expect(await remote.query('receipts'), hasLength(1));
  });

  test('an in-flight sync excludes another pass', () async {
    final enteredUpload = Completer<void>();
    final releaseUpload = Completer<void>();
    var posts = 0;
    final client = MockClient((request) async {
      if (request.method == 'POST') {
        posts++;
        if (!enteredUpload.isCompleted) enteredUpload.complete();
        await releaseUpload.future;
      }
      return _forward(api.client, request);
    });
    addTearDown(client.close);
    repository = TrackingRepository(
      store,
      LocationApi(client, api.baseUrl),
      clock: () => now,
    );
    await store.save([record]);
    final first = repository.synchronize(() => true);
    await enteredUpload.future.timeout(const Duration(seconds: 3));
    final second = repository.synchronize(() => true);
    releaseUpload.complete();

    await Future.wait([first, second]);
    expect(posts, 1);
    expect(await remote.query('receipts'), hasLength(1));
    expect((await store.snapshot()).counts, {SyncStatus.synced: 1});
  });

  test('an unreachable health endpoint preserves the upload budget', () async {
    var posts = 0;
    final client = MockClient((request) async {
      if (request.method == 'POST') posts++;
      return http.Response('unavailable', 503);
    });
    addTearDown(client.close);
    repository = TrackingRepository(
      store,
      LocationApi(client, api.baseUrl),
      clock: () => now,
    );
    await store.save([record]);

    expect(
      await repository.synchronize(() => true),
      const Duration(seconds: 15),
    );
    expect(posts, 0);
    expect((await store.snapshot()).counts, {SyncStatus.pending: 1});
    expect((await local.query('locations')).single['retryCount'], 0);
  });

  testWidgets(
    'repeated start and stop leave no simulation timer on a narrow screen',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 640);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final memory = _MemoryLocationStore(local);
      final cubit = TrackingCubit(
        NativeTracking(),
        TrackingRepository(memory, api),
        server,
        Connectivity(),
      );
      addTearDown(cubit.close);
      await tester.pumpWidget(
        BlocProvider.value(value: cubit, child: const DriverTrackingApp()),
      );
      cubit.setSimulated(true);
      await cubit.start();
      await cubit.start();
      await tester.pump();
      expect(find.text('Tracking active'), findsOneWidget);
      expect(memory.records, hasLength(1));

      await cubit.stop();
      await cubit.stop();
      await tester.pump(const Duration(seconds: 6));
      expect(find.text('Tracking stopped'), findsOneWidget);
      expect(memory.records, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  test('native channel reads and acknowledges stable location IDs', () async {
    const channel = MethodChannel('driver_tracking/methods');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'read' => [record.toPayload()],
        'state' => {'active': true, 'authorized': true},
        _ => null,
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    messenger.setMockStreamHandler(
      const EventChannel('driver_tracking/events'),
      MockStreamHandler.inline(
        onListen: (_, events) =>
            events.success({'location': record.toPayload()}),
      ),
    );

    final native = NativeTracking();
    await native.start();
    expect((await native.events.first)['location'], record.toPayload());
    expect((await native.state())['active'], isTrue);
    final fixes = await native.read();
    expect(fixes.single.toPayload(), record.toPayload());
    await native.acknowledge([fixes.single.id]);
    await native.stop();
    expect(calls.map((call) => call.method), [
      'start',
      'state',
      'read',
      'ack',
      'stop',
    ]);
    expect(calls[3].arguments, [record.id]);
  });
}

class _MemoryLocationStore extends LocationStore {
  _MemoryLocationStore(super.db);

  final records = <LocationRecord>[];

  @override
  Future<void> save(Iterable<LocationRecord> fixes) async =>
      records.addAll(fixes);

  @override
  Future<History> snapshot() async => (
    history: records.reversed.toList(),
    counts: {SyncStatus.pending: records.length},
  );
}

Future<http.Response> _forward(http.Client client, http.Request request) {
  final copy = http.Request(request.method, request.url)
    ..headers.addAll(request.headers)
    ..bodyBytes = request.bodyBytes;
  return client.send(copy).then(http.Response.fromStream);
}

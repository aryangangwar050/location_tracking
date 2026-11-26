import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

import 'core/location_api.dart';
import 'core/location_database.dart';
import 'core/native_tracking.dart';
import 'features/tracking/tracking_cubit.dart';
import 'features/tracking/tracking_dashboard.dart';
import 'features/tracking/tracking_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final directory = await getDatabasesPath();
    final database = await openLocationDatabase(
      '$directory/driver_tracking.db',
    );
    const backend = String.fromEnvironment('TRACKING_API_BASE_URL');
    MockLocationServer? mock;
    if (backend.isEmpty) {
      final mockDb = await openDatabase(
        '$directory/mock_location_server.db',
        version: 1,
        onCreate: (db, _) => db.execute(
          'CREATE TABLE receipts (id TEXT PRIMARY KEY, payload TEXT NOT NULL)',
        ),
      );
      mock = MockLocationServer(mockDb);
    }
    final baseUrl = backend.isEmpty
        ? Uri.https('mock.driver-tracking.invalid', '/')
        : Uri.parse(backend.endsWith('/') ? backend : '$backend/');
    final api = LocationApi(mock?.createClient() ?? http.Client(), baseUrl);
    runApp(
      BlocProvider(
        create: (_) => TrackingCubit(
          NativeTracking(),
          TrackingRepository(LocationStore(database), api),
          mock,
          Connectivity(),
        )..initialize(),
        child: const DriverTrackingApp(),
      ),
    );
  } catch (error) {
    if (kDebugMode) debugPrint('Driver Tracking startup: ${error.runtimeType}');
    runApp(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Text(
              'Could not open local storage. Reopen Driver Tracking to try again.',
            ),
          ),
        ),
      ),
    );
  }
}

class DriverTrackingApp extends StatelessWidget {
  const DriverTrackingApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Driver Tracking',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF075E5B)),
      scaffoldBackgroundColor: const Color(0xFFF3F6F5),
      useMaterial3: true,
    ),
    home: const TrackingDashboard(),
  );
}

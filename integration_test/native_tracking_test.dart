import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:location_tracking/features/tracking/location_record.dart';
import 'package:location_tracking/features/tracking/tracking_cubit.dart';
import 'package:location_tracking/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native GPS fixes persist offline and sync on reconnect',
    (tester) async {
      await app.main();
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(app.DriverTrackingApp));
      final cubit = context.read<TrackingCubit>();
      addTearDown(cubit.stop);
      await _waitFor(
        tester,
        () => cubit.state.network,
        'an active device network before simulating offline mode',
      );
      cubit.setOffline(true);
      final started = DateTime.now();

      await cubit.start();
      await _waitFor(tester, () => cubit.state.gps.active, 'native GPS start');

      LocationRecord? fix;
      await _waitFor(
        tester,
        () {
          fix = cubit.state.data.history
              .where(
                (record) =>
                    !record.simulated &&
                    record.timestamp.isAfter(started) &&
                    record.status == SyncStatus.pending,
              )
              .firstOrNull;
          return fix != null;
        },
        'a fresh pending fix (inject emulator coordinates or move the device)',
      );

      await cubit.stop();
      await _waitFor(tester, () => !cubit.state.gps.active, 'native GPS stop');
      cubit.setOffline(false);
      await _waitFor(
        tester,
        () => cubit.state.data.history.any(
          (record) =>
              record.id == fix!.id && record.status == SyncStatus.synced,
        ),
        'mock API acknowledgement',
      );
      expect(find.text('Driver Tracking'), findsOneWidget);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() isReady,
  String description,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 35));
  while (!isReady() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await tester.pump();
  }
  expect(isReady(), isTrue, reason: description);
}

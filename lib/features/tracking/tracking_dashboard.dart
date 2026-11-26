import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'location_record.dart';
import 'tracking_cubit.dart';

class TrackingDashboard extends StatefulWidget {
  const TrackingDashboard({super.key});

  @override
  State<TrackingDashboard> createState() => _TrackingDashboardState();
}

class _TrackingDashboardState extends State<TrackingDashboard> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    final cubit = context.read<TrackingCubit>();
    _lifecycle = AppLifecycleListener(onResume: cubit.resume);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Driver Tracking')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: CustomScrollView(
            slivers: [
              const SliverPadding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                sliver: SliverToBoxAdapter(child: _Controls()),
              ),
              BlocSelector<TrackingCubit, TrackingState, History>(
                selector: (state) => state.data,
                builder: (context, data) => SliverMainAxisGroup(
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.all(16),
                      sliver: SliverToBoxAdapter(child: _Overview(data: data)),
                    ),
                    if (data.history.isEmpty)
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.symmetric(horizontal: 20),
                          child: Text(
                            'Start tracking to record your first location.',
                          ),
                        ),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        sliver: SliverList.builder(
                          itemCount: data.history.length,
                          itemBuilder: (context, index) {
                            final record = data.history[index];
                            return Card(
                              child: ListTile(
                                title: Text(_coordinates(record)),
                                subtitle: Text(
                                  '${_localTime(context, record.timestamp)} · ${record.simulated ? 'Simulated GPS' : 'Real GPS'}',
                                ),
                                trailing: _Status(record.status),
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _Controls extends StatelessWidget {
  const _Controls();

  @override
  Widget build(
    BuildContext context,
  ) => BlocBuilder<TrackingCubit, TrackingState>(
    buildWhen: (previous, current) =>
        previous.gps != current.gps ||
        previous.simulated != current.simulated ||
        previous.simulationActive != current.simulationActive ||
        previous.busy != current.busy ||
        previous.error != current.error ||
        previous.network != current.network ||
        previous.offline != current.offline ||
        previous.syncing != current.syncing ||
        previous.failUploads != current.failUploads,
    builder: (context, state) {
      final cubit = context.read<TrackingCubit>();
      final active = state.gps.active || state.simulationActive;
      final online = state.network && !state.offline;
      final theme = Theme.of(context);
      return Card(
        color: theme.colorScheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                state.busy
                    ? 'Updating tracking…'
                    : active
                    ? 'Tracking active'
                    : 'Tracking stopped',
                style: theme.textTheme.headlineSmall,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  state.offline
                      ? 'Simulated offline'
                      : online
                      ? state.syncing
                            ? 'Network connected · Syncing'
                            : 'Network connected'
                      : 'No network connection',
                ),
              ),
              LayoutBuilder(
                builder: (context, constraints) => SegmentedButton<bool>(
                  direction:
                      constraints.maxWidth <
                          MediaQuery.textScalerOf(context).scale(260)
                      ? Axis.vertical
                      : Axis.horizontal,
                  segments: const [
                    ButtonSegment(value: false, label: Text('Real GPS')),
                    ButtonSegment(value: true, label: Text('Simulated GPS')),
                  ],
                  selected: {state.simulated},
                  onSelectionChanged: active || state.busy
                      ? null
                      : (selection) => cubit.setSimulated(selection.single),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: active || state.busy ? null : cubit.start,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Start Tracking'),
                  ),
                  OutlinedButton.icon(
                    onPressed: active && !state.busy ? cubit.stop : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop Tracking'),
                  ),
                ],
              ),
              if (state.error.isNotEmpty || state.gps.error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    state.gps.error.isEmpty ? state.error : state.gps.error,
                    style: TextStyle(color: theme.colorScheme.onErrorContainer),
                  ),
                ),
              const SizedBox(height: 4),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Testing controls'),
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Simulate offline'),
                    value: state.offline,
                    onChanged: cubit.setOffline,
                  ),
                  if (cubit.mock != null)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Fail mock uploads'),
                      value: state.failUploads,
                      onChanged: cubit.setFailUploads,
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _Overview extends StatelessWidget {
  const _Overview({required this.data});

  final History data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final latest = data.history.firstOrNull;
    final pending = data.counts[SyncStatus.pending] ?? 0;
    final synced = data.counts[SyncStatus.synced] ?? 0;
    final failed = data.counts[SyncStatus.failed] ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Latest recorded location', style: theme.textTheme.titleMedium),
        Text(
          latest == null ? 'Awaiting location' : _coordinates(latest),
          style: theme.textTheme.headlineSmall,
        ),
        if (latest != null)
          Text(
            '${_localTime(context, latest.timestamp)} · ${latest.simulated ? 'Simulated GPS' : 'Real GPS'}',
          ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Chip(label: Text('${pending + synced + failed} total')),
            Chip(label: Text('$pending pending')),
            Chip(label: Text('$synced synced')),
            if (failed > 0)
              ActionChip(
                label: Text('$failed failed · Retry'),
                onPressed: context.read<TrackingCubit>().retryFailed,
              ),
          ],
        ),
        const SizedBox(height: 16),
        Text('Location history', style: theme.textTheme.titleLarge),
        if (pending + synced + failed > data.history.length)
          Text('Showing the latest ${data.history.length} locations'),
      ],
    );
  }
}

class _Status extends StatelessWidget {
  const _Status(this.status);

  final SyncStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      SyncStatus.synced => ('Synced', Colors.green.shade800),
      SyncStatus.pending => ('Pending', Colors.deepOrange.shade800),
      SyncStatus.failed => ('Failed', Colors.red.shade800),
    };
    return Text(
      label,
      style: TextStyle(color: color, fontWeight: FontWeight.w600),
    );
  }
}

String _coordinates(LocationRecord record) =>
    '${record.latitude.toStringAsFixed(5)}, ${record.longitude.toStringAsFixed(5)}';

String _localTime(BuildContext context, DateTime timestamp) {
  final local = timestamp.toLocal();
  final format = MaterialLocalizations.of(context);
  return '${format.formatShortDate(local)} ${format.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
}

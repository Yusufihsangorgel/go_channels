import 'dart:async';

import 'package:go_channels/go_channels.dart';

/// Fan-out / fan-in: one producer feeds a pool of workers over a [Channel], and
/// their results fan back in over another, the pattern Go's channels and
/// `select` make trivial, here in plain Dart.
///
/// Run with: `dart run example/go_channels_example.dart`
Future<void> main() async {
  final jobs = Channel<int>(); // producer -> workers
  final results = Channel<int>(); // workers -> collector

  // Fan-out: a scope of four workers, each draining `jobs` until it closes.
  // The scope guarantees no worker outlives this pipeline.
  final workers = withTaskScope((scope) async {
    for (var w = 0; w < 4; w++) {
      scope.spawn((_) async {
        await for (final n in jobs.stream) {
          await results.send(n * n); // stand-in for expensive work
        }
      });
    }
  });

  // Produce ten jobs, then close so the workers drain and finish.
  final produce = () async {
    for (var i = 1; i <= 10; i++) {
      await jobs.send(i);
    }
    jobs.close();
  }();

  // Fan-in: collect ten results, using `select` so a stall becomes a timeout
  // rather than a hang.
  final squares = <int>[];
  while (squares.length < 10) {
    await select<void>((s) {
      s.onReceive(results, (value, ok) {
        if (ok) squares.add(value!);
      });
      s.onTimeout(const Duration(seconds: 5), () {
        throw TimeoutException('workers stalled');
      });
    });
  }

  await produce;
  await workers;
  results.close();

  squares.sort();
  print('squares: $squares');
}

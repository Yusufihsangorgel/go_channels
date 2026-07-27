// What does buffer capacity actually buy, and what does `select` cost?
//
// Every case moves the same number of values through a channel from one task
// to another, so the numbers are comparable. Run with:
//   dart run benchmark/capacity_benchmark.dart
import 'dart:async';

import 'package:go_channels/go_channels.dart';

const _n = 200000;

/// Sends [_n] values through [ch] from one task while another drains it, and
/// returns how long the whole exchange took.
Future<Duration> _pump(Channel<int> ch, {bool viaSelect = false}) async {
  final sw = Stopwatch()..start();

  final producer = () async {
    for (var i = 0; i < _n; i++) {
      await ch.send(i);
    }
    ch.close();
  }();

  var received = 0;
  if (viaSelect) {
    // The same drain, but each value is taken through a select with two
    // branches, which is what a real worker waiting on work-or-shutdown does.
    final quit = Channel<void>();
    var open = true;
    while (open) {
      await select<void>((s) {
        s.onReceive(ch, (value, ok) {
          if (!ok) {
            open = false;
          } else {
            received++;
          }
        });
        s.onReceive(quit, (_, __) => open = false);
      });
    }
  } else {
    // receiveOr, not ch.stream: the stream wraps every value in a
    // StreamController event, so draining through it would measure Dart's
    // stream machinery rather than the channel, and would not be comparable
    // to the select case below.
    while (true) {
      final (_, ok) = await ch.receiveOr();
      if (!ok) break;
      received++;
    }
  }

  await producer;
  sw.stop();
  if (received != _n) {
    throw StateError(
        'received $received of $_n — the cases are not comparable');
  }
  return sw.elapsed;
}

String _rate(Duration d) =>
    '${(_n / d.inMicroseconds).toStringAsFixed(2)} M/sec';

Future<void> main() async {
  // Warm the JIT so the first case is not paying for everyone else.
  await _pump(Channel<int>(capacity: 16));

  final rows = <String, Duration>{};
  rows['unbuffered (rendezvous)'] = await _pump(Channel<int>());
  for (final cap in [1, 16, 256, 4096]) {
    rows['buffered, capacity $cap'] = await _pump(Channel<int>(capacity: cap));
  }
  rows['buffered 256, drained via select'] =
      await _pump(Channel<int>(capacity: 256), viaSelect: true);

  print('$_n values through one channel, sender and receiver on one isolate\n');
  for (final e in rows.entries) {
    print(
        '${e.key.padRight(34)} ${e.value.inMilliseconds.toString().padLeft(5)} ms   ${_rate(e.value)}');
  }

  final unbuf = rows['unbuffered (rendezvous)']!.inMicroseconds;
  final buf256 = rows['buffered, capacity 256']!.inMicroseconds;
  print(
      '\nbuffering 256 is ${(unbuf / buf256).toStringAsFixed(1)}x the throughput of a rendezvous');
  final plain = rows['buffered, capacity 256']!.inMicroseconds;
  final sel = rows['buffered 256, drained via select']!.inMicroseconds;
  print(
      'select costs ${(sel / plain).toStringAsFixed(1)}x a plain receive on the same channel');
}

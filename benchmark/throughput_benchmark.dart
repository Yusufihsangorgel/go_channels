import 'package:go_channels/go_channels.dart';

/// Measures raw coordination throughput: how many `send`/`receive` round-trips
/// an unbuffered-ish [Channel] sustains per second on a single isolate.
///
/// This is a single-isolate coordination primitive, so this is a measure of
/// per-message overhead, not of parallel speed-up. Run with:
/// `dart run benchmark/throughput_benchmark.dart`
Future<void> main() async {
  const messages = 1000000;
  final channel = Channel<int>(capacity: 1024);

  final consumer = () async {
    var sum = 0;
    for (var i = 0; i < messages; i++) {
      sum += await channel.receive();
    }
    return sum;
  }();

  final stopwatch = Stopwatch()..start();
  for (var i = 0; i < messages; i++) {
    await channel.send(i);
  }
  await consumer;
  stopwatch.stop();

  final perSecond = messages / stopwatch.elapsedMicroseconds * 1e6;
  print('$messages round-trips in ${stopwatch.elapsedMilliseconds} ms '
      '(${(perSecond / 1e6).toStringAsFixed(1)}M/sec)');
}

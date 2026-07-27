# go_channels example

`go_channels_example.dart` is the fan-out / fan-in pattern: one producer feeds a
pool of four workers over a `Channel`, and their results fan back in over
another. A `withTaskScope` guarantees no worker outlives the pipeline, and the
collector uses `select` so a stalled worker becomes a timeout rather than a
hang — the shape Go's channels and `select` make routine, here in plain Dart on
one isolate.

```dart
final jobs = Channel<int>();      // producer -> workers
final results = Channel<int>();   // workers -> collector

// Four workers, each draining jobs until it closes; the scope owns them.
final workers = withTaskScope((scope) async {
  for (var w = 0; w < 4; w++) {
    scope.spawn((_) async {
      await for (final n in jobs.stream) {
        await results.send(n * n);
      }
    });
  }
});

// Collect with select, so a stall times out instead of hanging.
await select<void>((s) {
  s.onReceive(results, (value, ok) { if (ok) squares.add(value!); });
  s.onTimeout(const Duration(seconds: 5), () => throw TimeoutException('stalled'));
});
```

Run it:

```
dart run example/go_channels_example.dart
```

Output:

```
squares: [1, 4, 9, 16, 25, 36, 49, 64, 81, 100]
```

For what buffer capacity does and does not buy on one isolate, and the cost of
`select`, see the benchmark chart in the package README.

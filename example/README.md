# go_channels examples

Two runnable files: `go_channels_example.dart` builds a pipeline,
`select_multiway.dart` isolates the one primitive `dart:async` has no answer for.

## go_channels_example.dart — fan-out / fan-in

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

## select_multiway.dart — waiting on two channels, and what happens to the loser

The pipeline above uses `select` as a stall guard: one channel plus a deadline.
`select_multiway.dart` takes the primitive on its own and measures the part that
makes it worth having — a genuine multi-way choice, and the fate of the branches
that did not win.

It runs four scenes, each on a fresh pair of channels:

1. **Two branches ready, one wins.** The losing branch never ran, so its value is
   still in its channel and the next receiver gets it.
2. **The same race with `Future.any`.** Both `receive()` calls have already taken
   their value before `Future.any` looks, so the loser's value goes to a future
   nobody awaits. It is destroyed, both sends report success, and nothing throws.
3. **Nobody ready, the deadline wins.** Five rounds of each spelling, side by
   side. `select` withdraws every branch it parked, so `waiters` stays at zero;
   the `Future.any` loop leaves two dead receivers behind per round and they
   accumulate.
4. **Ties.** 2000 rounds with both branches ready, to show the pick is random and
   declaration order is not priority.

```
dart run example/select_multiway.dart
```

Output (which branch wins in scenes 1 and 4 varies by design):

```
armed: a.waiters=1, b.waiters=1
  won: a=1  ->  a: empty, b: still holds 2
  exactly one channel was drained; the loser kept its value

Future.any won: a=1  ->  a: empty, b: empty
  both senders saw a successful send, yet one value reached nobody

idle select -> deadline
  after 5 select rounds:     a.waiters=0, b.waiters=0
  after 5 Future.any rounds: c.waiters=5, d.waiters=5  <- one per round, each

ties over 2000 rounds: a won 973, b won 1027
  order of declaration is not priority — do not encode it as such
```

For what buffer capacity does and does not buy on one isolate, and the cost of
`select`, see the benchmark chart in the package README.

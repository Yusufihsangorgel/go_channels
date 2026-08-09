# go_channels examples

Three runnable files: `go_channels_example.dart` builds a pipeline,
`select_multiway.dart` isolates the one primitive `dart:async` has no answer for,
and `cancellation.dart` measures what cancelling a task actually achieves.

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

## cancellation.dart — a scope losing a task, and a deadline nobody watches

Cancellation in Dart is cooperative because it has to be: nothing can kill a
running future from outside, and a scope can only raise a flag and wait for its
tasks to notice. `cancellation.dart` measures what that buys and where it stops.

Three scenes:

1. Three workers of six steps each, then the same scope again with worker 1
   throwing on step 3. `withTaskScope` cancels the token, waits for every task
   anyway, and rethrows the first error. The run where nobody fails is what
   makes the shortened counts readable.
2. Two tasks, each with a 25 ms deadline over 100 ms of work. The one calling
   `throwIfCancelled` between chunks gives up three chunks in. The one that
   never reads its token runs all ten chunks and returns a value, with no error
   anywhere.
3. A worker parked in `select`, waiting on work-or-shutdown. Every branch is a
   channel operation and a token is not one of those, which the scene works
   around by closing a channel when the token is cancelled. Polling
   `isCancelled` is no help to a parked task, which runs no code.

```
dart run example/cancellation.dart
```

Output (the millisecond figures move a few ms between runs; the counts do not):

```
nobody fails:    steps completed [6, 6, 6]
worker 1 throws: steps completed [4, 2, 3]
  the scope rethrew: Bad state: worker 1 failed on step 3
  worker 1 threw on step 3, which is why its count stops at 2
  the other two ran to their next check and stopped there; neither reaches 6

deadline 25 ms over 100 ms of work
  checks the token: gave up after 3 chunks (39ms)
    reason: TimeoutException after 0:00:00.025000: withTimeout elapsed
  ignores it:       ran all 10 chunks (127ms)
  the second one outlived its deadline and nothing complained

after 3 jobs: worker parked in select, jobs.waiters=1, shutdown.waiters=1
  worker handled 3 jobs, then left on: operator asked to stop
  cancelling a scope token is not a failure; this scope returned normally
```

The counts in scene 1 are the point of it. A sibling does not stop the instant
its token flips; it stops at its next check, and worker 0 had just passed one.

For what buffer capacity does and does not buy on one isolate, and the cost of
`select`, see the benchmark chart in the package README.

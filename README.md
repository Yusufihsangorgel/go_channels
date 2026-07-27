# go_channels

Go-style concurrency for Dart: typed channels, a faithful `select` over many
channel operations, and structured task scopes with cooperative cancellation.

Dart's `dart:async` gives you futures and streams, but not the primitives Go
and Kotlin developers reach for: a typed channel, a `select` that waits on
several operations at once, or a scope where one task's failure cancels its
siblings. `go_channels` adds those, in plain Dart, on a single isolate.

```dart
import 'package:go_channels/go_channels.dart';

final ch = Channel<int>(capacity: 1);
await ch.send(1);
print(await ch.receive()); // 1
```

## Channels

A `Channel<T>` passes values between asynchronous tasks. Unbuffered channels
(the default) rendezvous: a `send` completes only when a receiver takes the
value. Buffered channels hold up to `capacity` values before a `send` blocks.

The whole distinction is *when `send` completes*, which is what decides whether
the sender feels backpressure the instant the receiver stalls:

![On the left, an unbuffered channel: send waits until receive takes the value, so send completes at the moment of receive — a rendezvous. On the right, a buffered channel with capacity 2: send(1) and send(2) return at once because the buffer has room, and send(3) waits only once the buffer is full.](https://raw.githubusercontent.com/Yusufihsangorgel/go_channels/main/doc/buffered-vs-unbuffered.png)

```dart
final jobs = Channel<String>();              // unbuffered
final queue = Channel<String>(capacity: 32); // buffered

await for (final job in jobs.stream) {        // ranges until the channel closes
  handle(job);
}
```

Closing a channel lets receivers drain what is left, then observe closure.
`receiveOr` mirrors Go's `v, ok := <-ch`:

```dart
final (value, ok) = await ch.receiveOr();
if (!ok) print('channel closed');
```

## select

`select` waits on several channel operations and runs exactly one, like Go's
`select`. If more than one branch is ready, it picks one at random for fairness.

```dart
final label = await select<String>((s) {
  s.onReceive(jobs, (job, ok) => ok ? 'job: $job' : 'jobs closed');
  s.onSend(results, 42, () => 'sent a result');
  s.onTimeout(const Duration(seconds: 1), () => 'timed out');
});
```

Add `onDefault` to make the whole `select` non-blocking:

```dart
await select<void>((s) {
  s.onReceive(events, (e, ok) => handle(e));
  s.onDefault(() {}); // returns immediately if nothing is ready
});
```

## Structured task scopes

`withTaskScope` runs a group of tasks and returns only once all of them finish.
If any task fails, the scope's token is cancelled so the siblings can stop, and
the first error is rethrown. Nothing spawned inside outlives the scope.

```dart
final results = await withTaskScope((scope) async {
  final a = scope.spawn((_) => fetchA());
  final b = scope.spawn((_) => fetchB());
  return [await a, await b];
});
```

`waitAll` is the common case in one call:

```dart
final pages = await waitAll([
  (_) => fetch('/a'),
  (_) => fetch('/b'),
  (_) => fetch('/c'),
]);
```

## Cancellation

Dart futures cannot be forcibly killed, so cancellation is cooperative: a task
observes its `CancelToken` and stops itself. Check `isCancelled`, call
`throwIfCancelled`, or await `whenCancelled` inside a `select`.

```dart
await withTimeout(const Duration(seconds: 5), (token) async {
  while (!token.isCancelled) {
    await doOneChunk();
  }
});
```

## A note on parallelism

`go_channels` coordinates asynchronous tasks on one isolate. It does not add
parallelism by itself: use it to structure concurrent work, and combine it with
isolates when you need more than one core.

## Choosing a capacity

The obvious reason to buffer a channel is speed, and on one isolate that turns
out not to be the reason. Pushing 200,000 values from one task to another,
every buffered size lands within a few percent of every other, about 10% above
the unbuffered rendezvous:

![Bar chart of throughput in millions of values per second. Unbuffered rendezvous 2.32; capacity 1 gives 2.70; capacity 16 gives 2.55; capacity 256 gives 2.60; capacity 4096 gives 2.59; capacity 256 drained through select gives 2.90. Every buffered size is within a few percent of the others and about ten percent above the rendezvous.](https://raw.githubusercontent.com/Yusufihsangorgel/go_channels/main/doc/capacity-throughput.png)

A waiting rendezvous does not block the isolate. With a `send` outstanding and
no receiver in sight, a 1 ms periodic timer still fired 20 times in 20 ms, so
there is no stalled thread for a buffer to buy back the way there would be with
OS threads.

What capacity actually decides is **when a producer feels backpressure**:
unbuffered, `send` waits for a receiver, so a slow consumer throttles the
producer immediately; buffered, the producer runs ahead until the buffer fills.
Pick it for that, not for throughput.

Draining through `select` is not a slow path either — measured on the same
channel it came out slightly *faster* than a direct `receive`, so a worker that
waits on work-or-shutdown pays nothing for the extra branch.

Numbers from `benchmark/capacity_benchmark.dart` on an Apple M-series core,
stable across runs; `benchmark/throughput_benchmark.dart` measures the raw
round-trip rate separately.

Dart is landing shared-memory multithreading (`Isolate.runShared`, tracked in
[dart-lang/sdk#56841](https://github.com/dart-lang/sdk/issues/56841)). As that
stabilizes, `go_channels` will offer a shared-memory execution path behind a
capability check, so the same channel and `select` code can run across threads.

## Status

Stable at 1.0.0. The surface is small and follows Go's, so it is unlikely to
need reshaping; every public type is `final`, which leaves room to add to the
package (the shared-memory path above, for one) without breaking callers.
Issues and feedback are welcome.

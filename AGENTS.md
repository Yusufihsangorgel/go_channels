# go_channels

`go_channels` is a typed `Channel`, a `select` that waits on several send/receive operations and runs exactly one, and a `withTaskScope` that cancels siblings on the first failure. It coordinates asynchronous tasks on one isolate: operations are race-free without locks, and it does not add parallelism — CPU-bound work here shares the event loop and starves everyone else; use `Isolate` for that.

Reach for `Stream` / `Future` instead when one producer and `listen` or `await for` already model the problem. Reaching for `Channel` by default makes ordinary Dart concurrency less idiomatic. Use this package when a producer must not commit a value if a timeout or cancel branch wins, when you need send-side `select`, or when one failure should cancel siblings without a hand-rolled `Completer`.

## Usage

From `example/select_multiway.dart`. `capacity: 1` so each `send` completes without a waiting receiver:

```dart
import 'package:go_channels/go_channels.dart';

Future<void> main() async {
  final a = Channel<int>(capacity: 1);
  final b = Channel<int>(capacity: 1);
  await a.send(1);
  await b.send(2);
  final winner = await select<String>((s) {
    s.onReceive(a, (value, ok) => 'a=$value');
    s.onReceive(b, (value, ok) => 'b=$value');
  });
  print(winner); // 'a=1' or 'b=2'; ties are random
}
```

The producer/worker pipeline is `example/go_channels_example.dart`: unbuffered channels, workers under `withTaskScope` ranging `Channel.stream`, collector `select` with `onTimeout`. That terminates only because send and receive run in different tasks and collection runs concurrently with production.

## Contracts

**`Channel.send` / `Channel.capacity`.** Default `capacity` is 0 (unbuffered): `send` completes only when a receiver takes the value (rendezvous). With `capacity > 0`, `send` completes while `Channel.length < capacity` and stays pending once the buffer is full. A pending send or receive does not stop the isolate event loop.

**`Channel.close`.** Buffered values remain receivable. A later `send` throws `StateError` immediately. A send already pending fails its Future with `StateError`. Pending receivers complete: `receiveOr` yields `(null, false)`, `receive` throws `ChannelClosedError`. Closing twice throws `StateError`. A closed empty channel is a ready `select` receive (`ok == false`), not a stall.

**Detecting closure.** `Channel.receiveOr` returns `(T?, bool)` — `(null, false)` when closed and drained. `Channel.stream` ends. `Channel.isClosed` is true after `close` even while values remain to drain. `receive` throws `ChannelClosedError` only when closed and empty.

**`select` / `SelectCases`.** Exactly one branch runs. Losing branches are withdrawn from the channel queues (`Channel.waiters` returns to 0) and do not consume a value. `SelectCases.onSend` does not put the value in the channel unless that branch wins. If several branches are ready, one is chosen at random; declaration order is not priority. `SelectCases.onDefault` makes the call non-blocking. `SelectCases.onTimeout` runs only if no other branch becomes ready in time.

**`withTaskScope` / `TaskScope.spawn` / `CancelToken`.** If the body or any spawned task fails, `TaskScope.token` is cancelled, every spawned task is awaited, then the first error is rethrown. Cancellation is cooperative: `CancelToken.isCancelled`, `throwIfCancelled` (throws `CancelledException`), `whenCancelled`. A child token is cancelled with its parent. Calling `CancelToken.cancel` does not by itself fail the scope; a task that reacts with `throwIfCancelled` throws `CancelledException`, and that does. `waitAll` is fail-fast fan-out. `withTimeout` cancels its token after `duration` and still waits for the task; ignoring the token is not a failure.

## Mistakes

**Deadlock** (a Future never completes; timers still fire):

1. Same-task rendezvous. `await ch.send(x)` then `await ch.receive()` on `capacity == 0`, or a second `send` on a full buffer, in one task. The send waits for a receiver that starts after it. Fix: `capacity >= 1` for sequential use, or send and receive from different tasks.
2. Cyclic rendezvous. Two tasks each `send` on an unbuffered channel before `receive` on the other. Fix: buffer one side, receive first, or `select`.
3. Unclosed range. `await for` on `Channel.stream` while the producer never calls `close`. Workers never finish; `withTaskScope` never returns. Fix: the producer closes after the last send.
4. Parked sibling. A task blocked on `receive` / `select` with no shutdown branch. Another spawn fails, the token is cancelled, `withTaskScope` still awaits the parked task. Fix: close a side channel from `token.whenCancelled` and `onReceive` it (`example/cancellation.dart`). Polling `isCancelled` does not run while parked. Same hang: `withTimeout` around a parked task that never inspects the token; or `await`ing work in the scope body that only a not-yet-spawned sibling can complete.
5. `select` with nothing ready and no `onTimeout` / `onDefault`. Fix: add one.

**`Future.any([a.receive(), b.receive()])`.** Both receives take a value; the loser is discarded; both sends succeed. Symptom: missing values; idle races leave `waiters` behind. Fix: `select`.

**`receive` to detect close.** Symptom: `ChannelClosedError`. Fix: `receiveOr` or `stream`.

**Multiple `Channel.stream` consumers.** Each `stream` access is a new `receiveOr` loop on the same channel. Workers share values (fan-out); they do not each get a copy.

**Ignoring `CancelToken`.** Symptom: work continues past a deadline; `withTimeout` returns normally. Fix: observe the token. `select` cannot wait on a token; bridge it with a channel `close`.

**Branch order as priority.** Ties are random. Do not encode priority as declaration order.

**Second `close`, or `send` after close.** `StateError`. Close once, from the producer, after the last send.

## Layout

- `lib/go_channels.dart` — public exports. Implementation: `lib/src/channel.dart`, `lib/src/scope.dart`.
- `test/channel_test.dart`, `test/contract_test.dart` (frozen close / `select` / scope contracts), `test/scope_test.dart`.
- `example/` — `go_channels_example.dart`, `select_multiway.dart`, `cancellation.dart`.
- `benchmark/capacity_benchmark.dart`, `benchmark/throughput_benchmark.dart`.

```
dart analyze
dart test
dart run benchmark/capacity_benchmark.dart
dart run benchmark/throughput_benchmark.dart
```

Do not change close, `select` withdrawal, or scope fail-fast behaviour without updating `test/contract_test.dart`.

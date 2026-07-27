## 1.0.0

The API is stable. No behaviour changes; this freezes the surface after an
adversarial pass over the three primitives, and pins what it found as tests.

Verified by execution and now covered by `test/contract_test.dart` — mostly the
cases that deadlock when they are wrong:

- **Channels.** Sending on a closed channel throws, as does closing twice.
  `receive` on a closed and drained channel throws `ChannelClosedError`, while
  `receiveOr` reports closure instead. Values already buffered still drain after
  a close, so closing loses nothing. A receive that is already waiting completes
  (with `ok: false`) when the channel closes rather than hanging, and a waiting
  send fails rather than hanging.
- **select.** `onDefault` makes it non-blocking; a closed channel counts as a
  ready receive rather than stalling the select; and when several branches are
  ready it picks at random, which the test pins statistically — a
  first-ready-wins implementation would fail it.
- **Task scopes.** A failing task cancels its siblings' tokens and the first
  error is rethrown from the scope; `withTimeout` cancels the token it hands out.

The status note in the README, which still claimed 0.1.0, now says what freezing
means here: every public type is `final`, so the planned shared-memory execution
path can be added without breaking callers. No runtime dependencies.

## 0.2.2

- Add `example/README.md` for pub.dev's Example tab (it was empty). It walks
  through the fan-out/fan-in example — a producer, a scope of four workers, and
  a `select`-based collector — with the real output. Also fixes the stale run
  command in the example's doc comment. Docs only.

## 0.2.1

- Add `benchmark/capacity_benchmark.dart` and document what buffer capacity
  actually buys. Moving 200,000 values from one task to another, every buffered
  size (1, 16, 256, 4096) lands within a few percent of every other and about
  10% above the unbuffered rendezvous, and draining through `select` measured
  slightly faster than a direct `receive`. Capacity is a backpressure decision,
  not a throughput one, and the README now says so with the chart.

  Two things the benchmark had to get right to be worth reading: the plain case
  drains with `receiveOr` rather than `ch.stream`, because the stream wraps
  every value in a `StreamController` event and would have measured Dart's
  stream machinery instead of the channel; and every case asserts it moved all
  200,000 values, so the rows are comparable. The claim that a waiting
  rendezvous does not block the isolate is measured too — a 1 ms timer fires 20
  times in 20 ms with a `send` outstanding.

## 0.2.0

- Seal the public types. `Channel`, `SelectCases`, `TaskScope`, `CancelToken`,
  `ChannelClosedError` and `CancelledException` are now `final`. None is meant
  to be subtyped — a channel's guarantees come from its implementation, not
  from an interface — and doing this now, while the package is young, keeps
  every future field from being a breaking change for a subclasser later.
  Nothing in the package, its tests, its example or its benchmark subtypes any
  of them. No behaviour change.

## 0.1.1

First pub.dev release. The package was developed under the name `channels`,
which pub.dev rejects as too similar to the existing `channel` package, so it
is published as `go_channels`. The import is
`package:go_channels/go_channels.dart`; the API is unchanged.

- Add a diagram to the README, and declare it as a pub.dev screenshot, showing
  the one thing that separates an unbuffered channel from a buffered one: when
  `send` completes. Unbuffered rendezvous — `send` finishes at the receive;
  buffered lets `send` return while the buffer has room, and blocks only when
  it is full.

## 0.1.0

- Initial release.
- `Channel<T>`: buffered and unbuffered channels with `send`, `receive`,
  `receiveOr` (Go-style `value, ok`), a `stream` view, and `close`.
- `select`: waits on several channel receives/sends at once and runs exactly
  one, with `onDefault` (non-blocking) and `onTimeout` branches; random choice
  among ready branches for fairness.
- Structured concurrency: `withTaskScope` and `waitAll` run a group of tasks
  fail-fast, `CancelToken` provides cooperative cancellation, and `withTimeout`
  cancels on a deadline.

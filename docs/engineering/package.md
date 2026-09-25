# Package engineering rules: go_channels

Rules-Version: go_channels/759c564c41879243bb7496f36382aa5e7474ee77182c4ec9708416c4b77f5bf0
Core-Version: 1
Core-Digest: 1825fa7ff346dca23e65b1b3bf9b2e3e06959f1414bae9952d596d2f62f09b8f
Survey-Digest: f90f45c8a172068c3ed3b9488ba5a7cb4e58efa93c380d2d9a70b399349ec35e
Evidence-Revision: f1f9059
Verified-Revision: unverified

Read CONTRIBUTING.md and docs/engineering/debt.json before editing.

## Current architecture
HEAD f1f9059 (2026-09-22), v1.1.1, sdk ^3.6.0 (short formatter style), zero runtime dependencies. Two independent modules on a single-isolate event loop: channel.dart (CSP `Channel<T>`: buffer + receiver/sender waiter queues; `select` is built on a one-shot shared `_Claimer` and reaches the channel's internal methods from the same file through library privacy) and scope.dart (cooperative cancellation `CancelToken` + parent propagation, structured concurrency `TaskScope`/`withTaskScope`, `waitAll`, `withTimeout`). No platform-conditional code; CI runs on VM, dart2js, and dart2wasm. Behavior is pinned as a 'frozen 1.0.0 contract' in test/contract_test.dart. Two files, ~580 lines: no layer should be forced.

## Layers and responsibilities
- lib/go_channels.dart: Explicit `show` lists (lines 5-13).
- lib/src/channel.dart: `Channel<T>`, `ChannelClosedError`, `SelectCases<R>`, `select<R>`; private `_Claimer`, `_RecvWaiter`, `_SendWaiter`, `_Case`/`_ReceiveCase`/`_SendCase`; internal methods the channel opens to select (150-240).
- lib/src/scope.dart: `CancelToken` (parent propagation), `CancelledException`, `TaskScope` (spawn/drain/fail-fast), `withTaskScope`, `waitAll`, `withTimeout`.
- benchmark/, example/: Throughput/capacity measurement; examples that produce the README output (CI runs both).

## Public API and dependency direction
`Channel`, `ChannelClosedError`, `SelectCases`, `select` (lib/go_channels.dart:5); `CancelToken`, `CancelledException`, `TaskScope`, `withTaskScope`, `waitAll`, `withTimeout` (6-13). `SelectCases._`, `TaskScope._` are private; `CancelToken()` is a public factory → private `_` constructor (the parent parameter is internal only). Go counterparts: `receiveOr` `(T?, bool)` record, closed-channel semantics, random choice among ready branches.

channel.dart and scope.dart do not import each other. channel.dart → dart:async, dart:collection, dart:math; scope.dart → dart:async. The select ↔ Channel link is library-internal (private `_trySendNow`, `_tryReceiveNow`, `_canReceiveNow`, `_canSendNow`, `_addSelectReceive`, `_addSelectSend`). Tests, examples, benchmark depend only on the barrel. No cycles.

## Error, state and platform contracts
- Select branches share a one-shot `_Claimer`; losing waiters are lazily skipped and withdrawn when the select ends (channel.dart:12-24, 152-168, 220-240, 391-408).
- Misuse raises `StateError` (send on closed, close twice: channel.dart:138, 146, 153); `ChannelClosedError extends StateError` (8-10); cancellation is `CancelledException` (scope.dart:4-13).
- Private constructors + factory functions (`TaskScope._`, `SelectCases._`, `CancelToken._`).
- `Future.sync` to route synchronous throws into the future (scope.dart:82, 164; channel.dart:377, 381, 387); sync Completer (scope.dart:36).
- Streaming: `Channel.stream` ends at closure via async* (channel.dart:125-133).
- Cancellation is cooperative; no forced-stop claim (scope.dart:15-20, 148-152).
- Randomness is a global private `Random` (channel.dart:355), not injectable; the test verifies it with a statistical bound (contract_test.dart:84-103).
- Argument validation is assert only (channel.dart:66).
- No FFI, no platform checks, multi-platform CI (VM + dart2js + dart2wasm).
- Short dartdoc; a marker comment 'internals shared with select' for the select internal methods (channel.dart:150).

## Package rules
### go_channels/GOC-1 [MUST]
Keep lib platform-neutral. Import only `dart:async`, `dart:collection` and `dart:math`: no `dart:io`, `dart:isolate` or `dart:html`, and no conditional imports. CI runs the suite on the VM, dart2js and dart2wasm.
Reason: The CI comment says 'there is no platform-conditional code in the library, the difference is a real behavior difference'; the three compiler targets rest on this assumption.
Evidence: .github/workflows/ci.yaml (Test on Chrome dart2js/dart2wasm steps and comment); lib/src/channel.dart:1-3; lib/src/scope.dart:1
Evidence role: current-pattern
Existing violation: none

### go_channels/GOC-2 [MUST_NOT]
Do not change a behavior pinned by test/contract_test.dart outside a major version. New Go-parity behavior gets its own contract test.
Reason: The file defines these behaviors as the frozen 1.0.0 contract and as behaviors that lock in when they are wrong.
Evidence: test/contract_test.dart:6-7, 9-138
Evidence role: current-pattern
Existing violation: none

### go_channels/GOC-3 [MUST]
Keep the Channel internals used by `select` library-private in lib/src/channel.dart. Do not make them public or move `select` into another library.
Reason: select reaches the channel queues through library privacy; separating it would either make internal state public or break compilation.
Evidence: lib/src/channel.dart:150, 204-240, 263-316, 370-410
Evidence role: current-pattern
Existing violation: none

### go_channels/GOC-4 [MUST]
A select branch claims the shared `_Claimer` before it delivers, and every waiter a select registers is withdrawn when the select completes.
Reason: Exactly one branch running, and the losing waiter not staying in a queue, is select's correctness requirement.
Evidence: lib/src/channel.dart:12-24, 152-168, 220-240, 391-408
Evidence role: current-pattern
Existing violation: none

### go_channels/GOC-5 [MUST]
Report misuse (send on a closed channel, closing twice) as `StateError`, receive on a closed and drained channel as `ChannelClosedError`, and cancellation as `CancelledException`. Do not add new exception types for these conditions.
Reason: Error types are pinned in contract tests (throwsStateError, isA<ChannelClosedError>).
Evidence: lib/src/channel.dart:8-10, 138, 146, 153; lib/src/scope.dart:4-13, 47-50; test/contract_test.dart:10-23
Evidence role: current-pattern
Existing violation: none

### go_channels/GOC-6 [MUST]
Keep cancellation cooperative. No API may claim to stop a running future; the dartdoc tells the task to observe its token.
Reason: Dart futures cannot be forcibly stopped; the package documents this honestly.
Evidence: lib/src/scope.dart:15-20, 148-152
Evidence role: current-pattern
Existing violation: none

### go_channels/GOC-7 [MUST]
Bound every wait in an async test with `.timeout(...)` to turn a deadlock into a failure instead of a hung run.
Reason: Most channel errors appear as deadlocks; the current contract tests use this pattern.
Evidence: test/contract_test.dart:46, 57, 70, 80, 121, 135
Evidence role: current-pattern
Existing violation: none

### go_channels/GOC-8 [MUST]
Keep example output in step with the README. CI runs example/go_channels_example.dart and example/select_multiway.dart.
Reason: The README quotes the output of these programs; analysis alone cannot catch an example that compiles but prints something different (CI comment).
Evidence: .github/workflows/ci.yaml 'Run examples' step
Evidence role: current-pattern
Existing violation: none

### go_channels/GOC-9 [SHOULD]
Keep zero runtime dependencies.
Reason: There is no dependencies entry in the pubspec; the core concurrency primitives were written without adding dependencies.
Evidence: pubspec.yaml (only dev_dependencies)
Evidence role: current-pattern
Existing violation: none

### go_channels/GOC-10 [SHOULD]
Validate public arguments with `ArgumentError`, not only `assert`, since asserts are gone in release builds.
Reason: Today capacity is checked only with an assert (debt GOC-B4); sibling packages use ArgumentError.
Evidence: lib/src/channel.dart:64-66
Evidence role: counterexample
Existing violation: go_channels-D004

## Required verification
- Working directory: repository root; command: dart pub get; conditions: ci.yaml job build; evidence: .github/workflows/ci.yaml:22.
- Working directory: repository root; command: dart format --output=none --set-exit-if-changed .; conditions: ci.yaml job build; evidence: .github/workflows/ci.yaml:24.
- Working directory: repository root; command: dart analyze --fatal-infos; conditions: ci.yaml job build; evidence: .github/workflows/ci.yaml:26.
- Working directory: repository root; command: dart test; conditions: ci.yaml job build; evidence: .github/workflows/ci.yaml:28.
- Working directory: repository root; command: dart run example/go_channels_example.dart; conditions: ci.yaml job build; evidence: .github/workflows/ci.yaml:35.
- Working directory: repository root; command: dart run example/select_multiway.dart; conditions: ci.yaml job build; evidence: .github/workflows/ci.yaml:36.
- Working directory: repository root; command: dart test -p chrome; conditions: ci.yaml job build; evidence: .github/workflows/ci.yaml:43.
- Working directory: repository root; command: dart test -p chrome -c dart2wasm; conditions: ci.yaml job build; evidence: .github/workflows/ci.yaml:46.
Not verified by the survey:
- I did not run `dart analyze` and `dart test` (read-only); GOC-B1 uncaught error and GOC-B2 memory growth are from reading, not run or measured.
- example/ (3 files, 410 lines) and benchmark/ (2 files, 131 lines) content was not read.
- The name of the test at scope_test.dart:63 and the scope_test bodies were not read; only test lines were grepped (no parent-token test).
- There is an untracked `~/` directory tree at the repository root (.dart, .dart-tool, .pub-cache, Documents, Library, flutter; 2026-08-29 16:21). git status is clean, the leaves are most likely empty; it looks like the residue of a run made with a literal '~' against HOME. I did not descend into it.
- README.md and AGENTS.md content was not read; AGENTS.md headings: Usage, Contracts, Mistakes, Layout (77 lines).
- GitHub Actions latest run result and pub.dev score (network not permitted).
- Whether the shared detectors (kod-kapisi.py) run on this package: the filter depends on the dart_mcp path (dart-kod-kurallari.md:130-133); I did not open the script.

## Existing debt
The complete register is docs/engineering/debt.json.
- go_channels-D001 | small | lib/src/channel.dart:401-408 | correctness: failing future left unlistened (PLAUSIBLE)
  Fix: Use `completer.future.whenComplete(cleanup).ignore()` (supported by sdk ^3.6) or do the cleanup on the resolve/timer paths; add a contract test: a blocked select on onSend, then close → select throwsStateError and no uncaught error.
  Closure: The blocked select cleanup leaves no derived future without a listener, either through ignore() or by running the cleanup on the resolve and timer paths. The new contract test closes a channel under a blocked onSend select, expects throwsStateError and reports no uncaught error.
- go_channels-D002 | medium | lib/src/scope.dart:22-29 | memory growth
  Fix: Build a cancel-listener list (add/remove) in CancelToken; have withTaskScope/withTimeout detach the child from the parent in `finally`; add a test that measures the listener count across many short scopes.
  Closure: CancelToken removes each child listener when withTaskScope or withTimeout finishes. The new test shows the listener count staying flat across many short scopes under one parent.
- go_channels-D003 | small | lib/src/scope.dart:66-67, 81-85, 93-100 | silent error
  Fix: A `_closed` flag after drain; `spawn` on a closed scope should throw StateError; add a test.
  Closure: A drained scope sets a _closed flag and spawn on it throws StateError. The new scope test passes.
- go_channels-D004 | small | lib/src/channel.dart:64-66 | validation by assert only
  Fix: `ArgumentError.value(capacity, 'capacity', 'must not be negative')` + a test (not a contract change, undocumented input).
  Closure: The Channel constructor raises ArgumentError.value for a negative capacity in a release build. The new argument test passes.
- go_channels-D005 | small | lib/src/scope.dart:125 | untyped catch (J10/D11)
  Fix: `on Object catch (error, stack)` + a short rationale comment.
  Closure: scope.dart uses on Object catch with a short rationale comment and still rethrows through Error.throwWithStackTrace.
- go_channels-D006 | small | analysis_options.yaml:1-30; lib/src/scope.dart:5; lib/src/channel.dart:9 | lint / documentation debt
  Fix: Adopt the resilience analysis set and close the findings in the same change.
  Closure: analysis_options.yaml carries the strict set used by resilience and both exception constructors have dartdoc. dart analyze is clean.
- go_channels-D007 | small | CHANGELOG.md:5-6 | public text safety
  Fix: Rewrite the line without the internal name in the next release (for example a script that produces the frames from a real run); the published 1.1.1 archive does not change, accept that.
  Closure: The next release CHANGELOG describes the frame source without naming tools/term-trailer.sh or the portfolio repository.

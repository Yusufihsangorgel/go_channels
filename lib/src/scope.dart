import 'dart:async';

/// Thrown by [CancelToken.throwIfCancelled] when a token has been cancelled.
final class CancelledException implements Exception {
  CancelledException([this.reason]);

  /// Why the token was cancelled, if a reason was supplied.
  final Object? reason;

  @override
  String toString() =>
      reason == null ? 'CancelledException' : 'CancelledException: $reason';
}

/// A cooperative cancellation signal.
///
/// Dart futures cannot be forcibly killed, so cancellation is cooperative: a
/// running task observes the token (via [isCancelled], [throwIfCancelled], or
/// by awaiting [whenCancelled]) and stops itself. A child token created with a
/// [parent] is cancelled automatically when its parent is.
final class CancelToken {
  CancelToken._([CancelToken? parent]) {
    if (parent == null) return;
    if (parent.isCancelled) {
      _cancel(parent.reason);
    } else {
      parent.whenCancelled.then((_) => _cancel(parent.reason));
    }
  }

  /// Creates a standalone (root) token.
  factory CancelToken() = CancelToken._;

  bool _cancelled = false;
  Object? _reason;
  final Completer<void> _whenCancelled = Completer<void>.sync();

  /// Whether cancellation has been requested.
  bool get isCancelled => _cancelled;

  /// The reason passed to [cancel], if any.
  Object? get reason => _reason;

  /// Completes once the token is cancelled.
  Future<void> get whenCancelled => _whenCancelled.future;

  /// Throws [CancelledException] if the token is cancelled; otherwise returns.
  void throwIfCancelled() {
    if (_cancelled) throw CancelledException(_reason);
  }

  /// Requests cancellation. Has no effect if already cancelled.
  void cancel([Object? reason]) => _cancel(reason);

  void _cancel(Object? reason) {
    if (_cancelled) return;
    _cancelled = true;
    _reason = reason;
    if (!_whenCancelled.isCompleted) _whenCancelled.complete();
  }
}

/// A structured-concurrency scope: a group of tasks that all finish before the
/// scope returns, and where one failure cancels the rest (fail-fast).
///
/// Obtain one from [withTaskScope]; spawn children with [spawn]. Do not keep a
/// reference to the scope past the [withTaskScope] body.
final class TaskScope {
  TaskScope._([CancelToken? parent]) : token = CancelToken._(parent);

  /// The scope's cancellation token. It is cancelled if any child fails, if the
  /// body throws, or if a [parent] token is cancelled. Pass it down to children.
  final CancelToken token;

  final List<Future<void>> _tracked = [];
  Object? _error;
  StackTrace? _stack;

  /// Starts [task] as a child of this scope and returns its future. The scope
  /// will not return until every spawned task has completed.
  Future<T> spawn<T>(FutureOr<T> Function(CancelToken token) task) {
    final future = Future<T>.sync(() => task(token));
    _tracked.add(future.then<void>((_) {}, onError: _fail));
    return future;
  }

  void _fail(Object error, StackTrace stack) {
    _error ??= error;
    _stack ??= stack;
    token._cancel(error);
  }

  Future<void> _drain() async {
    // Tasks may spawn further tasks while draining, so loop until quiescent.
    while (_tracked.isNotEmpty) {
      final batch = List<Future<void>>.of(_tracked);
      _tracked.clear();
      await Future.wait(batch);
    }
  }
}

/// Runs [body] in a fresh [TaskScope] and returns its result once every task
/// spawned inside has finished.
///
/// If [body] throws, or any spawned task fails, the scope's [TaskScope.token] is
/// cancelled so the siblings can stop, all tasks are awaited, and the first
/// error is rethrown. Nothing spawned inside outlives this call.
///
/// ```dart
/// final results = await withTaskScope((scope) async {
///   final a = scope.spawn((_) => fetchA());
///   final b = scope.spawn((_) => fetchB());
///   return [await a, await b];
/// });
/// ```
Future<R> withTaskScope<R>(
  FutureOr<R> Function(TaskScope scope) body, {
  CancelToken? parent,
}) async {
  final scope = TaskScope._(parent);
  R? result;
  try {
    result = await body(scope);
  } catch (error, stack) {
    scope._fail(error, stack);
  }
  await scope._drain();
  final error = scope._error;
  if (error != null) {
    Error.throwWithStackTrace(error, scope._stack ?? StackTrace.current);
  }
  return result as R;
}

/// Runs [tasks] concurrently under one scope and returns their results in
/// order. Fails fast: the first error cancels the rest and is rethrown.
Future<List<T>> waitAll<T>(
  Iterable<FutureOr<T> Function(CancelToken token)> tasks, {
  CancelToken? parent,
}) {
  return withTaskScope<List<T>>(
    (scope) => Future.wait(tasks.map(scope.spawn)),
    parent: parent,
  );
}

/// Runs [task] with a token that is cancelled after [duration].
///
/// Cancellation is cooperative: [task] must observe its token to stop promptly.
/// If it does and rethrows, that error propagates; a well-behaved task that
/// ignores the token will simply run to completion.
Future<T> withTimeout<T>(
  Duration duration,
  FutureOr<T> Function(CancelToken token) task, {
  CancelToken? parent,
}) async {
  final token = CancelToken._(parent);
  final timer = Timer(
    duration,
    () => token._cancel(TimeoutException('withTimeout elapsed', duration)),
  );
  try {
    return await Future.sync(() => task(token));
  } finally {
    timer.cancel();
  }
}

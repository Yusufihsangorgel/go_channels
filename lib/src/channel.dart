import 'dart:async';
import 'dart:collection';
import 'dart:math';

/// Thrown by [Channel.receive] when the channel is closed and no values are
/// left to drain. Use [Channel.receiveOr] or [Channel.stream] if you would
/// rather observe closure without an exception.
final class ChannelClosedError extends StateError {
  ChannelClosedError() : super('receive on a closed, empty Channel');
}

/// A one-time claim shared by the branches of a [select]. The first branch to
/// become ready claims it; every other branch then fails [claim] and is
/// discarded. A plain [Channel.send]/[Channel.receive] uses a private claimer,
/// so it always succeeds.
class _Claimer {
  bool _taken = false;
  bool get isTaken => _taken;
  bool claim() {
    if (_taken) return false;
    _taken = true;
    return true;
  }
}

class _RecvWaiter<T> {
  _RecvWaiter(this.claimer, this.onReady);
  final _Claimer claimer;
  final void Function(T? value, bool ok) onReady;
  bool get isClaimed => claimer.isTaken;
  bool claim() => claimer.claim();
}

class _SendWaiter<T> {
  _SendWaiter(this.value, this.claimer, this.onSent, this.onError);
  final T value;
  final _Claimer claimer;
  final void Function() onSent;
  final void Function(Object error) onError;
  bool get isClaimed => claimer.isTaken;
  bool claim() => claimer.claim();
}

/// A CSP-style channel that carries values of type [T] between asynchronous
/// tasks, modelled on Go's channels.
///
/// A channel with `capacity == 0` (the default) is *unbuffered*: a [send]
/// completes only once a receiver takes the value (a rendezvous). A channel
/// with `capacity > 0` is *buffered*: a [send] completes immediately while the
/// buffer has room, and blocks once it is full.
///
/// The whole channel lives on a single isolate's event loop, so its operations
/// are race-free without locks. It coordinates asynchronous tasks; it does not
/// add parallelism. Combine it with isolates (or, in future, shared-memory
/// isolates) when you need real parallel execution.
///
/// ```dart
/// final ch = Channel<int>(capacity: 1);
/// await ch.send(1);
/// print(await ch.receive()); // 1
/// ch.close();
/// ```
final class Channel<T> {
  /// Creates a channel with the given buffer [capacity] (0 = unbuffered).
  Channel({this.capacity = 0})
      : assert(capacity >= 0, 'capacity must be non-negative');

  /// The buffer capacity. Zero means unbuffered (rendezvous).
  final int capacity;

  final ListQueue<T> _buffer = ListQueue<T>();
  final ListQueue<_RecvWaiter<T>> _recvQ = ListQueue<_RecvWaiter<T>>();
  final ListQueue<_SendWaiter<T>> _sendQ = ListQueue<_SendWaiter<T>>();
  bool _closed = false;

  /// Whether [close] has been called.
  bool get isClosed => _closed;

  /// The number of values currently sitting in the buffer.
  int get length => _buffer.length;

  /// The number of tasks currently blocked on a [send] or [receive] for this
  /// channel, useful for diagnostics and backpressure checks.
  int get waiters => _recvQ.length + _sendQ.length;

  /// Sends [value], completing once it is buffered or handed to a receiver.
  ///
  /// Throws [StateError] if the channel is closed.
  Future<void> send(T value) {
    if (_trySendNow(value)) return Future<void>.value();
    final completer = Completer<void>();
    _sendQ.add(_SendWaiter<T>(
      value,
      _Claimer(),
      completer.complete,
      completer.completeError,
    ));
    return completer.future;
  }

  /// Receives the next value, throwing [ChannelClosedError] if the channel is
  /// closed and drained. Prefer [receiveOr] or [stream] to observe closure
  /// without an exception.
  Future<T> receive() async {
    final (value, ok) = await receiveOr();
    if (!ok) throw ChannelClosedError();
    return value as T;
  }

  /// Receives the next value as `(value, true)`, or `(null, false)` once the
  /// channel is closed and drained, mirroring Go's `v, ok := <-ch`.
  Future<(T?, bool)> receiveOr() {
    final (has, value, open) = _tryReceiveNow();
    if (has) return Future<(T?, bool)>.value((value, true));
    if (!open) return Future<(T?, bool)>.value((null, false));
    final completer = Completer<(T?, bool)>();
    _recvQ.add(_RecvWaiter<T>(
      _Claimer(),
      (v, ok) => completer.complete((v, ok)),
    ));
    return completer.future;
  }

  /// The channel as a broadcast-free stream that ends when the channel closes,
  /// so values can be consumed with `await for`.
  Stream<T> get stream async* {
    while (true) {
      final (value, ok) = await receiveOr();
      if (!ok) return;
      yield value as T;
    }
  }

  /// Closes the channel. Buffered values remain receivable; further [send]s
  /// throw, blocked receivers observe closure, and blocked senders error.
  void close() {
    if (_closed) throw StateError('close on an already closed Channel');
    _closed = true;
    while (_recvQ.isNotEmpty) {
      final w = _recvQ.removeFirst();
      if (w.claim()) w.onReady(null, false);
    }
    while (_sendQ.isNotEmpty) {
      final w = _sendQ.removeFirst();
      if (w.claim()) w.onError(StateError('send on a closed Channel'));
    }
  }

  // --- internals shared with `select` (same library) ---

  bool _trySendNow(T value) {
    if (_closed) throw StateError('send on a closed Channel');
    while (_recvQ.isNotEmpty) {
      final w = _recvQ.first;
      if (w.claim()) {
        _recvQ.removeFirst();
        w.onReady(value, true);
        return true;
      }
      _recvQ.removeFirst(); // claimed by another select branch; discard
    }
    if (_buffer.length < capacity) {
      _buffer.add(value);
      return true;
    }
    return false;
  }

  /// Returns `(hasValue, value, open)`: a value was taken, or the channel is
  /// closed (`open == false`), or it would block (`hasValue == false, open`).
  (bool, T?, bool) _tryReceiveNow() {
    if (_buffer.isNotEmpty) {
      final v = _buffer.removeFirst();
      _drainSendersIntoBuffer();
      return (true, v, true);
    }
    while (_sendQ.isNotEmpty) {
      final w = _sendQ.first;
      if (w.claim()) {
        _sendQ.removeFirst();
        w.onSent();
        return (true, w.value, true);
      }
      _sendQ.removeFirst();
    }
    if (_closed) return (false, null, false);
    return (false, null, true);
  }

  void _drainSendersIntoBuffer() {
    while (_buffer.length < capacity && _sendQ.isNotEmpty) {
      final w = _sendQ.first;
      if (w.claim()) {
        _sendQ.removeFirst();
        _buffer.add(w.value);
        w.onSent();
      } else {
        _sendQ.removeFirst();
      }
    }
  }

  bool _canReceiveNow() {
    if (_buffer.isNotEmpty) return true;
    for (final w in _sendQ) {
      if (!w.isClaimed) return true;
    }
    return _closed;
  }

  bool _canSendNow() {
    if (_closed) return true; // taking it will throw, surfacing the error
    for (final w in _recvQ) {
      if (!w.isClaimed) return true;
    }
    return _buffer.length < capacity;
  }

  /// Registers a receive waiter for a `select` branch and returns a callback
  /// that withdraws it, so a losing branch does not linger in the queue.
  void Function() _addSelectReceive(
    _Claimer claimer,
    void Function(T?, bool) onReady,
  ) {
    final waiter = _RecvWaiter<T>(claimer, onReady);
    _recvQ.add(waiter);
    return () => _recvQ.remove(waiter);
  }

  void Function() _addSelectSend(
    T value,
    _Claimer claimer,
    void Function() onSent,
    void Function(Object) onError,
  ) {
    final waiter = _SendWaiter<T>(value, claimer, onSent, onError);
    _sendQ.add(waiter);
    return () => _sendQ.remove(waiter);
  }
}

/// A single branch of a [select]. Its type parameter `T` is kept entirely
/// inside the concrete subclasses, so the builder can hold a `List<_Case<R>>`
/// without erasing each branch's channel element type.
abstract class _Case<R> {
  /// Whether this branch could proceed right now, without blocking.
  bool get isReady;

  /// Performs the (ready) operation and runs the branch's handler.
  FutureOr<R> runReady();

  /// Registers a blocking waiter that resolves through [resolve] when the
  /// branch becomes ready. [completer] is used only to surface send errors.
  /// Returns a callback that withdraws this branch's waiter.
  void Function() register(
    _Claimer claimer,
    void Function(FutureOr<R> Function() run) resolve,
    Completer<R> completer,
  );
}

class _ReceiveCase<R, T> implements _Case<R> {
  _ReceiveCase(this.channel, this.handler);
  final Channel<T> channel;
  final FutureOr<R> Function(T? value, bool ok) handler;

  @override
  bool get isReady => channel._canReceiveNow();

  @override
  FutureOr<R> runReady() {
    final (has, value, _) = channel._tryReceiveNow();
    return handler(value, has);
  }

  @override
  void Function() register(_Claimer claimer,
      void Function(FutureOr<R> Function()) resolve, Completer<R> completer) {
    return channel._addSelectReceive(claimer, (value, ok) {
      resolve(() => handler(value, ok));
    });
  }
}

class _SendCase<R, T> implements _Case<R> {
  _SendCase(this.channel, this.value, this.handler);
  final Channel<T> channel;
  final T value;
  final FutureOr<R> Function() handler;

  @override
  bool get isReady => channel._canSendNow();

  @override
  FutureOr<R> runReady() {
    channel._trySendNow(value); // may throw if the channel is closed
    return handler();
  }

  @override
  void Function() register(_Claimer claimer,
      void Function(FutureOr<R> Function()) resolve, Completer<R> completer) {
    return channel._addSelectSend(value, claimer, () => resolve(handler),
        (error) {
      if (!completer.isCompleted) completer.completeError(error);
    });
  }
}

/// Collects the branches of a [select]. Register a receive with [onReceive], a
/// send with [onSend], a non-blocking fallback with [onDefault], and a deadline
/// with [onTimeout].
final class SelectCases<R> {
  SelectCases._();

  final List<_Case<R>> _cases = [];
  FutureOr<R> Function()? _default;
  Duration? _timeoutDuration;
  FutureOr<R> Function()? _timeoutHandler;

  /// Runs [handler] when [channel] yields a value, or is closed (`ok == false`).
  void onReceive<T>(
    Channel<T> channel,
    FutureOr<R> Function(T? value, bool ok) handler,
  ) {
    _cases.add(_ReceiveCase<R, T>(channel, handler));
  }

  /// Runs [handler] once [value] has been sent on [channel].
  void onSend<T>(Channel<T> channel, T value, FutureOr<R> Function() handler) {
    _cases.add(_SendCase<R, T>(channel, value, handler));
  }

  /// Makes the select non-blocking: [handler] runs if no other branch is
  /// immediately ready.
  void onDefault(FutureOr<R> Function() handler) {
    _default = handler;
  }

  /// Runs [handler] if no branch becomes ready within [duration].
  void onTimeout(Duration duration, FutureOr<R> Function() handler) {
    _timeoutDuration = duration;
    _timeoutHandler = handler;
  }
}

final Random _selectRandom = Random();

/// Waits on several channel operations at once and runs exactly one, modelled
/// on Go's `select`. Register branches with the [SelectCases] builder:
///
/// ```dart
/// final label = await select<String>((s) {
///   s.onReceive(jobs, (job, ok) => ok ? 'got $job' : 'jobs closed');
///   s.onSend(results, 42, () => 'sent a result');
///   s.onTimeout(Duration(seconds: 1), () => 'timed out');
/// });
/// ```
///
/// If more than one branch is ready at once, one is chosen at random, matching
/// Go's fairness. Add [SelectCases.onDefault] to make the call non-blocking.
Future<R> select<R>(void Function(SelectCases<R> cases) build) {
  final cases = SelectCases<R>._();
  build(cases);

  final ready = cases._cases.where((c) => c.isReady).toList();
  if (ready.isNotEmpty) {
    final chosen = ready[_selectRandom.nextInt(ready.length)];
    return Future<R>.sync(chosen.runReady);
  }

  if (cases._default != null) {
    return Future<R>.sync(cases._default!);
  }

  final claimer = _Claimer();
  final completer = Completer<R>();
  void resolve(FutureOr<R> Function() run) {
    Future<R>.sync(run)
        .then(completer.complete, onError: completer.completeError);
  }

  final withdrawals = [
    for (final c in cases._cases) c.register(claimer, resolve, completer),
  ];

  Timer? timer;
  if (cases._timeoutHandler != null) {
    timer = Timer(cases._timeoutDuration!, () {
      if (claimer.claim()) resolve(cases._timeoutHandler!);
    });
  }
  completer.future.whenComplete(() {
    timer?.cancel();
    // Withdraw every branch's waiter so a losing branch does not linger in its
    // channel's queue.
    for (final withdraw in withdrawals) {
      withdraw();
    }
  });
  return completer.future;
}

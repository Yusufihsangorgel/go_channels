import 'dart:async';

import 'package:go_channels/go_channels.dart';

/// Waiting on two channels at once — and what becomes of the branch that loses.
///
/// This is the half of `go_channels` that `dart:async` has no answer for. The
/// reflex Dart reaches for is `Future.any` over two `receive()` calls, which
/// looks equivalent, runs green, and silently destroys a value. Scene 2
/// measures that; the other scenes show what `select` does instead.
///
/// Run with: `dart run example/select_multiway.dart`
Future<void> main() async {
  await _oneBranchWinsTheLoserKeepsItsValue();
  await _theFutureAnyTrap();
  await _whenNobodyIsReadyTheDeadlineWins();
  await _tiesAreBrokenAtRandom();
}

/// Two producers, two channels, a value parked and ready on each. `select`
/// commits to exactly one branch and leaves the other channel untouched.
Future<void> _oneBranchWinsTheLoserKeepsItsValue() async {
  final a = Channel<int>();
  final b = Channel<int>();

  // Unbuffered channels rendezvous: a `send` with no receiver yet parks a
  // waiter and stays pending. Not awaiting it is safe and deliberate here: the
  // value sits in the channel until somebody receives it, and `waiters` lets us
  // watch that happen.
  unawaited(a.send(1));
  unawaited(b.send(2));
  print('armed: a.waiters=${a.waiters}, b.waiters=${b.waiters}');

  final winner = await select<String>((s) {
    s.onReceive(a, (value, ok) => 'a=$value');
    s.onReceive(b, (value, ok) => 'b=$value');
    // A deadline belongs on any select that could block forever. Both branches
    // are already ready here, so this one never even arms: `select` takes the
    // synchronous fast path. Scene 3 is the case where it fires.
    s.onTimeout(const Duration(seconds: 5), () => 'deadline');
  });

  // The property that matters: the losing branch never ran, so its value is
  // still in its channel and the next receiver gets it.
  final leftInA = _describe(await _pollWithoutBlocking(a));
  final leftInB = _describe(await _pollWithoutBlocking(b));
  print('  won: $winner  ->  a: $leftInA, b: $leftInB');
  print('  exactly one channel was drained; the loser kept its value\n');
}

/// The same race written with `dart:async` alone — and the bug it ships with.
///
/// `Future.any` reports whichever future completes first, but it cannot
/// un-start the others. Both `receive()` calls have already pulled their value
/// out of their channel before `Future.any` even looks, so the loser's value is
/// handed to a future nobody awaits and is gone. Dart offers no way to cancel a
/// pending `receive` from the outside, which is exactly why the withdrawal has
/// to live inside `select`.
Future<void> _theFutureAnyTrap() async {
  final a = Channel<int>();
  final b = Channel<int>();
  final sentA = a.send(1);
  final sentB = b.send(2);

  final winner = await Future.any<String>([
    a.receive().then((value) => 'a=$value'),
    b.receive().then((value) => 'b=$value'),
  ]);

  final leftInA = _describe(await _pollWithoutBlocking(a));
  final leftInB = _describe(await _pollWithoutBlocking(b));
  print('Future.any won: $winner  ->  a: $leftInA, b: $leftInB');

  // The sting. Both sends completed *successfully*, so neither producer has any
  // way to learn that one of the values was dropped on the floor. Nothing
  // throws, no test fails, and a value is missing.
  await sentA;
  await sentB;
  print('  both senders saw a successful send, yet one value reached nobody\n');
}

/// Nothing is ready, so the deadline wins. This is where the withdrawal stops
/// being a detail: it decides whether you can leave the loop running.
///
/// While it waits, `select` parks a waiter on every channel it is watching, and
/// when the timeout fires it takes all of them back out, so the queues stay flat
/// across rounds. That is the shape a worker waiting on work-or-shutdown sits in
/// all day. The `Future.any` spelling has no withdrawal available to it: every
/// round abandons two receivers, and their channel holds them for as long as it
/// lives.
Future<void> _whenNobodyIsReadyTheDeadlineWins() async {
  const rounds = 5;
  const deadline = Duration(milliseconds: 5);

  final a = Channel<int>();
  final b = Channel<int>();
  for (var i = 0; i < rounds; i++) {
    final outcome = await select<String>((s) {
      s.onReceive(a, (value, ok) => 'a=$value');
      s.onReceive(b, (value, ok) => 'b=$value');
      s.onTimeout(deadline, () => 'deadline');
    });
    if (i == 0) print('idle select -> $outcome');
  }
  print('  after $rounds select rounds:     '
      'a.waiters=${a.waiters}, b.waiters=${b.waiters}');

  // The same loop with dart:async alone. Nothing ever arrives, the delay wins
  // every round, and both abandoned receives stay parked in their queue.
  final c = Channel<int>();
  final d = Channel<int>();
  for (var i = 0; i < rounds; i++) {
    await Future.any<String>([
      c.receive().then((_) => 'c'),
      d.receive().then((_) => 'd'),
      Future<String>.delayed(deadline, () => 'deadline'),
    ]);
  }
  print('  after $rounds Future.any rounds: '
      'c.waiters=${c.waiters}, d.waiters=${d.waiters}  <- one per round, each\n');
}

/// When several branches are ready at once, Go picks one at random rather than
/// in declaration order, so a busy channel cannot starve a quiet one. Declaring
/// the hot channel first buys it nothing. Over many rounds the split lands near
/// even, which also means branch order is not a priority mechanism and should
/// not be used as one.
Future<void> _tiesAreBrokenAtRandom() async {
  const rounds = 2000;
  var aWins = 0;

  for (var i = 0; i < rounds; i++) {
    // capacity 1 so both sends complete immediately and both branches are
    // genuinely ready by the time `select` runs.
    final a = Channel<int>(capacity: 1);
    final b = Channel<int>(capacity: 1);
    await a.send(1);
    await b.send(2);

    final aWon = await select<bool>((s) {
      s.onReceive(a, (value, ok) => true);
      s.onReceive(b, (value, ok) => false);
    });
    if (aWon) aWins++;
  }

  print('ties over $rounds rounds: a won $aWins, b won ${rounds - aWins}');
  print('  order of declaration is not priority — do not encode it as such');
}

/// Attempts a receive without ever blocking.
///
/// `onDefault` runs when no other branch is ready, which turns `select` into a
/// poll. Used here as the measuring instrument: "is there still a value sitting
/// in this channel?" Returns `null` when the channel has nothing to give.
Future<int?> _pollWithoutBlocking(Channel<int> channel) {
  return select<int?>((s) {
    s.onReceive(channel, (value, ok) => value);
    s.onDefault(() => null);
  });
}

String _describe(int? value) => value == null ? 'empty' : 'still holds $value';

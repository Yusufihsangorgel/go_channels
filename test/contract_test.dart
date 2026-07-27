import 'dart:async';

import 'package:go_channels/go_channels.dart';
import 'package:test/test.dart';

/// The behaviours a caller coming from Go relies on. They are the frozen 1.0.0
/// contract, and most of them are the ones that deadlock when they are wrong.
void main() {
  group('close semantics', () {
    test('sending on a closed channel throws', () {
      final channel = Channel<int>(capacity: 1)..close();
      expect(() => channel.send(1), throwsStateError);
    });

    test('closing twice throws', () {
      final channel = Channel<int>()..close();
      expect(channel.close, throwsStateError);
    });

    test('receive on a closed, drained channel throws ChannelClosedError', () {
      final channel = Channel<int>()..close();
      expect(channel.receive, throwsA(isA<ChannelClosedError>()));
    });

    test('receiveOr reports closure instead of throwing', () async {
      final channel = Channel<int>()..close();
      final (value, ok) = await channel.receiveOr();
      expect(value, isNull);
      expect(ok, isFalse);
    });

    test('buffered values still drain after close', () async {
      final channel = Channel<int>(capacity: 3);
      await channel.send(1);
      await channel.send(2);
      channel.close();
      expect(await channel.stream.toList(), [1, 2]);
    });

    test('a pending receive completes when the channel closes', () async {
      final channel = Channel<int>();
      final pending = channel.receiveOr();
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 20), channel.close),
      );
      final (_, ok) = await pending.timeout(const Duration(seconds: 2));
      expect(ok, isFalse, reason: 'must not hang waiting on a closed channel');
    });

    test('a pending send fails when the channel closes', () async {
      final channel = Channel<int>();
      final pending = channel.send(1);
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 20), channel.close),
      );
      await expectLater(
        pending.timeout(const Duration(seconds: 2)),
        throwsStateError,
      );
    });
  });

  group('select', () {
    test('onDefault makes select non-blocking', () async {
      final channel = Channel<int>();
      var tookDefault = false;
      await select<void>((cases) {
        cases.onReceive(channel, (_, __) {});
        cases.onDefault(() => tookDefault = true);
      }).timeout(const Duration(seconds: 2));
      expect(tookDefault, isTrue);
    });

    test('a closed channel is a ready receive, not a stall', () async {
      final channel = Channel<int>()..close();
      var sawClosed = false;
      await select<void>((cases) {
        cases.onReceive(channel, (_, ok) => sawClosed = !ok);
        cases.onTimeout(const Duration(milliseconds: 500), () {});
      }).timeout(const Duration(seconds: 2));
      expect(sawClosed, isTrue);
    });

    test('picks at random when several branches are ready', () async {
      final a = Channel<int>(capacity: 100);
      final b = Channel<int>(capacity: 100);
      for (var i = 0; i < 100; i++) {
        await a.send(1);
        await b.send(2);
      }
      var fromA = 0;
      for (var i = 0; i < 100; i++) {
        await select<void>((cases) {
          cases.onReceive(a, (_, __) => fromA++);
          cases.onReceive(b, (_, __) {});
        });
      }
      // A first-ready-wins implementation would take 100 from a. Randomised
      // selection lands near the middle; this range fails with probability
      // far below one in a million.
      expect(fromA, greaterThan(20));
      expect(fromA, lessThan(80));
    });
  });

  group('structured concurrency', () {
    test('a failing task cancels its siblings and the error propagates',
        () async {
      var siblingSawCancellation = false;
      await expectLater(
        withTaskScope((scope) async {
          scope.spawn((token) async {
            await Future<void>.delayed(const Duration(milliseconds: 300));
            siblingSawCancellation = token.isCancelled;
          });
          scope.spawn((_) async {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            throw StateError('task failed');
          });
        }).timeout(const Duration(seconds: 2)),
        throwsStateError,
      );
      expect(siblingSawCancellation, isTrue);
    });

    test('withTimeout cancels the token it hands out', () async {
      var observedCancellation = false;
      await withTimeout(const Duration(milliseconds: 50), (token) async {
        while (!token.isCancelled) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        observedCancellation = true;
      }).timeout(const Duration(seconds: 2));
      expect(observedCancellation, isTrue);
    });
  });
}

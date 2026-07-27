import 'dart:async';

import 'package:go_channels/go_channels.dart';
import 'package:test/test.dart';

void main() {
  group('CancelToken', () {
    test('throwIfCancelled throws only after cancel', () {
      final token = CancelToken();
      expect(token.throwIfCancelled, returnsNormally);
      token.cancel('stop');
      expect(token.isCancelled, isTrue);
      expect(token.reason, 'stop');
      expect(token.throwIfCancelled, throwsA(isA<CancelledException>()));
    });

    test('whenCancelled completes on cancel', () async {
      final token = CancelToken();
      var fired = false;
      unawaited(token.whenCancelled.then((_) => fired = true));
      token.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(fired, isTrue);
    });
  });

  group('withTaskScope', () {
    test('waits for all spawned tasks before returning', () async {
      final done = <int>[];
      final result = await withTaskScope<String>((scope) async {
        scope.spawn((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          done.add(1);
        });
        scope.spawn((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          done.add(2);
        });
        return 'ok';
      });
      expect(result, 'ok');
      expect(done, containsAll([1, 2]));
    });

    test('one task failing cancels the siblings (fail-fast)', () async {
      var siblingObservedCancel = false;
      await expectLater(
        withTaskScope<void>((scope) async {
          scope.spawn((token) async {
            await Future<void>.delayed(const Duration(milliseconds: 5));
            throw StateError('boom');
          });
          scope.spawn((token) async {
            await token.whenCancelled;
            siblingObservedCancel = true;
          });
        }),
        throwsA(isA<StateError>()),
      );
      expect(siblingObservedCancel, isTrue);
    });

    test('a task spawned but never awaited still propagates its failure',
        () async {
      await expectLater(
        withTaskScope<String>((scope) async {
          scope.spawn((_) => throw StateError('orphan'));
          return 'body-returned';
        }),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('waitAll', () {
    test('returns results in order', () async {
      final out = await waitAll<int>([
        (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return 1;
        },
        (_) async => 2,
        (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return 3;
        },
      ]);
      expect(out, [1, 2, 3]);
    });

    test('fails fast on the first error', () {
      expect(
        waitAll<int>([
          (_) async => 1,
          (_) async => throw StateError('nope'),
        ]),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('withTimeout', () {
    test('returns the value when the task finishes in time', () async {
      final v = await withTimeout(const Duration(seconds: 1), (_) async => 42);
      expect(v, 42);
    });

    test('cancels the token when the deadline passes', () async {
      final v =
          await withTimeout(const Duration(milliseconds: 10), (token) async {
        await token.whenCancelled;
        return token.isCancelled ? 'cancelled' : 'ran';
      });
      expect(v, 'cancelled');
    });
  });
}

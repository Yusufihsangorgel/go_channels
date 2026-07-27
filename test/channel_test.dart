import 'dart:async';

import 'package:go_channels/go_channels.dart';
import 'package:test/test.dart';

void main() {
  group('Channel (buffered)', () {
    test('send within capacity does not block; FIFO receive', () async {
      final ch = Channel<int>(capacity: 2);
      await ch.send(1);
      await ch.send(2);
      expect(ch.length, 2);
      expect(await ch.receive(), 1);
      expect(await ch.receive(), 2);
    });

    test('send blocks once the buffer is full, then unblocks on receive',
        () async {
      final ch = Channel<int>(capacity: 1);
      await ch.send(1);
      var sent = false;
      final pending = ch.send(2).then((_) => sent = true);
      await Future<void>.delayed(Duration.zero);
      expect(sent, isFalse, reason: 'buffer full, send must block');
      expect(await ch.receive(), 1);
      await pending;
      expect(sent, isTrue);
      expect(await ch.receive(), 2);
    });
  });

  group('Channel (unbuffered)', () {
    test('send rendezvous: completes only when received', () async {
      final ch = Channel<String>();
      var sent = false;
      final pending = ch.send('hi').then((_) => sent = true);
      await Future<void>.delayed(Duration.zero);
      expect(sent, isFalse);
      expect(await ch.receive(), 'hi');
      await pending;
      expect(sent, isTrue);
    });

    test('receive blocks until a send arrives', () async {
      final ch = Channel<int>();
      final got = ch.receive();
      await ch.send(7);
      expect(await got, 7);
    });

    test('multiple blocked receivers are served in order', () async {
      final ch = Channel<int>();
      final r1 = ch.receive();
      final r2 = ch.receive();
      await ch.send(1);
      await ch.send(2);
      expect(await r1, 1);
      expect(await r2, 2);
    });
  });

  group('close semantics', () {
    test('buffered values drain, then receive throws', () async {
      final ch = Channel<int>(capacity: 2);
      await ch.send(1);
      await ch.send(2);
      ch.close();
      expect(await ch.receive(), 1);
      expect(await ch.receive(), 2);
      expect(ch.receive(), throwsA(isA<ChannelClosedError>()));
    });

    test('receiveOr reports closure as (null, false)', () async {
      final ch = Channel<int>()..close();
      expect(await ch.receiveOr(), (null, false));
    });

    test('stream yields buffered values then ends', () async {
      final ch = Channel<int>(capacity: 3);
      await ch.send(1);
      await ch.send(2);
      await ch.send(3);
      ch.close();
      expect(await ch.stream.toList(), [1, 2, 3]);
    });

    test('send on a closed channel throws', () async {
      final ch = Channel<int>()..close();
      expect(() => ch.send(1), throwsStateError);
    });

    test('a blocked receiver observes closure', () async {
      final ch = Channel<int>();
      final got = ch.receiveOr();
      ch.close();
      expect(await got, (null, false));
    });

    test('a blocked sender errors when the channel closes', () async {
      final ch = Channel<int>();
      final pending = ch.send(1);
      ch.close();
      expect(pending, throwsStateError);
    });
  });

  group('select', () {
    test('takes from whichever channel is ready', () async {
      final a = Channel<int>(capacity: 1);
      final b = Channel<int>(capacity: 1);
      await b.send(99);
      final result = await select<String>((s) {
        s.onReceive(a, (v, ok) => 'a=$v');
        s.onReceive(b, (v, ok) => 'b=$v');
      });
      expect(result, 'b=99');
      expect(a.length, 0);
      expect(b.length, 0);
    });

    test('consumes exactly one branch when several are ready', () async {
      final a = Channel<int>(capacity: 1);
      final b = Channel<int>(capacity: 1);
      await a.send(1);
      await b.send(2);
      await select<void>((s) {
        s.onReceive(a, (v, ok) {});
        s.onReceive(b, (v, ok) {});
      });
      // One channel still holds its value — only one branch ran.
      expect(a.length + b.length, 1);
    });

    test('default makes it non-blocking', () async {
      final ch = Channel<int>();
      final result = await select<String>((s) {
        s.onReceive(ch, (v, ok) => 'got');
        s.onDefault(() => 'nothing ready');
      });
      expect(result, 'nothing ready');
    });

    test('blocks until a channel becomes ready', () async {
      final ch = Channel<int>();
      final pending = select<int>((s) {
        s.onReceive(ch, (v, ok) => v! * 10);
      });
      await ch.send(5);
      expect(await pending, 50);
    });

    test('onSend fires when a receiver takes the value', () async {
      final ch = Channel<int>();
      final pending = select<String>((s) {
        s.onSend(ch, 42, () => 'sent');
      });
      expect(await ch.receive(), 42);
      expect(await pending, 'sent');
    });

    test('onTimeout fires when nothing is ready', () async {
      final ch = Channel<int>();
      final result = await select<String>((s) {
        s.onReceive(ch, (v, ok) => 'got');
        s.onTimeout(const Duration(milliseconds: 20), () => 'timed out');
      });
      expect(result, 'timed out');
    });

    test('receive branch sees closure (ok == false)', () async {
      final ch = Channel<int>()..close();
      final result = await select<String>((s) {
        s.onReceive(ch, (v, ok) => ok ? 'value' : 'closed');
      });
      expect(result, 'closed');
    });

    test('withdraws a losing branch waiter (no lingering blocked receiver)',
        () async {
      final a = Channel<int>();
      final b = Channel<int>();
      final pending = select<String>((s) {
        s.onReceive(a, (v, ok) => 'a');
        s.onReceive(b, (v, ok) => 'b');
      });
      expect(a.waiters, 1);
      expect(b.waiters, 1);
      await a.send(1); // a wins
      expect(await pending, 'a');
      await Future<void>.delayed(Duration.zero); // let whenComplete run
      expect(a.waiters, 0);
      expect(b.waiters, 0, reason: 'losing branch waiter must be withdrawn');
    });

    test('a losing branch is withdrawn and can still be used after', () async {
      final a = Channel<int>();
      final b = Channel<int>();
      final pending = select<String>((s) {
        s.onReceive(a, (v, ok) => 'a=$v');
        s.onReceive(b, (v, ok) => 'b=$v');
      });
      await a.send(1);
      expect(await pending, 'a=1');
      // b never fired; it is still fully usable.
      final later = b.receive();
      await b.send(2);
      expect(await later, 2);
    });
  });
}

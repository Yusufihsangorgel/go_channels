import 'dart:async';

import 'package:go_channels/go_channels.dart';

/// What a scope does when one of its tasks fails, and what a `CancelToken` can
/// and cannot make a running task do.
///
/// Dart cannot kill a running future from the outside, which leaves
/// cancellation cooperative: a scope raises a flag and waits for its tasks to
/// look at it. These three scenes measure that. Siblings stop at their next
/// check rather than instantly, a task that never checks does not stop at all,
/// and a worker parked inside `select` needs the flag delivered as a channel.
///
/// Run with: `dart run example/cancellation.dart`
Future<void> main() async {
  await _oneFailureStopsTheSiblings();
  await _aDeadlineOnlyStopsATaskThatLooks();
  await _waitingOnWorkOrShutdown();
}

/// Three workers of six steps each, and one of them throws partway through.
///
/// `withTaskScope` cancels the scope token on that first failure, waits for
/// every task to finish anyway, then rethrows the error. The siblings see the
/// flag between steps and return early. The control run is what makes the
/// shortened counts readable: six is what a worker does when nothing interrupts
/// it.
Future<void> _oneFailureStopsTheSiblings() async {
  const steps = 6;

  final control = await _runThreeWorkers(steps: steps, failOnStep: null);
  print('nobody fails:    steps completed ${control.done}');

  final failed = await _runThreeWorkers(steps: steps, failOnStep: 3);
  print('worker 1 throws: steps completed ${failed.done}');
  print('  the scope rethrew: ${failed.error}');
  print('  worker 1 threw on step 3, which is why its count stops at 2');
  print('  the other two ran to their next check and stopped there; '
      'neither reaches $steps\n');
}

/// Runs three workers under one scope. Worker 1 throws on [failOnStep] if a
/// step number is given. Returns the steps each worker completed and the error
/// the scope rethrew.
Future<({List<int> done, Object? error})> _runThreeWorkers({
  required int steps,
  required int? failOnStep,
}) async {
  final done = [0, 0, 0];
  Object? error;

  try {
    await withTaskScope<void>((scope) async {
      for (var w = 0; w < done.length; w++) {
        final worker = w;
        scope.spawn((token) async {
          for (var step = 1; step <= steps; step++) {
            // The whole of cooperative cancellation is this line: look, and
            // decide to stop. Nothing outside the task can do it for you.
            if (token.isCancelled) return;
            await Future<void>.delayed(const Duration(milliseconds: 5));
            if (worker == 1 && step == failOnStep) {
              throw StateError('worker 1 failed on step $step');
            }
            done[worker]++;
          }
        });
      }
    });
  } on StateError catch (e) {
    error = e;
  }

  return (done: done, error: error);
}

/// A deadline cancels the token. It does not stop the task.
///
/// Both tasks below get 25 ms and want 100 ms of work, in ten chunks. The one
/// that calls `throwIfCancelled` between chunks gives up three chunks in, a
/// little past the deadline because it was mid-chunk when the token flipped.
/// The one that never looks at its token runs all ten and returns a value, with
/// no error anywhere: `withTimeout` reports no failure of its own.
Future<void> _aDeadlineOnlyStopsATaskThatLooks() async {
  const deadline = Duration(milliseconds: 25);
  const chunk = Duration(milliseconds: 10);
  const chunks = 10;

  final watch = Stopwatch()..start();
  var checkedChunks = 0;
  Object? stopReason;
  final checked = await withTimeout<String>(deadline, (token) async {
    try {
      for (var i = 0; i < chunks; i++) {
        token.throwIfCancelled();
        await Future<void>.delayed(chunk);
        checkedChunks++;
      }
      return 'ran all $checkedChunks chunks';
    } on CancelledException catch (e) {
      // The reason rides along with the exception, which is how a task tells a
      // deadline apart from an operator who asked it to stop.
      stopReason = e.reason;
      return 'gave up after $checkedChunks chunks';
    }
  });
  final checkedMs = watch.elapsedMilliseconds;

  watch.reset();
  var ignoredChunks = 0;
  final ignored = await withTimeout<String>(deadline, (token) async {
    for (var i = 0; i < chunks; i++) {
      await Future<void>.delayed(chunk);
      ignoredChunks++;
    }
    return 'ran all $ignoredChunks chunks';
  });
  final ignoredMs = watch.elapsedMilliseconds;

  print('deadline ${deadline.inMilliseconds} ms over '
      '${chunks * chunk.inMilliseconds} ms of work');
  print('  checks the token: $checked (${checkedMs}ms)');
  print('    reason: $stopReason');
  print('  ignores it:       $ignored (${ignoredMs}ms)');
  print('  the second one outlived its deadline and nothing complained\n');
}

/// A worker waiting on work-or-shutdown, which is where a token and a `select`
/// have to meet.
///
/// `select` chooses among channel operations, and a token is not one of those.
/// Bridge it: close a channel when the token is cancelled and give `select` a
/// branch on it. A closed channel is always ready to receive and reports
/// `ok == false`, which is enough to end the loop.
///
/// Polling `isCancelled` between receives would not work here. The worker is
/// parked inside `select` waiting for a job that never comes, and a task that
/// is parked runs no code that could do the polling.
Future<void> _waitingOnWorkOrShutdown() async {
  final jobs = Channel<int>();
  var handled = 0;

  await withTaskScope<void>((scope) async {
    final shutdown = Channel<void>();
    unawaited(scope.token.whenCancelled.then((_) => shutdown.close()));

    // The worker never reads its token directly: everything it needs to know
    // arrives on `shutdown`, which is the only form `select` can wait on.
    final worker = scope.spawn((_) async {
      while (true) {
        final gotJob = await select<bool>((s) {
          s.onReceive(jobs, (job, ok) {
            if (ok) handled++;
            return ok;
          });
          s.onReceive(shutdown, (_, ok) => false);
        });
        if (!gotJob) return;
      }
    });

    for (var i = 1; i <= 3; i++) {
      await jobs.send(i);
    }
    // A send completes the moment the receiver takes the value, one turn before
    // the worker loops back into `select`. Yield so the count below describes a
    // worker that is parked rather than one that is on its way there.
    await Future<void>.delayed(Duration.zero);
    print('after 3 jobs: worker parked in select, jobs.waiters='
        '${jobs.waiters}, shutdown.waiters=${shutdown.waiters}');

    scope.token.cancel('operator asked to stop');
    await worker;
    print('  worker handled $handled jobs, then left on: '
        '${scope.token.reason}');
    print('  cancelling a scope token is not a failure; this scope '
        'returned normally');
  });
}

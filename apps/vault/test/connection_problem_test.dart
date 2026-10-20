import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/production/connection_problem.dart';

void main() {
  test('every problem has its own text naming who and one action', () {
    final texts = <String>{};
    for (final problem in ConnectionProblem.values) {
      final copy = problemCopy(problem, who: 'Rina');
      expect(copy.text, contains('Rina'), reason: problem.name);
      expect(copy.label, isNotEmpty, reason: problem.name);
      expect(texts.add(copy.text), isTrue, reason: problem.name);
    }
    expect(
      {
        for (final problem in ConnectionProblem.values)
          problem: problemCopy(problem, who: 'x').action,
      },
      {
        ConnectionProblem.notAContact: ProblemAction.pair,
        ConnectionProblem.youDisconnected: ProblemAction.connect,
        ConnectionProblem.negotiationTimedOut: ProblemAction.retry,
        ConnectionProblem.noDirectRoute: ProblemAction.retry,
        ConnectionProblem.signalingUnavailable: ProblemAction.retry,
      },
    );
  });

  test('no direct route suggests a shared network and never a relay', () {
    final text = problemCopy(
      ConnectionProblem.noDirectRoute,
      who: 'Rina',
    ).text.toLowerCase();
    expect(text, contains('direct connection'));
    expect(text, contains('wi-fi'));
    expect(text, contains('same network'));
    for (final word in ['turn', 'relay', 'server']) {
      expect(text, isNot(contains(word)), reason: word);
    }
  });

  test('unknown senders are bounded, deduplicated and repeat-limited', () {
    final log = IgnoredAttempts();
    final start = DateTime.utc(2026);
    PeerProblem unknown(int index) =>
        PeerProblem('sender$index', ConnectionProblem.notAContact);

    expect(log.record(unknown(0), now: start), isTrue);
    expect(
      log.record(unknown(0), now: start.add(const Duration(seconds: 5))),
      isFalse,
      reason: 'a repeat inside the window must not notify again',
    );
    expect(
      log.record(unknown(0), now: start.add(const Duration(minutes: 2))),
      isTrue,
    );
    for (var index = 1; index <= 20; index++) {
      log.record(unknown(index), now: start.add(Duration(minutes: 3 + index)));
    }
    expect(log.unknownSenders, hasLength(IgnoredAttempts.maxUnknownSenders));
    expect(log.unknownSenders.keys.last, 'sender20');
    expect(log.unknownSenders, isNot(contains('sender0')));
  });

  test('a blocked offer notifies once until dismissed', () {
    final log = IgnoredAttempts();
    const attempt = PeerProblem('bob', ConnectionProblem.youDisconnected);
    final now = DateTime.utc(2026);
    expect(log.record(attempt, now: now), isTrue);
    expect(log.record(attempt, now: now), isFalse);
    expect(log.blockedOffers, {'bob'});
    expect(log.dismissBlocked('bob'), isTrue);
    expect(log.record(attempt, now: now), isTrue);
  });

  testWidgets('a notice runs its one remedy', (tester) async {
    ProblemAction? chosen;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConnectionProblemNotice(
            problem: ConnectionProblem.youDisconnected,
            who: 'Rina',
            onAction: (action) => chosen = action,
          ),
        ),
      ),
    );
    expect(find.textContaining('you disconnected them'), findsOneWidget);
    await tester.tap(find.text('Connect'));
    expect(chosen, ProblemAction.connect);
  });
}

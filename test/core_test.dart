import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/core/approval/approval_gate.dart';
import 'package:jarvis/core/greeting.dart';
import 'package:jarvis/core/intent/local_intent.dart';
import 'package:jarvis/core/intent/local_intent_engine.dart';
import 'package:jarvis/core/task/task_models.dart';
import 'package:jarvis/core/task/task_runner.dart';

void main() {
  final e = LocalIntentEngine();

  group('Local intent engine — interrupts never need AI', () {
    for (final s in ['STOP', 'Jarvis, stop', 'stop now', 'stop it please', 'Halt']) {
      test('"$s" → Stop', () => expect(e.parse(s), isA<StopIntent>()));
    }
    test('stop everything', () => expect(e.parse('STOP EVERYTHING'), isA<StopEverythingIntent>()));
    test('pause', () => expect(e.parse('PAUSE'), isA<PauseIntent>()));
    test('hold on', () => expect(e.parse('hold on'), isA<PauseIntent>()));
    test('resume', () => expect(e.parse('RESUME'), isA<ResumeIntent>()));
    test('cancel this task', () => expect(e.parse('CANCEL THIS TASK'), isA<CancelTaskIntent>()));
    test('what are you doing', () => expect(e.parse('WHAT ARE YOU DOING?'), isA<StatusIntent>()));
    test('continue where you stopped',
        () => expect(e.parse('CONTINUE WHERE YOU STOPPED'), isA<ContinueWhereStoppedIntent>()));
    test('bare continue with interrupted task → continue where stopped',
        () => expect(e.parse('continue', ctx: const IntentContext(hasInterruptedTask: true)), isA<ContinueWhereStoppedIntent>()));
    test('stop listening is not Stop', () => expect(e.parse('stop listening'), isA<StopListeningIntent>()));
    test('none of the interrupts require AI', () {
      for (final s in ['stop', 'pause', 'resume', 'cancel this task', 'what are you doing', 'continue where you stopped']) {
        expect(e.parse(s).requiresAi, isFalse, reason: s);
      }
    });
  });

  group('Local intent engine — device actions', () {
    test('open WhatsApp is local', () {
      final i = e.parse('Open WhatsApp');
      expect(i, isA<OpenAppIntent>());
      expect((i as OpenAppIntent).appName, 'WhatsApp');
      expect(i.requiresAi, isFalse);
    });
    test('launch youtube app', () => expect((e.parse('launch the YouTube app') as OpenAppIntent).appName, 'YouTube'));

    test('demo sentence → WhatsApp send with exact message', () {
      final i = e.parse("LEO, open WhatsApp and send a message to Yadava ISE saying I'm not coming to college today.");
      expect(i, isA<SendMessageIntent>());
      final s = i as SendMessageIntent;
      expect(s.app, MessagingApp.whatsapp);
      expect(s.recipient, 'Yadava ISE');
      expect(s.message, "I'm not coming to college today.");
      expect(s.isGroup, isFalse);
      expect(s.requiresAi, isFalse);
    });
    test('business app only when mentioned', () {
      final s = e.parse('send a message to Ravi on WhatsApp Business saying the order is ready') as SendMessageIntent;
      expect(s.app, MessagingApp.whatsappBusiness);
      expect(s.recipient, 'Ravi');
      expect(s.message, 'the order is ready');
    });
    test('group detection: "message the group X saying Y"', () {
      final s = e.parse('message the group Yadava ISE saying class is cancelled') as SendMessageIntent;
      expect(s.isGroup, isTrue);
      expect(s.recipient, 'Yadava ISE');
      expect(s.message, 'class is cancelled');
    });
    test('group detection: "X group"', () {
      final s = e.parse('send a WhatsApp message to the ISE friends group saying meet at 5') as SendMessageIntent;
      expect(s.isGroup, isTrue);
      expect(s.recipient, 'ISE friends');
    });
    test('tell X that Y', () {
      final s = e.parse('tell Mom that I will be late') as SendMessageIntent;
      expect(s.recipient, 'Mom');
      expect(s.message, 'I will be late');
    });
    test('message without content asks later', () {
      final s = e.parse('send a message to Rahul') as SendMessageIntent;
      expect(s.message, isNull);
      expect(s.composeTopic, isNull);
    });
    test('about → AI compose, still a send task', () {
      final s = e.parse('message Rahul on WhatsApp about tomorrow\'s meeting') as SendMessageIntent;
      expect(s.composeTopic, "tomorrow's meeting");
      expect(s.requiresAi, isTrue);
    });
    test('"tell me a joke" is not a message', () => expect(e.parse('tell me a joke'), isNot(isA<SendMessageIntent>())));
  });

  group('Local intent engine — info, memory, AI routing', () {
    test('time', () => expect(e.parse('what time is it'), isA<TellTimeIntent>()));
    test('remember', () => expect((e.parse('remember that my exam is on Monday') as RememberIntent).fact, 'my exam is on Monday'));
    test('statement', () => expect(e.parse('I am working on the Nocom application'), isA<ContextStatementIntent>()));
    test('continue previous work', () => expect(e.parse('Continue the work we discussed'), isA<ContinuePreviousWorkIntent>()));
    test('delete history', () => expect(e.parse('delete all conversation history'), isA<ForgetEverythingIntent>()));
    test('knowledge question → AI', () {
      final i = e.parse('Who discovered penicillin?');
      expect(i, isA<KnowledgeIntent>());
      expect(i.requiresAi, isTrue);
    });
    test('write email → AI writer', () {
      final i = e.parse('Write a professional email to my professor asking for leave tomorrow');
      expect(i, isA<WriteIntent>());
      expect((i as WriteIntent).kind, WritingKind.email);
    });
    test('unknown → AI fallback', () => expect(e.parse('I feel like doing something fun'), isA<UnknownIntent>()));
  });

  group('Approval answers only in approval context', () {
    const ctx = IntentContext(awaitingApproval: true);
    test('yes → approve', () => expect(e.parse('yes send it', ctx: ctx), isA<ApproveIntent>()));
    test('no → reject', () => expect(e.parse("no don't send", ctx: ctx), isA<RejectIntent>()));
    test('edit', () {
      final i = e.parse('change the message to I will come tomorrow', ctx: ctx);
      expect((i as EditMessageIntent).newText, 'I will come tomorrow');
    });
    test('stop still wins during approval', () => expect(e.parse('stop', ctx: ctx), isA<StopIntent>()));
    test('choice', () => expect((e.parse('the second one', ctx: const IntentContext(choiceCount: 3)) as ChooseOptionIntent).index, 1));
  });

  group('Approval gate binds to exact action', () {
    ApprovalRequest req(String content, {String recipient = 'tel:+919999999999'}) => ApprovalRequest(
        id: '1', actionType: 'whatsapp.send', title: 't', recipientId: recipient, content: content);

    test('cannot consume without approval', () {
      final g = ApprovalGate()..request(req('hi'));
      expect(g.consume('whatsapp.send', 'tel:+919999999999', 'hi'), isFalse);
    });
    test('approved exact action can be consumed once', () {
      final g = ApprovalGate()..request(req('hi'));
      g.approve();
      expect(g.consume('whatsapp.send', 'tel:+919999999999', 'hi'), isTrue);
      expect(g.consume('whatsapp.send', 'tel:+919999999999', 'hi'), isFalse);
    });
    test('changed content invalidates', () {
      final g = ApprovalGate()..request(req('hi'));
      g.approve();
      expect(g.consume('whatsapp.send', 'tel:+919999999999', 'hi!'), isFalse);
      expect(g.consume('whatsapp.send', 'tel:+919999999999', 'hi'), isFalse, reason: 'mismatch invalidates the approval');
    });
    test('changed recipient invalidates', () {
      final g = ApprovalGate()..request(req('hi'));
      g.approve();
      expect(g.consume('whatsapp.send', 'tel:+918888888888', 'hi'), isFalse);
    });
    test('new request replaces old approval', () {
      final g = ApprovalGate()..request(req('hi'));
      g.approve();
      g.request(req('hello'));
      expect(g.consume('whatsapp.send', 'tel:+919999999999', 'hi'), isFalse);
    });
  });

  group('Task state machine', () {
    test('happy path', () {
      for (final (a, b) in [
        (AgentState.understanding, AgentState.planning),
        (AgentState.planning, AgentState.running),
        (AgentState.running, AgentState.waitingForApproval),
        (AgentState.waitingForApproval, AgentState.running),
        (AgentState.running, AgentState.completed),
      ]) {
        expect(TaskStateMachine.canTransition(a, b), isTrue, reason: '$a→$b');
      }
    });
    test('completed is final', () => expect(TaskStateMachine.canTransition(AgentState.completed, AgentState.running), isFalse));
    test('cancelled is final', () => expect(TaskStateMachine.canTransition(AgentState.cancelled, AgentState.running), isFalse));
    test('interrupted can resume', () => expect(TaskStateMachine.canTransition(AgentState.interrupted, AgentState.running), isTrue));
    test('illegal throws', () => expect(() => TaskStateMachine.require(AgentState.completed, AgentState.paused), throwsA(isA<IllegalTransitionException>())));
  });

  group('Task control — STOP / PAUSE', () {
    test('abort interrupts a guarded long operation immediately', () async {
      final c = TaskControl();
      final never = Completer<int>().future;
      final f = c.guard(never);
      c.abort(AgentState.interrupted);
      await expectLater(f, throwsA(isA<TaskAbort>()));
    });
    test('pause blocks checkpoint until resume', () async {
      final c = TaskControl()..pause();
      var passed = false;
      final f = c.checkpoint().then((_) => passed = true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(passed, isFalse);
      c.resume();
      await f;
      expect(passed, isTrue);
    });
    test('resume after stop skips completed steps (no duplicate side effects)', () async {
      final snap = TaskSnapshot(
        id: 1, title: 't', kind: 'k', state: AgentState.running, route: TaskRoute.local,
        createdAt: DateTime.now(), updatedAt: DateTime.now(),
        steps: const [TaskStep(id: 'a', description: 'A'), TaskStep(id: 'b', description: 'B', irreversible: true)],
      );
      final tr = TaskTracker(snap, (_) {});
      var aRuns = 0;
      await tr.step('a', () async => ++aRuns);
      tr.control.abort(AgentState.interrupted);
      await expectLater(tr.step('b', () async => 1), throwsA(isA<TaskAbort>()));
      tr.reopenCancelled();
      await tr.step('a', () async => ++aRuns);
      await tr.step('b', () async => 1);
      expect(aRuns, 1);
      expect(tr.stepStatus('b'), StepStatus.done);
    });
  });

  group('Greeting', () {
    final g = GreetingGenerator();
    test('morning', () => expect(g.greet(now: DateTime(2026, 1, 1, 9)), startsWith('Good morning, sir')));
    test('afternoon', () => expect(g.greet(now: DateTime(2026, 1, 1, 14)), startsWith('Good afternoon, sir')));
    test('evening', () => expect(g.greet(now: DateTime(2026, 1, 1, 19)), startsWith('Good evening, sir')));
    test('night mentions still working', () => expect(g.greet(now: DateTime(2026, 1, 1, 22)), contains('sir')));
    test('does not repeat consecutively', () {
      final a = g.greet(now: DateTime(2026, 1, 1, 14));
      final b = g.greet(now: DateTime(2026, 1, 1, 14));
      expect(a == b, isFalse);
    });
  });
}

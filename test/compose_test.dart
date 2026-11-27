import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/core/intent/compose_detector.dart';
import 'package:jarvis/core/intent/local_intent.dart';
import 'package:jarvis/core/intent/local_intent_engine.dart';

void main() {
  final engine = LocalIntentEngine();
  LocalIntent run(String s) => ComposeDetector.upgrade(engine.parse(s), LocalIntentEngine.clean(s));

  SendMessageIntent msg(String s) {
    final i = run(s);
    expect(i, isA<SendMessageIntent>(), reason: s);
    return i as SendMessageIntent;
  }

  group('requests that need writing → OpenAI writes, user approves', () {
    test('explaining (was handed to the screen agent)', () {
      final i = msg("send a WhatsApp message to my manager explaining why I won't be coming today");
      expect(i.recipient, 'manager');
      expect(i.composeLong, isTrue);
      expect(i.message, isNull);
      expect(i.composeTopic, contains("why I won't be coming today"));
    });

    test('write a message to … saying … (was draft-only, never sent)', () {
      final i = msg("write a message to Kiran saying I won't come to office today");
      expect(i.recipient, 'Kiran');
      expect(i.composeLong, isTrue);
    });

    test('write a WhatsApp message to my team lead explaining …', () {
      expect(msg('write a WhatsApp message to my team lead explaining that I will be on leave tomorrow').recipient, 'team lead');
    });

    test('compose a long message to Amma telling her …', () {
      final i = msg('compose a long message to Amma telling her I reached safely and will call at night');
      expect(i.recipient, 'Amma');
      expect(i.composeLong, isTrue);
    });

    test('a polite message (recipient was read as "polite message to my manager")', () {
      final i = msg('send a polite message to my manager that I will be late by an hour');
      expect(i.recipient, 'manager');
      expect(i.composeLong, isTrue);
    });

    test('dictation + "write it properly" (was sent word for word)', () {
      final i = msg("tell Kiran on WhatsApp that I can't come today because I have a fever, write it properly");
      expect(i.recipient, 'Kiran');
      expect(i.composeLong, isTrue);
      expect(i.composeTopic, contains('fever')); // the facts go to the writer
    });

    test('a group, with "explain it professionally"', () {
      final i = msg('whatsapp the office group that I am working from home today, explain it professionally');
      expect(i.composeLong, isTrue);
      expect(i.isGroup, isTrue);
    });

    test('email: explaining (was handed to the screen agent)', () {
      final i = run('email pavan@example.com explaining why I missed the meeting');
      expect(i, isA<EmailIntent>());
      expect((i as EmailIntent).to, 'pavan@example.com');
      expect(i.body, isNull);
      expect(i.topic, contains('missed the meeting'));
      expect(i.topic, contains('Use only the facts')); // no invented reasons
    });

    test('email: write … asking for leave (recipient was "my manager asking")', () {
      final i = run('write an email to my manager asking for leave tomorrow') as EmailIntent;
      expect(i.to, 'manager');
      expect(i.topic, contains('leave tomorrow'));
    });
  });

  group('existing commands stay exactly as they were', () {
    test('plain dictation sends the exact words', () {
      final i = msg('message Rahul that I am late');
      expect(i.message, 'I am late');
      expect(i.composeTopic, isNull);
      expect(i.composeLong, isFalse);
    });

    test('"message X about Y" keeps the existing short writer', () {
      final i = msg('message Suresh about the project deadline');
      expect(i.composeTopic, 'the project deadline');
      expect(i.composeLong, isFalse);
    });

    test('email with dictated text is sent as said', () {
      final i = run('send an email to hr@example.com saying I need leave on Friday') as EmailIntent;
      expect(i.body, 'I need leave on Friday');
    });

    test('"draft a mail to … about …" keeps its existing topic', () {
      final i = run('draft a mail to ravi@example.com about the invoice delay') as EmailIntent;
      expect(i.to, 'ravi@example.com');
      expect(i.body, isNull);
    });

    test('documents without a recipient are still the writing assistant', () {
      expect(run('write a leave letter to submit tomorrow'), isA<WriteIntent>());
    });

    for (final s in [
      'ask chatgpt to write a message to my boss about leave',
      'set an alarm for 6 am',
      'call amma',
      'open whatsapp',
      'play believer on youtube',
    ]) {
      test('untouched: "$s"', () {
        expect(run(s).runtimeType, engine.parse(s).runtimeType);
      });
    }
  });
}

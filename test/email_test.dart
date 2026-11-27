import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/core/intent/local_intent.dart';
import 'package:jarvis/core/intent/local_intent_engine.dart';

void main() {
  final e = LocalIntentEngine();
  EmailIntent em(String s) => e.parse(s) as EmailIntent;

  test('the exact request', () {
    final i = em('go and compose new email to pavankumarhox56@gmail.com that saying hi');
    expect(i.to, 'pavankumarhox56@gmail.com');
    expect(i.body, 'hi');
  });
  test('spoken address', () {
    final i = em('compose a new email to pavankumarhox56 at gmail dot com saying hi there');
    expect(i.to, 'pavankumarhox56@gmail.com');
    expect(i.body, 'hi there');
  });
  test('subject + body', () {
    final i = em('send an email to rahul@example.com with subject meeting saying see you at 5');
    expect(i.subject, 'meeting');
    expect(i.body, 'see you at 5');
  });
  test('contact name + topic → AI writes it', () {
    final i = em('write an email to Rahul about tomorrow\'s leave');
    expect(i.to, 'Rahul');
    expect(i.topic, 'tomorrow\'s leave');
    expect(i.body, isNull);
  });
  test('short form', () => expect(em('email pavan@gmail.com saying good morning').body, 'good morning'));
  test('Leo, … please', () => expect(em('Leo, please send a mail to a@b.co saying ok').to, 'a@b.co'));
  test('WhatsApp still WhatsApp', () => expect(e.parse('send a whatsapp message to Rahul saying hi'), isA<SendMessageIntent>()));
  test('check my email is not compose', () => expect(e.parse('check my email'), isNot(isA<EmailIntent>())));
  test('address + "with my leave request" → address and topic', () {
    final i = em('send an email to hr@company.com with my leave request');
    expect(i.to, 'hr@company.com');
    expect(i.topic, 'my leave request');
  });
  test('"write a mail to HR and send it" → HR, AI writes it', () {
    final i = em('write a mail to HR and send it');
    expect(i.to, 'HR');
    expect(i.topic, isNull);
    expect(i.requiresAi, isTrue);
  });
  test('dictated email needs no AI', () => expect(em('email a@b.co saying hi').requiresAi, isFalse));
}

// Accuracy + speed benchmark for LEO's on-device understanding (rules → Naive Bayes → brain hand-off).
// Run:  flutter test test/benchmark_intent_test.dart --reporter expanded
// Writes build/benchmark_local.json. Phrases are held out: none is copied from the classifier's seed set.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/core/intent/local_classifier.dart';
import 'package:jarvis/core/intent/local_intent.dart';
import 'package:jarvis/core/intent/local_intent_engine.dart';
import 'package:jarvis/orchestrator/jarvis_orchestrator.dart';

/// (what the user says, acceptable routes). 'BRAIN' = should be handed to the cloud/phone brain
/// (several steps, mixed language, open questions) instead of being guessed locally.
const cases = <(String, List<String>)>[
  // open apps
  ('open whatsapp', ['OpenAppIntent']),
  ('leo open instagram please', ['OpenAppIntent']),
  ('can you launch the calculator', ['OpenAppIntent']),
  ('open google maps', ['OpenAppIntent', 'NavigateIntent']),
  ('open settings', ['OpenAppIntent', 'SettingsPanelIntent']),
  ('open spotify', ['OpenAppIntent']),
  // calls
  ('call amma', ['CallIntent']),
  ('please call rahul', ['CallIntent']),
  ('give dad a call', ['CallIntent']),
  ('ring kiran now', ['CallIntent']),
  ('video call pavan on whatsapp', ['CallIntent']),
  // messages
  ('send a whatsapp message to rahul saying i will be late', ['SendMessageIntent']),
  ('message amma that i reached home', ['SendMessageIntent']),
  ('text kiran see you at 5', ['SendMessageIntent']),
  ('tell suresh on whatsapp that the class is cancelled', ['SendMessageIntent']),
  ('any new messages on whatsapp', ['CheckMessagesIntent', 'ReadChatIntent']),
  ('read my latest messages', ['CheckMessagesIntent', 'ReadChatIntent']),
  // media
  ('play believer on youtube', ['PlayMediaIntent']),
  ('play some arijit singh songs', ['PlayMediaIntent']),
  ('play kesariya on spotify', ['PlayMediaIntent']),
  ('pause the music', ['MediaControlIntent']),
  ('next song', ['MediaControlIntent']),
  ('pause the music in spotify', ['MediaControlIntent']),
  ('resume the song', ['MediaControlIntent', 'ResumeIntent']),
  // alarms, timers, reminders
  ('set an alarm for 6:30 am', ['SetAlarmIntent']),
  ('wake me up at 7 tomorrow', ['SetAlarmIntent']),
  ('set a timer for 10 minutes', ['SetTimerIntent']),
  ('remind me to drink water at 5 pm', ['SetAlarmIntent', 'SetTimerIntent']),
  ('turn off my 6 am alarm', ['DismissAlarmIntent']),
  ('show my reminders', ['ListRemindersIntent']),
  // time/date/small talk
  ('what time is it', ['TellTimeIntent']),
  ('what is the time now leo', ['TellTimeIntent']),
  ("what's the date today", ['TellDateIntent']),
  ('which day is it today', ['TellDateIntent']),
  ('hello leo', ['GreetingIntent']),
  ('how are you', ['HowAreYouIntent']),
  ('thank you', ['ThanksIntent']),
  // phone controls
  ('turn on the flashlight', ['FlashlightIntent']),
  ('switch off torch', ['FlashlightIntent']),
  ('take a selfie', ['CameraIntent']),
  ('turn on bluetooth', ['SettingsPanelIntent', 'PhoneTaskIntent']),
  ('turn on wifi', ['SettingsPanelIntent', 'PhoneTaskIntent']),
  // navigation, web, files
  ('navigate to mg road', ['NavigateIntent']),
  ('directions to the airport', ['NavigateIntent']),
  ('search google for best laptops under 50000', ['WebSearchIntent']),
  ('open wikipedia', ['OpenWebsiteIntent', 'OpenAppIntent']),
  ('search for black holes on wikipedia', ['OpenWebsiteIntent']),
  ('open my resume pdf', ['FindFileIntent']),
  ('find the pdf named invoice', ['FindFileIntent']),
  ('show my photos from yesterday', ['FindFileIntent', 'OpenAppIntent', 'PhoneTaskIntent', 'BRAIN']),
  // install / shop / meetings / email
  ('install telegram', ['InstallAppIntent']),
  ('download zomato from play store', ['InstallAppIntent']),
  ('search for earbuds on amazon', ['ShopIntent']),
  ('add usb c cable to cart on amazon', ['ShopIntent']),
  ('compare iphone 15 on flipkart', ['ShopIntent']),
  ('schedule a zoom meeting tomorrow at 5 pm with kiran', ['ScheduleMeetingIntent']),
  ('start a google meet', ['StartMeetIntent']),
  ('compose a new email to ravi@example.com saying hi', ['EmailIntent']),
  // screen / apps
  ('click battery', ['ScreenCommandIntent']),
  ('tap on the search button', ['ScreenCommandIntent']),
  ('ask chatgpt to write a poem about rain', ['AskAppIntent']),
  ('ask claude to make a ppt about blood', ['AskAppIntent']),
  // control
  ('stop', ['StopIntent', 'StopEverythingIntent']),
  ('pause the task', ['PauseIntent']),
  ('continue', ['ResumeIntent', 'ContinueWhereStoppedIntent']),
  ('cancel this', ['CancelTaskIntent']),
  ('what are you doing', ['StatusIntent']),
  // memory / writing
  ('remember that my locker code is near the window', ['RememberIntent']),
  ('what did i tell you about my locker', ['RecallIntent']),
  ('write a leave letter to my manager', ['WriteIntent']),
  // knowledge → brain
  ('who won the 2011 cricket world cup', ['KnowledgeIntent', 'BRAIN']),
  ('explain how vaccines work', ['KnowledgeIntent', 'BRAIN', 'WriteIntent']),
  // multi-step / mixed language → brain plans it
  ('open youtube and play lofi then set a timer for 20 minutes', ['BRAIN']),
  ('mujhe kal subah 6 baje uthana aur amma ko message karo ki main late hoon', ['BRAIN']),
  ('whatsapp kholo aur rahul ko bolo main aa raha hoon', ['BRAIN', 'SendMessageIntent']),
  ('start the stopwatch', ['BRAIN', 'PhoneTaskIntent', 'OpenAppIntent']),
  ('turn on do not disturb and then call amma', ['BRAIN']),
  ('find a good biryani place nearby and navigate there', ['BRAIN', 'NavigateIntent']),
  ('message rahul the meeting moved to 4 and also email the same to kiran', ['BRAIN']),
  ('naale 7 gantege alarm idu', ['BRAIN', 'SetAlarmIntent']),
];

String route(LocalIntentEngine engine, LocalIntentClassifier clf, String said) {
  final intent = engine.parse(said);
  if (intent is! UnknownIntent) return intent.runtimeType.toString();
  final cleaned = LocalIntentEngine.clean(said);
  if (JarvisOrchestrator.looksComplex(cleaned)) return 'BRAIN';
  final guess = clf.classify(cleaned);
  return guess == null ? 'BRAIN' : guess.runtimeType.toString();
}

void main() {
  test('LEO on-device understanding benchmark', () {
    final engine = LocalIntentEngine();
    final clf = LocalIntentClassifier()..train();

    // Warm-up (JIT), then time each phrase 50× and keep the mean.
    for (final (s, _) in cases) {
      route(engine, clf, s);
    }
    final rows = <Map<String, Object>>[];
    final micros = <double>[];
    var correct = 0;
    for (final (said, ok) in cases) {
      final sw = Stopwatch()..start();
      late String got;
      for (var i = 0; i < 50; i++) {
        got = route(engine, clf, said);
      }
      final us = sw.elapsedMicroseconds / 50;
      micros.add(us);
      final pass = ok.contains(got);
      if (pass) correct++;
      rows.add({'said': said, 'expected': ok.join(' | '), 'got': got, 'pass': pass, 'micros': us});
    }
    micros.sort();
    double pct(double p) => micros[((micros.length - 1) * p).round()];
    final local = rows.where((r) => r['got'] != 'BRAIN').length;
    final summary = {
      'cases': cases.length,
      'correct': correct,
      'accuracy': correct / cases.length,
      'handled_on_device': local,
      'sent_to_brain': cases.length - local,
      'latency_ms_mean': micros.reduce((a, b) => a + b) / micros.length / 1000,
      'latency_ms_p50': pct(0.5) / 1000,
      'latency_ms_p95': pct(0.95) / 1000,
      'latency_ms_max': micros.last / 1000,
    };
    Directory('build').createSync(recursive: true);
    File('build/benchmark_local.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert({'summary': summary, 'rows': rows}));
    // ignore: avoid_print
    print(const JsonEncoder.withIndent(' ').convert(summary));
    for (final r in rows.where((r) => r['pass'] != true)) {
      // ignore: avoid_print
      print('MISS  "${r['said']}"  expected ${r['expected']}  got ${r['got']}');
    }
  });
}

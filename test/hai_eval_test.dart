// Human–Agent Interaction evaluation: LEO vs a conventional prompt-and-wait baseline.
//   flutter test test/hai_eval_test.dart --reporter expanded      → also writes build/hai_eval.json
//
// WHAT IS COMPARED. Both agents get the same request on the same (simulated) phone and use LEO's
// real understanding code (rules, on-device model, contact/app matching). They differ only in the
// interaction model — the thing Problem Statement 3 asks about:
//   • Baseline (prompt-and-wait): acts on its first interpretation, never asks, never asks for an
//     OK, can't be interrupted until it finishes, and only reports the end result.
//   • LEO: detects ambiguity and asks ONE question, confirms before anything is sent, can be
//     stopped/paused at any step, and shows every step.
// The phone is simulated (contacts, apps) so results are reproducible; all decisions come from the
// same functions the app runs (lib/core/ambiguity.dart, AppResolver.match, the intent engine).
// Offline mode: the cloud planner is not used here (it is measured separately, live).
//
// HOW EACH CASE IS LABELLED. By hand, before running: is the request ambiguous for a person who can
// see this phone's contacts and apps? And what did the user actually mean? When an agent asks, the
// simulated user answers truthfully with what they meant.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/core/ambiguity.dart';
import 'package:jarvis/core/approval/approval_gate.dart';
import 'package:jarvis/core/intent/compose_detector.dart';
import 'package:jarvis/core/intent/local_classifier.dart';
import 'package:jarvis/core/intent/local_intent.dart';
import 'package:jarvis/core/intent/local_intent_engine.dart';
import 'package:jarvis/core/task/task_models.dart';
import 'package:jarvis/core/task/task_runner.dart';
import 'package:jarvis/device/app_resolver.dart';
import 'package:jarvis/device/device_bridge.dart';
import 'package:jarvis/orchestrator/jarvis_orchestrator.dart';
import 'package:jarvis/voice/language.dart';

// ------------------------------------------------------------------ the simulated phone
const contacts = <ContactMatch>[
  ContactMatch('Rahul Sharma', ['9800000001'], true),
  ContactMatch('Rahul Verma', ['9800000002'], true),
  ContactMatch('Rahul Iyer', ['9800000003'], false),
  ContactMatch('Kiran', ['9811111111', '9822222222'], true),
  ContactMatch('Amma', ['9833333333'], true),
  ContactMatch('Appa', ['9844444444'], true),
  ContactMatch('Suresh Kumar', ['9855555555'], true),
  ContactMatch('Priya', ['9866666666'], true),
  ContactMatch('Priya Office', ['08012345678'], false),
  ContactMatch('Deepak', ['9877777777'], true),
];
const apps = <InstalledApp>[
  InstalledApp('WhatsApp', 'com.whatsapp'),
  InstalledApp('WhatsApp Business', 'com.whatsapp.w4b'),
  InstalledApp('YouTube', 'com.google.android.youtube'),
  InstalledApp('YouTube Music', 'com.google.android.apps.youtube.music'),
  InstalledApp('Instagram', 'com.instagram.android'),
  InstalledApp('Calculator', 'com.sec.android.app.popupcalculator'),
  InstalledApp('Calculator Vault', 'com.calculator.vault'),
  InstalledApp('Samsung Notes', 'com.samsung.android.app.notes'),
  InstalledApp('Keep Notes', 'com.google.android.keep'),
  InstalledApp('Spotify', 'com.spotify.music'),
  InstalledApp('Clock', 'com.sec.android.app.clockpackage'),
];

/// Android's contact search: name contains the query; then relation words ("mother" → Amma).
List<ContactMatch> search(String name) {
  final q = name.toLowerCase().trim();
  final hit = contacts.where((c) => c.name.toLowerCase().contains(q)).toList();
  if (hit.isNotEmpty) return hit;
  final aliases = Lang.relationAliases(q);
  return contacts.where((c) => aliases.any((a) => JarvisOrchestrator.nameHasWord(c.name, a))).toList();
}

// ------------------------------------------------------------------ the scenarios
class Sc {
  final String said;
  final bool ambiguous; // hand label
  final String meant; // what the user actually wanted (the correct final action)
  const Sc(this.said, this.ambiguous, this.meant);
}

const scenarios = <Sc>[
  // ---- ambiguous: several people / numbers / apps fit
  Sc('call rahul', true, 'call:Rahul Verma:9800000002'),
  Sc('message rahul that i am on my way', true, 'msg:Rahul Sharma:9800000001'),
  Sc('whatsapp rahul saying the cab is here', true, 'msg:Rahul Verma:9800000002'),
  Sc('call kiran', true, 'call:Kiran:9822222222'),
  Sc('text kiran that the meeting moved to 4', true, 'msg:Kiran:9811111111'),
  Sc('open notes', true, 'open:Keep Notes'),
  Sc('open calc', true, 'open:Calculator'),
  // ---- ambiguous: a required detail is missing
  Sc('set an alarm', true, 'alarm'),
  Sc('wake me up tomorrow', true, 'alarm'),
  Sc('remind me to call the bank', true, 'reminder'),
  Sc('message deepak', true, 'msg:Deepak:9877777777'),
  Sc('send a whatsapp to priya', true, 'msg:Priya:9866666666'),
  // ---- ambiguous: too little said to know the action
  Sc('rahul', true, 'msg:Rahul Iyer:9800000003'),
  Sc('dad', true, 'call:Appa:9844444444'),
  Sc('mom', true, 'call:Amma:9833333333'),
  Sc('news', true, 'KnowledgeIntent'),
  Sc('something relaxing', true, 'PlayMediaIntent'),
  // ---- clear: should be done straight away, no questions
  Sc('call amma', false, 'call:Amma:9833333333'),
  Sc('call mother', false, 'call:Amma:9833333333'),
  Sc('call rahul verma', false, 'call:Rahul Verma:9800000002'),
  Sc('call priya', false, 'call:Priya:9866666666'),
  Sc('call 9876543210', false, 'call:9876543210:9876543210'),
  Sc('message suresh that i will be late', false, 'msg:Suresh Kumar:9855555555'),
  Sc('message rahul sharma saying see you at 5', false, 'msg:Rahul Sharma:9800000001'),
  Sc('whatsapp deepak saying happy birthday', false, 'msg:Deepak:9877777777'),
  Sc('text appa i reached home', false, 'msg:Appa:9844444444'),
  Sc('open whatsapp', false, 'open:WhatsApp'),
  Sc('open youtube', false, 'open:YouTube'),
  Sc('open calculator', false, 'open:Calculator'),
  Sc('open instagram', false, 'open:Instagram'),
  Sc('set an alarm for 6:30 am', false, 'alarm'),
  Sc('remind me to drink water at 5 pm', false, 'reminder'),
  Sc('set a timer for 10 minutes', false, 'SetTimerIntent'),
  Sc('play believer on youtube', false, 'PlayMediaIntent'),
  Sc('what time is it', false, 'TellTimeIntent'),
  Sc('turn on the flashlight', false, 'FlashlightIntent'),
  Sc('hear arijit', false, 'PlayMediaIntent'),
  Sc('pause', false, 'PauseIntent'),
];

// ------------------------------------------------------------------ one run of one agent
class Run {
  String outcome = 'nothing';
  int questions = 0; // clarifying questions (not approvals)
  int approvals = 0;
  bool failed = false;
  final kinds = <String>[];
  bool get irreversible => outcome.startsWith('call:') || outcome.startsWith('msg:');
}

final engine = LocalIntentEngine();
final model = LocalIntentClassifier()..train();

const _labelAction = {
  'call': 'call:', 'send_message': 'msg:', 'play_media': 'PlayMediaIntent', 'check_messages': 'CheckMessagesIntent',
  'open_app': 'open:', 'time': 'TellTimeIntent', 'date': 'TellDateIntent', 'status': 'StatusIntent',
  'greeting': 'GreetingIntent', 'stop': 'StopIntent', 'pause': 'PauseIntent', 'resume': 'ResumeIntent', 'cancel': 'CancelTaskIntent',
};

/// [interactive] = LEO's interaction model; false = the prompt-and-wait baseline.
Run runAgent(Sc sc, {required bool interactive}) {
  final r = Run();
  final clean = LocalIntentEngine.clean(sc.said);
  var intent = ComposeDetector.upgrade(engine.parse(sc.said), clean);

  if (intent is UnknownIntent) {
    final top = model.predict(clean);
    final guess = model.classify(clean);
    final best = top.isEmpty ? null : top.first.$1;
    bool confirm(String kind) {
      // "Did you want me to …?" — the user says yes only if that is what they meant.
      r.questions++;
      r.kinds.add(kind);
      return best != null && sc.meant.startsWith(_labelAction[best] ?? '#');
    }

    if (!interactive) {
      final g = model.classify(clean, minConfidence: 0); // acts on its top guess, however unsure
      if (g == null) return r..failed = true;
      intent = g;
    } else if (guess != null && best != null && Ambiguity.riskyGuess(best, clean)) {
      if (!confirm('riskyGuess')) return r..failed = true;
      intent = guess;
    } else if (guess != null) {
      intent = guess;
    } else if (Ambiguity.isUnsure(top)) {
      if (!confirm('unsureIntent')) return r..failed = true;
      final g = model.classify(clean, minConfidence: 0);
      if (g == null) return r..failed = true;
      intent = g;
    } else {
      return r..failed = true; // offline and not understood
    }
  }

  String? meantPart(int i) => sc.meant.split(':').length > i ? sc.meant.split(':')[i] : null;

  ContactMatch? pickContact(List<ContactMatch> pool) {
    if (pool.isEmpty) return null;
    if (pool.length == 1 || !interactive) return pool.first;
    r.questions++;
    r.kinds.add('severalContacts');
    return pool.where((c) => c.name == meantPart(1)).firstOrNull; // the user picks who they meant
  }

  String pickNumber(ContactMatch c) {
    if (c.numbers.length == 1 || !interactive) return c.numbers.first;
    r.questions++;
    r.kinds.add('severalNumbers');
    return c.numbers.contains(meantPart(2)) ? meantPart(2)! : c.numbers.first;
  }

  switch (intent) {
    case CallIntent(:final name):
      final digits = name.replaceAll(RegExp(r'[^0-9+]'), '');
      if (digits.length >= 6) return r..outcome = 'call:$digits:$digits';
      final c = pickContact(Ambiguity.callCandidates(name, search(name)));
      if (c == null) return r..failed = true;
      r.outcome = 'call:${c.name}:${pickNumber(c)}'; // calls are placed directly (no approval) in LEO too
    case SendMessageIntent(:final recipient, :final message, :final composeTopic):
      final c = pickContact(Ambiguity.messageCandidates(recipient, search(recipient)));
      if (c == null) return r..failed = true;
      final number = pickNumber(c);
      if ((message == null || message.isEmpty) && composeTopic == null) {
        if (!interactive) return r..failed = true; // nothing to send
        r.questions++;
        r.kinds.add('missingMessage');
      }
      if (interactive) r.approvals++; // "Shall I send … to …?"
      r.outcome = 'msg:${c.name}:$number';
    case OpenAppIntent(:final appName):
      final m = AppResolver.match(appName, apps);
      if (m.isEmpty) return r..failed = true;
      var a = m.first;
      if (m.length > 1 && interactive) {
        r.questions++;
        r.kinds.add('severalApps');
        a = m.firstWhere((x) => x.label == meantPart(1), orElse: () => m.first);
      }
      r.outcome = 'open:${a.label}';
    case SetAlarmIntent(:final text, :final label):
      if (Ambiguity.needsTime(text)) {
        if (!interactive) return r..failed = true; // no time → can't set it
        r.questions++;
        r.kinds.add('missingTime');
      }
      r.outcome = label == null ? 'alarm' : 'reminder';
    default:
      r.outcome = intent.runtimeType.toString();
  }
  return r;
}

// ------------------------------------------------------------------ scoring
class Score {
  int n = 0, correct = 0, wrongActions = 0, wrongIrreversible = 0, turns = 0, questions = 0;
  int tp = 0, fn = 0, fp = 0, tn = 0, resolved = 0;

  void add(Sc sc, Run r) {
    n++;
    final ok = !r.failed && r.outcome == sc.meant;
    if (ok) correct++;
    if (!r.failed && !ok) {
      wrongActions++;
      if (r.irreversible) wrongIrreversible++;
    }
    // Effort = what the user had to say: the request, each answer, each OK — plus, when the agent
    // failed or did the wrong thing, noticing it and asking again (2 turns, assumed to then succeed).
    turns += 1 + r.questions + r.approvals + (ok ? 0 : 2);
    questions += r.questions;
    final asked = r.questions > 0;
    if (sc.ambiguous && asked) tp++;
    if (sc.ambiguous && !asked) fn++;
    if (!sc.ambiguous && asked) fp++;
    if (!sc.ambiguous && !asked) tn++;
    if (sc.ambiguous && ok) resolved++;
  }

  int get amb => tp + fn;
  double pct(int a, int b) => b == 0 ? 0 : 100 * a / b;
  Map<String, Object> toJson() => {
        'cases': n,
        'task_success_pct': pct(correct, n),
        'wrong_actions': wrongActions,
        'wrong_calls_or_messages_to_people': wrongIrreversible,
        'user_turns_per_task': turns / n,
        'ambiguity_detection_recall_pct': pct(tp, amb),
        'ambiguity_detection_precision_pct': pct(tp, tp + fp),
        'false_questions_on_clear_requests_pct': pct(fp, fp + tn),
        'ambiguous_resolved_correctly_pct': pct(resolved, amb),
        'clear_done_without_questions_pct': pct(tn, fp + tn),
      };
}

void main() {
  test('HAI evaluation: LEO vs prompt-and-wait baseline', () async {
    final leo = Score(), base = Score();
    final rows = <Map<String, Object?>>[];
    for (final sc in scenarios) {
      final l = runAgent(sc, interactive: true);
      final b = runAgent(sc, interactive: false);
      leo.add(sc, l);
      base.add(sc, b);
      rows.add({
        'said': sc.said,
        'ambiguous': sc.ambiguous,
        'meant': sc.meant,
        'leo': l.failed ? 'FAILED' : l.outcome,
        'leo_questions': l.kinds,
        'leo_ok': !l.failed && l.outcome == sc.meant,
        'baseline': b.failed ? 'FAILED' : b.outcome,
        'baseline_ok': !b.failed && b.outcome == sc.meant,
      });
    }

    // ---- control: how fast does STOP take effect during a slow step (e.g. a 3 s network call)?
    final control = TaskControl();
    final sw = Stopwatch();
    final slow = Future<String>.delayed(const Duration(seconds: 3), () => 'done');
    final running = control.guard(slow);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    sw.start();
    control.abort(AgentState.interrupted);
    var stopped = false;
    try {
      await running;
    } on TaskAbort {
      stopped = true;
    }
    sw.stop();
    final stopMs = sw.elapsedMicroseconds / 1000;

    // ---- control: nothing is sent without an OK for exactly that recipient and text.
    ApprovalRequest req(String text, String to) =>
        ApprovalRequest(id: '1', actionType: 'whatsapp.send', title: 't', recipientId: to, content: text);
    final gate = ApprovalGate()..request(req('hi', 'tel:1'));
    final blockedWithoutOk = !gate.consume('whatsapp.send', 'tel:1', 'hi');
    gate.approve();
    final blockedIfChanged = !gate.consume('whatsapp.send', 'tel:1', 'hi!');

    final out = {
      'leo': leo.toJson(),
      'baseline': base.toJson(),
      'control': {
        'stop_takes_effect_ms_leo': stopMs,
        'stop_takes_effect_ms_baseline': 'waits for the step to finish (2800 ms left in this test)',
        'nothing_sent_without_ok': blockedWithoutOk,
        'changed_text_needs_new_ok': blockedIfChanged,
      },
      'rows': rows,
    };
    Directory('build').createSync(recursive: true);
    File('build/hai_eval.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert(out));

    String f(num v) => v.toStringAsFixed(v is int ? 0 : 1);
    print('\n${'metric'.padRight(44)}${'LEO'.padLeft(10)}${'baseline'.padLeft(12)}');
    for (final k in leo.toJson().keys) {
      print('${k.padRight(44)}${f(leo.toJson()[k] as num).padLeft(10)}${f(base.toJson()[k] as num).padLeft(12)}');
    }
    print('STOP takes effect after: ${stopMs.toStringAsFixed(2)} ms (baseline: waits ~2800 ms)');
    print('nothing sent without OK: $blockedWithoutOk · changed text needs new OK: $blockedIfChanged\n');
    for (final r in rows) {
      if (r['leo_ok'] != true || r['baseline_ok'] != true) {
        print('${r['leo_ok'] == true ? 'ok  ' : 'MISS'} LEO  ${r['baseline_ok'] == true ? 'ok  ' : 'MISS'} base  '
            '"${r['said']}"  meant ${r['meant']}  · LEO ${r['leo']} ${r['leo_questions']}  · base ${r['baseline']}');
      }
    }

    expect(stopped, isTrue);
    expect(blockedWithoutOk && blockedIfChanged, isTrue);
    expect(leo.correct, greaterThan(base.correct));
  });
}

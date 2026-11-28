// Live check of LEO's cloud planner on free-form requests (needs OPENAI_API_KEY in lib/.env):
// does it ask ONE clarifying question when a request is truly ambiguous, act directly when it is
// clear, and use the conversation so far to resolve "it / him / her / that"?
//   dart run tool/ambiguity_check.dart        → also writes build/ambiguity_live.json
// Same model, prompt and settings as the app (OpenAiBrain.interpret).
import 'dart:convert';
import 'dart:io';

import 'package:jarvis/ai/openai_brain.dart';
import 'package:jarvis/core/privacy_filter.dart';

class Case {
  final String said;
  final List<String> context; // recent conversation shown to the planner
  final bool ambiguous; // hand label
  final String? mustMention; // for context cases: what "it/him/her/that" refers to
  const Case(this.said, this.ambiguous, {this.context = const [], this.mustMention});
}

const cases = [
  // ---- ambiguous: nothing tells LEO what "it / him / them / the thing" is
  Case('send it to him', true),
  Case('call her back', true),
  Case('do that again', true),
  Case('book it', true),
  Case('message them', true),
  Case('remind me about the thing', true),
  Case('order the usual', true),
  Case('play that song from yesterday', true),
  // ---- the same words, but the conversation makes them clear
  Case('send it to him', false,
      context: ['User: write a birthday wish for Rahul', 'LEO: Here it is: "Happy birthday Rahul, have a great year!"'],
      mustMention: 'rahul'),
  Case('call her back', false, context: ['LEO: You have a missed call from Priya.'], mustMention: 'priya'),
  Case('do that again', false, context: ['User: set an alarm for 6 am', 'LEO: Alarm set for 6:00 AM, sir.'], mustMention: '6'),
  // ---- clear on their own (several steps, questions, everyday tasks)
  Case('open youtube and play lofi music', false),
  Case('call amma and then set an alarm for 7 am', false),
  Case('message suresh that i am running late and then open maps', false),
  Case('turn on wifi and bluetooth', false),
  Case('who won the last ipl', false),
  Case('what is the capital of australia', false),
  Case('play something relaxing', false),
];

Future<void> main() async {
  final key = File('lib/.env')
      .readAsLinesSync()
      .map((l) => RegExp(r'^\s*OPENAI_API_KEY\s*=\s*(\S+)').firstMatch(l)?.group(1))
      .whereType<String>()
      .first
      .replaceAll(RegExp('''["']'''), '');
  final brain = OpenAiBrain();
  var tp = 0, fn = 0, fp = 0, tn = 0, ctxOk = 0, ctxN = 0;
  final rows = <Map<String, Object?>>[];
  for (final c in cases) {
    final red = PrivacyFilter.redact(c.said);
    final r = await brain.interpret(apiKey: key, model: 'gpt-4o-mini', utterance: red.text, recentTurns: c.context);
    final asked = r?.clarify != null;
    if (c.ambiguous && asked) tp++;
    if (c.ambiguous && !asked) fn++;
    if (!c.ambiguous && asked) fp++;
    if (!c.ambiguous && !asked) tn++;
    var resolved = true;
    if (c.mustMention != null) {
      ctxN++;
      resolved = !asked && (r?.commands.join(' ').toLowerCase().contains(c.mustMention!) ?? false);
      if (resolved) ctxOk++;
    }
    final ok = asked == c.ambiguous && resolved;
    final did = asked ? 'ASKS: ${r!.clarify}' : (r?.commands.isNotEmpty == true ? 'DOES: ${r!.commands.join(' → ')}' : 'ANSWERS: ${r?.answer}');
    stdout.writeln('${ok ? 'PASS' : 'FAIL'}  ${c.ambiguous ? '[ambiguous]' : '[clear]    '} "${c.said}"'
        '${c.context.isEmpty ? '' : '  (with context)'}\n      $did  [${r?.latencyMs} ms]');
    rows.add({'said': c.said, 'context': c.context, 'ambiguous': c.ambiguous, 'asked': asked, 'ok': ok, 'result': did});
  }
  double pct(int a, int b) => b == 0 ? 0 : 100 * a / b;
  final summary = {
    'cases': cases.length,
    'detection_recall_pct': pct(tp, tp + fn),
    'detection_precision_pct': pct(tp, tp + fp),
    'false_questions_on_clear_pct': pct(fp, fp + tn),
    'context_resolved_pct': pct(ctxOk, ctxN),
  };
  stdout.writeln('\n$summary');
  Directory('build').createSync(recursive: true);
  File('build/ambiguity_live.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert({'summary': summary, 'rows': rows}));
  exit(0);
}

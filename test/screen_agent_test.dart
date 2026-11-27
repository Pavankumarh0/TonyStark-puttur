import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/agent/screen_agent.dart';
import 'package:jarvis/ai/openai_brain.dart';
import 'package:jarvis/device/app_resolver.dart';
import 'package:jarvis/device/device_bridge.dart';
import 'package:jarvis/orchestrator/jarvis_orchestrator.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Fake phone: a scripted list of screens; records actions.
class FakePhone extends DeviceBridge {
  final List<String> screens;
  int screenIdx = 0;
  final acts = <String>[];
  FakePhone(this.screens);

  @override
  Future<Map<String, dynamic>> screenDump({int max = 70, bool skipOwn = false}) async =>
      {'ok': true, 'package': 'com.example.chat', 'screen': screens[screenIdx.clamp(0, screens.length - 1)]};

  @override
  Future<Map<String, dynamic>> screenAct(String type, {int? index, String? text, String? dir, String? package}) async {
    acts.add('$type${index == null ? '' : ' [$index]'}${text == null ? '' : ' "$text"'}');
    if (screenIdx < screens.length - 1) screenIdx++;
    return {'ok': true};
  }

  @override
  Future<bool> isBlockedApp(String pkg) async => false;

  @override
  Future<List<InstalledApp>> launchableApps() async => const [InstalledApp('Chat', 'com.example.chat')];
}

/// Fake model: replays scripted tool calls; records what it was sent.
class ScriptedBrain extends OpenAiBrain {
  final List<List<(String, Map<String, dynamic>)>> script;
  int turn = 0;
  final sent = <List<Map<String, dynamic>>>[];
  ScriptedBrain(this.script);

  @override
  Future<
      ({
        Map<String, dynamic> message,
        List<({String id, String name, Map<String, dynamic> args})> calls,
        String text,
        int? input,
        int? output,
        int? cached,
        int ms
      })> chatTools({
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    int maxTokens = 300,
  }) async {
    sent.add([for (final m in messages) Map<String, dynamic>.from(m)]);
    final calls = [
      for (final (i, c) in script[turn].indexed) (id: 't$turn$i', name: c.$1, args: c.$2),
    ];
    turn++;
    return (
      message: <String, dynamic>{
        'role': 'assistant',
        'content': null,
        'tool_calls': [
          for (final c in calls) {'id': c.id, 'type': 'function', 'function': {'name': c.name, 'arguments': '{}'}}
        ],
      },
      calls: calls,
      text: '',
      input: 100,
      output: 10,
      cached: 0,
      ms: 1,
    );
  }
}

ScreenAgentHooks hooks({
  bool approveAnswer = true,
  List<String>? approvals,
  Future<void> Function()? checkpoint,
}) =>
    ScreenAgentHooks(
      checkpoint: checkpoint ?? () async {},
      approve: (app, button, typed) async {
        approvals?.add('$button|${typed ?? ''}');
        return approveAnswer;
      },
      askUser: (q) async => 'the first one',
      onStep: (s, {index, warn = false}) {},
      onUsage: (i, o, c, ms, sent) {},
      isSensitive: JarvisOrchestrator.isSensitiveLabel,
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const search = '[0] EditText "Search" (tap,input)\n[1] Button "Go" (tap)';
  const results = '[0] Text "3 results for cats" ()\n[1] Button "Cats video" (tap)';

  test('success is rejected until the result was seen on screen', () async {
    final phone = FakePhone([search]);
    final brain = ScriptedBrain([
      [('open_app', {'app': 'Chat'})],
      [('finish_task', {'status': 'success', 'message': 'Opened'})], // nothing looked at yet → refused
      [('get_screen', {})],
      [('finish_task', {'status': 'success', 'message': 'Opened Chat'})],
    ]);
    final agent = ScreenAgent(device: phone, apps: AppResolver(phone), brain: brain, apiKey: 'k', model: 'm', hooks: hooks());
    final r = await agent.run('open chat');
    expect(r.status, 'success');
    expect(r.message, 'Opened Chat');
    expect(brain.turn, 4);
    expect(brain.sent[2].lastWhere((m) => m['role'] == 'tool')['content'], contains('Not verified'));
  });

  test('each action returns the new screen (one model call per action)', () async {
    final phone = FakePhone([search, results]);
    final brain = ScriptedBrain([
      [('get_screen', {})],
      [('act', {'action': 'tap', 'index': 1})],
      [('finish_task', {'status': 'success', 'message': 'ok'})],
    ]);
    final r = await ScreenAgent(device: phone, apps: AppResolver(phone), brain: brain, apiKey: 'k', model: 'm', hooks: hooks()).run('g');
    expect(r.status, 'success');
    expect(brain.sent[2].lastWhere((m) => m['role'] == 'tool')['content'], contains('3 results for cats'));
  });

  test('an approved send is confirmed by code from the screen', () async {
    const typed = '[0] Text "Rahul" ()\n[1] EditText "see you at 5" (tap,input)\n[2] ImageButton "Send" (tap)';
    const sent = '[0] Text "Rahul" ()\n[1] Text "see you at 5 | 11:40" ()\n[2] EditText "Message" (tap,input)';
    final phone = FakePhone([typed, typed, sent]);
    phone.screenIdx = 0;
    final brain = ScriptedBrain([
      [('get_screen', {})],
      [('act', {'action': 'type', 'index': 1, 'text': 'see you at 5'})],
      [('act', {'action': 'tap', 'index': 2})],
    ]);
    final r = await ScreenAgent(device: phone, apps: AppResolver(phone), brain: brain, apiKey: 'k', model: 'm', hooks: hooks()).run('send');
    expect(r.status, 'success');
    expect(r.message, contains('see you at 5'));
    expect(brain.turn, 3); // no extra model calls after the send
  });

  test('sensitive tap waits for approval; "no" means it is never pressed', () async {
    const chat = '[0] EditText "Message" (tap,input)\n[1] ImageButton "Send" (tap)';
    final phone = FakePhone([chat, chat]);
    final approvals = <String>[];
    final brain = ScriptedBrain([
      [('get_screen', {})],
      [('act', {'action': 'type', 'index': 0, 'text': 'hello'})],
      [('get_screen', {})],
      [('act', {'action': 'tap', 'index': 1})],
    ]);
    final agent = ScreenAgent(
        device: phone, apps: AppResolver(phone), brain: brain, apiKey: 'k', model: 'm', hooks: hooks(approveAnswer: false, approvals: approvals));
    final r = await agent.run('send hello');
    expect(r.status, 'declined');
    expect(approvals, ['Send|hello']); // asked about exactly this button + text
    expect(phone.acts.where((a) => a.startsWith('tap')), isEmpty);
  });

  test('only the latest screen is sent to the model', () async {
    final phone = FakePhone([search, results, results]);
    final brain = ScriptedBrain([
      [('get_screen', {})],
      [('act', {'action': 'tap', 'index': 1})],
      [('get_screen', {})],
      [('finish_task', {'status': 'failed', 'message': 'x'})],
    ]);
    await ScreenAgent(device: phone, apps: AppResolver(phone), brain: brain, apiKey: 'k', model: 'm', hooks: hooks()).run('g');
    final last = brain.sent.last;
    final fullScreens = last.where((m) => m['role'] == 'tool' && '${m['content']}'.contains('SCREEN (app:')).length;
    expect(fullScreens, 1);
    expect(last.any((m) => '${m['content']}'.contains('[older screen omitted]')), isTrue);
  });

  test('STOP halts the loop', () async {
    final phone = FakePhone([search]);
    var calls = 0;
    final brain = ScriptedBrain([
      for (var i = 0; i < 10; i++) [('get_screen', {})]
    ]);
    final agent = ScreenAgent(
        device: phone,
        apps: AppResolver(phone),
        brain: brain,
        apiKey: 'k',
        model: 'm',
        hooks: hooks(checkpoint: () async {
          if (++calls > 3) throw StateError('stopped');
        }));
    await expectLater(agent.run('g'), throwsStateError);
    expect(brain.turn, lessThan(3));
  });

  test('phone numbers on screen are masked for the model and restored when typed', () async {
    const screen = '[0] Text "Call 9845012345" ()\n[1] EditText "Number" (tap,input)';
    final phone = FakePhone([screen, screen]);
    final brain = ScriptedBrain([
      [('get_screen', {})],
      [('act', {'action': 'type', 'index': 1, 'text': '<PHONE_1>'})],
      [('finish_task', {'status': 'failed', 'message': 'x'})],
    ]);
    await ScreenAgent(device: phone, apps: AppResolver(phone), brain: brain, apiKey: 'k', model: 'm', hooks: hooks()).run('copy number');
    final seen = brain.sent[1].lastWhere((m) => m['role'] == 'tool')['content'] as String;
    expect(seen, isNot(contains('9845012345')));
    expect(seen, contains('<PHONE_1>'));
    expect(phone.acts, contains('type [1] "9845012345"'));
  });

  test('add to cart is confirmed by code and the agent stops (no wandering onto Buy)', () async {
    const results = '[0] Text "₹293.50 Buy for ₹288 with coupon" (tap)\n[1] Button "Add to cart" (tap)';
    const added = '[0] Text "₹293.50 Buy for ₹288 with coupon" (tap)\n[1] Button "1 in cart" (tap)';
    final phone = FakePhone([results, added]);
    final brain = ScriptedBrain([
      [('get_screen', {})],
      [('act', {'action': 'tap', 'index': 1})],
      [('act', {'action': 'tap', 'index': 0})], // must never be reached
    ]);
    final r = await ScreenAgent(device: phone, apps: AppResolver(phone), brain: brain, apiKey: 'k', model: 'm', hooks: hooks()).run('add to cart');
    expect(r.status, 'success');
    expect(brain.turn, 2);
    expect(phone.acts, ['tap [1]']);
  });
}


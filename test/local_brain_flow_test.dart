import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/ai/local_agent_brain.dart';
import 'package:jarvis/device/app_resolver.dart';
import 'package:jarvis/device/device_bridge.dart';

/// Fake phone: installed apps + a scripted "model" answer.
class FakeBridge extends DeviceBridge {
  String modelAnswer = '1';
  String? lastPrompt;
  @override
  Future<List<InstalledApp>> launchableApps() async => const [
        InstalledApp('Gallery', 'com.sec.android.gallery3d'),
        InstalledApp('Gmail', 'com.google.android.gm'),
        InstalledApp('WhatsApp', 'com.whatsapp'),
        InstalledApp('Settings', 'com.android.settings'),
      ];
  @override
  Future<String> llmGenerate(String prompt) async {
    lastPrompt = prompt;
    return modelAnswer;
  }
}

void main() {
  late FakeBridge dev;
  late LocalAgentBrain brain;
  setUp(() {
    dev = FakeBridge();
    brain = LocalAgentBrain(dev, AppResolver(dev));
  });

  test('searchQuery', () {
    expect(LocalAgentBrain.searchQuery('open gallery and search for beach photos'), 'beach photos');
    expect(LocalAgentBrain.searchQuery('find invoices from Amazon in gmail'), 'invoices from Amazon');
    expect(LocalAgentBrain.searchQuery('open settings'), isNull);
  });

  test('full gallery search flow is decided by rules (no model call)', () async {
    const goal = 'open gallery and search for beach photos';
    var p = await brain.step(goal: goal, screen: '[0] TextView "WhatsApp" (tap)', package: 'com.sec.android.app.launcher', history: []);
    expect((p['action'] as Map)['type'], 'open_app');
    expect((p['action'] as Map)['app'], 'Gallery');

    final h = ['1. open_app — Open Gallery → ok'];
    p = await brain.step(goal: goal, screen: '[0] TextView "Pictures" ()\n[1] ImageButton "Search" (tap)', package: 'com.sec.android.gallery3d', history: h);
    expect((p['action'] as Map)['type'], 'tap');
    expect((p['action'] as Map)['index'], 1);

    h.add('2. tap [1] — Tap "Search" → ok');
    p = await brain.step(goal: goal, screen: '[0] EditText "hint: Search" (input)', package: 'com.sec.android.gallery3d', history: h);
    expect((p['action'] as Map)['type'], 'type');
    expect((p['action'] as Map)['text'], 'beach photos');

    h.add('3. type [0] "beach photos" — Type "beach photos" → ok');
    p = await brain.step(goal: goal, screen: '[0] EditText "beach photos" (input)', package: 'com.sec.android.gallery3d', history: h);
    expect((p['action'] as Map)['type'], 'submit');

    h.add('4. submit [0] — Press search → ok');
    p = await brain.step(goal: goal, screen: '[0] ImageView "Image" (tap)', package: 'com.sec.android.gallery3d', history: h);
    expect(p['done'], isTrue);
    expect(dev.lastPrompt, isNull, reason: 'no model needed for this task');
  });

  test('distinctive word match: Rahul chat picked without the model', () async {
    final p = await brain.step(
      goal: "open Rahul's chat in WhatsApp",
      screen: '[0] TextView "Kiran" (tap)\n[1] TextView "Rahul ISE" (tap)\n[2] TextView "Updates" (tap)',
      package: 'com.whatsapp',
      history: ['1. open_app — Open WhatsApp → ok'],
    );
    expect((p['action'] as Map)['index'], 1);
    expect(p['how'], 'match');
    expect(dev.lastPrompt, isNull);
  });

  test('ambiguous screen → numbered menu for the model; answer maps to the element', () async {
    dev.modelAnswer = '2';
    final p = await brain.step(
      goal: 'turn on dark mode in settings',
      screen: '[0] TextView "Connections" (tap)\n[1] TextView "Display" (tap)\n[2] TextView "Sounds and vibration" (tap)',
      package: 'com.android.settings',
      history: ['1. open_app — Open Settings → ok'],
    );
    expect(dev.lastPrompt, contains('Options:'));
    expect(p['how'], 'model');
    expect((p['action'] as Map)['type'], 'tap');
  });

  test('model nonsense → asks the user instead of guessing', () async {
    dev.modelAnswer = 'I think maybe';
    final p = await brain.step(
      goal: 'turn on dark mode in settings',
      screen: '[0] TextView "Connections" (tap)\n[1] TextView "Display" (tap)',
      package: 'com.android.settings',
      history: ['1. open_app — Open Settings → ok'],
    );
    expect(p['ask'], isNotNull);
  });
}

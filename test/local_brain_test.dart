import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/ai/local_agent_brain.dart';

void main() {
  const screen = ['[0] TextView "Inbox" (tap)', '[1] Button "Compose" (tap)', '[2] EditText "hint: Search in mail" (input)'];

  test('tap with label from screen', () {
    final p = LocalAgentBrain.parse('{"action":"tap","index":1}', screenLines: screen);
    expect((p['action'] as Map)['type'], 'tap');
    expect((p['action'] as Map)['index'], 1);
    expect(p['describe'], 'Tap "Compose"');
  });
  test('trailing junk after JSON is ignored', () {
    final p = LocalAgentBrain.parse('{"action":"open_app","app":"Gmail"} I will now open Gmail<|im_end|>');
    expect((p['action'] as Map)['app'], 'Gmail');
  });
  test('single quotes tolerated', () {
    final p = LocalAgentBrain.parse("{'action':'type','index':2,'text':'amazon'}", screenLines: screen);
    expect((p['action'] as Map)['text'], 'amazon');
  });
  test('index as string', () => expect(((LocalAgentBrain.parse('{"action":"tap","index":"0"}')['action']) as Map)['index'], 0));
  test('done', () => expect(LocalAgentBrain.parse('{"action":"done","text":"Opened your beach photos"}')['done'], isTrue));
  test('garbage → asks instead of guessing', () => expect(LocalAgentBrain.parse('I think you should tap compose')['ask'], isNotNull));
  test('unknown action → asks', () => expect(LocalAgentBrain.parse('{"action":"hack"}')['ask'], isNotNull));
}

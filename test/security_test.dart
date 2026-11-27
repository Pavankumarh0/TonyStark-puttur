import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/agent/screen_agent.dart';
import 'package:jarvis/core/approval/approval_gate.dart';
import 'package:jarvis/core/privacy_filter.dart';
import 'package:jarvis/data/settings_store.dart';
import 'package:jarvis/data/vault.dart';
import 'package:jarvis/device/app_resolver.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screen_agent_test.dart' show FakePhone, ScriptedBrain, hooks;

/// Test double: reversible "sealing" that records which AAD each value was sealed for.
/// (The real AES-256-GCM is verified on the phone by Vault.selfTest.)
class FakeVault extends Vault {
  final sealedFor = <String>[];
  @override
  Future<Map<String, dynamic>> init() async => {'ready': true};
  @override
  Future<Map<String, dynamic>> status() async => {'ready': true};
  @override
  Future<List<String?>> seal(List<String?> plain, String aad) async {
    sealedFor.add(aad);
    return [for (final p in plain) p == null ? null : '${Vault.prefix}${base64Encode(utf8.encode('$aad|$p'))}'];
  }

  @override
  Future<List<String?>> open(List<String?> sealed, String aad) async => [
        for (final s in sealed)
          if (s == null || !Vault.isSealed(s))
            null
          else
            () {
              final t = utf8.decode(base64Decode(s.substring(3)));
              return t.startsWith('$aad|') ? t.substring(aad.length + 1) : null; // wrong field → rejected
            }()
      ];
  @override
  Future<List<String>> blind(List<String> words) async => [for (final w in words) 'b${w.hashCode.toRadixString(16)}'];
  @override
  Future<void> wipe() async {}
  @override
  Future<List<Map<String, dynamic>>> selfTest() async => const [];
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('consent', () {
    test('OpenAI is never used before the user explicitly allows it', () async {
      final s = SettingsStore();
      await s.load();
      await s.setSecret(SecretKey.openai, 'sk-test-123');
      expect(s.cloudBrainConsent, isNull);
      expect(s.hasSecret(SecretKey.openai), isFalse); // not asked yet → off
      s.cloudBrainConsent = false;
      expect(s.hasSecret(SecretKey.openai), isFalse); // declined → off
      s.cloudBrainConsent = true;
      expect(s.secret(SecretKey.openai), 'sk-test-123'); // allowed → on
      s.cloudBrainConsent = false;
      expect(s.secret(SecretKey.openai), isNull); // revoked → off again
      expect(s.hasSecret(SecretKey.sarvam), isFalse); // other keys unaffected by the gate
    });

    test('learning from the user\'s own commands is off unless opted in', () async {
      final s = SettingsStore();
      await s.load();
      expect(s.learnFromMe, isFalse);
      expect(s.retentionDays, 90);
    });
  });

  group('screen-agent memory', () {
    const screen = '[0] EditText "Message" (tap,input)\n[1] Button "Go" (tap)';
    List<List<(String, Map<String, dynamic>)>> script() => [
          [('get_screen', {})],
          [('act', {'action': 'type', 'index': 0, 'text': 'my PIN is 4321'})],
          [('finish_task', {'status': 'success', 'message': 'ok'})],
        ];

    test('nothing about the task is saved without opt-in', () async {
      final phone = FakePhone([screen, screen]);
      await ScreenAgent(
              device: phone, apps: AppResolver(phone), brain: ScriptedBrain(script()), apiKey: 'k', model: 'm', hooks: hooks(),
              vault: FakeVault(), remember: false)
          .run('type my pin 4321 for rahul 9845012345');
      final p = await SharedPreferences.getInstance();
      expect(p.getKeys().where((k) => k.startsWith('agent_hints_')), isEmpty);
    });

    test('with opt-in, hints are encrypted and never contain what was typed', () async {
      final phone = FakePhone([screen, screen]);
      final vault = FakeVault();
      await ScreenAgent(
              device: phone, apps: AppResolver(phone), brain: ScriptedBrain(script()), apiKey: 'k', model: 'm', hooks: hooks(),
              vault: vault, remember: true)
          .run('type my pin 4321 for rahul 9845012345');
      final p = await SharedPreferences.getInstance();
      final stored = p.getString('agent_hints_com.example.chat')!;
      expect(Vault.isSealed(stored), isTrue);
      expect(stored, isNot(contains('4321')));
      final plain = (await vault.open([stored], 'prefs.agent_hints')).single!;
      expect(plain, isNot(contains('4321'))); // typed text dropped
      expect(plain, isNot(contains('9845012345'))); // phone number masked
      expect(plain, contains('type (text)'));
      expect(await vault.open([stored], 'messages.text'), [null]); // bound to its field
    });
  });

  group('approval binding', () {
    ApprovalRequest req(String content, {String to = '+919800000001'}) => ApprovalRequest(
        id: 'r', actionType: 'whatsapp.send', title: 'Send', recipientId: to, content: content);

    test('approval only works for the exact action, recipient and text', () {
      ApprovalGate approved() => ApprovalGate()
        ..request(req('see you at 5'))
        ..approve();
      expect(approved().consume('whatsapp.send', '+919800000001', 'see you at 6'), isFalse); // edited text
      expect(approved().consume('whatsapp.send', '+919800000002', 'see you at 5'), isFalse); // other person
      expect(approved().consume('sms.send', '+919800000001', 'see you at 5'), isFalse); // other action
      final g = approved();
      expect(g.consume('whatsapp.send', '+919800000001', 'see you at 5'), isTrue);
      expect(g.consume('whatsapp.send', '+919800000001', 'see you at 5'), isFalse); // single use
    });

    test('a mismatched attempt cancels the approval (must ask again)', () {
      final g = ApprovalGate()
        ..request(req('see you at 5'))
        ..approve();
      expect(g.consume('whatsapp.send', '+919800000001', 'see you at 6'), isFalse);
      expect(g.consume('whatsapp.send', '+919800000001', 'see you at 5'), isFalse); // even the original is now void
    });

    test('fingerprints of different actions never collide', () {
      final a = ApprovalGate.fingerprintOf('whatsapp.send', 'x', 'hello');
      final b = ApprovalGate.fingerprintOf('whatsapp.send', 'x', 'hello ');
      expect(a, isNot(b));
    });
  });

  group('data minimisation', () {
    test('private identifiers are masked before anything is sent to a cloud model', () {
      final r = PrivacyFilter.redact('Call 9845012345, mail a@b.com, OTP 482913, card 4111 1111 1111 1111');
      for (final secret in ['9845012345', 'a@b.com', '482913', '4111 1111 1111 1111']) {
        expect(r.text, isNot(contains(secret)));
      }
    });
  });
}

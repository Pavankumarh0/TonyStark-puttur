import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/memory_repository.dart';
import '../data/settings_store.dart';
import '../device/device_bridge.dart';
import '../orchestrator/jarvis_orchestrator.dart';
import 'permissions_screen.dart';
import 'theme.dart';

/// One place that shows the user what LEO can access, where their data goes, how it is protected,
/// and lets them change or delete it. Everything stated here is what the code actually does.
class PrivacyScreen extends StatefulWidget {
  const PrivacyScreen({super.key});

  @override
  State<PrivacyScreen> createState() => _PrivacyScreenState();
}

class _PrivacyScreenState extends State<PrivacyScreen> {
  Map<String, dynamic>? _vault;
  bool? _qwenInstalled;
  List<Map<String, dynamic>>? _tests;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final memory = context.read<MemoryRepository>();
    final device = context.read<DeviceBridge>();
    final v = await memory.vault.status();
    final q = await device.llmStatus();
    if (mounted) setState(() {
      _vault = v;
      _qwenInstalled = q['installed'] == true;
    });
  }

  Future<void> _selfTest() async {
    setState(() => _testing = true);
    final r = await context.read<MemoryRepository>().vault.selfTest();
    for (final t in r) {
      debugPrint('LEO security self-test: ${t['pass'] == true ? 'PASS' : 'FAIL'} · ${t['name']}'); // results only
    }
    if (mounted) setState(() {
      _tests = r;
      _testing = false;
    });
  }

  Future<void> _deleteEverything() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete everything?'),
        content: const Text(
            'All conversations, tasks, remembered facts, learned phrases, the privacy ledger and usage history will be '
            'deleted, and the encryption keys that protected them destroyed. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: JColors.red),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Delete everything')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context.read<JarvisOrchestrator>().wipeAllData();
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Deleted. New encryption keys created.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsStore>();
    final v = _vault;
    final keyWhere = switch (v?['keyStorage']) {
      'strongbox' => 'StrongBox security chip',
      'tee' => 'hardware Trusted Execution Environment',
      'software' => 'software keystore (no secure hardware on this phone)',
      _ => '…',
    };
    return Scaffold(
      appBar: AppBar(title: const Text('PRIVACY & SECURITY')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        _card(Icons.lock_outline, 'Stored on this phone — encrypted', [
          'Conversations, tasks, remembered facts, learned phrases and the privacy ledger are encrypted with '
              'AES-256-GCM before they are saved.',
          'The master key lives in Android Keystore ($keyWhere) and can never be exported — not even by LEO.',
          'Search works on keyed fingerprints (HMAC), so the search index holds no readable words.',
          'Nothing is included in cloud backups or device-to-device transfers.',
        ], status: v == null ? null : (v['ready'] == true && v['kekExportable'] == false)),
        _card(Icons.memory, 'Processed on this phone', [
          'Wake word "Leo", everyday commands (apps, calls, alarms, music, messages) and LEO\'s memory.',
          _qwenInstalled == true
              ? 'Qwen 2.5 (1.5B) runs entirely on this phone — prompts to it never leave the device.'
              : 'Qwen 2.5 (1.5B) on-device model: not downloaded yet (Settings → On-device brain).',
        ]),
        _card(Icons.cloud_outlined, 'Sent over the internet (TLS-encrypted in transit)', [
          'Sarvam (voice): your recorded speech for transcription, and the text LEO speaks aloud. Sarvam can read/hear these.',
          s.cloudBrainAllowed
              ? 'OpenAI (brain): only requests LEO can\'t handle on the phone, and screen summaries during screen tasks — '
                  'phone numbers, emails, OTPs, card/Aadhaar/PAN numbers and message bodies are masked first. '
                  'OpenAI can read what is sent (this is not end-to-end encrypted); API data is not used for training.'
              : 'OpenAI: OFF — nothing is sent to OpenAI.',
          'Every cloud request is listed, exactly as sent, in Analytics → Privacy ledger.',
        ]),
        const SizedBox(height: 8),
        _label('YOUR CHOICES'),
        Card(
          child: Column(children: [
            SwitchListTile(
              value: s.cloudBrainAllowed,
              onChanged: (x) => s.cloudBrainConsent = x,
              title: const Text('Allow OpenAI for hard requests'),
              subtitle: const Text('Off = everything is understood on this phone (rules + Qwen). Slower on complex tasks.',
                  style: TextStyle(color: JColors.dim, fontSize: 12)),
            ),
            SwitchListTile(
              value: s.learnFromMe,
              onChanged: (x) async {
                s.learnFromMe = x;
                final o = context.read<JarvisOrchestrator>();
                if (!x) await context.read<MemoryRepository>().deleteLearnedExamples(); // withdrawn → data deleted
                o.classifier.train(learned: x ? await o.memory.learnedExamples() : const []);
              },
              title: const Text('Learn from my commands'),
              subtitle: const Text(
                  'Improves LEO\'s on-phone understanding using your own past commands. Stored encrypted, never uploaded, '
                  'never used to train any cloud model. Off unless you turn it on.',
                  style: TextStyle(color: JColors.dim, fontSize: 12)),
            ),
            SwitchListTile(
              value: s.privateVoice,
              onChanged: (x) => s.privateVoice = x,
              title: const Text('Read private content with the on-phone voice'),
              subtitle: const Text('Messages, chats and codes are spoken by the phone\'s own voice instead of Sarvam.',
                  style: TextStyle(color: JColors.dim, fontSize: 12)),
            ),
            ListTile(
              title: const Text('Keep history for'),
              subtitle: const Text('Older conversations, tasks and ledger entries are deleted automatically.',
                  style: TextStyle(color: JColors.dim, fontSize: 12)),
              trailing: DropdownButton<int>(
                value: const [7, 30, 90, 365, 0].contains(s.retentionDays) ? s.retentionDays : 90,
                items: const [
                  DropdownMenuItem(value: 7, child: Text('7 days')),
                  DropdownMenuItem(value: 30, child: Text('30 days')),
                  DropdownMenuItem(value: 90, child: Text('90 days')),
                  DropdownMenuItem(value: 365, child: Text('1 year')),
                  DropdownMenuItem(value: 0, child: Text('Forever')),
                ],
                onChanged: (d) async {
                  if (d == null) return;
                  s.retentionDays = d;
                  final memory = context.read<MemoryRepository>();
                  if (d > 0) await memory.purgeOlderThan(d);
                },
              ),
            ),
          ]),
        ),
        const SizedBox(height: 8),
        Card(
          child: ListTile(
            leading: const Icon(Icons.admin_panel_settings_outlined, color: JColors.cyan),
            title: const Text('What LEO can access on this phone'),
            subtitle: const Text('See every permission, grant or revoke it.', style: TextStyle(color: JColors.dim, fontSize: 12)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PermissionsScreen())),
          ),
        ),
        const SizedBox(height: 8),
        _label('CHECKS'),
        OutlinedButton.icon(
          onPressed: _testing ? null : _selfTest,
          icon: const Icon(Icons.verified_user_outlined),
          label: Text(_testing ? 'Testing…' : 'Run security self-test'),
        ),
        if (_tests != null)
          Card(
            child: Column(children: [
              for (final t in _tests!)
                ListTile(
                  dense: true,
                  leading: Icon(t['pass'] == true ? Icons.check_circle : Icons.cancel,
                      color: t['pass'] == true ? JColors.green : JColors.red),
                  title: Text('${t['name']}'),
                  subtitle: Text('${t['detail']}', style: const TextStyle(color: JColors.dim, fontSize: 11)),
                ),
            ]),
          ),
        const SizedBox(height: 16),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: JColors.red),
          onPressed: _deleteEverything,
          icon: const Icon(Icons.delete_forever),
          label: const Text('Delete everything LEO stored'),
        ),
        const SizedBox(height: 24),
      ]),
    );
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
        child: Text(t, style: const TextStyle(letterSpacing: 2, fontSize: 12, color: JColors.cyan)),
      );

  Widget _card(IconData icon, String title, List<String> lines, {bool? status}) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, color: JColors.cyan),
              const SizedBox(width: 8),
              Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600))),
              if (status != null)
                Icon(status ? Icons.check_circle : Icons.error_outline, color: status ? JColors.green : JColors.amber, size: 18),
            ]),
            const SizedBox(height: 8),
            for (final l in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('• $l', style: const TextStyle(color: JColors.dim, fontSize: 12, height: 1.4)),
              ),
          ]),
        ),
      );
}

/// First-run informed consent for the only optional cloud processor (OpenAI). Sarvam voice is
/// disclosed too. Until the user answers, OpenAI stays off (fail-closed).
Future<void> showPrivacyConsent(BuildContext context) async {
  final s = context.read<SettingsStore>();
  if (s.cloudBrainConsent != null) return;
  final allow = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (c) => AlertDialog(
      title: const Text('Your data, your choice'),
      content: const SingleChildScrollView(
        child: Text(
          'LEO understands everyday commands on this phone, and everything it stores is encrypted here.\n\n'
          '• Voice: your speech is sent to Sarvam (India) for transcription, and LEO\'s replies for its voice.\n\n'
          '• Optional — OpenAI: for requests LEO can\'t handle on the phone (multi-step, mixed language, '
          'operating unfamiliar apps), LEO can send the request and a text summary of the screen to OpenAI. '
          'Phone numbers, emails, codes and message text are masked first. OpenAI can read what is sent; '
          'it does not use API data for training.\n\n'
          'If you choose "Keep on this phone", LEO uses only its on-phone rules and the on-device Qwen model. '
          'You can change this any time in Settings → Privacy & Security.',
          style: TextStyle(height: 1.4),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep on this phone')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Allow OpenAI')),
      ],
    ),
  );
  s.cloudBrainConsent = allow ?? false;
}

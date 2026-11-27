import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ai/gemini_client.dart';
import '../data/settings_store.dart';
import '../device/device_bridge.dart';
import '../orchestrator/jarvis_orchestrator.dart';
import 'permissions_screen.dart';
import 'privacy_screen.dart';
import 'theme.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  static const bulbulV3Speakers = [
    'shubh',
    'aditya',
    'rahul',
    'rohan',
    'amit',
    'dev',
    'ratan',
    'varun',
    'manan',
    'sumit',
    'kabir',
    'aayan',
    'ashutosh',
    'advait',
    'anand',
    'tarun',
    'sunny',
    'mani',
    'gokul',
    'vijay',
    'mohit',
    'rehan',
    'soham',
    'ritu',
    'priya',
    'neha',
    'pooja',
    'simran',
    'kavya',
    'ishita',
    'shreya',
    'roopa',
    'tanya',
    'shruti',
    'suhani',
    'kavitha',
    'rupali',
  ];

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsStore>();
    final o = context.read<JarvisOrchestrator>();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'SETTINGS',
          style: TextStyle(letterSpacing: 4, fontSize: 18, color: JColors.cyan),
        ),
        const SizedBox(height: 16),
        ListTile(
          tileColor: JColors.panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: JColors.line),
          ),
          leading: const Icon(
            Icons.admin_panel_settings_outlined,
            color: JColors.cyan,
          ),
          title: const Text('Permissions & device setup'),
          subtitle: const Text(
            'Microphone, contacts, accessibility, battery',
            style: TextStyle(color: JColors.dim),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const PermissionsScreen())),
        ),
        const SizedBox(height: 10),
        ListTile(
          tileColor: JColors.panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: JColors.line),
          ),
          leading: const Icon(Icons.lock_outline, color: JColors.cyan),
          title: const Text('Privacy & Security'),
          subtitle: const Text(
            'Encryption, where your data goes, consent, retention, delete everything',
            style: TextStyle(color: JColors.dim),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PrivacyScreen())),
        ),
        const SizedBox(height: 20),
        _label('API KEYS (built into the app — tap only to override)'),
        _KeyTile(
          k: SecretKey.sarvam,
          title: 'Sarvam API key (voice)',
          help: 'dashboard.sarvam.ai → API keys. Used only for speech-to-text and LEO\'s voice.',
          onSaved: () {},
        ),
        _KeyTile(
          k: SecretKey.openai,
          title: 'OpenAI API key (brain)',
          help: 'platform.openai.com → API keys. Understands free-form requests, writes, answers. Personal data is masked first.',
          onSaved: () {},
        ),
        _TextPref(
          title: 'OpenAI model',
          value: s.openAiModel,
          onChanged: (v) => s.openAiModel = v,
        ),
        _KeyTile(
          k: SecretKey.picovoice,
          title: 'Picovoice AccessKey (optional)',
          help:
              'Not needed — the free sherpa-onnx wake word is used without it',
          onSaved: () async {
            if (o.listeningEnabled) {
              await o.mic.disableWakeWord();
              await o.enableListening();
            }
          },
        ),
        const SizedBox(height: 20),
        _label('PHONE CONTROL BRAIN'),
        const _BrainCard(),
        const SizedBox(height: 20),
        _label('VOICE (SARVAM)'),
        _TextPref(
          title: 'Speech-to-text model',
          value: s.sarvamSttModel,
          onChanged: (v) => s.sarvamSttModel = v,
        ),
        _TextPref(
          title: 'Text-to-speech model',
          value: s.sarvamTtsModel,
          onChanged: (v) => s.sarvamTtsModel = v,
        ),
        Card(
          child: ListTile(
            title: const Text('Voice'),
            subtitle: Text(
              s.sarvamSpeaker,
              style: const TextStyle(color: JColors.dim),
            ),
            trailing: s.sarvamTtsModel == 'bulbul:v3'
                ? DropdownButton<String>(
                    value: bulbulV3Speakers.contains(s.sarvamSpeaker)
                        ? s.sarvamSpeaker
                        : null,
                    dropdownColor: JColors.panel,
                    items: [
                      for (final v in bulbulV3Speakers)
                        DropdownMenuItem(value: v, child: Text(v)),
                    ],
                    onChanged: (v) => v == null ? null : s.sarvamSpeaker = v,
                  )
                : const Icon(Icons.edit),
            onTap: s.sarvamTtsModel == 'bulbul:v3'
                ? null
                : () async {
                    final v = await _prompt(
                      context,
                      'Voice (persona id)',
                      s.sarvamSpeaker,
                    );
                    if (v != null) s.sarvamSpeaker = v;
                  },
          ),
        ),
        Card(
          child: ListTile(
            title: const Text('Speaking pace'),
            subtitle: Slider(
              value: s.ttsPace,
              min: 0.7,
              max: 1.5,
              divisions: 16,
              label: s.ttsPace.toStringAsFixed(2),
              onChanged: (v) => s.ttsPace = v,
            ),
          ),
        ),
        Card(
          child: ListTile(
            title: const Text('Test voice'),
            trailing: const Icon(Icons.volume_up, color: JColors.cyan),
            onTap: () => o.speechOut.speak(
              'Good evening, ${s.address}. All systems are online.',
            ),
          ),
        ),
        SwitchListTile(
          value: s.sarvamUnderstanding,
          onChanged: (v) => s.sarvamUnderstanding = v,
          title: const Text('Smart understanding (OpenAI brain)'),
          subtitle: const Text(
              'When LEO isn\'t sure what you meant, OpenAI rewrites it into clear steps (and answers questions). '
              'Everyday commands stay on the phone. Phone numbers, emails, OTPs and IDs are masked before sending.',
              style: TextStyle(color: JColors.dim)),
        ),
        SwitchListTile(
          value: s.privateVoice,
          onChanged: (v) => s.privateVoice = v,
          title: const Text('Read private things with the phone\'s own voice'),
          subtitle: const Text(
              'Messages, chats, OTPs and screen text are spoken on-device — never sent to a cloud voice.',
              style: TextStyle(color: JColors.dim)),
        ),
        SwitchListTile(
          value: s.secureScreen,
          onChanged: (v) {
            s.secureScreen = v;
            o.device.applySecureScreen(v);
          },
          title: const Text('Hide LEO from screenshots & recording'),
          subtitle: const Text('Other apps (and screen recorders) see a black screen instead of your conversations.',
              style: TextStyle(color: JColors.dim)),
        ),
        SwitchListTile(
          value: s.mixedLanguage,
          onChanged: (v) => s.mixedLanguage = v,
          title: const Text('Understand Hindi / Kannada / mixed speech'),
          subtitle: const Text(
            'Detects the language you speak and translates it into English before LEO acts. Turn off if names get mistranslated.',
            style: TextStyle(color: JColors.dim),
          ),
        ),
        SwitchListTile(
          value: s.replyInMyLanguage,
          onChanged: s.mixedLanguage ? (v) => s.replyInMyLanguage = v : null,
          title: const Text('Reply in the language I speak'),
          subtitle: const Text(
            'Speak Kannada or Hindi and LEO answers in Kannada or Hindi (everyday mixed style). Off = always English.',
            style: TextStyle(color: JColors.dim),
          ),
        ),
        SwitchListTile(
          value: s.useDeviceTts,
          onChanged: (v) => s.useDeviceTts = v,
          title: const Text('Use phone\'s offline voice instead'),
          subtitle: const Text(
            'No network needed; lower quality',
            style: TextStyle(color: JColors.dim),
          ),
        ),
        const SizedBox(height: 20),
        _label('WAKE WORD & CONVERSATION'),
        SwitchListTile(
          value: s.wakeEngine == 'porcupine',
          onChanged: (v) async {
            s.wakeEngine = v ? 'porcupine' : 'sherpa';
            if (o.listeningEnabled) {
              await o.mic.disableWakeWord();
              await o.enableListening();
            }
          },
          title: const Text('Use Picovoice Porcupine'),
          subtitle: Text(
            s.wakeEngine == 'porcupine'
                ? 'Porcupine only knows the word "Jarvis" — wake word becomes "Jarvis" (needs Picovoice key)'
                : 'Say "Leo" — free sherpa-onnx keyword spotter, fully on-device',
            style: const TextStyle(color: JColors.dim),
          ),
        ),
        Card(
          child: ListTile(
            title: const Text('Wake word sensitivity'),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Slider(
                  value: s.wakeSensitivity,
                  min: 0.3,
                  max: 0.9,
                  divisions: 12,
                  label: s.wakeSensitivity.toStringAsFixed(2),
                  onChanged: (v) => s.wakeSensitivity = v,
                ),
                const Text(
                  'Higher = fewer misses, more false triggers. Applies next time listening starts.',
                  style: TextStyle(color: JColors.dim, fontSize: 11),
                ),
              ],
            ),
          ),
        ),
        SwitchListTile(
          value: s.speakResponses,
          onChanged: (v) => s.speakResponses = v,
          title: const Text('Speak responses'),
        ),
        SwitchListTile(
          value: s.followUpListening,
          onChanged: (v) => s.followUpListening = v,
          title: const Text('Listen again after responding'),
          subtitle: const Text(
            'One follow-up turn without saying "Leo"',
            style: TextStyle(color: JColors.dim),
          ),
        ),
        _TextPref(
          title: 'How LEO addresses you',
          value: s.address,
          onChanged: (v) => s.address = v,
        ),
        const SizedBox(height: 30),
      ],
    );
  }

  Widget _label(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 8, left: 4),
    child: Text(
      t,
      style: const TextStyle(
        color: JColors.dim,
        letterSpacing: 2,
        fontSize: 11,
      ),
    ),
  );
}

Future<String?> _prompt(
  BuildContext context,
  String title,
  String initial, {
  bool obscure = false,
}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: JColors.panel,
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        obscureText: obscure,
        enableSuggestions: !obscure,
        autocorrect: false,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, c.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

class _KeyTile extends StatelessWidget {
  final SecretKey k;
  final String title;
  final String help;
  final VoidCallback onSaved;
  const _KeyTile({
    required this.k,
    required this.title,
    required this.help,
    required this.onSaved,
  });

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsStore>();
    final set = s.hasSecret(k);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: ListTile(
          leading: Icon(
            set ? Icons.key : Icons.key_off,
            color: set ? JColors.green : JColors.amber,
          ),
          title: Text(title),
          subtitle: Text(
            '${s.maskedSecret(k)}\n$help',
            style: const TextStyle(color: JColors.dim, fontSize: 12),
          ),
          isThreeLine: true,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (set && !s.isBuiltIn(k))
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: JColors.red),
                  onPressed: () async {
                    await s.setSecret(k, null);
                    onSaved();
                  },
                ),
              const Icon(Icons.edit),
            ],
          ),
          onTap: () async {
            final v = await _prompt(context, title, '', obscure: true);
            if (v != null && v.isNotEmpty) {
              await s.setSecret(k, v);
              onSaved();
            }
          },
        ),
      ),
    );
  }
}

class _TextPref extends StatelessWidget {
  final String title;
  final String value;
  final void Function(String) onChanged;
  const _TextPref({
    required this.title,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Card(
      child: ListTile(
        title: Text(title),
        subtitle: Text(value, style: const TextStyle(color: JColors.dim)),
        trailing: const Icon(Icons.edit),
        onTap: () async {
          final v = await _prompt(context, title, value);
          if (v != null && v.isNotEmpty) onChanged(v);
        },
      ),
    ),
  );
}

class _VerifyGemini extends StatefulWidget {
  final SettingsStore settings;
  const _VerifyGemini({required this.settings});

  @override
  State<_VerifyGemini> createState() => _VerifyGeminiState();
}

class _VerifyGeminiState extends State<_VerifyGemini> {
  String? _result;
  bool _busy = false;

  Future<void> _verify() async {
    final key = widget.settings.secret(SecretKey.gemini);
    if (key == null) {
      setState(() => _result = 'Set the Gemini API key first.');
      return;
    }
    setState(() => _busy = true);
    try {
      final models = await GeminiClient().listModels(key);
      final m = widget.settings.geminiModel;
      final ok = models.contains(m);
      final flash = models.where((x) => x.contains('flash')).take(6).join(', ');
      _result = ok
          ? 'Key works. "$m" is available.'
          : 'Key works, but "$m" is not in your model list. Available flash models: $flash';
    } catch (e) {
      _result = 'Verification failed: $e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      title: const Text('Verify key & model'),
      subtitle: _result == null
          ? null
          : Text(
              _result!,
              style: const TextStyle(color: JColors.dim, fontSize: 12),
            ),
      trailing: _busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.verified_outlined, color: JColors.cyan),
      onTap: _busy ? null : _verify,
    ),
  );
}

/// On-device model for the screen agent: download / progress / delete, and brain choice.
class _BrainCard extends StatefulWidget {
  const _BrainCard();

  @override
  State<_BrainCard> createState() => _BrainCardState();
}

class _BrainCardState extends State<_BrainCard> {
  Map<String, dynamic> _st = const {};
  StreamSubscription? _sub;
  String? _error;

  @override
  void initState() {
    super.initState();
    final d = context.read<DeviceBridge>();
    _refresh();
    _sub = d.events.listen((e) {
      if (e['type'] != 'model_download') return;
      if (!mounted) return;
      setState(() {
        _error = e['error'] as String?;
        _st = {
          ..._st,
          'bytes': e['bytes'] ?? _st['bytes'],
          'downloading': e['done'] != true && e['error'] == null,
        };
      });
      if (e['done'] == true || e['error'] != null) _refresh();
    });
  }

  Future<void> _refresh() async {
    final st = await context.read<DeviceBridge>().llmStatus();
    if (mounted) setState(() => _st = st);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsStore>();
    final d = context.read<DeviceBridge>();
    final installed = _st['installed'] == true;
    final downloading = _st['downloading'] == true;
    final total = (_st['total'] as num?)?.toDouble() ?? 1597913616;
    final bytes = (_st['bytes'] as num?)?.toDouble() ?? 0;
    final pct = (bytes / total).clamp(0.0, 1.0);
    String gb(double b) => (b / 1e9).toStringAsFixed(2);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  installed ? Icons.memory : Icons.cloud_download_outlined,
                  color: installed ? JColors.volt : JColors.mute,
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'On-device brain',
                    style: TextStyle(
                      fontFamily: JFonts.display,
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    ),
                  ),
                ),
                Text(
                  installed
                      ? 'READY'
                      : (downloading ? 'DOWNLOADING' : 'NOT DOWNLOADED'),
                  style: monoLabel(
                    color: installed ? JColors.volt : JColors.mute,
                    size: 9,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Qwen 2.5 · 1.5B (Apache-2.0) runs on your phone to operate apps step by step — no API key, works offline, '
              'nothing leaves the phone. Less clever than the cloud on long tasks.',
              style: TextStyle(color: JColors.mute, fontSize: 12, height: 1.4),
            ),
            if (downloading || (!installed && bytes > 0)) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: pct,
                  minHeight: 8,
                  color: JColors.volt,
                  backgroundColor: JColors.line,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${gb(bytes)} / ${gb(total)} GB',
                style: monoLabel(color: JColors.mute, size: 9),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                'Download stopped: $_error. Tap Download to resume.',
                style: const TextStyle(color: JColors.amber, fontSize: 12),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (!installed && !downloading)
                  FilledButton.icon(
                    onPressed: () async {
                      setState(() => _error = null);
                      await d.llmDownload();
                      await _refresh();
                    },
                    icon: const Icon(Icons.download, size: 18),
                    label: Text(
                      bytes > 0
                          ? 'Resume download'
                          : 'Download (1.6 GB, use Wi-Fi)',
                    ),
                  ),
                if (downloading)
                  OutlinedButton(
                    onPressed: () async => d.llmCancelDownload(),
                    child: const Text('Pause download'),
                  ),
                if (installed)
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: JColors.red,
                    ),
                    onPressed: () async {
                      await d.llmDelete();
                      await _refresh();
                    },
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Delete model'),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              'USE FOR OPERATING APPS',
              style: monoLabel(color: JColors.mute, size: 9),
            ),
            const SizedBox(height: 6),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'local',
                  label: Text('On-device'),
                  icon: Icon(Icons.phone_android, size: 16),
                ),
                ButtonSegment(
                  value: 'gemini',
                  label: Text('OpenAI cloud'),
                  icon: Icon(Icons.cloud_outlined, size: 16),
                ),
              ],
              selected: {s.agentBrain},
              onSelectionChanged: (v) => s.agentBrain = v.first,
              style: SegmentedButton.styleFrom(
                selectedBackgroundColor: JColors.volt,
                selectedForegroundColor: JColors.ink,
                foregroundColor: JColors.bone,
                side: BorderSide(color: JColors.volt.withValues(alpha: 0.25)),
              ),
            ),
            if (s.agentBrain == 'local' && !installed)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Until the model is downloaded, LEO uses OpenAI (the screen\'s text is sent, personal numbers masked).',
                  style: TextStyle(color: JColors.mute, fontSize: 11),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

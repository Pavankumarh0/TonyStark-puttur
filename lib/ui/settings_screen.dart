import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ai/gemini_client.dart';
import '../data/settings_store.dart';
import '../orchestrator/jarvis_orchestrator.dart';
import 'permissions_screen.dart';
import 'theme.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  static const bulbulV3Speakers = [
    'shubh', 'aditya', 'rahul', 'rohan', 'amit', 'dev', 'ratan', 'varun', 'manan', 'sumit', 'kabir', 'aayan',
    'ashutosh', 'advait', 'anand', 'tarun', 'sunny', 'mani', 'gokul', 'vijay', 'mohit', 'rehan', 'soham',
    'ritu', 'priya', 'neha', 'pooja', 'simran', 'kavya', 'ishita', 'shreya', 'roopa', 'tanya', 'shruti', 'suhani',
    'kavitha', 'rupali',
  ];

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsStore>();
    final o = context.read<JarvisOrchestrator>();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('SETTINGS', style: TextStyle(letterSpacing: 4, fontSize: 18, color: JColors.cyan)),
        const SizedBox(height: 16),
        ListTile(
          tileColor: JColors.panel,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: JColors.line)),
          leading: const Icon(Icons.admin_panel_settings_outlined, color: JColors.cyan),
          title: const Text('Permissions & device setup'),
          subtitle: const Text('Microphone, contacts, accessibility, battery', style: TextStyle(color: JColors.dim)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PermissionsScreen())),
        ),
        const SizedBox(height: 20),
        _label('API KEYS (built into the app — tap only to override)'),
        _KeyTile(k: SecretKey.gemini, title: 'Gemini API key', help: 'aistudio.google.com → Get API key', onSaved: () {}),
        _KeyTile(k: SecretKey.sarvam, title: 'Sarvam API key', help: 'dashboard.sarvam.ai → API keys (voice in/out)', onSaved: () {}),
        _KeyTile(
          k: SecretKey.picovoice,
          title: 'Picovoice AccessKey (optional)',
          help: 'Not needed — the free sherpa-onnx wake word is used without it',
          onSaved: () async {
            if (o.listeningEnabled) {
              await o.mic.disableWakeWord();
              await o.enableListening();
            }
          },
        ),
        const SizedBox(height: 20),
        _label('GEMINI'),
        _TextPref(title: 'Model', value: s.geminiModel, onChanged: (v) => s.geminiModel = v),
        _VerifyGemini(settings: s),
        const SizedBox(height: 20),
        _label('VOICE (SARVAM)'),
        _TextPref(title: 'Speech-to-text model', value: s.sarvamSttModel, onChanged: (v) => s.sarvamSttModel = v),
        _TextPref(title: 'Text-to-speech model', value: s.sarvamTtsModel, onChanged: (v) => s.sarvamTtsModel = v),
        Card(
          child: ListTile(
            title: const Text('Voice'),
            subtitle: Text(s.sarvamSpeaker, style: const TextStyle(color: JColors.dim)),
            trailing: s.sarvamTtsModel == 'bulbul:v3'
                ? DropdownButton<String>(
                    value: bulbulV3Speakers.contains(s.sarvamSpeaker) ? s.sarvamSpeaker : null,
                    dropdownColor: JColors.panel,
                    items: [for (final v in bulbulV3Speakers) DropdownMenuItem(value: v, child: Text(v))],
                    onChanged: (v) => v == null ? null : s.sarvamSpeaker = v,
                  )
                : const Icon(Icons.edit),
            onTap: s.sarvamTtsModel == 'bulbul:v3'
                ? null
                : () async {
                    final v = await _prompt(context, 'Voice (persona id)', s.sarvamSpeaker);
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
            onTap: () => o.speechOut.speak('Good evening, ${s.address}. All systems are online.'),
          ),
        ),
        SwitchListTile(
          value: s.useDeviceTts,
          onChanged: (v) => s.useDeviceTts = v,
          title: const Text('Use phone\'s offline voice instead'),
          subtitle: const Text('No network needed; lower quality', style: TextStyle(color: JColors.dim)),
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
                  ? 'Porcupine (needs Picovoice key; falls back to free engine if it fails)'
                  : 'Using free sherpa-onnx keyword spotter (no key, fully on-device)',
              style: const TextStyle(color: JColors.dim)),
        ),
        Card(
          child: ListTile(
            title: const Text('Wake word sensitivity'),
            subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Slider(
                value: s.wakeSensitivity,
                min: 0.3,
                max: 0.9,
                divisions: 12,
                label: s.wakeSensitivity.toStringAsFixed(2),
                onChanged: (v) => s.wakeSensitivity = v,
              ),
              const Text('Higher = fewer misses, more false triggers. Applies next time listening starts.',
                  style: TextStyle(color: JColors.dim, fontSize: 11)),
            ]),
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
          subtitle: const Text('One follow-up turn without saying "Jarvis"', style: TextStyle(color: JColors.dim)),
        ),
        _TextPref(title: 'How JARVIS addresses you', value: s.address, onChanged: (v) => s.address = v),
        const SizedBox(height: 30),
      ],
    );
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 8, left: 4),
        child: Text(t, style: const TextStyle(color: JColors.dim, letterSpacing: 2, fontSize: 11)),
      );
}

Future<String?> _prompt(BuildContext context, String title, String initial, {bool obscure = false}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: JColors.panel,
      title: Text(title),
      content: TextField(controller: c, autofocus: true, obscureText: obscure, enableSuggestions: !obscure, autocorrect: false),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Save')),
      ],
    ),
  );
}

class _KeyTile extends StatelessWidget {
  final SecretKey k;
  final String title;
  final String help;
  final VoidCallback onSaved;
  const _KeyTile({required this.k, required this.title, required this.help, required this.onSaved});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsStore>();
    final set = s.hasSecret(k);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: ListTile(
          leading: Icon(set ? Icons.key : Icons.key_off, color: set ? JColors.green : JColors.amber),
          title: Text(title),
          subtitle: Text('${s.maskedSecret(k)}\n$help', style: const TextStyle(color: JColors.dim, fontSize: 12)),
          isThreeLine: true,
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (set && !s.isBuiltIn(k))
              IconButton(
                icon: const Icon(Icons.delete_outline, color: JColors.red),
                onPressed: () async {
                  await s.setSecret(k, null);
                  onSaved();
                },
              ),
            const Icon(Icons.edit),
          ]),
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
  const _TextPref({required this.title, required this.value, required this.onChanged});

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
          subtitle: _result == null ? null : Text(_result!, style: const TextStyle(color: JColors.dim, fontSize: 12)),
          trailing: _busy
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.verified_outlined, color: JColors.cyan),
          onTap: _busy ? null : _verify,
        ),
      );
}

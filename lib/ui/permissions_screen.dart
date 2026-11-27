import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../device/device_bridge.dart';
import 'theme.dart';

/// Shows the REAL status of every permission JARVIS depends on, with a direct fix action.
class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key});

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen> with WidgetsBindingObserver {
  PermissionStatus? _mic, _notif, _contacts, _phone;
  bool? _a11y, _battery, _notifAccess, _assistant;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh(); // returning from system settings
  }

  Future<void> _refresh() async {
    final d = context.read<DeviceBridge>();
    final mic = await Permission.microphone.status;
    final n = await Permission.notification.status;
    final c = await Permission.contacts.status;
    final a = await d.accessibilityEnabled();
    final b = await d.isIgnoringBatteryOptimizations();
    final ph = await Permission.phone.status;
    final na = await d.notificationAccess();
    final asst = await d.isDefaultAssistant();
    if (mounted) {
      setState(() {
        _mic = mic;
        _notif = n;
        _contacts = c;
        _a11y = a;
        _battery = b;
        _phone = ph;
        _notifAccess = na;
        _assistant = asst;
      });
    }
  }

  Future<void> _request(Permission p) async {
    final s = await p.request();
    if (s.isPermanentlyDenied) await openAppSettings();
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final d = context.read<DeviceBridge>();
    return Scaffold(
      appBar: AppBar(title: const Text('PERMISSIONS')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _tile(
              'Microphone',
              'Wake word and voice commands. Audio is processed on-device until "Jarvis" is detected or you tap the mic.',
              _mic?.isGranted,
              () => _request(Permission.microphone),
            ),
            _tile(
              'Notifications',
              'Required to show the persistent "JARVIS is listening" notification (Android rule for background microphone).',
              _notif?.isGranted,
              () => _request(Permission.notification),
            ),
            _tile(
              'Contacts',
              'Find WhatsApp recipients by name. Only read when you ask to message someone.',
              _contacts?.isGranted,
              () => _request(Permission.contacts),
            ),
            _tile(
              'Default digital assistant',
              'Make JARVIS your phone assistant: long-press the side key (or swipe up from a bottom corner) to open the half-screen JARVIS panel, like Gemini.',
              _assistant,
              d.openAssistantSettings,
              extra: const Text(
                'Samsung: Settings → Apps → Choose default apps → Digital assistant app → Device assistance app → JARVIS. '
                'Then Settings → Advanced features → Side button → Press and hold → Digital assistant.',
                style: TextStyle(color: JColors.dim, fontSize: 12),
              ),
            ),
            _tile(
              'Phone calls',
              'Lets "call Pavan" place the call directly. Without it, JARVIS opens the dialer and you tap call.',
              _phone?.isGranted,
              () => _request(Permission.phone),
            ),
            _tile(
              'Notification access (message reader)',
              'Lets "check my new WhatsApp messages / emails" read what is in your notifications — on the phone, no AI.',
              _notifAccess,
              d.openNotificationAccessSettings,
              extra: const Text(
                'If it is greyed out, first allow restricted settings (App info → ⋮ → Allow restricted settings).',
                style: TextStyle(color: JColors.dim, fontSize: 12),
              ),
            ),
            _tile(
              'Accessibility service',
              'Lets JARVIS tap Send in WhatsApp (only after you approve the exact message) and start the YouTube video you asked for. Limited to WhatsApp and YouTube.',
              _a11y,
              d.openAccessibilitySettings,
              extra: const _A11yHelp(),
            ),
            _tile(
              'Battery: unrestricted',
              'Prevents Android/One UI from killing the listening service in the background.',
              _battery,
              () async {
                await d.requestIgnoreBatteryOptimizations();
                await _refresh();
              },
              extra: const Text(
                'Samsung: also open Settings → Battery → Background usage limits and make sure JARVIS is NOT in "Sleeping apps" or "Deep sleeping apps".',
                style: TextStyle(color: JColors.dim, fontSize: 12),
              ),
            ),
            const SizedBox(height: 16),
            const Card(
              child: Padding(
                padding: EdgeInsets.all(14),
                child: Text(
                  'Known limits: the wake word works while the JARVIS listening notification is showing. '
                  'It stops if you force-stop the app or swipe it away and Android kills the process, and it does not '
                  'auto-start after a reboot (Android 15+ blocks microphone services at boot) — open JARVIS once after restarting.',
                  style: TextStyle(color: JColors.dim, fontSize: 12, height: 1.5),
                ),
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(onPressed: d.openAppSettings, icon: const Icon(Icons.settings), label: const Text('Open app info')),
          ],
        ),
      ),
    );
  }

  Widget _tile(String title, String desc, bool? ok, VoidCallback onFix, {Widget? extra}) {
    final color = ok == null ? JColors.dim : (ok ? JColors.green : JColors.amber);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(ok == true ? Icons.check_circle : Icons.error_outline, color: color),
              const SizedBox(width: 8),
              Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600))),
              Text(ok == null ? '…' : (ok ? 'Granted' : 'Needed'), style: TextStyle(color: color, fontSize: 12)),
            ]),
            const SizedBox(height: 6),
            Text(desc, style: const TextStyle(color: JColors.dim, fontSize: 12)),
            if (extra != null) ...[const SizedBox(height: 8), extra],
            if (ok != true) ...[
              const SizedBox(height: 8),
              FilledButton(onPressed: onFix, child: const Text('Fix')),
            ],
          ]),
        ),
      ),
    );
  }
}

class _A11yHelp extends StatelessWidget {
  const _A11yHelp();

  @override
  Widget build(BuildContext context) => const Text(
        'Sideloaded apps on Android 13+ are "restricted" first:\n'
        '1. Open app info (button below) → ⋮ (top-right) → "Allow restricted settings".\n'
        '2. Then Accessibility → Installed apps → JARVIS device control → On.',
        style: TextStyle(color: JColors.dim, fontSize: 12, height: 1.5),
      );
}

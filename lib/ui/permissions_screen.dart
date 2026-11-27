import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../device/device_bridge.dart';
import 'theme.dart';

/// Shows the REAL status of every permission LEO depends on, with a direct fix action.
class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key});

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen> with WidgetsBindingObserver {
  PermissionStatus? _mic, _notif, _contacts, _phone;
  bool? _a11y, _battery, _notifAccess, _assistant, _files, _exact;

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
    final files = await d.allFilesAccess();
    final exact = await d.exactAlarmsAllowed();
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
        _files = files;
        _exact = exact;
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
              'Wake word and voice commands. Audio is processed on-device until "Leo" is detected or you tap the mic.',
              _mic?.isGranted,
              () => _request(Permission.microphone),
            ),
            _tile(
              'Notifications',
              'Required to show the persistent "LEO is listening" notification (Android rule for background microphone).',
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
              'Make LEO your phone assistant: long-press the side key (or swipe up from a bottom corner) to open the half-screen LEO panel, like Gemini.',
              _assistant,
              d.openAssistantSettings,
              extra: const Text(
                'Samsung: Settings → Apps → Choose default apps → Digital assistant app → Device assistance app → LEO. '
                'Then Settings → Advanced features → Side button → Press and hold → Digital assistant.',
                style: TextStyle(color: JColors.dim, fontSize: 12),
              ),
            ),
            _tile(
              'All files access',
              'Lets "open my resume PDF" find documents anywhere on your phone (Downloads, WhatsApp Documents…). Searched on the phone only.',
              _files,
              d.openAllFilesSettings,
            ),
            _tile(
              'Alarms & reminders',
              'Lets LEO reminders ring at the exact minute.',
              _exact,
              d.openExactAlarmSettings,
            ),
            _tile(
              'Phone calls',
              'Lets LEO place, answer, reject and end calls when you ask ("Leo, answer", "Leo, cut the call").',
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
              'Lets LEO see and tap the app on screen when you ask it to do something (open, search, tap, scroll, switch off an alarm). Anything that sends, deletes, installs or pays waits for your approval. Banking and payment apps are never touched.',
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
                'Samsung: also open Settings → Battery → Background usage limits and make sure LEO is NOT in "Sleeping apps" or "Deep sleeping apps".',
                style: TextStyle(color: JColors.dim, fontSize: 12),
              ),
            ),
            const SizedBox(height: 16),
            const Card(
              child: Padding(
                padding: EdgeInsets.all(14),
                child: Text(
                  'Say "Leo" anywhere — even with LEO closed — and the panel slides up over the app you\'re in. '
                  'Set LEO as the Default assistant (above) so Android keeps it running and restarts it if it is closed. '
                  'The "LEO is listening" notification shows whenever the wake word is on. The panel cannot open over the lock screen — unlock first.',
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
            if (ok == true) ...[
              const SizedBox(height: 4),
              // Android only lets the user revoke a permission: take them straight to the switch.
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => title.toLowerCase().contains('accessibility')
                      ? context.read<DeviceBridge>().openAccessibilitySettings()
                      : openAppSettings(),
                  icon: const Icon(Icons.block, size: 16),
                  label: const Text('Revoke'),
                ),
              ),
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
        '2. Then Accessibility → Installed apps → LEO device control → On.',
        style: TextStyle(color: JColors.dim, fontSize: 12, height: 1.5),
      );
}

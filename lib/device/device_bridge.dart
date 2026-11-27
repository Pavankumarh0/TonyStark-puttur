import 'dart:async';

import 'package:flutter/services.dart';

class InstalledApp {
  final String label;
  final String packageName;
  const InstalledApp(this.label, this.packageName);
}

class ContactMatch {
  final String name;
  final List<String> numbers;
  final bool hasWhatsApp;
  const ContactMatch(this.name, this.numbers, this.hasWhatsApp);

  /// Primary number used as the stable recipient id for approvals.
  String get primaryNumber => numbers.first;
}

enum WhatsAppSendStatus { verified, sentUnverified, failed, cancelled, ambiguous }

class WhatsAppSendResult {
  final WhatsAppSendStatus status;
  final String? reason;
  final String? chatTitle;
  final List<String> candidates;
  final List<String> trace;
  const WhatsAppSendResult(this.status, {this.reason, this.chatTitle, this.candidates = const [], this.trace = const []});

  factory WhatsAppSendResult.fromMap(Map m) => WhatsAppSendResult(
        switch (m['status']) {
          'verified' => WhatsAppSendStatus.verified,
          'sent_unverified' => WhatsAppSendStatus.sentUnverified,
          'cancelled' => WhatsAppSendStatus.cancelled,
          'ambiguous' => WhatsAppSendStatus.ambiguous,
          _ => WhatsAppSendStatus.failed,
        },
        reason: m['reason'] as String?,
        chatTitle: m['chatTitle'] as String?,
        candidates: ((m['candidates'] as List?) ?? const []).cast<String>(),
        trace: ((m['trace'] as List?) ?? const []).cast<String>(),
      );

  /// True if the Send button was actually pressed (the message may be out — irreversible).
  bool get sendPressed => status == WhatsAppSendStatus.verified || status == WhatsAppSendStatus.sentUnverified;
}

/// Dart side of the native Android device-control layer (Kotlin: DeviceChannel.kt).
/// Receives only structured, already-approved actions.
class DeviceBridge {
  static const _ch = MethodChannel('jarvis/device');
  static const _events = EventChannel('jarvis/events');

  Stream<Map<String, dynamic>>? _eventStream;
  Stream<Map<String, dynamic>> get events => _eventStream ??=
      _events.receiveBroadcastStream().map((e) => Map<String, dynamic>.from(e as Map));

  Future<List<InstalledApp>> launchableApps() async {
    final list = await _ch.invokeListMethod<Map>('getLaunchableApps') ?? [];
    return [for (final m in list) InstalledApp(m['label'] as String, m['package'] as String)];
  }

  Future<bool> launchApp(String packageName) async =>
      await _ch.invokeMethod<bool>('launchApp', {'package': packageName}) ?? false;

  Future<bool> isInstalled(String packageName) async =>
      await _ch.invokeMethod<bool>('isInstalled', {'package': packageName}) ?? false;

  Future<List<ContactMatch>> searchContacts(String query) async {
    final list = await _ch.invokeListMethod<Map>('searchContacts', {'query': query}) ?? [];
    return [
      for (final m in list)
        ContactMatch(m['name'] as String, ((m['numbers'] as List?) ?? const []).cast<String>(), m['whatsapp'] == true)
    ];
  }

  Future<bool> accessibilityEnabled() async => await _ch.invokeMethod<bool>('accessibilityEnabled') ?? false;
  Future<void> openAccessibilitySettings() => _ch.invokeMethod('openAccessibilitySettings');
  Future<void> openAppSettings() => _ch.invokeMethod('openAppSettings');
  Future<bool> isIgnoringBatteryOptimizations() async =>
      await _ch.invokeMethod<bool>('isIgnoringBatteryOptimizations') ?? false;
  Future<void> requestIgnoreBatteryOptimizations() => _ch.invokeMethod('requestIgnoreBatteryOptimizations');

  Future<bool> startListenerService() async => await _ch.invokeMethod<bool>('startListenerService') ?? false;
  Future<void> stopListenerService() => _ch.invokeMethod('stopListenerService');
  Future<bool> isListenerServiceRunning() async => await _ch.invokeMethod<bool>('isListenerServiceRunning') ?? false;
  Future<void> updateServiceStatus(String text) => _ch.invokeMethod('updateServiceStatus', {'text': text});

  /// Opens the chat with the message pre-filled; the USER presses Send (no accessibility needed).
  Future<bool> openWhatsAppChat(String packageName, String phone, String text) async =>
      await _ch.invokeMethod<bool>('openWhatsAppChat', {'package': packageName, 'phone': phone, 'text': text}) ?? false;

  /// Performs an approved send through the accessibility service and verifies the result.
  Future<WhatsAppSendResult> whatsappSend({
    required String packageName,
    String? phone,
    String? searchName,
    required String message,
  }) async {
    final m = await _ch.invokeMapMethod<String, dynamic>('whatsappSend', {
      'package': packageName,
      'phone': phone,
      'searchName': searchName,
      'message': message,
    });
    return WhatsAppSendResult.fromMap(m ?? const {'status': 'failed', 'reason': 'No result from device layer'});
  }

  Future<void> whatsappCancel() => _ch.invokeMethod('whatsappCancel');
  Future<void> bringToFront() => _ch.invokeMethod('bringToFront');
  Future<bool> composeEmail(String? subject, String body) async =>
      await _ch.invokeMethod<bool>('composeEmail', {'subject': subject, 'body': body}) ?? false;

  // ---- media / calls / notifications (all local, no AI)
  Future<Map<String, dynamic>> playMedia(String app, String query) async =>
      await _ch.invokeMapMethod<String, dynamic>('playMedia', {'app': app, 'query': query}) ??
      const {'status': 'failed', 'reason': 'No result'};

  /// Returns "calling", "dialer_opened" (no CALL_PHONE permission) or "failed:<reason>".
  Future<String> placeCall(String number) async =>
      await _ch.invokeMethod<String>('placeCall', {'number': number}) ?? 'failed:no result';

  Future<bool> notificationAccess() async => await _ch.invokeMethod<bool>('notificationAccess') ?? false;
  Future<void> openNotificationAccessSettings() => _ch.invokeMethod('openNotificationAccessSettings');

  Future<List<NotificationItem>> readNotifications({bool whatsapp = true, bool email = true, bool sms = false}) async {
    final list = await _ch.invokeListMethod<Map>('readNotifications', {
          'kinds': [if (whatsapp) 'whatsapp', if (email) 'email', if (sms) 'sms']
        }) ??
        [];
    return [for (final m in list) NotificationItem.fromMap(m)];
  }

  /// Controls the playing app via its media session. Returns {status, title, artist, app} where status is
  /// paused | playing | done | not_playing | already_playing | nothing_to_resume | unchanged.
  Future<Map<String, dynamic>> mediaControl(String action) async =>
      await _ch.invokeMapMethod<String, dynamic>('mediaControl', {'action': action}) ?? const {'status': 'unchanged'};

  Future<Map<String, dynamic>> nowPlaying() async =>
      await _ch.invokeMapMethod<String, dynamic>('nowPlaying') ?? const {};

  /// While listening, pause other audio (transient focus) like Gemini/Assistant; it resumes after.
  /// Wake word heard: slide up the LEO panel over the current app if no LEO screen is showing.
  /// Returns visible | session | activity | failed: ….
  Future<String> wakePopup() async {
    try {
      return await _ch.invokeMethod<String>('wakePopup') ?? 'failed';
    } catch (e) {
      return 'failed: $e';
    }
  }

  Future<void> listenFocus(bool on) => _ch.invokeMethod('listenFocus', {'on': on});

  // ---- everyday phone actions (local, no AI). Each returns {ok, reason?}.
  Future<Map<String, dynamic>> _act(String m, [Map<String, dynamic>? a]) async =>
      await _ch.invokeMapMethod<String, dynamic>(m, a) ?? const {'ok': false};
  Future<Map<String, dynamic>> setAlarm(int hour, int minute, {String? message}) =>
      _act('setAlarm', {'hour': hour, 'minute': minute, 'message': message});
  Future<Map<String, dynamic>> setTimer(int seconds, {String? message}) =>
      _act('setTimer', {'seconds': seconds, 'message': message});
  Future<Map<String, dynamic>> insertEvent(String title, DateTime begin, DateTime end, {String? description, List<String> emails = const []}) =>
      _act('insertEvent', {
        'title': title, 'begin': begin.millisecondsSinceEpoch, 'end': end.millisecondsSinceEpoch,
        'description': description, 'emails': emails,
      });
  Future<Map<String, dynamic>> openUrl(String url, {String? package}) => _act('openUrl', {'url': url, 'package': package});
  Future<Map<String, dynamic>> navigate(String place) => _act('navigate', {'place': place});
  Future<Map<String, dynamic>> webSearch(String query) => _act('webSearch', {'query': query});
  Future<Map<String, dynamic>> torch(bool on) => _act('torch', {'on': on});
  Future<Map<String, dynamic>> camera({bool selfie = false, bool video = false}) => _act('camera', {'selfie': selfie, 'video': video});
  Future<Map<String, dynamic>> panel(String kind) => _act('panel', {'kind': kind});
  Future<List<Map<String, String>>> contactEmails(String name) async {
    final l = await _ch.invokeListMethod<Map>('contactEmails', {'name': name}) ?? [];
    return [for (final m in l) {'name': m['name'] as String, 'email': m['email'] as String}];
  }

  // ---- on-device model (screen-agent brain, no key)
  Future<Map<String, dynamic>> llmStatus() async =>
      await _ch.invokeMapMethod<String, dynamic>('llmStatus') ?? const {'installed': false};
  Future<void> llmDownload() => _ch.invokeMethod('llmDownload');
  Future<void> llmCancelDownload() => _ch.invokeMethod('llmCancelDownload');
  Future<void> llmDelete() => _ch.invokeMethod('llmDelete');
  Future<void> llmUnload() => _ch.invokeMethod('llmUnload');
  Future<int> llmCountTokens(String text) async => await _ch.invokeMethod<int>('llmCountTokens', {'text': text}) ?? text.length ~/ 3;
  Future<String> llmGenerate(String prompt) async => await _ch.invokeMethod<String>('llmGenerate', {'prompt': prompt}) ?? '';

  // ---- generic screen control (accessibility)
  Future<Map<String, dynamic>> screenDump({int max = 70, bool skipOwn = false}) async =>
      await _ch.invokeMapMethod<String, dynamic>('screenDump', {'max': max, 'skipOwn': skipOwn}) ?? const {'ok': false, 'reason': 'no_result'};
  /// Visible text of the app on screen (skipOwn: the app UNDER LEO's assistant panel).
  Future<Map<String, dynamic>> screenText({bool skipOwn = false}) async =>
      await _ch.invokeMapMethod<String, dynamic>('screenText', {'skipOwn': skipOwn}) ?? const {'ok': false};
  Future<Map<String, dynamic>> screenAct(String type, {int? index, String? text, String? dir, String? package}) async =>
      await _ch.invokeMapMethod<String, dynamic>('screenAct', {'type': type, 'index': index, 'text': text, 'dir': dir, 'package': package}) ??
      const {'ok': false};
  // Live overlay shown above other apps while the agent operates them.
  Future<void> overlayShow() => _ch.invokeMethod('overlayShow');
  Future<void> overlayUpdate({String? title, String? detail, int? highlightIndex, bool warn = false}) =>
      _ch.invokeMethod('overlayUpdate', {'title': title, 'detail': detail, 'index': highlightIndex, 'warn': warn});
  Future<void> overlayHide() => _ch.invokeMethod('overlayHide');

  Future<bool> isBlockedApp(String pkg) async => await _ch.invokeMethod<bool>('isBlockedApp', {'package': pkg}) ?? false;
  /// Real on/off via Quick Settings. status: already | changed | unknown | unchanged | not_found | accessibility_off
  Future<Map<String, dynamic>> quickToggle(String kind, bool on) async =>
      await _ch.invokeMapMethod<String, dynamic>('quickToggle', {'kind': kind, 'on': on}) ?? const {'ok': false};

  // ---- reply straight from a chat notification
  Future<List<Map<String, dynamic>>> replyTargets(String who) async =>
      [for (final m in await _ch.invokeListMethod<Map>('replyTargets', {'who': who}) ?? []) Map<String, dynamic>.from(m)];
  Future<Map<String, dynamic>> notificationReply(String key, String text) async =>
      await _ch.invokeMapMethod<String, dynamic>('notificationReply', {'key': key, 'text': text}) ?? const {'ok': false};

  // ---- alarms / reminders / calls / files (local)
  /// Opens the Clock alarm list and flips matching alarm switches off (accessibility). hour is 0..23.
  Future<Map<String, dynamic>> clockSwitchOff({int? hour, int? minute, bool ampmKnown = false, bool all = false}) =>
      _act('clockSwitchOff', {'hour': hour, 'minute': minute, 'ampmKnown': ampmKnown, 'all': all});

  Future<Map<String, dynamic>> dismissAlarm({String mode = 'next', int? hour, int? minute, String? label}) =>
      _act('dismissAlarm', {'mode': mode, 'hour': hour, 'minute': minute, 'label': label});
  Future<Map<String, dynamic>> snoozeAlarm({int? minutes}) => _act('snoozeAlarm', {'minutes': minutes});
  Future<Map<String, dynamic>> addReminder(DateTime at, String text) =>
      _act('addReminder', {'at': at.millisecondsSinceEpoch, 'text': text});
  Future<List<Map<String, dynamic>>> listReminders() async =>
      [for (final m in await _ch.invokeListMethod<Map>('listReminders') ?? []) Map<String, dynamic>.from(m)];
  Future<Map<String, dynamic>> deleteReminder({int? id}) => _act('deleteReminder', {'id': id});
  Future<bool> exactAlarmsAllowed() async => await _ch.invokeMethod<bool>('exactAlarmsAllowed') ?? true;
  Future<void> openExactAlarmSettings() => _ch.invokeMethod('openExactAlarmSettings');
  Future<Map<String, dynamic>> answerCall() => _act('answerCall');
  Future<Map<String, dynamic>> endCall() => _act('endCall');
  Future<String> callState() async => await _ch.invokeMethod<String>('callState') ?? 'unknown';
  Future<bool> allFilesAccess() async => await _ch.invokeMethod<bool>('allFilesAccess') ?? false;
  Future<void> openAllFilesSettings() => _ch.invokeMethod('openAllFilesSettings');
  Future<List<Map<String, dynamic>>> findFiles(String query, {List<String> exts = const ['pdf']}) async =>
      [for (final m in await _ch.invokeListMethod<Map>('findFiles', {'query': query, 'exts': exts}) ?? []) Map<String, dynamic>.from(m)];
  Future<Map<String, dynamic>> openFile(String path) => _act('openFile', {'path': path});

  // ---- sign-in help (LEO only acts on the user's answers; never types passwords)
  Future<Map<String, dynamic>> loginScan(String pkg) async =>
      await _ch.invokeMapMethod<String, dynamic>('loginScan', {'package': pkg}) ?? const {'needsLogin': false};
  Future<bool> loginChoose(String pkg, String method) async =>
      (await _ch.invokeMapMethod<String, dynamic>('loginChoose', {'package': pkg, 'method': method}))?['ok'] == true;
  Future<List<String>> loginAccounts(String pkg) async =>
      (await _ch.invokeListMethod<String>('loginAccounts', {'package': pkg})) ?? const [];
  Future<bool> loginPickAccount(String pkg, String email) async =>
      (await _ch.invokeMapMethod<String, dynamic>('loginPickAccount', {'package': pkg, 'email': email}))?['ok'] == true;
  Future<Map<String, dynamic>> loginEnter(String pkg, String value) async =>
      await _ch.invokeMapMethod<String, dynamic>('loginEnter', {'package': pkg, 'value': value}) ?? const {'ok': false};
  Future<bool> loginPasswordShowing(String pkg) async =>
      await _ch.invokeMethod<bool>('loginPasswordShowing', {'package': pkg}) ?? false;
  Future<void> loginRelease() => _ch.invokeMethod('loginRelease');

  // ---- assistant role / half-screen panel
  Future<bool> isDefaultAssistant() async => await _ch.invokeMethod<bool>('isDefaultAssistant') ?? false;
  Future<void> openAssistantSettings() => _ch.invokeMethod('openAssistantSettings');
  Future<void> closeAssist() => _ch.invokeMethod('closeAssist');
  Future<void> openFullApp() => _ch.invokeMethod('openFullApp');
}

class NotificationItem {
  final String packageName;
  final String title;
  final List<String> lines;
  final int count;
  final DateTime time;
  final String? subText;
  const NotificationItem(this.packageName, this.title, this.lines, this.count, this.time, this.subText);

  bool get isWhatsApp => packageName.startsWith('com.whatsapp');

  factory NotificationItem.fromMap(Map m) => NotificationItem(
        m['package'] as String,
        m['title'] as String,
        ((m['lines'] as List?) ?? const []).cast<String>(),
        (m['count'] as int?) ?? 0,
        DateTime.fromMillisecondsSinceEpoch((m['time'] as int?) ?? 0),
        m['subText'] as String?,
      );
}

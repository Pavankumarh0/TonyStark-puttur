import 'dart:math';

import 'device_bridge.dart';

/// Resolves a spoken app name to installed packages — locally, no AI.
class AppResolver {
  /// Spoken aliases → candidate packages (first installed one wins). Includes Samsung packages.
  static const Map<String, List<String>> aliases = {
    'whatsapp': ['com.whatsapp'],
    'whatsapp business': ['com.whatsapp.w4b'],
    'business whatsapp': ['com.whatsapp.w4b'],
    'youtube': ['com.google.android.youtube'],
    'gmail': ['com.google.android.gm'],
    'mail': ['com.google.android.gm', 'com.samsung.android.email.provider'],
    'email': ['com.google.android.gm', 'com.samsung.android.email.provider'],
    'chrome': ['com.android.chrome'],
    'browser': ['com.android.chrome', 'com.sec.android.app.sbrowser'],
    'internet': ['com.sec.android.app.sbrowser', 'com.android.chrome'],
    'maps': ['com.google.android.apps.maps'],
    'google maps': ['com.google.android.apps.maps'],
    'camera': ['com.sec.android.app.camera', 'com.google.android.GoogleCamera', 'com.android.camera'],
    'gallery': ['com.sec.android.gallery3d', 'com.google.android.apps.photos'],
    'photos': ['com.google.android.apps.photos', 'com.sec.android.gallery3d'],
    'settings': ['com.android.settings'],
    'phone': ['com.samsung.android.dialer', 'com.google.android.dialer'],
    'dialer': ['com.samsung.android.dialer', 'com.google.android.dialer'],
    'contacts': ['com.samsung.android.app.contacts', 'com.google.android.contacts'],
    'messages': ['com.samsung.android.messaging', 'com.google.android.apps.messaging'],
    'sms': ['com.samsung.android.messaging', 'com.google.android.apps.messaging'],
    'calculator': ['com.sec.android.app.popupcalculator', 'com.google.android.calculator'],
    'clock': ['com.sec.android.app.clockpackage', 'com.google.android.deskclock'],
    'alarm': ['com.sec.android.app.clockpackage', 'com.google.android.deskclock'],
    'calendar': ['com.samsung.android.calendar', 'com.google.android.calendar'],
    'play store': ['com.android.vending'],
    'store': ['com.android.vending'],
    'files': ['com.sec.android.app.myfiles', 'com.google.android.apps.nbu.files'],
    'my files': ['com.sec.android.app.myfiles'],
    'file manager': ['com.sec.android.app.myfiles', 'com.google.android.apps.nbu.files'],
    'notes': ['com.samsung.android.app.notes', 'com.google.android.keep'],
    'instagram': ['com.instagram.android'],
    'spotify': ['com.spotify.music'],
    'telegram': ['org.telegram.messenger'],
    'linkedin': ['com.linkedin.android'],
    'drive': ['com.google.android.apps.docs'],
    'google drive': ['com.google.android.apps.docs'],
    'google': ['com.google.android.googlequicksearchbox'],
    'meet': ['com.google.android.apps.tachyon', 'com.google.android.apps.meetings'],
    'zoom': ['us.zoom.videomeetings'],
    'teams': ['com.microsoft.teams'],
    'chatgpt': ['com.openai.chatgpt'],
    'gemini': ['com.google.android.apps.bard'],
  };

  List<InstalledApp> _apps = [];
  DateTime? _loadedAt;
  final DeviceBridge bridge;
  AppResolver(this.bridge);

  Future<List<InstalledApp>> apps({bool refresh = false}) async {
    if (refresh || _loadedAt == null || DateTime.now().difference(_loadedAt!) > const Duration(minutes: 5)) {
      _apps = await bridge.launchableApps();
      _loadedAt = DateTime.now();
    }
    return _apps;
  }

  static String _n(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Returns matches, best first. Empty = not installed / not understood.
  Future<List<InstalledApp>> resolve(String spoken) async {
    final installed = await apps();
    final q = _n(spoken).replaceAll(RegExp(r'\b(app|application)\b'), '').trim();
    if (q.isEmpty) return [];
    final byPkg = {for (final a in installed) a.packageName: a};

    final alias = aliases[q];
    if (alias != null) {
      for (final p in alias) {
        final a = byPkg[p];
        if (a != null) return [a];
      }
    }
    final exact = installed.where((a) => _n(a.label) == q).toList();
    if (exact.isNotEmpty) return exact;
    final starts = installed.where((a) => _n(a.label).startsWith(q)).toList();
    if (starts.isNotEmpty) return starts;
    final contains = installed.where((a) => _n(a.label).contains(q)).toList();
    if (contains.isNotEmpty) return contains;

    final scored = <(InstalledApp, double)>[];
    for (final a in installed) {
      final s = similarity(_n(a.label), q);
      if (s >= 0.72) scored.add((a, s));
    }
    scored.sort((x, y) => y.$2.compareTo(x.$2));
    return scored.map((e) => e.$1).take(3).toList();
  }

  static double similarity(String a, String b) {
    if (a == b) return 1;
    if (a.isEmpty || b.isEmpty) return 0;
    final d = _lev(a, b);
    return 1 - d / max(a.length, b.length);
  }

  static int _lev(String a, String b) {
    var prev = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final cur = List<int>.filled(b.length + 1, 0);
      cur[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        cur[j] = min(min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
      }
      prev = cur;
    }
    return prev[b.length];
  }
}

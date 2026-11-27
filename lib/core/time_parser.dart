/// Local (no AI) date/time understanding for alarms, timers, reminders and meetings.
/// Pure Dart so it is unit-tested.
library;

class ParsedWhen {
  final DateTime at;
  final bool hadTime; // the user said a clock time (vs only a day)
  final bool hadDay; // the user said a day
  const ParsedWhen(this.at, {required this.hadTime, required this.hadDay});
}

class TimeParser {
  static const _weekdays = {
    'monday': 1, 'tuesday': 2, 'wednesday': 3, 'thursday': 4, 'friday': 5, 'saturday': 6, 'sunday': 7,
  };
  static const _months = {
    'january': 1, 'jan': 1, 'february': 2, 'feb': 2, 'march': 3, 'mar': 3, 'april': 4, 'apr': 4, 'may': 5,
    'june': 6, 'jun': 6, 'july': 7, 'jul': 7, 'august': 8, 'aug': 8, 'september': 9, 'sep': 9, 'sept': 9,
    'october': 10, 'oct': 10, 'november': 11, 'nov': 11, 'december': 12, 'dec': 12,
  };
  static const _numWords = {
    'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5, 'six': 6, 'seven': 7, 'eight': 8, 'nine': 9,
    'ten': 10, 'eleven': 11, 'twelve': 12, 'fifteen': 15, 'twenty': 20, 'thirty': 30, 'forty': 40,
    'forty five': 45, 'fifty': 50, 'sixty': 60, 'ninety': 90, 'a': 1, 'an': 1,
  };

  static String _norm(String s) {
    var t = ' ${s.toLowerCase().replaceAll(RegExp(r'[,!?]'), ' ')} ';
    t = t.replaceAllMapped(RegExp(r'(\d)\.(\d\d)'), (m) => '${m[1]}:${m[2]}'); // 6.30 → 6:30
    t = t.replaceAll(RegExp(r'\b(a\.m\.|a m)\b'), 'am').replaceAll(RegExp(r'\b(p\.m\.|p m)\b'), 'pm');
    // "6 o'clock" → "6:00" (a bare number isn't a time, "6:00" is)
    t = t.replaceAllMapped(RegExp(r"\b(\d{1,2})\s*o'?\s?clock\b"), (m) => '${m[1]}:00');
    t = t.replaceAll('o\'clock', '').replaceAll('oclock', '');
    for (final e in _numWords.entries.toList()..sort((a, b) => b.key.length.compareTo(a.key.length))) {
      if (e.key == 'a' || e.key == 'an') continue;
      t = t.replaceAll(RegExp('\\b${e.key}\\b'), '${e.value}');
    }
    // "six thirty pm" → "6 30 pm" → "6:30 pm"
    t = t.replaceAllMapped(RegExp(r'\b(\d{1,2}) ([0-5]\d)(\s*(am|pm)\b)'), (m) => '${m[1]}:${m[2]}${m[3]}');
    return t.replaceAll(RegExp(r'\s+'), ' ');
  }

  /// Duration like "10 minutes", "1 hour 30 minutes", "90 seconds", "half an hour".
  static Duration? duration(String text) {
    final t = _norm(text);
    if (RegExp(r'\bhalf an? hour\b').hasMatch(t)) return const Duration(minutes: 30);
    if (RegExp(r'\b(a|an|1) quarter (of an )?hour\b').hasMatch(t)) return const Duration(minutes: 15);
    var total = Duration.zero;
    var found = false;
    for (final m in RegExp(r'\b(\d+|an?)\s*(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\b').allMatches(t)) {
      final n = int.tryParse(m.group(1)!) ?? 1;
      final u = m.group(2)!;
      if (u.startsWith('h')) {
        total += Duration(hours: n);
      } else if (u.startsWith('m')) {
        total += Duration(minutes: n);
      } else {
        total += Duration(seconds: n);
      }
      found = true;
    }
    return found && total > Duration.zero ? total : null;
  }

  /// Finds a date/time in [text]. [preferPm] treats 1–7 without am/pm as afternoon (meetings).
  static ParsedWhen? when(String text, {DateTime? now, bool preferPm = false}) {
    final n = now ?? DateTime.now();
    final t = _norm(text);

    // Relative: "in 10 minutes", "in 2 hours"
    final rel = RegExp(r'\bin (\d+|an?|half an?) ?(hours?|hrs?|minutes?|mins?|seconds?|secs?)\b').firstMatch(t);
    if (rel != null) {
      final d = duration(rel.group(0)!.replaceFirst('in ', ''));
      if (d != null) return ParsedWhen(n.add(d), hadTime: true, hadDay: false);
    }

    // ---- day
    DateTime? day;
    if (RegExp(r'\bday after tomorrow\b').hasMatch(t)) {
      day = DateTime(n.year, n.month, n.day + 2);
    } else if (RegExp(r'\b(tomorrow|tmrw|tmr)\b').hasMatch(t)) {
      day = DateTime(n.year, n.month, n.day + 1);
    } else if (RegExp(r'\b(today|tonight|this (morning|afternoon|evening))\b').hasMatch(t)) {
      day = DateTime(n.year, n.month, n.day);
    } else {
      for (final e in _weekdays.entries) {
        if (RegExp('\\b(next |this |on )?${e.key}\\b').hasMatch(t)) {
          var diff = (e.value - n.weekday) % 7;
          if (diff == 0 || t.contains('next ${e.key}')) diff = diff == 0 ? 7 : diff;
          day = DateTime(n.year, n.month, n.day + diff);
          break;
        }
      }
      if (day == null) {
        // "5th december" / "5 of december" and "december 5" — tried as separate patterns so an
        // earlier word ("on 5") can't swallow the real date.
        final pats = [
          RegExp(r'\b(\d{1,2})(?:st|nd|rd|th)?(?: of)? ([a-z]+)\b'),
          RegExp(r'\b([a-z]+) (\d{1,2})(?:st|nd|rd|th)?\b'),
        ];
        outer:
        for (var pi = 0; pi < pats.length; pi++) {
          for (final m in pats[pi].allMatches(t)) {
            final dd = int.tryParse(pi == 0 ? m.group(1)! : m.group(2)!);
            final mon = _months[pi == 0 ? m.group(2)! : m.group(1)!];
            if (dd != null && mon != null && dd >= 1 && dd <= 31) {
              var y = n.year;
              if (DateTime(y, mon, dd).isBefore(DateTime(n.year, n.month, n.day))) y++;
              day = DateTime(y, mon, dd);
              break outer;
            }
          }
        }
      }
    }

    // ---- time
    int? hour;
    var minute = 0;
    final tm = RegExp(r'\b(?:at |by |for )?(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b').firstMatch(t) ??
        RegExp(r'\b(?:at|by|for) (\d{1,2})(?::(\d{2}))?\b(?!\s*(?:minutes?|mins?|hours?|hrs?|seconds?|secs?|days?|people|members))')
            .firstMatch(t) ??
        RegExp(r'\b(\d{1,2}):(\d{2})\b').firstMatch(t);
    String? ampm;
    if (tm != null) {
      hour = int.parse(tm.group(1)!);
      minute = int.tryParse(tm.group(2) ?? '') ?? 0;
      ampm = tm.groupCount >= 3 ? tm.group(3) : null;
    } else if (RegExp(r'\bnoon\b|\bmidday\b').hasMatch(t)) {
      hour = 12;
    } else if (RegExp(r'\bmidnight\b').hasMatch(t)) {
      hour = 0;
    } else if (RegExp(r'\bmorning\b').hasMatch(t)) {
      hour = 9;
    } else if (RegExp(r'\bafternoon\b').hasMatch(t)) {
      hour = 14;
    } else if (RegExp(r'\bevening\b').hasMatch(t)) {
      hour = 18;
    } else if (RegExp(r'\btonight\b|\bnight\b').hasMatch(t)) {
      hour = 20;
    }
    if (hour == null && day == null) return null;
    if (hour != null && (hour > 23 || minute > 59)) return null;

    if (hour != null && ampm != null) {
      if (ampm == 'pm' && hour < 12) hour += 12;
      if (ampm == 'am' && hour == 12) hour = 0;
    } else if (hour != null && hour >= 1 && hour <= 12 && tm != null) {
      // No am/pm: context words, then a sensible default.
      if (RegExp(r'\b(evening|night|tonight|afternoon)\b').hasMatch(t) && hour < 12) {
        hour += 12;
      } else if (RegExp(r'\bmorning\b').hasMatch(t)) {
        if (hour == 12) hour = 0;
      } else if (preferPm && hour >= 1 && hour <= 7) {
        hour += 12;
      } else if (day == null && hour < 12) {
        // Next occurrence: if 6:30 already passed today, 18:30 if still ahead, else tomorrow 6:30.
        final am = DateTime(n.year, n.month, n.day, hour, minute);
        final pm = am.add(const Duration(hours: 12));
        if (!am.isAfter(n) && pm.isAfter(n)) hour += 12;
      }
    }

    final base = day ?? DateTime(n.year, n.month, n.day);
    var at = DateTime(base.year, base.month, base.day, hour ?? 9, minute);
    if (day == null && !at.isAfter(n)) at = at.add(const Duration(days: 1)); // time already passed today
    return ParsedWhen(at, hadTime: hour != null, hadDay: day != null);
  }

  static String spoken(DateTime d, {DateTime? now}) {
    final n = now ?? DateTime.now();
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final time = '$h${d.minute == 0 ? '' : ':${d.minute.toString().padLeft(2, '0')}'} ${d.hour < 12 ? 'AM' : 'PM'}';
    final today = DateTime(n.year, n.month, n.day);
    final dd = DateTime(d.year, d.month, d.day).difference(today).inDays;
    final day = switch (dd) {
      0 => 'today',
      1 => 'tomorrow',
      _ when dd > 1 && dd < 7 => const ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'][d.weekday - 1],
      _ => '${d.day} ${const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][d.month - 1]}',
    };
    return '$time $day';
  }

  static String spokenDuration(Duration d) {
    final parts = <String>[];
    if (d.inHours > 0) parts.add('${d.inHours} hour${d.inHours == 1 ? '' : 's'}');
    final m = d.inMinutes % 60;
    if (m > 0) parts.add('$m minute${m == 1 ? '' : 's'}');
    final s = d.inSeconds % 60;
    if (s > 0) parts.add('$s second${s == 1 ? '' : 's'}');
    return parts.join(' ');
  }
}

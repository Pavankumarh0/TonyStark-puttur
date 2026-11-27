import 'dart:math';

import 'local_intent.dart';

/// On-device intent model: multinomial Naive Bayes over word uni/bi-grams and character
/// tri-grams. Trains in milliseconds on the phone from (a) a built-in seed set and (b) examples
/// learned from this user's own successful commands — including requests that once needed AI.
/// Used only when the hand-written rules don't match, BEFORE any AI call.
class LocalIntentClassifier {
  final Map<String, Map<String, int>> _counts = {};
  final Map<String, int> _totals = {};
  final Map<String, int> _docs = {};
  final Set<String> _vocab = {};
  int _nDocs = 0;

  int get exampleCount => _nDocs;
  Set<String> get labels => _docs.keys.toSet();

  static const seed = <String, List<String>>{
    'play_media': [
      'play pesamale song in youtube', 'play arijit singh songs', 'play some music', 'play the song believer',
      'put on lofi music', 'i want to listen to kesariya', 'play shape of you on youtube', 'can you play a song by anirudh',
      'play the latest kannada songs', 'start playing naatu naatu', 'play hanuman chalisa', 'play video of virat kohli',
      'youtube play tum hi ho', 'play songs of sonu nigam', 'i want to watch mr beast', 'listen to coldplay yellow',
      'play my favourite song pesamale', 'search and play bhajan on youtube',
    ],
    'call': [
      'call pavan', 'call mom', 'phone dad', 'dial ravi', 'ring my brother', 'make a call to rahul',
      'give a call to yadava', 'call pavan kumar on his mobile', 'please call amma', 'phone the office',
      'can you call suresh', 'place a call to akash', 'call sir', 'i want to call my friend kiran', 'get rahul on the phone',
    ],
    'check_messages': [
      'check new messages in whatsapp', 'any new messages', 'check my email', 'read my messages',
      'do i have any unread whatsapp messages', 'what are my new emails', 'check whatsapp and email',
      'did i get any mail', 'show my inbox', 'any messages from rahul', 'read out my latest messages',
      'check new messages in whatsapp and email', 'have i got any new mails', 'what did people message me',
      'any whatsapp updates', 'check my notifications for messages',
    ],
    'open_app': [
      'open whatsapp', 'launch youtube', 'open camera', 'start instagram', 'open settings', 'go to gmail',
      'open the calculator app', 'launch spotify', 'open chrome', 'show me the gallery', 'open play store',
      'open maps', 'bring up the clock', 'open my files', 'open phone app', 'open snapchat',
    ],
    'send_message': [
      'send a message to rahul saying hi', 'message mom that i will be late', 'whatsapp yadava ise saying i am not coming',
      'text ravi i reached', 'tell kiran that the meeting is at 5', 'send hi to the college group',
      'message the group class is cancelled', 'drop a message to suresh',
    ],
    'time': ['what time is it', 'tell me the time', 'current time', 'what is the time now', 'time please'],
    'date': ['what is the date', 'what day is it', 'todays date', 'what is today', 'which day is today'],
    'stop': ['stop', 'stop it', 'halt', 'stop now', 'abort', 'be quiet', 'shut up'],
    'pause': ['pause', 'hold on', 'wait a second', 'pause the task', 'hold it'],
    'resume': ['resume', 'continue', 'carry on', 'go on', 'keep going'],
    'cancel': ['cancel', 'cancel this task', 'forget it', 'never mind', 'drop it'],
    'status': ['what are you doing', 'status', 'what is happening', 'what are you working on', 'where are we'],
    'greeting': ['hello', 'hi leo', 'hey', 'good morning', 'good evening', 'are you there'],
    'write': [
      'write an email to my professor', 'draft a leave letter', 'compose a message for my team', 'write a post about ai',
      'rewrite this paragraph', 'make this more professional', 'write a cover letter', 'draft a reply to the client',
      'write content and send it', 'write a birthday wish for my sister',
    ],
    'knowledge': [
      'who is the prime minister of india', 'what is a black hole', 'explain photosynthesis', 'how does wifi work',
      'tell me about tony stark', 'what is the capital of france', 'why is the sky blue', 'define machine learning',
      'how far is the moon', 'what is the meaning of life', 'tell me a joke', 'suggest a good movie',
    ],
  };

  /// Labels that the local executor can carry out on its own.
  static const localLabels = {
    'play_media', 'call', 'check_messages', 'open_app', 'time', 'date', 'stop', 'pause', 'resume', 'cancel', 'status', 'greeting',
  };

  static List<String> features(String text) {
    final n = text.toLowerCase().replaceAll(RegExp(r"[^a-z0-9' ]"), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    final words = n.split(' ').where((w) => w.isNotEmpty).toList();
    final f = <String>[];
    for (var i = 0; i < words.length; i++) {
      f.add('w:${words[i]}');
      if (i + 1 < words.length) f.add('b:${words[i]}_${words[i + 1]}');
      if (i == 0) f.add('first:${words[i]}');
    }
    for (final w in words) {
      final p = '#$w#';
      for (var i = 0; i + 3 <= p.length; i++) {
        f.add('c:${p.substring(i, i + 3)}');
      }
    }
    return f;
  }

  void add(String text, String label) {
    final f = features(text);
    if (f.isEmpty) return;
    final c = _counts.putIfAbsent(label, () => {});
    for (final x in f) {
      c[x] = (c[x] ?? 0) + 1;
      _vocab.add(x);
    }
    _totals[label] = (_totals[label] ?? 0) + f.length;
    _docs[label] = (_docs[label] ?? 0) + 1;
    _nDocs++;
  }

  void train({Iterable<(String, String)> learned = const []}) {
    _counts.clear();
    _totals.clear();
    _docs.clear();
    _vocab.clear();
    _nDocs = 0;
    seed.forEach((label, examples) {
      for (final e in examples) {
        add(e, label);
      }
    });
    for (final (text, label) in learned) {
      add(text, label);
    }
  }

  /// Returns (label, probability) sorted best-first.
  List<(String, double)> predict(String text) {
    final f = features(text);
    if (f.isEmpty || _nDocs == 0) return const [];
    final v = _vocab.length + 1;
    final logs = <String, double>{};
    for (final label in _docs.keys) {
      var lp = log(_docs[label]! / _nDocs);
      final c = _counts[label]!;
      final t = _totals[label]!;
      for (final x in f) {
        lp += log(((c[x] ?? 0) + 0.5) / (t + 0.5 * v));
      }
      logs[label] = lp;
    }
    final mx = logs.values.reduce(max);
    final z = logs.values.fold<double>(0, (a, b) => a + exp(b - mx));
    final out = [for (final e in logs.entries) (e.key, exp(e.value - mx) / z)];
    out.sort((a, b) => b.$2.compareTo(a.$2));
    return out;
  }

  /// Classifies and extracts slots. Returns null if not confident or the label needs AI.
  LocalIntent? classify(String text, {double minConfidence = 0.7}) {
    final p = predict(text);
    if (p.isEmpty) return null;
    final (label, conf) = p.first;
    if (conf < minConfidence || !localLabels.contains(label)) return null;
    final lower = text.toLowerCase();
    switch (label) {
      case 'play_media':
        final q = _strip(text, _mediaFiller);
        if (q.isEmpty) return null;
        final app = lower.contains('spotify')
            ? MediaApp.spotify
            : (lower.contains('youtube music') ? MediaApp.youtubeMusic : MediaApp.youtube);
        return PlayMediaIntent(q, app);
      case 'call':
        final name = _strip(text, _callFiller);
        return name.isEmpty ? null : CallIntent(name);
      case 'check_messages':
        final wa = RegExp(r'whatsapp|message|chat|text').hasMatch(lower);
        final mail = RegExp(r'mail|inbox|gmail').hasMatch(lower);
        return CheckMessagesIntent(whatsapp: wa || !mail, email: mail || !wa);
      case 'open_app':
        final app = _strip(text, _openFiller);
        return app.isEmpty ? null : OpenAppIntent(app);
      case 'time':
        return const TellTimeIntent();
      case 'date':
        return const TellDateIntent();
      case 'stop':
        return const StopIntent();
      case 'pause':
        return const PauseIntent();
      case 'resume':
        return const ResumeIntent();
      case 'cancel':
        return const CancelTaskIntent();
      case 'status':
        return const StatusIntent();
      case 'greeting':
        return const GreetingIntent();
    }
    return null;
  }

  static const _common = {'please', 'jarvis', 'leo', 'can', 'you', 'could', 'would', 'will', 'i', 'want', 'to', 'the', 'a', 'my', 'for', 'me', 'now', 'just'};
  static const _mediaFiller = {..._common, 'play', 'put', 'on', 'start', 'playing', 'listen', 'hear', 'watch', 'in', 'youtube', 'spotify', 'music', 'search', 'and', 'video', 'of', 'some', 'favourite', 'favorite', 'app'};
  static const _callFiller = {..._common, 'call', 'phone', 'dial', 'ring', 'give', 'make', 'place', 'get', 'on', 'his', 'her', 'their', 'mobile', 'number', 'contact', 'up'};
  static const _openFiller = {..._common, 'open', 'launch', 'start', 'go', 'show', 'bring', 'up', 'app', 'application'};

  static String _strip(String text, Set<String> filler) {
    final words = text.replaceAll(RegExp(r'[.!?,]'), ' ').split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    return words.where((w) => !filler.contains(w.toLowerCase())).join(' ').trim();
  }
}

/// Maps an executed intent to a classifier label (for learning from the user's own commands).
String? labelOf(LocalIntent i) => switch (i) {
      PlayMediaIntent() => 'play_media',
      CallIntent() => 'call',
      CheckMessagesIntent() => 'check_messages',
      OpenAppIntent() => 'open_app',
      SendMessageIntent() => 'send_message',
      TellTimeIntent() => 'time',
      TellDateIntent() => 'date',
      _ => null,
    };

import 'local_intent.dart';

/// What the conversation is currently waiting for. Changes how short answers ("yes", "the
/// second one") are interpreted.
class IntentContext {
  final bool awaitingApproval;
  final int choiceCount;
  final bool hasActiveTask;
  final bool hasPausedTask;
  final bool hasInterruptedTask;

  const IntentContext({
    this.awaitingApproval = false,
    this.choiceCount = 0,
    this.hasActiveTask = false,
    this.hasPausedTask = false,
    this.hasInterruptedTask = false,
  });
}

/// Rule-based, fully offline intent recogniser. It runs before any AI call; only
/// [UnknownIntent], [KnowledgeIntent] and [WriteIntent] ever reach Gemini.
class LocalIntentEngine {
  static final _leadingFiller = RegExp(
    r"^((hey|ok|okay|hi|yo)\s+)?((?:jarvis|leo)[\s,.!:]*)?"
    r"((please|kindly|can you|could you|would you|will you|i want you to|i need you to|i'd like you to)\s+)*",
    caseSensitive: false,
  );

  /// Removes the wake word and polite fillers, normalises "whats app" → "WhatsApp".
  static String clean(String raw) {
    var t = raw.trim();
    t = t.replaceAll(RegExp(r"\bwhats\s*app\b|\bwhat'?s\s+app\b", caseSensitive: false), 'WhatsApp');
    // Repeat because the filler regex can expose another filler ("jarvis, please can you").
    for (var i = 0; i < 3; i++) {
      final m = _leadingFiller.firstMatch(t);
      if (m == null || m.end == 0) break;
      t = t.substring(m.end).trimLeft();
    }
    t = t.replaceAll(RegExp(r'\s+please[.!?]*$', caseSensitive: false), '');
    return t.trim();
  }

  static String norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r"[^a-z0-9' ]"), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static bool _isOneOf(String n, List<String> options) => options.contains(n);

  LocalIntent parse(String raw, {IntentContext ctx = const IntentContext()}) {
    final text = clean(raw);
    final n = norm(text);
    if (n.isEmpty) return const UnknownIntent('');

    final media = _mediaControl(n);
    if (media != null) return media;

    final control = _control(n, ctx);
    if (control != null) return control;

    if (ctx.awaitingApproval) {
      final a = _approval(text, n);
      if (a != null) return a;
    }
    if (ctx.choiceCount > 0) {
      final c = _choice(n, ctx.choiceCount);
      if (c != null) return c;
    }

    return _checkMessages(n) ??
        _media(text, n) ??
        _call(text, n) ??
        _messaging(text, n) ??
        _openApp(text, n) ??
        _localInfo(n) ??
        _memory(text, n) ??
        _write(text, n) ??
        _knowledge(text, n) ??
        UnknownIntent(text);
  }

  // ---------------------------------------------------------------- media controls (local)
  static const _mediaNoun = r"(the )?(music|song|songs|video|track|playback|youtube|spotify|audio)";
  LocalIntent? _mediaControl(String n) {
    final t = n.replaceFirst(RegExp(r"^(uh|um|hey|ok|okay) "), '');
    if (RegExp("^(pause|stop|halt) $_mediaNoun( please| now)?\$").hasMatch(t)) return const MediaControlIntent(MediaAction.pause);
    if (RegExp("^(resume|continue|unpause|play) $_mediaNoun( please| again)?\$").hasMatch(t)) return const MediaControlIntent(MediaAction.play);
    if (RegExp(r"^(next|skip)( song| track| video| one)?( please)?$|^(play )?(the )?next (song|track|video)$|^skip (this|the) (song|track|video)$").hasMatch(t)) {
      return const MediaControlIntent(MediaAction.next);
    }
    if (RegExp(r"^(previous|last)( song| track| video)( please)?$|^(play )?(the )?previous (song|track|video)$|^go back (a|one) (song|track)$").hasMatch(t)) {
      return const MediaControlIntent(MediaAction.previous);
    }
    if (RegExp(r"^(volume up|increase (the )?volume|turn (it|the volume) up|louder|raise (the )?volume)( please)?$").hasMatch(t)) {
      return const MediaControlIntent(MediaAction.volumeUp);
    }
    if (RegExp(r"^(volume down|decrease (the )?volume|lower (the )?volume|turn (it|the volume) down|quieter|reduce (the )?volume)( please)?$").hasMatch(t)) {
      return const MediaControlIntent(MediaAction.volumeDown);
    }
    if (RegExp(r"^(mute|mute (the )?(volume|music|sound))( please)?$").hasMatch(t)) return const MediaControlIntent(MediaAction.mute);
    return null;
  }

  // ---------------------------------------------------------------- control
  LocalIntent? _control(String n, IntentContext ctx) {
    if (RegExp(r"^(stop|halt|abort|cancel|kill) (everything|all|all tasks|it all)( now)?$").hasMatch(n) ||
        _isOneOf(n, ['emergency stop', 'stop all tasks'])) {
      return const StopEverythingIntent();
    }
    if (_isOneOf(n, [
      'stop listening', 'go to sleep', 'sleep', 'goodbye', 'bye', "that's all", 'that is all',
      'that will be all', "that'll be all", 'go offline', 'stop listening to me'
    ])) {
      return const StopListeningIntent();
    }
    final words = n.split(' ');
    if (words.contains('stop') && words.length <= 4 && !n.contains('listening')) {
      return const StopIntent();
    }
    if (_isOneOf(n, ['halt', 'abort', 'shut up', 'be quiet', 'quiet', 'silence', 'enough'])) {
      return const StopIntent();
    }
    if (RegExp(r"^(pause|hold on|hold it|hold|wait|wait a (second|minute|moment)|one (second|moment|minute))( (it|this|that|the task|please))?$")
        .hasMatch(n)) {
      return const PauseIntent();
    }
    if (RegExp(r"^(continue|carry on|pick up|resume|go on)( the task)? (from )?where (you|we) (stopped|left off|left|were)$")
            .hasMatch(n) ||
        _isOneOf(n, ['continue the task', 'resume the task', 'continue where you stopped', 'continue from where you stopped'])) {
      return const ContinueWhereStoppedIntent();
    }
    if (_isOneOf(n, ['resume', 'continue', 'carry on', 'go on', 'go ahead and continue', 'keep going', 'unpause'])) {
      // A bare "continue" resumes a paused task, or picks up an interrupted one.
      if (ctx.hasPausedTask || !ctx.hasInterruptedTask) return const ResumeIntent();
      return const ContinueWhereStoppedIntent();
    }
    if (RegExp(r"^(cancel|cancel (this|the|that|current) task|cancel (it|that|this)|forget it|never mind|nevermind|drop it|abort (the|this) task)$")
        .hasMatch(n)) {
      return const CancelTaskIntent();
    }
    if (RegExp(r"^(what are you doing|what're you doing|what are you working on|status|what's the status|what is the status|what is happening|what's happening|what's going on|what is going on|task status|where are we)( now| right now)?$")
        .hasMatch(n)) {
      return const StatusIntent();
    }
    return null;
  }

  // ---------------------------------------------------------------- approval
  LocalIntent? _approval(String text, String n) {
    final edit = RegExp(
      r"^(?:change|edit|update|replace)\s+(?:it|the message|the text|that|message)\s+(?:to|with)\s+(.+)$|^(?:make it|instead)\s+say\s+(.+)$|^say\s+(.+?)\s+instead$",
      caseSensitive: false,
    ).firstMatch(text);
    if (edit != null) {
      final v = (edit.group(1) ?? edit.group(2) ?? edit.group(3) ?? '').trim();
      if (v.isNotEmpty) return EditMessageIntent(_stripQuotes(v));
    }
    if (RegExp(r"^(yes|yeah|yep|yup|sure|ok|okay|confirm|confirmed|approve|approved|do it|go ahead|send|send it|send now|send the message|yes send|yes send it|yes please|proceed|affirmative|go for it|ok send|okay send|absolutely|correct)( it)?( now)?( sir)?$")
        .hasMatch(n)) {
      return const ApproveIntent();
    }
    if (RegExp(r"^(no|nope|nah|negative|reject|rejected|deny|denied|wait no)\b").hasMatch(n) ||
        RegExp(r"^(don't|do not|dont)( send| do it| do that)?( it| this| that)?( now)?$").hasMatch(n)) {
      return const RejectIntent();
    }
    return null;
  }

  static const _ordinals = {
    'first': 0, 'one': 0, '1': 0, '1st': 0,
    'second': 1, 'two': 1, '2': 1, '2nd': 1,
    'third': 2, 'three': 2, '3': 2, '3rd': 2,
    'fourth': 3, 'four': 3, '4': 3, '4th': 3,
    'fifth': 4, 'five': 4, '5': 4, '5th': 4,
  };

  LocalIntent? _choice(String n, int count) {
    final m = RegExp(r"^(?:the |option |number )?(first|second|third|fourth|fifth|one|two|three|four|five|[1-5]|1st|2nd|3rd|4th|5th)(?: one| option| contact)?$")
        .firstMatch(n);
    if (m != null) {
      final i = _ordinals[m.group(1)!]!;
      if (i < count) return ChooseOptionIntent(i);
    }
    if (n == 'last one' || n == 'the last one') return ChooseOptionIntent(count - 1);
    return null;
  }

  // ---------------------------------------------------------------- everyday tasks (local)
  LocalIntent? _checkMessages(String n) {
    final asks = RegExp(r"^(check|read|read out|show|show me|any|anything|do i have|have i got|did i get|did i receive|are there|is there|what are|what's|whats|tell me|got any|get)\b")
        .hasMatch(n);
    if (!asks) return null;
    final wa = RegExp(r"\b(message|messages|msg|msgs|chat|chats|whatsapp|texts)\b").hasMatch(n);
    final mail = RegExp(r"\b(email|emails|e mail|e mails|mail|mails|gmail|inbox)\b").hasMatch(n);
    if (!wa && !mail) return null;
    if (RegExp(r"\b(send|reply|write|draft)\b").hasMatch(n)) return null;
    return CheckMessagesIntent(whatsapp: wa, email: mail);
  }

  LocalIntent? _media(String text, String n) {
    if (!RegExp(r"^(play|put on|start playing|can you play|i want to (hear|listen to|watch)|listen to|watch)\b").hasMatch(n)) {
      return null;
    }
    if (RegExp(r"^play ?store\b").hasMatch(n)) return null; // "open play store" style
    var app = MediaApp.youtube;
    if (RegExp(r"\byoutube music\b|\byt music\b").hasMatch(n)) {
      app = MediaApp.youtubeMusic;
    } else if (RegExp(r"\bspotify\b").hasMatch(n)) {
      app = MediaApp.spotify;
    }
    var q = text
        .replaceFirst(RegExp(r"^(play|put on|start playing|can you play|i want to (hear|listen to|watch)|listen to|watch)\s+", caseSensitive: false), '')
        .replaceAll(RegExp(r"\s+(on|in|using|from|via)\s+(youtube music|yt music|youtube|spotify)(\s+app)?\b", caseSensitive: false), '')
        .replaceAll(RegExp(r"^(the|a|some)\s+", caseSensitive: false), '')
        .replaceAll(RegExp(r"[.!?]+$"), '')
        .trim();
    if (q.isEmpty || RegExp(r"^(it|this|that|music|something|a song|song)$", caseSensitive: false).hasMatch(q)) {
      return null;
    }
    return PlayMediaIntent(q, app);
  }

  LocalIntent? _call(String text, String n) {
    final m = RegExp(
      r"^(?:call|phone|dial|ring|call up|give a call to|give (?:him|her) a call|make a call to|place a call to|make a phone call to)\s+(.+?)(?:\s+(?:now|right now|please|on (?:his|her|their) (?:mobile|phone|number)))?[.!?]*$",
      caseSensitive: false,
    ).firstMatch(text);
    if (m == null) return null;
    var name = m.group(1)!.replaceFirst(RegExp(r"^(to|my)\s+", caseSensitive: false), '').trim();
    if (name.isEmpty || name.split(' ').length > 5) return null;
    if (RegExp(r"^(it|this|that|it a day|back|me)$", caseSensitive: false).hasMatch(name)) return null;
    // A number spoken directly ("call 98450 12345").
    return CallIntent(name);
  }

  // ---------------------------------------------------------------- messaging
  LocalIntent? _messaging(String text, String n) {
    final mentionsWa = n.contains('whatsapp');
    final business = mentionsWa && (n.contains('business') );
    final app = business ? MessagingApp.whatsappBusiness : MessagingApp.whatsapp;

    // Remove app phrases so the recipient/message patterns stay simple.
    var t = text
        .replaceAll(
            RegExp(r"^(open|launch|go to|start)\s+(the\s+)?(whatsapp\s+business|business\s+whatsapp|whatsapp)(\s+app)?\s*(,|and|then)?\s*",
                caseSensitive: false),
            '')
        .replaceAll(
            RegExp(r"\s+(on|via|using|in|through|over)\s+(whatsapp\s+business|business\s+whatsapp|whatsapp)(\s+app)?\b",
                caseSensitive: false),
            '')
        .trim();
    // "WhatsApp Yadava saying hi" → verb form
    t = t.replaceFirst(RegExp(r"^(whatsapp\s+business|business\s+whatsapp)\s+", caseSensitive: false), 'whatsapp ');

    const verb = r"(?:send|text|message|msg|ping|whatsapp|tell|drop)";
    const filler = r"(?:\s+(?:a|an))?(?:\s+(?:whatsapp|quick|short))?(?:\s+(?:message|msg|text|note))?";
    const sep =
        r"(?:,?\s+(?:saying|that says|which says|telling (?:him|her|them)(?: that)?|and say|and tell (?:him|her|them)(?: that)?|that)\s+|\s*[:\-]\s*)";

    // 1) "send a message to R saying M" / "message R saying M" / "tell R that M"
    final withMsg = RegExp(
      "^$verb$filler(?:\\s+to)?\\s+(.+?)$sep(.+)\$",
      caseSensitive: false,
    ).firstMatch(t);
    if (withMsg != null) {
      final r = _recipient(withMsg.group(1)!);
      final m = _stripQuotes(withMsg.group(2)!.trim());
      if (r != null && m.isNotEmpty) {
        return SendMessageIntent(app: app, recipient: r.name, message: m, isGroup: r.isGroup);
      }
    }

    // 2) "message R about T" → compose with the AI writer, still requires approval
    final about = RegExp(
      "^$verb$filler(?:\\s+to)?\\s+(.+?)\\s+(?:about|regarding|asking|to tell (?:him|her|them)|to ask (?:him|her|them))\\s+(.+)\$",
      caseSensitive: false,
    ).firstMatch(t);
    if (about != null) {
      final r = _recipient(about.group(1)!);
      if (r != null) {
        return SendMessageIntent(
            app: app, recipient: r.name, composeTopic: about.group(2)!.trim(), isGroup: r.isGroup);
      }
    }

    // 3) "send a message to R" (no content yet) — only when it clearly is a messaging request
    final bare = RegExp("^$verb$filler\\s+to\\s+(.+)\$", caseSensitive: false).firstMatch(t);
    if (bare != null && (mentionsWa || RegExp(r'^(send|text|message|msg|ping)\b', caseSensitive: false).hasMatch(t))) {
      final r = _recipient(bare.group(1)!);
      if (r != null) return SendMessageIntent(app: app, recipient: r.name, isGroup: r.isGroup);
    }
    final bareMessage = RegExp(r"^(?:message|text|ping|whatsapp)\s+(.+)$", caseSensitive: false).firstMatch(t);
    if (bareMessage != null && mentionsWa) {
      final r = _recipient(bareMessage.group(1)!);
      if (r != null) return SendMessageIntent(app: app, recipient: r.name, isGroup: r.isGroup);
    }
    return null;
  }

  _Recipient? _recipient(String raw) {
    var r = raw.trim().replaceAll(RegExp(r'[.,!?;:"]+$'), '').trim();
    var isGroup = false;
    final g1 = RegExp(r"^(?:the\s+)?(?:whatsapp\s+)?group\s+(?:called\s+|named\s+)?(.+)$", caseSensitive: false).firstMatch(r);
    final g2 = RegExp(r"^(?:the\s+|my\s+)?(.+?)\s+(?:whatsapp\s+)?group$", caseSensitive: false).firstMatch(r);
    if (g1 != null) {
      r = g1.group(1)!;
      isGroup = true;
    } else if (g2 != null) {
      r = g2.group(1)!;
      isGroup = true;
    }
    r = r.replaceFirst(RegExp(r'^(the|my)\s+', caseSensitive: false), '').trim();
    r = _stripQuotes(r);
    if (r.isEmpty || r.split(' ').length > 6) return null;
    if (RegExp(r'^(him|her|them|it|me|someone|somebody)$', caseSensitive: false).hasMatch(r)) return null;
    return _Recipient(r, isGroup);
  }

  // ---------------------------------------------------------------- apps
  LocalIntent? _openApp(String text, String n) {
    final m = RegExp(r"^(?:open|launch|start|run|show me|go to|bring up|switch to)\s+(?:the\s+|my\s+)?(.+?)(?:\s+(?:app|application))?$",
            caseSensitive: false)
        .firstMatch(text);
    if (m == null) return null;
    final name = m.group(1)!.replaceAll(RegExp(r'[.!?]+$'), '').trim();
    if (name.isEmpty || name.split(' ').length > 4) return null;
    return OpenAppIntent(name);
  }

  // ---------------------------------------------------------------- local info
  LocalIntent? _localInfo(String n) {
    if (RegExp(r"^(what time is it|what's the time|what is the time|tell me the time|current time|time now|what's the time now|what is the time now|time)( now| right now)?$")
        .hasMatch(n)) {
      return const TellTimeIntent();
    }
    if (RegExp(r"^(what's the date|what is the date|what's today's date|what is today's date|today's date|what day is it|what day is today|date today|what's the date today|what is the date today)$")
        .hasMatch(n)) {
      return const TellDateIntent();
    }
    if (RegExp(r"^(hi|hello|hey|yo|good morning|good afternoon|good evening|wake up|are you there|you there|daddy's home)( jarvis| leo| buddy| there)?$")
        .hasMatch(n)) {
      return const GreetingIntent();
    }
    if (RegExp(r"^(how are you|how are you doing|how's it going|how are things|are you ok|are you okay)( today| jarvis| leo)?$").hasMatch(n)) {
      return const HowAreYouIntent();
    }
    if (RegExp(r"^(thanks|thank you|thank you so much|thanks a lot|great job|well done|good job|nice work|perfect|awesome|great)( jarvis| leo| buddy| sir)?$")
        .hasMatch(n)) {
      return const ThanksIntent();
    }
    return null;
  }

  // ---------------------------------------------------------------- memory
  LocalIntent? _memory(String text, String n) {
    final rem = RegExp(r"^(?:remember|note|keep in mind|don't forget|do not forget)\s+(?:that\s+)?(.+)$", caseSensitive: false)
        .firstMatch(text);
    if (rem != null && !n.startsWith('remember when') && !n.startsWith('do you remember')) {
      return RememberIntent(rem.group(1)!.trim());
    }
    if (RegExp(r"^(delete|clear|erase|wipe)( all)?( of)?( my| the| our)? (conversation history|conversations|chat history|history|memory|memories)$")
            .hasMatch(n) ||
        _isOneOf(n, ['forget everything', 'forget everything you know', 'clear your memory'])) {
      return const ForgetEverythingIntent();
    }
    if (RegExp(r"^(continue|let's continue|lets continue|resume|pick up)( with)? (the work|our work|what we were doing|the work we discussed|our discussion|where we left off( last time| yesterday)?|from (last time|yesterday))")
            .hasMatch(n) ||
        RegExp(r"^(continue|resume) (the|our) (work|project|discussion) (we|that we) (discussed|talked about|were doing)").hasMatch(n)) {
      return const ContinuePreviousWorkIntent();
    }
    final recall = RegExp(
            r"^(?:what do you remember(?: about (.+))?|what did (?:we|i) (?:discuss|talk about|say)(?: about (.+?))?(?: yesterday| last time| earlier| before)?|what was i (?:working on|doing)(?: yesterday| last time)?|what have we (?:discussed|talked about)|do you remember (.+))$")
        .firstMatch(n);
    if (recall != null) {
      return RecallIntent(recall.group(1) ?? recall.group(2) ?? recall.group(3));
    }
    final st = RegExp(
      r"^(?:i am|i'm|im|we are|we're)\s+(?:currently\s+|now\s+)?(?:working on|building|developing|making|creating|studying|preparing for|learning|doing)\s+(.+)$",
      caseSensitive: false,
    ).firstMatch(text);
    if (st != null) return ContextStatementIntent(text);
    return null;
  }

  // ---------------------------------------------------------------- writing (AI)
  LocalIntent? _write(String text, String n) {
    if (RegExp(r"^(rewrite|rephrase|reword|improve|polish|proofread|paraphrase|make (this|it) (more )?(professional|formal|polite|shorter|better))\b")
        .hasMatch(n)) {
      return WriteIntent(WritingKind.rewrite, text);
    }
    final m = RegExp(r"^(write|draft|compose|create|prepare|generate|make)\b.*\b(email|e mail|mail|message|msg|letter|note|post|essay|document|doc|report|application|caption|tweet|reply|summary|paragraph|speech|proposal|bio|cover letter|text)\b")
        .firstMatch(n);
    if (m != null) {
      final kind = switch (m.group(2)) {
        'email' || 'e mail' || 'mail' => WritingKind.email,
        'message' || 'msg' || 'text' || 'reply' || 'tweet' || 'caption' => WritingKind.message,
        _ => WritingKind.document,
      };
      return WriteIntent(kind, text);
    }
    return null;
  }

  // ---------------------------------------------------------------- knowledge (AI)
  LocalIntent? _knowledge(String text, String n) {
    if (RegExp(r"^(what|who|whom|whose|when|where|why|how|which|explain|define|describe|tell me|is|are|can|does|do|did|should|could|would|will|calculate|compare|summarize|summarise|give me|list|suggest|recommend|translate)\b")
            .hasMatch(n) ||
        text.trim().endsWith('?')) {
      return KnowledgeIntent(text);
    }
    return null;
  }

  static String _stripQuotes(String s) =>
      s.trim().replaceAll(RegExp(r'''^["'“”‘’]+|["'“”‘’]+$'''), '').trim();
}

class _Recipient {
  final String name;
  final bool isGroup;
  _Recipient(this.name, this.isGroup);
}

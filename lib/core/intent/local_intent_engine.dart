import '../time_parser.dart';
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
    r"^((?:uh+|um+|hmm+|so|well|and|okay so|ok so)[\s,.]+)?((hey|ok|okay|hi|hello|hii|yo|excuse me|listen)[\s,.!]+)?((?:jarvis|leo)[\s,.!:]*)?"
    r"((please|kindly|can you|could you|would you|will you|can u|could u|i want you to|i need you to|i'd like you to)[\s,]+)*",
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
    // "…send a reel to Pawan Kumar?" is still a command — but keep punctuation of dictated messages.
    // A command phrased politely ("send a message to X saying hi?") is still a command.
    final imperative = RegExp(
            r"^(send|open|play|call|message|text|whatsapp|set|turn|switch|show|read|search|find|book|schedule|remind|"
            r"delete|install|share|start|stop|pause|resume|take|launch|go to|navigate|check)\b",
            caseSensitive: false)
        .hasMatch(t);
    if (imperative || !RegExp(r"\b(saying|say|that|message|text|tell|reply|write|ask)\b", caseSensitive: false).hasMatch(t)) {
      t = t.replaceAll(RegExp(r'\s*\?+$'), '');
    }
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

    // "log in to spotify with my phone number" / "sign into instagram using google"
    final how = RegExp(r"\s+(?:with|using|via|through|by)\s+(?:my\s+|a\s+)?(phone(?: number)?|mobile(?: number)?|number|google(?: account)?|gmail|e-?mail(?: address)?)$",
            caseSensitive: false)
        .firstMatch(text);
    final method = how == null
        ? null
        : RegExp(r'phone|mobile|number', caseSensitive: false).hasMatch(how.group(1)!)
            ? 'phone'
            : RegExp(r'google|gmail', caseSensitive: false).hasMatch(how.group(1)!)
                ? 'google'
                : 'email';
    final signText = how == null ? text : text.substring(0, how.start);
    final signIn = RegExp(r"^(?:sign|log)\s*(?:in|into|on)(?:\s+(?:to|into|on))?\s+(?:my\s+)?(.+?)(?:\s+(?:app|account))?$",
            caseSensitive: false)
        .firstMatch(signText);
    if (signIn != null && signIn.group(1)!.split(' ').length <= 4) return SignInIntent(signIn.group(1)!.trim(), method: method);

    final early = _early(text, n);
    if (early != null) return early;

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

    return _phoneActions(text, n) ??
        _round3(text, n) ??
        _checkMessages(n) ??
        _media(text, n) ??
        _call(text, n) ??
        _messaging(text, n) ??
        _openApp(text, n) ??
        _localInfo(n) ??
        _memory(text, n) ??
        _write(text, n) ??
        _phoneTask(text, n) ??
        _knowledge(text, n) ??
        UnknownIntent(text);
  }

  // ---------------------------------------------------------------- media controls (local)
  static const _mediaNoun = r"(the )?(music|song|songs|video|track|playback|youtube|spotify|audio)";
  LocalIntent? _mediaControl(String n) {
    // "I said pause the music in Spotify", "please stop the song on youtube now" → same as "pause the music".
    final t = n
        .replaceFirst(RegExp(r"^(uh|um|hey|ok|okay|leo|no|i said|i told you( to)?|just|please|can you|could you)( |$)"), '')
        .replaceFirst(RegExp(r"^(i said|just|please|can you|could you) "), '')
        .replaceFirst(RegExp(r" (in|on|from) (spotify|youtube music|yt music|youtube|the player|the app)$"), '')
        .trim();
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
    // Ending the conversation: "thank you bye", "ok that's all", "nothing else", "no thanks", "I'm done".
    if (RegExp(r"^(ok |okay |no |nope |alright |all right )?((thank you|thanks)( so much| a lot| leo| sir)?,? )?"
            r"(bye|bye bye|goodbye|good bye|see you|see you later|that's all|that is all|that's it|that is it|nothing|nothing else|"
            r"no thanks|no thank you|i'm done|i am done|we're done|done for now|that will be all|that'll be all)"
            r"( leo| sir| for now| thanks| thank you)?$")
            .hasMatch(n) &&
        // While LEO waits for a yes/no or a choice, "no thanks" answers THAT question.
        !(ctx.awaitingApproval || ctx.choiceCount > 0)) {
      return const StopListeningIntent();
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

  // ---------------------------------------------------------------- alarms / calls / screen (checked before STOP)
  LocalIntent? _early(String text, String n) {
    final t = n.replaceFirst(RegExp(r"^(uh|um|hey|ok|okay) "), '');
    // Alarms
    if (RegExp(r"^(snooze)( the| my)?( alarm)?( for (\d+) minutes?)?$").hasMatch(t)) {
      final m = RegExp(r"(\d+) minutes?").firstMatch(t);
      return SnoozeAlarmIntent(minutes: m == null ? null : int.parse(m.group(1)!));
    }
    // Match on the original wording so "6:30" keeps its colon.
    final tl = text.toLowerCase().replaceFirst(RegExp(r"^(uh|um|hey|ok|okay),?\s+"), '').replaceAll(RegExp(r'[.!?]+$'), '').trim();
    final al = RegExp(r"^(?:stop|dismiss|turn off|switch off|cancel|delete|remove|disable|kill)\s+(?:the\s+|my\s+)?(all\s+)?(?:(.+?)\s+)?alarms?(?:\s+(?:for|at|of)\s+(.+))?$").firstMatch(tl);
    if (al != null) {
      final what = (al.group(3) ?? al.group(2) ?? 'next').trim();
      return DismissAlarmIntent(what, all: al.group(1) != null || RegExp(r"\balarms\b").hasMatch(tl) && !RegExp(r"\d").hasMatch(tl));
    }
    // Calls
    if (RegExp(r"^(answer|accept|pick up|pickup|receive|attend)( the| this)?( phone)?( call)?( please)?$").hasMatch(t) ||
        RegExp(r"^(pick it up|answer it)$").hasMatch(t)) {
      return const CallControlIntent(CallAction.answer);
    }
    if (RegExp(r"^(reject|decline|ignore|don't answer|do not answer)( the| this)?( phone)?( call)?$").hasMatch(t)) {
      return const CallControlIntent(CallAction.reject);
    }
    if (RegExp(r"^(end|cut|disconnect|hang up|hangup|drop|finish|terminate)( the| this| my)?( phone)?( call)?( now| please)?$").hasMatch(t) && t != 'end') {
      return const CallControlIntent(CallAction.end);
    }
    // Reminders
    if (RegExp(r"^(list|show|tell me|read|what are|what're|do i have)( me)?( all)?( my| the)?( any)? reminders?( do i have)?$").hasMatch(t)) {
      return const ListRemindersIntent();
    }
    if (RegExp(r"^(delete|remove|cancel|clear) (all )?(of )?(my |the )?reminders$").hasMatch(t)) {
      return const DeleteReminderIntent(all: true);
    }
    final dr = RegExp(r"^(?:delete|remove|cancel|clear)\s+(?:the\s+|my\s+)?reminder(?:\s+(?:about|to|for|called|that says))?\s*(.*)$").firstMatch(t);
    if (dr != null) return DeleteReminderIntent(about: dr.group(1)!.trim().isEmpty ? null : dr.group(1)!.trim());
    // Screen commands (work in whatever app is on screen)
    if (RegExp(r"^(scroll|swipe)( the page| the screen)? down$|^scroll$|^(go |move )?down$").hasMatch(t)) return const ScreenCommandIntent(ScreenCommand.scrollDown);
    if (RegExp(r"^(scroll|swipe)( the page| the screen)? up$|^(go |move )?up$").hasMatch(t)) return const ScreenCommandIntent(ScreenCommand.scrollUp);
    if (RegExp(r"^(go back|back|go to previous|previous screen)$").hasMatch(t)) return const ScreenCommandIntent(ScreenCommand.back);
    if (RegExp(r"^(go home|home|go to home screen|home screen)$").hasMatch(t)) return const ScreenCommandIntent(ScreenCommand.home);
    if (RegExp(r"^(read (this|it|that|the screen|this page|this screen|out this|this message|this chat|what's on (the|my) screen)|what's on (my|the) screen|what is on (my|the) screen|what does it say|what does this say)$").hasMatch(t)) {
      return const ScreenCommandIntent(ScreenCommand.read);
    }
    final tap = RegExp(r"^(?:tap|click|press|select|hit|choose)\s+(?:on\s+)?(?:the\s+)?(.+?)(?:\s+button|\s+option)?$", caseSensitive: false).firstMatch(text);
    if (tap != null) return ScreenCommandIntent(ScreenCommand.tap, arg: tap.group(1)!.trim());
    final typ = RegExp(r"^(?:type|write|enter)\s+(.+?)(?:\s+(?:here|in the box|in the field))?$", caseSensitive: false).firstMatch(text);
    if (typ != null && !RegExp(r"\b(email|mail|letter|message to|essay|post|document)\b", caseSensitive: false).hasMatch(text)) {
      return ScreenCommandIntent(ScreenCommand.type, arg: typ.group(1)!.trim());
    }
    return null;
  }

  // ---------------------------------------------------------------- files / web / install / shopping / chat reading
  /// AI / chat apps LEO may type a request into ("ask Claude to …").
  static const askableApps = r"claude|chat ?gpt|gemini|perplexity|copilot|meta ai|grok|deepseek|le chat|mistral|poe|pi";

  LocalIntent? _round3(String text, String n) {
    // "ask it to prepare a PPT about blood", "tell Claude to …", "ask ChatGPT what is …"
    final ask = RegExp("^(?:ask|tell|prompt)\\s+(it|this|that|the app|$askableApps)\\s+(?:to\\s+|for\\s+|about\\s+|that\\s+)?(.+)\$",
            caseSensitive: false)
        .firstMatch(text);
    if (ask != null) {
      final target = ask.group(1)!.toLowerCase();
      final app = RegExp(r'^(it|this|that|the app)$').hasMatch(target) ? null : _cap(target);
      final p = ask.group(2)!.trim();
      return AskAppIntent('${p[0].toUpperCase()}${p.substring(1)}', app: app);
    }
    // Read a WhatsApp chat aloud
    final rc = RegExp(r"^(?:read|read out|read me)\s+(?:my\s+|the\s+)?(?:latest\s+|last\s+|recent\s+)?(?:whatsapp\s+)?(?:chat|messages|conversation)\s+(?:with|from)\s+(.+?)(?:\s+(?:on|in)\s+whatsapp)?$", caseSensitive: false)
        .firstMatch(text);
    if (rc != null) return ReadChatIntent(_cap(rc.group(1)!));
    // Files
    final ext = RegExp(r"\b(pdf|pdfs|document|documents|doc|docx|excel|ppt|presentation|file|files)\b").firstMatch(n);
    if (ext != null && RegExp(r"^(find|search|open|show|look for|get|where is|where's|locate)\b").hasMatch(n)) {
      final kind = ext.group(1)!;
      final exts = switch (kind) {
        'doc' || 'docx' => ['doc', 'docx'],
        'excel' => ['xls', 'xlsx', 'csv'],
        'ppt' || 'presentation' => ['ppt', 'pptx'],
        'document' || 'documents' => ['pdf', 'doc', 'docx', 'txt'],
        'file' || 'files' => ['pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'zip'],
        _ => ['pdf'],
      };
      var q = n
          .replaceFirst(RegExp(r"^(find|search for|search|open|show me|show|look for|get|where is|where's|locate)\s+"), '')
          .replaceAll(RegExp(r"\b(my|the|a|an|pdf|pdfs|document|documents|doc|docx|excel|ppt|presentation|file|files|named|called|on my phone|in my phone|from downloads|in downloads)\b"), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      return FindFileIntent(q, exts: exts, open: n.startsWith('open') || n.contains(' and open'));
    }
    // Install apps
    final inst = RegExp(r"^(?:install|download|get)\s+(?:the\s+)?(.+?)(?:\s+app(?:lication)?)?(?:\s+(?:from|on)\s+(?:the\s+)?play ?store)?$", caseSensitive: false).firstMatch(text);
    if (inst != null && !RegExp(r"\b(pdf|file|photo|video|song|movie)\b", caseSensitive: false).hasMatch(text) && inst.group(1)!.split(' ').length <= 4) {
      return InstallAppIntent(inst.group(1)!.trim());
    }
    // Websites
    final web = RegExp(r"^(?:open|go to|visit|browse|load|show me)\s+(?:the\s+)?(?:website\s+|site\s+)?((?:https?://)?[a-z0-9-]+(?:\.[a-z0-9-]+)+(?:/\S*)?|[a-z0-9 ]+?\s+(?:website|site|dot com))(?:\s+and\s+(.+))?$", caseSensitive: false)
        .firstMatch(text);
    if (web != null) return OpenWebsiteIntent(web.group(1)!.trim(), then: web.group(2)?.trim());
    // "search for X on wikipedia / github.com" → that site's own search
    final onSite = RegExp(r"^(?:search|look up|find|look for)(?:\s+(?:for|about))?\s+(.+?)\s+(?:on|in)\s+((?:[a-z0-9-]+\.)+[a-z]{2,}|wikipedia|github|reddit|stack ?overflow|imdb|quora|linkedin|twitter|myntra|swiggy|zomato)$", caseSensitive: false)
        .firstMatch(text);
    if (onSite != null) return OpenWebsiteIntent(onSite.group(2)!.replaceAll(' ', '').toLowerCase(), then: 'search for ${onSite.group(1)!.trim()}');
    // Shopping
    final shop = RegExp(r"^(?:search for|search|find|look for|buy|order|shop for|compare|show me|add)\s+(.+?)\s+(?:(?:to (?:my |the )?cart )?(?:on|in|from|at)\s+)(amazon|flipkart)(?:\s+and\s+(.+))?$", caseSensitive: false)
        .firstMatch(text);
    if (shop != null) {
      final rest = '${n} ${shop.group(3) ?? ''}';
      final q = shop.group(1)!.replaceAll(RegExp(r"\s+to (my |the )?cart$", caseSensitive: false), '').trim();
      return ShopIntent(q,
          store: shop.group(2)!.toLowerCase(),
          addToCart: RegExp(r"\b(cart|buy|order)\b").hasMatch(rest),
          compare: true);
    }
    return null;
  }

  // ---------------------------------------------------------------- phone actions (local)
  LocalIntent? _phoneActions(String text, String n) {
    // Reply to a message from the notification
    final rp = RegExp(r"^(?:reply|respond|answer)(?: back)? to\s+(.+?)(?:\s*(?:,|saying|that|with|and say|telling (?:him|her|them))\s+(.+))?$", caseSensitive: false)
        .firstMatch(text);
    if (rp != null && rp.group(1)!.split(' ').length <= 5) {
      final who = rp.group(1)!.replaceAll(RegExp(r"'s (message|text|chat)$|\s+(on|in) (whatsapp|messages|telegram|instagram)$", caseSensitive: false), '').trim();
      final msg = rp.group(2)?.trim();
      return ReplyIntent(_cap(who), message: msg == null || msg.isEmpty ? null : _stripQuotes(msg));
    }
    // Timer
    if (RegExp(r"^(set|start|put|create)( a| an| the)? timer\b|^timer for\b|^countdown( for)?\b").hasMatch(n)) {
      final d = TimeParser.duration(n);
      if (d != null) {
        final label = RegExp(r"\bfor (?:the )?([a-z ]+?)$").firstMatch(n.replaceAll(RegExp(r"\b\d+\s*(hours?|minutes?|mins?|seconds?|secs?)\b"), '').trim());
        return SetTimerIntent(d, label: label?.group(1)?.trim().isEmpty == true ? null : label?.group(1)?.trim());
      }
    }
    // Reminder → labelled alarm
    final rem = RegExp(r"^(?:remind me|set a reminder|reminder)(?: to| about| that)?\s+(.+?)\s+(?:at|in|on|tomorrow|tonight|today|by)\b", caseSensitive: false)
        .firstMatch(text);
    if (rem != null && TimeParser.when(text) != null) return SetAlarmIntent(text, label: _cap(rem.group(1)!));
    // Alarm
    if (RegExp(r"^(set|create|put|make|add)( an| a| my| the)? alarm\b|^wake me( up)?\b|^alarm (for|at)\b").hasMatch(n)) {
      if (TimeParser.when(text) != null) {
        final label = RegExp(r"\b(?:called|named|labelled|labeled|saying|for) ([a-z ]+)$").firstMatch(n);
        final l = label?.group(1);
        return SetAlarmIntent(text, label: l != null && !RegExp(r"\d|am|pm|tomorrow|today|morning|evening").hasMatch(l) ? _cap(l) : null);
      }
    }
    // Start a meeting now
    if (RegExp(r"^(start|create|begin|open|new|make)( a| an)?( new)? (google meet|gmeet|g meet|meet|video call|video meeting)( call| meeting)?( now)?$").hasMatch(n)) {
      return const StartMeetIntent();
    }
    // Schedule a meeting / event
    // "call" only counts as a meeting with scheduling verbs ("make a call to X" is a phone call).
    final mt = RegExp(r"^(schedule|set up|setup|create|book|arrange|plan|fix|add|organi[sz]e)( a| an)?( new)?( google meet| gmeet| g meet| zoom| video| online| team| quick)? (meeting|meet|gmeet|google meet|g meet|call|event|appointment|session)\b").firstMatch(n);
    if (mt != null || RegExp(r"^(add|put) (.+) (to|in|on) (my )?calendar").hasMatch(n)) {
      final meet = RegExp(r"\b(google meet|gmeet|g meet|meet link|video call|video meeting|on meet|in meet|zoom)\b").hasMatch(n) ||
          (mt?.group(4)?.contains('meet') ?? false) || (mt?.group(5)?.contains('meet') ?? false);
      final withM = RegExp(r"\bwith (.+?)(?=\s+(?:tomorrow|today|tonight|at|on|about|regarding|for|from|next|this|in|titled|called)\b|[.?!]?$)", caseSensitive: false).firstMatch(text);
      final attendees = <String>[];
      if (withM != null) {
        for (final a in withM.group(1)!.split(RegExp(r",| and "))) {
          final name = a.trim().replaceAll(RegExp(r"\b(tomorrow|today|tonight|at|on|about|for|regarding|from|to|in)\b.*$", caseSensitive: false), '').trim();
          if (name.isNotEmpty && !RegExp(r"^(google|meet|gmeet|my team|team)$", caseSensitive: false).hasMatch(name)) attendees.add(_cap(name));
        }
      }
      final about = RegExp(r"\b(?:about|regarding|on the topic of|titled|called|for the) (.+?)(?=\s+(?:with|tomorrow|today|tonight|at|on|from|next|this)\b|$)", caseSensitive: false)
          .firstMatch(text);
      final title = about != null
          ? _cap(about.group(1)!)
          : (attendees.isNotEmpty ? 'Meeting with ${attendees.join(', ')}' : null);
      final len = RegExp(r"\bfor (\d+|an?|half an?) ?(hours?|hrs?|minutes?|mins?)\b").firstMatch(n);
      return ScheduleMeetingIntent(text,
          title: title, attendees: attendees, googleMeet: meet, length: len == null ? null : TimeParser.duration(len.group(0)!));
    }
    // Navigation
    final nav = RegExp(r"^(?:navigate|take me|drive me|directions|get directions|show me the way|route me)(?: to| me to)?\s+(.+)$", caseSensitive: false).firstMatch(text);
    if (nav != null) return NavigateIntent(nav.group(1)!.replaceAll(RegExp(r'[.!?]+$'), '').trim());
    // Web search
    final ws = RegExp(r"^(?:search google|search the web|search online|search on google|google search|look up|search|google)(?: on google| on the web| online)?(?: for| about)?\s+(.+)$", caseSensitive: false).firstMatch(text);
    final namesSite = RegExp(r"\s(?:on|in)\s+(?:(?:[a-z0-9-]+\.)+[a-z]{2,}|wikipedia|github|reddit|stack ?overflow|imdb|quora|linkedin|twitter|myntra|swiggy|zomato)$", caseSensitive: false).hasMatch(text);
    if (ws != null && !namesSite && !RegExp(r"\b(youtube|amazon|flipkart)\b", caseSensitive: false).hasMatch(text)) return WebSearchIntent(ws.group(1)!.trim());
    // Flashlight
    final fl = RegExp(r"^(?:turn|switch|put)\s+(on|off)\s+(?:the\s+)?(?:flashlight|torch|flash ?light|flash)$|^(?:turn|switch)\s+(?:the\s+)?(?:flashlight|torch|flash)\s+(on|off)$|^(?:flashlight|torch)\s+(on|off)$")
        .firstMatch(n);
    if (fl != null) return FlashlightIntent((fl.group(1) ?? fl.group(2) ?? fl.group(3)) == 'on');
    // Camera
    if (RegExp(r"^(take|click|capture)( a| me a)? (selfie|selfy)").hasMatch(n)) return const CameraIntent(selfie: true);
    if (RegExp(r"^(take|click|capture)( a)? (photo|picture|pic|snap)").hasMatch(n)) return const CameraIntent();
    if (RegExp(r"^(record|take|start)( a)? video").hasMatch(n)) return const CameraIntent(video: true);
    // Connectivity / settings panels
    final sp = RegExp(r"^(?:turn|switch|put)\s+(on|off)\s+(?:the\s+|my\s+)?(wi ?fi|wifi|bluetooth|mobile data|data|hotspot|nfc|location|gps|airplane mode|flight mode|do not disturb|dnd|power saving|battery saver|dark mode|auto rotate|rotation)(?: mode)?$|^(?:turn|switch)\s+(?:the\s+|my\s+)?(wi ?fi|wifi|bluetooth|mobile data|data|hotspot|nfc|location|gps|airplane mode|flight mode|do not disturb|dnd|power saving|battery saver|dark mode|auto rotate|rotation)(?: mode)?\s+(on|off)$|^(?:open\s+)?(wi ?fi|wifi|bluetooth|hotspot|location|display|brightness)\s+settings$")
        .firstMatch(n);
    if (sp != null) {
      final raw = sp.group(2) ?? sp.group(3) ?? sp.group(5) ?? '';
      final onOff = sp.group(1) ?? sp.group(4);
      final kind = switch (raw.replaceAll(' ', '')) {
        'wifi' => 'wifi',
        'bluetooth' => 'bluetooth',
        'mobiledata' || 'data' => 'data',
        'hotspot' => 'hotspot',
        'nfc' => 'nfc',
        'location' || 'gps' => 'location',
        'airplanemode' || 'flightmode' => 'airplane',
        'display' || 'brightness' => 'display',
        'donotdisturb' || 'dnd' => 'dnd',
        'powersaving' || 'batterysaver' => 'power_saving',
        'darkmode' => 'dark_mode',
        'autorotate' || 'rotation' => 'rotation',
        _ => 'settings',
      };
      return SettingsPanelIntent(kind, on: onOff == null ? null : onOff == 'on');
    }
    return null;
  }

  static String _cap(String s) {
    final t = s.trim().replaceAll(RegExp(r'[.!?]+$'), '');
    return t.isEmpty ? t : t[0].toUpperCase() + t.substring(1);
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

  // ---------------------------------------------------------------- generic phone task (screen agent)
  LocalIntent? _phoneTask(String text, String n) {
    final verbs = RegExp(r"^(open|go to|in|on|inside|delete|remove|archive|clear|find|show me|look for|search (in|on|my|for)|forward|share|post|upload|like|follow|unfollow|subscribe|download|install|uninstall|update|mark|block|unblock|mute|unmute|pin|unpin|save|star|add|create|change|set|enable|disable|send|compose|email|mail|book|order|scroll|tap|click|press|go back|close|switch to)\b");
    final appish = RegExp(r"\b(gallery|photos?|pictures?|gmail|email|mail|inbox|whatsapp|instagram|facebook|telegram|chrome|browser|settings|youtube|spotify|maps|calendar|contacts|files?|notes?|play store|camera|messages?|sms|snapchat|twitter|linkedin|amazon|flipkart|swiggy|zomato|uber|ola)\b");
    if (verbs.hasMatch(n) && (appish.hasMatch(n) || n.split(' ').length >= 4)) return PhoneTaskIntent(text);
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

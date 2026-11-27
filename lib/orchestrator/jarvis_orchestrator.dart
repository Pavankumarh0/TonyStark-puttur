import '../core/privacy_filter.dart';
import '../agent/screen_agent.dart';
import '../ai/openai_brain.dart';
import '../ai/sarvam_brain.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import '../ai/ai_service.dart';
import '../ai/gemini_client.dart';
import '../ai/local_agent_brain.dart';
import '../core/approval/approval_gate.dart';
import '../core/greeting.dart';
import '../core/intent/local_classifier.dart';
import '../core/intent/local_intent.dart';
import '../core/intent/local_intent_engine.dart';
import '../core/task/task_models.dart';
import '../core/time_parser.dart';
import '../core/task/task_runner.dart';
import '../data/context_builder.dart';
import '../data/memory_repository.dart';
import '../data/settings_store.dart';
import '../device/app_resolver.dart';
import '../device/device_bridge.dart';
import '../voice/mic_engine.dart';
import '../voice/speech_input.dart';
import '../voice/speech_output.dart';

enum VoicePhase { idle, listening, transcribing }

/// What the UI shows as LEO' visible state. Always derived from real component state.
enum DisplayState { offline, waiting, listening, thinking, speaking, executing, approval, paused }

class ChoicePrompt {
  final String question;
  final List<String> options;
  final List<String> details;
  const ChoicePrompt(this.question, this.options, {this.details = const []});
}

class Draft {
  final WritingKind kind;
  final String? subject;
  final String content;
  final DateTime createdAt = DateTime.now();
  Draft(this.kind, this.subject, this.content);
}

enum _ApprovalAnswer { approve, reject, edit }

class _ApprovalReply {
  final _ApprovalAnswer answer;
  final String? newText;
  const _ApprovalReply(this.answer, [this.newText]);
}

typedef _Runner = Future<String?> Function(TaskTracker t);

/// Central controller: input → local intent engine → (AI fallback only if needed) → structured
/// task → permission/approval checks → device layer. STOP/PAUSE/CANCEL never touch the AI.
class JarvisOrchestrator extends ChangeNotifier {
  final SettingsStore settings;
  final MemoryRepository memory;
  final ContextBuilder contextBuilder;
  final AiService ai;
  final SarvamBrain sarvamBrain = SarvamBrain(); // prompt + parsing shared with the OpenAI brain
  final OpenAiBrain openAiBrain = OpenAiBrain();
  final MicEngine mic;
  final SpeechInput speechIn;
  final SpeechOutput speechOut;
  final DeviceBridge device;
  final AppResolver apps;
  final LocalIntentEngine engine = LocalIntentEngine();
  final GreetingGenerator greeter = GreetingGenerator();

  /// On-device intent model (trained on the phone; learns from this user's commands).
  final LocalIntentClassifier classifier = LocalIntentClassifier();
  String _currentUtterance = '';

  /// True while the half-screen assistant panel (digital assistant role) is showing.
  bool assistMode = false;
  final ApprovalGate approvals = ApprovalGate();

  JarvisOrchestrator({
    required this.settings,
    required this.memory,
    required this.contextBuilder,
    required this.ai,
    required this.mic,
    required this.speechIn,
    required this.speechOut,
    required this.device,
    required this.apps,
  });

  // ------------------------------------------------------------------ observable state
  int sessionId = 0;
  List<StoredMessage> messages = [];
  List<StoredMessage> previousSessionTail = [];
  VoicePhase voice = VoicePhase.idle;
  TaskSnapshot? task;
  ChoicePrompt? choice;
  Draft? draft;
  String? banner;
  String? lastHeard;
  bool listeningEnabled = false;
  bool serviceRunning = false;
  bool get speaking => speechOut.speaking;

  TaskTracker? _tracker;
  Completer<_ApprovalReply>? _approvalWait;
  Completer<int>? _choiceWait;
  Completer<String>? _freeTextWait;
  AgentState? _stateBeforePause;
  bool _loopRunning = false;
  bool _stopLoop = false;
  DateTime? _lastUserAt;
  StreamSubscription? _eventsSub;

  DisplayState get display {
    if (speechOut.speaking) return DisplayState.speaking;
    if (voice == VoicePhase.listening) return DisplayState.listening;
    if (voice == VoicePhase.transcribing) return DisplayState.thinking;
    final t = task;
    if (t != null && !t.state.isTerminal && t.state != AgentState.interrupted) {
      switch (t.state) {
        case AgentState.waitingForApproval:
          return DisplayState.approval;
        case AgentState.paused:
          return DisplayState.paused;
        case AgentState.understanding:
        case AgentState.planning:
          return choice != null || _freeTextWait != null ? DisplayState.approval : DisplayState.thinking;
        case AgentState.running:
          return t.route == TaskRoute.ai && t.kind != 'whatsapp_send' && t.kind != 'open_app'
              ? DisplayState.thinking
              : DisplayState.executing;
        default:
          break;
      }
    }
    return listeningEnabled ? DisplayState.waiting : DisplayState.offline;
  }

  ApprovalRequest? get pendingApproval => approvals.pending;
  bool get awaitingInput => _freeTextWait != null;

  // ------------------------------------------------------------------ lifecycle
  Future<void> init() async {
    await memory.markOrphanedTasksInterrupted();
    sessionId = await memory.resumeOrStartSession();
    messages = await memory.messagesOf(sessionId, limit: 200);
    previousSessionTail = (await memory.previousMessages(sessionId, limit: 6)).reversed.toList();
    _lastUserAt = await memory.lastInteraction();
    final unfinished = await memory.unfinishedTasks();
    if (unfinished.isNotEmpty) task = unfinished.first;
    // The user's own past commands are used for training only with their opt-in.
    classifier.train(learned: settings.learnFromMe ? await memory.learnedExamples() : const []);
    unawaited(apps.apps().then((list) {
      final labels = list.map((x) => x.label).where((l) => l.length > 2 && l.length < 20).toList()..sort((a, b) => a.length.compareTo(b.length));
      speechIn.keyterms.addAll(labels.take(30));
    }).catchError((_) {}));
    debugPrint('LEO local-model: trained on ${classifier.exampleCount} examples');
    mic.onWake = _onWake;
    mic.addListener(notifyListeners);
    speechOut.addListener(() {
      mic.captureMuted = speechOut.speaking;
      notifyListeners();
    });
    _eventsSub = device.events.listen(_onNativeEvent, onError: (_) {});
    serviceRunning = await device.isListenerServiceRunning();
    if (settings.listeningEnabled) {
      await enableListening(silent: true);
    }
    notifyListeners();
  }

  void _onNativeEvent(Map<String, dynamic> e) {
    switch (e['type']) {
      case 'notificationStop':
        unawaited(stopEverything(fromNotification: true));
      case 'notificationDisable':
        unawaited(disableListening());
      case 'serviceStopped':
        serviceRunning = false;
        notifyListeners();
      case 'incoming_call':
        final caller = (e['caller'] as String?) ?? 'Unknown caller';
        unawaited(_say('Incoming call from $caller, ${settings.address}. Say "Leo, answer" or "Leo, reject".', kind: 'call'));
      case 'reminder':
        unawaited(_say('Reminder, ${settings.address}: ${e['text']}', kind: 'reminder'));
      case 'assist':
        final on = e['on'] == true;
        if (on == assistMode) return;
        assistMode = on;
        notifyListeners();
        // Like Gemini: the panel opens ready to listen.
        if (on && voice == VoicePhase.idle && !speechOut.speaking) unawaited(tapMic());
    }
  }

  void _setBanner(String? b) {
    banner = b;
    notifyListeners();
  }

  void dismissBanner() => _setBanner(null);

  // ------------------------------------------------------------------ listening control
  Future<bool> _ensureMicPermission() async {
    var st = await Permission.microphone.status;
    if (!st.isGranted) st = await Permission.microphone.request();
    if (!st.isGranted) {
      _setBanner(st.isPermanentlyDenied
          ? 'Microphone permission is blocked. Open Permissions → Microphone to allow it.'
          : 'Microphone permission was denied, so I can only take typed instructions.');
      return false;
    }
    return true;
  }

  /// Turns on the always-listening mode: microphone foreground service + offline wake word.
  Future<void> enableListening({bool silent = false}) async {
    if (!await _ensureMicPermission()) {
      settings.listeningEnabled = false;
      listeningEnabled = false;
      notifyListeners();
      return;
    }
    if (await Permission.notification.isDenied) await Permission.notification.request();
    serviceRunning = await device.startListenerService();
    if (!serviceRunning) {
      _setBanner('Android refused to start the listening service. Open LEO in the foreground and try again.');
    }
    try {
      await mic.start();
    } catch (e) {
      _setBanner('Could not open the microphone: $e');
      await device.stopListenerService();
      serviceRunning = false;
      notifyListeners();
      return;
    }
    final err = await mic.enableWakeWord(
        picovoiceKey: settings.wakeEngine == 'porcupine' ? settings.secret(SecretKey.picovoice) : null,
        sensitivity: settings.wakeSensitivity);
    listeningEnabled = true;
    settings.listeningEnabled = true;
    if (err != null) _setBanner('Wake word failed to start: $err. You can still tap the mic to talk.');
    unawaited(device.updateServiceStatus(_serviceText()));
    notifyListeners();
  }

  Future<void> disableListening() async {
    _stopLoop = true;
    speechIn.cancel();
    await mic.disableWakeWord();
    await mic.stop();
    await device.stopListenerService();
    serviceRunning = false;
    listeningEnabled = false;
    settings.listeningEnabled = false;
    voice = VoicePhase.idle;
    notifyListeners();
  }

  String _serviceText() {
    final t = task;
    if (t != null && t.state.isActive) return 'Task: ${t.title} — ${t.state.label}';
    return mic.wakeStatus == WakeWordStatus.armed ? 'Listening for "Leo" (on-device)' : 'Microphone ready — wake word off';
  }

  // ------------------------------------------------------------------ voice entry points
  void _onWake() {
    debugPrint('LEO mic-trigger: wake word detected');
    if (speechOut.speaking) {
      unawaited(speechOut.stop()); // barge-in: "Leo" interrupts speech
      if (_loopRunning) return; // the running loop listens next
    }
    if (voice != VoicePhase.idle) return;
    // Like "Hey Google": if LEO isn't on screen, pop the assistant panel up over the current app.
    unawaited(device.wakePopup().then((r) => debugPrint('LEO wake popup: $r')));
    final midConversation = _loopRunning || (task?.state.isActive ?? false);
    unawaited(_startVoiceLoop(greet: !midConversation, ack: midConversation));
  }

  /// Mic button: start/stop a voice turn manually.
  Future<void> tapMic() async {
    debugPrint('LEO mic-trigger: mic button / orb tapped');
    if (voice == VoicePhase.listening) {
      _stopLoop = true;
      speechIn.cancel();
      return;
    }
    if (speechOut.speaking) await speechOut.stop();
    if (!await _ensureMicPermission()) return;
    unawaited(_startVoiceLoop(greet: false, ack: false));
  }

  Future<void> _startVoiceLoop({required bool greet, required bool ack}) async {
    if (_loopRunning) {
      // A loop is already listening/handling: the next capture picks the user up.
      return;
    }
    _loopRunning = true;
    _stopLoop = false;
    // Like Gemini/Assistant: pause other audio while we listen; it resumes when we're done.
    await device.listenFocus(true);
    try {
      if (greet) {
        final since = _lastUserAt == null ? null : DateTime.now().difference(_lastUserAt!);
        final g = (since != null && since < const Duration(minutes: 10))
            ? greeter.shortAck(address: settings.address)
            : greeter.greet(
                now: DateTime.now(),
                address: settings.address,
                sinceLastInteraction: since,
                pendingTasks: (await memory.unfinishedTasks()).length);
        await _say(g, store: true, kind: 'greeting');
      } else if (ack) {
        await _say(greeter.shortAck(address: settings.address), store: false);
      }
      var idleWhileWaiting = 0;
      var silentTurns = 0;
      while (!_stopLoop) {
        await _untilNotSpeaking();
        if (_stopLoop) break;
        final waitingOnUser = approvals.pending != null || choice != null || _freeTextWait != null;
        final taskBusy = task?.state == AgentState.running;
        final String? heard;
        try {
          heard = await _listen(timeout: Duration(seconds: waitingOnUser || taskBusy ? 8 : 6));
        } on SpeechInputException catch (e) {
          await _say(e.message, store: false);
          break;
        } catch (e) {
          _setBanner('Speech recognition failed: $e');
          break;
        }
        if (_stopLoop) break;
        if (heard == null) {
          if (waitingOnUser && idleWhileWaiting++ < 3) continue; // keep waiting for an answer for ~30 s
          if (taskBusy) continue; // keep listening for STOP while a task runs
          // Conversation mode: don't vanish on a pause — check once, then step back politely.
          if (settings.followUpListening && silentTurns++ == 0) {
            await _say('Anything else, ${settings.address}?', kind: 'question');
            continue;
          }
          await _say("I'll be right here, ${settings.address}. Just say Leo.", kind: 'conversation');
          break;
        }
        idleWhileWaiting = 0;
        silentTurns = 0;
        await handleInput(heard, source: 'voice');
        final stillWaiting = approvals.pending != null || choice != null || _freeTextWait != null;
        final stillBusy = task?.state == AgentState.running;
        if (stillWaiting || stillBusy) continue;
        // Keep the conversation going until the user ends it ("thank you", "bye", "that's all").
        if (!settings.followUpListening) break;
      }
    } finally {
      _loopRunning = false;
      voice = VoicePhase.idle;
      if (_listeningPill) {
        _listeningPill = false;
        unawaited(device.overlayHide());
      }
      await device.listenFocus(false);
      notifyListeners();
    }
  }

  bool _listeningPill = false;

  Future<String?> _listen({required Duration timeout}) async {
    voice = VoicePhase.listening;
    notifyListeners();
    // Mid-conversation but another app is in front (e.g. LEO just opened it): show a small
    // "LEO · LISTENING" bar so it's clear LEO is still with you.
    if (_loopRunning && !(task?.state.isActive ?? false) && !await device.uiVisible()) {
      _listeningPill = true;
      unawaited(device.overlayShow().then((_) => device.overlayUpdate(
          title: 'LEO · LISTENING', detail: 'Go ahead, ${settings.address} — say "thank you" or "bye" to finish')));
    }
    try {
      final text = await speechIn.listenOnce(
        noSpeechTimeout: timeout,
        onSpeechCaptured: () {
          voice = VoicePhase.transcribing;
          notifyListeners();
        },
      );
      lastHeard = text;
      return text;
    } finally {
      voice = VoicePhase.idle;
      notifyListeners();
      if (!listeningEnabled && !_loopRunning) unawaited(mic.stop());
    }
  }

  Future<void> _untilNotSpeaking() async {
    while (speechOut.speaking) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
  }

  // ------------------------------------------------------------------ main input handler
  Future<void> submitText(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    if (speechOut.speaking) await speechOut.stop();
    await handleInput(t, source: 'text');
  }

  IntentContext get _ctx => IntentContext(
        awaitingApproval: approvals.pending != null,
        choiceCount: choice?.options.length ?? 0,
        hasActiveTask: task?.state.isActive ?? false,
        hasPausedTask: task?.state == AgentState.paused,
        hasInterruptedTask: task?.state == AgentState.interrupted,
      );

  Future<void> handleInput(String raw, {required String source}) async {
    _lastUserAt = DateTime.now();
    _currentUtterance = LocalIntentEngine.clean(raw);
    // Just the wake word ("Leo." / "Hey Leo?"), e.g. said again mid-conversation: answer, don't ask AI.
    if (LocalIntentEngine.norm(_currentUtterance).replaceAll(RegExp(r'\b(leo|jarvis|hey|hi|ok|okay)\b'), '').trim().isEmpty) {
      await _say(greeter.shortAck(address: settings.address), store: false);
      return;
    }
    var intent = engine.parse(raw, ctx: _ctx);
    // Rules didn't match → try the on-device trained model before ever considering AI.
    // A step planned by the brain that no built-in command covers ("start the stopwatch") is done on
    // screen by the agent — never silently dropped.
    if (source == 'sarvam' && _freeTextWait == null && _choiceWait == null && _approvalWait == null) {
      final notAnApp = intent is OpenAppIntent && (await apps.resolve(intent.appName)).isEmpty; // "start the stopwatch"
      if (intent is UnknownIntent || intent is KnowledgeIntent || notAnApp) intent = PhoneTaskIntent(_currentUtterance);
    }
    if (intent is UnknownIntent && _freeTextWait == null && _choiceWait == null && _approvalWait == null) {
      // Several steps / mixed language / long → let the brain plan it; the small on-device
      // classifier only ever picks ONE action and would drop the rest.
      if (source != 'sarvam' && _sarvamReady && looksComplex(_currentUtterance) && await _understandWithSarvam(raw, source)) {
        return;
      }
      final guess = classifier.classify(_currentUtterance);
      if (guess != null) {
        debugPrint('LEO local-model → ${guess.runtimeType}'); // never the user's words
        intent = guess;
      } else if (source != 'sarvam' && _sarvamReady && await _understandWithSarvam(raw, source)) {
        return; // Sarvam understood it and handed LEO clear commands
      } else {
        // Voice + screen: "delete this", "share it", "save that" in the assistant panel act on the app underneath.
        final deictic = RegExp(r'\b(this|it|that|here|these|those)\b', caseSensitive: false).hasMatch(_currentUtterance);
        if (assistMode && deictic) {
          intent = PhoneTaskIntent('$_currentUtterance (on the screen that is open right now)');
        } else {
          // Somewhat sure → ask instead of guessing or failing.
          final top = classifier.predict(_currentUtterance);
          if (top.isNotEmpty && top.first.$2 >= 0.4 && LocalIntentClassifier.describe(top.first.$1) != null) {
            final clarified = await _clarify(raw, top.first.$1);
            if (clarified != null) intent = clarified;
          }
        }
      }
    }
    if (source != 'sarvam' &&
        _sarvamReady &&
        _freeTextWait == null &&
        _choiceWait == null &&
        _approvalWait == null &&
        (intent is KnowledgeIntent ||
            (intent is PhoneTaskIntent &&
                LocalAgentBrain.shareTarget(intent.goal) == null &&
                LocalAgentBrain.searchQuery(intent.goal) == null)) &&
        await _understandWithSarvam(raw, source)) {
      return;
    }
    final kind = _kindOf(intent);
    // Steps planned by the brain are shown once as LEO's plan — not as if the user had said them.
    if (source != 'sarvam') await _store('user', raw, source: source, kind: kind, route: intent.requiresAi ? 'ai' : 'local');

    // 0) Media controls act on the playing app immediately (no task needed).
    if (intent is MediaControlIntent) return _mediaControl(intent.action);
    // Conversation context: after "play pesamale", a bare "pause"/"stop"/"resume" means the song.
    if ((intent is PauseIntent || intent is StopIntent || intent is ResumeIntent) && await _mediaContextApplies()) {
      return _mediaControl(intent is ResumeIntent ? MediaAction.play : MediaAction.pause);
    }

    // 1) Interrupt controller — always local, always first.
    switch (intent) {
      case StopIntent():
        return stop();
      case StopEverythingIntent():
        return stopEverything();
      case PauseIntent():
        return pause();
      case ResumeIntent():
        return resume();
      case CancelTaskIntent():
        return cancelTask();
      case StatusIntent():
        return _say(_statusText(), kind: 'status');
      case ContinueWhereStoppedIntent():
        return continueWhereStopped();
      case StopListeningIntent():
        _stopLoop = true;
        await _say(RegExp(r'thank', caseSensitive: false).hasMatch(_currentUtterance)
            ? 'Always a pleasure, ${settings.address}. Say "Leo" whenever you need me.'
            : 'Very well, ${settings.address}. Say "Leo" whenever you need me.');
        if (assistMode) unawaited(device.closeAssist()); // like Gemini: the panel goes away when you're done
        return;
      default:
        break;
    }

    // 2) Answers to an open question (approval / choice / free text).
    if (_approvalWait != null) {
      switch (intent) {
        case ApproveIntent():
          return approve();
        case RejectIntent():
          return reject();
        case EditMessageIntent(:final newText):
          return editPending(newText);
        default:
          await _say('I\'m waiting for your approval, ${settings.address}. Say "send it", "no", or "change it to …".');
          return;
      }
    }
    if (_choiceWait != null) {
      if (intent is ChooseOptionIntent) return choose(intent.index);
      final c = choice!;
      final byName = _matchOption(raw, c.options);
      if (byName != null) return choose(byName);
      if (c.options.length == 2 && intent is ApproveIntent) return choose(0);
      if (c.options.length == 2 && intent is RejectIntent) return choose(1);
      await _say('Please pick one of the options, ${settings.address} — for example, "the first one".');
      return;
    }
    if (_freeTextWait != null) {
      final w = _freeTextWait!;
      _freeTextWait = null;
      w.complete(LocalIntentEngine.clean(raw));
      notifyListeners();
      return;
    }

    if (task?.state.isActive ?? false) {
      if (task!.state == AgentState.running || task!.state == AgentState.planning) {
        await _say('I\'m still working on "${task!.title}", ${settings.address}. Say "stop" to interrupt it first.');
        return;
      }
    }

    // 3) Everything else becomes a task.
    switch (intent) {
      case OpenAppIntent(:final appName):
        _startTask('Open $appName', 'open_app', TaskRoute.local, {'query': appName});
      case PlayMediaIntent(:final query, :final app):
        _startTask('Play "$query"', 'play_media', TaskRoute.local, {'query': query, 'app': app.name});
      case SetAlarmIntent():
        _startTask(intent.label == null ? 'Set alarm' : 'Reminder: ${intent.label}', 'set_alarm', TaskRoute.local,
            {'text': intent.text, 'label': intent.label});
      case SetTimerIntent(:final length, :final label):
        _startTask('Timer ${TimeParser.spokenDuration(length)}', 'phone_action', TaskRoute.local,
            {'action': 'timer', 'seconds': length.inSeconds, 'label': label});
      case ScheduleMeetingIntent():
        _startTask(intent.title ?? (intent.googleMeet ? 'Google Meet meeting' : 'Calendar event'), 'schedule', TaskRoute.local, {
          'text': intent.text,
          'title': intent.title,
          'attendees': intent.attendees,
          'meet': intent.googleMeet,
          'minutes': intent.length?.inMinutes,
        });
      case StartMeetIntent():
        _startTask('Start a Google Meet', 'phone_action', TaskRoute.local, {'action': 'start_meet'});
      case NavigateIntent(:final place):
        _startTask('Navigate to $place', 'phone_action', TaskRoute.local, {'action': 'navigate', 'place': place});
      case WebSearchIntent(:final query):
        _startTask('Search: $query', 'phone_action', TaskRoute.local, {'action': 'search', 'query': query});
      case FlashlightIntent(:final on):
        _startTask('Flashlight ${on ? 'on' : 'off'}', 'phone_action', TaskRoute.local, {'action': 'torch', 'on': on});
      case CameraIntent(:final selfie, :final video):
        _startTask(video ? 'Record video' : (selfie ? 'Take a selfie' : 'Take a photo'), 'phone_action', TaskRoute.local,
            {'action': 'camera', 'selfie': selfie, 'video': video});
      case SettingsPanelIntent(:final kind, :final on):
        _startTask('Open ${kind == 'wifi' ? 'Wi-Fi' : kind} controls', 'phone_action', TaskRoute.local,
            {'action': 'panel', 'kind': kind, 'on': on});
      case ReplyIntent(:final who, :final message):
        _startTask('Reply to $who', 'reply', TaskRoute.local, {'who': who, 'message': message});
      case PhoneTaskIntent(:final goal):
        _startTask(_titleFrom(goal), 'agent', TaskRoute.ai, {'goal': goal});
      case DismissAlarmIntent(:final text, :final all):
        _startTask('Turn off ${all ? 'all alarms' : 'alarm'}', 'alarm_off', TaskRoute.local, {'text': text, 'all': all});
      case SnoozeAlarmIntent(:final minutes):
        _startTask('Snooze alarm', 'alarm_off', TaskRoute.local, {'snooze': true, 'minutes': minutes});
      case ListRemindersIntent():
        _startTask('List reminders', 'reminders', TaskRoute.local, {'op': 'list'});
      case DeleteReminderIntent(:final about, :final all):
        _startTask(all ? 'Delete all reminders' : 'Delete reminder', 'reminders', TaskRoute.local, {'op': 'delete', 'about': about, 'all': all});
      case CallControlIntent(:final action):
        _startTask('${action.name[0].toUpperCase()}${action.name.substring(1)} call', 'call_control', TaskRoute.local, {'action': action.name});
      case FindFileIntent(:final query, :final exts, :final open):
        _startTask('Find ${exts.first.toUpperCase()} "$query"', 'find_file', TaskRoute.local, {'query': query, 'exts': exts, 'open': open});
      case OpenWebsiteIntent(:final site, :final then):
        _startTask('Open $site', 'website', TaskRoute.local, {'site': site, 'then': then});
      case InstallAppIntent(:final app):
        _startTask('Install $app', 'install_app', TaskRoute.local, {'app': app});
      case ShopIntent(:final query, :final store, :final addToCart):
        _startTask('Shop: $query on $store', 'shop', TaskRoute.local, {'query': query, 'store': store, 'cart': addToCart});
      case ScreenCommandIntent(:final command, :final arg):
        _startTask('Screen: ${command.name}${arg == null ? '' : ' "$arg"'}', 'screen_cmd', TaskRoute.local, {'cmd': command.name, 'arg': arg});
      case EmailIntent(:final to, :final subject, :final body, :final topic):
        _startTask('Email $to', 'email_send', TaskRoute.local, {'to': to, 'subject': subject, 'body': body, 'topic': topic});
      case AskAppIntent(:final prompt, :final app):
        _startTask('Ask ${app ?? 'the app'}: $prompt', 'ask_app', TaskRoute.local, {'prompt': prompt, 'app': app});
      case ReadChatIntent(:final who):
        _startTask('Read chat with $who', 'read_chat', TaskRoute.local, {'who': who});
      case SignInIntent(:final appName, :final method):
        _startTask('Sign in to $appName', 'sign_in', TaskRoute.local, {'query': appName, 'method': method});
      case CallIntent(:final name):
        _startTask('Call $name', 'call', TaskRoute.local, {'name': name});
      case CheckMessagesIntent(:final whatsapp, :final email):
        _startTask(
            'Check new ${[if (whatsapp) 'WhatsApp messages', if (email) 'emails'].join(' and ')}',
            'check_messages', TaskRoute.local, {'whatsapp': whatsapp, 'email': email});
      case SendMessageIntent():
        _startTask(
          'Send ${intent.app.displayName} message to ${intent.recipient}',
          'whatsapp_send',
          intent.requiresAi ? TaskRoute.ai : TaskRoute.local,
          {
            'app': intent.app.name,
            'recipient': intent.recipient,
            'isGroup': intent.isGroup,
            'message': intent.message,
            'composeTopic': intent.composeTopic,
          },
        );
      case ForgetEverythingIntent():
        _startTask('Delete conversation history', 'forget_all', TaskRoute.local, {});
      case KnowledgeIntent(:final question):
        // A question about something the user told LEO ("what is my locker code") is answered from
        // their encrypted on-phone memory — it is never sent to a cloud model.
        final own = await _answerFromFacts(question);
        if (own != null) {
          await _say(own, kind: 'recall');
        } else {
          _startTask(_titleFrom(question), 'knowledge', TaskRoute.ai, {'text': question});
        }
      case WriteIntent(:final kind, :final request):
        _startTask(_titleFrom(request), 'write', TaskRoute.ai, {'text': request, 'writeKind': kind.name});
      case UnknownIntent(:final text):
        _startTask(_titleFrom(text), 'ai_route', TaskRoute.ai, {'text': text});
      default:
        await _localReply(intent);
    }
  }

  String _kindOf(LocalIntent i) => switch (i) {
        StopIntent() || StopEverythingIntent() || PauseIntent() || ResumeIntent() || CancelTaskIntent() ||
        StatusIntent() || ContinueWhereStoppedIntent() || StopListeningIntent() => 'control',
        ApproveIntent() || RejectIntent() || EditMessageIntent() || ChooseOptionIntent() => 'answer',
        OpenAppIntent() || SendMessageIntent() || PlayMediaIntent() || CallIntent() || CheckMessagesIntent() ||
        MediaControlIntent() || SetAlarmIntent() || SetTimerIntent() || ScheduleMeetingIntent() || StartMeetIntent() ||
        NavigateIntent() || WebSearchIntent() || FlashlightIntent() || CameraIntent() || SettingsPanelIntent() ||
        SignInIntent() || ReplyIntent() || DismissAlarmIntent() || SnoozeAlarmIntent() || ListRemindersIntent() ||
        DeleteReminderIntent() || CallControlIntent() || FindFileIntent() || OpenWebsiteIntent() || InstallAppIntent() ||
        ShopIntent() || ScreenCommandIntent() || ReadChatIntent() || AskAppIntent() || EmailIntent() => 'command',
        PhoneTaskIntent() => 'agent',
        KnowledgeIntent() => 'knowledge',
        WriteIntent() => 'write',
        RememberIntent() => 'remember',
        ContextStatementIntent() => 'statement',
        UnknownIntent() => 'conversation',
        _ => 'smalltalk',
      };

  static String _titleFrom(String s) {
    final t = LocalIntentEngine.clean(s);
    return t.length > 48 ? '${t.substring(0, 48)}…' : t;
  }

  int? _matchOption(String raw, List<String> options) {
    final n = LocalIntentEngine.norm(raw);
    for (var i = 0; i < options.length; i++) {
      if (LocalIntentEngine.norm(options[i]) == n) return i;
    }
    final hits = [
      for (var i = 0; i < options.length; i++)
        if (n.length >= 3 && LocalIntentEngine.norm(options[i]).contains(n)) i
    ];
    return hits.length == 1 ? hits.first : null;
  }

  // ------------------------------------------------------------------ local replies (no AI)
  Future<void> _localReply(LocalIntent intent) async {
    final a = settings.address;
    final now = DateTime.now();
    switch (intent) {
      case TellTimeIntent():
        final h = now.hour % 12 == 0 ? 12 : now.hour % 12;
        await _say('It\'s $h:${now.minute.toString().padLeft(2, '0')} ${now.hour < 12 ? 'AM' : 'PM'}, $a.', kind: 'info');
      case TellDateIntent():
        await _say('Today is ${_weekday(now)}, ${now.day} ${_month(now)} ${now.year}.', kind: 'info');
      case GreetingIntent():
        await _say(greeter.greet(now: now, address: a, sinceLastInteraction: const Duration(hours: 4)), kind: 'greeting');
      case HowAreYouIntent():
        await _say('All systems operational, $a. Thank you for asking. What can I do for you?');
      case ThanksIntent():
        await _say('Always a pleasure, $a.');
        // "Thank you" ends the conversation; "great"/"perfect" just acknowledge.
        if (RegExp(r'\bthank', caseSensitive: false).hasMatch(_currentUtterance)) {
          _stopLoop = true;
          if (assistMode) unawaited(device.closeAssist());
        }
      case RememberIntent(:final fact):
        await memory.addFact(fact);
        await _say('Noted, $a. I\'ll remember that: $fact. You can review or delete it under Memory.', kind: 'remember');
      case ContextStatementIntent():
        await _say('Understood, $a. I\'ve noted that in our conversation history.', kind: 'statement');
      case RecallIntent(:final topic):
        await _recall(topic);
      case ContinuePreviousWorkIntent():
        await _continuePreviousWork();
      case ApproveIntent() || RejectIntent() || EditMessageIntent():
        await _say('There\'s nothing waiting for approval right now, $a.');
      case ChooseOptionIntent():
        await _say('There\'s no open question right now, $a.');
      default:
        await _say('I\'m not sure how to help with that yet, $a.');
    }
  }

  /// "what is my locker code" → the fact the user asked LEO to remember, answered on the phone.
  /// Only questions about the user's own things ("my …", "did I tell you") are matched, and only
  /// when a stored fact shares the important words. Returns null when nothing fits.
  Future<String?> _answerFromFacts(String question) async {
    final q = question.toLowerCase();
    if (!RegExp(r"\b(my|mine|i told|did i|i said|remember)\b").hasMatch(q)) return null;
    final words = MemoryRepository.keywords(q).where((w) => !const {'what', 'which', 'where', 'when', 'tell'}.contains(w)).toSet();
    if (words.isEmpty) return null;
    (Fact, int)? best;
    for (final f in await memory.facts()) {
      final fw = MemoryRepository.keywords(f.text).toSet();
      final overlap = words.intersection(fw).length;
      if (overlap > 0 && (best == null || overlap > best.$2)) best = (f, overlap);
    }
    if (best == null || best.$2 < (words.length >= 2 ? 2 : 1)) return null;
    return 'You told me: ${best.$1.text}, ${settings.address}.';
  }

  Future<void> _recall(String? topic) async {
    final a = settings.address;
    if (topic != null && topic.trim().isNotEmpty) {
      final hits = (await memory.search(topic, limit: 10)).where((m) => m.isUser).take(3).toList();
      final facts = (await memory.facts()).where((f) => f.text.toLowerCase().contains(topic.toLowerCase())).toList();
      if (hits.isEmpty && facts.isEmpty) {
        await _say('I have nothing stored about "$topic", $a.', kind: 'recall');
        return;
      }
      final parts = [
        for (final f in facts.take(2)) 'you asked me to remember: ${f.text}',
        for (final m in hits) 'on ${_shortDate(m.createdAt)} you said: "${m.text}"',
      ];
      await _say('Here\'s what I have about $topic, $a: ${parts.join('; ')}.', kind: 'recall');
      return;
    }
    final facts = await memory.facts();
    final prev = await memory.previousMessages(sessionId,
        limit: 4, role: 'user', kinds: ['statement', 'knowledge', 'write', 'conversation', 'remember', 'command']);
    if (facts.isEmpty && prev.isEmpty) {
      await _say('I don\'t have any earlier conversations stored yet, $a.', kind: 'recall');
      return;
    }
    final parts = [
      if (facts.isNotEmpty) 'You asked me to remember ${facts.take(3).map((f) => f.text).join('; ')}',
      if (prev.isNotEmpty)
        'Recently you said: ${prev.take(3).map((m) => '"${m.text}" (${_shortDate(m.createdAt)})').join(', ')}',
    ];
    await _say('${parts.join('. ')}.', kind: 'recall');
  }

  Future<void> _continuePreviousWork() async {
    final a = settings.address;
    final unfinished = (await memory.unfinishedTasks()).where((t) => t.state == AgentState.interrupted).toList();
    if (unfinished.isNotEmpty) {
      final t = unfinished.first;
      final done = t.completedSteps.map((s) => s.description).join(', ');
      await _say('Your last unfinished task was "${t.title}", stopped on ${_shortDate(t.updatedAt)}.'
          '${done.isEmpty ? '' : ' Already done: $done.'} Shall I resume it?');
      final pick = await _askChoice('Resume "${t.title}"?', ['Resume it', 'Leave it']);
      if (pick == 0) {
        task = t;
        await continueWhereStopped();
      } else {
        await _say('Understood, I\'ll leave it.');
      }
      return;
    }
    final prev = await memory.previousMessages(sessionId,
        limit: 3, role: 'user', kinds: ['statement', 'knowledge', 'write', 'conversation', 'remember']);
    if (prev.isEmpty) {
      await _say('I don\'t have an earlier discussion stored to continue from, $a. What are we working on?');
      return;
    }
    final last = prev.first;
    await _say('Last time, on ${_shortDate(last.createdAt)}, you told me: "${last.text}". '
        '${prev.length > 1 ? 'Before that: "${prev[1].text}". ' : ''}Where would you like to pick up, $a?',
        kind: 'recall');
  }

  // ------------------------------------------------------------------ interrupt controller
  String _statusText() {
    final a = settings.address;
    final t = task;
    if (t == null) {
      return 'I\'m not running any task, $a. ${listeningEnabled && mic.wakeStatus == WakeWordStatus.armed ? 'The wake word is armed.' : ''}';
    }
    final done = t.completedSteps.map((s) => s.description).toList();
    final cur = t.currentStep?.description;
    return switch (t.state) {
      AgentState.running || AgentState.planning || AgentState.understanding =>
        'I\'m working on "${t.title}". ${cur != null ? 'Current step: $cur. ' : ''}${done.isEmpty ? '' : 'Done so far: ${done.join(', ')}.'}',
      AgentState.waitingForApproval => 'I\'m waiting for your approval on "${t.title}".',
      AgentState.paused => '"${t.title}" is paused. ${done.isEmpty ? '' : 'Done so far: ${done.join(', ')}. '}Say resume to continue.',
      AgentState.interrupted =>
        '"${t.title}" was interrupted. ${done.isEmpty ? 'Nothing was completed.' : 'Completed: ${done.join(', ')}.'} Say "continue where you stopped" to resume.',
      _ => 'Nothing is running. The last task, "${t.title}", ${t.state.name}.',
    };
  }

  String _completionReport(TaskSnapshot t) {
    final done = t.completedSteps.map((s) => s.description).toList();
    final notDone = t.steps
        .where((s) => s.status == StepStatus.cancelled || s.status == StepStatus.pending)
        .map((s) => s.description)
        .toList();
    final irreversible = t.completedSteps.where((s) => s.irreversible).toList();
    final b = StringBuffer();
    b.write(done.isEmpty ? 'Nothing had been completed yet.' : 'Completed: ${done.join(', ')}.');
    if (notDone.isNotEmpty) b.write(' Not done: ${notDone.join(', ')}.');
    if (irreversible.isNotEmpty) {
      b.write(' Note: "${irreversible.map((s) => s.description).join(', ')}" had already happened and cannot be undone.');
    }
    return b.toString();
  }

  void _abortWaits() {
    _approvalWait = null;
    _choiceWait = null;
    _freeTextWait = null;
    choice = null;
    approvals.invalidate();
  }

  Future<void> _haltInFlight() async {
    await speechOut.stop();
    ai.cancel();
    unawaited(device.whatsappCancel());
  }

  /// STOP: halt the current task, keep its state so it can be resumed, report what happened.
  Future<void> stop() async {
    await _haltInFlight();
    final tr = _tracker;
    if (tr == null || !tr.snapshot.state.isActive) {
      await _say('Stopped, ${settings.address}.', kind: 'control');
      return;
    }
    tr.control.abort(AgentState.interrupted);
    _abortWaits();
    tr.cancelRemaining();
    tr.setState(AgentState.interrupted);
    _tracker = null;
    notifyListeners();
    await _say('Stopped, ${settings.address}. ${_completionReport(tr.snapshot)} Say "continue where you stopped" to resume.',
        kind: 'control');
  }

  Future<void> stopEverything({bool fromNotification = false}) async {
    _stopLoop = true;
    speechIn.cancel();
    await _haltInFlight();
    final tr = _tracker;
    if (tr != null && tr.snapshot.state.isActive) {
      tr.control.abort(AgentState.interrupted);
      _abortWaits();
      tr.cancelRemaining();
      tr.setState(AgentState.interrupted);
      _tracker = null;
      await _say('All activity halted, ${settings.address}. ${_completionReport(tr.snapshot)}', kind: 'control');
    } else {
      _abortWaits();
      await _say('All activity halted, ${settings.address}.', kind: 'control');
    }
    notifyListeners();
  }

  Future<void> pause() async {
    final tr = _tracker;
    if (tr == null || !(tr.snapshot.state == AgentState.running || tr.snapshot.state == AgentState.waitingForApproval)) {
      await speechOut.stop();
      await _say('There\'s no running task to pause, ${settings.address}.');
      return;
    }
    await speechOut.stop();
    _stateBeforePause = tr.snapshot.state;
    tr.control.pause();
    tr.setState(AgentState.paused);
    await _say('Paused, ${settings.address}. ${tr.snapshot.completedSteps.isEmpty ? '' : 'Done so far: ${tr.snapshot.completedSteps.map((s) => s.description).join(', ')}. '}Say "resume" when ready.',
        kind: 'control');
  }

  Future<void> resume() async {
    final tr = _tracker;
    if (tr != null && tr.snapshot.state == AgentState.paused) {
      tr.setState(_stateBeforePause ?? AgentState.running);
      tr.control.resume();
      await _say('Resuming, ${settings.address}.', kind: 'control');
      return;
    }
    if (task?.state == AgentState.interrupted) return continueWhereStopped();
    await _say('Nothing is paused, ${settings.address}.');
  }

  Future<void> cancelTask() async {
    await _haltInFlight();
    final tr = _tracker;
    if (tr == null || !tr.snapshot.state.isActive) {
      final t = task;
      if (t != null && t.state == AgentState.interrupted) {
        final c = t.copyWith(state: AgentState.cancelled, result: 'Cancelled by user');
        task = c;
        await memory.updateTask(c);
        notifyListeners();
        await _say('Cancelled "${t.title}", ${settings.address}.', kind: 'control');
        return;
      }
      await _say('There\'s no task to cancel, ${settings.address}.');
      return;
    }
    tr.control.abort(AgentState.cancelled);
    _abortWaits();
    tr.cancelRemaining();
    tr.setState(AgentState.cancelled, result: 'Cancelled by user');
    _tracker = null;
    notifyListeners();
    await _say('Task cancelled, ${settings.address}. ${_completionReport(tr.snapshot)}', kind: 'control');
  }

  Future<void> continueWhereStopped() async {
    final t = task;
    if (t == null || t.state != AgentState.interrupted) {
      final unfinished = (await memory.unfinishedTasks()).where((x) => x.state == AgentState.interrupted).toList();
      if (unfinished.isEmpty) {
        await _say('There\'s no interrupted task to continue, ${settings.address}.');
        return;
      }
      task = unfinished.first;
    }
    final snap = task!;
    final runner = _runners[snap.kind];
    if (runner == null) {
      await _say('I can\'t resume that kind of task, ${settings.address}.');
      return;
    }
    final tr = TaskTracker(snap, _onTaskChange);
    tr.reopenCancelled();
    _tracker = tr;
    tr.setState(AgentState.running);
    await _say('Continuing "${snap.title}" where I stopped, ${settings.address}.', kind: 'control');
    unawaited(_execute(tr, runner));
  }

  // ------------------------------------------------------------------ approvals & questions
  Future<void> approve() async {
    final w = _approvalWait;
    if (w == null) {
      await _say('There\'s nothing waiting for approval, ${settings.address}.');
      return;
    }
    approvals.approve();
    _approvalWait = null;
    w.complete(const _ApprovalReply(_ApprovalAnswer.approve));
    notifyListeners();
  }

  Future<void> reject() async {
    final w = _approvalWait;
    if (w == null) return;
    approvals.reject();
    _approvalWait = null;
    w.complete(const _ApprovalReply(_ApprovalAnswer.reject));
    notifyListeners();
  }

  Future<void> editPending(String newText) async {
    final w = _approvalWait;
    if (w == null) return;
    approvals.invalidate(); // content changed → old approval is void
    _approvalWait = null;
    w.complete(_ApprovalReply(_ApprovalAnswer.edit, newText.trim()));
    notifyListeners();
  }

  Future<void> choose(int index) async {
    final w = _choiceWait;
    if (w == null) return;
    _choiceWait = null;
    choice = null;
    w.complete(index);
    notifyListeners();
  }

  Future<_ApprovalReply> _askApproval(TaskTracker tr, ApprovalRequest req, String prompt) async {
    approvals.request(req);
    final w = Completer<_ApprovalReply>();
    _approvalWait = w;
    tr.setState(AgentState.waitingForApproval);
    unawaited(device.updateServiceStatus('Waiting for your approval'));
    await _say(prompt, kind: 'approval');
    return tr.control.guard(w.future);
  }

  Future<int> _askChoice(String question, List<String> options, {List<String> details = const [], TaskTracker? tr}) async {
    choice = ChoicePrompt(question, options, details: details);
    final w = Completer<int>();
    _choiceWait = w;
    notifyListeners();
    final spoken = options.length <= 4
        ? '$question ${[for (var i = 0; i < options.length; i++) '${_ordinal(i)}: ${options[i]}'].join('. ')}.'
        : question;
    await _say(spoken, kind: 'question');
    return tr == null ? w.future : tr.control.guard(w.future);
  }

  Future<String> _askFreeText(TaskTracker tr, String question) async {
    final w = Completer<String>();
    _freeTextWait = w;
    notifyListeners();
    await _say(question, kind: 'question');
    return tr.control.guard(w.future);
  }

  // ------------------------------------------------------------------ task engine
  late final Map<String, _Runner> _runners = {
    'open_app': _runOpenApp,
    'whatsapp_send': _runWhatsApp,
    'forget_all': _runForgetAll,
    'knowledge': _runKnowledge,
    'write': _runWrite,
    'ai_route': _runAiRoute,
    'play_media': _runPlayMedia,
    'call': _runCall,
    'check_messages': _runCheckMessages,
    'sign_in': _runSignIn,
    'set_alarm': _runSetAlarm,
    'schedule': _runSchedule,
    'phone_action': _runPhoneAction,
    'reply': _runReply,
    'agent': _runAgent,
    'alarm_off': _runAlarmOff,
    'reminders': _runReminders,
    'call_control': _runCallControl,
    'find_file': _runFindFile,
    'website': _runWebsite,
    'install_app': _runInstallApp,
    'shop': _runShop,
    'screen_cmd': _runScreenCommand,
    'read_chat': _runReadChat,
    'ask_app': _runAskApp,
    'email_send': _runEmail,
  };

  static const _kindToLabel = {
    'open_app': 'open_app',
    'play_media': 'play_media',
    'call': 'call',
    'check_messages': 'check_messages',
    'whatsapp_send': 'send_message',
  };

  /// Learns from a successfully executed command so the on-device model handles similar
  /// phrasing locally next time — including requests that originally needed the AI.
  void _learn(TaskSnapshot t) {
    final label = _kindToLabel[t.kind];
    final text = t.params['utterance'] as String?;
    if (label == null || text == null || text.isEmpty) return;
    // Training on the user's own words needs their explicit, informed opt-in (Privacy & Security).
    if (!settings.learnFromMe) return;
    classifier.add(text, label);
    unawaited(memory.addLearnedExample(text, label, source: t.route == TaskRoute.ai ? 'ai' : 'local'));
  }

  void _onTaskChange(TaskSnapshot s) {
    task = s;
    notifyListeners();
    if (s.id > 0) unawaited(memory.updateTask(s));
    if (listeningEnabled) unawaited(device.updateServiceStatus(_serviceText()));
  }

  void _startTask(String title, String kind, TaskRoute route, Map<String, dynamic> params) {
    final now = DateTime.now();
    params = {'utterance': _currentUtterance, ...params};
    unawaited(() async {
      var snap = TaskSnapshot(
        id: 0,
        title: title,
        kind: kind,
        state: AgentState.understanding,
        steps: const [],
        route: route,
        createdAt: now,
        updatedAt: now,
        params: params,
      );
      final id = await memory.insertTask(snap, sessionId);
      snap = TaskSnapshot(
        id: id, title: title, kind: kind, state: AgentState.understanding, steps: const [], route: route,
        createdAt: now, updatedAt: now, params: params,
      );
      final tr = TaskTracker(snap, _onTaskChange);
      _tracker = tr;
      task = snap;
      draft = kind == 'write' ? null : draft;
      notifyListeners();
      tr.setState(AgentState.planning);
      tr.setState(AgentState.running);
      await _execute(tr, _runners[kind]!);
    }());
  }

  Future<void> _execute(TaskTracker tr, _Runner runner) async {
    try {
      final result = await runner(tr);
      if (tr.control.isAborted) return;
      if (tr.snapshot.state == AgentState.cancelled) return;
      tr.setState(AgentState.completed, result: result);
      if (identical(_tracker, tr)) _tracker = null;
      _learn(tr.snapshot);
    } on TaskAbort {
      // stop()/cancelTask() already moved the task to its state and reported.
    } catch (e) {
      if (tr.control.isAborted) return;
      final msg = _friendlyError(e);
      if (TaskStateMachine.canTransition(tr.snapshot.state, AgentState.failed)) {
        tr.cancelRemaining();
        tr.setState(AgentState.failed, result: msg);
      }
      if (identical(_tracker, tr)) _tracker = null;
      _abortWaits();
      await _say(msg, kind: 'error');
    } finally {
      notifyListeners();
      if (listeningEnabled) unawaited(device.updateServiceStatus(_serviceText()));
    }
  }

  String _friendlyError(Object e) {
    final a = settings.address;
    if (e is AiNotConfigured) {
      return settings.cloudBrainConsent != true
          ? 'That needs my OpenAI brain, $a, which you\'ve kept switched off — so nothing was sent. '
              'Everyday tasks still work on the phone; you can allow OpenAI in Settings → Privacy & Security.'
          : 'That needs my OpenAI brain, $a — add the OpenAI key to lib/.env and rebuild. Everyday tasks still work.';
    }
    if ((e is GeminiException && (e.status == 429 || e.message.toLowerCase().contains('quota'))) ||
        '$e'.contains('credits are used up') || '$e'.contains('rate-limiting')) {
      return 'My OpenAI credits are used up for now, $a. Everyday tasks — apps, calls, music, messages — still work '
          'locally; writing and questions will work again once the quota resets.';
    }
    final s = e.toString().replaceFirst('Exception: ', '');
    return 'I couldn\'t complete that, $a. $s';
  }

  Future<void> _mediaControl(MediaAction a) async {
    final key = switch (a) {
      MediaAction.pause => 'pause',
      MediaAction.play => 'play',
      MediaAction.next => 'next',
      MediaAction.previous => 'previous',
      MediaAction.volumeUp => 'volume_up',
      MediaAction.volumeDown => 'volume_down',
      MediaAction.mute => 'mute',
    };
    if (a == MediaAction.pause || a == MediaAction.mute) await speechOut.stop();
    final r = await device.mediaControl(key);
    final status = r['status'] as String? ?? 'unchanged';
    final sir = settings.address;
    // Use the real title from the player, else what the user asked us to play earlier.
    final title = _shortTitle(r['title'] as String?) ?? _lastMediaQuery;
    if (r['title'] != null) _lastMediaQuery = _shortTitle(r['title'] as String?);
    final it = title ?? 'the music';
    final line = switch (status) {
      'paused' => 'Paused $it, $sir.',
      'playing' => 'Resuming $it.',
      'not_playing' => title != null ? '$it isn\'t playing right now, $sir.' : 'Nothing is playing right now, $sir.',
      'already_playing' => '$it is already playing, $sir.',
      'nothing_to_resume' => 'There\'s nothing to resume, $sir.',
      'unchanged' => 'I sent the command, but the player didn\'t respond, $sir.',
      'done' => switch (a) {
          MediaAction.next => 'Next track.',
          MediaAction.previous => 'Previous track.',
          MediaAction.volumeUp => 'Volume up.',
          MediaAction.volumeDown => 'Volume down.',
          MediaAction.mute => 'Muted.',
          _ => 'Done.',
        },
      _ => 'Done.',
    };
    await _say(line, kind: 'command');
    if (status == 'playing' || (status == 'done' && (a == MediaAction.next || a == MediaAction.previous))) {
      // Music is (re)starting: end this listening turn so we don't record the song.
      _lastMediaAt = DateTime.now();
      _stopLoop = true;
      speechIn.cancel();
    }
  }

  /// What the user last asked to play, e.g. "Pesamale" — used for natural follow-ups.
  String? _lastMediaQuery;
  DateTime? _lastMediaAt;

  static String? _shortTitle(String? t) {
    if (t == null || t.trim().isEmpty) return null;
    final s = t.split(RegExp(r'\s[-|–(\[]\s?')).first.trim();
    return s.isEmpty ? t.trim() : s;
  }

  /// "stop" / "pause" / "resume" right after music was started mean the MUSIC, not a LEO task.
  Future<bool> _mediaContextApplies() async {
    if (_tracker != null && _tracker!.snapshot.state.isActive) return false;
    if (_lastMediaAt == null || DateTime.now().difference(_lastMediaAt!) > const Duration(hours: 3)) return false;
    return true;
  }

  // ---- runner: play media (local — no AI)
  Future<String?> _runPlayMedia(TaskTracker tr) async {
    final q = tr.snapshot.params['query'] as String;
    final app = MediaApp.values.byName(tr.snapshot.params['app'] as String);
    final appLabel = switch (app) {
      MediaApp.youtube => 'YouTube',
      MediaApp.youtubeMusic => 'YouTube Music',
      MediaApp.spotify => 'Spotify',
    };
    final appKey = switch (app) {
      MediaApp.youtube => 'youtube',
      MediaApp.youtubeMusic => 'youtube_music',
      MediaApp.spotify => 'spotify',
    };
    if (tr.stepStatus('search') == null) {
      tr.addStep(TaskStep(id: 'search', description: 'Search $appLabel for "$q"'));
      tr.addStep(const TaskStep(id: 'play', description: 'Start playback'));
    }
    // Announce BEFORE the music starts so LEO never talks over the song.
    await _say('Playing $q on $appLabel, ${settings.address}.', kind: 'command');
    _lastMediaQuery = q;
    _lastMediaAt = DateTime.now();
    // Let the music play: end this listening turn and release the mic's audio focus,
    // otherwise follow-up listening would pause the song and transcribe the lyrics.
    _stopLoop = true;
    speechIn.cancel();
    await device.listenFocus(false);
    tr.updateStep('search', status: StepStatus.running);
    final r = await tr.control.guard(device.playMedia(appKey, q));
    final status = r['status'] as String?;
    if (status == 'failed') {
      tr.updateStep('search', status: StepStatus.failed, detail: r['reason'] as String?);
      throw Exception(r['reason'] ?? 'Could not open $appLabel');
    }
    tr.updateStep('search', status: StepStatus.done);
    if (status == 'playing') {
      final title = r['title'] as String?;
      final short = _shortTitle(title) ?? q;
      _lastMediaQuery = short;
      _lastMediaAt = DateTime.now();
      tr.updateStep('play', status: StepStatus.done, detail: title == null ? 'Playback confirmed' : 'Playing: $title');
      // Already announced before playback; stay quiet over the music (shown on screen instead).
      await _store('assistant', 'Now playing $short.', source: 'voice', kind: 'command', route: 'local');
      return title == null ? 'Playing' : 'Playing $title';
    }
    tr.updateStep('play', status: StepStatus.skipped, detail: r['reason'] as String?);
    const pkgs = {'youtube': 'com.google.android.youtube', 'youtube_music': 'com.google.android.apps.youtube.music', 'spotify': 'com.spotify.music'};
    if (tr.snapshot.params['retried'] != true && await _offerLogin(tr, pkgs[appKey]!, appLabel)) {
      // Signed in → carry straight on with the song.
      tr.setParams({'retried': true});
      await _say('Now let me play $q, ${settings.address}.', kind: 'command');
      final r2 = await tr.control.guard(device.playMedia(appKey, q));
      if (r2['status'] == 'playing') {
        tr.updateStep('play', status: StepStatus.done, detail: 'Playing: ${r2['title'] ?? q}');
        _lastMediaAt = DateTime.now();
        return 'Playing ${r2['title'] ?? q}';
      }
      await _say('You\'re signed in, but $appLabel didn\'t start playing, ${settings.address}. Please tap play.', kind: 'command');
      return 'Signed in';
    }
    final reason = r['reason'] as String? ?? '';
    await _say(
        reason.contains('Accessibility')
            ? 'I\'ve opened the $appLabel results for $q, but couldn\'t start it automatically. Turn on the LEO accessibility service and I\'ll press play myself next time.'
            : '$reason. ${settings.address}, please tap play.',
        kind: 'command');
    return 'Results opened (not auto-played)';
  }

  static String _kindLabel(String? k) => switch (k) {
        'wifi' => 'Wi-Fi',
        'data' => 'mobile data',
        'dnd' => 'Do Not Disturb',
        'power_saving' => 'power saving',
        'dark_mode' => 'dark mode',
        'rotation' => 'auto-rotate',
        'airplane' => 'airplane mode',
        _ => k ?? 'settings',
      };

  /// Switches a feature via Quick Settings (accessibility) and reports the REAL resulting state;
  /// falls back to opening the settings panel.
  Future<Map<String, dynamic>> _toggleOrPanel(TaskTracker tr, String kind, bool? on) async {
    const switchable = {'wifi', 'bluetooth', 'data', 'hotspot', 'airplane', 'location', 'dnd', 'power_saving', 'dark_mode', 'rotation', 'nfc'};
    if (on != null && switchable.contains(kind) && await device.accessibilityEnabled()) {
      final r = await device.quickToggle(kind, on);
      final label = _kindLabel(kind);
      final word = on ? 'on' : 'off';
      final line = switch (r['status']) {
        'already' => '$label is already $word, ${settings.address}.',
        'changed' => '$label is $word now.',
        'unknown' => 'I tapped the $label switch, but couldn\'t confirm its state — please check.',
        _ => null,
      };
      if (line != null) return {'ok': true, 'line': line};
      if (r['status'] == 'unchanged') return {'ok': true, 'line': '${r['reason']}'};
    }
    return device.panel(kind);
  }

  // ---- runner: reply to a message via its notification (local)
  Future<String?> _runReply(TaskTracker tr) async {
    final a = settings.address;
    final who = tr.snapshot.params['who'] as String;
    tr.addStep(TaskStep(id: 'find', description: 'Find the latest message from $who'));
    tr.addStep(const TaskStep(id: 'approval', description: 'Get your approval'));
    tr.addStep(const TaskStep(id: 'send', description: 'Send the reply', irreversible: true));
    if (!await device.notificationAccess()) {
      throw Exception('I need notification access to reply from messages. Turn on "LEO message reader" in Permissions.');
    }
    final targets = await tr.step('find', () => device.replyTargets(who)) ?? const [];
    if (targets.isEmpty) {
      tr.updateStep('find', status: StepStatus.failed, detail: 'No unread message with a reply box');
      throw Exception('I don\'t see a recent message from $who that I can reply to. If you want, say "send a WhatsApp message to $who".');
    }
    var t = targets.first;
    if (targets.length > 1) {
      final i = await _askChoice('Which chat should I reply to?', [for (final x in targets) '${x['title']}'],
          details: [for (final x in targets) '${x['package']}'], tr: tr);
      t = targets[i];
    }
    tr.updateStep('find', detail: '${t['title']}');
    var message = tr.snapshot.params['message'] as String?;
    message ??= await _askFreeText(tr, 'What should I reply to ${t['title']}, $a?');
    while (true) {
      final reply = await _askApproval(
          tr,
          ApprovalRequest(
              id: 'reply-${tr.snapshot.id}-${DateTime.now().millisecondsSinceEpoch}',
              actionType: 'message.reply',
              title: 'Reply to ${t['title']}',
              recipientId: '${t['key']}',
              recipientLabel: '${t['title']}',
              content: message,
              appLabel: '${t['package']}'.contains('whatsapp') ? 'WhatsApp' : 'Messages'),
          'Reply to ${t['title']}: "$message". Shall I send it, $a?');
      if (reply.answer == _ApprovalAnswer.edit) {
        message = reply.newText;
        continue;
      }
      if (reply.answer != _ApprovalAnswer.approve) {
        tr.cancelRemaining();
        tr.setState(AgentState.cancelled, result: 'Not sent');
        await _say('Okay, I won\'t reply.');
        return 'Not sent';
      }
      break;
    }
    tr.setState(AgentState.running);
    tr.updateStep('approval', status: StepStatus.done);
    if (!approvals.consume('message.reply', '${t['key']}', message)) throw Exception('The approval no longer matches.');
    tr.updateStep('send', status: StepStatus.running);
    final r = await device.notificationReply('${t['key']}', message!);
    if (r['ok'] != true) {
      tr.updateStep('send', status: StepStatus.failed, detail: '${r['reason']}');
      throw Exception('The reply wasn\'t sent: ${r['reason']}');
    }
    tr.updateStep('send', status: StepStatus.done, detail: 'Sent through the notification\'s reply box');
    await _say('Replied to ${t['title']}, $a.', kind: 'command');
    return 'Replied';
  }

  // ---- runner: generic screen agent (AI plans one step at a time; LEO executes with safety rails)
  /// Buttons that need the user's OK before LEO presses them.
  static bool isSensitiveLabel(String label) => _sensitiveWords.hasMatch(label);

  static final _sensitiveWords = RegExp(
      r'\b(send|delete|remove|discard|trash|archive all|pay|payment|buy|buy now|purchase|order|place order|checkout|post|publish|share|submit|confirm|transfer|install|uninstall|book|reserve|forward|reply all|unsubscribe|block|report|clear all|factory reset|erase|'
      // Anything that reaches another person or changes the account also needs an OK:
      r'call|calls|video call|voice call|audio call|dial|ring|join|join now|start meeting|go live|follow|unfollow|accept|decline|sign out|log out|logout)\b',
      caseSensitive: false);

  Future<String?> _runAgent(TaskTracker tr) => _agentFor(tr, tr.snapshot.params['goal'] as String);

  Future<String?> _agentFor(TaskTracker tr, String goal) async {
    final a = settings.address;
    if (assistMode) {
      // The agent works in the app under the panel: get out of the way first.
      await device.closeAssist();
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
    if (!await device.accessibilityEnabled()) {
      throw Exception('To operate apps for you I need the LEO accessibility service. Turn it on in Permissions.');
    }
    // Brain: OpenAI tool-calling screen agent when available (falls back to the on-device brain).
    final cloudOk = settings.agentBrain != 'local' && settings.hasSecret(SecretKey.openai) && !OpenAiBrain.blocked;
    if (cloudOk) {
      try {
        return await _cloudScreenAgent(tr, goal);
      } on SarvamBrainException catch (e) {
        // OpenAI unreachable / no credits → try the on-device brain instead of failing outright.
        debugPrint('LEO cloud agent unavailable, falling back: $e');
        if ((await device.llmStatus())['installed'] != true) {
          throw Exception('My OpenAI brain is unavailable right now (${e.message}).');
        }
        await _say('My online brain isn\'t reachable, ${settings.address}. Trying on-device.', kind: 'command');
      }
    }
    final llm = await device.llmStatus();
    final useLocal = settings.agentBrain == 'local' && llm['installed'] == true;
    if (!useLocal && !ai.isConfigured) throw AiNotConfigured();
    if (settings.agentBrain == 'local' && llm['installed'] != true && !ai.isConfigured) {
      throw Exception('Download the on-device brain in Settings (one time, 1.6 GB) so I can operate apps without a key.');
    }
    final brain = LocalAgentBrain(device, apps);
    tr.setParams({'brain': useLocal ? 'on-device' : 'gemini'});
    await _say('On it, $a. ${useLocal ? 'Working on-device. ' : ''}I\'ll show each step — say "stop" any time.', kind: 'command');
    final brainLabel = useLocal ? 'ON-DEVICE' : 'OPENAI';
    await device.overlayShow();
    try {
      return await _agentLoop(tr, goal, useLocal, brain, brainLabel);
    } finally {
      unawaited(device.overlayHide());
    }
  }

  /// OpenAI tool-calling screen agent (Sanna-style sub-agent + LEO's approvals, STOP/PAUSE, masking).
  Future<String?> _cloudScreenAgent(TaskTracker tr, String goal) async {
    final a = settings.address;
    final model = settings.openAiModel;
    tr.setParams({'brain': 'openai'});
    await _say('On it, $a. I\'ll show each step — say "stop" any time.', kind: 'command');
    await device.overlayShow();
    var n = 0;
    final agent = ScreenAgent(
      device: device,
      apps: apps,
      brain: openAiBrain,
      apiKey: settings.secret(SecretKey.openai)!,
      model: model,
      vault: memory.vault,
      remember: settings.learnFromMe,
      hooks: ScreenAgentHooks(
        checkpoint: () => tr.control.checkpoint(),
        isSensitive: isSensitiveLabel,
        askUser: (q) async {
          unawaited(device.overlayUpdate(title: 'LEO · NEEDS YOU', detail: q, warn: true));
          return _askFreeText(tr, q);
        },
        approve: (app, button, typed) async {
          final content = typed == null ? 'Press "$button" in $app' : 'Press "$button" in $app — text: "$typed"';
          final reply = await _askApproval(
              tr,
              ApprovalRequest(
                  id: 'agent-${tr.snapshot.id}-${n + 1}', actionType: 'phone.tap', title: 'Press "$button"',
                  recipientId: '$app#$button', recipientLabel: app, content: content),
              typed == null ? '$a, shall I press "$button"?' : '$a, shall I press "$button" to send "$typed"?');
          if (reply.answer != _ApprovalAnswer.approve) return false;
          approvals.consume('phone.tap', '$app#$button', content);
          tr.setState(AgentState.running);
          return true;
        },
        onStep: (s, {index, warn = false}) {
          n++;
          tr.addStep(TaskStep(id: 'cs$n', description: s, status: warn ? StepStatus.running : StepStatus.done));
          unawaited(device.overlayUpdate(
              title: warn ? 'LEO · WAITING FOR YOUR OK' : 'LEO · STEP $n · OPENAI', detail: s, highlightIndex: index, warn: warn));
        },
        onUsage: (input, output, cached, ms, sent) {
          final cost = Pricing.cost('openai', model, input, output, cached);
          unawaited(memory.logCloud(
              provider: 'openai', model: model, purpose: 'screen_agent', sentText: sent, maskedCount: 0,
              input: input, output: output, cached: cached, cost: cost?.amount, currency: cost?.currency, latencyMs: ms, ok: true));
          unawaited(memory.logTokenUsage(
              provider: 'openai', model: model, purpose: 'screen_agent', input: input, output: output,
              total: (input ?? 0) + (output ?? 0), reported: input != null, ok: true));
        },
      ),
    );
    try {
      final r = await agent.run(goal);
      // Per-task tokens/cost are recorded in Analytics (onUsage above), not shown on the task card.
      switch (r.status) {
        case 'success':
          await _say(r.message.isEmpty ? 'Done, $a.' : r.message, kind: 'agent', route: 'openai');
          return r.message;
        case 'declined':
          tr.cancelRemaining();
          tr.setState(AgentState.cancelled, result: r.message);
          await _say(r.message, kind: 'approval');
          return r.message;
        default:
          throw Exception(r.message);
      }
    } finally {
      unawaited(device.overlayHide());
    }
  }

  /// Returns 'continue' (re-read the screen), 'stop', or null (nothing to ask — let the brain decide).
  Future<String?> _handleScreenQuestion(TaskTracker tr, String goal, Map<String, dynamic> dump, int step,
      List<String> history, Set<String> asked) async {
    final a = settings.address;
    final screen = dump['screen'] as String? ?? '';
    final pkg = dump['package'] as String?;
    final q = LocalAgentBrain.detectQuestion(screen);
    if (q == null || pkg == null) return null;
    // The goal itself says which button to press ("allow camera", "skip the ad") → no need to ask.
    final g = goal.toLowerCase();
    if (q.buttons.any((b) => RegExp('\\b${RegExp.escape(b.label.toLowerCase())}\\b').hasMatch(g))) return null;
    final sig = '$pkg|${q.question}|${q.buttons.map((b) => b.label).join('/')}';
    if (!asked.add(sig)) return null; // already asked about this exact popup
    final appLabel = (await apps.apps()).where((x) => x.packageName == pkg).map((x) => x.label).firstOrNull ?? 'The app';

    // Sign-in wall → the guided login (Google / phone number + OTP), with permission.
    final isLogin = q.buttons.where((b) => RegExp(r'^(sign in|log in|sign up|continue with (google|phone)|use phone number)$', caseSensitive: false).hasMatch(b.label)).length;
    if (isLogin > 0 && !RegExp(r'\b(sign|log) ?(in|up)\b').hasMatch(g)) {
      final ok = await _offerLogin(tr, pkg, appLabel);
      history.add('$step. sign-in screen → ${ok ? 'signed in' : 'not signed in'}');
      if (!ok) {
        await _say('I\'ll stop here then, $a. Ask me again once you\'re signed in.');
        return 'stop';
      }
      await _say('Carrying on with your request.', kind: 'command');
      return 'continue';
    }

    tr.addStep(TaskStep(id: 'q$step', description: '$appLabel asks: ${q.question}', status: StepStatus.running));
    unawaited(device.overlayUpdate(title: 'LEO · $appLabel IS ASKING', detail: q.question, warn: true));
    final options = [...q.buttons.map((b) => b.label), 'Stop the task'];
    final i = await _askChoice('$appLabel is asking: "${q.question}". What should I do, $a?', options, tr: tr);
    if (i >= q.buttons.length) {
      tr.updateStep('q$step', status: StepStatus.skipped, detail: 'You stopped the task');
      await _say('Stopped, $a. Nothing was pressed.');
      return 'stop';
    }
    final b = q.buttons[i];
    final r = await device.screenAct('tap', index: b.index);
    tr.updateStep('q$step', status: r['ok'] == true ? StepStatus.done : StepStatus.failed, detail: 'You chose "${b.label}"');
    history.add('$step. tap [${b.index}] "${b.label}" (user chose on a popup) → ${r['ok'] == true ? 'ok' : 'FAILED'}');
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    return 'continue';
  }

  Future<String?> _agentLoop(TaskTracker tr, String goal, bool useLocal, LocalAgentBrain brain, String brainLabel) async {
    final a = settings.address;
    final history = <String>[];
    final installed = (await apps.apps()).map((x) => x.label).toList();
    final askedQuestions = <String>{};
    const maxSteps = 18;
    for (var step = 1; step <= maxSteps; step++) {
      await tr.control.checkpoint();
      unawaited(device.overlayUpdate(title: 'LEO · STEP $step · THINKING ($brainLabel)', detail: 'Reading the screen…'));
      final dump = await device.screenDump(max: useLocal ? 40 : 70);
      if (dump['ok'] != true) {
        if (dump['reason'] == 'blocked_app') {
          throw Exception('For your safety I don\'t operate banking or payment apps (${dump['package']}). Please do that part yourself.');
        }
        throw Exception('I can\'t read the screen (${dump['reason']}).');
      }
      // The app is asking something (permission, "One-Step Login", update, sign-in wall…)?
      // Tell the user what it says and do what they choose — never guess on their behalf.
      final handled = await _handleScreenQuestion(tr, goal, dump, step, history, askedQuestions);
      if (handled == 'stop') return 'Stopped by user';
      if (handled == 'continue') continue;
      final Map<String, dynamic> plan;
      if (useLocal) {
        plan = await tr.control.guard(brain.step(
          goal: goal,
          screen: dump['screen'] as String? ?? '',
          package: dump['package'] as String?,
          history: history,
        ));
      } else {
        plan = await tr.control.guard(ai.agentStep(
          goal: goal,
          screen: dump['screen'] as String? ?? '',
          package: dump['package'] as String?,
          history: history.length > 8 ? history.sublist(history.length - 8) : history,
          apps: installed,
        ));
      }
      if (plan['done'] == true) {
        final summary = (plan['summary'] as String?)?.trim();
        tr.addStep(TaskStep(id: 'done', description: 'Finished', status: StepStatus.done, detail: summary));
        await _say(summary == null || summary.isEmpty ? 'Done, $a.' : '$summary', route: useLocal ? 'local' : 'ai', kind: 'agent');
        return summary ?? 'Done';
      }
      final ask = (plan['ask'] as String?)?.trim();
      final raw = plan['raw'] as String?;
      if (raw != null && plan['action'] == null && plan['done'] != true) {
        // Show what the on-device model actually said, so failures are understandable.
        tr.addStep(TaskStep(id: 'raw$step', description: 'Model reply could not be used', status: StepStatus.failed, detail: '"$raw"'));
      }
      if (ask != null && ask.isNotEmpty) {
        unawaited(device.overlayUpdate(title: 'LEO · NEEDS YOU', detail: ask, warn: true));
        final choices = (plan['choices'] as List?)?.cast<Map>();
        if (choices != null && choices.isNotEmpty) {
          final i = await _askChoice(ask, [for (final c in choices) '${c['label']}'], tr: tr);
          final pick = choices[i];
          final r = await device.screenAct('tap', index: (pick['index'] as num).toInt());
          tr.addStep(TaskStep(id: 'pick$step', description: 'Select "${pick['label']}"', status: r['ok'] == true ? StepStatus.done : StepStatus.failed, detail: 'you chose'));
          history.add('$step. tap [${pick['index']}] — Select "${pick['label']}" → ${r['ok'] == true ? 'ok' : 'FAILED'}');
          await Future<void>.delayed(const Duration(milliseconds: 800));
          continue;
        }
        final answer = await _askFreeText(tr, ask);
        history.add('$step. asked user "$ask" → "$answer"');
        continue;
      }
      final act = (plan['action'] as Map?)?.cast<String, dynamic>();
      final type = act?['type'] as String?;
      if (type == null) {
        history.add('$step. (no action returned)');
        continue;
      }
      final index = (act!['index'] as num?)?.toInt();
      final text = act['text'] as String?;
      final describe = ((plan['describe'] as String?) ?? '$type ${index ?? ''}').trim();
      String? pkg;
      if (type == 'open_app') {
        final found = await apps.resolve('${act['app'] ?? text ?? ''}');
        if (found.isEmpty) {
          history.add('$step. open_app "${act['app']}" → not installed');
          continue;
        }
        pkg = found.first.packageName;
        if (await device.isBlockedApp(pkg)) {
          throw Exception('For your safety I don\'t operate banking or payment apps (${found.first.label}).');
        }
      }
      // Safety: anything irreversible needs the user's explicit OK, described exactly.
      final screenLine = index == null
          ? ''
          : ((dump['screen'] as String).split('\n').firstWhere((l) => l.startsWith('[$index]'), orElse: () => ''));
      // A fixed recipe may declare a step harmless (e.g. opening the share sheet); the model never can.
      final declaredSafe = plan['how'] == 'rule' && plan['sensitive'] == false;
      final sensitive = plan['sensitive'] == true ||
          (!declaredSafe && type == 'tap' && _sensitiveWords.hasMatch(screenLine)) ||
          (!declaredSafe && type == 'submit' && _sensitiveWords.hasMatch(describe));
      final sid = 's$step';
      final how = switch (plan['how']) {
        'rule' => 'decided by rule',
        'match' => 'matched your words',
        'model' => 'chosen by on-device model',
        _ => useLocal ? null : 'chosen by OpenAI',
      };
      tr.addStep(TaskStep(id: sid, description: describe, irreversible: sensitive, detail: how));
      unawaited(device.overlayUpdate(
          title: sensitive ? 'LEO · WAITING FOR YOUR OK' : 'LEO · STEP $step · $brainLabel',
          detail: how == null ? describe : '$describe  ·  $how',
          highlightIndex: index,
          warn: sensitive));
      if (sensitive) {
        final reply = await _askApproval(
            tr,
            ApprovalRequest(
                id: 'agent-${tr.snapshot.id}-$step',
                actionType: 'phone.$type',
                title: describe,
                recipientId: '${dump['package']}#$index',
                recipientLabel: '${dump['package']}',
                content: screenLine.isEmpty ? describe : screenLine),
            '$describe. Shall I go ahead, $a?');
        if (reply.answer != _ApprovalAnswer.approve) {
          tr.updateStep(sid, status: StepStatus.skipped, detail: 'You said no');
          tr.cancelRemaining();
          tr.setState(AgentState.cancelled, result: 'Stopped before: $describe');
          await _say('Okay, I stopped before that step. Nothing was ${type == 'tap' ? 'pressed' : 'done'}.');
          return 'Stopped by user';
        }
        approvals.consume('phone.$type', '${dump['package']}#$index', screenLine.isEmpty ? describe : screenLine);
        tr.setState(AgentState.running);
      }
      tr.updateStep(sid, status: StepStatus.running);
      final r = await device.screenAct(type, index: index, text: text, dir: act['dir'] as String?, package: pkg);
      final ok = r['ok'] == true;
      tr.updateStep(sid, status: ok ? StepStatus.done : StepStatus.failed, detail: ok ? null : '${r['reason'] ?? 'failed'}');
      if (r['reason'] == 'password_field') {
        await _say('This needs a password, $a. For your security I never type passwords — please enter it, then say "continue".');
        throw TaskAbort(AgentState.interrupted);
      }
      history.add('$step. $type${index != null ? ' [$index]' : ''}${text != null ? ' "$text"' : ''} — $describe → ${ok ? 'ok' : 'FAILED ${r['reason'] ?? ''}'}');
      // Guard against a model looping on the same action.
      if (history.length >= 3) {
        String key(String h) => h.replaceFirst(RegExp(r'^\d+\. '), '');
        final last3 = history.sublist(history.length - 3).map(key).toSet();
        if (last3.length == 1) {
          await _say('I seem to be stuck repeating "$describe", $a, so I\'ve stopped. The steps so far are on screen.');
          return 'Stopped: repeating';
        }
      }
    }
    await _say('I couldn\'t finish that within $maxSteps steps, $a. I\'ve stopped; the steps I took are on screen.');
    return 'Step limit reached';
  }

  // ---- runner: alarm / reminder (local)
  Future<String?> _runSetAlarm(TaskTracker tr) async {
    final a = settings.address;
    final label = tr.snapshot.params['label'] as String?;
    var when = TimeParser.when(tr.snapshot.params['text'] as String);
    tr.addStep(const TaskStep(id: 'time', description: 'Understand the time'));
    tr.addStep(const TaskStep(id: 'set', description: 'Set it in the Clock app'));
    if (when == null || !when.hadTime) {
      final said = await _askFreeText(tr, 'For what time, $a?');
      when = TimeParser.when(said);
      if (when == null) throw Exception('I couldn\'t understand that time.');
    }
    final at = when.at;
    tr.updateStep('time', status: StepStatus.done, detail: TimeParser.spoken(at));
    if (label != null) {
      // A reminder: LEO schedules it itself, so it can be listed and deleted later.
      tr.updateStep('set', description: 'Save reminder', status: StepStatus.running);
      final r = await device.addReminder(at, label);
      if (r['ok'] != true) throw Exception('${r['reason'] ?? 'Could not save the reminder'}');
      tr.updateStep('set', status: StepStatus.done, detail: r['exact'] == true ? 'Exact time' : 'May be a few minutes late');
      await _say('I\'ll remind you to ${label[0].toLowerCase()}${label.substring(1)} at ${TimeParser.spoken(at)}, $a.'
          '${r['exact'] == true ? '' : ' Allow "Alarms & reminders" for LEO in Settings for exact timing.'}', kind: 'command');
      return 'Reminder ${TimeParser.spoken(at)}';
    }
    if (at.difference(DateTime.now()) > const Duration(hours: 24)) {
      // Clock alarms only ring within the next 24 h; further out, use a calendar entry with a reminder.
      tr.updateStep('set', description: 'Add a calendar reminder', status: StepStatus.running);
      final r = await device.insertEvent(label ?? 'Reminder', at, at.add(const Duration(minutes: 15)));
      if (r['ok'] != true) throw Exception(r['reason'] ?? 'Calendar could not open');
      tr.updateStep('set', status: StepStatus.done, detail: 'Calendar opened — tap Save');
      await _say('That\'s more than a day away, so I\'ve filled in a calendar reminder for ${TimeParser.spoken(at)}, $a. Tap Save to keep it.', kind: 'command');
      return 'Calendar reminder prepared';
    }
    tr.updateStep('set', status: StepStatus.running);
    final r = await device.setAlarm(at.hour, at.minute, message: label);
    if (r['ok'] != true) throw Exception(r['reason'] ?? 'The Clock app refused');
    tr.updateStep('set', status: StepStatus.done, detail: 'Clock app accepted');
    await _say(label == null
        ? 'Alarm set for ${TimeParser.spoken(at)}, $a.'
        : 'I\'ll remind you to ${label[0].toLowerCase()}${label.substring(1)} at ${TimeParser.spoken(at)}, $a.', kind: 'command');
    return 'Alarm ${TimeParser.spoken(at)}';
  }

  // ---- runner: schedule a meeting (local). The user taps Save in the calendar = approval.
  Future<String?> _runSchedule(TaskTracker tr) async {
    final a = settings.address;
    final p = tr.snapshot.params;
    final meet = p['meet'] == true;
    final names = ((p['attendees'] as List?) ?? const []).cast<String>();
    tr.addStep(const TaskStep(id: 'time', description: 'Understand date & time'));
    if (names.isNotEmpty) tr.addStep(TaskStep(id: 'guests', description: 'Find email for ${names.join(', ')}'));
    tr.addStep(TaskStep(id: 'open', description: meet ? 'Fill the event in Google Calendar with a Meet link' : 'Fill the event in Calendar'));

    var when = TimeParser.when(p['text'] as String, preferPm: true);
    if (when == null || !when.hadTime) {
      final said = await _askFreeText(tr, 'What day and time should I schedule it for, $a?');
      when = TimeParser.when('${when?.hadDay == true ? p['text'] : ''} $said', preferPm: true);
      if (when == null) throw Exception('I couldn\'t understand that time.');
    }
    final start = when.at;
    final end = start.add(Duration(minutes: (p['minutes'] as int?) ?? 30));
    tr.updateStep('time', status: StepStatus.done, detail: TimeParser.spoken(start));

    final emails = <String>[];
    final missing = <String>[];
    if (names.isNotEmpty) {
      tr.updateStep('guests', status: StepStatus.running);
      var st = await Permission.contacts.status;
      if (!st.isGranted) st = await Permission.contacts.request();
      for (final n in names) {
        final found = st.isGranted ? await device.contactEmails(n) : const <Map<String, String>>[];
        if (found.isEmpty) {
          missing.add(n);
        } else if (found.length == 1) {
          emails.add(found.first['email']!);
        } else {
          final i = await _askChoice('Which email should I invite for $n?',
              [for (final f in found) f['email']!], details: [for (final f in found) f['name']!], tr: tr);
          emails.add(found[i]['email']!);
        }
      }
      tr.updateStep('guests', status: StepStatus.done,
          detail: [if (emails.isNotEmpty) emails.join(', '), if (missing.isNotEmpty) 'no email saved for ${missing.join(', ')}'].join(' · '));
    }

    final zoom = (p['text'] as String).toLowerCase().contains('zoom');
    final useMeet = meet && !zoom;
    final title = (p['title'] as String?) ?? (zoom ? 'Zoom meeting' : (meet ? 'Google Meet' : 'Meeting'));
    tr.updateStep('open', status: StepStatus.running);
    Map<String, dynamic> r;
    if (meet || zoom) {
      String utc(DateTime d) {
        final u = d.toUtc();
        String two(int v) => v.toString().padLeft(2, '0');
        return '${u.year}${two(u.month)}${two(u.day)}T${two(u.hour)}${two(u.minute)}00Z';
      }
      final url = Uri.https('calendar.google.com', '/calendar/render', {
        'action': 'TEMPLATE',
        'text': title,
        'dates': '${utc(start)}/${utc(end)}',
        if (useMeet) 'vcon': 'meet', // Google Calendar attaches a Meet link
        if (zoom) 'location': 'Zoom',
        if (emails.isNotEmpty) 'add': emails.join(','),
        'details': zoom ? 'Zoom meeting — add the Zoom link from the Zoom app (Schedule → copy invitation).' : 'Scheduled by LEO',
      }).toString();
      r = await device.openUrl(url);
    } else {
      r = await device.insertEvent(title, start, end, emails: emails);
    }
    if (r['ok'] != true) throw Exception(r['reason'] ?? 'The calendar could not open');
    tr.updateStep('open', status: StepStatus.done, detail: 'Waiting for you to tap Save');
    final who = emails.isEmpty ? '' : ' with ${names.where((n) => !missing.contains(n)).join(' and ')} invited';
    final miss = missing.isEmpty ? '' : ' I don\'t have an email saved for ${missing.join(' and ')}, so add them in Guests.';
    if (zoom) {
      await _say('Zoom doesn\'t let other apps create Zoom links, $a, so I\'ve filled in "$title" for ${TimeParser.spoken(start)} in your calendar$who. '
          'Tap Save, then open Zoom, tap Schedule and paste the link into the event.', kind: 'command');
      return 'Event prepared (Zoom link needed)';
    }
    await _say('I\'ve filled in "$title" for ${TimeParser.spoken(start)}${useMeet ? ' with a Google Meet link' : ''}$who.$miss '
        'Please check it and tap Save, $a — nothing is sent until you do.', kind: 'command');
    return 'Event prepared (user saves)';
  }

  // ---- runner: simple phone actions (local)
  Future<String?> _runPhoneAction(TaskTracker tr) async {
    final a = settings.address;
    final p = tr.snapshot.params;
    tr.addStep(TaskStep(id: 'do', description: tr.snapshot.title));
    tr.updateStep('do', status: StepStatus.running);
    final action = p['action'] as String;
    final r = switch (action) {
      'timer' => await device.setTimer(p['seconds'] as int, message: p['label'] as String?),
      'start_meet' => await device.openUrl('https://meet.google.com/new'),
      'navigate' => await device.navigate(p['place'] as String),
      'search' => await device.webSearch(p['query'] as String),
      'torch' => await device.torch(p['on'] == true),
      'camera' => await device.camera(selfie: p['selfie'] == true, video: p['video'] == true),
      'panel' => await _toggleOrPanel(tr, p['kind'] as String, p['on'] as bool?),
      _ => const <String, dynamic>{'ok': false, 'reason': 'Unsupported action'},
    };
    if (r['ok'] != true) {
      tr.updateStep('do', status: StepStatus.failed, detail: r['reason'] as String?);
      throw Exception(r['reason'] ?? 'That didn\'t work');
    }
    tr.updateStep('do', status: StepStatus.done);
    final kind = p['kind'] as String?;
    final line = switch (action) {
      'timer' => 'Timer set for ${TimeParser.spokenDuration(Duration(seconds: p['seconds'] as int))}, $a.',
      'start_meet' => 'Starting a new Google Meet, $a.',
      'navigate' => 'Starting navigation to ${p['place']}, $a.',
      'search' => 'Here are the results for ${p['query']}.',
      'torch' => 'Flashlight ${p['on'] == true ? 'on' : 'off'}.',
      'camera' => 'Camera is ready, $a.',
      'panel' => (r['line'] as String?) ??
          (p['on'] == null
              ? 'Here are the ${_kindLabel(kind)} settings.'
              : 'I\'ve opened the ${_kindLabel(kind)} controls, $a — one tap there. (Turn on the LEO accessibility service and I can switch it myself.)'),
      _ => 'Done.',
    };
    await _say(line, kind: 'command');
    return 'Done';
  }

  /// Asks "Did you mean …?" and, on yes, re-reads the request as that action.
  Future<LocalIntent?> _clarify(String raw, String label) async {
    final what = LocalIntentClassifier.describe(label)!;
    await _store('user', raw, source: 'voice', kind: 'conversation', route: 'local');
    final w = Completer<int>();
    choice = ChoicePrompt('Did you want me to $what?', ['Yes', 'No']);
    _choiceWait = w;
    notifyListeners();
    await _say('Sorry ${settings.address}, I\'m not sure I understood. Did you want me to $what?', kind: 'question');
    final i = await w.future.timeout(const Duration(seconds: 30), onTimeout: () => 1);
    if (i != 0) {
      await _say('Okay. Could you say it another way?');
      return const ThanksIntent(); // harmless: nothing executed
    }
    return classifier.classify(_currentUtterance, minConfidence: 0) ?? UnknownIntent(raw);
  }

  // ======================================================================== round 3 runners (local)
  Future<String?> _runAlarmOff(TaskTracker tr) async {
    final a = settings.address;
    final p = tr.snapshot.params;
    tr.addStep(TaskStep(id: 'do', description: tr.snapshot.title));
    tr.updateStep('do', status: StepStatus.running);
    if (p['snooze'] == true) {
      final r = await device.snoozeAlarm(minutes: p['minutes'] as int?);
      if (r['ok'] != true) throw Exception('No alarm seems to be ringing (${r['reason']}).');
      tr.updateStep('do', status: StepStatus.done);
      await _say('Snoozed, $a.', kind: 'command');
      return 'Snoozed';
    }
    final text = (p['text'] as String?) ?? 'next';
    final when = RegExp(r'\d').hasMatch(text) ? TimeParser.when(text) : null;
    // Preferred path: flip the switch in the Clock app's list ourselves (works even when the alarm isn't ringing).
    if ((when != null || p['all'] == true) && await device.accessibilityEnabled()) {
      if (p['all'] == true) {
        final w = Completer<int>();
        choice = ChoicePrompt('Turn off ALL your alarms?', ['Yes, turn them all off', 'No']);
        _choiceWait = w;
        notifyListeners();
        await _say('That will switch off every alarm in your Clock app, $a. Shall I?', kind: 'question');
        final pick = await w.future.timeout(const Duration(seconds: 30), onTimeout: () => 1);
        if (pick != 0) {
          tr.updateStep('do', status: StepStatus.skipped, detail: 'You said no');
          await _say('Okay, I left your alarms alone.');
          return 'Kept alarms';
        }
      }
      final ampmKnown = RegExp(r'\b(a\.?m|p\.?m|morning|evening|night|afternoon|tonight)\b').hasMatch(text.toLowerCase());
      final res = await device.clockSwitchOff(hour: when?.at.hour, minute: when?.at.minute, ampmKnown: ampmKnown, all: p['all'] == true);
      if (res['ok'] == true) {
        final off = ((res['turnedOff'] as List?) ?? const []).cast<Object?>().map((e) => '$e').toList();
        final already = ((res['alreadyOff'] as List?) ?? const []).cast<Object?>().map((e) => '$e').toList();
        tr.updateStep('do', status: StepStatus.done, detail: off.isEmpty ? 'Nothing to switch off' : 'Switched off: ${off.join(', ')}');
        if (off.isNotEmpty) {
          await _say(p['all'] == true
              ? 'Done, $a. I switched off ${off.length} alarm${off.length == 1 ? '' : 's'}.'
              : 'Done, $a. Your ${off.first} alarm is off.', kind: 'command');
          return 'Turned off ${off.join(', ')}';
        }
        await _say(already.isNotEmpty
            ? 'Your ${already.first} alarm is already off, $a.'
            : p['all'] == true
                ? 'All your alarms are already off, $a.'
                : 'I couldn\'t find a ${text.trim()} alarm in your Clock app, $a.', kind: 'command');
        return already.isNotEmpty ? 'Already off' : 'Not found';
      }
      debugPrint('LEO clockSwitchOff fell back: ${res['status']}');
    }
    final r = p['all'] == true
        ? await device.dismissAlarm(mode: 'all')
        : when != null
            ? await device.dismissAlarm(mode: 'time', hour: when.at.hour, minute: when.at.minute)
            : await device.dismissAlarm(mode: 'next');
    if (r['ok'] != true) throw Exception('The Clock app didn\'t accept that (${r['reason']}).');
    tr.updateStep('do', status: StepStatus.done, detail: 'Clock app handled the request');
    final which = p['all'] == true ? 'all your alarms' : (when != null ? 'your ${TimeParser.spoken(when.at).split(' ').take(2).join(' ')} alarm' : 'your next alarm');
    await _say('I\'ve asked the Clock app to turn off $which, $a. If it shows a list, pick the one to turn off.', kind: 'command');
    return 'Dismiss requested';
  }

  Future<String?> _runReminders(TaskTracker tr) async {
    final a = settings.address;
    final p = tr.snapshot.params;
    final list = await device.listReminders();
    tr.addStep(TaskStep(id: 'list', description: 'Read your LEO reminders', status: StepStatus.done, detail: '${list.length} upcoming'));
    String fmt(Map<String, dynamic> r) =>
        '${r['text']} at ${TimeParser.spoken(DateTime.fromMillisecondsSinceEpoch(r['at'] as int))}';
    if (p['op'] == 'list') {
      await _say(list.isEmpty
          ? 'You have no upcoming reminders, $a.'
          : 'You have ${list.length} reminder${list.length == 1 ? '' : 's'}: ${list.take(5).map(fmt).join('; ')}.', kind: 'command');
      return '${list.length} reminder${list.length == 1 ? '' : 's'}';
    }
    if (list.isEmpty) {
      await _say('There are no reminders to delete, $a.');
      return 'Nothing to delete';
    }
    if (p['all'] == true) {
      final reply = await _askApproval(tr,
          ApprovalRequest(id: 'rem-all-${tr.snapshot.id}', actionType: 'reminders.delete_all', title: 'Delete all reminders', content: list.map(fmt).join('\n')),
          'Delete all ${list.length} reminders, $a?');
      if (reply.answer != _ApprovalAnswer.approve) {
        await _say('Okay, I kept them.');
        return 'Kept';
      }
      tr.setState(AgentState.running);
      await device.deleteReminder();
      await _say('All reminders deleted.', kind: 'command');
      return 'Deleted all';
    }
    final about = (p['about'] as String?)?.toLowerCase();
    var matches = about == null
        ? list
        : list.where((r) => MemoryRepository.keywords(about).any((w) => (r['text'] as String).toLowerCase().contains(w))).toList();
    if (matches.isEmpty) matches = list;
    var pick = matches.first;
    if (matches.length > 1) {
      final i = await _askChoice('Which reminder should I delete?', [for (final r in matches) fmt(r)], tr: tr);
      pick = matches[i];
    }
    await device.deleteReminder(id: pick['id'] as int);
    tr.addStep(TaskStep(id: 'del', description: 'Delete reminder', status: StepStatus.done, detail: fmt(pick)));
    await _say('Deleted the reminder: ${pick['text']}.', kind: 'command');
    return 'Deleted';
  }

  Future<String?> _runCallControl(TaskTracker tr) async {
    final a = settings.address;
    final action = tr.snapshot.params['action'] as String;
    tr.addStep(TaskStep(id: 'do', description: tr.snapshot.title));
    var ph = await Permission.phone.status;
    if (!ph.isGranted) ph = await Permission.phone.request();
    tr.updateStep('do', status: StepStatus.running);
    final r = action == 'answer' ? await device.answerCall() : await device.endCall();
    if (r['ok'] != true) {
      if (r['reason'] == 'no_permission') throw Exception('I need the Phone permission to answer or end calls.');
      throw Exception(action == 'answer' ? 'There\'s no ringing call to answer.' : 'There\'s no call to end.');
    }
    tr.updateStep('do', status: StepStatus.done);
    await _say(switch (action) { 'answer' => 'Answered.', 'reject' => 'Call rejected, $a.', _ => 'Call ended, $a.' }, kind: 'command');
    return 'Done';
  }

  Future<String?> _runFindFile(TaskTracker tr) async {
    final a = settings.address;
    final p = tr.snapshot.params;
    final q = p['query'] as String;
    final exts = ((p['exts'] as List?) ?? const ['pdf']).cast<String>();
    tr.addStep(TaskStep(id: 'search', description: 'Search your files for "${q.isEmpty ? 'any' : q}" (${exts.join('/')})'));
    if (!await device.allFilesAccess()) {
      unawaited(device.openAllFilesSettings());
      throw Exception('I need "All files access" to search your documents. I\'ve opened the setting — turn it on for LEO.');
    }
    final files = await tr.step('search', () => device.findFiles(q, exts: exts)) ?? const [];
    if (files.isEmpty) {
      tr.updateStep('search', status: StepStatus.failed, detail: 'No matches');
      // Report it as a failure (not "completed"): nothing was found or opened.
      throw Exception('I couldn\'t find any ${exts.first.toUpperCase()} named like "$q" on your phone.');
    }
    tr.updateStep('search', detail: '${files.length} found');
    var f = files.first;
    if (files.length > 1) {
      final i = await _askChoice('I found ${files.length} files. Which one?',
          [for (final x in files.take(6)) x['name'] as String], details: [for (final x in files.take(6)) 'in ${x['folder']}'], tr: tr);
      f = files[i];
    }
    tr.addStep(TaskStep(id: 'open', description: 'Open ${f['name']}'));
    final r = await tr.step('open', () => device.openFile(f['path'] as String));
    if (r?['ok'] != true) throw Exception('${r?['reason'] ?? 'Could not open it'}');
    await _say('Opening ${f['name']}, $a.', kind: 'command');
    return 'Opened';
  }

  /// A site's own search results page; unknown sites fall back to a Google `site:` search.
  static String siteSearchUrl(String site, String q) {
    final e = Uri.encodeQueryComponent(q);
    final host = site.replaceFirst(RegExp(r'^https?://'), '').replaceFirst(RegExp(r'^www\.'), '').split('/').first;
    final base = host.contains('.') ? host : '$host.com';
    final name = base.split('.').first;
    return switch (name) {
      'wikipedia' => 'https://en.wikipedia.org/w/index.php?search=$e',
      'youtube' => 'https://www.youtube.com/results?search_query=$e',
      'github' => 'https://github.com/search?q=$e',
      'amazon' => 'https://www.amazon.in/s?k=$e',
      'flipkart' => 'https://www.flipkart.com/search?q=$e',
      'reddit' => 'https://www.reddit.com/search/?q=$e',
      'stackoverflow' => 'https://stackoverflow.com/search?q=$e',
      'google' => 'https://www.google.com/search?q=$e',
      'bing' => 'https://www.bing.com/search?q=$e',
      'duckduckgo' => 'https://duckduckgo.com/?q=$e',
      'twitter' || 'x' => 'https://x.com/search?q=$e',
      'imdb' => 'https://www.imdb.com/find/?q=$e',
      'myntra' => 'https://www.myntra.com/$e',
      'swiggy' => 'https://www.swiggy.com/search?query=$e',
      'zomato' => 'https://www.zomato.com/search?q=$e',
      'quora' => 'https://www.quora.com/search?q=$e',
      'linkedin' => 'https://www.linkedin.com/search/results/all/?keywords=$e',
      _ => 'https://www.google.com/search?q=${Uri.encodeQueryComponent('site:$base $q')}',
    };
  }

  Future<String?> _runWebsite(TaskTracker tr) async {
    final a = settings.address;
    var site = (tr.snapshot.params['site'] as String).trim().toLowerCase();
    site = site.replaceAll(RegExp(r'\s+(website|site)$'), '').replaceAll(' dot com', '.com').replaceAll(' ', '');
    var url = site.startsWith('http') ? site : 'https://${site.contains('.') ? site : '$site.com'}';
    final then = tr.snapshot.params['then'] as String?;
    // "… and search for X": use the site's own search page — typing into the page is unreliable
    // (the browser's address bar is also a text box).
    final sq = then == null ? null : RegExp(r'^(?:search|look up|find|look for)(?:\s+(?:for|about))?\s+(.+)$', caseSensitive: false).firstMatch(then.trim());
    if (sq != null) {
      final searchUrl = siteSearchUrl(site, sq.group(1)!.trim());
      tr.addStep(TaskStep(id: 'open', description: 'Search $site for "${sq.group(1)!.trim()}"'));
      final r = await tr.step('open', () => device.openUrl(searchUrl));
      if (r?['ok'] != true) throw Exception('No browser could open $searchUrl.');
      await _say('Searching $site for ${sq.group(1)!.trim()}, $a.', kind: 'command');
      return 'Searched';
    }
    tr.addStep(TaskStep(id: 'open', description: 'Open $url'));
    final r = await tr.step('open', () => device.openUrl(url));
    if (r?['ok'] != true) throw Exception('No browser could open $url.');
    await _say('Opening $site, $a.', kind: 'command');
    if (then != null && then.isNotEmpty) {
      await Future<void>.delayed(const Duration(seconds: 3));
      return _agentFor(tr, '$then on $site');
    }
    return 'Opened';
  }

  Future<String?> _runInstallApp(TaskTracker tr) async {
    final app = tr.snapshot.params['app'] as String;
    // Already on the phone? Say so instead of re-installing.
    final have = (await apps.resolve(app)).where((x) => AppResolverHelpers.closeName(x.label, app)).toList();
    if (have.isNotEmpty) {
      tr.addStep(TaskStep(id: 'check', description: 'Check installed apps', status: StepStatus.done, detail: '${have.first.label} is already installed'));
      await _say('${have.first.label} is already installed, ${settings.address}. Say "open ${have.first.label}" to use it.', kind: 'command');
      return 'Already installed';
    }
    tr.addStep(TaskStep(id: 'store', description: 'Search Play Store for "$app"'));
    final r = await tr.step('store', () => device.openUrl('market://search?q=${Uri.encodeComponent(app)}&c=apps', package: 'com.android.vending'));
    if (r?['ok'] != true) throw Exception('The Play Store could not be opened.');
    await Future<void>.delayed(const Duration(seconds: 3));
    // The agent picks the matching result and taps Install — Install always asks you first.
    return _agentFor(tr, 'install $app');
  }

  /// Search a shopping app, compare results read from the screen, let the user pick, add to cart.
  /// Never buys: "Buy now" / "Place order" are blocked as sensitive and not attempted.
  Future<String?> _runShop(TaskTracker tr) async {
    final a = settings.address;
    final p = tr.snapshot.params;
    final q = p['query'] as String;
    final store = p['store'] as String;
    final searched = await _agentFor(tr, 'open $store and search for $q');
    if (tr.control.isAborted) return searched;
    await Future<void>.delayed(const Duration(seconds: 3));
    // The first screen is often ads / a sponsored video with no prices: scroll a little to reach them.
    var products = parseProducts(((await device.screenText(skipOwn: true))['lines'] as List? ?? const []).cast<String>());
    for (var s = 0; s < 2 && products.isEmpty && !tr.control.isAborted; s++) {
      await device.screenAct('scroll', dir: 'down');
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      products = parseProducts(((await device.screenText(skipOwn: true))['lines'] as List? ?? const []).cast<String>());
    }
    tr.addStep(TaskStep(id: 'compare', description: 'Compare results on screen', status: StepStatus.done, detail: '${products.length} products with prices'));
    if (products.isEmpty) {
      if (p['cart'] == true) {
        // Couldn't read prices — let the screen agent pick a result and add it (it never buys: "Buy" needs approval).
        return _agentFor(tr, 'On the $store search results for "$q", open one $q product and tap "Add to cart". Do not buy. '
            'Finish with success only when the screen shows it was added to the cart.');
      }
      await _say('I searched $store for $q, but couldn\'t read product prices on this screen, $a.');
      return 'No prices found';
    }
    final cheapest = [...products]..sort((x, y) => x.price.compareTo(y.price));
    await _say('Top results: ${products.take(3).map((x) => '${x.short} for ${x.priceText}').join('; ')}. '
        'The cheapest is ${cheapest.first.short} at ${cheapest.first.priceText}.', kind: 'command');
    if (p['cart'] != true) return 'Compared ${products.length}';
    final i = await _askChoice('Which one should I add to the cart?',
        [for (final x in products.take(5)) x.short], details: [for (final x in products.take(5)) x.priceText], tr: tr);
    final chosen = products[i];
    // The panel can hide the shopping app from accessibility: step aside before touching it.
    if (assistMode) {
      await device.closeAssist();
      await Future<void>.delayed(const Duration(milliseconds: 900));
    }
    // Deterministic first: tap the "Add to cart" in the card that shows the chosen price, then check
    // that SAME card now says "in cart". (Asking the model picked the wrong card once on Amazon.)
    const addBtn = r'add to (cart|basket|bag)';
    tr.addStep(TaskStep(id: 'cart', description: 'Tap "Add to cart" for ${chosen.short} (${chosen.priceText})', status: StepStatus.running));
    var tap = await device.tapBelow(chosen.priceText, addBtn);
    if (tap['reason'] == 'anchor_not_found') {
      await device.screenAct('scroll', dir: 'up'); // it may have scrolled just out of view
      await Future<void>.delayed(const Duration(milliseconds: 900));
      tap = await device.tapBelow(chosen.priceText, addBtn);
    }
    if (tap['ok'] == true) {
      await Future<void>.delayed(const Duration(milliseconds: 2200));
      final v = await device.tapBelow(chosen.priceText, r'in (cart|basket|bag)|added|' + addBtn, tap: false);
      final added = RegExp(r'in (cart|basket|bag)|added', caseSensitive: false).hasMatch('${v['label'] ?? ''}');
      tr.updateStep('cart', status: added ? StepStatus.done : StepStatus.failed, detail: added ? 'Card now shows "${v['label']}"' : 'Could not confirm');
      await _say(added
          ? 'Added ${chosen.short} at ${chosen.priceText} to your $store cart, $a. I haven\'t bought anything.'
          : 'I tapped "Add to cart" for ${chosen.short}, $a, but couldn\'t confirm it on screen — please check.', kind: 'command');
      return added ? 'Added to cart' : 'Unconfirmed';
    }
    tr.updateStep('cart', status: StepStatus.failed, detail: '${tap['reason'] ?? 'not found'} — handing to the agent');
    // Fallback (e.g. the card has no "Add to cart"): the screen agent, which must SEE it added before it
    // may report success. "Buy now" / "Place order" stay sensitive and are never pressed silently.
    return _agentFor(
        tr,
        'On the $store search results for "$q", tap the "Add to cart" button of the product priced ${chosen.priceText} '
        '(described as "${chosen.short}"). If that card has no "Add to cart", open the product and tap "Add to cart" there. '
        'Do not buy anything. Finish with success only when the screen shows it was added '
        '(e.g. a quantity stepper, "Added to cart", or the cart count going up).');
  }

  /// Number on the shopping app's cart badge, read from a screen dump ("Cart 3 items", "3 items in cart"), or null.
  static int? cartCount(String screen) {
    for (final line in screen.split('\n')) {
      final m = RegExp(r'cart\D{0,12}?(\d{1,3})\b|(\d{1,3})\s+items? in (?:your )?cart', caseSensitive: false).firstMatch(line);
      if (m != null) return int.tryParse(m.group(1) ?? m.group(2)!);
    }
    return null;
  }

  static List<({String title, String short, int price, String priceText})> parseProducts(List<String> lines) {
    final out = <({String title, String short, int price, String priceText})>[];
    final priceRe = RegExp(r'₹\s?([\d,]+)');
    for (var i = 0; i < lines.length; i++) {
      final m = priceRe.firstMatch(lines[i]);
      if (m == null) continue;
      // "M.R.P: ₹999" / "Buy for ₹288 with coupon" are not the selling price.
      if (RegExp(r'm\.?r\.?p|buy for|coupon|% off|save ₹', caseSensitive: false).hasMatch(lines[i])) continue;
      String? title;
      for (var j = i - 1; j >= 0 && j >= i - 6; j--) {
        final l = lines[j];
        if (priceRe.hasMatch(l)) break; // crossed into the previous product (or this one's MRP)
        // Product titles are long; skip filter chips / guides like "ANC vs transparency mode", "Best earbuds for iPhone".
        final chip = RegExp(r'(\bvs\.?\b|^best\b|^top\b|\bguide\b|\?$|^shop\b|^see\b|^explore\b)', caseSensitive: false).hasMatch(l);
        if (l.length >= 25 && !chip && !RegExp(r'(sponsored|^ad\b|rating|stars|delivery|bought|offer|ends in|heart to save|wish ?list|your list|feedback)', caseSensitive: false).hasMatch(l)) {
          title = l;
          // A long line just above is the real title (this one is its subtitle, e.g. "Charging Cables, 2-in-1…").
          if (j > 0 && lines[j - 1].length >= 25 && !priceRe.hasMatch(lines[j - 1]) &&
              !RegExp(r'(sponsored|^ad\b|rating|stars|delivery|bought|offer|ends in|heart to save|wish ?list|your list|feedback|\bvs\.?\b|^best\b)', caseSensitive: false).hasMatch(lines[j - 1])) {
            title = lines[j - 1];
          }
          break;
        }
      }
      // Some apps (Amazon) don't expose the product title as text: keep a bare price line as "result N"
      // (unless it directly follows another price — that's the struck-out list price).
      if (title == null && (i == 0 || !priceRe.hasMatch(lines[i - 1])) && RegExp(r'^₹\s?[\d,]+(\.\d+)?$').hasMatch(lines[i].trim())) title = 'result ${out.length + 1}';
      if (title == null || out.any((x) => x.title == title)) continue;
      final price = int.tryParse(m.group(1)!.replaceAll(',', '')) ?? 0;
      if (price <= 0) continue;
      final short = title.split(RegExp(r'[,|(\-–]')).first.trim();
      out.add((title: title, short: short.length > 60 ? '${short.substring(0, 60)}…' : short, price: price, priceText: '₹${m.group(1)}'));
      if (out.length >= 8) break;
    }
    return out;
  }

  /// Index of the on-screen element whose label best matches [want] (word overlap), or null.
  static int? _findElement(String screen, String want) {
    final w = MemoryRepository.keywords(want).toSet();
    final wl = want.toLowerCase();
    int? best;
    var bestScore = 0;
    for (final line in screen.split('\n')) {
      final m = RegExp(r'^\[(\d+)\]\s+\S+\s+"(.*)"').firstMatch(line);
      if (m == null) continue;
      final label = m.group(2)!.toLowerCase();
      var score = MemoryRepository.keywords(label).where(w.contains).length;
      if (label.contains(wl)) score += 3;
      if (score > bestScore) {
        bestScore = score;
        best = int.parse(m.group(1)!);
      }
    }
    return bestScore > 0 ? best : null;
  }

  Future<String?> _runScreenCommand(TaskTracker tr) async {
    final a = settings.address;
    final cmd = ScreenCommand.values.byName(tr.snapshot.params['cmd'] as String);
    final arg = tr.snapshot.params['arg'] as String?;
    if (!await device.accessibilityEnabled()) throw Exception('I need the LEO accessibility service to work with what\'s on screen.');
    final under = assistMode; // invoked from the assistant panel → act on the app underneath
    if (cmd == ScreenCommand.read) {
      var t = await device.screenText(skipOwn: true);
      if (t['ok'] != true && t['reason'] != 'blocked_app' && under) {
        // The panel can hide the app's window from accessibility: step aside, then read the app itself.
        await device.closeAssist();
        await Future<void>.delayed(const Duration(milliseconds: 800));
        t = await device.screenText(skipOwn: true);
      }
      if (t['ok'] != true) {
        throw Exception(t['reason'] == 'blocked_app' ? 'I don\'t read banking or payment apps.' : 'I can\'t read this screen.');
      }
      final lines = ((t['lines'] as List?) ?? const []).cast<String>().where((l) => l.length > 2).toList();
      tr.addStep(TaskStep(id: 'read', description: 'Read the screen', status: StepStatus.done, detail: '${lines.length} text items'));
      if (lines.isEmpty) {
        await _say('I don\'t see any text on this screen, $a.');
        return 'Empty';
      }
      await _say(lines.take(12).join('. '), kind: 'screen');
      return 'Read';
    }
    if (under) {
      await device.closeAssist();
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
    tr.addStep(TaskStep(id: 'do', description: tr.snapshot.title));
    tr.updateStep('do', status: StepStatus.running);
    Map<String, dynamic> r;
    switch (cmd) {
      case ScreenCommand.scrollDown:
        r = await device.screenAct('scroll', dir: 'down');
      case ScreenCommand.scrollUp:
        r = await device.screenAct('scroll', dir: 'up');
      case ScreenCommand.back:
        r = await device.screenAct('back');
      case ScreenCommand.home:
        r = await device.screenAct('home');
      case ScreenCommand.type:
        await device.screenDump();
        r = await device.screenAct('type', text: arg ?? '');
      case ScreenCommand.tap:
        final want = arg ?? '';
        var dump = await device.screenDump(max: 90, skipOwn: true);
        var matches = matchButtons(dump['screen'] as String? ?? '', want);
        // Not visible? Look further down the screen before giving up.
        for (var s = 0; matches.isEmpty && s < 2; s++) {
          final sc = await device.screenAct('scroll', dir: 'down');
          if (sc['ok'] != true) break;
          await Future<void>.delayed(const Duration(milliseconds: 700));
          dump = await device.screenDump(max: 90, skipOwn: true);
          matches = matchButtons(dump['screen'] as String? ?? '', want);
        }
        if (matches.isEmpty) {
          // Not a visible button: treat it as a task for the screen agent.
          tr.updateStep('do', status: StepStatus.skipped, detail: 'No "$want" on screen');
          return _agentFor(tr, 'tap $want');
        }
        var pick = matches.first;
        if (matches.length > 1) {
          // Two different buttons fit equally well → ask, don't guess.
          final i = await _askChoice('I see ${matches.length} buttons like that. Which one?', [for (final m in matches.take(4)) m.label], tr: tr);
          pick = matches[i];
        }
        final idx = pick.index;
        final screen = dump['screen'] as String? ?? '';
        tr.updateStep('do', description: 'Tap "${pick.label}"');
        // Show which button before pressing it.
        await device.overlayShow();
        await device.overlayUpdate(title: 'LEO · TAPPING', detail: pick.label, highlightIndex: idx);
        await Future<void>.delayed(const Duration(milliseconds: 600));
        unawaited(Future<void>.delayed(const Duration(milliseconds: 900), device.overlayHide));
        final line = screen.split('\n').firstWhere((l) => l.startsWith('[$idx]'), orElse: () => '');
        if (_sensitiveWords.hasMatch(line)) {
          final ok = await _askApproval(tr,
              ApprovalRequest(id: 'tap-${tr.snapshot.id}', actionType: 'phone.tap', title: 'Tap "$arg"', recipientId: '${dump['package']}#$idx', content: line),
              'That will ${arg?.toLowerCase()}. Shall I go ahead, $a?');
          if (ok.answer != _ApprovalAnswer.approve) {
            await _say('Okay, I didn\'t tap it.');
            return 'Not tapped';
          }
          approvals.consume('phone.tap', '${dump['package']}#$idx', line);
          tr.setState(AgentState.running);
        }
        r = await device.screenAct('tap', index: idx);
      case ScreenCommand.read:
        r = const {'ok': true};
    }
    if (r['ok'] != true) throw Exception('That didn\'t work (${r['reason'] ?? 'unknown'}).');
    tr.updateStep('do', status: StepStatus.done);
    if (cmd == ScreenCommand.tap) {
      final what = tr.snapshot.steps.where((s) => s.id == 'do').firstOrNull?.description.replaceFirst('Tap ', '') ?? '"$arg"';
      await _say(_loopRunning ? 'Tapped $what, $a. What next?' : 'Tapped $what, $a.', kind: 'command');
    }
    return 'Done';
  }

  /// On-screen buttons matching a spoken name, best first. Several entries only when they tie
  /// (different buttons that fit equally well → LEO asks which).
  static List<({int index, String label})> matchButtons(String screen, String want) {
    String norm(String s) => s.toLowerCase().replaceAll(RegExp(r"[^a-z0-9 ]"), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    final w = norm(want);
    if (w.isEmpty) return const [];
    final wWords = w.split(' ').where((x) => x.length > 1).toSet();
    final scored = <({int index, String label, int score})>[];
    for (final l in screen.split('\n')) {
      final m = RegExp(r'^\[(\d+)\]\s+\S+\s+"(.*)"\s*(?:\((.*)\))?$').firstMatch(l.trim());
      if (m == null) continue;
      final flags = m.group(3) ?? '';
      final full = m.group(2)!;
      // A line's label may carry "text | description | hint": score the best part.
      var best = 0;
      for (final part in full.split(' | ')) {
        final p = norm(part.replaceFirst(RegExp(r'^hint:\s*'), ''));
        if (p.isEmpty) continue;
        var s = 0;
        if (p == w) {
          s = 100;
        } else if (p.startsWith('$w ') || p.endsWith(' $w')) {
          s = 70;
        } else if (' $p '.contains(' $w ')) {
          s = 55;
        } else {
          final pw = p.split(' ').toSet();
          final hit = wWords.where(pw.contains).length;
          if (hit > 0 && hit == wWords.length) s = 40 - (pw.length - hit).clamp(0, 20);
          else if (hit > 0) s = 10 + hit * 5;
        }
        if (s > best) best = s;
      }
      if (best == 0) continue;
      if (flags.contains('tap')) best += 5; // prefer things that can actually be pressed
      final label = full.split(' | ').firstWhere((x) => x.trim().isNotEmpty, orElse: () => want).trim();
      scored.add((index: int.parse(m.group(1)!), label: label, score: best));
    }
    if (scored.isEmpty) return const [];
    scored.sort((a, b) => b.score.compareTo(a.score));
    final top = scored.first.score;
    if (top < 15) return const []; // too weak — let the agent figure it out
    final ties = <({int index, String label})>[];
    final seen = <String>{};
    for (final s in scored.where((s) => s.score == top)) {
      if (seen.add(s.label.toLowerCase())) ties.add((index: s.index, label: s.label));
    }
    return ties;
  }

  /// Compose → (approval of the exact email) → verify the draft on screen → Send.
  Future<String?> _runEmail(TaskTracker tr) async {
    final a = settings.address;
    final p = tr.snapshot.params;
    var to = (p['to'] as String).trim();
    var subject = p['subject'] as String?;
    var body = p['body'] as String?;
    final topic = p['topic'] as String?;
    tr.addStep(const TaskStep(id: 'to', description: 'Find the recipient'));
    tr.addStep(const TaskStep(id: 'write', description: 'Prepare the email'));
    tr.addStep(const TaskStep(id: 'compose', description: 'Open it in Gmail'));
    tr.addStep(const TaskStep(id: 'approval', description: 'Get your approval'));
    tr.addStep(const TaskStep(id: 'send', description: 'Send', irreversible: true));

    // 1) Recipient: an address as said, or a contact's email.
    tr.updateStep('to', status: StepStatus.running);
    if (!to.contains('@')) {
      final found = await device.contactEmails(to);
      if (found.isEmpty) throw Exception('I couldn\'t find an email address for $to in your contacts. Say the address instead.');
      var pick = found.first;
      if (found.length > 1) {
        final i = await _askChoice('Which address for $to?', [for (final f in found) '${f['name']} · ${f['email']}'], tr: tr);
        pick = found[i];
      }
      to = pick['email']!;
    }
    if (!RegExp(r'^[\w.+-]+@[\w-]+(\.[\w-]+)+$').hasMatch(to)) {
      throw Exception('"$to" doesn\'t look like a complete email address.');
    }
    tr.updateStep('to', status: StepStatus.done, detail: to);

    // 2) Body: exactly what was said, or written by the brain from the topic.
    tr.updateStep('write', status: StepStatus.running);
    if (body == null) {
      if (topic == null) {
        body = (await _askFreeText(tr, 'What should the email say, $a?')).trim();
      } else {
        final d = await tr.control.guard(ai.write(WritingKind.email, 'An email to $to about: $topic', ''));
        body = d.content;
        subject ??= d.subject;
      }
    }
    if (body.isEmpty) throw Exception('The email has no text.');
    body = '${body[0].toUpperCase()}${body.substring(1)}';
    subject ??= _subjectFrom(body);
    tr.setParams({'to': to, 'subject': subject, 'body': body});
    tr.updateStep('write', status: StepStatus.done, detail: 'Subject: $subject');

    // 3) Show it in Gmail so the user can see exactly what will go.
    final c = await tr.step('compose', () => device.emailCompose(to, subject!, body!));
    if (c?['ok'] != true) throw Exception('No email app could open (${c?['reason']}).');
    final app = c?['app'] as String?;
    await Future<void>.delayed(const Duration(milliseconds: 1200));

    // 4) Approval bound to this exact recipient + subject + text.
    final content = 'Subject: $subject\n\n$body';
    tr.updateStep('approval', status: StepStatus.running);
    final reply = await _askApproval(
        tr,
        ApprovalRequest(
            id: 'email-${tr.snapshot.id}', actionType: 'email.send', title: 'Send email',
            recipientId: to, recipientLabel: to, content: content, appLabel: 'Gmail'),
        '$a, I\'ve prepared an email to ${to.replaceAll('@', ' at ')}. Subject: $subject. It says: "$body". Shall I send it?');
    if (reply.answer != _ApprovalAnswer.approve) {
      tr.updateStep('approval', status: StepStatus.failed, detail: 'You said no');
      tr.cancelRemaining();
      tr.setState(AgentState.cancelled, result: 'Not sent — left as a draft');
      await _say('Okay, I didn\'t send it, $a. The draft is open in Gmail if you want to change it.', kind: 'approval');
      return 'Not sent';
    }
    approvals.consume('email.send', to, content);
    tr.setState(AgentState.running);
    tr.updateStep('approval', status: StepStatus.done, detail: 'Approved');

    // 5) Send — only if the draft on screen matches what was approved.
    if (!await device.accessibilityEnabled()) {
      tr.updateStep('send', status: StepStatus.skipped, detail: 'Accessibility off');
      await _say('The email is ready in Gmail, $a — please tap Send. Turn on LEO device control and I\'ll press it next time.');
      return 'Ready to send';
    }
    tr.updateStep('send', status: StepStatus.running);
    final r = await device.emailSend(to, body, app: app);
    switch (r['status']) {
      case 'sent' || 'sent_unconfirmed':
        tr.updateStep('send', status: StepStatus.done, detail: r['status'] == 'sent' ? 'Gmail is sending it' : 'Send pressed');
        await _say(_loopRunning ? 'Email sent to ${to.replaceAll('@', ' at ')}, $a. What next?' : 'Email sent, $a.', kind: 'command');
        return 'Sent to $to';
      case 'mismatch':
        tr.updateStep('send', status: StepStatus.failed, detail: r['reason'] as String?);
        await _say('I stopped before sending, $a: ${r['reason']}. Please check the draft.');
        return 'Not sent — draft differs';
      default:
        tr.updateStep('send', status: StepStatus.failed, detail: '${r['status']}');
        await _say('I couldn\'t press Send, $a. The email is ready in Gmail — please tap Send.');
        return 'Ready to send';
    }
  }

  /// "Hi" → "Hi"; a longer body → its first few words.
  static String _subjectFrom(String body) {
    final first = body.split(RegExp(r'[\n.!?]')).first.trim();
    final words = first.split(RegExp(r'\s+'));
    final s = words.length <= 6 ? first : '${words.take(6).join(' ')}…';
    return s.isEmpty ? 'Message' : '${s[0].toUpperCase()}${s.substring(1)}';
  }

  /// Apps where typing + sending reaches a PERSON. These keep the WhatsApp-style flow (exact message + approval).
  static final _messagingPkgs = RegExp(
      r'^(com\.whatsapp(\.w4b)?|org\.telegram\..*|com\.instagram\.android|com\.facebook\.orca|com\.google\.android\.apps\.messaging|'
      r'com\.samsung\.android\.messaging|com\.google\.android\.gm|com\.microsoft\.teams|com\.slack|com\.discord|com\.snapchat\.android|'
      r'com\.linkedin\.android|com\.twitter\.android|org\.thoughtcrime\.securesms)$');

  /// "ask it to prepare a PPT about blood": type the request into the app's message box and send it.
  Future<String?> _runAskApp(TaskTracker tr) async {
    final a = settings.address;
    final prompt = tr.snapshot.params['prompt'] as String;
    final appName = tr.snapshot.params['app'] as String?;
    if (!await device.accessibilityEnabled()) {
      throw Exception('I need the LEO accessibility service to type into apps. Turn it on in Permissions.');
    }
    if (appName != null) {
      final found = await apps.resolve(appName);
      if (found.isEmpty) throw Exception('$appName isn\'t installed.');
      tr.addStep(TaskStep(id: 'open', description: 'Open ${found.first.label}'));
      await tr.step('open', () => device.launchApp(found.first.packageName));
      await Future<void>.delayed(const Duration(milliseconds: 2500));
    } else if (assistMode) {
      await device.closeAssist();
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    Map<String, dynamic> dump = await device.screenDump(max: 60, skipOwn: true);
    final pkg = dump['package'] as String? ?? '';
    final label = (await apps.apps()).where((x) => x.packageName == pkg).map((x) => x.label).firstOrNull ?? 'the app';
    if (_messagingPkgs.hasMatch(pkg)) {
      // WhatsApp & co. keep the old mechanism: exact message, named recipient, your approval.
      await _say('$label sends to people, $a, so I won\'t type there directly. Say "send a message to …" and I\'ll show you the exact message first.');
      return 'Messaging app — not typed';
    }
    if (dump['ok'] != true) throw Exception('I can\'t read $label\'s screen (${dump['reason']}).');
    String screen() => dump['screen'] as String? ?? '';
    // The message box: an input field (prefer the lowest on screen = chat composer).
    int? findInput() {
      int? idx;
      for (final l in screen().split('\n')) {
        final m = RegExp(r'^\[(\d+)\]\s+\S+\s+"(.*)"\s+\((.*)\)$').firstMatch(l.trim());
        if (m != null && m.group(3)!.contains('input')) idx = int.parse(m.group(1)!);
      }
      return idx;
    }
    var input = findInput();
    if (input == null) {
      // Some apps show a "Message"/"Ask" button before the field appears.
      final starter = _findElement(screen(), 'message ask chat type reply prompt');
      if (starter != null) {
        await device.screenAct('tap', index: starter);
        await Future<void>.delayed(const Duration(milliseconds: 900));
        dump = await device.screenDump(max: 60, skipOwn: true);
        input = findInput();
      }
    }
    if (input == null) throw Exception('I couldn\'t find where to type in $label.');
    tr.addStep(TaskStep(id: 'type', description: 'Type: "$prompt"'));
    final typed = await tr.step('type', () => device.screenAct('type', index: input, text: prompt));
    if (typed?['ok'] != true) throw Exception('I couldn\'t type into $label (${typed?['reason']}).');
    await Future<void>.delayed(const Duration(milliseconds: 700));
    // Press send: a Send/Submit button, else the keyboard's enter.
    dump = await device.screenDump(max: 60, skipOwn: true);
    int? send;
    for (final l in screen().split('\n')) {
      final m = RegExp(r'^\[(\d+)\]\s+\S+\s+"(.*)"\s+\((.*)\)$').firstMatch(l.trim());
      // Never the text box itself (ChatGPT's placeholder is "Ask anything").
      if (m == null || !m.group(3)!.contains('tap') || m.group(3)!.contains('input')) continue;
      final lbl = m.group(2)!.split(' | ').where((x) => x.trim().isNotEmpty && !x.startsWith('hint:')).firstOrNull?.trim() ?? '';
      if (RegExp(r'^(send|send message|submit|send prompt)$', caseSensitive: false).hasMatch(lbl)) {
        send = int.parse(m.group(1)!);
      }
    }
    // No labelled Send button (ChatGPT's arrow has no label): tap the right-most button beside/below the
    // text box with a real tap (such apps ignore accessibility clicks).
    tr.addStep(const TaskStep(id: 'send', description: 'Send it'));
    final inputNow = findInput() ?? input;
    final sent = await tr.step('send', () async {
      if (send != null) return device.screenAct('tap', index: send);
      final r = await device.tapSendNear(inputNow);
      debugPrint('LEO ask-app send: $r');
      return r['ok'] == true ? r : await device.screenAct('submit', index: inputNow);
    });
    if (sent?['ok'] != true) throw Exception('I typed it, but couldn\'t press send in $label — please tap send.');
    // Verify: the request must have left the text box — never report "sent" on a guess.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    final after = await device.screenDump(max: 60, skipOwn: true);
    final probe = (prompt.length > 24 ? prompt.substring(0, 24) : prompt).toLowerCase();
    final stillTyped = (after['screen'] as String? ?? '')
        .split('\n')
        .any((l) => l.contains('input') && l.toLowerCase().contains(probe));
    if (stillTyped) {
      tr.updateStep('send', status: StepStatus.failed, detail: 'Text still in the box');
      await _say('I typed it into $label, $a, but the send button didn\'t respond. Please tap send.');
      return 'Typed, not sent';
    }
    await _say(_loopRunning
        ? 'Asked $label: ${prompt[0].toLowerCase()}${prompt.substring(1)}. Say "read this" when you want the answer read out. What next, $a?'
        : 'Asked $label, $a.', kind: 'command');
    return 'Sent to $label';
  }

  Future<String?> _runReadChat(TaskTracker tr) async {
    final a = settings.address;
    final who = tr.snapshot.params['who'] as String;
    tr.addStep(TaskStep(id: 'find', description: 'Find $who in contacts'));
    final contacts = await _findContacts(tr, who);
    if (contacts.isEmpty) throw Exception('I couldn\'t find $who in your contacts.');
    var c = contacts.first;
    if (contacts.length > 1) {
      final i = await _askChoice('Whose chat should I read?', [for (final x in contacts) x.name], tr: tr);
      c = contacts[i];
    }
    tr.updateStep('find', status: StepStatus.done, detail: c.name);
    tr.addStep(const TaskStep(id: 'open', description: 'Open the WhatsApp chat'));
    await tr.step('open', () => device.openWhatsAppChat('com.whatsapp', c.primaryNumber, ''));
    await Future<void>.delayed(const Duration(seconds: 3));
    final t = await device.screenText();
    final noise = RegExp(
        r'^(online|typing…|today|yesterday|message|learn more|last seen.*|\d{1,2}:\d{2}\s?(am|pm)?|'
        r'\d{1,2} (january|february|march|april|may|june|july|august|september|october|november|december)( \d{4})?|'
        r'(monday|tuesday|wednesday|thursday|friday|saturday|sunday)|'
        r'.*end-to-end encrypted.*|.*messages and calls are.*|tap to.*|.*joined using.*|.*disappearing messages.*|'
        r'.*security code (changed|with).*|.*is a contact|.*not in your contacts.*|\d+ unread messages?)$',
        caseSensitive: false);
    final lines = ((t['lines'] as List?) ?? const [])
        .cast<String>()
        .where((l) => l.length > 1 && !noise.hasMatch(l.trim()) && l.trim() != c.name)
        .toList();
    final last = lines.length > 6 ? lines.sublist(lines.length - 6) : lines;
    tr.addStep(TaskStep(id: 'read', description: 'Read the latest messages', status: StepStatus.done, detail: '${last.length} lines'));
    await _say(last.isEmpty ? 'There are no messages in your chat with ${c.name} yet, $a.' : 'Latest in your chat with ${c.name}: ${last.join('. ')}',
        kind: 'screen');
    return 'Read ${last.length}';
  }

  /// Contacts by name, with a fuzzy fallback for mis-heard names ("Rahool" → Rahul).
  /// Alternate spellings of a spoken name (one swap at a time): Pawan→Pavan, Sreya→Shreya, Deepak→Dipak.
  static List<String> spellingVariants(String name) {
    const swaps = [
      ('w', 'v'), ('v', 'w'), ('ph', 'f'), ('f', 'ph'), ('aa', 'a'), ('ee', 'i'), ('i', 'ee'), ('oo', 'u'), ('u', 'oo'),
      ('sh', 's'), ('s', 'sh'), ('th', 't'), ('t', 'th'), ('dh', 'd'), ('kh', 'k'), ('z', 'j'), ('j', 'z'), ('y', 'i'),
    ];
    final n = name.toLowerCase().trim();
    final out = <String>{};
    for (final (from, to) in swaps) {
      var i = n.indexOf(from);
      while (i >= 0) {
        out.add(n.substring(0, i) + to + n.substring(i + from.length));
        i = n.indexOf(from, i + 1);
      }
    }
    out.remove(n);
    return out.take(12).toList();
  }

  Future<List<ContactMatch>> _findContacts(TaskTracker tr, String name) async {
    var st = await Permission.contacts.status;
    if (!st.isGranted) st = await Permission.contacts.request();
    if (!st.isGranted) throw Exception('I need Contacts permission to find $name.');
    final exact = await device.searchContacts(name);
    if (exact.isNotEmpty) return exact;
    // Speech-to-text spells Indian names differently from how they're saved: Pawan/Pavan, Shreya/Sreya…
    for (final v in spellingVariants(name)) {
      final hit = await device.searchContacts(v);
      if (hit.isNotEmpty) return hit;
    }
    final first = name.split(' ').first.toLowerCase();
    if (first.length < 3) return const [];
    final broad = await device.searchContacts(first.substring(0, 2));
    final scored = [
      for (final c in broad)
        (c, AppResolver.similarity(c.name.toLowerCase().split(' ').first, first))
    ]..sort((x, y) => y.$2.compareTo(x.$2));
    return [for (final s in scored) if (s.$2 >= 0.7) s.$1];
  }

  /// Pulls a one-time code out of an SMS notification that arrived after [since]. Waits up to 45 s.
  Future<String?> _waitForOtp(TaskTracker tr, DateTime since) async {
    if (!await device.notificationAccess()) return null;
    for (var i = 0; i < 15; i++) {
      await tr.control.checkpoint();
      final items = await device.readNotifications(whatsapp: false, email: false, sms: true);
      for (final n in items.where((n) => n.time.isAfter(since.subtract(const Duration(seconds: 5))))) {
        final code = extractOtp(n.lines.join(' '));
        if (code != null) return code;
      }
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    return null;
  }

  /// "123456 is your Spotify verification code" → "123456". Needs an OTP-ish word nearby.
  static String? extractOtp(String text) {
    if (!RegExp(r'\b(otp|code|verification|verify|one[- ]time|passcode|pin)\b', caseSensitive: false).hasMatch(text)) return null;
    final m = RegExp(r'(?<![\d₹$.,/])(\d{4,8})(?!\d)(?![.,/]\d)').allMatches(text).map((m) => m.group(1)!).toList();
    if (m.isEmpty) return null;
    return m.firstWhere((c) => c.length == 6, orElse: () => m.first);
  }

  // ---- sign-in help: every step happens only after the user's answer. Never passwords; OTPs only with your OK.
  /// Returns true if the user ended up signed in.
  Future<bool> _offerLogin(TaskTracker tr, String pkg, String appLabel, {bool userAsked = false, String? preferred}) async {
    if (!await device.accessibilityEnabled()) return false;
    final scan = await device.loginScan(pkg);
    if (scan['needsLogin'] != true) {
      if (userAsked) await _say('$appLabel doesn\'t show a sign-in screen right now, ${settings.address}. You may already be signed in.');
      return false;
    }
    final a = settings.address;
    tr.addStep(TaskStep(id: 'login', description: 'Sign in to $appLabel (with your permission)'));
    tr.updateStep('login', status: StepStatus.running);
    try {
      if (!userAsked) {
        final ok = await _askChoice('$appLabel needs you to sign in. Shall I sign you in, $a?', ['Yes, sign me in', 'No'], tr: tr);
        if (ok != 0) {
          tr.updateStep('login', status: StepStatus.skipped, detail: 'You chose not to sign in');
          return false;
        }
      }
      final options = ((scan['options'] as List?) ?? const ['google']).cast<String>();
      const labels = {'google': 'Google account', 'phone': 'Phone number', 'email': 'Email'};
      var method = options.first;
      if (preferred != null && options.contains(preferred)) {
        method = preferred; // the user already said how
      } else if (options.length > 1) {
        final i = await _askChoice('Which way should I sign you in?', [for (final o in options) labels[o] ?? o], tr: tr);
        method = options[i];
      }
      if (!await device.loginChoose(pkg, method)) {
        throw Exception('I couldn\'t find the ${labels[method]} option on the $appLabel screen.');
      }
      switch (method) {
        case 'google':
          final accounts = await device.loginAccounts(pkg);
          if (accounts.isEmpty) {
            tr.updateStep('login', status: StepStatus.skipped, detail: 'Google sign-in opened');
            await _say('I\'ve opened Google sign-in, $a, but I can\'t see the account list. Please pick your account on screen.');
            return false;
          }
          final i = await _askChoice('Which Google account should I use?', accounts, tr: tr);
          if (!await device.loginPickAccount(pkg, accounts[i])) throw Exception('I couldn\'t select ${accounts[i]}.');
          tr.updateStep('login', detail: 'Account: ${accounts[i]}');
        case 'phone':
          final said = await _askFreeText(tr, 'Which phone number should I use, $a?');
          final number = said.replaceAll(RegExp(r'[^0-9+]'), '');
          if (number.length < 10) throw Exception('That doesn\'t look like a full phone number.');
          final sentAt = DateTime.now();
          final r = await device.loginEnter(pkg, number);
          if (r['ok'] != true) throw Exception('I couldn\'t type the number (${r['reason']}).');
          tr.updateStep('login', detail: 'Number entered — waiting for the code');
          await _say('I\'ve entered your number, $a. Waiting for the code.');
          // Read the OTP from the SMS notification (on the phone only); the user confirms before it's typed.
          var code = await _waitForOtp(tr, sentAt);
          if (code != null) {
            final ok = await _askChoice('I see the code $code in your messages. Shall I enter it?', ['Yes, enter it', 'No'], tr: tr);
            if (ok != 0) code = null;
          }
          code ??= (await _askFreeText(tr, 'Tell me the OTP when it arrives, $a.')).replaceAll(RegExp(r'[^0-9]'), '');
          if (code.length < 4) throw Exception('I didn\'t get a valid code.');
          final r2 = await device.loginEnter(pkg, code);
          if (r2['ok'] != true) throw Exception('I couldn\'t enter the code (${r2['reason']}).');
        case 'email':
          final email = (await _askFreeText(tr, 'Which email address should I use, $a?')).replaceAll(' at ', '@').replaceAll(' ', '');
          final r = await device.loginEnter(pkg, email);
          if (r['ok'] != true) throw Exception('I couldn\'t type the email (${r['reason']}).');
      }
      await Future<void>.delayed(const Duration(seconds: 3));
      if (await device.loginPasswordShowing(pkg)) {
        tr.updateStep('login', status: StepStatus.skipped, detail: 'Waiting for you to type the password');
        await _say('$appLabel is asking for a password, $a. For your security I never type passwords — please enter it yourself.');
        return false;
      }
      final after = await device.loginScan(pkg);
      if (after['needsLogin'] == true) {
        tr.updateStep('login', status: StepStatus.failed, detail: 'Still on the sign-in screen');
        await _say('$appLabel still shows the sign-in screen, $a. Please check it.');
        return false;
      }
      tr.updateStep('login', status: StepStatus.done);
      if (!userAsked) await _say('Login completed, $a.');
      return true;
    } finally {
      unawaited(device.loginRelease()); // shrink accessibility scope back to WhatsApp/YouTube
    }
  }

  // ---- runner: "sign in to X"
  Future<String?> _runSignIn(TaskTracker tr) async {
    final query = tr.snapshot.params['query'] as String;
    final matches = await tr.control.guard(apps.resolve(query));
    if (matches.isEmpty) throw Exception('I couldn\'t find an app called "$query".');
    final app = matches.first;
    tr.addStep(TaskStep(id: 'launch', description: 'Open ${app.label}'));
    await tr.step('launch', () => device.launchApp(app.packageName));
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!await device.accessibilityEnabled()) {
      throw Exception('I need the LEO accessibility service to help with sign-in. Turn it on in Permissions.');
    }
    final ok = await _offerLogin(tr, app.packageName, app.label, userAsked: true, preferred: tr.snapshot.params['method'] as String?);
    if (!ok) return 'Not signed in';
    // Next: what to do inside this app ("play Kesariya" → plays on Spotify).
    final next = (await _askFreeText(tr, 'Login completed, ${settings.address}. What should I do in ${app.label}?')).trim();
    if (next.isEmpty || RegExp(r'^(nothing|no|nope|that.?s it|done|ok(ay)?|thanks?( you)?)\b', caseSensitive: false).hasMatch(next)) {
      await _say('Okay, ${settings.address}.');
      return 'Signed in';
    }
    final mentionsApp = (await apps.apps()).any((x) => x.label.length > 2 && next.toLowerCase().contains(x.label.toLowerCase()));
    final followUp = mentionsApp ? next : '$next on ${app.label}';
    // Run it as a new request once this task has finished.
    unawaited(Future<void>.delayed(const Duration(milliseconds: 400), () => handleInput(followUp, source: 'voice')));
    return 'Signed in';
  }

  // ---- runner: phone call (local — no AI). Ambiguous contacts / numbers are asked, never guessed.
  Future<String?> _runCall(TaskTracker tr) async {
    final name = tr.snapshot.params['name'] as String;
    if (tr.stepStatus('contact') == null) {
      tr.addStep(TaskStep(id: 'contact', description: 'Find "$name" in contacts'));
      tr.addStep(const TaskStep(id: 'number', description: 'Choose number'));
      tr.addStep(const TaskStep(id: 'call', description: 'Place the call', irreversible: true));
    }
    String? number = tr.snapshot.params['number'] as String?;
    String label = (tr.snapshot.params['label'] as String?) ?? name;
    final digits = name.replaceAll(RegExp(r'[^0-9+]'), '');
    if (number == null && digits.length >= 6 && digits.length >= name.replaceAll(' ', '').length - 1) {
      number = digits; // the user said a number
      tr.updateStep('contact', status: StepStatus.skipped, detail: 'Number given directly');
      tr.updateStep('number', status: StepStatus.done, detail: number);
    }
    if (number == null) {
      tr.updateStep('contact', status: StepStatus.running);
      var st = await Permission.contacts.status;
      if (!st.isGranted) st = await Permission.contacts.request();
      if (!st.isGranted) throw Exception('I need Contacts permission to find $name.');
      final all = await tr.control.guard(_findContacts(tr, name));
      final exact = all.where((c) => c.name.toLowerCase() == name.toLowerCase()).toList();
      final firstName = all.where((c) => c.name.toLowerCase().split(' ').first == name.toLowerCase()).toList();
      final pool = exact.isNotEmpty ? exact : (firstName.isNotEmpty ? firstName : all);
      if (pool.isEmpty) {
        tr.updateStep('contact', status: StepStatus.failed, detail: 'No match');
        throw Exception('I couldn\'t find $name in your contacts.');
      }
      var c = pool.first;
      if (pool.length > 1) {
        final i = await _askChoice('I found ${pool.length} contacts matching "$name". Who should I call?',
            pool.map((c) => c.name).take(5).toList(), details: pool.map((c) => c.numbers.join(', ')).take(5).toList(), tr: tr);
        c = pool[i];
      }
      tr.updateStep('contact', status: StepStatus.done, detail: c.name);
      tr.updateStep('number', status: StepStatus.running);
      number = c.primaryNumber;
      if (c.numbers.length > 1) {
        final i = await _askChoice('${c.name} has ${c.numbers.length} numbers. Which one should I call?', c.numbers, tr: tr);
        number = c.numbers[i];
      }
      label = c.name;
      tr.updateStep('number', status: StepStatus.done, detail: number);
      tr.setParams({'number': number, 'label': label});
      speechIn.keyterms.add(c.name);
    }
    await tr.control.checkpoint();
    var ph = await Permission.phone.status;
    if (!ph.isGranted) ph = await Permission.phone.request();
    tr.updateStep('call', status: StepStatus.running);
    await _say('Calling $label, ${settings.address}.', kind: 'command');
    await tr.control.checkpoint(); // last chance for STOP before dialling
    final r = await device.placeCall(number);
    if (r == 'calling') {
      tr.updateStep('call', status: StepStatus.done, detail: 'Calling $number');
      return 'Calling $label';
    }
    if (r == 'dialer_opened') {
      tr.updateStep('call', status: StepStatus.skipped, detail: 'Phone permission denied — dialer opened');
      await _say('I opened the dialer with $label\'s number. Please tap call — I don\'t have phone permission.');
      return 'Dialer opened';
    }
    throw Exception('The call could not be placed (${r.replaceFirst('failed:', '')}).');
  }

  // ---- runner: check new messages / emails from notifications (local — no AI)
  Future<String?> _runCheckMessages(TaskTracker tr) async {
    final wa = tr.snapshot.params['whatsapp'] == true;
    final mail = tr.snapshot.params['email'] == true;
    if (tr.stepStatus('read') == null) {
      tr.addStep(const TaskStep(id: 'access', description: 'Check notification access'));
      tr.addStep(TaskStep(id: 'read', description: 'Read new ${[if (wa) 'WhatsApp', if (mail) 'email'].join(' & ')} notifications'));
    }
    final ok = await tr.step('access', () => device.notificationAccess());
    if (ok != true) {
      tr.updateStep('access', status: StepStatus.failed, detail: 'Notification access is off');
      unawaited(device.openNotificationAccessSettings());
      throw Exception('I need notification access to read your new messages. I\'ve opened the setting — turn on "LEO message reader".');
    }
    final items = await tr.step('read', () => device.readNotifications(whatsapp: wa, email: mail)) ?? const [];
    final chats = items.where((i) => i.isWhatsApp).toList();
    final emails = items.where((i) => !i.isWhatsApp).toList();
    final a = settings.address;
    final parts = <String>[];
    if (wa) {
      if (chats.isEmpty) {
        parts.add('No new WhatsApp messages.');
      } else {
        final total = chats.fold<int>(0, (s, c) => s + (c.count == 0 ? 1 : c.count));
        final top = chats.take(4).map((c) {
          final last = c.lines.isEmpty ? '' : ': "${c.lines.last}"';
          return '${c.title}${c.count > 1 ? ' (${c.count})' : ''}$last';
        }).join('; ');
        parts.add('$total new WhatsApp message${total == 1 ? '' : 's'} from ${chats.length} chat${chats.length == 1 ? '' : 's'}. $top.');
      }
    }
    if (mail) {
      if (emails.isEmpty) {
        parts.add('No new emails.');
      } else {
        final top = emails.take(4).map((e) => '${e.title}${e.lines.isEmpty ? '' : ' — ${e.lines.first}'}').join('; ');
        parts.add('${emails.length} new email${emails.length == 1 ? '' : 's'}: $top.');
      }
    }
    tr.updateStep('read', detail: '${chats.length} chats, ${emails.length} emails');
    await _say('${parts.join(' ')}${items.isEmpty ? '' : ' That\'s what\'s in your notifications, $a.'}', kind: 'messages');
    return '${chats.length} chats, ${emails.length} emails';
  }

  // ---- runner: open app (local)
  Future<String?> _runOpenApp(TaskTracker tr) async {
    final query = tr.snapshot.params['query'] as String;
    if (tr.stepStatus('resolve') == null) {
      tr.addStep(TaskStep(id: 'resolve', description: 'Identify app "$query"'));
      tr.addStep(const TaskStep(id: 'launch', description: 'Launch app'));
    }
    String? pkg = tr.snapshot.params['package'] as String?;
    String? label = tr.snapshot.params['label'] as String?;
    if (pkg == null) {
      final matches = await tr.step('resolve', () => apps.resolve(query));
      final list = matches ?? const [];
      if (list.isEmpty) {
        tr.updateStep('resolve', status: StepStatus.failed, detail: 'Not installed');
        throw Exception('I couldn\'t find an app called "$query" on this phone.');
      }
      var chosen = list.first;
      if (list.length > 1) {
        final i = await _askChoice('I found several apps matching "$query". Which one?',
            list.map((a) => a.label).toList(), details: list.map((a) => a.packageName).toList(), tr: tr);
        chosen = list[i];
      }
      pkg = chosen.packageName;
      label = chosen.label;
      tr.setParams({'package': pkg, 'label': label});
      tr.updateStep('resolve', detail: '$label ($pkg)');
    }
    tr.updateStep('launch', description: 'Launch $label');
    await tr.step('launch', () async {
      final ok = await device.launchApp(pkg!);
      if (!ok) throw Exception('Android did not allow $label to be launched.');
      return ok;
    }, doneDetail: 'Launch intent accepted by Android');
    // Mid-conversation: keep going ("open Claude" → "What next, sir?").
    await _say(_loopRunning ? '$label is open, ${settings.address}. What next?' : '$label is open, ${settings.address}.', kind: 'command');
    await _offerLogin(tr, pkg, label!);
    return '$label launched';
  }

  // ---- runner: WhatsApp send (local orchestration, approval-gated, accessibility execution)
  Future<String?> _runWhatsApp(TaskTracker tr) async {
    final p = tr.snapshot.params;
    final app = MessagingApp.values.byName(p['app'] as String);
    final isGroup = p['isGroup'] == true;
    final recipientQuery = p['recipient'] as String;
    if (tr.stepStatus('app') == null) {
      tr.addStep(TaskStep(id: 'app', description: 'Check ${app.displayName} is installed'));
      tr.addStep(TaskStep(id: 'recipient', description: 'Find ${isGroup ? 'group' : 'recipient'} "$recipientQuery"'));
      tr.addStep(const TaskStep(id: 'message', description: 'Prepare message'));
      tr.addStep(const TaskStep(id: 'approval', description: 'Get your approval'));
      tr.addStep(TaskStep(id: 'send', description: 'Send on ${app.displayName}', irreversible: true));
      tr.addStep(const TaskStep(id: 'verify', description: 'Verify message in chat'));
    }
    if (tr.snapshot.completedSteps.isEmpty) {
      await _say('Certainly, ${settings.address}. Preparing a ${app.displayName} message for $recipientQuery.', kind: 'command');
    }

    await tr.step('app', () async {
      if (!await device.isInstalled(app.packageName)) throw Exception('${app.displayName} is not installed on this phone.');
      return true;
    }, doneDetail: app.packageName);

    // -- recipient
    if (tr.stepStatus('recipient') != StepStatus.done) {
      await tr.control.checkpoint();
      tr.updateStep('recipient', status: StepStatus.running);
      String recipientId;
      String recipientLabel;
      String? phone;
      String? searchName;
      if (isGroup) {
        searchName = recipientQuery;
        recipientId = 'search:${recipientQuery.toLowerCase()}';
        recipientLabel = '$recipientQuery (group)';
        tr.updateStep('recipient', status: StepStatus.done, detail: 'Will open the group via WhatsApp search');
      } else {
        var contacts = <ContactMatch>[];
        var st = await Permission.contacts.status;
        if (!st.isGranted) st = await Permission.contacts.request();
        if (st.isGranted) contacts = await tr.control.guard(device.searchContacts(recipientQuery));
        final exact = contacts.where((c) => c.name.toLowerCase() == recipientQuery.toLowerCase()).toList();
        var pool = exact.isNotEmpty ? exact : contacts;
        final wa = pool.where((c) => c.hasWhatsApp).toList();
        if (wa.isNotEmpty) pool = wa;
        if (pool.isEmpty) {
          searchName = recipientQuery;
          recipientId = 'search:${recipientQuery.toLowerCase()}';
          recipientLabel = recipientQuery;
          tr.updateStep('recipient',
              status: StepStatus.done,
              detail: st.isGranted
                  ? 'Not in phone contacts — will search inside ${app.displayName}'
                  : 'Contacts permission denied — will search inside ${app.displayName}');
        } else {
          var c = pool.first;
          if (pool.length > 1) {
            final i = await _askChoice('I found ${pool.length} contacts matching "$recipientQuery". Which one?',
                pool.map((c) => c.name).toList(),
                details: pool.map((c) => c.numbers.join(', ')).toList(), tr: tr);
            c = pool[i];
          }
          var number = c.primaryNumber;
          if (c.numbers.length > 1) {
            final i = await _askChoice('${c.name} has ${c.numbers.length} numbers. Which one?', c.numbers, tr: tr);
            number = c.numbers[i];
          }
          phone = number;
          recipientId = 'tel:${number.replaceAll(RegExp(r'[^0-9+]'), '')}';
          recipientLabel = '${c.name} ($number)';
          speechIn.keyterms.add(c.name);
          tr.updateStep('recipient', status: StepStatus.done, detail: recipientLabel);
        }
      }
      tr.setParams({'recipientId': recipientId, 'recipientLabel': recipientLabel, 'phone': phone, 'searchName': searchName});
    }

    // -- message
    if (tr.stepStatus('message') != StepStatus.done) {
      await tr.control.checkpoint();
      tr.updateStep('message', status: StepStatus.running);
      var message = tr.snapshot.params['message'] as String?;
      final topic = tr.snapshot.params['composeTopic'] as String?;
      if ((message == null || message.isEmpty) && topic != null) {
        tr.updateStep('message', description: 'Compose message with AI writer');
        final ctx = await contextBuilder.build(sessionId: sessionId, query: topic, includeRecent: false);
        message = await tr.control.guard(ai.composeMessage(recipientQuery, topic, ctx.text));
      }
      if (message == null || message.isEmpty) {
        message = await _askFreeText(tr, 'What should the message say, ${settings.address}?');
      }
      tr.setParams({'message': message});
      tr.updateStep('message', status: StepStatus.done, detail: '"$message"');
    }

    // -- approval (bound to exact recipient + content; edits require re-approval)
    if (tr.stepStatus('approval') != StepStatus.done || !approvals.isApproved('whatsapp.send', tr.snapshot.params['recipientId'] as String, tr.snapshot.params['message'] as String)) {
      tr.updateStep('approval', status: StepStatus.running);
      while (true) {
        final recipientId = tr.snapshot.params['recipientId'] as String;
        final recipientLabel = tr.snapshot.params['recipientLabel'] as String;
        final message = tr.snapshot.params['message'] as String;
        final req = ApprovalRequest(
          id: '${tr.snapshot.id}-${DateTime.now().millisecondsSinceEpoch}',
          actionType: 'whatsapp.send',
          title: 'Send ${app.displayName} message',
          recipientId: recipientId,
          recipientLabel: recipientLabel,
          content: message,
          appLabel: app.displayName,
        );
        final reply = await _askApproval(tr, req,
            '${settings.address}, I\'ve prepared this message for ${recipientLabel.replaceAll(RegExp(r' \(.*\)$'), '')}: "$message". Shall I send it?');
        if (reply.answer == _ApprovalAnswer.approve) {
          tr.setState(AgentState.running);
          tr.updateStep('approval', status: StepStatus.done, detail: 'Approved: "$message"');
          break;
        }
        if (reply.answer == _ApprovalAnswer.reject) {
          tr.updateStep('approval', status: StepStatus.failed, detail: 'You declined');
          tr.cancelRemaining();
          tr.setState(AgentState.cancelled, result: 'Not sent — you declined');
          if (identical(_tracker, tr)) _tracker = null;
          await _say('Understood, ${settings.address}. I won\'t send it.', kind: 'approval');
          return 'Not sent';
        }
        // edit → new content, ask again
        tr.setParams({'message': reply.newText});
        tr.updateStep('message', detail: '"${reply.newText}" (edited)');
        tr.setState(AgentState.planning);
      }
    }

    // -- send (irreversible; NOT raced with abort so we never misreport a sent message)
    await tr.control.checkpoint();
    final recipientId = tr.snapshot.params['recipientId'] as String;
    final message = tr.snapshot.params['message'] as String;
    final phone = tr.snapshot.params['phone'] as String?;
    final searchName = tr.snapshot.params['searchName'] as String?;
    if (!approvals.consume('whatsapp.send', recipientId, message)) {
      throw Exception('The approval no longer matches the message, so I did not send it.');
    }
    tr.updateStep('send', status: StepStatus.running);
    if (!await device.accessibilityEnabled()) {
      if (phone != null) {
        final opened = await device.openWhatsAppChat(app.packageName, phone, message);
        if (!opened) throw Exception('I couldn\'t open the ${app.displayName} chat.');
        tr.updateStep('send', status: StepStatus.skipped, detail: 'Accessibility is off — chat opened with the message pre-filled');
        tr.updateStep('verify', status: StepStatus.skipped, detail: 'You need to tap Send');
        await _say('The LEO accessibility service is off, so I can\'t press Send myself. I\'ve opened the chat with your message ready, ${settings.address}. Please tap Send.',
            kind: 'command');
        return 'Chat opened with pre-filled message (user must tap Send)';
      }
      throw Exception('To message a group I need the LEO accessibility service. Enable it in Permissions.');
    }
    var result = await device.whatsappSend(packageName: app.packageName, phone: phone, searchName: searchName, message: message);
    if (result.status == WhatsAppSendStatus.ambiguous && result.candidates.isNotEmpty) {
      final i = await _askChoice('I found several chats matching "$searchName". Which one?', result.candidates, tr: tr);
      final pickedName = result.candidates[i];
      // Recipient changed from a search term to a specific chat → approval must be renewed.
      final newId = 'search:${pickedName.toLowerCase()}';
      tr.setParams({'searchName': pickedName, 'recipientId': newId, 'recipientLabel': pickedName});
      final reply = await _askApproval(
          tr,
          ApprovalRequest(
              id: '${tr.snapshot.id}-chat', actionType: 'whatsapp.send', title: 'Send ${app.displayName} message',
              recipientId: newId, recipientLabel: pickedName, content: message, appLabel: app.displayName),
          'Send "$message" to $pickedName, ${settings.address}?');
      if (reply.answer != _ApprovalAnswer.approve || !approvals.consume('whatsapp.send', newId, message)) {
        tr.cancelRemaining();
        tr.setState(AgentState.cancelled, result: 'Not sent');
        await _say('Alright, I haven\'t sent anything.', kind: 'approval');
        return 'Not sent';
      }
      tr.setState(AgentState.running);
      result = await device.whatsappSend(packageName: app.packageName, searchName: pickedName, message: message);
    }
    unawaited(device.bringToFront());
    if (!result.sendPressed) {
      tr.updateStep('send', status: result.status == WhatsAppSendStatus.cancelled ? StepStatus.cancelled : StepStatus.failed,
          detail: result.reason);
      if (result.status == WhatsAppSendStatus.cancelled) throw TaskAbort(AgentState.interrupted);
      throw Exception('The message was not sent: ${result.reason ?? 'unknown reason'}.');
    }
    tr.updateStep('send', status: StepStatus.done, detail: 'Send pressed in ${result.chatTitle ?? app.displayName}');
    if (result.status == WhatsAppSendStatus.verified) {
      tr.updateStep('verify', status: StepStatus.done, detail: 'Message visible in the chat');
      await _say('Done, ${settings.address}. Your message to ${result.chatTitle ?? recipientQuery} has been sent — I can see it in the chat.',
          kind: 'command');
      return 'Sent and verified in chat';
    }
    tr.updateStep('verify', status: StepStatus.failed, detail: result.reason ?? 'Could not confirm in the chat view');
    await _say('I pressed Send in ${result.chatTitle ?? 'the chat'}, ${settings.address}, but I couldn\'t confirm the message in the chat view. Please check.',
        kind: 'command');
    return 'Send pressed, not verified';
  }

  // ---- runner: delete all history (approval-gated, local)
  Future<String?> _runForgetAll(TaskTracker tr) async {
    if (tr.stepStatus('approval') == null) {
      tr.addStep(const TaskStep(id: 'approval', description: 'Get your approval'));
      tr.addStep(const TaskStep(id: 'delete', description: 'Delete conversations, tasks and remembered facts', irreversible: true));
    }
    final reply = await _askApproval(
        tr,
        ApprovalRequest(id: 'forget-${tr.snapshot.id}', actionType: 'memory.delete_all', title: 'Delete all memory',
            content: 'All conversations, task history and remembered facts'),
        'This will permanently delete all conversations, task history and remembered facts, ${settings.address}. Shall I proceed?');
    if (reply.answer != _ApprovalAnswer.approve || !approvals.consume('memory.delete_all', null, 'All conversations, task history and remembered facts')) {
      tr.cancelRemaining();
      tr.setState(AgentState.cancelled, result: 'Kept memory');
      if (identical(_tracker, tr)) _tracker = null;
      await _say('Understood. I\'ve kept everything.');
      return null;
    }
    tr.updateStep('approval', status: StepStatus.done);
    tr.setState(AgentState.running);
    tr.updateStep('delete', status: StepStatus.running);
    await wipeAllData();
    tr.updateStep('delete', status: StepStatus.done);
    _tracker = null;
    await _say('Done, ${settings.address}. Everything I stored has been deleted, and the keys that protected it were destroyed.');
    return 'Deleted';
  }

  /// Deletes everything LEO stored about the user (conversations, tasks, facts, learned phrases,
  /// privacy ledger, usage, screen-agent hints) and destroys the encryption keys (crypto-shredding).
  Future<void> wipeAllData() async {
    await memory.deleteEverything();
    await ScreenAgent.clearHints();
    classifier.train();
    sessionId = await memory.resumeOrStartSession();
    messages = [];
    previousSessionTail = [];
    task = null;
    notifyListeners();
  }

  // ---- runner: knowledge (AI)
  Future<String?> _runKnowledge(TaskTracker tr) async {
    final q = tr.snapshot.params['text'] as String;
    if (tr.stepStatus('context') == null) {
      tr.addStep(const TaskStep(id: 'context', description: 'Retrieve relevant memory (local)'));
      tr.addStep(const TaskStep(id: 'ai', description: 'Ask OpenAI'));
    }
    if (!ai.isConfigured) throw AiNotConfigured();
    final ctx = await tr.step('context', () => contextBuilder.build(sessionId: sessionId, query: q));
    tr.updateStep('context', detail: ctx == null || ctx.isEmpty ? 'No context needed' : ctx.sources.join(', '));
    final answer = await tr.step('ai', () => ai.answer(q, ctx?.text ?? ''));
    if (answer == null) return null;
    await _say(answer, route: 'ai', kind: 'knowledge');
    return 'Answered';
  }

  // ---- runner: writing (AI) — produces a draft for review, never sends
  Future<String?> _runWrite(TaskTracker tr) async {
    final q = tr.snapshot.params['text'] as String;
    final kind = WritingKind.values.byName(tr.snapshot.params['writeKind'] as String);
    if (tr.stepStatus('context') == null) {
      tr.addStep(const TaskStep(id: 'context', description: 'Retrieve relevant memory (local)'));
      tr.addStep(const TaskStep(id: 'ai', description: 'Draft with OpenAI'));
    }
    if (!ai.isConfigured) throw AiNotConfigured();
    final ctx = await tr.step('context', () => contextBuilder.build(sessionId: sessionId, query: q, includeRecent: kind == WritingKind.rewrite));
    final d = await tr.step('ai', () => ai.write(kind, q, ctx?.text ?? ''));
    if (d == null) return null;
    _presentDraft(d);
    return 'Draft ready for review';
  }

  void _presentDraft(AiDraft d) {
    draft = Draft(d.kind, d.subject, d.content);
    notifyListeners();
    final a = settings.address;
    final line = switch (d.kind) {
      WritingKind.email => '$a, I\'ve prepared your email. Would you like to review or send it?',
      WritingKind.message => 'I\'ve drafted the message, $a. It\'s on screen for your review.',
      WritingKind.rewrite => 'Here\'s the improved version, $a. It\'s on screen.',
      _ => 'The draft is ready for your review, $a.',
    };
    unawaited(_say(line, route: 'ai', kind: 'write', extraStoredText: '\n\n${d.subject != null ? 'Subject: ${d.subject}\n\n' : ''}${d.content}'));
  }

  void dismissDraft() {
    draft = null;
    notifyListeners();
  }

  Future<void> emailDraft() async {
    final d = draft;
    if (d == null) return;
    final ok = await device.composeEmail(d.subject, d.content);
    if (!ok) _setBanner('No email app could open the draft.');
  }

  // ---- runner: AI fallback understanding → validated structured proposal
  Future<String?> _runAiRoute(TaskTracker tr) async {
    final q = tr.snapshot.params['text'] as String;
    if (tr.stepStatus('context') == null) {
      tr.addStep(const TaskStep(id: 'context', description: 'Retrieve relevant memory (local)'));
      tr.addStep(const TaskStep(id: 'ai', description: 'Understand request with OpenAI'));
    }
    if (!ai.isConfigured) throw AiNotConfigured();
    final ctx = await tr.step('context', () => contextBuilder.build(sessionId: sessionId, query: q));
    final installed = (await apps.apps()).map((a) => a.label).toList();
    final proposal = await tr.step('ai', () => ai.route(q, ctx?.text ?? '', installed));
    switch (proposal) {
      case AiAnswer(:final text):
        await _say(text, route: 'ai', kind: 'conversation');
        return 'Answered';
      case AiOperatePhone(:final goal):
        tr.addStep(TaskStep(id: 'handoff', description: 'Hand off to the screen agent: $goal'));
        tr.updateStep('handoff', status: StepStatus.done);
        tr.setState(AgentState.completed, result: 'Handed off');
        _tracker = null;
        _startTask(_titleFrom(goal), 'agent', TaskRoute.ai, {'goal': goal});
        return null;
      case AiClarify(:final question):
        await _say(question, route: 'ai', kind: 'question');
        return 'Asked for clarification';
      case AiDraft():
        _presentDraft(proposal);
        return 'Draft ready for review';
      case AiOpenApp(:final app):
        tr.addStep(TaskStep(id: 'handoff', description: 'Hand off to local executor: open "$app"'));
        tr.updateStep('handoff', status: StepStatus.done);
        tr.setState(AgentState.completed, result: 'Handed off');
        _tracker = null;
        _startTask('Open $app', 'open_app', TaskRoute.ai, {'query': app});
        return null;
      case AiSendMessage():
        tr.addStep(TaskStep(id: 'handoff', description: 'Hand off to local executor: message ${proposal.recipient}'));
        tr.updateStep('handoff', status: StepStatus.done);
        tr.setState(AgentState.completed, result: 'Handed off');
        _tracker = null;
        _startTask('Send ${proposal.app.displayName} message to ${proposal.recipient}', 'whatsapp_send', TaskRoute.ai, {
          'app': proposal.app.name,
          'recipient': proposal.recipient,
          'isGroup': proposal.isGroup,
          'message': proposal.message,
        });
        return null;
      case null:
        return null;
    }
  }

  // ------------------------------------------------------------------ speaking & storage
  // ------------------------------------------------------------------ cloud understanding (OpenAI brain)
  /// Multi-step ("…then…", "phir", "uske baad"), mixed Hindi/Kannada, or long requests.
  static bool looksComplex(String t) {
    final s = t.toLowerCase();
    if (RegExp(r'\b(then|after that|and also|also|first|next|phir|fir|pehle|uske baad|aur|baad mein|nantara|amele|matte|mele)\b').hasMatch(s)) {
      return true;
    }
    if (RegExp(r'\b(karo|kar do|kardo|khol|bata|chala|bajao|bhej|lagao|band|maadi|haaku|helu|kodi|beku|yaar|bhai|mujhe|mera|meri|nanna|nange)\b').hasMatch(s)) {
      return true;
    }
    return s.split(RegExp(r'\s+')).length > 9;
  }

  /// LEO's brain is OpenAI (Sarvam is voice only). null = cloud understanding off or no key.
  String? get _cloudProvider =>
      settings.sarvamUnderstanding && settings.hasSecret(SecretKey.openai) ? 'openai' : null;

  bool get _sarvamReady => _cloudProvider != null;

  /// Sends what the user said (personal data masked, plus the NAME of the app on screen and a few
  /// recent turns) to the cloud model, which rewrites it into plain LEO commands / a short answer /
  /// a clarifying question. Every call is written to the privacy ledger. Returns false to fall back.
  Future<bool> _understandWithSarvam(String raw, String source) async {
    final provider = _cloudProvider;
    if (provider == null) return false;
    String? screenApp;
    try {
      if (!await device.uiVisible() || assistMode) {
        final d = await device.screenDump(max: 4, skipOwn: true);
        final pkg = d['package'] as String?;
        // Only the app's name is shared — never what's on the screen; nothing at all for banking/payment apps.
        if (pkg != null && !await device.isBlockedApp(pkg)) {
          screenApp = (await apps.apps()).where((x) => x.packageName == pkg).map((x) => x.label).firstOrNull;
        }
      }
    } catch (_) {}
    final recent = [
      for (final m in messages.length > 4 ? messages.sublist(messages.length - 4) : messages)
        '${m.role == 'user' ? 'User' : 'LEO'}: '
            '${_privateKinds.contains(m.kind) ? '[private content hidden]' : (m.text.length > 120 ? m.text.substring(0, 120) : m.text)}'
    ];
    // Mask personal identifiers in ONE pass so the same value gets the same placeholder everywhere.
    const sep = '\n<<<NOW>>>\n';
    final red = PrivacyFilter.redact('${recent.join('\n')}$sep$raw');
    final parts = red.text.split(sep);
    final safeRecent = parts.first.isEmpty ? <String>[] : parts.first.split('\n');
    final safeUtterance = parts.length > 1 ? parts.last : red.text;

    Interpretation? r;
    String? error;
    try {
      r = await openAiBrain.interpret(
          apiKey: settings.secret(SecretKey.openai)!, model: settings.openAiModel,
          utterance: safeUtterance, screenApp: screenApp, recentTurns: safeRecent);
    } catch (e) {
      error = '$e';
      debugPrint('LEO cloud-understand ($provider) failed: $e');
    }
    final model = settings.openAiModel;
    final cost = r?.cost;
    unawaited(memory.logCloud(
        provider: provider, model: model, purpose: 'understand',
        sentText: '${screenApp == null ? '' : '[app: $screenApp] '}$safeUtterance', maskedCount: red.count,
        input: r?.inputTokens, output: r?.outputTokens, cached: r?.cachedTokens,
        cost: cost?.amount, currency: cost?.currency, latencyMs: r?.latencyMs, ok: r != null && error == null));
    unawaited(memory.logTokenUsage(
        provider: provider, model: model, purpose: 'understand',
        input: r?.inputTokens, output: r?.outputTokens, total: r?.totalTokens, reported: r?.inputTokens != null, ok: r != null));
    if (r == null || r.isEmpty) return false;
    // Put the masked values back — on the phone, never in the cloud.
    final res = r.copyWith(
      commands: [for (final c in r.commands) red.restore(c)],
      answer: r.answer == null ? null : red.restore(r.answer!),
      clarify: r.clarify == null ? null : red.restore(r.clarify!),
    );
    debugPrint('LEO cloud-understand ($provider): ${res.commands.length} step(s), answer=${res.answer != null}'); // no content
    await _store('user', raw, source: source, kind: 'conversation', route: provider);
    if (res.commands.isEmpty) {
      // Token counts stay in Analytics only (not shown in the conversation).
      await _say(res.clarify ?? res.answer!, route: provider, kind: res.clarify != null ? 'question' : 'answer');
      return true;
    }
    // Show the plan + its cost once (no spoken words: LEO reports each step as it happens).
    final planText = res.commands.map((c) => c.startsWith('on the phone:') ? c.substring(13).trim() : c).join('  →  ');
    await _store('jarvis', 'Plan: $planText', route: provider, kind: 'plan');
    // Run the commands in order through the normal engine (all rules & approvals apply). The first
    // starts now; the rest wait for each task to finish, so the voice loop stays free for answers.
    await handleInput(res.commands.first, source: 'sarvam');
    final t = _tracker;
    if (t != null && t.snapshot.state.isActive) {
      t.addStep(TaskStep(
          id: 'cloud',
          description: 'Understood by OpenAI'
              '${res.commands.length > 1 ? ' (${res.commands.length} steps)' : ''}',
          status: StepStatus.done,
          detail: red.count > 0 ? '${red.count} private item${red.count == 1 ? '' : 's'} masked' : null));
    }
    if (res.commands.length > 1) unawaited(_runCommandChain(res.commands.sublist(1)));
    return true;
  }

  int _chainId = 0;
  Future<void> _runCommandChain(List<String> rest) async {
    final id = ++_chainId;
    for (final c in rest) {
      if (!await _waitTaskIdle() || id != _chainId) return;
      if (task?.state == AgentState.failed || task?.state == AgentState.cancelled) return; // don't plough on after a failure
      await handleInput(c, source: 'sarvam');
    }
  }

  /// Waits (max 3 min) until no task is running or waiting on the user. False if stopped meanwhile.
  Future<bool> _waitTaskIdle() async {
    final end = DateTime.now().add(const Duration(minutes: 3));
    await Future<void>.delayed(const Duration(milliseconds: 400));
    while (DateTime.now().isBefore(end)) {
      final busy = (task?.state.isActive ?? false) || approvals.pending != null || choice != null || _freeTextWait != null;
      if (!busy) return true;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return false;
  }

  Future<void> _store(String role, String text, {String? source, String? route, String? kind}) async {
    final m = await memory.addMessage(sessionId: sessionId, role: role, text: text, source: source, route: route, kind: kind);
    messages = [...messages, m];
    notifyListeners();
  }

  /// Kinds whose text quotes people's messages, chats or screen contents.
  static const _privateKinds = {'screen', 'approval', 'reminder', 'messages', 'private'};

  /// Private = quotes messages/chats/screen, or contains a phone number, OTP, email, ID…
  static bool isPrivateSpeech(String text, String? kind) =>
      _privateKinds.contains(kind) || PrivacyFilter.redact(text).secrets.keys.any((k) => !k.startsWith('<QUOTE'));

  Future<void> _say(String text,
      {bool store = true, String route = 'local', String? kind, String extraStoredText = '', bool private = false}) async {
    if (store) await _store('jarvis', '$text$extraStoredText', route: route, kind: kind);
    if (settings.speakResponses) {
      await speechOut.speak(text, private: private || isPrivateSpeech(text, kind));
      if (speechOut.lastError != null && speechOut.lastEngine == 'device') {
        banner ??= speechOut.lastError;
      }
    }
  }

  // ------------------------------------------------------------------ history helpers
  Future<void> reloadSession() async {
    messages = await memory.messagesOf(sessionId, limit: 200);
    notifyListeners();
  }

  static String _ordinal(int i) => const ['First', 'Second', 'Third', 'Fourth', 'Fifth', 'Sixth'][i.clamp(0, 5)];
  static String _weekday(DateTime d) => const ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'][d.weekday - 1];
  static String _month(DateTime d) => const [
        'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'
      ][d.month - 1];
  static String _shortDate(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'today';
    if (diff == 1) return 'yesterday';
    return '${d.day} ${_month(d)}';
  }

  @override
  void dispose() {
    _eventsSub?.cancel();
    super.dispose();
  }
}

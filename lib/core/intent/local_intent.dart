/// Everything the local engine understands without any cloud call.
library;

enum MessagingApp {
  whatsapp('com.whatsapp', 'WhatsApp'),
  whatsappBusiness('com.whatsapp.w4b', 'WhatsApp Business');

  final String packageName;
  final String displayName;
  const MessagingApp(this.packageName, this.displayName);
}

enum WritingKind { email, message, document, rewrite, generic }

sealed class LocalIntent {
  const LocalIntent();

  /// True when fulfilling this intent needs the AI service.
  bool get requiresAi => false;
}

// ---- Interrupt / control: handled by the local interrupt controller, never by AI ----
class StopIntent extends LocalIntent {
  const StopIntent();
}

class StopEverythingIntent extends LocalIntent {
  const StopEverythingIntent();
}

class PauseIntent extends LocalIntent {
  const PauseIntent();
}

class ResumeIntent extends LocalIntent {
  const ResumeIntent();
}

class CancelTaskIntent extends LocalIntent {
  const CancelTaskIntent();
}

class StatusIntent extends LocalIntent {
  const StatusIntent();
}

class ContinueWhereStoppedIntent extends LocalIntent {
  const ContinueWhereStoppedIntent();
}

class StopListeningIntent extends LocalIntent {
  const StopListeningIntent();
}

// ---- Approval / clarification answers ----
class ApproveIntent extends LocalIntent {
  const ApproveIntent();
}

class RejectIntent extends LocalIntent {
  const RejectIntent();
}

class EditMessageIntent extends LocalIntent {
  final String newText;
  const EditMessageIntent(this.newText);
}

class ChooseOptionIntent extends LocalIntent {
  final int index; // 0-based
  const ChooseOptionIntent(this.index);
}

// ---- Device actions ----
class OpenAppIntent extends LocalIntent {
  final String appName;
  const OpenAppIntent(this.appName);
}

class SendMessageIntent extends LocalIntent {
  final MessagingApp app;
  final String recipient;

  /// Exact text the user dictated. Null when the user did not say what to send.
  final String? message;

  /// When set, the user asked LEO to compose the message about this topic (AI writer).
  final String? composeTopic;
  final bool isGroup;

  /// The user asked for a well-written message (explain, polite, detailed…): OpenAI writes a fuller
  /// message from [composeTopic] (the user's whole request) instead of a one-liner.
  final bool composeLong;

  const SendMessageIntent({
    required this.app,
    required this.recipient,
    this.message,
    this.composeTopic,
    required this.isGroup,
    this.composeLong = false,
  });

  @override
  bool get requiresAi => message == null && composeTopic != null;
}

// ---- Local information & memory ----
class TellTimeIntent extends LocalIntent {
  const TellTimeIntent();
}

class TellDateIntent extends LocalIntent {
  const TellDateIntent();
}

class GreetingIntent extends LocalIntent {
  const GreetingIntent();
}

class HowAreYouIntent extends LocalIntent {
  const HowAreYouIntent();
}

class ThanksIntent extends LocalIntent {
  const ThanksIntent();
}

class RememberIntent extends LocalIntent {
  final String fact;
  const RememberIntent(this.fact);
}

class RecallIntent extends LocalIntent {
  final String? topic;
  const RecallIntent(this.topic);
}

class ContinuePreviousWorkIntent extends LocalIntent {
  const ContinuePreviousWorkIntent();
}

class ContextStatementIntent extends LocalIntent {
  final String statement;
  const ContextStatementIntent(this.statement);
}

class ForgetEverythingIntent extends LocalIntent {
  const ForgetEverythingIntent();
}

// ---- Needs the AI service ----
class WriteIntent extends LocalIntent {
  final WritingKind kind;
  final String request;
  const WriteIntent(this.kind, this.request);
  @override
  bool get requiresAi => true;
}

class KnowledgeIntent extends LocalIntent {
  final String question;
  const KnowledgeIntent(this.question);
  @override
  bool get requiresAi => true;
}

/// Local engine could not understand — route to the AI fallback (which may return a structured action).
class UnknownIntent extends LocalIntent {
  final String text;
  const UnknownIntent(this.text);
  @override
  bool get requiresAi => true;
}

// ---- Everyday phone tasks: always local, never AI ----
enum MediaApp { youtube, youtubeMusic, spotify }

class PlayMediaIntent extends LocalIntent {
  final String query;
  final MediaApp app;
  const PlayMediaIntent(this.query, this.app);
}

class CallIntent extends LocalIntent {
  final String name;
  const CallIntent(this.name);
}

class CheckMessagesIntent extends LocalIntent {
  final bool whatsapp;
  final bool email;
  const CheckMessagesIntent({required this.whatsapp, required this.email});
}

enum MediaAction { pause, play, next, previous, volumeUp, volumeDown, mute }

/// Controls whatever app is currently playing (YouTube, Spotify, …) — local, no AI.
class MediaControlIntent extends LocalIntent {
  final MediaAction action;
  const MediaControlIntent(this.action);
}

/// "Sign in to YouTube Music" — opens the app and walks through sign-in with the user's consent.
class SignInIntent extends LocalIntent {
  final String appName;
  /// 'google' | 'phone' | 'email' when the user said how ("with my phone number").
  final String? method;
  const SignInIntent(this.appName, {this.method});
}

// ---- Everyday phone actions (local, no AI)
class SetAlarmIntent extends LocalIntent {
  final String text; // full utterance — parsed by TimeParser
  final String? label;
  const SetAlarmIntent(this.text, {this.label});
}

class SetTimerIntent extends LocalIntent {
  final Duration length;
  final String? label;
  const SetTimerIntent(this.length, {this.label});
}

class ScheduleMeetingIntent extends LocalIntent {
  final String text; // parsed by TimeParser for the start time
  final String? title;
  final List<String> attendees;
  final bool googleMeet;
  final Duration? length;
  const ScheduleMeetingIntent(this.text, {this.title, this.attendees = const [], this.googleMeet = false, this.length});
}

class StartMeetIntent extends LocalIntent {
  const StartMeetIntent();
}

class NavigateIntent extends LocalIntent {
  final String place;
  const NavigateIntent(this.place);
}

class WebSearchIntent extends LocalIntent {
  final String query;
  const WebSearchIntent(this.query);
}

class FlashlightIntent extends LocalIntent {
  final bool on;
  const FlashlightIntent(this.on);
}

class CameraIntent extends LocalIntent {
  final bool selfie;
  final bool video;
  const CameraIntent({this.selfie = false, this.video = false});
}

/// Wi-Fi / Bluetooth / data etc. Android doesn't allow apps to toggle these, so LEO opens the panel.
class SettingsPanelIntent extends LocalIntent {
  final String kind;
  final bool? on;
  const SettingsPanelIntent(this.kind, {this.on});
}

/// Reply to someone who messaged you, through the chat notification's reply box (local).
class ReplyIntent extends LocalIntent {
  final String who;
  final String? message;
  const ReplyIntent(this.who, {this.message});
}

/// Anything else on the phone: handled by the screen agent (needs AI to plan the steps).
class PhoneTaskIntent extends LocalIntent {
  final String goal;
  const PhoneTaskIntent(this.goal);
  @override
  bool get requiresAi => true;
}

// ---- Round 3: alarms, reminders, calls, files, web, installs, shopping, screen context
class DismissAlarmIntent extends LocalIntent {
  final String text; // "next" | "all" | a time phrase
  final bool all;
  const DismissAlarmIntent(this.text, {this.all = false});
}

class SnoozeAlarmIntent extends LocalIntent {
  final int? minutes;
  const SnoozeAlarmIntent({this.minutes});
}

class ListRemindersIntent extends LocalIntent {
  const ListRemindersIntent();
}

class DeleteReminderIntent extends LocalIntent {
  final String? about; // null + all=true → delete all
  final bool all;
  const DeleteReminderIntent({this.about, this.all = false});
}

enum CallAction { answer, end, reject }

class CallControlIntent extends LocalIntent {
  final CallAction action;
  const CallControlIntent(this.action);
}

class FindFileIntent extends LocalIntent {
  final String query;
  final List<String> exts;
  final bool open;
  const FindFileIntent(this.query, {this.exts = const ['pdf'], this.open = true});
}

class OpenWebsiteIntent extends LocalIntent {
  final String site; // domain or name
  final String? then; // optional follow-up ("and search for laptops")
  const OpenWebsiteIntent(this.site, {this.then});
}

class InstallAppIntent extends LocalIntent {
  final String app;
  const InstallAppIntent(this.app);
}

class ShopIntent extends LocalIntent {
  final String query;
  final String store; // amazon | flipkart
  final bool addToCart;
  final bool compare;
  const ShopIntent(this.query, {this.store = 'amazon', this.addToCart = false, this.compare = true});
}

enum ScreenCommand { scrollDown, scrollUp, back, home, read, tap, type }

/// Acts on whatever app is on screen right now ("read this", "scroll down", "tap Archive").
class ScreenCommandIntent extends LocalIntent {
  final ScreenCommand command;
  final String? arg;
  const ScreenCommandIntent(this.command, {this.arg});
}

/// "read my chat with Rahul" — open the WhatsApp chat and read the latest messages aloud.
/// "ask it to prepare a PPT about blood" / "ask Claude to …" / "tell ChatGPT …": type the request into
/// the app on screen (or the named AI app) and send it. Never used for messaging apps.
class AskAppIntent extends LocalIntent {
  final String prompt;
  final String? app; // null = the app on screen
  const AskAppIntent(this.prompt, {this.app});
}

/// "compose a new email to x@gmail.com saying hi" / "email Rahul about tomorrow's leave".
/// [body] given → sent word for word (no AI). Only [topic] → the brain writes it. Always needs approval.
class EmailIntent extends LocalIntent {
  final String to; // an address, or a contact name to look up
  final String? subject;
  final String? body;
  final String? topic;
  const EmailIntent(this.to, {this.subject, this.body, this.topic});

  /// No exact text given → the brain writes it.
  @override
  bool get requiresAi => body == null;
}

class ReadChatIntent extends LocalIntent {
  final String who;
  const ReadChatIntent(this.who);
}

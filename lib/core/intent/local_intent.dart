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

  const SendMessageIntent({
    required this.app,
    required this.recipient,
    this.message,
    this.composeTopic,
    required this.isGroup,
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
  const SignInIntent(this.appName);
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

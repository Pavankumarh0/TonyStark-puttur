# JARVIS — personal AI device assistant (Phase 1, Android)

JARVIS listens for **"Jarvis"**, understands what you ask, does everyday phone tasks **locally**,
uses AI only for writing and knowledge, remembers your conversations, and always keeps you in control
(STOP / PAUSE / approvals).

Built with **Flutter** (Dart) + native Android (Kotlin) for the parts Android only exposes natively.

## What runs where

| Capability | How | Cloud? |
|---|---|---|
| Wake word "Jarvis" | sherpa-onnx keyword spotter (Apache-2.0), bundled model | **No** — on-device |
| Speech → text | Sarvam Saaras v4 (`en-IN`), only after the wake word / mic tap | Sarvam |
| Voice replies | Sarvam Bulbul (phone's offline TTS as fallback) | Sarvam |
| Open apps, play music/YouTube, call contacts, check WhatsApp/email notifications, time/date, STOP/PAUSE/RESUME/CANCEL/STATUS | Rule engine → **on-device trained intent model** → native executor | **No AI** |
| Write emails/messages/documents, general questions, unclear requests | Gemini (with small, relevant memory snippets only) | Gemini |
| WhatsApp send | Contacts lookup → **approval bound to exact recipient + text** → accessibility tap → verify in chat | No AI |
| Memory | SQLite + FTS4 on the phone | No |

The on-device intent model (Naive Bayes over word/char n-grams) trains on the phone at startup and
**learns from every successfully executed command** — including requests that once needed Gemini —
so they run locally the next time.

## Build

1. Put keys in `lib/.env` (gitignored, never committed):
   ```
   GEMINI_API_KEY=...
   SARVAM_API_KEY=...
   PICOVOICE_ACCESS_KEY=...   # optional
   GEMINI_MODEL=gemini-2.5-flash   # optional
   ```
2. Connect the phone (USB debugging) and run:
   ```powershell
   .\scripts\build_apk.ps1
   ```
   This compiles the keys into the APK, installs it and starts JARVIS.
   ⚠️ Keys inside an APK can be extracted — don't share the APK publicly.

## One-time phone setup (all inside JARVIS → Settings → Permissions)

- Microphone, notifications, contacts, phone.
- **Allow restricted settings** (sideloaded apps on Android 13+): App info → ⋮ → Allow restricted settings.
- Accessibility service "JARVIS device control" (WhatsApp send, YouTube auto-play).
- Notification access "JARVIS message reader" (check new messages/emails).
- Battery: Unrestricted (Samsung: not in Sleeping apps).
- **Digital assistant**: Settings → Apps → Choose default apps → Digital assistant app → JARVIS.
  Then long-press the side key opens the half-screen JARVIS panel.

## Honest limitations

- Wake word works while the "JARVIS is listening" notification is showing; not after force-stop or
  reboot until you open the app once (Android blocks starting microphone services at boot).
- WhatsApp/YouTube UI automation depends on those apps' screens and can break after their updates;
  JARVIS reports failures instead of claiming success.
- "Check messages" reads what is currently in your notifications (it cannot open chats you've already cleared).

## Tests

```
flutter test
```

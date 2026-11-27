# LEO — data privacy, security and cost

**Providers:** Sarvam = voice only (speech-to-text, LEO's voice). OpenAI = the brain (understanding free-form requests, answers, writing). Everything else runs on the phone.

LEO is a voice assistant that can operate the phone, so it sees personal things: who you call, your messages, what is on your screen. The design rule is **do it on the phone first, send as little as possible, show the user everything that leaves, and never act on another person without the user's OK.**

## 1. What stays on the phone (never sent anywhere)

| Data | Where it lives |
|---|---|
| Wake word ("Leo") | Detected on-device by sherpa-onnx. The mic audio is processed in memory and not stored. |
| Everyday commands: open apps, call, music, alarms, reminders, toggles, files, WhatsApp, clicking buttons, scrolling | Rule engine plus a small on-device classifier. **0 tokens, no network.** |
| Screen contents read by the accessibility service | Used on the phone to find buttons and read text aloud. Never uploaded. |
| Contacts, messages, notifications, files | Read on the phone. Never uploaded. |
| Conversation history, memory, tasks, privacy ledger | Local SQLite in LEO's private app storage. App backups are turned off (`allowBackup=false`), so it isn't copied to Google Drive or extracted over adb. |
| API keys | Compiled in for the demo. Keys typed into Settings are kept in Android's encrypted secure storage (Keystore). Not in Git (`lib/.env` is git-ignored). |
| Optional on-device "brain" (Qwen 1.5B) | Runs fully offline for screen tasks. |

## 2. What leaves the phone, and how it's protected

| Goes to | When | What exactly | Protection |
|---|---|---|---|
| **Sarvam** speech-to-text | Only after "Leo" or a mic tap | The audio of that one request | HTTPS only (cleartext traffic is blocked app-wide) |
| **Sarvam** text-to-speech | Whenever LEO speaks | LEO's reply text (including read-outs of messages) | HTTPS |
| **OpenAI** (LEO's brain: understanding, answers, writing) | Only when on-device rules can't place a request, or for a general question | The request text, **with personal data masked**, plus the app's *name* (never its contents) and the last 4 turns, also masked | Masking, `store:false`, a ledger of every call, no screen contents |

**Masking (`lib/core/privacy_filter.dart`).** Before anything is sent, the phone replaces these with placeholders:
- phone numbers
- emails
- UPI IDs
- OTPs and PINs
- passwords ("password is …")
- card numbers
- Aadhaar, PAN and IFSC
- bank account numbers

For example, `send my OTP 482913 to 98450 12345` is sent as `send my OTP <OTP_1> to <PHONE_1>`. The model copies the placeholders, and the phone puts the real values back locally. Measured on the real API: the cloud never saw the number or the code.

**Privacy ledger (Analytics tab).** Every cloud request is listed with:
- the exact text that was sent (after masking);
- the provider and model;
- tokens, cost and latency;
- how many items were masked.

The user can clear it.

**No screen contents for banking or payment apps.** Those apps are on a blocklist. LEO won't read or operate them, and doesn't even send their names.

## 2a. A WhatsApp message, step by step ("Leo, send hi to Rahul on WhatsApp")

| Step | Where it happens | Does the message text go anywhere? |
|---|---|---|
| Hearing "Leo" | Phone (sherpa-onnx) | No |
| Turning your voice into text | Sarvam speech-to-text, over HTTPS | **Yes, your voice audio for this one request.** It is the only place the words travel. Nothing is stored by LEO outside the phone. |
| Understanding "send … saying hi" | Phone rule engine | No. If a cloud model is needed, the body is masked as `<MESSAGE_1>` first. |
| Finding Rahul in contacts | Phone | No |
| "I've prepared: 'hi' for Rahul. Shall I send?" | Sarvam voice, over HTTPS | The confirmation text, to Sarvam only |
| Your "yes" | Phone; approval bound to this exact text and recipient | No |
| Sending | **WhatsApp itself**, end-to-end encrypted. LEO only presses Send. | Only to Rahul, via WhatsApp's encryption |
| Reading Rahul's reply aloud | Phone reads the notification; Sarvam voice speaks it | The reply text, to Sarvam only |

LEO has **no server and no cloud database**. "Uses the internet" means three narrow, encrypted calls to named providers, each with a published retention policy. It never means publishing data on the web. Chats are never uploaded, synced or used to train anything.

To remove even the voice step, the next improvement is on-device speech recognition (Android's offline recogniser), so dictated messages never leave the phone.

## 3. Safety of actions (human in the loop)

- **Approval bound to the exact action.** Anything that reaches another person or moves money needs an explicit "yes": send, share, post, pay, buy, order, install, delete, call, video call, join, follow, sign out. The approval shows the exact message and recipient, and is fingerprinted, so an approval for one message can't be reused for a changed one.
- **WhatsApp** always shows the exact text and recipient first. LEO never types into messaging apps through the general "ask it to …" path.
- **Passwords are never typed** by LEO. OTPs are read from SMS only after the user says yes.
- **STOP / PAUSE / CANCEL** are handled on the phone, instantly, at any step.
- **The screen agent shows every step** on an overlay and in the task list. It can't loop forever (18-step cap plus a repeat guard).
- Optional **"Hide LEO from screenshots & recording"** (`FLAG_SECURE`) stops other apps and screen recorders capturing conversations.

## 4. Provider data policies (as published, 27 Nov 2026)

- **OpenAI API:** API data is not used for training by default. Inputs and outputs may be kept up to 30 days for abuse monitoring, then deleted. LEO sends `store: false`. Zero Data Retention exists but needs OpenAI's approval, so it isn't enabled for this prototype.
- **Sarvam:** used for voice only (Indian-language speech-to-text and LEO's voice). Check Sarvam's current terms for its retention period before production use.

## 5. Speed and tokens

| Step | Where | Typical time | Tokens |
|---|---|---|---|
| Everyday command (≈ most requests) | Phone | < 100 ms after transcription | 0 |
| Understanding a free-form request | OpenAI `gpt-4o-mini` | ~0.3–0.6 s (same prompt measured at 0.26–0.5 s) | ~735 in (mostly cached) + ~15–20 out |
| Speech-to-text / text-to-speech | Sarvam | ~1 s each | billed per second / character, not tokens |

How tokens are kept low:
- **On-device first.** Only requests the phone can't handle reach a model.
- **One fixed system prompt, always sent first.** Providers cache it automatically (on our test, 640–704 of ~735 prompt tokens were cache hits).
- **Strict JSON with one field.** That cut the output from 39–53 tokens to 15–18 per request (output is the most expensive token).
- **Only the last 4 turns**, 120 characters each, and the app *name* rather than its contents.

Each task shows its own usage, e.g. "Understood by OpenAI · 752 tokens · $0.00008 · 0.4 s". The Analytics tab totals it.

**Budget: $5 of OpenAI credit.** With `gpt-4o-mini` ($0.15 per 1M input, $0.075 per 1M cached input, $0.60 per 1M output):
- one free-form request ≈ $0.00008–0.00013;
- **$5 ≈ 38,000–60,000 understood requests.**

A full day of demo testing (a few hundred requests) costs a few cents. Everyday commands cost nothing.

## 6. Known gaps (honest list)

- Speech audio goes to Sarvam for transcription. An on-device speech-to-text model would remove that.
- Contact *names* are sent when they're part of a free-form request (numbers are masked). Mapping names to local IDs would close this.
- The local database relies on Android's app sandbox and file-based encryption. It isn't separately encrypted with SQLCipher.
- Demo API keys are compiled into the APK, so a determined person could extract them. For production, route calls through a small backend that holds the keys, and set spend limits on the provider dashboards.
- OpenAI keeps request data for up to 30 days for abuse monitoring unless Zero Data Retention is approved.

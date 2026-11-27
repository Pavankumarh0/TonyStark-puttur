# LEO Desktop — Architecture & Implementation Plan

Status: **Phase 1 (inspection + plan)**. No desktop code yet. The Android app (`lib/`, `android/`) is not
modified by any desktop phase.

## 1. What exists today (inspected 2026-11-28)

### Reusable from the Android app (pure Dart, no Android/Flutter-plugin dependencies)
| File | Lines | Reuse on desktop |
|---|---|---|
| `lib/core/approval/approval_gate.dart` | 108 | As-is: approval bound to exact action + target + content, single use, mismatch voids it |
| `lib/core/privacy_filter.dart` | 70 | As-is: masks phone/email/OTP/card/Aadhaar/PAN/secrets before anything leaves the machine |
| `lib/core/task/task_models.dart`, `task_runner.dart` | 390 | As-is: task states, steps, STOP/PAUSE/RESUME/CANCEL checkpoint |
| `lib/core/intent/local_intent_engine.dart`, `local_classifier.dart`, `local_intent.dart` | 1,361 | Pattern reused; desktop needs its own intent set (git/code/project commands) |
| `lib/core/time_parser.dart`, `greeting.dart` | 271 | As-is |
| `lib/agent/tools.dart` | 46 | As-is: tool/registry interface for model tool-calling |
| `lib/ai/openai_brain.dart` (tool-calling client) | 221 | Optional cloud fallback only (consent-gated) |
| Vault design (`android/.../Vault.kt`, `lib/data/vault.dart`) | — | Same scheme re-implemented for Windows (DPAPI instead of Keystore) |

### Not reusable (Android-bound)
`jarvis_orchestrator.dart` (3,511 lines, mixes Android UI/permissions/accessibility), `screen_agent.dart`,
`device_bridge.dart`, voice stack (Porcupine/Android mic), all `lib/ui/*`.

### This PC
| Item | Found |
|---|---|
| OS | Windows 11 25H2 |
| Flutter | 3.47.9, Visual Studio Build Tools 2022 (Windows desktop builds work; `enable-windows-desktop` not yet set) |
| Qwen | Ollama 0.40.18 with `qwen2.5:1.5b` (also `gemma3:1b`) |
| GPU / RAM | RTX 3050 Laptop 4 GB VRAM / 15.7 GB RAM → `qwen2.5:3b` fits fully in VRAM; `7b` would split CPU/GPU (slower) |
| Claude Code | 2.1.332 at `~\.local\bin\claude.exe` |
| VS Code | installed (`code` CLI on PATH) |
| Git | 2.52 (no `gh`) |
| PlatformIO | Core 6.2.0, espressif32 platform installed |
| ESP32 | **COM9**, CP210x bridge, ESP32-D0WD-V3 rev 3.1, dual-core 240 MHz, 4 MB flash |
| TFT | **unknown — needed before Phase 5** (controller, touch type, resolution, wiring) |
| Projects | 35 folders in `Documents\projects`, 26 are git repos (incl. `nocom`, `kadamly`) |

## 2. Architecture

```
 ┌──────────────── LEO Desktop UI (Flutter Windows) ───────────────┐
 │ project · git dashboard · approvals · tasks · agents · monitor  │
 └───────────────▲─────────────────────────────────────────────────┘
                 │ local WebSocket 127.0.0.1 + per-session token (JSON-RPC)
 ┌───────────────┴──────────── LEO Agent Service (Dart, headless) ─────────────────────┐
 │ Task Orchestrator ── plan → approve → execute → VERIFY  (STOP/PAUSE/RESUME/CANCEL)  │
 │ Intent: deterministic rules first → Qwen (Ollama, local) for language & planning    │
 │ Permission & Approval Manager (ApprovalGate)   Security & Audit Log (hash-chained)   │
 │ Persistent Memory (SQLite, AES-256-GCM per field, key wrapped with Windows DPAPI)    │
 │ Agents: Project · Git · Coding · File · Terminal · Browser · App · System Monitor    │
 │ TFT Service (serial, authenticated)    Credential store (Windows Credential Manager) │
 └──────▲──────────────────────────▲───────────────────────────▲──────────────────────┘
        │ USB serial (COM9)        │ WebSocket + token          │ Process (no shell)
 ┌──────┴────────────┐   ┌─────────┴──────────────┐   ┌─────────┴───────────────────┐
 │ ESP32 + TFT       │   │ VS Code extension       │   │ git · code · claude · ollama │
 │ (PlatformIO)      │   │ workspace, active file, │   └─────────────────────────────┘
 │ UI only, signed   │   │ terminal cwd            │
 │ events, no exec   │   └────────────────────────┘
 └───────────────────┘
```

Why this shape:
- **Service separate from UI**: tasks, TFT and approvals keep working if the UI window is closed or crashes;
  the UI, the TFT and the VS Code extension are all just clients of one service.
- **Dart for the service and UI**: shares the approval gate, privacy filter, task model and tool interfaces
  with Android without touching Android code (copied into a desktop `leo_core` package now; Android can
  switch to the package later as a separate, approved change). Dart covers what we need: `Process`
  (argument arrays, no shell), FFI serial (`libserialport`), FFI SQLite, `win32` (DPAPI, Credential Manager,
  window enumeration), HTTP to Ollama.
- **Qwen via Ollama** (already installed): local HTTP API, tool calling, model switch without code changes.
  Default `qwen2.5:3b` for planning; `1.5b` for fast intent fallback. Cloud (OpenAI) only if the user opts in.

### Repository layout (all new, under `desktop/`)
```
desktop/
  leo_core/        pure Dart: approval, privacy filter, task model, tools, desktop intents (shared)
  leo_agent/       Dart service: orchestrator, agents, memory, audit, IPC, TFT service
  leo_desktop/     Flutter Windows UI
  vscode-leo/      VS Code extension (TypeScript) — reports workspace / active file / terminal cwd
  firmware/leo_tft PlatformIO project for the ESP32 TFT kiosk
  docs/            PLAN.md, ARCHITECTURE.md, PROTOCOL.md, SECURITY.md, TEST_REPORT.md
```

## 3. Component design (key decisions)

**Task Orchestrator.** Every action is a task: `understand → plan → (approve) → execute → verify → report`.
Each step passes a checkpoint (STOP/PAUSE/CANCEL), same model as Android. A task is "done" only when the
verify step passes (e.g. new commit hash exists, remote ref equals local HEAD, file changed).

**Permission & Approval Manager.** Risk levels per tool: `read` (status, diff) → no prompt; `write-local`
(stage, commit, edit files, run allowlisted commands) → approval; `external/destructive` (push, pull with
merge, branch delete, force anything, Claude Code with edit rights) → explicit approval showing exact
parameters. Approval is bound to the canonical action + parameters (repo, branch, file list, message, commit
range) and is single-use; any change voids it. Approvals can come from the desktop UI or the TFT (both show
the same request id).

**Active project detection** (in order of trust):
1. VS Code extension: workspace folders, the active editor's file → its git root, focused terminal cwd
   (VS Code shell integration).
2. `leo here` CLI from any terminal (sends cwd to the service).
3. Configured project folders (default `Documents\projects`, 26 repos found).
4. Hints only: VS Code window title / recent workspaces. Never used alone to act.
If two or more candidates disagree → ask the user (UI + TFT picker). Display: name, path, remote, branch,
modified/untracked counts, latest commit, ahead/behind.

**Git Agent.** Git CLI with argument arrays (never a shell string), `--porcelain=v2 -z`,
`GIT_TERMINAL_PROMPT=0`, repo path validated against known roots. Commit flow = the 10 steps in the brief:
status → show files → inspect diff → message (Qwen from a diff summary, local) → approve → stage **only the
selected files** → commit → verify hash via `git rev-parse HEAD` + `git show --stat` → UI + TFT.
Push flow: branch + upstream → `git log @{u}..HEAD` outgoing list → approve → push → verify with
`git ls-remote` that the remote ref equals local HEAD. Conflict detection via status/unmerged entries.
Never offered: `push --force`, `reset --hard`, `clean -fd`, branch delete — unless the user explicitly
requests that exact operation and approves it.

**Secret detection (pre-commit).** Blocks by file name (`.env*`, `*.pem`, `*.key`, `id_rsa*`, `*.p12`,
`credentials*.json`, `jarvis_defines.json`, `*.keystore`, …) and by content scan of the staged diff (private
key headers, `sk-…`, `ghp_…`, AWS keys, Google API keys, JWTs, high-entropy assignments to
`*key*/*token*/*secret*`). Flagged files are excluded from the selection and shown as "excluded: secret";
including one requires a separate per-file override approval.

**Coding Agent.** `code <dir>` to open a project. Claude Code launched headless in the project directory
(`claude -p "<approved task>" --output-format stream-json`), permission mode chosen by the user at approval
time; progress streamed to UI/TFT; STOP kills the process tree. Completion is reported only from the
process exit code **plus** the actual `git status`/diff afterwards ("Claude Code exited 0; 3 files changed:
…"), never from Claude's own claim.

**File / Terminal / Browser / App / System agents.** File agent scoped to project roots. Terminal agent:
allowlisted commands (e.g. `npm test`, `flutter test`, `pytest`) run without shell; anything else needs
approval with the exact command line. Browser: open URLs in the default browser. App controller: launch
allowlisted apps, focus windows. System monitor: CPU, RAM, disk, GPU (`nvidia-smi`), battery, Ollama status.

**Persistent memory & credentials.** SQLite; private fields AES-256-GCM (fresh IV, AAD = table.column);
data key wrapped with Windows DPAPI (user scope). API keys and the TFT pairing key in Windows Credential
Manager. Retention + delete-everything like Android.

**Audit log.** Append-only JSONL, each entry hash-chained to the previous (tamper-evident): time, task id,
action, repo name, file count, decision, result (e.g. commit hash). No diffs, file contents, prompts or keys.

## 4. ESP32 ↔ Windows protocol (summary; full spec in PROTOCOL.md during Phase 5)
- Transport: USB serial 115200, newline-delimited JSON frames, max 1 KB per frame.
- Frame: `{"v":1,"t":"<type>","seq":n,"id":"<msg id>","b":{…},"mac":"<hex>"}`;
  `mac` = HMAC-SHA256(pairing key, canonical frame without mac), truncated to 128 bits.
- Pairing: on first connect the desktop shows a 6-digit code; the user confirms the same code on the TFT;
  a 256-bit key is then stored in ESP32 NVS and Windows Credential Manager. Unpaired devices only get
  `HELLO`/`PAIR_*`.
- Anti-replay: per-direction monotonically increasing `seq`; out-of-order or repeated → rejected.
- Desktop → ESP32: `STATUS`, `PROJECT`, `GIT`, `TASK`, `APPROVAL_REQUEST`, `AGENTS`, `SYSMON`, `NOTIFY`,
  `RESULT`, `PING`.
- ESP32 → desktop: `HELLO`, `ACK`, `PONG`, `UI_EVENT` (button id + screen + request id), `ERROR`.
- Validation: `UI_EVENT` accepted only if the button id is in the allowlist **for the screen currently
  shown** and, for approvals, references the pending request id + nonce. The ESP32 never runs anything;
  it only reports touches. Unknown types/fields → `ERROR` + audit entry.
- Disconnect: heartbeat every 2 s; 3 misses = disconnected; auto-rediscovery by USB VID:PID (CP210x
  10C4:EA60), re-handshake, full state resync.

## 5. Phases and exit tests

| Phase | Deliverable | Exit test (on this PC) |
|---|---|---|
| 1 | This plan + decisions | — |
| 2 | `leo_agent` skeleton (IPC, task engine, approvals, audit) + `leo_desktop` shell | UI connects; a dummy task can be paused/stopped |
| 3 | Project detection + Git agent + secret scan + VS Code extension | status/diff on nocom & kadamly; commit + hash verify on a scratch repo; `.env` excluded; push verify on a test remote |
| 4 | Coding, File, Terminal, Browser, App, System agents | `code kadamly` opens; Claude Code runs an approved task, STOP kills it, result read from git |
| 5 | Firmware base + protocol + pairing + reconnect | HELLO/pair/HMAC on COM9; unplug/replug recovers; forged/replayed frames rejected |
| 6 | 10 TFT screens + touch events | Each screen shown; commit approval from the TFT completes a real commit |
| 7 | Voice, Qwen planning, encrypted memory, credentials | Example commands from the brief; model down → graceful fallback |
| 8 | Full test run + TEST_REPORT.md | Every item in the brief; hardware tests marked passed only with the device attached |

## 6. Decisions (user, 2026-11-28)
1. **TFT:** 2.8" ILI9341 (320×240, SPI) + XPT2046 resistive touch on the ESP32 (COM9). Firmware: PlatformIO,
   LovyanGFX (display + touch) + LVGL for the 10 screens. Pin wiring to be confirmed at the start of Phase 5.
2. **Qwen:** `qwen2.5:3b` default via Ollama (fits the 4 GB GPU); `qwen2.5:1.5b` kept as fast fallback.
3. **Claude Code:** "edit files only" — launched with `--permission-mode acceptEdits`; it cannot run shell
   commands on its own; the user reviews the diff and commits through LEO's normal approval flow.
4. **Name / wake word:** LEO (same as Android).

Constraint: desktop work never modifies the Android app (`lib/`, `android/`).

# LEO Desktop — Test Report

## Phase 2 (agent service + desktop UI) — 2026-11-28, Windows 11 (this PC)

### Automated (`leo_agent`: 17 tests, run 3× — all pass; `leo_desktop`: 2 widget tests pass)
| Area | Test | Result |
|---|---|---|
| IPC security | Wrong token refused | PASS |
| | Browser request (Origin header) refused even with the right token | PASS |
| | Unknown method (`shell.exec`) and non-allowlisted task kind refused | PASS |
| | Discovery file holds port + token | PASS |
| | Second agent for the same user refused (single instance) | PASS |
| Controls | Full run: approve → write → read-back verify | PASS |
| | PAUSE stops progress; RESUME continues | PASS |
| | STOP mid-task → interrupted; later steps cancelled; no file written | PASS |
| | CANCEL while waiting for approval → request withdrawn; late "approve" rejected; no file | PASS |
| | PAUSE during approval → approving does not run the task until RESUME | PASS |
| Approvals | Deny → task cancelled, nothing written | PASS |
| | Answer with a forged fingerprint rejected; request stays pending | PASS |
| | Ticket only works for the exact approved parameters; a mismatch voids it | PASS |
| | Unanswered approval expires as denied | PASS |
| Audit | Run recorded; chain verifies; content and token never logged | PASS |
| | Editing one line breaks the chain at that entry | PASS |
| | Free text masked + truncated | PASS |
| UI | Approval card shows exact parameters; task controls match state | PASS |

### On this PC (release builds: `leo_agent.exe`, `leo_desktop.exe`)
| Test | Expected | Actual | Result |
|---|---|---|---|
| UI with no agent | "Agent not running" + Start button | As expected | PASS |
| Start agent from UI | Agent process starts, UI connects | pid 36568, connected on 127.0.0.1 | PASS |
| Run self-test task (clicked) | Steps progress | Counted 1→10, approval card with exact path + content | PASS |
| Pause during approval, then Approve (clicked) | Stays paused, nothing written | PAUSED, file absent | PASS |
| Resume (clicked) | Writes, verifies, reports | "Wrote and verified task-1.txt (51 bytes)", file content matches | PASS |
| Cancel during approval (task 2, via CLI client) | Cancelled, nothing written | cancelled, file absent | PASS |
| Audit chain after the session | Intact | ok, 15 entries | PASS |
| Pause/Stop during counting by mouse click | — | Not completed: clicks arrived after counting ended; covered by automated tests over the same IPC | NOT RUN (UI click) |

### Bugs found and fixed during Phase 2
1. Sending an event to a disconnecting client threw `StreamSink is closed` (could crash the agent when a window closes) → dead clients are dropped.
2. Approval card overflowed on narrow windows → wrapping layout.
3. Window larger than the 125%-scaled screen; title "leo_desktop" → 1180×720, "LEO Desktop".
4. Button errors from the agent were ignored silently → shown as "Agent refused: …".

### Incident during testing
A screenshot taken for the UI test captured the user's screen after focus moved to VS Code, showing
`lib/.env` (API keys). The file was deleted immediately; GUI automation was stopped and remaining checks
used the IPC client. Recommendation: rotate the keys shown in that file.

## ESP32 TFT firmware v0.1.0 — 2026-11-28, real device on COM9
Board ESP32-D0WD-V3, 2.8" ILI9341 + XPT2046 (wiring taken from the chiguru project). Built with PlatformIO
(espressif32 6.x, TFT_eSPI, ArduinoJson): RAM 6.8 %, flash 27.1 %. Flashed and hash-verified.
Tested with `desktop/firmware/tools/tft_test.py` against the physical board — **25/25 PASS**:

| Test | Result |
|---|---|
| HELLO after reset (fw, chip, paired, touch calibration reused) / on request, same session | PASS |
| Broken JSON, oversized frame, wrong version, unknown type (`RUN_SHELL`) → refused with ERROR | PASS |
| `PAIR_KEY` without a confirmed pairing; signed command while unpaired → refused | PASS |
| Pairing: code shown on the TFT, **user tapped Confirm on the device**, key delivered, `PAIR_DONE` signed with it | PASS |
| Pairing key stored on the PC with Windows DPAPI (not plaintext) | PASS |
| Signed PING → signed PONG | PASS |
| Replay (same seq), tampered body, wrong key, other session id, unsigned frame → refused | PASS |
| STATUS, NOTIFY, APPROVAL_REQUEST displayed (signed ACKs) | PASS |
| **User tapped Approve on the TFT** → signed UI_EVENT carrying the request id + nonce | PASS |
| Reconnect (port reopened = board reset): new session id; frames from the old session refused | PASS |

Not yet done: the desktop agent's TFT service (Dart) that uses this protocol, and the other 7 screens (Phase 6).
The board's previous firmware was not backed up (read_flash failed twice with serial noise); it is the
chiguru kiosk, whose source is in the chiguru repo and can be reflashed from there.

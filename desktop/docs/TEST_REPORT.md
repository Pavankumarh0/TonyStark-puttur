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

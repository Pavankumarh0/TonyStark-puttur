# LEO Desktop

Windows desktop agent for LEO. Plan: [docs/PLAN.md](docs/PLAN.md) · Phase 2 results: [docs/TEST_REPORT.md](docs/TEST_REPORT.md).
Independent of the Android app (`../lib`, `../android` are never modified by desktop work).

| Package | What it is |
|---|---|
| `leo_core/` | Pure-Dart shared core: task lifecycle (STOP/PAUSE/RESUME/CANCEL), approval binding, privacy masking, tool interfaces (copied from the Android app) |
| `leo_agent/` | Headless agent service: task engine, approvals, hash-chained audit log, local IPC server |
| `leo_desktop/` | Flutter Windows UI (a client of the agent) |

## Run
```powershell
# 1. Build the agent once
cd desktop\leo_agent; dart pub get; dart compile exe bin\leo_agent.dart -o build\leo_agent.exe
# 2. Run the UI (it offers "Start agent" if the agent isn't running)
cd ..\leo_desktop; flutter run -d windows        # or: flutter build windows --release
```
The agent writes `%LOCALAPPDATA%\LEO\agent.json` (port + session token) for local clients and keeps its
audit log in `%LOCALAPPDATA%\LEO\audit`. Stop it with Ctrl+C (or "STOP ALL" for tasks).

## Test
```powershell
cd desktop\leo_agent;   dart test      # 17 tests: IPC security, controls, approvals, audit
cd ..\leo_desktop;      flutter test   # widget tests
```

## IPC (for future clients: TFT bridge, VS Code extension)
WebSocket `ws://127.0.0.1:<port>/ws`, header `Authorization: Bearer <token>`, no `Origin` header.
Request `{"id":1,"method":"task.start","params":{"kind":"selftest"}}` → `{"id":1,"result":…}` or
`{"id":1,"error":{"code":"…"}}`. Events: `{"event":"task"|"approval.pending"|"approval.resolved"|"audit","data":…}`.
Methods: `hello, ping, task.start, task.pause, task.resume, task.stop, task.cancel, task.stopAll,
approval.respond (id + fingerprint + approve), audit.tail, audit.verify`.

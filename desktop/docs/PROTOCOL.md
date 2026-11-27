# LEO Desktop ↔ ESP32 TFT protocol (v1)

The ESP32 is a **display and touch panel only**. It shows what the desktop agent sends and reports
touches. It never executes commands; the desktop agent validates every event against what is on screen.

## Transport
- USB serial (CP210x), **115200 baud**, 8N1. Opening the port resets the board (auto-reset).
- One JSON object per line (`\n`). Max **1024 bytes** per frame. Lines not starting with `{` are ignored
  (boot noise).

## Frame
```json
{"v":1,"t":"STATUS","sid":"6f1c0a…","seq":42,"b":{…},"mac":"3a9f…(32 hex)"}
```
| Field | Meaning |
|---|---|
| `v` | Protocol version (1). Anything else → `ERROR bad_version` |
| `t` | Message type (tables below). Unknown → `ERROR unknown_type` |
| `sid` | Session id: 64 random bits chosen by the ESP32 at every boot, announced in `HELLO` |
| `seq` | Per-direction counter. Each accepted frame must have a higher `seq` than the previous one |
| `b` | Body (object) |
| `mac` | After pairing: first 16 bytes (hex) of **HMAC-SHA256(pairing key, frame bytes without `,"mac":"…"`)**. The MAC covers the exact bytes sent, so no JSON canonicalisation is needed: remove the trailing `,"mac":"<32 hex>"` and put back `}` to get the signed bytes |

## Acceptance rules on the ESP32 (in order)
1. Valid JSON, `v == 1`.
2. **Unsigned frames accepted only for**: `HELLO`, `PAIR_START`, `PAIR_KEY` (the latter only inside a pairing
   that the user physically confirmed, within 30 s).
3. Everything else must be: a known type → paired → signed → MAC valid (constant-time compare) →
   `sid` equals this boot's session → `seq` greater than the last accepted. Otherwise `ERROR` with
   `not_paired` / `unsigned` / `bad_mac` / `bad_session` / `replay`.

## Desktop → ESP32
| Type | Signed | Body | Effect |
|---|---|---|---|
| `HELLO` | no | `{}` | ESP32 replies `HELLO` |
| `PAIR_START` | no | `{code: "6 digits"}` | Shows the code with Confirm/Reject; replies `PAIR_WAIT` |
| `PAIR_KEY` | no | `{code, key: 64 hex}` | Only after the user confirmed on the device; stores the key in NVS; replies signed `PAIR_DONE` |
| `PING` | yes | `{}` | Replies signed `PONG {ms, rejected}` |
| `STATUS` | yes | `{state, text, project?}` | Home screen status |
| `NOTIFY` | yes | `{level: info/warn/error, text}` | 4 s banner |
| `APPROVAL_REQUEST` | yes | `{id, nonce (≥8 chars), title, lines[≤4]}` | Approval screen with Approve / Deny |
| `APPROVAL_CLEAR` | yes | `{id}` | Leaves the approval screen if it shows that id |
| `RESULT` | yes | `{ok, text}` | 5 s success/failure banner |
| `UNPAIR` | yes | `{}` | Forgets the key |

Every accepted signed command except `PING` is answered with a signed `ACK {ack: seq}`.

## ESP32 → desktop
| Type | Signed | Body |
|---|---|---|
| `HELLO` | no | `{fw, proto, chip, id, paired, touch, w, h}` (identity only) |
| `PAIR_WAIT` / `PAIR_ACCEPT` / `PAIR_REJECT` | no | `{code}` / `{code}` / `{reason}` |
| `PAIR_DONE` | yes (new key) | `{code}` — proves the key arrived intact |
| `PONG`, `ACK` | yes | see above |
| `UI_EVENT` | yes | `{screen, button, req?, nonce?}` — approval touches carry the request id + nonce shown |
| `ERROR` | yes when paired | `{code, ref: seq}` |

## What the desktop agent must enforce (Phase 5 TFT service)
- Accept `UI_EVENT` only if signed, in session, in order, and the `button` is allowed **for the screen the
  desktop last sent**; for approvals, `req` + `nonce` must match the pending request it displayed. Then
  pass it to the Approval Manager like any other client response (same fingerprint binding).
- Heartbeat: `PING` every 2 s; 3 missed `PONG`s = disconnected → rediscover the port by USB VID:PID
  `10C4:EA60`, read the new `HELLO` (new `sid`), resend the current screen.
- Keep the pairing key in Windows-protected storage (DPAPI / Credential Manager), never in plaintext.

## Pairing
1. Desktop shows a random 6-digit code and sends `PAIR_START {code}`.
2. The TFT shows the same code. The user checks it matches and taps **Confirm** (or presses **BOOT**) —
   physical presence; 60 s timeout.
3. Desktop sends a fresh random 256-bit key in `PAIR_KEY`; the ESP32 stores it in NVS and answers with
   `PAIR_DONE`, signed with that key.
4. Forget the pairing: `UNPAIR` from the desktop, or hold **BOOT for 8 s** on the device.

Limits (stated honestly): the key travels once over the USB cable during pairing, so someone who can
tap that cable at that moment could learn it; the NVS on this board is not flash-encrypted, so someone with
physical access to the board can read the key. Both require physical access to the PC or the device.

## Device controls
- Hold **BOOT 3 s** → touch calibration. Hold **BOOT 8 s** → forget pairing.
- The touch calibration saved by the earlier chiguru firmware on this board is reused automatically.

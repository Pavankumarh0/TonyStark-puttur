/*
 * LEO Desktop — ESP32 TFT kiosk firmware.
 *
 * Role: a display + touch panel for the LEO desktop agent. It shows status, approvals and results
 * that the desktop sends, and reports touches as UI_EVENTs. It never executes anything itself.
 *
 * Link: USB serial, newline-delimited JSON frames  {"v":1,"t":TYPE,"sid":S,"seq":N,"b":{...}}
 * After pairing every frame carries "mac" = first 16 bytes of HMAC-SHA256(key, frame-without-mac),
 * hex. Accepted desktop frames must be signed, belong to this boot's session id (sid) and have a
 * higher seq than the last one (no replays). Unsigned frames are only accepted for HELLO and pairing.
 * Pairing needs a physical confirm on the device (touch "Confirm" or press BOOT).
 * Full spec: desktop/docs/PROTOCOL.md
 */
#include <Arduino.h>
#include <ArduinoJson.h>
#include <Preferences.h>
#include <TFT_eSPI.h>

#include "config.h"
#include "esp_random.h"
#include "mbedtls/md.h"

TFT_eSPI tft;
static Preferences prefs;

// ---- colours (LEO green) ------------------------------------------------------------------
static const uint16_t C_BG = 0x00C1;     // #04190C
static const uint16_t C_PANEL = 0x0122;  // #072514
static const uint16_t C_LINE = 0x1224;   // #134726
static const uint16_t C_TEXT = 0xE7FD;   // #E4FFEA
static const uint16_t C_DIM = 0x7D91;    // #7CB08E
static const uint16_t C_ACCENT = 0x2FED; // #2EFF6E
static const uint16_t C_AMBER = 0xFE4A;  // #FFC857
static const uint16_t C_RED = 0xFACB;    // #FF5A5F

// ---- link state ---------------------------------------------------------------------------
static uint8_t pairKey[32];
static bool paired = false;
static char sid[17];             // session id: new at every boot
static uint32_t txSeq = 0, rxSeq = 0;
static uint32_t lastValidMs = 0;
static bool everValid = false;
static uint32_t rejected = 0;    // frames refused since boot (shown on the device)

// ---- UI state -----------------------------------------------------------------------------
enum Screen { S_HOME, S_PAIR, S_APPROVAL };
static Screen screen = S_HOME;
static bool dirty = true;
static bool linkShown = false;
static String stState = "idle", stText = "Waiting for LEO desktop", stProject = "";
static String pairCode;
static uint32_t pairStartMs = 0, pairAcceptMs = 0;
static bool pairPending = false, pairAccepted = false;
static String apId, apNonce, apTitle, apLines[5];
static int apCount = 0;
static String toast;
static uint16_t toastColor = C_ACCENT;
static uint32_t toastUntil = 0;
static bool touchReady = false;
static uint16_t touchCal[5];

struct Btn { int16_t x, y, w, h; const char *id; const char *label; uint16_t color; };
static const Btn HOME_BTNS[] = {{196, 186, 112, 44, "stop", "STOP", C_RED}};
static const Btn PAIR_BTNS[] = {{24, 180, 128, 46, "pair_confirm", "Confirm", C_ACCENT}, {168, 180, 128, 46, "pair_reject", "Reject", C_LINE}};
static const Btn APPR_BTNS[] = {{16, 186, 136, 44, "deny", "Deny", C_LINE}, {168, 186, 136, 44, "approve", "Approve", C_ACCENT}};

// ---- crypto helpers -----------------------------------------------------------------------
static void hmac16Hex(const String &msg, char out[33]) {
  uint8_t mac[32];
  mbedtls_md_hmac(mbedtls_md_info_from_type(MBEDTLS_MD_SHA256), pairKey, sizeof pairKey,
                  reinterpret_cast<const uint8_t *>(msg.c_str()), msg.length(), mac);
  for (int i = 0; i < 16; i++) sprintf(out + 2 * i, "%02x", mac[i]);
  out[32] = 0;
}

static bool constEq(const char *a, const char *b, size_t n) {
  uint8_t d = 0;
  for (size_t i = 0; i < n; i++) d |= static_cast<uint8_t>(a[i] ^ b[i]);
  return d == 0;
}

static bool parseHexKey(const char *hex, uint8_t out[32]) {
  if (!hex || strlen(hex) != 64) return false;
  for (int i = 0; i < 32; i++) {
    char b[3] = {hex[2 * i], hex[2 * i + 1], 0};
    char *end;
    out[i] = static_cast<uint8_t>(strtoul(b, &end, 16));
    if (*end) return false;
  }
  return true;
}

// ---- sending ------------------------------------------------------------------------------
static void sendFrame(const char *type, JsonVariantConst body, bool sign) {
  JsonDocument f;
  f["v"] = PROTO_VERSION;
  f["t"] = type;
  f["sid"] = sid;
  f["seq"] = ++txSeq;
  if (body.isNull()) f["b"].to<JsonObject>();
  else f["b"] = body;
  String s;
  serializeJson(f, s);
  if (sign && paired) {
    char mac[33];
    hmac16Hex(s, mac);
    s.remove(s.length() - 1);
    s += ",\"mac\":\"";
    s += mac;
    s += "\"}";
  }
  Serial.println(s);
}

static void sendSimple(const char *type, bool sign, const char *k = nullptr, const char *v = nullptr) {
  JsonDocument b;
  if (k) b[k] = v;
  sendFrame(type, b.as<JsonVariantConst>(), sign);
}

static void sendError(const char *code, uint32_t ref) {
  rejected++;
  JsonDocument b;
  b["code"] = code;
  b["ref"] = ref;
  sendFrame("ERROR", b.as<JsonVariantConst>(), paired);
}

static void sendHello() {
  JsonDocument b;
  char efuse[13];
  uint64_t m = ESP.getEfuseMac();
  snprintf(efuse, sizeof efuse, "%012llx", m);
  b["fw"] = FW_VERSION;
  b["proto"] = PROTO_VERSION;
  b["chip"] = ESP.getChipModel();
  b["id"] = efuse;
  b["paired"] = paired;
  b["touch"] = touchReady;
  b["w"] = tft.width();
  b["h"] = tft.height();
  sendFrame("HELLO", b.as<JsonVariantConst>(), false); // identity only; nothing secret
}

static void sendUiEvent(const char *button) {
  if (!paired) {
    toast = "Not paired with LEO";
    toastColor = C_AMBER;
    toastUntil = millis() + 3000;
    dirty = true;
    return;
  }
  JsonDocument b;
  b["screen"] = screen == S_HOME ? "home" : screen == S_PAIR ? "pair" : "approval";
  b["button"] = button;
  if (screen == S_APPROVAL) {
    b["req"] = apId;
    b["nonce"] = apNonce; // binds the touch to the exact request on screen
  }
  sendFrame("UI_EVENT", b.as<JsonVariantConst>(), true);
}

// ---- drawing ------------------------------------------------------------------------------
static bool linkUp() { return everValid && millis() - lastValidMs < LINK_TIMEOUT_MS; }

static void drawButton(const Btn &b) {
  tft.fillRoundRect(b.x, b.y, b.w, b.h, 10, b.color);
  tft.setTextColor(b.color == C_ACCENT ? C_BG : C_TEXT, b.color);
  tft.setTextDatum(MC_DATUM);
  tft.drawString(b.label, b.x + b.w / 2, b.y + b.h / 2, 4);
}

static void drawHeader() {
  tft.fillRect(0, 0, 320, 34, C_PANEL);
  tft.drawFastHLine(0, 34, 320, C_LINE);
  tft.setTextDatum(ML_DATUM);
  tft.setTextColor(C_ACCENT, C_PANEL);
  tft.drawString("L E O", 10, 17, 4);
  const bool up = linkUp();
  tft.fillCircle(206, 17, 5, up ? C_ACCENT : C_AMBER);
  tft.setTextColor(up ? C_TEXT : C_DIM, C_PANEL);
  tft.drawString(up ? "connected" : (paired ? "not connected" : "not paired"), 216, 17, 2);
  linkShown = up;
}

static void drawWrapped(const String &text, int x, int y, int w, int font, uint16_t color, int maxLines) {
  tft.setTextDatum(TL_DATUM);
  tft.setTextColor(color, C_BG);
  String line, word;
  int lines = 0;
  const int lh = tft.fontHeight(font) + 2;
  String t = text + " ";
  for (size_t i = 0; i < t.length() && lines < maxLines; i++) {
    const char c = t[i];
    if (c == ' ' || c == '\n') {
      String cand = line.length() ? line + " " + word : word;
      if (tft.textWidth(cand, font) > w && line.length()) {
        tft.drawString(line, x, y + lines++ * lh, font);
        line = word;
      } else {
        line = cand;
      }
      word = "";
      if (c == '\n' && lines < maxLines) {
        tft.drawString(line, x, y + lines++ * lh, font);
        line = "";
      }
    } else {
      word += c;
    }
  }
  if (line.length() && lines < maxLines) tft.drawString(line, x, y + lines * lh, font);
}

static void drawScreen() {
  tft.fillScreen(C_BG);
  drawHeader();
  if (screen == S_HOME) {
    const uint16_t sc = stState == "failed" ? C_RED : stState == "paused" || stState == "waiting" ? C_AMBER : C_ACCENT;
    tft.setTextDatum(TL_DATUM);
    tft.setTextColor(sc, C_BG);
    String st = stState;
    st.toUpperCase();
    tft.drawString(st, 12, 46, 2);
    drawWrapped(stText, 12, 66, 296, 4, C_TEXT, 3);
    if (stProject.length()) {
      tft.setTextColor(C_DIM, C_BG);
      tft.drawString("Project: " + stProject, 12, 150, 2);
    }
    tft.setTextColor(C_DIM, C_BG);
    tft.drawString(touchReady ? "" : "Touch not calibrated: hold BOOT 3 s", 12, 168, 2);
    if (!paired) tft.drawString("Pair from LEO Desktop to use this panel", 12, 196, 2);
    else drawButton(HOME_BTNS[0]);
  } else if (screen == S_PAIR) {
    tft.setTextDatum(MC_DATUM);
    tft.setTextColor(C_TEXT, C_BG);
    tft.drawString("Pair with LEO Desktop?", 160, 60, 4);
    tft.setTextColor(C_DIM, C_BG);
    tft.drawString(pairAccepted ? "Confirmed - waiting for the desktop" : "Only confirm if your PC shows this code", 160, 88, 2);
    tft.setTextColor(C_ACCENT, C_BG);
    tft.drawString(pairCode, 160, 130, 4);
    tft.setTextColor(C_DIM, C_BG);
    tft.drawString("(or press BOOT to confirm)", 160, 160, 2);
    if (!pairAccepted) {
      drawButton(PAIR_BTNS[0]);
      drawButton(PAIR_BTNS[1]);
    }
  } else {
    tft.setTextDatum(TL_DATUM);
    tft.setTextColor(C_AMBER, C_BG);
    tft.drawString("APPROVAL NEEDED", 12, 44, 2);
    drawWrapped(apTitle, 12, 62, 296, 4, C_TEXT, 2);
    for (int i = 0; i < apCount; i++) drawWrapped(apLines[i], 12, 116 + i * 16, 296, 2, C_DIM, 1);
    drawButton(APPR_BTNS[0]);
    drawButton(APPR_BTNS[1]);
  }
  if (millis() < toastUntil) {
    tft.fillRoundRect(10, 40, 300, 30, 8, toastColor);
    tft.setTextDatum(MC_DATUM);
    tft.setTextColor(C_BG, toastColor);
    tft.drawString(toast, 160, 55, 2);
  }
  dirty = false;
}

static void showToast(const String &t, uint16_t c, uint32_t ms) {
  toast = t;
  toastColor = c;
  toastUntil = millis() + ms;
  dirty = true;
}

// ---- pairing ------------------------------------------------------------------------------
static void pairConfirm() {
  if (!pairPending || pairAccepted) return;
  pairAccepted = true;
  pairAcceptMs = millis();
  sendSimple("PAIR_ACCEPT", false, "code", pairCode.c_str());
  dirty = true;
}

static void pairEnd(const char *reason) {
  if (pairPending && !paired) sendSimple("PAIR_REJECT", false, "reason", reason);
  else if (pairPending) sendSimple("PAIR_REJECT", true, "reason", reason);
  pairPending = pairAccepted = false;
  screen = S_HOME;
  dirty = true;
}

static void forgetPairing() {
  prefs.remove("key");
  memset(pairKey, 0, sizeof pairKey);
  paired = false;
  everValid = false;
  rxSeq = 0;
  dirty = true;
}

// ---- receiving ----------------------------------------------------------------------------
static bool knownSigned(const char *t) {
  static const char *types[] = {"PING", "STATUS", "NOTIFY", "APPROVAL_REQUEST", "APPROVAL_CLEAR", "RESULT", "UNPAIR"};
  for (auto x : types)
    if (!strcmp(t, x)) return true;
  return false;
}

static void ack(uint32_t seq) {
  JsonDocument b;
  b["ack"] = seq;
  sendFrame("ACK", b.as<JsonVariantConst>(), true);
}

static void dispatch(const char *t, JsonObjectConst b, uint32_t seq) {
  if (!strcmp(t, "PING")) {
    JsonDocument r;
    r["ms"] = millis();
    r["rejected"] = rejected;
    sendFrame("PONG", r.as<JsonVariantConst>(), true);
  } else if (!strcmp(t, "STATUS")) {
    stState = String(b["state"] | "idle").substring(0, 16);
    stText = String(b["text"] | "").substring(0, 160);
    stProject = String(b["project"] | "").substring(0, 40);
    if (screen == S_HOME) dirty = true;
    ack(seq);
  } else if (!strcmp(t, "NOTIFY")) {
    const String level = b["level"] | "info";
    showToast(String(b["text"] | "").substring(0, 44), level == "error" ? C_RED : level == "warn" ? C_AMBER : C_ACCENT, 4000);
    ack(seq);
  } else if (!strcmp(t, "APPROVAL_REQUEST")) {
    const char *id = b["id"] | "";
    const char *nonce = b["nonce"] | "";
    if (!*id || strlen(nonce) < 8) {
      sendError("bad_body", seq);
      return;
    }
    apId = String(id).substring(0, 32);
    apNonce = String(nonce).substring(0, 32);
    apTitle = String(b["title"] | "Approve?").substring(0, 80);
    apCount = 0;
    for (JsonVariantConst l : b["lines"].as<JsonArrayConst>()) {
      if (apCount >= 4) break;
      apLines[apCount++] = String(l.as<const char *>() ? l.as<const char *>() : "").substring(0, 60);
    }
    screen = S_APPROVAL;
    dirty = true;
    ack(seq);
  } else if (!strcmp(t, "APPROVAL_CLEAR")) {
    if (screen == S_APPROVAL && apId == String(b["id"] | "")) {
      screen = S_HOME;
      dirty = true;
    }
    ack(seq);
  } else if (!strcmp(t, "RESULT")) {
    const bool ok = b["ok"] | false;
    if (screen == S_APPROVAL) screen = S_HOME;
    showToast(String(b["text"] | (ok ? "Done" : "Failed")).substring(0, 44), ok ? C_ACCENT : C_RED, 5000);
    ack(seq);
  } else if (!strcmp(t, "UNPAIR")) {
    ack(seq);
    forgetPairing();
    showToast("Pairing removed", C_AMBER, 4000);
  }
}

static void handleLine(String &line) {
  line.trim();
  if (!line.length() || line[0] != '{') return; // boot noise etc. is not protocol
  // Split off the MAC: the signed bytes are the frame exactly as sent, without ,"mac":"…".
  String body = line;
  char gotMac[33] = {0};
  bool hasMac = false;
  const int mi = line.lastIndexOf(",\"mac\":\"");
  if (mi > 0 && line.endsWith("\"}") && static_cast<int>(line.length()) - mi == 8 + 32 + 2) {
    body = line.substring(0, mi) + "}";
    memcpy(gotMac, line.c_str() + mi + 8, 32);
    hasMac = true;
  }
  JsonDocument doc;
  if (deserializeJson(doc, body)) {
    sendError("bad_json", 0);
    return;
  }
  if ((doc["v"] | 0) != PROTO_VERSION) {
    sendError("bad_version", 0);
    return;
  }
  const char *t = doc["t"] | "";
  const uint32_t seq = doc["seq"] | 0;
  JsonObjectConst b = doc["b"].as<JsonObjectConst>();

  // --- the only frames accepted without a signature ---
  if (!strcmp(t, "HELLO")) {
    sendHello();
    return;
  }
  if (!strcmp(t, "PAIR_START")) {
    const char *code = b["code"] | "";
    if (strlen(code) != 6) {
      sendError("bad_body", seq);
      return;
    }
    pairCode = code;
    pairPending = true;
    pairAccepted = false;
    pairStartMs = millis();
    screen = S_PAIR;
    dirty = true;
    sendSimple("PAIR_WAIT", false, "code", code);
    return;
  }
  if (!strcmp(t, "PAIR_KEY")) {
    uint8_t k[32];
    if (!pairPending || !pairAccepted || millis() - pairAcceptMs > PAIR_KEY_WINDOW_MS) {
      sendError("not_pairing", seq);
      return;
    }
    if (pairCode != String(b["code"] | "") || !parseHexKey(b["key"] | "", k)) {
      sendError("bad_body", seq);
      return;
    }
    memcpy(pairKey, k, 32);
    memset(k, 0, sizeof k);
    prefs.putBytes("key", pairKey, sizeof pairKey);
    paired = true;
    rxSeq = 0;
    pairPending = pairAccepted = false;
    screen = S_HOME;
    showToast("Paired with LEO Desktop", C_ACCENT, 4000);
    sendSimple("PAIR_DONE", true, "code", pairCode.c_str()); // signed: proves the key arrived intact
    return;
  }

  // --- everything else: paired, signed, this session, newer than the last ---
  if (!knownSigned(t)) {
    sendError("unknown_type", seq);
    return;
  }
  if (!paired) {
    sendError("not_paired", seq);
    return;
  }
  if (!hasMac) {
    sendError("unsigned", seq);
    return;
  }
  char want[33];
  hmac16Hex(body, want);
  if (!constEq(want, gotMac, 32)) {
    sendError("bad_mac", seq);
    return;
  }
  if (strcmp(doc["sid"] | "", sid) != 0) {
    sendError("bad_session", seq);
    return;
  }
  if (seq <= rxSeq) {
    sendError("replay", seq);
    return;
  }
  rxSeq = seq;
  lastValidMs = millis();
  everValid = true;
  dispatch(t, b, seq);
}

// ---- input --------------------------------------------------------------------------------
static String rx;
static bool rxOverflow = false;

static void pollSerial() {
  while (Serial.available()) {
    const char c = static_cast<char>(Serial.read());
    if (c == '\n') {
      if (rxOverflow) sendError("too_long", 0);
      else handleLine(rx);
      rx = "";
      rxOverflow = false;
    } else if (!rxOverflow) {
      if (rx.length() >= MAX_LINE) rxOverflow = true;
      else rx += c;
    }
  }
}

static void calibrateTouch() {
  for (int attempt = 1; attempt <= 3; attempt++) {
    tft.fillScreen(C_BG);
    tft.setTextDatum(MC_DATUM);
    tft.setTextColor(C_TEXT, C_BG);
    tft.drawString("Touch calibration", 160, 100, 4);
    tft.setTextColor(C_DIM, C_BG);
    tft.drawString("Touch each arrow tip in turn", 160, 132, 2);
    delay(2000);
    uint16_t cal[5];
    tft.calibrateTouch(cal, C_ACCENT, C_BG, 15);
    if (cal[1] >= TOUCH_CAL_MIN_RANGE && cal[3] >= TOUCH_CAL_MIN_RANGE) {
      memcpy(touchCal, cal, sizeof touchCal);
      prefs.putBytes("tcal", touchCal, sizeof touchCal);
      tft.setTouch(touchCal);
      touchReady = true;
      break;
    }
  }
  dirty = true;
}

static const Btn *hit(const Btn *btns, int n, uint16_t x, uint16_t y) {
  for (int i = 0; i < n; i++)
    if (x >= btns[i].x && x < btns[i].x + btns[i].w && y >= btns[i].y && y < btns[i].y + btns[i].h) return &btns[i];
  return nullptr;
}

static uint32_t lastTouchMs = 0;
static void pollTouch() {
  if (!touchReady) return;
  uint16_t x, y;
  if (!tft.getTouch(&x, &y) || millis() - lastTouchMs < 350) return;
  lastTouchMs = millis();
  const Btn *b = nullptr;
  if (screen == S_HOME && paired) b = hit(HOME_BTNS, 1, x, y);
  else if (screen == S_PAIR && !pairAccepted) b = hit(PAIR_BTNS, 2, x, y);
  else if (screen == S_APPROVAL) b = hit(APPR_BTNS, 2, x, y);
  if (!b) return;
  tft.drawRoundRect(b->x, b->y, b->w, b->h, 10, C_TEXT); // press feedback
  if (!strcmp(b->id, "pair_confirm")) pairConfirm();
  else if (!strcmp(b->id, "pair_reject")) pairEnd("rejected_on_device");
  else sendUiEvent(b->id); // the desktop decides; the panel only reports
}

static uint32_t bootDownMs = 0;
static bool bootLong = false;
static void pollBootButton() {
  const bool down = digitalRead(PIN_BOOT) == LOW;
  if (down && !bootDownMs) {
    bootDownMs = millis();
    bootLong = false;
  } else if (down && !bootLong && millis() - bootDownMs > BOOT_UNPAIR_HOLD_MS) {
    bootLong = true;
    forgetPairing();
    showToast("Pairing forgotten", C_AMBER, 4000);
  } else if (!down && bootDownMs) {
    const uint32_t held = millis() - bootDownMs;
    bootDownMs = 0;
    if (bootLong) return;
    if (held >= BOOT_CAL_HOLD_MS) calibrateTouch();
    else if (held > 40 && screen == S_PAIR) pairConfirm();
  }
}

// ---- main ---------------------------------------------------------------------------------
void setup() {
  Serial.setRxBufferSize(2048);
  Serial.begin(SERIAL_BAUD);
  pinMode(PIN_BOOT, INPUT_PULLUP);

  uint8_t r[8];
  esp_fill_random(r, sizeof r);
  for (int i = 0; i < 8; i++) sprintf(sid + 2 * i, "%02x", r[i]);

  prefs.begin("leo", false);
  paired = prefs.getBytes("key", pairKey, sizeof pairKey) == sizeof pairKey;

  tft.init();
  tft.setRotation(1); // landscape 320x240, same as the chiguru kiosk on this board
  // Touch calibration: our own, else the one already saved on this board by the chiguru kiosk.
  touchReady = prefs.getBytes("tcal", touchCal, sizeof touchCal) == sizeof touchCal;
  if (!touchReady) {
    Preferences old;
    if (old.begin("krishi", true)) {
      touchReady = old.getBytes("tcal", touchCal, sizeof touchCal) == sizeof touchCal;
      old.end();
    }
  }
  touchReady = touchReady && touchCal[1] >= TOUCH_CAL_MIN_RANGE && touchCal[3] >= TOUCH_CAL_MIN_RANGE;
  if (touchReady) tft.setTouch(touchCal);

  drawScreen();
  sendHello();
}

void loop() {
  pollSerial();
  pollBootButton();
  pollTouch();
  if (pairPending && !pairAccepted && millis() - pairStartMs > PAIR_CONFIRM_MS) pairEnd("timeout");
  if (pairPending && pairAccepted && millis() - pairAcceptMs > PAIR_KEY_WINDOW_MS) pairEnd("key_timeout");
  if (toastUntil && millis() >= toastUntil) {
    toastUntil = 0;
    dirty = true;
  }
  if (linkUp() != linkShown) drawHeader();
  if (dirty) drawScreen();
  delay(5);
}

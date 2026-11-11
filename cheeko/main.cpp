// Cheeko Gotchi firmware: Pip (virtual pet) and Navigation in one image.
//
// Buttons (shared by every app):
//   hold + and - together (~1s)   switch app; the last one opens at power-on
//   + or - short press            the app's action (on release, so a chord
//                                 for switching doesn't trigger it)
//   middle short press            the app's action
//   middle hold 3s                power off (on battery)
//
// Protocol messages (PROTOCOL.md) arrive over Bluetooth from the phone, or as
// '@<hex>' lines on the USB console; either way they go to Navigation, and a
// new route switches to it. Also: app [pip|nav], fps, shot, help, plus app commands.
//
// Hardware access lives in ../lib/cheeko_board. Build with ../pet.sh.

#include <Arduino.h>
#include <Preferences.h>
#include <cheeko_board.h>

#include "app.h"
#include "ble_link.h"
#include "model.h"

using namespace board;

static const App* const apps[] = {&pip::app, &nav::app};
static constexpr int APP_COUNT = sizeof(apps) / sizeof(apps[0]);
static int current = 0;
static Preferences settings;

static MiddleKey midKey;
static bool keyLog = false;
static uint32_t frameDrawUs = 0, frameWaitUs = 0;
static float fps = 0;

// ---- Toast ----
static char toastText[40] = "";
static uint32_t toastUntil = 0;
static int toastSize = 1;

void showToast(const char* text, uint32_t ms, int size) {
  strlcpy(toastText, text, sizeof(toastText));
  toastUntil = millis() + ms;
  toastSize = size;
}

static void switchTo(int index) {
  if (index == current) return;
  apps[current]->leave();
  current = index;
  settings.putUChar("app", current);
  apps[current]->enter();
  showToast(apps[current]->name, 1200, 2);
}

// ---- + / - with chord detection ----
struct Key {
  int pin;
  bool down;
  uint32_t changedAt;
};
static Key keyPlus{PIN_VOLUME_UP, false, 0}, keyMinus{PIN_VOLUME_DOWN, false, 0};
static bool chord = false, chordFired = false;
static uint32_t chordSince = 0;
static constexpr uint32_t CHORD_MS = 900;

// Debounced read. Returns true on release.
static bool released(Key& k, uint32_t now) {
  bool level = digitalRead(k.pin) == LOW;  // active LOW
  if (level == k.down || now - k.changedAt < 40) return false;
  k.down = level;
  k.changedAt = now;
  return !level;
}

static void pollKeys(uint32_t now) {
  bool relPlus = released(keyPlus, now);
  bool relMinus = released(keyMinus, now);

  if (keyPlus.down && keyMinus.down) {
    if (!chord) { chord = true; chordSince = now; }
    if (!chordFired && now - chordSince >= CHORD_MS) {
      chordFired = true;
      sfx({{660, 60}, {990, 80}});
      switchTo((current + 1) % APP_COUNT);
    }
  }
  if (relPlus && !chord) apps[current]->plus();
  if (relMinus && !chord) apps[current]->minus();
  if (!keyPlus.down && !keyMinus.down) chord = chordFired = false;
}

static void doPowerOff() {
  apps[current]->beforePowerOff();
  lcdPush();
  sfx({{784, 100}, {523, 100}, {392, 220}});
  delay(600);
  powerOff();  // returns only on USB power
  showToast("on USB - unplug to power off", 3500);
}

// ---- Console ----
static int hexVal(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

// A protocol message from either transport.
static bool dispatch(const uint8_t* msg, size_t n) {
  if (nav::demoRunning()) nav::demoStop();  // a real sender takes over
  bool ok = nav::handleMessage(msg, n);
  if (ok && n && (msg[0] == 0x01 || msg[0] == 0x14)) switchTo(1);  // ROUTE_BEGIN / RESET: show the navigator
  return ok;
}

static void pollBluetooth() {
  static uint8_t msg[ble::MAX_MESSAGE];
  size_t n;
  for (int i = 0; i < 40 && ble::receive(msg, &n); ++i) dispatch(msg, n);
}

static void handleMessageLine(const char* hex) {
  static uint8_t msg[600];
  size_t n = 0;
  for (const char* p = hex; p[0] && p[1] && n < sizeof(msg); p += 2) {
    int hi = hexVal(p[0]), lo = hexVal(p[1]);
    if (hi < 0 || lo < 0) { Serial.println("err hex"); return; }
    msg[n++] = hi << 4 | lo;
  }
  Serial.println(dispatch(msg, n) ? "ok" : "err msg");
}

static void handleLine(const char* line) {
  if (line[0] == '@') {
    handleMessageLine(line + 1);
  } else if (!strcmp(line, "app")) {
    Serial.printf("app=%s\n", apps[current]->name);
  } else if (!strcmp(line, "app pip")) {
    switchTo(0);
  } else if (!strcmp(line, "app nav")) {
    switchTo(1);
  } else if (!strcmp(line, "keys")) {
    Serial.printf("middle(gpio3)=%d plus(gpio40)=%d minus(gpio39)=%d held=%ums\n",
                  digitalRead(PIN_POWER_KEY), digitalRead(PIN_VOLUME_UP), digitalRead(PIN_VOLUME_DOWN),
                  (unsigned)midKey.heldMs(millis()));
  } else if (!strcmp(line, "keylog")) {
    keyLog = !keyLog;
    Serial.printf("key logging %s\n", keyLog ? "on" : "off");
  } else if (!strcmp(line, "ble")) {
    Serial.printf("bluetooth: %s\n", ble::connected() ? "phone connected" : "advertising as Cheeko");
  } else if (!strcmp(line, "fps")) {
    Serial.printf("draw=%uus wait=%uus fps=%.1f\n", frameDrawUs, frameWaitUs, fps);
  } else if (!strcmp(line, "shot")) {
    // The last finished frame isn't kept, so draw a fresh one to send.
    // Raw RGB565, little-endian, row by row (tools/screenshot.py).
    apps[current]->frame(millis());
    size_t bytes = LCD_W * LCD_H * 2;
    Serial.printf("SHOT %u %u %u\n", LCD_W, LCD_H, (unsigned)bytes);
    Serial.write((const uint8_t*)fb->getBuffer(), bytes);
    Serial.println();
  } else if (!apps[current]->command(line)) {
    Serial.printf("commands: app [pip|nav] ble fps shot help | %s: %s\n", apps[current]->name, apps[current]->help);
  }
}

static void handleSerial() {
  static char line[1400];
  static size_t len = 0;
  while (Serial.available()) {
    char c = Serial.read();
    if (c != '\n' && c != '\r') {
      if (len < sizeof(line) - 1) line[len++] = c;
      continue;
    }
    if (len == 0) continue;
    line[len] = 0;
    len = 0;
    handleLine(line);
  }
}

// ---- Overlays drawn on top of any app ----
static void drawOverlays(uint32_t now) {
  fb->setFont(nullptr);
  uint32_t held = midKey.heldMs(now);
  if (held > 600) {
    char msg[32];
    snprintf(msg, sizeof(msg), "powering off in %u...",
             (unsigned)((MiddleKey::HOLD_MS - min(MiddleKey::HOLD_MS, held) + 999) / 1000));
    fb->fillRoundRect(30, 130, 180, 40, 12, 0xffff);
    centerText(146, msg, 0x0000);
  } else if (chord && !chordFired && now - chordSince > 200) {
    fb->fillRoundRect(40, 130, 160, 40, 12, 0xffff);
    centerText(146, "switching app...", 0x0000);
  } else if ((int32_t)(toastUntil - now) > 0) {
    int h = toastSize == 2 ? 44 : 34;
    fb->fillRoundRect(20, 148 - h / 2, 200, h, 12, 0xffff);
    centerText(148 - 4 * toastSize, toastText, 0x0000, toastSize);
  }
}

void setup() {
  Serial.setRxBufferSize(8192);  // route uploads arrive in bursts
  Serial.begin(115200);
  if (!board::begin()) {
    for (;;) { Serial.println("framebuffer alloc failed - is PSRAM=opi set?"); delay(1000); }
  }
  midKey.begin();
  ble::begin();
  settings.begin("cheeko", false);
  current = constrain(settings.getUChar("app", 0), 0, APP_COUNT - 1);
  for (const App* a : apps) a->init();
  apps[current]->enter();
  Serial.printf("cheeko booted. app=%s audio=%d accel=%d\n", apps[current]->name, audioOk, accelOk);
  Serial.println("@20");  // HELLO for a route sender
}

void loop() {
  uint32_t now = millis();
  handleSerial();
  pollBluetooth();
  pollKeys(now);
  if (keyLog) {
    static int lastLevel = -1;
    int level = digitalRead(PIN_POWER_KEY);
    if (level != lastLevel) Serial.printf("t=%u middle=%d\n", (unsigned)now, level);
    lastLevel = level;
  }
  MiddleKey::Event ev = midKey.poll(now);
  if (keyLog && ev != MiddleKey::Event::None)
    Serial.printf("t=%u middle event=%s\n", (unsigned)now, ev == MiddleKey::Event::Short ? "short" : "hold");
  switch (ev) {
    case MiddleKey::Event::Short: apps[current]->middle(); break;
    case MiddleKey::Event::Hold: doPowerOff(); break;
    case MiddleKey::Event::None: break;
  }
  for (int i = 0; i < APP_COUNT; ++i)
    if (i != current) apps[i]->background(now);

  uint32_t t0 = micros();
  apps[current]->frame(now);
  drawOverlays(now);
  uint32_t t1 = micros();
  lcdPushAsync();  // sent in the background while the next frame is drawn
  uint32_t t2 = micros();
  frameDrawUs = (frameDrawUs * 7 + (t1 - t0)) / 8;
  frameWaitUs = (frameWaitUs * 7 + (t2 - t1)) / 8;

  static uint32_t frames = 0, windowStart = 0;
  ++frames;
  if (now - windowStart >= 2000) {
    fps = frames * 1000.0f / (now - windowStart);
    frames = 0;
    windowStart = now;
  }
}

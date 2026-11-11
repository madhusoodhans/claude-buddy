// Claude Buddy: a face for Claude Code on the Mac (see ../mac).
//
// Three pages, swipe left/right (or press + / -):
//   1. the buddy, acting out what Claude is doing      face.cpp
//   2. plan usage: 5-hour session and weekly limits    meters.cpp
//   3. Claude's day: lines, prompts, tools, activity   day.cpp
// The time runs along the top of every page.
//
// Touch and hold anywhere (1s) toggles sound. Tap the buddy, shake the device.
// The middle button is the hardware power key (hold to power off).
//
// Messages (PROTOCOL.md) arrive over Bluetooth from the Mac helper, or as
// lines on the USB console. Console also: page N, demo, shot, sound, status.
//
// Hardware access lives in ../lib/cheeko_board. Build with ../pet.sh.

#include <Arduino.h>
#include <Preferences.h>
#include <cheeko_board.h>

#include "bt_link.h"
#include "model.h"
#include "ui.h"

using namespace board;
using namespace ui;

bool soundOn = true;

static constexpr int PAGES = 3;
static int page = 0;
static Preferences settings;
static MiddleKey midKey;

// ---- Page slide: the old page is kept as a picture and slides out ----
static uint16_t* oldFrame;  // PSRAM, one screen
static uint16_t* newFrame;
static int slideDir = 0;    // +1 new page comes from the right, -1 from the left, 0 none
static uint32_t slideAt = 0;
static constexpr uint32_t SLIDE_MS = 260;

// ---- Toast ----
static char toastText[40] = "";
static uint32_t toastUntil = 0;

static void showToast(const char* text, uint32_t ms) {
  strlcpy(toastText, text, sizeof(toastText));
  toastUntil = millis() + ms;
}

// ---- Demo: fake data so every screen can be seen without a Mac ----
static bool demo = false;
static uint32_t demoStep = 0, demoAt = 0;

static bool linked(uint32_t now) {
  return bt::connected() || demo || (lastMessageAt && now - lastMessageAt < 30000);
}

static void drawPage(int p, uint32_t now) {
  fb->fillScreen(BG);
  bool l = linked(now);
  if (p == 0) face::draw(now, l);
  else if (p == 1) meters::draw(now, l);
  else day::draw(now, l);
}

static void goTo(int p, int dir, uint32_t now) {
  p = (p + PAGES) % PAGES;
  if (p == page) return;
  drawPage(page, now);  // what's on screen now, minus the header
  memcpy(oldFrame, fb->getBuffer(), LCD_W * LCD_H * 2);
  page = p;
  slideDir = dir;
  slideAt = now;
  settings.putUChar("page", page);
  if (soundOn) sfx({{1200, 18}});
}

// Moves the content below the header: old page out, new page in.
static void composeSlide(uint32_t now) {
  float t = (now - slideAt) / (float)SLIDE_MS;
  if (t >= 1) {
    slideDir = 0;
    return;
  }
  float e = 1 - (1 - t) * (1 - t) * (1 - t);  // ease out
  int shift = (int)(e * LCD_W);
  uint16_t* out = fb->getBuffer();
  memcpy(newFrame, out, LCD_W * LCD_H * 2);
  for (int y = HEADER_H; y < LCD_H; ++y) {
    uint16_t* row = out + y * LCD_W;
    const uint16_t* o = oldFrame + y * LCD_W;
    const uint16_t* n = newFrame + y * LCD_W;
    if (slideDir > 0) {  // everything moves left
      memcpy(row, o + shift, (LCD_W - shift) * 2);
      memcpy(row + LCD_W - shift, n, shift * 2);
    } else {  // everything moves right
      memcpy(row, n + LCD_W - shift, shift * 2);
      memcpy(row + shift, o, (LCD_W - shift) * 2);
    }
  }
}

// ---- Header (clock) and page dots, fixed while pages slide ----
static void drawChrome(uint32_t now) {
  fb->fillRect(0, 0, LCD_W, HEADER_H, BG);
  char t[12];
  int h, m, s;
  if (localTime(h, m, s)) {
    if (clock24h()) snprintf(t, sizeof(t), "%02d:%02d", h, m);
    else snprintf(t, sizeof(t), "%d:%02d", (h + 11) % 12 + 1, m);
  } else {
    strlcpy(t, "--:--", sizeof(t));
  }
  int w = aa::textWidth(t, fontClock);
  aa::text(120, 32, t, fontClock, TEXT, aa::Align::Center);

  // left of the clock: Claude's state as a little spark; right: the Bluetooth link
  float tt = now / 1000.0f;
  bool l = linked(now);
  Mood mood = activity.known ? activity.mood : Mood::Idle;
  float sx = 120 - w / 2 - 16, dx = 120 + w / 2 + 14;
  if (!l) spark(sx, 23, 6, 0, FAINT, 2);
  else if (mood == Mood::Working) spark(sx, 23, 7, tt * 4, CLAY, 2.2f);
  else if (mood == Mood::Waiting) spark(sx, 23, 6 + 1.5f * sinf(tt * 8), 0, AMBER, 2.4f);
  else if (mood == Mood::Done) spark(sx, 23, 7, 0, GREEN, 2.2f);
  else spark(sx, 23, 6, 0, CLAY_SLEEP, 2);
  aa::disc(dx, 23, 3.5f, bt::connected() ? BLUE : (l ? DIM : FAINT));

  for (int i = 0; i < PAGES; ++i) {
    int x = 120 + (i - 1) * 14;
    if (i == page) aa::roundRect(x - 8, 285, 16, 6, 3, TEXT);
    else aa::disc(x, 288, 3, FAINT);
  }

  if ((int32_t)(toastUntil - now) > 0) {
    aa::roundRect(30, 128, 180, 40, 14, TEXT);
    centered(120, 154, toastText, fontBody, BG, 170);
  }
}

// ---- Touch: swipe between pages, tap, hold for sound ----
static bool touching = false, swiped = false, held = false;
static int startX, startY, lastX, lastY;
static uint32_t touchAt;

static void pollTouch(uint32_t now) {
  int x, y;
  bool down = touchRead(x, y);
  if (down && !touching) {
    startX = lastX = x;
    startY = lastY = y;
    touchAt = now;
    swiped = held = false;
  }
  if (down) {
    lastX = x;
    lastY = y;
    int dx = x - startX, dy = y - startY;
    if (!swiped && !held && abs(dx) > 34 && abs(dx) > abs(dy)) {
      swiped = true;
      goTo(page + (dx < 0 ? 1 : -1), dx < 0 ? 1 : -1, now);
    }
    if (!swiped && !held && now - touchAt > 1000 && abs(dx) < 14 && abs(dy) < 14) {
      held = true;
      soundOn = !soundOn;
      settings.putBool("sound", soundOn);
      showToast(soundOn ? "Sound on" : "Sound off", 1200);
      if (soundOn) sfx({{988, 60}, {1319, 80}});
    }
  } else if (touching && !swiped && !held && now - touchAt < 500 && abs(lastX - startX) < 16 &&
             abs(lastY - startY) < 16) {
    if (page == 0) face::tap(startX, startY, now);
  }
  touching = down;
}

// ---- Motion: tilt moves the buddy's eyes, a shake makes it dizzy ----
static void pollMotion(uint32_t now) {
  static int16_t px, py, pz;
  static float shakeScore = 0;
  static uint32_t lastRead = 0;
  int16_t ax, ay, az;
  if (now - lastRead < 30 || !accelRead(ax, ay, az)) return;
  lastRead = now;
  face::tilt(constrain(-ax / 600.0f, -1.0f, 1.0f), constrain(-ay / 600.0f, -1.0f, 1.0f));
  int jerk = abs(ax - px) + abs(ay - py) + abs(az - pz);
  px = ax; py = ay; pz = az;
  shakeScore = shakeScore * 0.85f + (jerk > 900 ? jerk : 0);
  if (shakeScore > 5000) {
    shakeScore = 0;
    face::shake(now);
  }
}

// ---- Demo ----
static void demoTick(uint32_t now) {
  if (!demo || now - demoAt < 7000) return;
  demoAt = now;
  static const char* const steps[] = {
      "S|1|42|2|diy-pet|Editing buddy/face.cpp",
      "S|2|5|2|diy-pet|Needs permission: Bash",
      "S|1|3|2|diy-pet|Running: ./pet.sh flash",
      "S|3|1|2|diy-pet|Finished in 6m 12s",
      "S|0|300|2|diy-pet|",
  };
  handleMessage(steps[demoStep++ % 5]);
}

static void startDemo() {
  demo = true;
  demoStep = 0;
  demoAt = 0;
  handleMessage("T|1762862400|19800|1|Demo MacBook");
  handleMessage("U|1|42|175|28|8460|Pro|20|");
  handleMessage("D|23|187|9|842|61234|0,0,0,0,0,0,0,0,2,14,30,22,8,0,12,40,35,28,9,0,0,0,0,0|diy-pet");
  handleMessage("A|12:38|Read main.cpp");
  handleMessage("A|12:40|Edit face.cpp");
  handleMessage("A|12:41|Bash: ./pet.sh build");
}

// ---- Console ----
static void handleLine(const char* line) {
  if (handleMessage(line)) {
    Serial.println("ok");
  } else if (!strncmp(line, "page ", 5)) {
    int p = atoi(line + 5) - 1;
    goTo(p, p > page ? 1 : -1, millis());
  } else if (!strcmp(line, "demo")) {
    startDemo();
    Serial.println("demo on (any message from a Mac keeps the data; 'demo off' stops cycling)");
  } else if (!strcmp(line, "demo off")) {
    demo = false;
  } else if (!strcmp(line, "sound")) {
    soundOn = !soundOn;
    Serial.printf("sound %s\n", soundOn ? "on" : "off");
  } else if (!strcmp(line, "status")) {
    Serial.printf("page=%d ble=%d mood=%d detail='%s' usage=%d/%d%% %d/%d%% clock=%d host='%s'\n", page + 1,
                  bt::connected(), (int)activity.mood, activity.detail, usage.known, usage.session, usage.ok,
                  usage.week, clockKnown(), hostName);
  } else if (!strcmp(line, "shot")) {
    // Raw RGB565, little-endian, row by row (tools/screenshot.py).
    uint32_t now = millis();
    drawPage(page, now);
    drawChrome(now);
    size_t bytes = LCD_W * LCD_H * 2;
    Serial.printf("SHOT %u %u %u\n", LCD_W, LCD_H, (unsigned)bytes);
    Serial.write((const uint8_t*)fb->getBuffer(), bytes);
    Serial.println();
  } else {
    Serial.println("commands: page 1|2|3, demo, demo off, sound, status, shot, or a protocol line (PROTOCOL.md)");
  }
}

static void handleSerial() {
  static char line[300];
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

static void pollBluetooth() {
  char msg[bt::MAX_MESSAGE];
  for (int i = 0; i < 12 && bt::receive(msg, sizeof(msg)); ++i) {
    if (demo) demo = false;  // a real Mac takes over
    handleMessage(msg);
  }
}

// Sounds and the page jump when Claude's mood changes.
static void watchMood(uint32_t now) {
  static Mood last = Mood::Idle;
  static bool lastKnown = false;
  if (!activity.known) return;
  Mood m = activity.mood;
  if (lastKnown && m == last) return;
  face::moodChanged(lastKnown ? last : Mood::Idle, m, now);
  if (lastKnown && (m == Mood::Waiting || m == Mood::Done) && page != 0) goTo(0, -1, now);
  last = m;
  lastKnown = true;
}

void setup() {
  Serial.begin(115200);
  if (!board::begin()) {
    for (;;) { Serial.println("framebuffer alloc failed - is PSRAM=opi set?"); delay(1000); }
  }
  oldFrame = (uint16_t*)ps_malloc(LCD_W * LCD_H * 2);
  newFrame = (uint16_t*)ps_malloc(LCD_W * LCD_H * 2);
  midKey.begin();
  bt::begin();
  settings.begin("buddy", false);
  page = constrain(settings.getUChar("page", 0), 0, PAGES - 1);
  soundOn = settings.getBool("sound", true);
  Serial.println("claude buddy booted");
  if (soundOn) sfx({{523, 70}, {784, 70}, {1047, 120}});
}

void loop() {
  uint32_t now = millis();
  handleSerial();
  pollBluetooth();
  pollTouch(now);
  pollMotion(now);
  demoTick(now);
  watchMood(now);

  bool upPressed = false, downPressed = false;
  static Button up = volumeUp(), down = volumeDown();
  upPressed = pressed(up, now);
  downPressed = pressed(down, now);
  if (upPressed) goTo(page + 1, 1, now);
  if (downPressed) goTo(page - 1, -1, now);
  if (midKey.poll(now) == MiddleKey::Event::Hold) {
    sfx({{784, 100}, {523, 100}, {392, 220}});
    fb->fillScreen(BG);
    centered(120, 150, "Bye for now", fontTitle, TEXT);
    lcdPush();
    delay(600);
    powerOff();  // returns only on USB power
    showToast("On USB power", 2000);
  }

  drawPage(page, now);
  if (slideDir && oldFrame && newFrame) composeSlide(now);
  drawChrome(now);
  lcdPushAsync();
}

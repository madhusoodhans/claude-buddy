// Pip — a DIY virtual pet for the Cheeko Gotchi v1.2 (ESP32-S3).
//
// Controls:
//   tap the pet      pet it (hearts, happy chirp)
//   tap elsewhere    Pip looks where you tapped
//   + button         feed
//   - button         play
//   hold on Pip ~1s  sleep (tap to wake)
//   shake            Pip gets dizzy
//   tilt             Pip's eyes follow the tilt
//
// Buttons, power-off and the console are handled by main.cpp, which calls in
// through pip::app. Pip's needs keep decaying while another app is shown.

#include <Arduino.h>
#include <Preferences.h>
#include <cheeko_board.h>

#include "app.h"

namespace pip {

using namespace board;

// ---- Colours (RGB565) ----
static constexpr uint16_t C_BG = rgb(28, 36, 64);
static constexpr uint16_t C_NIGHT = rgb(10, 12, 28);
static constexpr uint16_t C_GROUND = rgb(40, 52, 88);
static constexpr uint16_t C_SHADOW = rgb(18, 22, 44);
static constexpr uint16_t C_BODY = rgb(120, 220, 170);
static constexpr uint16_t C_BODY_DARK = rgb(70, 160, 120);
static constexpr uint16_t C_CHEEK = rgb(255, 140, 160);
static constexpr uint16_t C_INK = rgb(20, 24, 36);
static constexpr uint16_t C_WHITE = rgb(255, 255, 255);
static constexpr uint16_t C_MOUTH = rgb(150, 40, 60);
static constexpr uint16_t C_HEART = rgb(255, 80, 110);
static constexpr uint16_t C_GOLD = rgb(255, 210, 80);
static constexpr uint16_t C_COOKIE = rgb(210, 150, 80);
static constexpr uint16_t C_CHOC = rgb(90, 50, 30);
static constexpr uint16_t C_TEXT = rgb(200, 210, 235);
static constexpr uint16_t C_DIM = rgb(110, 120, 150);
static constexpr uint16_t C_GOOD = rgb(110, 220, 120);
static constexpr uint16_t C_WARN = rgb(255, 200, 70);
static constexpr uint16_t C_BAD = rgb(255, 90, 80);


static void sfxBoot()   { sfx({{1047, 80}, {1319, 80}, {1568, 140}}); }
static void sfxPet()    { sfx({{1319, 60}, {1568, 60}, {2093, 90}}); }
static void sfxEat()    { sfx({{523, 50}, {0, 40}, {523, 50}, {0, 40}, {659, 90}}); }
static void sfxPlay()   { sfx({{784, 70}, {988, 70}, {1175, 70}, {1568, 120}}); }
static void sfxSleep()  { sfx({{784, 120}, {659, 120}, {523, 220}}); }
static void sfxWake()   { sfx({{523, 80}, {784, 80}, {1047, 120}}); }
static void sfxDizzy()  { sfx({{600, 40}, {500, 40}, {400, 40}, {300, 70}}); }
static void sfxWhine()  { sfx({{440, 150}, {415, 260}}); }
static void sfxNope()   { sfx({{330, 80}, {0, 40}, {262, 120}}); }

// ============================================================================
// Pet state
// ============================================================================

struct PetState {
  float food = 80, fun = 80, energy = 80;  // 0..100, higher is better
  bool asleep = false;
  uint32_t ageMinutes = 0;
};

enum class Action { None, Eat, Play, Pet, Dizzy };

static PetState pet;
static Action action = Action::None;
static uint32_t actionStart = 0, actionUntil = 0;
static Preferences prefs;

static char bubbleText[24] = "";
static uint32_t bubbleUntil = 0;

static float lookX = 0, lookY = 0;      // -1..1, where the pupils point
static int lookTapX = -1, lookTapY = -1;
static uint32_t lookTapUntil = 0;
static float tiltX = 0, tiltY = 0;

static uint32_t nextBlink = 3000, blinkUntil = 0;
static bool logTouch = false;

static void say(const char* text, uint32_t ms = 1800) {
  strlcpy(bubbleText, text, sizeof(bubbleText));
  bubbleUntil = millis() + ms;
}

static void startAction(Action a, uint32_t ms) {
  action = a;
  actionStart = millis();
  actionUntil = actionStart + ms;
}

static float clamp100(float v) { return v < 0 ? 0 : (v > 100 ? 100 : v); }

static void savePet() {
  prefs.putFloat("food", pet.food);
  prefs.putFloat("fun", pet.fun);
  prefs.putFloat("energy", pet.energy);
  prefs.putBool("asleep", pet.asleep);
  prefs.putUInt("age", pet.ageMinutes);
}

static void loadPet() {
  pet.food = prefs.getFloat("food", 80);
  pet.fun = prefs.getFloat("fun", 80);
  pet.energy = prefs.getFloat("energy", 80);
  pet.asleep = prefs.getBool("asleep", false);
  pet.ageMinutes = prefs.getUInt("age", 0);
}

// ---- Particles (hearts, Zs, crumbs, sparkles) ----
enum class Fx : uint8_t { Heart, Zee, Crumb, Sparkle };
struct Particle { Fx type; float x, y, vx, vy; uint32_t born, life; };
static Particle particles[20];
static int particleCount = 0;

static void spawn(Fx type, float x, float y, float vx, float vy, uint32_t life) {
  if (particleCount >= (int)(sizeof(particles) / sizeof(particles[0]))) return;
  particles[particleCount++] = {type, x, y, vx, vy, millis(), life};
}

// ============================================================================
// Interactions
// ============================================================================

static void wakeUp() {
  pet.asleep = false;
  sfxWake();
  say("good morning!");
  savePet();
}

static void feed() {
  if (pet.asleep) { wakeUp(); return; }
  if (pet.food > 92) { sfxNope(); say("I'm full!"); return; }
  pet.food = clamp100(pet.food + 25);
  startAction(Action::Eat, 1600);
  sfxEat();
}

static void play() {
  if (pet.asleep) { wakeUp(); return; }
  if (pet.energy < 15) { sfxNope(); say("too sleepy..."); return; }
  pet.fun = clamp100(pet.fun + 20);
  pet.energy = clamp100(pet.energy - 8);
  pet.food = clamp100(pet.food - 4);
  startAction(Action::Play, 2000);
  sfxPlay();
}

static void toggleSleep() {
  if (pet.asleep) { wakeUp(); return; }
  pet.asleep = true;
  action = Action::None;
  sfxSleep();
  savePet();
}

static void petIt() {
  if (pet.asleep) { wakeUp(); return; }
  pet.fun = clamp100(pet.fun + 6);
  startAction(Action::Pet, 1200);
  sfxPet();
  for (int i = 0; i < 4; ++i) spawn(Fx::Heart, 90 + random(60), 120, random(-10, 10) / 10.0f, -40 - random(30), 1300);
}

static void getDizzy() {
  if (pet.asleep || action == Action::Dizzy) return;
  pet.fun = clamp100(pet.fun - 3);
  startAction(Action::Dizzy, 2600);
  sfxDizzy();
}

// ---- Input polling ----
static void drawGoodbye() {
  savePet();
  fb->fillScreen(C_NIGHT);
  centerText(120, "bye bye!", C_TEXT, 2);
  centerText(150, "press the middle button", C_DIM);
  centerText(164, "to turn me back on", C_DIM);
}

static bool touchWasDown = false;
static bool holdOnPip = false;  // finger went down on Pip and hasn't lifted
static uint32_t touchDownAt = 0;
static int petCx = 120, petCy = 180;  // where Pip was last drawn, for hit-testing

// Tap Pip: pet it (or wake it). Hold on Pip ~1s: sleep. Tap elsewhere: Pip looks.
// (Sleep isn't on the middle button: that one is wired into the power circuit.)
static void pollTouch(uint32_t now) {
  int x, y;
  bool down = touchRead(x, y);
  if (down && !touchWasDown) {
    if (logTouch) Serial.printf("touch x=%d y=%d\n", x, y);
    touchDownAt = now;
    bool onPip = abs(x - petCx) < 56 && abs(y - petCy) < 54;  // Pip's body only
    holdOnPip = onPip && !pet.asleep;  // a touch that wakes Pip doesn't also put it back to sleep
    if (onPip) {
      petIt();
    } else {
      lookTapX = x;
      lookTapY = y;
      lookTapUntil = now + 1500;
    }
  }
  if (down && holdOnPip && !pet.asleep && now - touchDownAt > 1000) {
    holdOnPip = false;  // once per touch
    toggleSleep();
  }
  if (!down) holdOnPip = false;
  touchWasDown = down;
}

static int16_t prevAx, prevAy, prevAz;
static float shakeScore = 0;

static void pollMotion() {
  if (!accelOk) return;
  int16_t ax, ay, az;
  if (!accelRead(ax, ay, az)) return;
  tiltX = constrain(-ax / 600.0f, -1.0f, 1.0f);
  tiltY = constrain(-ay / 600.0f, -1.0f, 1.0f);
  int jerk = abs(ax - prevAx) + abs(ay - prevAy) + abs(az - prevAz);
  prevAx = ax; prevAy = ay; prevAz = az;
  shakeScore = shakeScore * 0.85f + (jerk > 900 ? jerk : 0);
  if (shakeScore > 5000) { shakeScore = 0; getDizzy(); }
}

static bool command(const char* line) {
  if (!strcmp(line, "stats")) {
    Serial.printf("food=%.1f fun=%.1f energy=%.1f asleep=%d age=%um tilt=%.2f,%.2f audio=%d accel=%d\n",
                  pet.food, pet.fun, pet.energy, pet.asleep, pet.ageMinutes, tiltX, tiltY, audioOk, accelOk);
  } else if (!strcmp(line, "reset")) {
    pet = PetState();
    savePet();
    Serial.println("pet reset");
  } else if (!strcmp(line, "touch")) {
    logTouch = !logTouch;
    Serial.printf("touch logging %s\n", logTouch ? "on" : "off");
  } else if (!strcmp(line, "adc")) {
    // GPIO18 is the only ADC-capable pin the pin map leaves unused; probing for a battery divider.
    Serial.printf("gpio18=%umV\n", analogReadMilliVolts(18));
  } else if (!strcmp(line, "feed")) { feed();
  } else if (!strcmp(line, "play")) { play();
  } else if (!strcmp(line, "pet"))  { petIt();
  } else if (!strcmp(line, "sleep")) { toggleSleep();
  } else if (!strcmp(line, "dizzy")) { getDizzy();
  } else {
    return false;
  }
  return true;
}

// ---- Needs decay, once per second ----
static uint32_t lastTick = 0, lastSave = 0, secondsAlive = 0;
static bool whinedHungry = false;

// quiet: Pip isn't on screen, so no sounds or speech bubbles.
static void updateNeeds(uint32_t now, bool quiet) {
  if (now - lastTick < 1000) return;
  lastTick = now;
  const float perSec = 1.0f / 60.0f;
  if (pet.asleep) {
    pet.energy = clamp100(pet.energy + 4.0f * perSec);
    pet.food = clamp100(pet.food - 0.5f * perSec);
    if (pet.energy >= 100) {
      if (quiet) pet.asleep = false; else wakeUp();
    }
  } else {
    pet.food = clamp100(pet.food - 1.5f * perSec);
    pet.fun = clamp100(pet.fun - 1.2f * perSec);
    pet.energy = clamp100(pet.energy - 0.6f * perSec);
  }
  if (++secondsAlive % 60 == 0) pet.ageMinutes++;

  if (!quiet && !pet.asleep && pet.food < 25 && !whinedHungry) {
    whinedHungry = true;
    sfxWhine();
    say("I'm hungry...", 2500);
  }
  if (pet.food >= 25) whinedHungry = false;

  if (now - lastSave > 60000) { lastSave = now; savePet(); }
}

// ============================================================================
// Drawing
// ============================================================================

static void thickLine(int x0, int y0, int x1, int y1, uint16_t c) {
  for (int dx = -1; dx <= 1; ++dx)
    for (int dy = -1; dy <= 1; ++dy) fb->drawLine(x0 + dx, y0 + dy, x1 + dx, y1 + dy, c);
}

// Parabolic mouth/brow curve. bend > 0 curves down (smile), < 0 curves up (frown).
static void curve(int cx, int y, int halfW, int bend, int r, uint16_t c) {
  for (int i = -halfW; i <= halfW; ++i) {
    float t = (float)i / halfW;
    fb->fillCircle(cx + i, y + (int)(bend * (1 - t * t)), r, c);
  }
}

static void heart(int x, int y, int s, uint16_t c) {
  fb->fillCircle(x - s, y, s, c);
  fb->fillCircle(x + s, y, s, c);
  fb->fillTriangle(x - 2 * s, y + 1, x + 2 * s, y + 1, x, y + 3 * s, c);
}


static constexpr int METER_W = 58;

static void drawMeter(int x, const char* label, float v) {
  fb->setTextSize(1);
  fb->setTextColor(C_DIM);
  fb->setCursor(x, 12);
  fb->print(label);
  uint16_t col = v > 50 ? C_GOOD : (v > 25 ? C_WARN : C_BAD);
  fb->fillRoundRect(x, 24, METER_W, 9, 4, C_SHADOW);
  int w = (int)(METER_W * v / 100);
  if (w > 3) fb->fillRoundRect(x, 24, w, 9, 4, col);
}

static void drawStatus() {
  // Kept inside SAFE_X: the rounded glass hides the top corners.
  const int gap = (LCD_W - 2 * SAFE_X - 3 * METER_W) / 2;
  drawMeter(SAFE_X, "FOOD", pet.food);
  drawMeter(SAFE_X + METER_W + gap, "FUN", pet.fun);
  drawMeter(SAFE_X + 2 * (METER_W + gap), "ENERGY", pet.energy);
  char age[32];
  if (pet.ageMinutes < 60) snprintf(age, sizeof(age), "Pip  -  age %um", pet.ageMinutes);
  else snprintf(age, sizeof(age), "Pip  -  age %uh %um", pet.ageMinutes / 60, pet.ageMinutes % 60);
  centerText(44, age, C_TEXT);
}

enum class Eyes { Open, Closed, Happy, Dizzy, Sad, Tired };
enum class Mouth { Smile, Frown, Open, Chomp, Small, Wavy };

static void drawEye(int x, int y, Eyes style, uint32_t now) {
  switch (style) {
    case Eyes::Open:
    case Eyes::Sad:
    case Eyes::Tired: {
      fb->fillRoundRect(x - 11, y - 14, 22, 28, 11, C_WHITE);
      int px = x + (int)(lookX * 5);
      int py = y + (int)(lookY * 6) + (style == Eyes::Sad ? 4 : 0);
      fb->fillCircle(px, py, 7, C_INK);
      fb->fillCircle(px + 3, py - 3, 2, C_WHITE);
      if (style == Eyes::Tired) fb->fillRect(x - 11, y - 14, 22, 14, C_BODY);  // heavy lids
      if (style == Eyes::Tired) fb->drawFastHLine(x - 10, y, 20, C_INK);
      break;
    }
    case Eyes::Closed:
      fb->fillRoundRect(x - 10, y - 1, 20, 4, 2, C_INK);
      break;
    case Eyes::Happy:  // ^ shape
      thickLine(x - 9, y + 4, x, y - 5, C_INK);
      thickLine(x, y - 5, x + 9, y + 4, C_INK);
      break;
    case Eyes::Dizzy: {  // spinning X
      float a = now / 120.0f;
      int dx = (int)(9 * cosf(a)), dy = (int)(9 * sinf(a));
      thickLine(x - dx, y - dy, x + dx, y + dy, C_INK);
      thickLine(x + dy, y - dx, x - dy, y + dx, C_INK);
      break;
    }
  }
}

static void drawFace(int cx, int cy, uint32_t now) {
  Eyes eyes = Eyes::Open;
  Mouth mouth = Mouth::Smile;
  bool blush = false, brows = false;

  if (pet.asleep) {
    eyes = Eyes::Closed; mouth = Mouth::Small;
  } else if (action == Action::Eat) {
    eyes = Eyes::Happy; mouth = Mouth::Chomp; blush = true;
  } else if (action == Action::Play) {
    eyes = Eyes::Happy; mouth = Mouth::Open; blush = true;
  } else if (action == Action::Pet) {
    eyes = Eyes::Happy; mouth = Mouth::Smile; blush = true;
  } else if (action == Action::Dizzy) {
    eyes = Eyes::Dizzy; mouth = Mouth::Wavy;
  } else if (pet.food < 25 || pet.fun < 30) {
    eyes = Eyes::Sad; mouth = Mouth::Frown; brows = true;
  } else if (pet.energy < 20) {
    eyes = Eyes::Tired; mouth = Mouth::Small;
  } else if (pet.fun > 75 && pet.food > 50) {
    blush = true;
  }
  if (eyes == Eyes::Open && now < blinkUntil) eyes = Eyes::Closed;

  // turn the whole face toward where Pip is looking
  if (!pet.asleep && action != Action::Dizzy) {
    cx += (int)(lookX * 10);
    cy += (int)(lookY * 6);
  }

  int ey = cy - 10;
  drawEye(cx - 24, ey, eyes, now);
  drawEye(cx + 24, ey, eyes, now);

  if (brows) {
    thickLine(cx - 34, ey - 20, cx - 16, ey - 25, C_INK);
    thickLine(cx + 16, ey - 25, cx + 34, ey - 20, C_INK);
  }
  if (blush) {
    fb->fillCircle(cx - 40, cy + 10, 7, C_CHEEK);
    fb->fillCircle(cx + 40, cy + 10, 7, C_CHEEK);
  }

  int my = cy + 18;
  switch (mouth) {
    case Mouth::Smile: curve(cx, my, 11, 6, 1, C_INK); break;
    case Mouth::Frown: curve(cx, my + 6, 9, -5, 1, C_INK); break;
    case Mouth::Open:
      fb->fillRoundRect(cx - 11, my - 2, 22, 16, 8, C_MOUTH);
      fb->fillRect(cx - 11, my - 2, 22, 5, C_BODY);
      break;
    case Mouth::Chomp:
      if ((now / 180) % 2) fb->fillCircle(cx, my + 4, 8, C_MOUTH);
      else fb->fillRoundRect(cx - 9, my + 2, 18, 4, 2, C_INK);
      break;
    case Mouth::Small: fb->fillCircle(cx, my + 4, 3, C_INK); break;
    case Mouth::Wavy:
      for (int i = -12; i <= 12; ++i) fb->fillCircle(cx + i, my + 4 + (int)(3 * sinf(i * 0.6f)), 1, C_INK);
      break;
  }
}

static void drawCookie(int x, int y, float eaten) {
  fb->fillCircle(x, y, 13, C_COOKIE);
  fb->fillCircle(x - 5, y - 3, 2, C_CHOC);
  fb->fillCircle(x + 4, y + 4, 2, C_CHOC);
  fb->fillCircle(x + 3, y - 6, 2, C_CHOC);
  // bites come out of the left side as the cookie gets eaten
  uint16_t bg = C_BG;
  if (eaten > 0.25f) fb->fillCircle(x - 14, y - 4, 7, bg);
  if (eaten > 0.5f) fb->fillCircle(x - 12, y + 7, 8, bg);
  if (eaten > 0.75f) fb->fillCircle(x - 4, y, 11, bg);
}

static void drawPet(int cx, int cy, uint32_t now) {
  // feet
  fb->fillRoundRect(cx - 42, cy + 40, 28, 14, 7, C_BODY_DARK);
  fb->fillRoundRect(cx + 14, cy + 40, 28, 14, 7, C_BODY_DARK);

  // antenna — sways, tip glows when happy
  int sway = (int)(6 * sinf(now / 300.0f));
  if (action == Action::Dizzy) sway = (int)(14 * sinf(now / 80.0f));
  thickLine(cx, cy - 46, cx + sway, cy - 70, C_BODY_DARK);
  bool glow = !pet.asleep && (action == Action::Pet || action == Action::Play || pet.fun > 75);
  fb->fillCircle(cx + sway, cy - 72, 7, glow ? C_GOLD : C_BODY_DARK);

  // body
  fb->fillRoundRect(cx - 56, cy - 52, 112, 104, 48, C_BODY);
  fb->fillRoundRect(cx - 34, cy + 14, 68, 32, 16, rgb(150, 235, 190));  // belly

  drawFace(cx, cy, now);

  if (action == Action::Eat) {
    float t = (float)(now - actionStart) / (actionUntil - actionStart);
    drawCookie(cx + 30, cy + 26, t);
    if ((now / 180) % 2 && particleCount < 12) spawn(Fx::Crumb, cx + 18, cy + 30, random(-20, 20), 30, 500);
  }
  if (action == Action::Dizzy) {
    for (int i = 0; i < 3; ++i) {
      float a = now / 250.0f + i * 2.094f;
      fb->fillCircle(cx + (int)(40 * cosf(a)), cy - 62 + (int)(8 * sinf(a)), 4, C_GOLD);
    }
  }
}

static void drawParticles(uint32_t now) {
  int alive = 0;
  for (int i = 0; i < particleCount; ++i) {
    Particle& p = particles[i];
    uint32_t age = now - p.born;
    if (age > p.life) continue;
    float t = age / 1000.0f;
    int x = (int)(p.x + p.vx * t), y = (int)(p.y + p.vy * t);
    switch (p.type) {
      case Fx::Heart: heart(x, y, 4, C_HEART); break;
      case Fx::Crumb: fb->fillCircle(x, y, 2, C_COOKIE); break;
      case Fx::Sparkle: fb->fillCircle(x, y, 2, C_GOLD); break;
      case Fx::Zee:
        fb->setTextSize(1 + age * 2 / p.life);
        fb->setTextColor(C_TEXT);
        fb->setCursor(x, y);
        fb->print('z');
        break;
    }
    particles[alive++] = p;
  }
  particleCount = alive;
}

static void drawBubble(int cx, int cy, uint32_t now) {
  if (now > bubbleUntil || !bubbleText[0]) return;
  int16_t bx, by;
  uint16_t w, h;
  fb->setTextSize(1);
  fb->getTextBounds(bubbleText, 0, 0, &bx, &by, &w, &h);
  int bw = w + 16, bh = 22;
  int x = constrain(cx - bw / 2 + 30, 4, LCD_W - bw - 4);
  int y = max(52, cy - 112);
  fb->fillRoundRect(x, y, bw, bh, 10, C_WHITE);
  fb->fillTriangle(cx + 6, y + bh - 1, cx + 18, y + bh - 1, cx + 6, y + bh + 8, C_WHITE);
  fb->setTextColor(C_INK);
  fb->setCursor(x + 8, y + 7);
  fb->print(bubbleText);
}

static void render(uint32_t now) {
  bool night = pet.asleep;
  fb->fillScreen(night ? C_NIGHT : C_BG);
  if (night) {
    for (int i = 0; i < 14; ++i) {  // twinkling stars
      int sx = (i * 73 + 17) % LCD_W, sy = 56 + (i * 41) % 80;
      if ((now / 400 + i) % 5) fb->drawPixel(sx, sy, C_TEXT);
    }
  }
  fb->fillRect(0, 238, LCD_W, LCD_H - 238, night ? C_SHADOW : C_GROUND);
  drawStatus();

  // vertical motion: idle bob, play bounce, sleepy breathing
  float lift = 3 * sinf(now / 400.0f);
  if (pet.asleep) lift = 2 * sinf(now / 900.0f);
  if (action == Action::Play) lift = -fabsf(sinf((now - actionStart) / 170.0f)) * 38;
  int cx = 120, cy = 180 + (int)lift;
  if (action == Action::Dizzy) cx += (int)(6 * sinf(now / 90.0f));
  petCx = cx;
  petCy = cy;

  int shadowW = 96 + (int)(lift * 0.8f);
  fb->fillRoundRect(cx - shadowW / 2, 230, shadowW, 12, 6, C_SHADOW);

  drawPet(cx, cy, now);
  drawParticles(now);
  drawBubble(cx, cy, now);

  if (pet.asleep) {
    centerText(254, "zzz...", C_DIM);
    centerText(270, "tap me to wake", C_DIM);
  } else {
    centerText(254, "+ feed     - play", C_TEXT);
    static const char* const hints[] = {"tap me!  shake me!", "hold me to sleep", "hold + and - : navigation"};
    centerText(270, hints[(now / 4000) % 3], C_DIM);
  }
}

// ---- Eyes: tap target beats tilt beats idle wander ----
static void updateLook(uint32_t now) {
  float tx, ty;
  if (now < lookTapUntil) {
    tx = constrain((lookTapX - petCx) / 70.0f, -1.0f, 1.0f);
    ty = constrain((lookTapY - petCy) / 70.0f, -1.0f, 1.0f);
  } else if (fabsf(tiltX) > 0.25f || fabsf(tiltY) > 0.25f) {
    tx = tiltX; ty = tiltY;
  } else {
    tx = 0.6f * sinf(now / 2300.0f);
    ty = 0.3f * sinf(now / 3100.0f);
  }
  lookX += (tx - lookX) * 0.2f;
  lookY += (ty - lookY) * 0.2f;

  if (now > nextBlink) {
    blinkUntil = now + 140;
    nextBlink = now + 2500 + random(3000);
  }
}

static uint32_t lastZee = 0;

// ============================================================================
// App hooks
// ============================================================================

static bool greeted = false;

static void init() {
  prefs.begin("pip", false);
  loadPet();
  randomSeed(esp_random());
}

static void enter() {
  sfxBoot();
  say(pet.asleep ? "zzz" : (greeted ? "welcome back!" : "hi! I'm Pip"));
  greeted = true;
}

static void leave() { savePet(); }

static void frame(uint32_t now) {
  pollTouch(now);
  pollMotion();
  updateNeeds(now, false);
  updateLook(now);

  if (action != Action::None && now > actionUntil) action = Action::None;
  if (pet.asleep && now - lastZee > 1200) {
    lastZee = now;
    spawn(Fx::Zee, 150, 120, 12, -30, 2200);
  }
  render(now);
}

static void background(uint32_t now) { updateNeeds(now, true); }

static void noop() {}

const App app = {
    "Pip", init, enter, leave, frame, background,
    feed, play, noop, drawGoodbye, command,
    "stats reset touch adc feed play pet sleep dizzy",
};

}  // namespace pip

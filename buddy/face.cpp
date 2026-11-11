// Page 1: the buddy itself, acting out what Claude is doing on the Mac.
//
//   working   chef hat, chopping arms, sparks orbiting: "Claude is cooking"
//   waiting   hops and waves with a "!" bubble: "Your turn!" (chimes)
//   done      happy eyes, arms up, confetti for a moment (jingle)
//   idle      nightcap, closed eyes, breathing, Zzz
//   no Mac    looks around with a "?"
//
// Tap it to make it giggle, shake the device to make it dizzy, tilt to make
// it look around.

#include <cheeko_board.h>

#include "model.h"
#include "ui.h"

namespace face {

using namespace ui;
using board::sfx;
using board::fb;

enum class Eyes { Open, Closed, Happy, Wide, Dizzy, Focused };
enum class Mouth { Smile, Dot, O, Open, Flat, Grin };

struct Pose {
  float x = 120, y = 150, w = 120, h = 100;
  Eyes eyes = Eyes::Open;
  Mouth mouth = Mouth::Smile;
  float lookX = 0, lookY = 0;  // -1..1
  float blink = 0;             // 0 open .. 1 shut
  float armL = 0.35f, armR = 0.35f;  // radians out from hanging straight down
  bool chefHat = false, nightcap = false, blush = false;
  uint16_t body = CLAY;
};

static float tiltX = 0, tiltY = 0;
static uint32_t giggleUntil = 0, dizzyUntil = 0, moodAt = 0;
static uint32_t blinkAt = 0, nextBlink = 2000;
static uint32_t reminders = 0, lastReminder = 0;
static float hitX = 120, hitY = 150;  // where the body was last drawn

// ---- Drawing the buddy ----

static void drawArm(float sx, float sy, float angle, int side, uint16_t color) {
  const float len = angle > 1.5f ? 32 : 24;  // raised arms reach clear of the body
  float ex = sx + side * sinf(angle) * len, ey = sy + cosf(angle) * len;
  aa::line(sx, sy, ex, ey, 11, color);
}

static void drawEye(float ex, float ey, const Pose& p, int side, float t) {
  switch (p.eyes) {
    case Eyes::Closed:
      arc(ex, ey - 3, 8, 0.15f * PI, 0.85f * PI, 3.5f, INK);
      return;
    case Eyes::Happy:
      arc(ex, ey + 5, 9, 1.15f * PI, 1.85f * PI, 4, INK);
      return;
    case Eyes::Dizzy: {
      float px = ex, py = ey;
      for (int i = 1; i <= 24; ++i) {
        float a = i * 0.65f + t * 9 * side, r = i * 0.42f;
        float x = ex + cosf(a) * r, y = ey + sinf(a) * r;
        aa::line(px, py, x, y, 2.6f, INK);
        px = x;
        py = y;
      }
      return;
    }
    default:
      break;
  }
  bool wide = p.eyes == Eyes::Wide;
  int w = wide ? 18 : 15;
  int h = max(4, (int)((wide ? 30 : 26) * (1 - p.blink)));
  aa::roundRect((int)ex - w / 2, (int)(ey - h / 2), w, h, min(w, h) / 2, INK);
  if (h > 12) {
    aa::disc(ex - w * 0.18f, ey - h / 2 + 6, wide ? 3.2f : 2.6f, TEXT);
    if (wide) aa::disc(ex + 3, ey + h / 2 - 7, 1.6f, TEXT);
  }
  if (p.eyes == Eyes::Focused) {  // determined lids, sloping down toward the nose
    float top = ey - h / 2 - 2;
    aa::triangle(ex - 11, top, ex + 11, top, side < 0 ? ex + 11 : ex - 11, top + 10, p.body);
  }
}

static void drawMouth(float mx, float my, const Pose& p, float t) {
  switch (p.mouth) {
    case Mouth::Smile: arc(mx, my - 4, 7, 0.2f * PI, 0.8f * PI, 3, INK); break;
    case Mouth::Dot: aa::disc(mx, my, 2.5f, INK); break;
    case Mouth::O: aa::disc(mx, my, 4 + sinf(t * 5) * 1.2f, INK); break;
    case Mouth::Open: aa::roundRect((int)mx - 7, (int)my - 4, 14, 10, 4, INK); break;
    case Mouth::Flat: aa::line(mx - 5, my, mx + 5, my + sinf(t * 7) * 1.5f, 3, INK); break;
    case Mouth::Grin:
      aa::disc(mx, my - 2, 8, INK);
      fb->fillRect((int)mx - 9, (int)my - 11, 19, 9, p.body);
      aa::disc(mx, my + 3, 3.2f, BLUSH);
      break;
  }
}

static void drawChefHat(float x, float top) {
  const uint16_t fold = lerp(TEXT, DIM, 0.45f);
  aa::disc(x - 19, top - 20, 13, TEXT);
  aa::disc(x + 19, top - 20, 13, TEXT);
  aa::disc(x, top - 28, 16, TEXT);
  aa::roundRect((int)x - 27, (int)top - 14, 54, 17, 5, TEXT);
  aa::line(x - 9, top - 12, x - 9, top - 4, 1.5f, fold);
  aa::line(x + 9, top - 12, x + 9, top - 4, 1.5f, fold);
}

static void drawNightcap(float x, float top, float t) {
  const uint16_t cap = rgb(72, 92, 156);
  float sway = sinf(t * 1.3f) * 3;
  aa::triangle(x - 36, top + 4, x + 32, top + 2, x + 54 + sway, top - 30, cap);
  aa::disc(x + 54 + sway, top - 30, 7, TEXT);
  aa::roundRect((int)x - 40, (int)top - 4, 78, 12, 6, TEXT);
}

static void drawBuddy(const Pose& p, float t) {
  float top = p.y - p.h / 2, bottom = p.y + p.h / 2;
  hitX = p.x;
  hitY = p.y;

  // feet and arms first: the body covers their joins
  aa::roundRect((int)p.x - 30, (int)bottom - 6, 20, 13, 6, CLAY_DARK);
  aa::roundRect((int)p.x + 10, (int)bottom - 6, 20, 13, 6, CLAY_DARK);
  drawArm(p.x - p.w / 2 + 6, p.y + 4, p.armL, -1, p.body);
  drawArm(p.x + p.w / 2 - 6, p.y + 4, p.armR, 1, p.body);

  aa::roundRect((int)(p.x - p.w / 2), (int)top, (int)p.w, (int)p.h, 32, p.body);
  arc(p.x - p.w / 2 + 30, top + 30, 20, 1.08f * PI, 1.42f * PI, 4, lerp(p.body, TEXT, 0.3f));  // sheen

  float lx = p.lookX * 7, ly = p.lookY * 5;
  drawEye(p.x - 24 + lx, p.y - 8 + ly, p, -1, t);
  drawEye(p.x + 24 + lx, p.y - 8 + ly, p, 1, t);
  if (p.blush) {
    aa::disc(p.x - 38 + lx * 0.5f, p.y + 12, 6, BLUSH);
    aa::disc(p.x + 38 + lx * 0.5f, p.y + 12, 6, BLUSH);
  }
  drawMouth(p.x + lx * 0.6f, p.y + 22 + ly * 0.5f, p, t);

  if (p.chefHat) drawChefHat(p.x, top);
  if (p.nightcap) drawNightcap(p.x, top, t);
}

// ---- Moods ----

static void drawZzz(float x, float top, float t) {
  for (int i = 0; i < 3; ++i) {
    float ph = fmodf(t / 3.6f + i / 3.0f, 1.0f);
    float zx = x + 66 + ph * 26 + sinf(ph * 7) * 4, zy = top - 4 - ph * 40;
    uint16_t c = lerp(TEXT, BG, ph * ph);
    aa::text((int)zx, (int)zy, i % 2 ? "z" : "Z", i % 2 ? fontBody : fontTitle, c);
  }
}

static void drawBubble(float x, float y, float t) {
  float pulse = sinf(t * 6) * 1.5f;
  aa::triangle(x - 12, y + 8, x - 2, y + 14, x - 24, y + 26, AMBER);
  aa::roundRect((int)(x - 17 - pulse), (int)(y - 18 - pulse), (int)(34 + 2 * pulse), (int)(36 + 2 * pulse), 13, AMBER);
  aa::text((int)x, (int)y + 8, "!", fontTitle, INK, aa::Align::Center);
}

static void drawOrbitSparks(float x, float y, float t) {
  for (int i = 0; i < 3; ++i) {
    float a = t * 1.3f + i * 2 * PI / 3;
    float sx = x + cosf(a) * 90, sy = y - 4 + sinf(a) * 46;
    spark(sx, sy, 6 + sinf(t * 4 + i) * 1.5f, t * 3 + i, lerp(CLAY, TEXT, 0.35f + 0.3f * sinf(t * 3 + i)));
  }
}

static void drawConfetti(float x, float y, float sinceDone, float t) {
  static const uint16_t colors[] = {CLAY, AMBER, GREEN, BLUE, TEXT, BLUSH};
  for (int i = 0; i < 8; ++i) {
    float a = i * PI / 4 + 0.3f;
    if (sinceDone < 1.6f) {  // burst outward
      float d = 40 + sinceDone * 70;
      spark(x + cosf(a) * d, y + sinf(a) * d * 0.7f, 5, t * 4, colors[i % 6]);
    } else if (i % 2 == 0) {  // then a few twinkle in place
      float tw = 0.5f + 0.5f * sinf(t * 3 + i);
      spark(x + cosf(a) * 92, y + sinf(a) * 60, 3 + tw * 4, 0, lerp(BG, colors[i % 6], tw));
    }
  }
}

static void statusText(const char* title, uint16_t titleColor, const char* detail, const char* meta, bool dots, float t) {
  if (dots) {  // "Claude is cooking..." with the dots ticking, title not jumping around
    int w = aa::textWidth(title, fontTitle) + aa::textWidth("...", fontTitle);
    int x = aa::text(120 - w / 2, 234, title, fontTitle, titleColor);
    int n = (int)(t * 2.5f) % 4;
    char d[4] = "...";
    d[n] = 0;
    aa::text(x, 234, d, fontTitle, titleColor);
  } else {
    centered(120, 234, title, fontTitle, titleColor, 208);
  }
  if (detail && *detail) centered(120, 254, detail, fontSmall, TEXT, 204);
  if (meta && *meta) centered(120, 271, meta, fontTiny, DIM, 170);
}

void draw(uint32_t now, bool linked) {
  float t = now / 1000.0f;
  Pose p;
  p.x += tiltX * 4;
  p.lookX = constrain(tiltX * 0.9f, -1.0f, 1.0f);
  p.lookY = constrain(tiltY * 0.7f, -1.0f, 1.0f);

  if (now - blinkAt > nextBlink) {
    blinkAt = now;
    nextBlink = 2200 + random(3000);
  }
  uint32_t sinceBlink = now - blinkAt;
  p.blink = sinceBlink < 140 ? sinf(sinceBlink / 140.0f * PI) : 0;

  char detail[72] = "", meta[64] = "", dur[16];
  uint32_t inMood = activity.known ? (now - activity.since) / 1000 : 0;
  formatDuration(inMood, dur, sizeof(dur));
  Mood mood = activity.known ? activity.mood : Mood::Idle;

  if (!linked) {
    p.body = lerp(CLAY, BG, 0.25f);
    p.lookX = sinf(t * 0.9f);
    p.mouth = Mouth::Flat;
    drawBuddy(p, t);
    aa::text((int)p.x + 58, (int)(p.y - 54 + sinf(t * 2) * 4), "?", fontTitle, DIM);
    statusText("Looking for your Mac", DIM, "Open Claude Buddy on a Mac", nullptr, false, t);
    return;
  }

  switch (mood) {
    case Mood::Working: {
      p.y += sinf(t * 2 * PI * 1.6f) * 3;
      p.eyes = Eyes::Focused;
      p.lookX += sinf(t * 0.7f) * 0.6f;
      p.lookY += 0.3f;
      p.mouth = Mouth::O;
      p.armL = 0.6f + 0.6f * max(0.0f, sinf(t * 10));
      p.armR = 0.6f + 0.6f * max(0.0f, sinf(t * 10 + PI));
      p.chefHat = true;
      drawOrbitSparks(p.x, p.y, t);
      strlcpy(detail, activity.detail[0] ? activity.detail : "Thinking", sizeof(detail));
      snprintf(meta, sizeof(meta), "%s%s%s", activity.project, activity.project[0] ? "  -  " : "", dur);
      break;
    }
    case Mood::Waiting:
      p.y -= fabsf(sinf(t * PI * 1.1f)) * 7;
      p.eyes = Eyes::Wide;
      p.mouth = Mouth::Open;
      p.armR = 2.45f + 0.45f * sinf(t * 9);
      break;
    case Mood::Done: {
      float since = (now - moodAt) / 1000.0f;
      if (since < 3) p.y -= fabsf(sinf(since * PI * 1.6f)) * 10;
      p.eyes = Eyes::Happy;
      p.mouth = Mouth::Grin;
      p.blush = true;
      p.armL = p.armR = since < 4 ? 2.6f + 0.25f * sinf(t * 7) : 0.4f;
      drawConfetti(p.x, p.y, since, t);
      break;
    }
    case Mood::Idle: {
      float breath = sinf(t * 2 * PI / 4.2f);
      p.h = 100 + breath * 3;
      p.w = 120 - breath * 1.5f;
      p.y += (100 - p.h) / 2;
      p.body = CLAY_SLEEP;
      p.eyes = Eyes::Closed;
      p.mouth = Mouth::Dot;
      p.armL = p.armR = 0.25f;
      p.nightcap = true;
      p.lookX = p.lookY = 0;
      break;
    }
  }

  // Local reactions override the mood's face for a moment.
  if ((int32_t)(dizzyUntil - now) > 0) {
    p.eyes = Eyes::Dizzy;
    p.mouth = Mouth::Flat;
    p.x += sinf(t * 8) * 5;
  } else if ((int32_t)(giggleUntil - now) > 0) {
    float g = (giggleUntil - now) / 1200.0f;
    p.eyes = Eyes::Happy;
    p.mouth = Mouth::Grin;
    p.blush = true;
    p.h *= 1 - 0.07f * sinf(g * PI * 6);
    p.w *= 1 + 0.05f * sinf(g * PI * 6);
  }

  drawBuddy(p, t);

  switch (mood) {
    case Mood::Working:
      statusText("Claude is cooking", CLAY, detail, meta, true, t);
      break;
    case Mood::Waiting:
      drawBubble(p.x + 66, p.y - 62, t);
      snprintf(meta, sizeof(meta), "%s%swaiting %s", activity.project, activity.project[0] ? "  -  " : "", dur);
      statusText("Your turn!", lerp(AMBER, TEXT, 0.25f + 0.25f * sinf(t * 4)),
                 activity.detail[0] ? activity.detail : "Claude needs your input", meta, false, t);
      if (inMood > 60 && reminders < 3 && now - lastReminder > 60000) {  // nudge, gently
        ++reminders;
        lastReminder = now;
        if (soundOn) sfx({{880, 70}, {0, 40}, {1175, 110}});
      }
      break;
    case Mood::Done:
      statusText("All done!", GREEN, activity.detail[0] ? activity.detail : "Ready for the next one",
                 activity.project, false, t);
      break;
    case Mood::Idle:
      drawZzz(p.x, p.y - p.h / 2, t);
      if (activity.sessions > 0)
        snprintf(meta, sizeof(meta), "%d session%s open  -  idle %s", activity.sessions,
                 activity.sessions == 1 ? "" : "s", dur);
      else
        strlcpy(meta, "No Claude sessions open", sizeof(meta));
      statusText("Claude is napping", lerp(CLAY, DIM, 0.4f), activity.project[0] ? activity.project : hostName,
                 meta, false, t);
      break;
  }
}

bool tap(int x, int y, uint32_t now) {
  if (fabsf(x - hitX) > 70 || fabsf(y - hitY) > 66) return false;
  giggleUntil = now + 1200;
  if (soundOn) sfx({{1319, 40}, {1568, 40}, {1319, 40}, {1760, 70}});
  return true;
}

void shake(uint32_t now) {
  if ((int32_t)(dizzyUntil - now) > 0) return;
  dizzyUntil = now + 2500;
  if (soundOn) sfx({{700, 60}, {600, 60}, {500, 60}, {400, 120}});
}

void tilt(float x, float y) {
  tiltX = tiltX * 0.8f + x * 0.2f;
  tiltY = tiltY * 0.8f + y * 0.2f;
}

void moodChanged(Mood from, Mood to, uint32_t now) {
  moodAt = now;
  reminders = 0;
  lastReminder = now;
  if (!soundOn) return;
  if (to == Mood::Waiting) sfx({{880, 90}, {0, 40}, {1175, 140}});
  else if (to == Mood::Done) sfx({{784, 80}, {988, 80}, {1319, 170}});
  else if (to == Mood::Working && from != Mood::Working) sfx({{660, 35}, {990, 45}});
}

}  // namespace face

// What the Mac told us (PROTOCOL.md), plus the clock it set.

#pragma once

#include <Arduino.h>

enum class Mood : uint8_t { Idle, Working, Waiting, Done };

// One bar on the usage page. The Mac decides what they are: a 5-hour session and
// a weekly limit for most plans, the weekly one alone, or an organisation's spend cap.
struct Meter {
  char label[24] = "";
  int pct = 0;
  int pace = -1;  // how much of the window has gone by, in 1/1000, -1 = unknown
  char reset[28] = "";  // "Resets in 2h 54m", "Resets Dec 1", "Not started"
};

struct Usage {
  bool known = false;  // a U message arrived
  bool ok = false;
  int count = 0;  // meters (0..2)
  Meter meters[2];
  char plan[16] = "";
  char note[48] = "";
  uint32_t at = 0;  // millis() of the reading (age already subtracted)
};

struct Activity {
  bool known = false;
  Mood mood = Mood::Idle;
  uint32_t since = 0;  // millis() when this mood started
  int sessions = 0;
  char project[32] = "";
  char detail[64] = "";
};

struct Today {
  bool known = false;
  int prompts = 0, tools = 0, files = 0, lines = 0;
  uint32_t tokens = 0;
  uint16_t hours[24] = {};
  char top[32] = "";
};

struct FeedLine {
  char time[6];
  char text[48];
};

constexpr int FEED_MAX = 4;

extern Usage usage;
extern Activity activity;
extern Today today;
extern FeedLine feed[FEED_MAX];  // oldest first
extern int feedLen;
extern char hostName[32];
extern uint32_t lastMessageAt;  // millis(), 0 = never

// Applies one protocol line. False if it isn't one.
bool handleMessage(const char* line);

// Wall clock from the last T message.
bool clockKnown();
// Local time of day; false until a T message arrived.
bool localTime(int& hour, int& minute, int& second);
bool clock24h();

// "<1m", "12m", "3h 05m", "2d 4h"
void formatDuration(uint32_t seconds, char* out, size_t size);

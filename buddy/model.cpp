#include "model.h"

Usage usage;
Activity activity;
Today today;
FeedLine feed[FEED_MAX];
int feedLen = 0;
char hostName[32] = "";
uint32_t lastMessageAt = 0;

static bool haveClock = false;
static bool use24h = true;
static int64_t localEpochAtBoot = 0;  // local seconds since 1970 when millis() was 0

// Splits s in place on '|'. Returns the field count.
static int split(char* s, char** fields, int max) {
  int n = 0;
  fields[n++] = s;
  for (char* p = s; *p && n < max; ++p)
    if (*p == '|') {
      *p = 0;
      fields[n++] = p + 1;
    }
  return n;
}

bool handleMessage(const char* line) {
  static char buf[300];
  strlcpy(buf, line, sizeof(buf));
  char* f[32];
  int n = split(buf, f, 32);
  if (strlen(f[0]) != 1) return false;
  uint32_t now = millis();

  switch (f[0][0]) {
    case 'T':
      if (n < 5) return false;
      localEpochAtBoot = atoll(f[1]) + atol(f[2]) - now / 1000;
      use24h = atoi(f[3]) != 0;
      strlcpy(hostName, f[4], sizeof(hostName));
      haveClock = true;
      break;
    case 'U':
      if (n < 5) return false;
      usage.known = true;
      usage.ok = atoi(f[1]) != 0;
      usage.at = now - (uint32_t)max(0, atoi(f[2])) * 1000;
      strlcpy(usage.plan, f[3], sizeof(usage.plan));
      strlcpy(usage.note, f[4], sizeof(usage.note));
      usage.count = 0;
      for (int i = 5; i < n && usage.count < 2; ++i) {  // label;pct;pace;reset
        char* m[4];
        int k = 0;
        m[k++] = f[i];
        for (char* p = f[i]; *p && k < 4; ++p)
          if (*p == ';') { *p = 0; m[k++] = p + 1; }
        if (k < 4) continue;
        Meter& meter = usage.meters[usage.count++];
        strlcpy(meter.label, m[0], sizeof(meter.label));
        meter.pct = atoi(m[1]);
        meter.pace = atoi(m[2]);
        strlcpy(meter.reset, m[3], sizeof(meter.reset));
      }
      break;
    case 'S': {
      if (n < 6) return false;
      Mood mood = (Mood)constrain(atoi(f[1]), 0, 3);
      activity.known = true;
      activity.mood = mood;
      activity.since = now - (uint32_t)max(0, atoi(f[2])) * 1000;
      activity.sessions = atoi(f[3]);
      strlcpy(activity.project, f[4], sizeof(activity.project));
      strlcpy(activity.detail, f[5], sizeof(activity.detail));
      break;
    }
    case 'A':
      if (n < 3) return false;
      if (feedLen == FEED_MAX) {
        memmove(feed, feed + 1, sizeof(FeedLine) * (FEED_MAX - 1));
        --feedLen;
      }
      strlcpy(feed[feedLen].time, f[1], sizeof(feed[0].time));
      strlcpy(feed[feedLen].text, f[2], sizeof(feed[0].text));
      ++feedLen;
      break;
    case 'D': {
      if (n < 8) return false;
      today.known = true;
      today.prompts = atoi(f[1]);
      today.tools = atoi(f[2]);
      today.files = atoi(f[3]);
      today.lines = atoi(f[4]);
      today.tokens = strtoul(f[5], nullptr, 10);
      char* p = f[6];
      for (int h = 0; h < 24; ++h) {
        today.hours[h] = strtoul(p, &p, 10);
        if (*p == ',') ++p;
      }
      strlcpy(today.top, f[7], sizeof(today.top));
      break;
    }
    default:
      return false;
  }
  lastMessageAt = now ? now : 1;
  return true;
}

bool clockKnown() { return haveClock; }
bool clock24h() { return use24h; }

bool localTime(int& hour, int& minute, int& second) {
  if (!haveClock) return false;
  int64_t t = localEpochAtBoot + millis() / 1000;
  int daySec = (int)(t % 86400);
  hour = daySec / 3600;
  minute = daySec / 60 % 60;
  second = daySec % 60;
  return true;
}

void formatDuration(uint32_t s, char* out, size_t size) {
  if (s < 60) snprintf(out, size, "<1m");
  else if (s < 3600) snprintf(out, size, "%um", (unsigned)(s / 60));
  else if (s < 86400) snprintf(out, size, "%uh %02um", (unsigned)(s / 3600), (unsigned)(s / 60 % 60));
  else snprintf(out, size, "%ud %uh", (unsigned)(s / 86400), (unsigned)(s / 3600 % 24));
}

// Page 3: Claude's day. Lines written, prompts, tool calls and tokens since
// midnight, a 24-hour activity chart, and the latest things it did.

#include <cheeko_board.h>

#include "model.h"
#include "ui.h"

namespace day {

using namespace ui;

static void compact(uint32_t v, char* out, size_t size) {
  if (v >= 1000000) snprintf(out, size, "%.1fM", v / 1e6f);
  else if (v >= 10000) snprintf(out, size, "%uk", (unsigned)(v / 1000));
  else if (v >= 1000) snprintf(out, size, "%.1fk", v / 1e3f);
  else snprintf(out, size, "%u", (unsigned)v);
}

static void tile(int x, int y, uint32_t value, const char* label) {
  char buf[16];
  compact(value, buf, sizeof(buf));
  aa::roundRect(x, y, 68, 46, 12, CARD);
  aa::text(x + 34, y + 25, buf, fontTitle, TEXT, aa::Align::Center);
  aa::text(x + 34, y + 39, label, fontTiny, DIM, aa::Align::Center);
}

void draw(uint32_t now, bool linked) {
  char buf[64];
  aa::text(16, 64, "Today", fontBody, TEXT);
  if (today.top[0]) {
    aa::fit(today.top, fontSmall, 130, buf, sizeof(buf));
    aa::text(224, 64, buf, fontSmall, CLAY, aa::Align::Right);
  }

  if (!today.known) {
    centered(120, 150, linked ? "Counting today's work" : "Connect a Mac", fontBody, DIM);
    return;
  }

  // Hero: lines of code written
  snprintf(buf, sizeof(buf), "%d", today.lines);
  int x = aa::text(16, 108, buf, fontBig, TEXT);
  aa::text(x + 6, 96, "lines written", fontSmall, TEXT);
  snprintf(buf, sizeof(buf), "in %d file%s", today.files, today.files == 1 ? "" : "s");
  aa::text(x + 6, 110, buf, fontSmall, DIM);

  tile(12, 120, today.prompts, "prompts");
  tile(86, 120, today.tools, "tool calls");
  tile(160, 120, today.tokens, "tokens out");

  // 24 bars, one per hour; the current hour in Claude's colour
  int hourNow = -1, m, s;
  localTime(hourNow, m, s);
  uint16_t peak = 1;
  for (uint16_t v : today.hours) peak = max(peak, v);
  const int bottom = 222, maxH = 42, bx = 13;
  for (int h = 0; h < 24; ++h) {
    int x0 = bx + h * 9;
    int bh = today.hours[h] ? max(4, today.hours[h] * maxH / peak) : 0;
    uint16_t c = h == hourNow ? CLAY : lerp(CLAY, BG, 0.5f);
    if (bh) aa::roundRect(x0, bottom - bh, 7, bh, 3, c);
    else board::fb->fillRect(x0 + 2, bottom - 2, 3, 2, h == hourNow ? CLAY : FAINT);
  }
  static const int marks[] = {0, 6, 12, 18};
  for (int h : marks) {
    snprintf(buf, sizeof(buf), "%d", h);
    aa::text(bx + h * 9 + 3, 235, buf, fontTiny, DIM, aa::Align::Center);
  }

  // Latest activity, newest at the bottom
  int shown = min(feedLen, 2);
  for (int i = 0; i < shown; ++i) {
    const FeedLine& f = feed[feedLen - shown + i];
    int y = 254 + i * 16;
    int tx = aa::text(26, y, f.time, fontTiny, DIM);
    aa::fit(f.text, fontTiny, 214 - tx - 8, buf, sizeof(buf));
    aa::text(tx + 8, y, buf, fontTiny, i == shown - 1 ? TEXT : DIM);
  }
}

}  // namespace day

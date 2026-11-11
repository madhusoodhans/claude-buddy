// Page 2: plan usage, the 5-hour session window and the weekly one.
// Layout after Clawdmeter's cards. Each bar has a pace marker at how much of
// the window has gone by; the fill is green behind pace, amber ahead, red at 100%.

#include <cheeko_board.h>

#include "model.h"
#include "ui.h"

namespace meters {

using namespace ui;

static void card(int y, const char* label, int pct, int resetMin, int windowMin, bool valid, uint32_t ageSec) {
  const int x = 12, w = 216, h = 102;
  aa::roundRect(x, y, w, h, 14, CARD);

  int pw = aa::textWidth(label, fontSmall) + 18;
  aa::roundRect(x + w - 14 - pw, y + 14, pw, 22, 11, PILL);
  aa::text(x + w - 14 - pw / 2, y + 30, label, fontSmall, TEXT, aa::Align::Center);

  char buf[40];
  if (!valid) {
    aa::text(x + 14, y + 46, "--", fontBig, DIM);
    aa::roundRect(x + 14, y + 58, w - 28, 10, 5, TRACK);
    return;
  }
  snprintf(buf, sizeof(buf), "%d", pct);
  int nx = aa::text(x + 14, y + 46, buf, fontBig, TEXT);
  aa::text(nx + 2, y + 46, "%", fontBody, DIM);

  float elapsed = resetMin >= 0 ? 1.0f - (float)resetMin / windowMin : -1;
  uint16_t fill = GREEN;
  const char* pace = nullptr;
  if (pct >= 100) {
    fill = RED;
    pace = "limit hit";
  } else if (elapsed >= 0 && pct > elapsed * 100 + 5) {
    fill = AMBER;
    pace = "ahead of pace";
  } else if (elapsed >= 0) {
    pace = "on pace";
  }

  const int bx = x + 14, bw = w - 28, by = y + 58;
  aa::roundRect(bx, by, bw, 10, 5, TRACK);
  int fw = constrain(pct, 0, 100) * bw / 100;
  if (fw >= 10) aa::roundRect(bx, by, fw, 10, 5, fill);
  else if (fw > 0) aa::disc(bx + 5, by + 5, 5, fill);
  if (elapsed >= 0) {
    int mx = bx + (int)(constrain(elapsed, 0.0f, 1.0f) * bw);
    board::fb->fillRect(mx - 1, by - 3, 2, 16, TEXT);
  }

  if (resetMin >= 0) {
    char d[16];
    formatDuration(resetMin * 60 - min<uint32_t>(ageSec, resetMin * 60), d, sizeof(d));
    snprintf(buf, sizeof(buf), "Resets in %s", d);
  } else {
    strlcpy(buf, "Not started", sizeof(buf));
  }
  aa::text(x + 14, y + 88, buf, fontSmall, DIM);
  if (pace) aa::text(x + w - 14, y + 88, pace, fontTiny, fill == GREEN ? DIM : fill, aa::Align::Right);
}

void draw(uint32_t now, bool linked) {
  uint32_t age = usage.known ? (now - usage.at) / 1000 : 0;
  bool valid = usage.known && usage.ok;
  card(48, "Session  5h", usage.session, usage.sessionReset, 5 * 60, valid, age);
  card(158, "Weekly", usage.week, usage.weekReset, 7 * 24 * 60, valid, age);

  char line[64];
  if (!usage.known) {
    strlcpy(line, linked ? "Asking Claude for usage" : "Connect a Mac to see usage", sizeof(line));
  } else if (!usage.ok) {
    strlcpy(line, usage.note[0] ? usage.note : "Usage unavailable", sizeof(line));
  } else {
    char d[16];
    formatDuration(age, d, sizeof(d));
    snprintf(line, sizeof(line), "%s%supdated %s ago", usage.plan, usage.plan[0] ? "  -  " : "", d);
  }
  centered(120, 276, line, fontTiny, usage.known && !usage.ok ? AMBER : DIM, 176);
}

}  // namespace meters

// Page 2: plan usage, one card per meter the Mac sends (PROTOCOL.md): usually
// the 5-hour session and the weekly limit; on some plans the weekly one alone;
// on spend-capped Enterprise accounts the organisation's spend limit.
// Layout after Clawdmeter's cards. Each bar has a pace marker at how much of
// the window has gone by; the fill is green behind pace, amber ahead, red at 100%.

#include <cheeko_board.h>

#include "model.h"
#include "ui.h"

namespace meters {

using namespace ui;

static constexpr int CARD_H = 102;

static void card(int y, const Meter* m) {
  const int x = 12, w = 216;
  aa::roundRect(x, y, w, CARD_H, 14, CARD);

  const char* label = m ? m->label : "Usage";
  int pw = aa::textWidth(label, fontSmall) + 18;
  aa::roundRect(x + w - 14 - pw, y + 14, pw, 22, 11, PILL);
  aa::text(x + w - 14 - pw / 2, y + 30, label, fontSmall, TEXT, aa::Align::Center);

  const int bx = x + 14, bw = w - 28, by = y + 58;
  if (!m) {
    aa::text(x + 14, y + 46, "--", fontBig, DIM);
    aa::roundRect(bx, by, bw, 10, 5, TRACK);
    return;
  }
  char buf[16];
  snprintf(buf, sizeof(buf), "%d", m->pct);
  int nx = aa::text(x + 14, y + 46, buf, fontBig, TEXT);
  aa::text(nx + 2, y + 46, "%", fontBody, DIM);

  uint16_t fill = GREEN;
  const char* pace = nullptr;
  if (m->pct >= 100) {
    fill = RED;
    pace = "limit hit";
  } else if (m->pace >= 0 && m->pct * 10 > m->pace + 50) {
    fill = AMBER;
    pace = "ahead of pace";
  } else if (m->pace >= 0) {
    pace = "on pace";
  }

  aa::roundRect(bx, by, bw, 10, 5, TRACK);
  int fw = constrain(m->pct, 0, 100) * bw / 100;
  if (fw >= 10) aa::roundRect(bx, by, fw, 10, 5, fill);
  else if (fw > 0) aa::disc(bx + 5, by + 5, 5, fill);
  if (m->pace >= 0) {
    int mx = bx + constrain(m->pace, 0, 1000) * bw / 1000;
    board::fb->fillRect(mx - 1, by - 3, 2, 16, TEXT);
  }

  aa::text(x + 14, y + 88, m->reset, fontSmall, DIM);
  if (pace) aa::text(x + w - 14, y + 88, pace, fontTiny, fill == GREEN ? DIM : fill, aa::Align::Right);
}

// A note in the space a second card would take, wrapped onto two lines if it must.
static void note(int y, const char* s) {
  char first[48], rest[48] = "";
  strlcpy(first, s, sizeof(first));
  if (aa::textWidth(first, fontBody) > 200) {
    char* space = nullptr;
    for (char* p = first; *p; ++p)
      if (*p == ' ' && p - first < (int)strlen(first) * 2 / 3) space = p;
    if (space) {
      strlcpy(rest, space + 1, sizeof(rest));
      *space = 0;
    }
  }
  centered(120, y, first, fontBody, DIM, 204);
  if (rest[0]) centered(120, y + 20, rest, fontBody, DIM, 204);
}

void draw(uint32_t now, bool linked) {
  uint32_t age = usage.known ? (now - usage.at) / 1000 : 0;
  bool valid = usage.known && usage.ok && usage.count > 0;
  if (usage.known && !usage.ok) {  // e.g. an API key account: nothing to meter
    aa::roundRect(12, 48, 216, 212, 14, CARD);
    spark(120, 118, 16, 0, FAINT, 4);
    note(170, usage.note[0] ? usage.note : "Usage unavailable");
  } else if (!valid) {
    card(48, nullptr);
    card(158, nullptr);
  } else {
    card(48, &usage.meters[0]);
    if (usage.count > 1) card(158, &usage.meters[1]);
    else if (usage.note[0]) note(196, usage.note);
  }

  char line[64];
  if (!usage.known) {
    strlcpy(line, linked ? "Asking Claude for usage" : "Connect a Mac to see usage", sizeof(line));
  } else if (!valid) {
    strlcpy(line, hostName[0] ? hostName : "", sizeof(line));
  } else if (usage.count > 1 && usage.note[0]) {
    strlcpy(line, usage.note, sizeof(line));
  } else {
    char d[16];
    formatDuration(age, d, sizeof(d));
    snprintf(line, sizeof(line), "%s%supdated %s ago", usage.plan, usage.plan[0] ? "  -  " : "", d);
  }
  centered(120, 276, line, fontTiny, DIM, 176);
}

}  // namespace meters

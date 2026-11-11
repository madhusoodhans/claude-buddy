// nav — black-and-white bike navigation display. See ../plan.md and PROTOCOL.md.
//
// Controls:
//   + button   start / stop the demo ride
//
// Protocol messages ('@' lines on USB) are handled by main.cpp, which calls
// nav::handleMessage whichever app is showing.

#include <Arduino.h>
#include <cheeko_board.h>

#include "app.h"
#include "model.h"

namespace nav {

using namespace board;

static void init() {
  if (!modelInit()) Serial.println("nav: route memory alloc failed");
}

static void enter() { sfx({{880, 60}, {1320, 90}}); }

static void leave() {
  if (demoRunning()) demoStop();
}

static void frame(uint32_t now) {
  demoTick(now);
  viewUpdate(now);
  render(now);
}

static void toggleDemo() {
  if (demoRunning()) demoStop(); else demoStart();
  sfx({{1047, 50}});
}

static void noop() {}
static void noopTime(uint32_t) {}

static void drawGoodbye() {
  fb->fillScreen(0);
  centerText(130, "powering off", 0xffff, 2);
}

static bool command(const char* line) {
  if (!strcmp(line, "demo")) {
    demoStart();
    Serial.println("demo started");
  } else if (!strcmp(line, "stop")) {
    demoStop();
    Serial.println("stopped");
  } else if (!strcmp(line, "status")) {
    Serial.printf("state=%d route=%d roads=%d/%d fix=%d(%.1f,%.1f %ums ago, %.1fm/s +/-%.0fm) trail=%d turn=%d(%.0fm) last msg %ums ago demo=%d\n",
                  (int)state, route.len, roads.lines, roads.len, fix.valid, fix.pos.x, fix.pos.y,
                  (unsigned)(millis() - fix.at), fix.speed, fix.accuracy, trailLen,
                  (int)turn.type, turnDistance(), (unsigned)(millis() - lastMessageAt), demoRunning());
  } else if (!strcmp(line, "hello")) {
    Serial.println("@20");  // HELLO: ask the sender for the route again
  } else {
    return false;
  }
  return true;
}

const App app = {
    "Navigation", init, enter, leave, frame, noopTime,
    toggleDemo, noop, noop, drawGoodbye, command,
    "demo stop status hello, or @<hex message>",
};

}  // namespace nav

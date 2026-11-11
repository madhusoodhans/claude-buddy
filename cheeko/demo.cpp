// Built-in demo ride: plays the phone's part on a made-up town, using the same
// model calls the protocol does, so the screen can be tried without a phone.

#include <vector>

#include "model.h"

namespace nav {

struct DemoTurn {
  int idx;
  Maneuver type;
  const char* street;
};

static bool running = false;
static std::vector<DemoTurn> turns;
static float prog = 0, speed = 0;
static uint32_t lastTick = 0, lastFix = 0, arrivedAt = 0;

// Turns are found from the route shape: any bend sharper than 25 degrees.
static Maneuver classify(float deltaDeg) {
  float a = fabsf(deltaDeg);
  bool right = deltaDeg > 0;
  if (a > 165) return Maneuver::UTurn;
  if (a > 120) return right ? Maneuver::SharpRight : Maneuver::SharpLeft;
  if (a > 55) return right ? Maneuver::Right : Maneuver::Left;
  return right ? Maneuver::SlightRight : Maneuver::SlightLeft;
}

static float bearing(const Pt& a, const Pt& b) { return atan2f(b.x - a.x, b.y - a.y) * RAD_TO_DEG; }

static void buildTown() {
  std::vector<Pt> r = {{0, -60}, {0, 300}, {260, 300}};
  for (int a = -80; a <= 0; a += 10) {  // a long left-hand bend
    float t = a * DEG_TO_RAD;
    r.push_back({260 + 160 * cosf(t), 460 + 160 * sinf(t)});
  }
  r.insert(r.end(), {{420, 800}, {120, 800}, {120, 1100}, {230, 1290}});

  routeBegin();
  for (const Pt& p : r) routeAppend(p);
  routeEnd();

  roadsClear();
  for (float y : {-60.0f, 120.0f, 300.0f, 560.0f, 800.0f, 1000.0f, 1180.0f}) {
    Pt line[2] = {{-320, y}, {760, y}};
    roadsAdd(line, 2);
  }
  for (float x : {-200.0f, 0.0f, 120.0f, 260.0f, 420.0f, 620.0f}) {
    Pt line[2] = {{x, -260}, {x, 1450}};
    roadsAdd(line, 2);
  }
  Pt diag[3] = {{620, 120}, {760, 380}, {900, 520}};
  roadsAdd(diag, 3);

  static const char* names[] = {"Park Street", "Lake View Road", "Hill Avenue", "Station Road", "Market Lane"};
  turns.clear();
  for (int i = 1; i + 1 < route.len; ++i) {
    float d = bearing(route.pts[i], route.pts[i + 1]) - bearing(route.pts[i - 1], route.pts[i]);
    d = fmodf(d + 540.0f, 360.0f) - 180.0f;
    if (fabsf(d) >= 25) turns.push_back({i, classify(d), names[turns.size() % 5]});
  }
  turns.push_back({route.len - 1, Maneuver::Arrive, "Destination"});
}

void demoStart() {
  reset();
  buildTown();
  prog = 0;
  speed = 0;
  arrivedAt = 0;
  lastTick = lastFix = millis();
  running = true;
  setState(State::Navigating);
}

void demoStop() {
  running = false;
  reset();
}

bool demoRunning() { return running; }

void demoTick(uint32_t now) {
  if (!running) return;
  // Signed: lastTick can be a little *after* `now` if the ride started this frame.
  float dt = max<int32_t>(0, (int32_t)(now - lastTick)) / 1000.0f;
  lastTick = now;

  if (arrivedAt) {
    if (now - arrivedAt > 6000) demoStart();  // loop the ride
    return;
  }

  size_t nextNo = turns.size() - 1;
  for (size_t i = 0; i < turns.size(); ++i)
    if (route.cum[turns[i].idx] > prog + 1) { nextNo = i; break; }
  const DemoTurn* next = &turns[nextNo];
  float toTurn = route.cum[next->idx] - prog;

  // ~40 km/h, slowing to ~16 km/h for turns.
  float target = (toTurn < 60 && next->type != Maneuver::Arrive) ? 4.5f : 11.0f;
  speed += constrain(target - speed, -2.5f * dt, 1.5f * dt);
  prog += speed * dt;

  if (prog >= route.length()) {
    prog = route.length();
    setFix(pointAt(prog), headingAt(prog), 0);
    setTurn(Maneuver::Arrive, 0, route.len - 1, 0, "Destination");
    setState(State::Arrived);
    arrivedAt = now;
    return;
  }

  if ((int32_t)(now - lastFix) >= 1000) {  // like a phone: one GPS fix per second, a bit noisy
    lastFix = now;
    Pt p = pointAt(prog);
    p.x += random(-150, 150) / 100.0f;
    p.y += random(-150, 150) / 100.0f;
    setFix(p, headingAt(prog, 5) + random(-30, 30) / 10.0f, speed);
    setTurn(next->type, 0, next->idx, toTurn, next->street);
    Upcoming up[MAX_UPCOMING];
    int n = 0;
    for (size_t i = nextNo + 1; i < turns.size() && n < MAX_UPCOMING; ++i) up[n++] = {turns[i].type, 0, turns[i].idx};
    setUpcoming(up, n);
    setRoadName(nextNo == 0 ? "Church Street" : turns[nextNo - 1].street);

    float remain = route.length() - prog;
    uint32_t remainSec = remain / 9.0f;
    uint32_t etaSec = 10 * 3600 + now / 1000 + remainSec;  // pretend it's 10:00 at boot
    setTrip((etaSec / 3600) % 24, (etaSec / 60) % 60, remain, (remainSec + 59) / 60);
  }
}

}  // namespace nav

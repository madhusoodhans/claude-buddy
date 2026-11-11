#include "model.h"

namespace nav {

Route route = {};
Roads roads = {};
Fix fix = {};
Turn turn = {};
Trip trip = {};
Upcoming upcoming[MAX_UPCOMING];
int upcomingCount = 0;
char roadName[48] = "";
Pt trail[MAX_TRAIL];
int trailLen = 0;
State state = State::Idle;
uint32_t lastMessageAt = 0;

bool modelInit() {
  route.pts = (Pt*)ps_malloc(sizeof(Pt) * MAX_ROUTE);
  route.cum = (float*)ps_malloc(sizeof(float) * MAX_ROUTE);
  roads.pts = (Pt*)ps_malloc(sizeof(Pt) * MAX_ROAD_PTS);
  roads.lineEnd = (int*)ps_malloc(sizeof(int) * MAX_ROADS);
  reset();
  return route.pts && route.cum && roads.pts && roads.lineEnd;
}

void reset() {
  route.len = 0;
  route.ready = false;
  roads.lines = 0;
  roads.len = 0;
  fix.valid = false;
  turn.valid = false;
  trip.valid = false;
  upcomingCount = 0;
  roadName[0] = 0;
  trailLen = 0;
  state = State::Idle;
}

// ---- Route ----

void routeBegin() {
  route.len = 0;
  route.ready = false;
  turn.valid = false;
}

void routeAppend(Pt p) {
  if (route.len < MAX_ROUTE) route.pts[route.len++] = p;
}

void routeEnd() {
  if (route.len == 0) return;
  route.cum[0] = 0;
  for (int i = 1; i < route.len; ++i) {
    float dx = route.pts[i].x - route.pts[i - 1].x, dy = route.pts[i].y - route.pts[i - 1].y;
    route.cum[i] = route.cum[i - 1] + sqrtf(dx * dx + dy * dy);
  }
  route.ready = route.len >= 2;
  if (route.ready && (state == State::Idle || state == State::Rerouting || state == State::Arrived))
    state = State::Navigating;
}

int segmentAt(float progress) {
  int lo = 0, hi = route.len - 2;
  while (lo < hi) {  // last segment whose start is <= progress
    int mid = (lo + hi + 1) / 2;
    if (route.cum[mid] <= progress) lo = mid; else hi = mid - 1;
  }
  return lo;
}

Pt pointAt(float progress) {
  if (!route.ready) return {0, 0};
  progress = constrain(progress, 0.0f, route.length());
  int i = segmentAt(progress);
  float segLen = route.cum[i + 1] - route.cum[i];
  float t = segLen > 0 ? (progress - route.cum[i]) / segLen : 0;
  const Pt& a = route.pts[i];
  const Pt& b = route.pts[i + 1];
  return {a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t};
}

float headingAt(float progress, float lookahead) {
  float end = route.length();
  float p1 = min(progress + lookahead, end);
  float p0 = max(0.0f, min(progress - lookahead * 0.3f, p1 - 1.0f));
  Pt a = pointAt(p0), b = pointAt(p1);
  float h = atan2f(b.x - a.x, b.y - a.y) * RAD_TO_DEG;
  return h < 0 ? h + 360 : h;
}

static float projectRange(Pt p, int from, int to, float* bestDist) {
  float bestD2 = 1e18f, bestProg = 0;
  for (int i = from; i < to; ++i) {
    const Pt& a = route.pts[i];
    const Pt& b = route.pts[i + 1];
    float vx = b.x - a.x, vy = b.y - a.y;
    float len2 = vx * vx + vy * vy;
    float t = len2 > 0 ? ((p.x - a.x) * vx + (p.y - a.y) * vy) / len2 : 0;
    t = constrain(t, 0.0f, 1.0f);
    float qx = a.x + vx * t - p.x, qy = a.y + vy * t - p.y;
    float d2 = qx * qx + qy * qy;
    if (d2 < bestD2) {
      bestD2 = d2;
      bestProg = route.cum[i] + (route.cum[i + 1] - route.cum[i]) * t;
    }
  }
  *bestDist = sqrtf(bestD2);
  return bestProg;
}

float project(Pt p, int hintSeg, float* distOut) {
  if (!route.ready) { *distOut = 1e9f; return 0; }
  // Search near the last known segment first; fall back to the whole route.
  int from = max(0, hintSeg - 30), to = min(route.len - 1, hintSeg + 120);
  float prog = projectRange(p, from, to, distOut);
  if (*distOut > 40) prog = projectRange(p, 0, route.len - 1, distOut);
  return prog;
}

// ---- Roads ----

void roadsClear() {
  roads.lines = 0;
  roads.len = 0;
}

void roadsAdd(const Pt* p, int n) {
  if (n < 2 || roads.lines >= MAX_ROADS || roads.len + n > MAX_ROAD_PTS) return;
  memcpy(roads.pts + roads.len, p, sizeof(Pt) * n);
  roads.len += n;
  roads.lineEnd[roads.lines++] = roads.len;
}

// ---- Live data ----

void setFix(Pt p, float headingDeg, float speed, float accuracy) {
  fix.valid = true;
  fix.pos = p;
  fix.headingDeg = headingDeg;
  fix.speed = speed;
  fix.accuracy = accuracy;
  fix.at = millis();

  const Pt* last = trailLen ? &trail[trailLen - 1] : nullptr;
  if (!last || fabsf(p.x - last->x) + fabsf(p.y - last->y) > 3) {
    if (trailLen == MAX_TRAIL) {  // full: drop the oldest half
      memmove(trail, trail + MAX_TRAIL / 2, sizeof(Pt) * (MAX_TRAIL - MAX_TRAIL / 2));
      trailLen = MAX_TRAIL - MAX_TRAIL / 2;
    }
    trail[trailLen++] = p;
  }
}

void setTurn(Maneuver m, uint8_t exit, int routeIdx, float distM, const char* street) {
  turn.valid = m != Maneuver::None;
  turn.type = m;
  turn.exit = exit;
  turn.routeIdx = routeIdx;
  turn.distM = distM;
  strlcpy(turn.street, street, sizeof(turn.street));
}

void setTrip(uint8_t etaH, uint8_t etaM, float remainM, uint16_t remainMin) {
  trip = {true, etaH, etaM, remainM, remainMin};
}

void setState(State s) { state = s; }

void setUpcoming(const Upcoming* u, int n) {
  upcomingCount = min(n, MAX_UPCOMING);
  for (int i = 0; i < upcomingCount; ++i) upcoming[i] = u[i];
}

void setRoadName(const char* name) { strlcpy(roadName, name, sizeof(roadName)); }

static void copyString(const uint8_t* p, size_t len, char* out, size_t outSize) {
  size_t n = min(len, outSize - 1);
  memcpy(out, p, n);
  out[n] = 0;
}

// ---- Protocol (PROTOCOL.md). All integers little-endian. ----

static int32_t rd32(const uint8_t* p) {
  return (int32_t)((uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24);
}
static uint16_t rd16(const uint8_t* p) { return p[0] | p[1] << 8; }
static Pt rdPt(const uint8_t* p) { return {rd32(p) / 10.0f, rd32(p + 4) / 10.0f}; }  // decimetres

bool handleMessage(const uint8_t* d, size_t n) {
  if (n < 1) return false;
  lastMessageAt = millis();
  const uint8_t* p = d + 1;
  size_t len = n - 1;

  switch (d[0]) {
    case 0x01:  // ROUTE_BEGIN
      routeBegin();
      return true;
    case 0x02:  // ROUTE_POINTS: N x (i32 x, i32 y)
      if (len % 8) return false;
      for (size_t i = 0; i < len; i += 8) routeAppend(rdPt(p + i));
      return true;
    case 0x03:  // ROUTE_END
      routeEnd();
      return true;
    case 0x04:  // ROADS_CLEAR
      roadsClear();
      return true;
    case 0x05: {  // ROADS_LINE: N x (i32 x, i32 y), one polyline
      static Pt tmp[128];
      if (len % 8 || len < 16 || len / 8 > 128) return false;
      int k = len / 8;
      for (int i = 0; i < k; ++i) tmp[i] = rdPt(p + i * 8);
      roadsAdd(tmp, k);
      return true;
    }
    case 0x10:  // POS: i32 x, i32 y, u16 heading (centidegrees), u16 speed (cm/s) [, u16 accuracy (dm)]
      if (len < 12) return false;
      setFix(rdPt(p), rd16(p + 8) / 100.0f, rd16(p + 10) / 100.0f, len >= 14 ? rd16(p + 12) / 10.0f : 0);
      return true;
    case 0x11: {  // TURN: u8 maneuver, u8 exit, u16 route index, u32 distance (m), street (UTF-8)
      if (len < 8) return false;
      char street[48];
      size_t sl = min(len - 8, sizeof(street) - 1);
      memcpy(street, p + 8, sl);
      street[sl] = 0;
      uint16_t idx = rd16(p + 2);
      setTurn((Maneuver)p[0], p[1], idx == 0xffff ? -1 : idx, (float)(uint32_t)rd32(p + 4), street);
      return true;
    }
    case 0x12:  // TRIP: u8 eta hour, u8 eta minute, u32 remaining (m), u16 remaining (min)
      if (len < 8) return false;
      setTrip(p[0], p[1], (float)(uint32_t)rd32(p + 2), rd16(p + 6));
      return true;
    case 0x13:  // STATE: u8
      if (len < 1) return false;
      setState((State)p[0]);
      return true;
    case 0x14:  // RESET
      reset();
      return true;
    case 0x15: {  // UPCOMING: N x (u8 maneuver, u8 exit, u16 route index), the turns after TURN
      if (len % 4) return false;
      Upcoming u[MAX_UPCOMING];
      int k = min((int)(len / 4), MAX_UPCOMING);
      for (int i = 0; i < k; ++i) u[i] = {(Maneuver)p[i * 4], p[i * 4 + 1], rd16(p + i * 4 + 2)};
      setUpcoming(u, k);
      return true;
    }
    case 0x16: {  // ROAD: name of the road we're on (UTF-8)
      char name[48];
      copyString(p, len, name, sizeof(name));
      setRoadName(name);
      return true;
    }
  }
  return false;
}

}  // namespace nav

// Heading-up map view: the arrow stays put, the map rotates and slides under it.
//
// Layout (240x296, rounded glass corners — keep text inside board::SAFE_X):
//   top     turn tile, distance, street, "then" row with the next two turns
//   middle  street network, lime route, arrow, current road label
//   bottom  ARR (arrival time) and TO GO (distance left)

#include <cheeko_board.h>

#include "aa.h"
#include "ble_link.h"
#include "model.h"

using namespace board;
using aa::Align;

namespace nav {

// ---- Colours ----
static constexpr uint16_t C_BG = rgb(18, 19, 22);
static constexpr uint16_t C_FG = rgb(255, 255, 255);
static constexpr uint16_t C_DIM = rgb(150, 153, 160);
static constexpr uint16_t C_FAINT = rgb(100, 103, 110);
static constexpr uint16_t C_ROAD = rgb(88, 91, 98);
static constexpr uint16_t C_PASSED = rgb(58, 60, 66);
static constexpr uint16_t C_ACCENT = rgb(190, 242, 80);  // lime: route, near-turn tile
static constexpr uint16_t C_TILE = rgb(48, 50, 56);
static constexpr uint16_t C_PILL = rgb(38, 40, 45);
static constexpr uint16_t C_GRID = rgb(50, 53, 60);

// ---- Layout ----
static constexpr int TOP_H = 108;       // solid panel above the map
static constexpr int BOTTOM_Y = 258;    // solid panel below the map
static constexpr int FADE = 12;         // map fades into the panels
static constexpr int AX = LCD_W / 2;    // where "you" are on screen
static constexpr int AY = 210;
static constexpr float AHEAD_PX = AY - TOP_H;
static constexpr int TILE_X = 16, TILE_Y = 12, TILE = 50;
static constexpr float NEAR_TURN_M = 100;

static constexpr float ROUTE_W = 7;
static constexpr float ROAD_W = 1.8f;

// ---- View state ----
static Pt viewPos = {0, 0};
static float viewHeading = 0;   // degrees
static float viewProgress = 0;  // metres along the route
static float viewScale = 0.5f;  // pixels per metre
static bool viewOnRoute = false;
static bool viewInit = false;
static uint32_t lastFrame = 0;

static uint32_t projectedFixAt = 0;
static float fixProgress = 0, fixDist = 1e9f;
static int hintSeg = 0;

static float angleDiff(float to, float from) {
  float d = fmodf(to - from + 540.0f, 360.0f) - 180.0f;
  return d;
}

float turnDistance() {
  if (!turn.valid) return 0;
  if (route.ready && viewOnRoute && turn.routeIdx >= 0 && turn.routeIdx < route.len)
    return max(0.0f, route.cum[turn.routeIdx] - viewProgress);
  return turn.distM;
}

static float remainingDistance() {
  if (route.ready && viewOnRoute) return max(0.0f, route.length() - viewProgress);
  return trip.valid ? trip.remainM : 0;
}

void viewUpdate(uint32_t now) {
  float dt = min((now - lastFrame) / 1000.0f, 0.2f);
  lastFrame = now;
  if (!fix.valid) { viewInit = false; return; }

  // Project each new fix onto the route once.
  if (fix.at != projectedFixAt) {
    projectedFixAt = fix.at;
    if (route.ready) {
      fixProgress = project(fix.pos, hintSeg, &fixDist);
      hintSeg = segmentAt(fixProgress);
    } else {
      fixDist = 1e9f;
    }
  }

  // Predict where we are now. On the route, move *along the road*, so the
  // arrow follows bends between GPS fixes instead of cutting corners.
  // Signed: a fix that arrived during this frame is stamped after `now`.
  float since = constrain((int32_t)(now - fix.at) / 1000.0f, 0.0f, 2.0f);
  bool onRoute = route.ready && fixDist < 30;
  Pt target;
  float targetHeading, targetProgress = fixProgress;
  if (onRoute) {
    targetProgress = min(fixProgress + fix.speed * since, route.length());
    target = pointAt(targetProgress);
    targetHeading = fix.speed > 0.5f ? headingAt(targetProgress) : viewHeading;
  } else {
    float h = fix.headingDeg * DEG_TO_RAD;
    target = {fix.pos.x + sinf(h) * fix.speed * since, fix.pos.y + cosf(h) * fix.speed * since};
    targetHeading = fix.headingDeg;
  }

  float dx = target.x - viewPos.x, dy = target.y - viewPos.y;
  if (!viewInit || dx * dx + dy * dy > 80 * 80) {  // first fix, or a jump: snap
    viewPos = target;
    viewHeading = targetHeading;
    viewProgress = targetProgress;
    viewInit = true;
  } else {
    float k = 1 - expf(-dt / 0.25f);
    viewProgress += (targetProgress - viewProgress) * k;
    if (onRoute) {
      // Smooth along the road, not in a straight line, so the arrow stays on the
      // route through sharp turns and U-turns.
      viewPos = pointAt(viewProgress);
    } else {
      viewPos.x += dx * k;
      viewPos.y += dy * k;
    }
    viewHeading += angleDiff(targetHeading, viewHeading) * (1 - expf(-dt / 0.35f));
    viewHeading = fmodf(viewHeading + 360.0f, 360.0f);
  }
  viewOnRoute = onRoute;

  // Auto-zoom: see further when fast; near a turn, switch to a fixed close-up
  // so the corner visibly slides down to meet the arrow.
  float ahead = constrain(90 + fix.speed * 9, 110.0f, 450.0f);
  if (turn.valid && onRoute && turnDistance() < 250) ahead = min(ahead, 150.0f);
  viewScale += (AHEAD_PX / ahead - viewScale) * (1 - expf(-dt / 0.6f));
}

// ============================================================================
// Geometry helpers
// ============================================================================

struct SPt { float x, y; };

static float cosH = 1, sinH = 0;

static SPt toScreen(const Pt& p) {
  float dx = p.x - viewPos.x, dy = p.y - viewPos.y;
  float right = dx * cosH - dy * sinH;
  float fwd = dx * sinH + dy * cosH;
  return {AX + right * viewScale, AY - fwd * viewScale};
}

// Liang-Barsky clip to the map area plus a margin. False if fully outside.
static bool clip(SPt& a, SPt& b) {
  const float xmin = -10, xmax = LCD_W + 10, ymin = TOP_H - 10, ymax = BOTTOM_Y + 10;
  float t0 = 0, t1 = 1, dx = b.x - a.x, dy = b.y - a.y;
  const float p[4] = {-dx, dx, -dy, dy};
  const float q[4] = {a.x - xmin, xmax - a.x, a.y - ymin, ymax - a.y};
  for (int i = 0; i < 4; ++i) {
    if (p[i] == 0) {
      if (q[i] < 0) return false;
    } else {
      float r = q[i] / p[i];
      if (p[i] < 0) { if (r > t1) return false; if (r > t0) t0 = r; }
      else          { if (r < t0) return false; if (r < t1) t1 = r; }
    }
  }
  SPt na = {a.x + t0 * dx, a.y + t0 * dy}, nb = {a.x + t1 * dx, a.y + t1 * dy};
  a = na;
  b = nb;
  return true;
}

static void worldSegment(const Pt& pa, const Pt& pb, float w, uint16_t c) {
  SPt a = toScreen(pa), b = toScreen(pb);
  if (clip(a, b)) aa::line(a.x, a.y, b.x, b.y, w, c);
}

// ============================================================================
// Map
// ============================================================================

static void drawRoads() {
  int start = 0;
  for (int l = 0; l < roads.lines; ++l) {
    int end = roads.lineEnd[l];
    for (int i = start; i + 1 < end; ++i) worldSegment(roads.pts[i], roads.pts[i + 1], ROAD_W, C_ROAD);
    start = end;
  }
}

static void drawRoute() {
  if (!route.ready) return;
  int cur = viewOnRoute ? segmentAt(viewProgress) : -1;
  Pt here = viewOnRoute ? pointAt(viewProgress) : Pt{0, 0};

  // Behind us: thin and dim. Ahead: lime.
  for (int i = 0; i < cur; ++i) worldSegment(route.pts[i], route.pts[i + 1], 3, C_PASSED);
  if (cur >= 0) worldSegment(route.pts[cur], here, 3, C_PASSED);
  if (cur >= 0) worldSegment(here, route.pts[cur + 1], ROUTE_W, C_ACCENT);
  for (int i = cur >= 0 ? cur + 1 : 0; i + 1 < route.len; ++i)
    worldSegment(route.pts[i], route.pts[i + 1], ROUTE_W, C_ACCENT);

  // A dot where the next turn is.
  if (turn.valid && turn.routeIdx >= 0 && turn.routeIdx < route.len) {
    SPt t = toScreen(route.pts[turn.routeIdx]);
    if (t.y > TOP_H && t.y < BOTTOM_Y) {
      aa::disc(t.x, t.y, 5, C_BG);
      aa::disc(t.x, t.y, 3.2f, C_FG);
    }
  }
}

// Free ride (no route yet): a faint ground grid, so moving and turning show even
// with no streets, and a dim trail of where we've been.
static void drawTrail() {
  if (route.ready) return;
  const float step = 20;  // metres
  const float reach = 340 / max(viewScale, 0.05f);  // world distance to the screen edge, roughly
  const float gx0 = floorf((viewPos.x - reach) / step) * step, gy0 = floorf((viewPos.y - reach) / step) * step;
  for (float g = 0; g <= 2 * reach + step; g += step) {
    worldSegment({gx0 + g, viewPos.y - reach}, {gx0 + g, viewPos.y + reach}, 1, C_GRID);
    worldSegment({viewPos.x - reach, gy0 + g}, {viewPos.x + reach, gy0 + g}, 1, C_GRID);
  }
  for (int i = 0; i + 1 < trailLen; ++i) worldSegment(trail[i], trail[i + 1], 4, C_PASSED);
  if (trailLen) worldSegment(trail[trailLen - 1], viewPos, 4, C_PASSED);
}

static void drawArrow() {
  aa::chevron(AX, AY, 15, 0, C_BG);  // dark outline so it reads on the route
  aa::chevron(AX, AY, 11, 0, C_FG);
}

// Solid panels above and below the map, with the map fading into them.
static void drawPanels() {
  fb->fillRect(0, 0, LCD_W, TOP_H, C_BG);
  fb->fillRect(0, BOTTOM_Y, LCD_W, LCD_H - BOTTOM_Y, C_BG);
  for (int i = 0; i < FADE; ++i) {
    uint8_t a = 255 - (i + 1) * 255 / (FADE + 1);
    for (int x = 0; x < LCD_W; ++x) {
      aa::blend(x, TOP_H + i, C_BG, a);
      aa::blend(x, BOTTOM_Y - 1 - i, C_BG, a);
    }
  }
}

// ============================================================================
// Turn icons, drawn around (cx, cy); at scale 1 they fill about 56px.
// ============================================================================

static float maneuverAngle(Maneuver m) {
  switch (m) {
    case Maneuver::SlightLeft: return -45;
    case Maneuver::Left: return -90;
    case Maneuver::SharpLeft: return -135;
    case Maneuver::SlightRight: return 45;
    case Maneuver::Right: return 90;
    case Maneuver::SharpRight: return 135;
    case Maneuver::KeepLeft: return -28;
    case Maneuver::KeepRight: return 28;
    default: return 0;
  }
}

static void drawManeuver(float cx, float cy, Maneuver m, float s, uint16_t c, uint16_t bg) {
  const float W = max(2.2f, 8 * s);
  auto L = [&](float x0, float y0, float x1, float y1) { aa::line(cx + x0 * s, cy + y0 * s, cx + x1 * s, cy + y1 * s, W, c); };
  auto head = [&](float x, float y, float angleDeg, float size) {
    float a = angleDeg * DEG_TO_RAD, ux = sinf(a), uy = -cosf(a), nx = -uy, ny = ux;
    aa::triangle(cx + (x + ux * size) * s, cy + (y + uy * size) * s,
                 cx + (x - nx * size) * s, cy + (y - ny * size) * s,
                 cx + (x + nx * size) * s, cy + (y + ny * size) * s, c);
  };

  if (m == Maneuver::Arrive) {  // chequered flag
    aa::line(cx - 14 * s, cy + 26 * s, cx - 14 * s, cy - 24 * s, max(2.0f, 4 * s), c);
    int fx = cx - 12 * s, fy = cy - 25 * s, sq = max(2, (int)(5 * s));
    fb->fillRect(fx, fy, sq * 6 + 2, sq * 4 + 2, c);
    for (int r = 0; r < 4; ++r)
      for (int q = 0; q < 6; ++q)
        if ((r + q) % 2) fb->fillRect(fx + 1 + q * sq, fy + 1 + r * sq, sq, sq, bg);
    return;
  }
  if (m == Maneuver::UTurn || m == Maneuver::UTurnLeft) {  // up, over the top, back down
    float side = m == Maneuver::UTurn ? 1 : -1;
    const float r = 10, top = -8;
    L(-side * r, 26, -side * r, top);
    for (int a = 180; a > 0; a -= 20) {
      float a0 = a * DEG_TO_RAD, a1 = (a - 20) * DEG_TO_RAD;
      L(side * r * cosf(a0), top - r * sinf(a0), side * r * cosf(a1), top - r * sinf(a1));
    }
    L(side * r, top, side * r, 6);
    head(side * r, 6, 180, 10);
    return;
  }
  if (m == Maneuver::Roundabout) {
    aa::disc(cx, cy - 4 * s, 15 * s, c);
    aa::disc(cx, cy - 4 * s, 15 * s - W, bg);
    L(0, 26, 0, 11);
    float a = 45 * DEG_TO_RAD;
    L(sinf(a) * 13, -4 - cosf(a) * 13, sinf(a) * 22, -4 - cosf(a) * 22);
    head(sinf(a) * 22, -4 - cosf(a) * 22, 45, 10);
    return;
  }
  // Straight, slight, normal, sharp, keep: a stem with a bent branch.
  float ang = maneuverAngle(m);
  bool sharp = fabsf(ang) > 100;  // branch points back down, so bend higher up
  float jy = ang == 0 ? -6 : (sharp ? -12 : 4);
  float a = ang * DEG_TO_RAD, len = ang == 0 ? 10 : 18;
  float ex = sinf(a) * len, ey = jy - cosf(a) * len;
  // Centre the whole shape (stem, branch, arrowhead) on (cx, cy), not just the stem.
  const float hs = 11, ux = sinf(a), uy = -cosf(a);
  const float xs[5] = {0, ex, ex + ux * hs, ex - uy * hs, ex + uy * hs};
  const float ys[5] = {26, jy, ey + uy * hs, ey + ux * hs, ey - ux * hs};
  float x0 = 1e9f, x1 = -1e9f, y0 = 1e9f, y1 = -1e9f;
  for (int i = 0; i < 5; ++i) {
    x0 = min(x0, xs[i]); x1 = max(x1, xs[i]);
    y0 = min(y0, ys[i]); y1 = max(y1, ys[i]);
  }
  float ox = -(x0 + x1) / 2, oy = -(y0 + y1) / 2;
  L(ox, 26 + oy, ox, jy + oy);
  L(ox, jy + oy, ex + ox, ey + oy);
  head(ex + ox, ey + oy, ang, hs);
}

// ============================================================================
// Text helpers
// ============================================================================

static void formatDistance(float m, char* num, size_t numSize, const char** unit) {
  if (m < 1000) {
    int step = m < 100 ? 5 : (m < 300 ? 10 : 50);
    snprintf(num, numSize, "%d", (int)(m / step + 0.5f) * step);
    *unit = "m";
  } else {
    snprintf(num, numSize, m < 10000 ? "%.1f" : "%.0f", m / 1000);
    *unit = "km";
  }
}

// ============================================================================
// Top: next turn
// ============================================================================

static void drawTile(Maneuver m, bool near) {
  uint16_t fill = near ? C_ACCENT : C_TILE, ink = near ? C_BG : C_FG;
  aa::roundRect(TILE_X, TILE_Y, TILE, TILE, 12, fill);
  drawManeuver(TILE_X + TILE / 2.0f, TILE_Y + TILE / 2.0f, m, 0.62f, ink, fill);
}

static void drawThenRow() {
  if (!route.ready || upcomingCount == 0 || !turn.valid || turn.routeIdx < 0) return;
  const int y = 101;
  int x = aa::text(18, y, "THEN", fontTiny, C_FAINT) + 8;
  int prevIdx = turn.routeIdx;
  for (int i = 0; i < upcomingCount; ++i) {
    const Upcoming& u = upcoming[i];
    if (u.routeIdx < 0 || u.routeIdx >= route.len || x > LCD_W - 60) break;
    drawManeuver(x + 6, y - 5, u.type, 0.24f, C_DIM, C_BG);
    char num[12];
    const char* unit;
    formatDistance(route.cum[u.routeIdx] - route.cum[prevIdx], num, sizeof(num), &unit);
    x = aa::text(x + 16, y, num, fontSmall, C_DIM) + 14;
    prevIdx = u.routeIdx;
  }
}

static void drawTop() {
  const int textX = TILE_X + TILE + 12;
  if (state == State::Arrived) {
    drawTile(Maneuver::Arrive, true);
    aa::text(textX, 46, "Arrived", fontLarge, C_FG);
    aa::text(18, 84, "You're here", fontLarge, C_DIM);
    return;
  }
  if (!route.ready) {  // free ride: speed and GPS quality
    aa::roundRect(TILE_X, TILE_Y, TILE, TILE, 12, C_TILE);
    aa::chevron(TILE_X + TILE / 2.0f, TILE_Y + TILE / 2.0f + 2, 11, 0, C_ACCENT);
    char num[8];
    snprintf(num, sizeof(num), "%d", (int)(fix.speed * 3.6f + 0.5f));
    int x = aa::text(textX, 52, num, fontHuge, C_FG);
    aa::text(x + 4, 52, "km/h", fontMedium, C_DIM);
    aa::text(18, 84, "Free ride", fontLarge, C_FG);
    if (fix.accuracy > 0) {
      char gps[24];
      snprintf(gps, sizeof(gps), "+/- %d m", (int)(fix.accuracy + 0.5f));
      int gx = aa::text(18, 101, "GPS", fontTiny, C_FAINT) + 8;
      aa::text(gx, 101, gps, fontSmall, fix.accuracy <= 15 ? C_DIM : C_FG);
    }
    return;
  }
  if (!turn.valid) {
    aa::text(LCD_W / 2, 56, "Follow the route", fontLarge, C_FG, Align::Center);
    return;
  }

  float d = turnDistance();
  drawTile(turn.type, d <= NEAR_TURN_M);
  if (d < 15) {
    aa::text(textX, 52, "Now", fontHuge, C_FG);
  } else {
    char num[12];
    const char* unit;
    formatDistance(d, num, sizeof(num), &unit);
    int x = aa::text(textX, 52, num, fontHuge, C_FG);
    aa::text(x + 4, 52, unit, fontMedium, C_DIM);
  }

  char street[64], fitted[64];
  if (turn.type == Maneuver::Roundabout && turn.exit)
    snprintf(street, sizeof(street), "Exit %u%s%s", turn.exit, turn.street[0] ? " - " : "", turn.street);
  else
    strlcpy(street, turn.street, sizeof(street));
  aa::fit(street, fontLarge, LCD_W - 36, fitted, sizeof(fitted));
  aa::text(18, 84, fitted, fontLarge, C_FG);

  drawThenRow();
}

// ============================================================================
// Bottom: arrival time and distance left; road label under the arrow
// ============================================================================

static void drawBottom() {
  if (!trip.valid) return;
  const int left = SAFE_X + 6, right = LCD_W - SAFE_X - 6;
  char buf[16];
  aa::text(left, 271, "ARR", fontTiny, C_FAINT);
  snprintf(buf, sizeof(buf), "%02u:%02u", trip.etaH, trip.etaM);
  aa::text(left, 290, buf, fontMedium, C_FG);

  aa::text(right, 271, "TO GO", fontTiny, C_FAINT, Align::Right);
  char num[12];
  const char* unit;
  formatDistance(remainingDistance(), num, sizeof(num), &unit);
  snprintf(buf, sizeof(buf), "%s %s", num, unit);
  aa::text(right, 290, buf, fontMedium, C_FG, Align::Right);

  if (trip.remainMin) {
    if (trip.remainMin >= 60) snprintf(buf, sizeof(buf), "%uh %02um", trip.remainMin / 60, trip.remainMin % 60);
    else snprintf(buf, sizeof(buf), "%u min", trip.remainMin);
    aa::text(LCD_W / 2, 290, buf, fontSmall, C_DIM, Align::Center);
  }
}

static void drawRoadLabel() {
  if (!roadName[0]) return;
  char name[48];
  aa::fit(roadName, fontSmall, 150, name, sizeof(name));
  int w = aa::textWidth(name, fontSmall) + 16;
  int y = AY + 24;
  aa::roundRect(AX - w / 2, y, w, 19, 9, C_PILL);
  aa::text(AX, y + 14, name, fontSmall, C_FG, Align::Center);
}

static void drawNotice(const char* msg) {
  int w = aa::textWidth(msg, fontMedium) + 28;
  int y = TOP_H + 10;
  aa::roundRect(AX - w / 2, y, w, 28, 14, C_FG);
  aa::text(AX, y + 20, msg, fontMedium, C_BG, Align::Center);
}

static void drawIdle() {
  aa::text(LCD_W / 2, 64, "Navigation", fontLarge, C_FG, Align::Center);
  aa::text(LCD_W / 2, 98, ble::connected() ? "phone connected" : "waiting for phone...", fontSmall,
           ble::connected() ? C_ACCENT : C_DIM, Align::Center);
  aa::chevron(AX, 150, 15, 0, C_ACCENT);
  aa::text(LCD_W / 2, 212, "+  demo ride", fontSmall, C_DIM, Align::Center);
  aa::text(LCD_W / 2, 232, "hold + and -  for Pip", fontSmall, C_DIM, Align::Center);
}

// ============================================================================

void render(uint32_t now) {
  fb->fillScreen(C_BG);
  if (state == State::Idle && !route.ready && !fix.valid) {
    drawIdle();
    return;
  }

  float h = viewHeading * DEG_TO_RAD;
  cosH = cosf(h);
  sinH = sinf(h);

  drawRoads();
  drawRoute();
  drawTrail();
  drawArrow();
  drawRoadLabel();
  drawPanels();
  drawTop();
  drawBottom();

  if (state == State::Rerouting) drawNotice("Rerouting...");
  else if (state == State::NoGps) drawNotice("No GPS");
  else if (!demoRunning() && !ble::connected() && (int32_t)(now - lastMessageAt) > 5000) drawNotice("Phone lost");
  else if (!demoRunning() && (int32_t)(now - fix.at) > 5000) drawNotice("Waiting for GPS");

  if (demoRunning()) aa::text(LCD_W - 12, TOP_H + 16, "DEMO", fontTiny, C_FAINT, Align::Right);
}

}  // namespace nav

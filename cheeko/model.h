// Navigation data model, protocol, demo ride and view — shared declarations.
// Message format: see PROTOCOL.md.

#pragma once

#include <Arduino.h>

namespace nav {

enum class Maneuver : uint8_t {
  None = 0, Straight, SlightLeft, Left, SharpLeft, SlightRight, Right, SharpRight,
  UTurn, Roundabout, Arrive, KeepLeft, KeepRight,
  UTurnLeft,  // UTurn goes round to the right (left-hand traffic, e.g. India)
};

enum class State : uint8_t { Idle = 0, Navigating, Rerouting, Arrived, NoGps };

struct Pt { float x, y; };  // metres east / north of the route origin

constexpr int MAX_ROUTE = 6000;
constexpr int MAX_ROAD_PTS = 16000;
constexpr int MAX_ROADS = 2000;

struct Route {
  Pt* pts;
  float* cum;  // distance along the route at each point, metres
  int len;
  bool ready;
  float length() const { return len > 0 ? cum[len - 1] : 0; }
};

struct Roads {
  Pt* pts;
  int* lineEnd;  // line i spans [i == 0 ? 0 : lineEnd[i - 1], lineEnd[i])
  int lines;
  int len;
};

struct Fix {
  bool valid;
  Pt pos;
  float headingDeg;  // clockwise from north
  float speed;       // m/s
  float accuracy;    // metres, 0 if unknown
  uint32_t at;       // millis() when received
};

struct Turn {
  bool valid;
  Maneuver type;
  uint8_t exit;  // roundabout exit number, 0 if unknown
  int routeIdx;  // route point where the turn is, -1 if unknown
  float distM;   // distance from the phone, used when we can't compute it
  char street[48];
};

// Turns after the next one, for the "then" row.
constexpr int MAX_UPCOMING = 2;
struct Upcoming {
  Maneuver type;
  uint8_t exit;
  int routeIdx;
};

struct Trip {
  bool valid;
  uint8_t etaH, etaM;
  float remainM;
  uint16_t remainMin;
};

extern Route route;
extern Roads roads;
extern Fix fix;
extern Turn turn;
extern Trip trip;
extern Upcoming upcoming[MAX_UPCOMING];
extern int upcomingCount;
extern char roadName[48];  // the road we're on now

// Where we've been, for the free-ride view (no route yet).
constexpr int MAX_TRAIL = 400;
extern Pt trail[MAX_TRAIL];
extern int trailLen;
extern State state;
extern uint32_t lastMessageAt;

// ---- Model (model.cpp) ----
bool modelInit();
void reset();
void routeBegin();
void routeAppend(Pt p);
void routeEnd();
void roadsClear();
void roadsAdd(const Pt* p, int n);
void setFix(Pt p, float headingDeg, float speed, float accuracy = 0);
void setTurn(Maneuver m, uint8_t exit, int routeIdx, float distM, const char* street);
void setTrip(uint8_t etaH, uint8_t etaM, float remainM, uint16_t remainMin);
void setState(State s);
void setUpcoming(const Upcoming* u, int n);
void setRoadName(const char* name);

Pt pointAt(float progress);
float headingAt(float progress, float lookahead = 8);       // degrees
int segmentAt(float progress);
float project(Pt p, int hintSeg, float* distOut);           // progress of the nearest route point

// Applies one decoded message. Returns false if it was malformed.
bool handleMessage(const uint8_t* data, size_t len);

// ---- Demo ride (demo.cpp) ----
void demoStart();
void demoStop();
bool demoRunning();
void demoTick(uint32_t now);

// ---- View (view.cpp) ----
void viewUpdate(uint32_t now);
void render(uint32_t now);
float turnDistance();

}  // namespace nav

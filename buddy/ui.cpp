#include "model.h"
#include "ui.h"

namespace ui {

uint16_t lerp(uint16_t a, uint16_t b, float t) {
  t = constrain(t, 0.0f, 1.0f);
  int r = ((a >> 11) & 31) + (((b >> 11) & 31) - ((a >> 11) & 31)) * t;
  int g = ((a >> 5) & 63) + (((b >> 5) & 63) - ((a >> 5) & 63)) * t;
  int bl = (a & 31) + ((b & 31) - (a & 31)) * t;
  return r << 11 | g << 5 | bl;
}

void spark(float cx, float cy, float r, float angle, uint16_t color, float width) {
  for (int i = 0; i < 4; ++i) {
    float a = angle + i * PI / 4;
    float len = i % 2 ? r * 0.62f : r;  // long and short rays, like the Claude spark
    aa::line(cx - cosf(a) * len, cy - sinf(a) * len, cx + cosf(a) * len, cy + sinf(a) * len, width, color);
  }
}

void arc(float cx, float cy, float r, float a0, float a1, float width, uint16_t color) {
  const int steps = 10;
  float px = cx + cosf(a0) * r, py = cy + sinf(a0) * r;
  for (int i = 1; i <= steps; ++i) {
    float a = a0 + (a1 - a0) * i / steps;
    float x = cx + cosf(a) * r, y = cy + sinf(a) * r;
    aa::line(px, py, x, y, width, color);
    px = x;
    py = y;
  }
}

void centered(int cx, int y, const char* s, const AaFont& f, uint16_t color, int maxW) {
  char buf[80];
  aa::fit(s, f, maxW, buf, sizeof(buf));
  aa::text(cx, y, buf, f, color, aa::Align::Center);
}

}  // namespace ui

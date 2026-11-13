#include "aa.h"

#include <cheeko_board.h>

using namespace board;

namespace aa {

// RGB565 blend with 5-bit alpha: spread the fields so one multiply does all three.
static inline uint16_t mix(uint16_t fg, uint16_t bg, uint32_t a5) {
  uint32_t f = (fg | ((uint32_t)fg << 16)) & 0x07e0f81f;
  uint32_t b = (bg | ((uint32_t)bg << 16)) & 0x07e0f81f;
  uint32_t r = ((((f - b) * a5) >> 5) + b) & 0x07e0f81f;
  return (uint16_t)((r >> 16) | r);
}

void blend(int x, int y, uint16_t color, uint8_t alpha) {
  if ((unsigned)x >= (unsigned)LCD_W || (unsigned)y >= (unsigned)LCD_H || alpha < 8) return;
  uint16_t* p = fb->getBuffer() + y * LCD_W + x;
  *p = alpha >= 248 ? color : mix(color, *p, alpha >> 3);
}

static inline uint8_t coverage(float c) {  // 0..1 -> 0..255
  return c <= 0 ? 0 : (c >= 1 ? 255 : (uint8_t)(c * 255));
}

// ---- Text ----

static const AaGlyph* glyph(const AaFont& f, char c) {
  if ((uint8_t)c < f.first || (uint8_t)c > f.last) c = '?';
  return &f.glyphs[(uint8_t)c - f.first];
}

int textWidth(const char* s, const AaFont& f) {
  int w = 0;
  for (; *s; ++s) w += glyph(f, *s)->advance;
  return w;
}

int text(int x, int y, const char* s, const AaFont& f, uint16_t color, Align align) {
  if (align != Align::Left) x -= textWidth(s, f) / (align == Align::Center ? 2 : 1);
  for (; *s; ++s) {
    const AaGlyph* g = glyph(f, *s);
    int gx = x + g->dx, gy = y + g->dy;
    if (gx < LCD_W && gx + g->w > 0 && gy < LCD_H && gy + g->h > 0) {
      const uint8_t* bits = f.bits + g->offset;
      int n = 0;
      for (int row = 0; row < g->h; ++row)
        for (int col = 0; col < g->w; ++col, ++n) {
          uint8_t v = bits[n >> 1];
          uint8_t a = (n & 1) ? (v & 0x0f) : (v >> 4);
          if (a) blend(gx + col, gy + row, color, a * 17);
        }
    }
    x += g->advance;
  }
  return x;
}

void fit(const char* s, const AaFont& f, int maxW, char* out, size_t outSize) {
  strlcpy(out, s, outSize);
  if (textWidth(out, f) <= maxW) return;
  int dots = textWidth("...", f);
  for (int n = strlen(out) - 1; n > 0; --n) {
    out[n] = 0;
    if (textWidth(out, f) + dots <= maxW) {
      strlcat(out, "...", outSize);
      return;
    }
  }
}

// ---- Shapes ----

void line(float x0, float y0, float x1, float y1, float width, uint16_t color) {
  const float r = width / 2;
  float dx = x1 - x0, dy = y1 - y0;
  float len2 = dx * dx + dy * dy;
  int minX = max(0, (int)floorf(min(x0, x1) - r - 1)), maxX = min(LCD_W - 1, (int)ceilf(max(x0, x1) + r + 1));
  int minY = max(0, (int)floorf(min(y0, y1) - r - 1)), maxY = min(LCD_H - 1, (int)ceilf(max(y0, y1) + r + 1));
  if (minX > maxX || minY > maxY) return;

  const float outer2 = (r + 0.5f) * (r + 0.5f);
  const float inner = r - 0.5f, inner2 = inner > 0 ? inner * inner : 0;
  const float invLen2 = len2 > 0 ? 1.0f / len2 : 0;
  uint16_t* buf = fb->getBuffer();

  auto shade = [&](int x, int y) {
    float px = x + 0.5f, py = y + 0.5f;
    float t = ((px - x0) * dx + (py - y0) * dy) * invLen2;
    t = t < 0 ? 0 : (t > 1 ? 1 : t);
    float ex = x0 + dx * t - px, ey = y0 + dy * t - py;
    float d2 = ex * ex + ey * ey;
    if (d2 >= outer2) return;
    uint16_t* p = buf + y * LCD_W + x;
    if (d2 <= inner2) { *p = color; return; }
    uint8_t a = coverage(r + 0.5f - sqrtf(d2));
    if (a >= 8) *p = a >= 248 ? color : mix(color, *p, a >> 3);
  };

  // Walk along the line's main direction and only shade the short band across
  // it, instead of the whole bounding box (thin diagonal roads are mostly empty box).
  const float len = sqrtf(len2);
  const float slack = r + 1.5f;
  const bool steep = fabsf(dy) >= fabsf(dx);
  const float major = steep ? dy : dx;
  if (len == 0 || fabsf(major) < 0.01f) {  // a dot
    for (int y = minY; y <= maxY; ++y)
      for (int x = minX; x <= maxX; ++x) shade(x, y);
    return;
  }
  const float half = slack * len / fabsf(major);  // band half-width along the minor axis
  const float a0 = steep ? y0 : x0, a1 = steep ? y1 : x1;  // major-axis ends
  const float b0 = steep ? x0 : y0, slope = (steep ? dx : dy) / major;
  const int lo = steep ? minY : minX, hi = steep ? maxY : maxX;
  const int minorLo = steep ? minX : minY, minorHi = steep ? maxX : maxY;
  const float endLo = min(a0, a1) + slack, endHi = max(a0, a1) - slack;
  for (int m = lo; m <= hi; ++m) {
    float pm = m + 0.5f;
    int ka, kb;
    if (pm < endLo || pm > endHi) {  // near an end: the round cap can poke out of the band
      ka = minorLo;
      kb = minorHi;
    } else {
      float c = b0 + (pm - a0) * slope;
      ka = max(minorLo, (int)floorf(c - half));
      kb = min(minorHi, (int)ceilf(c + half));
    }
    for (int k = ka; k <= kb; ++k) steep ? shade(k, m) : shade(m, k);
  }
}

void disc(float cx, float cy, float r, uint16_t color) { line(cx, cy, cx, cy, r * 2, color); }

void roundRect(int x, int y, int w, int h, int r, uint16_t color) {
  fb->fillRect(x + r, y, w - 2 * r, h, color);
  fb->fillRect(x, y + r, r, h - 2 * r, color);
  fb->fillRect(x + w - r, y + r, r, h - 2 * r, color);
  // corners: distance to each corner's circle centre
  const float cxs[2] = {x + r - 0.0f, x + w - r - 0.0f}, cys[2] = {y + r - 0.0f, y + h - r - 0.0f};
  for (int i = 0; i < 2; ++i)
    for (int j = 0; j < 2; ++j) {
      int x0 = i ? x + w - r : x, y0 = j ? y + h - r : y;
      for (int py = y0; py < y0 + r; ++py)
        for (int px = x0; px < x0 + r; ++px) {
          float ddx = px + 0.5f - cxs[i], ddy = py + 0.5f - cys[j];
          blend(px, py, color, coverage(r + 0.5f - sqrtf(ddx * ddx + ddy * ddy)));
        }
    }
}

// Signed distance from p to the edge a->b; positive on the inside of a clockwise triangle.
static inline float edgeDist(float px, float py, float ax, float ay, float bx, float by) {
  float ex = bx - ax, ey = by - ay;
  float l = sqrtf(ex * ex + ey * ey);
  return l > 0 ? ((px - ax) * ey - (py - ay) * ex) / -l : 0;
}

// Coverage of a triangle (any winding) at a pixel centre.
static float triCov(float px, float py, const float* v) {
  float d0 = edgeDist(px, py, v[0], v[1], v[2], v[3]);
  float d1 = edgeDist(px, py, v[2], v[3], v[4], v[5]);
  float d2 = edgeDist(px, py, v[4], v[5], v[0], v[1]);
  float area = (v[2] - v[0]) * (v[5] - v[1]) - (v[3] - v[1]) * (v[4] - v[0]);
  if (area < 0) { d0 = -d0; d1 = -d1; d2 = -d2; }
  float d = min(d0, min(d1, d2));
  return d + 0.5f;
}

static void fillTris(const float* tris, int count, uint16_t color) {
  float minX = 1e9f, maxX = -1e9f, minY = 1e9f, maxY = -1e9f;
  for (int i = 0; i < count * 3; ++i) {
    minX = min(minX, tris[i * 2]); maxX = max(maxX, tris[i * 2]);
    minY = min(minY, tris[i * 2 + 1]); maxY = max(maxY, tris[i * 2 + 1]);
  }
  for (int y = max(0, (int)minY - 1); y <= min(LCD_H - 1, (int)maxY + 1); ++y)
    for (int x = max(0, (int)minX - 1); x <= min(LCD_W - 1, (int)maxX + 1); ++x) {
      float c = 0;  // union of the triangles: take the best coverage
      for (int t = 0; t < count; ++t) c = max(c, triCov(x + 0.5f, y + 0.5f, tris + t * 6));
      blend(x, y, color, coverage(c));
    }
}

void triangle(float x0, float y0, float x1, float y1, float x2, float y2, uint16_t color) {
  const float v[6] = {x0, y0, x1, y1, x2, y2};
  fillTris(v, 1, color);
}

}  // namespace aa

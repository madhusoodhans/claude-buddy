// Anti-aliased drawing into board::fb: smooth text, lines and rounded boxes.
// Fonts come from tools/make_fonts.py (4-bit coverage per pixel).

#pragma once

#include <Arduino.h>

struct AaGlyph {
  uint32_t offset;  // into the font's bitmap, in bytes
  uint8_t w, h;
  uint8_t advance;
  int8_t dx, dy;  // top-left of the bitmap relative to the pen on the baseline
};

struct AaFont {
  const uint8_t* bits;  // 4 bits per pixel, high nibble first, rows packed
  const AaGlyph* glyphs;
  uint8_t first, last;
  uint8_t ascent, lineHeight;
};

extern const AaFont fontBig, fontClock, fontTitle, fontBody, fontSmall, fontTiny;

namespace aa {

enum class Align { Left, Center, Right };

// Blends `color` over the pixel at (x, y) with coverage 0..255.
void blend(int x, int y, uint16_t color, uint8_t alpha);

int textWidth(const char* s, const AaFont& f);
// Draws s with its baseline at y. Returns the x just past the text.
int text(int x, int y, const char* s, const AaFont& f, uint16_t color, Align align = Align::Left);
// Shortens s with "..." so it fits maxW pixels.
void fit(const char* s, const AaFont& f, int maxW, char* out, size_t outSize);

// A line with round ends, `width` pixels wide, smooth edges.
void line(float x0, float y0, float x1, float y1, float width, uint16_t color);
void disc(float cx, float cy, float r, uint16_t color);
void roundRect(int x, int y, int w, int h, int r, uint16_t color);
void triangle(float x0, float y0, float x1, float y1, float x2, float y2, uint16_t color);
// Navigation arrowhead centred on (cx, cy), pointing at angleDeg (0 = up).
void chevron(float cx, float cy, float size, float angleDeg, uint16_t color);

}  // namespace aa

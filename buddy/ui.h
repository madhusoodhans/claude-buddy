// Colours, layout and small drawing helpers shared by the three pages.

#pragma once

#include <Arduino.h>
#include <cheeko_board.h>

#include "aa.h"
#include "model.h"

namespace ui {

using board::rgb;

constexpr uint16_t BG = rgb(0, 0, 0);
constexpr uint16_t CARD = rgb(28, 30, 28);
constexpr uint16_t PILL = rgb(48, 50, 48);
constexpr uint16_t TRACK = rgb(46, 48, 46);
constexpr uint16_t TEXT = rgb(240, 238, 230);  // Claude cream
constexpr uint16_t DIM = rgb(140, 140, 134);
constexpr uint16_t FAINT = rgb(70, 70, 66);
constexpr uint16_t CLAY = rgb(217, 119, 87);  // Claude terracotta
constexpr uint16_t CLAY_DARK = rgb(168, 84, 58);
constexpr uint16_t CLAY_SLEEP = rgb(150, 86, 66);
constexpr uint16_t INK = rgb(30, 20, 18);  // eyes, mouth
constexpr uint16_t BLUSH = rgb(240, 150, 140);
constexpr uint16_t GREEN = rgb(134, 170, 98);
constexpr uint16_t AMBER = rgb(232, 168, 64);
constexpr uint16_t RED = rgb(214, 72, 58);
constexpr uint16_t BLUE = rgb(120, 160, 230);

constexpr int HEADER_H = 42;  // the clock row; pages draw below it
constexpr int CONTENT_BOTTOM = 274;  // the page dots sit below

// Mixes a toward b; t = 0 gives a, 1 gives b.
uint16_t lerp(uint16_t a, uint16_t b, float t);
// An eight-ray spark (the buddy's sparkle), rotated by `angle` radians.
void spark(float cx, float cy, float r, float angle, uint16_t color, float width = 2.2f);
// A smooth arc through angles a0..a1 (radians, 0 = right, clockwise on screen).
void arc(float cx, float cy, float r, float a0, float a1, float width, uint16_t color);
// Text shortened to fit maxW, centred on cx.
void centered(int cx, int y, const char* s, const AaFont& f, uint16_t color, int maxW = 200);

}  // namespace ui

extern bool soundOn;  // main.cpp; touch and hold toggles it

// The pages (one file each). Each draws into board::fb between HEADER_H and CONTENT_BOTTOM.
namespace face {
void draw(uint32_t now, bool linked);
bool tap(int x, int y, uint32_t now);  // true if it hit the buddy
void shake(uint32_t now);
void tilt(float x, float y);
void moodChanged(Mood from, Mood to, uint32_t now);
}  // namespace face
namespace meters { void draw(uint32_t now, bool linked); }
namespace day { void draw(uint32_t now, bool linked); }

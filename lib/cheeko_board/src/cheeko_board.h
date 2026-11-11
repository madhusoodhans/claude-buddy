// Board support for the Cheeko Gotchi v1.2 (ESP32-S3).
//
// Pin map, init sequences and touch mapping come from cheeko-gotchi/SKILL.md (github.com/ALTIO-AI-PRIVATE-LIMITED/cheeko-gotchi),
// with the vendor's full JD9853 panel init (SKILL.md calls it ST7789 and its
// short init only works if another firmware already set the panel up).
// Build with FQBN esp32:esp32:XIAO_ESP32S3:PSRAM=opi (see ../../pet.sh).
//
// Do not touch GPIO 33-37: they belong to the octal PSRAM. Configuring GPIO 37
// (charge detect on the schematic) hangs the chip in a watchdog reset loop.

#pragma once

#include <Arduino.h>
#include <Adafruit_GFX.h>
#include <initializer_list>

namespace board {

// ---- Pins ----
constexpr int PIN_LCD_DC = 8;
constexpr int PIN_LCD_SCLK = 9;
constexpr int PIN_LCD_MOSI = 10;
constexpr int PIN_LCD_BL = 13;
constexpr int PIN_LCD_CS = 14;
constexpr int PIN_LCD_RST = 17;
constexpr int PIN_I2C_SCL = 11;
constexpr int PIN_I2C_SDA = 12;
constexpr int PIN_PA_CTRL = 4;
constexpr int PIN_I2S_MCLK = 5;
constexpr int PIN_I2S_DOUT = 6;
constexpr int PIN_I2S_BCLK = 15;
constexpr int PIN_I2S_LRCK = 16;
constexpr int PIN_POWER_OFF = 2;     // HIGH cuts battery power — keep LOW
constexpr int PIN_POWER_KEY = 3;     // middle button, active HIGH
constexpr int PIN_VOLUME_DOWN = 39;  // active LOW
constexpr int PIN_VOLUME_UP = 40;    // active LOW

constexpr int LCD_W = 240;
constexpr int LCD_H = 296;

// The glass has rounded corners (radius ~40px) and the case covers the edge, so
// anything near a corner is hidden. In the top and bottom ~40px rows, keep text
// and icons between SAFE_X and LCD_W - SAFE_X. Elsewhere, stay 6px from the sides.
constexpr int CORNER_R = 40;
constexpr int SAFE_X = 26;

constexpr uint16_t rgb(uint8_t r, uint8_t g, uint8_t b) {
  return ((r & 0xf8) << 8) | ((g & 0xfc) << 3) | (b >> 3);
}

// ---- Setup ----
// Holds the power latch, then brings up display, framebuffer, I2C, motion and
// sound. Returns false only if the framebuffer can't be allocated (PSRAM off).
bool begin();

// ---- Display ----
extern GFXcanvas16* fb;  // full-screen framebuffer (PSRAM); draw here, then lcdPush()
void lcdPush();
// Hands the finished frame to a background task and switches `fb` to a second
// buffer, so the next frame is drawn while this one is sent. `fb` then holds
// stale content: redraw the whole screen every frame when using this.
void lcdPushAsync();
void backlight(bool on);
void centerText(int y, const char* s, uint16_t color, int size = 1);

// ---- Touch (screen coordinates) ----
bool touchRead(int& x, int& y);

// ---- Motion (roughly milli-g) ----
extern bool accelOk;
bool accelRead(int16_t& x, int16_t& y, int16_t& z);

// ---- Sound: square-wave notes on a background task ----
struct Note { uint16_t freq; uint16_t ms; };  // freq 0 = rest
extern bool audioOk;
void sfx(std::initializer_list<Note> notes);  // replaces whatever is playing

// ---- Buttons ----
struct Button {
  int pin;
  bool activeHigh;
  bool down;
  uint32_t changedAt;
};
Button volumeUp();
Button volumeDown();
bool pressed(Button& b, uint32_t now);  // debounced press edge

// Middle key: short press, or a long hold (used for power off).
class MiddleKey {
 public:
  enum class Event { None, Short, Hold };
  static constexpr uint32_t HOLD_MS = 3000;

  void begin();
  Event poll(uint32_t now);
  // How long the current hold has lasted, 0 when not held (or not armed).
  uint32_t heldMs(uint32_t now) const;
  // Ignore the button until it is released again.
  void disarm() { armed_ = false; }

 private:
  bool down_ = false;
  bool armed_ = false;  // false until released once (it may be held at power-on)
  uint32_t changedAt_ = 0, downAt_ = 0;
};

// ---- Power ----
// Cuts battery power. Returns only if the board is still running, which means
// it is on USB power (USB keeps it alive whatever the latch says).
void powerOff();

}  // namespace board

// An app on the Cheeko Gotchi. main.cpp owns the buttons, the console and the
// screen push; apps just react and draw. Hold + and - together to switch apps.

#pragma once

#include <Arduino.h>

struct App {
  const char* name;
  void (*init)();                    // once at boot
  void (*enter)();                   // shown
  void (*leave)();                   // hidden
  void (*frame)(uint32_t now);       // update and draw the whole screen into board::fb
  void (*background)(uint32_t now);  // while another app is shown
  void (*plus)();                    // short press, acted on release
  void (*minus)();
  void (*middle)();
  void (*beforePowerOff)();          // save state, draw a goodbye screen into board::fb
  bool (*command)(const char* line); // console line; false if not this app's
  const char* help;                  // its console commands
};

namespace pip { extern const App app; }
namespace nav { extern const App app; }

// A short message drawn over whatever app is showing.
void showToast(const char* text, uint32_t ms, int size = 1);

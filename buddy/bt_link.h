// Bluetooth LE link to the Mac helper (../mac). The Mac writes one text
// message (PROTOCOL.md) per write to RX; the device notifies "H" on TX when
// the Mac subscribes, asking it to send everything again.

#pragma once

#include <Arduino.h>

namespace bt {

constexpr const char* DEVICE_NAME = "Claude Buddy";
constexpr const char* SERVICE_UUID = "c1a0de01-b0d7-4c1a-9e5e-6275646479a1";
constexpr const char* RX_UUID = "c1a0de02-b0d7-4c1a-9e5e-6275646479a1";  // Mac -> device, write
constexpr const char* TX_UUID = "c1a0de03-b0d7-4c1a-9e5e-6275646479a1";  // device -> Mac, notify
constexpr size_t MAX_MESSAGE = 256;

void begin();
bool connected();
// Takes the next message the Mac sent, NUL-terminated, if any. Call from the
// main loop: the Bluetooth stack runs on its own task, so messages are queued.
bool receive(char* buf, size_t size);
void notify(const char* text);

}  // namespace bt

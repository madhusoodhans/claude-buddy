// Bluetooth LE link to the phone. The phone writes protocol messages
// (PROTOCOL.md) to the RX characteristic, one message per write; the device
// notifies HELLO on TX when the phone subscribes, asking for the route again.

#pragma once

#include <Arduino.h>

namespace ble {

constexpr const char* DEVICE_NAME = "Cheeko";
constexpr const char* SERVICE_UUID = "6e3a0001-6c3f-4b6a-9c2e-8f1d2c3b4a50";
constexpr const char* RX_UUID = "6e3a0002-6c3f-4b6a-9c2e-8f1d2c3b4a50";  // phone -> device, write
constexpr const char* TX_UUID = "6e3a0003-6c3f-4b6a-9c2e-8f1d2c3b4a50";  // device -> phone, notify
constexpr size_t MAX_MESSAGE = 512;

void begin();
bool connected();
// Takes the next message the phone sent, if any. Call from the main loop: the
// Bluetooth stack runs on its own task, so messages are queued, not applied.
bool receive(uint8_t* buf, size_t* len);
void notify(const uint8_t* data, size_t len);

}  // namespace ble

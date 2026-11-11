#include "ble_link.h"

#include <NimBLEDevice.h>

namespace ble {

struct Message {
  uint16_t len;
  uint8_t data[MAX_MESSAGE];
};

static QueueHandle_t inbox;
static NimBLECharacteristic* tx;
static volatile bool isConnected = false;

class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* server, NimBLEConnInfo& info) override {
    isConnected = true;
    // Ask for a short connection interval: route uploads are many small writes.
    server->updateConnParams(info.getConnHandle(), 12, 24, 0, 400);
  }
  void onDisconnect(NimBLEServer*, NimBLEConnInfo&, int) override {
    isConnected = false;
    NimBLEDevice::startAdvertising();
  }
};

class RxCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c, NimBLEConnInfo&) override {
    static Message m;  // only the Bluetooth task writes here
    NimBLEAttValue v = c->getValue();
    m.len = min((size_t)v.length(), MAX_MESSAGE);
    memcpy(m.data, v.data(), m.len);
    xQueueSend(inbox, &m, 0);  // full queue: drop, the phone resends every second
  }
};

class TxCallbacks : public NimBLECharacteristicCallbacks {
  void onSubscribe(NimBLECharacteristic* c, NimBLEConnInfo&, uint16_t subValue) override {
    if (subValue) {
      const uint8_t hello = 0x20;  // HELLO: send me the route again
      c->setValue(&hello, 1);
      c->notify();
    }
  }
};

void begin() {
  inbox = xQueueCreate(64, sizeof(Message));  // street uploads arrive in bursts
  NimBLEDevice::init(DEVICE_NAME);
  NimBLEDevice::setMTU(247);
  NimBLEServer* server = NimBLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  NimBLEService* svc = server->createService(SERVICE_UUID);
  NimBLECharacteristic* rx = svc->createCharacteristic(RX_UUID, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  rx->setCallbacks(new RxCallbacks());
  tx = svc->createCharacteristic(TX_UUID, NIMBLE_PROPERTY::NOTIFY);
  tx->setCallbacks(new TxCallbacks());
  svc->start();

  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->setName(DEVICE_NAME);
  adv->enableScanResponse(true);
  adv->start();
}

bool connected() { return isConnected; }

bool receive(uint8_t* buf, size_t* len) {
  static Message m;
  if (xQueueReceive(inbox, &m, 0) != pdTRUE) return false;
  memcpy(buf, m.data, m.len);
  *len = m.len;
  return true;
}

void notify(const uint8_t* data, size_t len) {
  if (!isConnected) return;
  tx->setValue(data, len);
  tx->notify();
}

}  // namespace ble

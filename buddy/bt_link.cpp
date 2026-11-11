#include "bt_link.h"

#include <NimBLEDevice.h>

namespace bt {

struct Message {
  uint16_t len;
  char data[MAX_MESSAGE];
};

static QueueHandle_t inbox;
static NimBLECharacteristic* tx;
static volatile bool isConnected = false;

class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer*, NimBLEConnInfo&) override { isConnected = true; }
  void onDisconnect(NimBLEServer*, NimBLEConnInfo&, int) override {
    isConnected = false;
    NimBLEDevice::startAdvertising();
  }
};

class RxCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c, NimBLEConnInfo&) override {
    static Message m;  // only the Bluetooth task writes here
    NimBLEAttValue v = c->getValue();
    m.len = min((size_t)v.length(), MAX_MESSAGE - 1);
    memcpy(m.data, v.data(), m.len);
    m.data[m.len] = 0;
    xQueueSend(inbox, &m, 0);  // full queue: drop, the Mac resends every few seconds
  }
};

class TxCallbacks : public NimBLECharacteristicCallbacks {
  void onSubscribe(NimBLECharacteristic* c, NimBLEConnInfo&, uint16_t subValue) override {
    if (subValue) {
      c->setValue((const uint8_t*)"H", 1);  // HELLO: send me everything
      c->notify();
    }
  }
};

void begin() {
  inbox = xQueueCreate(24, sizeof(Message));
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

bool receive(char* buf, size_t size) {
  static Message m;
  if (xQueueReceive(inbox, &m, 0) != pdTRUE) return false;
  strlcpy(buf, m.data, size);
  return true;
}

void notify(const char* text) {
  if (!isConnected) return;
  tx->setValue((const uint8_t*)text, strlen(text));
  tx->notify();
}

}  // namespace bt

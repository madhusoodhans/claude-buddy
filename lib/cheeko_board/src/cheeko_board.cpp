#include "cheeko_board.h"

#include <SPI.h>
#include <Wire.h>
#include "driver/i2s.h"

namespace board {

static constexpr uint8_t CST810_ADDR = 0x15;
static constexpr uint8_t ES8311_ADDR = 0x18;
static constexpr uint8_t LIS2DH12_ADDR = 0x19;

GFXcanvas16* fb = nullptr;
bool accelOk = false;
bool audioOk = false;

// ============================================================================
// Display
// ============================================================================

static void lcdCmd(uint8_t c) {
  digitalWrite(PIN_LCD_DC, LOW);
  digitalWrite(PIN_LCD_CS, LOW);
  SPI.write(c);
  digitalWrite(PIN_LCD_CS, HIGH);
}

static void lcdData(uint8_t d) {
  digitalWrite(PIN_LCD_DC, HIGH);
  digitalWrite(PIN_LCD_CS, LOW);
  SPI.write(d);
  digitalWrite(PIN_LCD_CS, HIGH);
}

static void lcdSetWindow(uint16_t x0, uint16_t y0, uint16_t x1, uint16_t y1) {
  lcdCmd(0x2a);
  lcdData(x0 >> 8); lcdData(x0 & 0xff); lcdData(x1 >> 8); lcdData(x1 & 0xff);
  lcdCmd(0x2b);
  lcdData(y0 >> 8); lcdData(y0 & 0xff); lcdData(y1 >> 8); lcdData(y1 & 0xff);
  lcdCmd(0x2c);
}

// JD9853 2.01" 240x296 panel setup, from the vendor's hardware test
// (cheeko-gotchi/firmware/hardware_test, JD9853_PANEL_INIT). The panel keeps
// these registers until it loses power, so a short generic init only *seems*
// to work after another firmware has run: after a real power-off the panel
// comes up mirrored with red and blue swapped. Always send the full sequence.
struct LcdInitCmd {
  uint8_t cmd;
  uint8_t len;
  uint8_t data[32];
  uint8_t delayMs;
};
static const LcdInitCmd JD9853_INIT[] = {
    {0xDF, 2, {0x98, 0x53}, 0},
    {0xDE, 1, {0x00}, 0},
    {0xB2, 1, {0x25}, 0},
    {0xB7, 4, {0x00, 0x29, 0x00, 0x51}, 0},
    {0xBB, 6, {0x4F, 0x1A, 0x55, 0x73, 0x63, 0xF0}, 0},
    {0xC0, 2, {0x44, 0xA4}, 0},
    {0xC1, 1, {0x12}, 0},
    {0xC3, 8, {0x7D, 0x07, 0x14, 0x06, 0xC8, 0x71, 0x6C, 0x77}, 0},
    {0xC4, 12, {0x00, 0x00, 0x94, 0x79, 0x25, 0x0A, 0x16, 0x79, 0x25, 0x0A, 0x16, 0x82}, 0},
    {0xC8, 32, {0x3F, 0x34, 0x2D, 0x26, 0x2B, 0x2B, 0x25, 0x24, 0x23, 0x22, 0x20, 0x17, 0x14, 0x0E, 0x06, 0x00,
                0x3F, 0x34, 0x2D, 0x26, 0x2B, 0x2B, 0x25, 0x24, 0x23, 0x22, 0x20, 0x17, 0x14, 0x0E, 0x06, 0x00}, 0},
    {0xD0, 5, {0x04, 0x06, 0x6B, 0x0F, 0x00}, 0},
    {0xD7, 2, {0x00, 0x30}, 0},
    {0xE6, 1, {0x10}, 0},
    {0xDE, 1, {0x01}, 0},
    {0xB7, 5, {0x03, 0x13, 0xEF, 0x35, 0x35}, 0},
    {0xC1, 3, {0x14, 0x15, 0xC0}, 0},
    {0xC2, 2, {0x06, 0x3A}, 0},
    {0xC4, 2, {0x72, 0x12}, 0},
    {0xBE, 1, {0x00}, 0},
    {0xDE, 1, {0x00}, 0},
    {0x35, 1, {0x00}, 0},
    {0x3A, 1, {0x05}, 0},                    // RGB565
    {0x2A, 4, {0x00, 0x00, 0x00, 0xEF}, 0},  // columns 0..239
    {0x2B, 4, {0x00, 0x00, 0x01, 0x27}, 0},  // rows 0..295
    {0x11, 0, {}, 120},                      // sleep out
    {0x29, 0, {}, 10},                       // display on
};

static void lcdInit() {
  pinMode(PIN_LCD_CS, OUTPUT);
  pinMode(PIN_LCD_DC, OUTPUT);
  pinMode(PIN_LCD_RST, OUTPUT);
  pinMode(PIN_LCD_BL, OUTPUT);
  digitalWrite(PIN_LCD_CS, HIGH);
  digitalWrite(PIN_LCD_BL, HIGH);

  SPI.begin(PIN_LCD_SCLK, -1, PIN_LCD_MOSI, -1);
  SPI.setFrequency(40000000);
  SPI.setDataMode(SPI_MODE0);

  digitalWrite(PIN_LCD_RST, LOW);  delay(10);
  digitalWrite(PIN_LCD_RST, HIGH); delay(10);
  lcdCmd(0x11); delay(100);                // SLPOUT
  // MADCTL: no mirroring, RGB order. (The vendor driver uses 0x08/BGR, but it also
  // sends its pixels in the other byte order; with ours, 0x08 swaps red and blue.)
  lcdCmd(0x36); lcdData(0x00);
  lcdCmd(0x3a); lcdData(0x55);             // RGB565
  for (const LcdInitCmd& c : JD9853_INIT) {
    lcdCmd(c.cmd);
    for (int i = 0; i < c.len; ++i) lcdData(c.data[i]);
    if (c.delayMs) delay(c.delayMs);
  }
}

static void sendFrame(const uint16_t* pixels) {
  lcdSetWindow(0, 0, LCD_W - 1, LCD_H - 1);
  digitalWrite(PIN_LCD_DC, HIGH);
  digitalWrite(PIN_LCD_CS, LOW);
  SPI.writePixels(pixels, LCD_W * LCD_H * 2);  // swaps to big-endian
  digitalWrite(PIN_LCD_CS, HIGH);
}

// ---- Double buffering: a task on core 0 sends one buffer while we draw the other ----
static GFXcanvas16* canvases[2];
static int drawing = 0;
static TaskHandle_t pushTask;
static SemaphoreHandle_t lcdFree;  // held while a frame is being sent
static const uint16_t* pendingFrame;

static void pushTaskFn(void*) {
  for (;;) {
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
    sendFrame(pendingFrame);
    xSemaphoreGive(lcdFree);
    vTaskDelay(1);  // let core 0's idle task run, or the watchdog resets the chip
  }
}

void lcdPush() {
  xSemaphoreTake(lcdFree, portMAX_DELAY);
  sendFrame(fb->getBuffer());
  xSemaphoreGive(lcdFree);
}

void lcdPushAsync() {
  xSemaphoreTake(lcdFree, portMAX_DELAY);  // previous frame finished sending
  pendingFrame = fb->getBuffer();
  drawing ^= 1;
  fb = canvases[drawing];
  xTaskNotifyGive(pushTask);
}

void backlight(bool on) { digitalWrite(PIN_LCD_BL, on ? HIGH : LOW); }

void centerText(int y, const char* s, uint16_t color, int size) {
  int16_t bx, by;
  uint16_t w, h;
  fb->setTextSize(size);
  fb->getTextBounds(s, 0, 0, &bx, &by, &w, &h);
  fb->setTextColor(color);
  fb->setCursor((LCD_W - w) / 2, y);
  fb->print(s);
}

// ============================================================================
// I2C helpers, touch, accelerometer
// ============================================================================

static bool i2cWrite(uint8_t addr, uint8_t reg, uint8_t val) {
  Wire.beginTransmission(addr);
  Wire.write(reg);
  Wire.write(val);
  return Wire.endTransmission() == 0;
}

static bool i2cRead(uint8_t addr, uint8_t reg, uint8_t* buf, size_t n) {
  Wire.beginTransmission(addr);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) return false;
  if (Wire.requestFrom((uint16_t)addr, (size_t)n) != n) return false;
  for (size_t i = 0; i < n; ++i) buf[i] = Wire.read();
  return true;
}

bool touchRead(int& x, int& y) {
  uint8_t d[5] = {};
  if (!i2cRead(CST810_ADDR, 0x02, d, sizeof(d))) return false;
  if ((d[0] & 0x0f) == 0) return false;
  int rawX = ((d[1] & 0x0f) << 8) | d[2];
  int rawY = ((d[3] & 0x0f) << 8) | d[4];
  // Touch panel is rotated 90° vs the display (SKILL.md, Gotcha 3).
  x = constrain((rawY - 12) * 180 / 211 + 30, 0, LCD_W - 1);
  y = constrain((260 - rawX) * 216 / 222 + 40, 0, LCD_H - 1);
  return true;
}

static bool accelInit() {
  uint8_t who = 0;
  if (!i2cRead(LIS2DH12_ADDR, 0x0f, &who, 1) || who != 0x33) return false;
  i2cWrite(LIS2DH12_ADDR, 0x20, 0x57);  // 100Hz, XYZ on
  i2cWrite(LIS2DH12_ADDR, 0x23, 0x88);  // BDU, high-res
  return true;
}

bool accelRead(int16_t& x, int16_t& y, int16_t& z) {
  if (!accelOk) return false;
  uint8_t raw[6] = {};
  if (!i2cRead(LIS2DH12_ADDR, 0x28 | 0x80, raw, sizeof(raw))) return false;
  x = (int16_t)((raw[1] << 8) | raw[0]) >> 4;
  y = (int16_t)((raw[3] << 8) | raw[2]) >> 4;
  z = (int16_t)((raw[5] << 8) | raw[4]) >> 4;
  return true;
}

// ============================================================================
// Audio — square-wave chiptune on a background task so the UI never blocks
// ============================================================================

static constexpr uint32_t AUDIO_SAMPLE_RATE = 16000;
static constexpr uint32_t AUDIO_MCLK_HZ = 4096000;

static QueueHandle_t soundQueue;

static void audioInit() {
  i2s_config_t cfg = {};
  cfg.mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_TX);
  cfg.sample_rate = AUDIO_SAMPLE_RATE;
  cfg.bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT;
  cfg.channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT;
  cfg.communication_format = I2S_COMM_FORMAT_STAND_I2S;
  cfg.dma_buf_count = 4;
  cfg.dma_buf_len = 128;
  cfg.tx_desc_auto_clear = true;
  cfg.fixed_mclk = AUDIO_MCLK_HZ;

  i2s_pin_config_t pins = {};
  pins.mck_io_num = PIN_I2S_MCLK;
  pins.bck_io_num = PIN_I2S_BCLK;
  pins.ws_io_num = PIN_I2S_LRCK;
  pins.data_out_num = PIN_I2S_DOUT;
  pins.data_in_num = I2S_PIN_NO_CHANGE;

  if (i2s_driver_install(I2S_NUM_0, &cfg, 0, nullptr) != ESP_OK) return;
  i2s_set_pin(I2S_NUM_0, &pins);
  i2s_zero_dma_buffer(I2S_NUM_0);

  pinMode(PIN_PA_CTRL, OUTPUT);
  digitalWrite(PIN_PA_CTRL, HIGH);

  // ES8311 DAC-only setup, 16-bit / 16kHz / 4.096MHz MCLK.
  if (!i2cWrite(ES8311_ADDR, 0x00, 0x1f)) return;
  delay(20);
  static const uint8_t regs[][2] = {
      {0x00, 0x00}, {0x00, 0x80}, {0x01, 0x3f}, {0x02, 0x00}, {0x03, 0x10},
      {0x04, 0x10}, {0x05, 0x00}, {0x06, 0x03}, {0x07, 0x00}, {0x08, 0xff},
      {0x09, 0x0c}, {0x0a, 0x0c}, {0x0d, 0x01}, {0x0e, 0x02}, {0x12, 0x00},
      {0x13, 0x10}, {0x1c, 0x6a}, {0x31, 0x00}, {0x32, 0xbf}, {0x37, 0x08},
  };
  for (auto& r : regs) i2cWrite(ES8311_ADDR, r[0], r[1]);
  audioOk = true;
}

static void playSquare(uint16_t freq, int durationMs, int amplitude) {
  int16_t samples[64 * 2];
  size_t written = 0;
  int total = (AUDIO_SAMPLE_RATE * durationMs) / 1000;
  if (freq == 0) { freq = 1000; amplitude = 0; }  // rest
  int halfPeriod = max(1, (int)(AUDIO_SAMPLE_RATE / freq / 2));
  for (int frame = 0; frame < total; frame += 64) {
    int count = min(64, total - frame);
    for (int i = 0; i < count; ++i) {
      int n = frame + i;
      float env = 1.0f - (float)n / max(1, total) * 0.6f;
      int16_t s = (int16_t)(((n / halfPeriod) % 2 ? -amplitude : amplitude) * env);
      samples[i * 2] = s;
      samples[i * 2 + 1] = s;
    }
    i2s_write(I2S_NUM_0, samples, count * 2 * sizeof(int16_t), &written, portMAX_DELAY);
  }
}

static void soundTask(void*) {
  Note n;
  for (;;) {
    if (xQueueReceive(soundQueue, &n, portMAX_DELAY) == pdTRUE) playSquare(n.freq, n.ms, 2500);
  }
}

void sfx(std::initializer_list<Note> notes) {
  if (!audioOk) return;
  xQueueReset(soundQueue);  // newest sound wins
  for (const Note& n : notes) xQueueSend(soundQueue, &n, 0);
}

// ============================================================================
// Buttons and power
// ============================================================================

Button volumeUp() { return {PIN_VOLUME_UP, false, false, 0}; }
Button volumeDown() { return {PIN_VOLUME_DOWN, false, false, 0}; }

bool pressed(Button& b, uint32_t now) {
  bool level = digitalRead(b.pin) == (b.activeHigh ? HIGH : LOW);
  if (level == b.down || now - b.changedAt < 40) return false;
  b.down = level;
  b.changedAt = now;
  return level;
}

void MiddleKey::begin() {
  down_ = digitalRead(PIN_POWER_KEY) == HIGH;
  armed_ = !down_;
}

MiddleKey::Event MiddleKey::poll(uint32_t now) {
  bool level = digitalRead(PIN_POWER_KEY) == HIGH;
  if (level != down_ && now - changedAt_ >= 40) {
    down_ = level;
    changedAt_ = now;
    if (level) {
      downAt_ = now;
    } else {
      bool wasArmed = armed_;
      armed_ = true;
      if (wasArmed && now - downAt_ < 1000) return Event::Short;
    }
  }
  if (armed_ && down_ && now - downAt_ >= HOLD_MS) {
    armed_ = false;  // one Hold per press
    return Event::Hold;
  }
  return Event::None;
}

uint32_t MiddleKey::heldMs(uint32_t now) const {
  return (armed_ && down_) ? now - downAt_ : 0;
}

void powerOff() {
  backlight(false);
  digitalWrite(PIN_POWER_OFF, HIGH);  // cuts battery power (hold ~2.8s)
  delay(3500);
  digitalWrite(PIN_POWER_OFF, LOW);
  backlight(true);
}

// ============================================================================

bool begin() {
  pinMode(PIN_POWER_OFF, OUTPUT);
  digitalWrite(PIN_POWER_OFF, LOW);  // HIGH would cut power (Gotcha 8)
  pinMode(PIN_VOLUME_UP, INPUT_PULLUP);
  pinMode(PIN_VOLUME_DOWN, INPUT_PULLUP);
  pinMode(PIN_POWER_KEY, INPUT);

  lcdInit();
  for (auto& c : canvases) {
    c = new GFXcanvas16(LCD_W, LCD_H);
    if (!c->getBuffer()) return false;
  }
  fb = canvases[drawing];
  lcdFree = xSemaphoreCreateBinary();
  xSemaphoreGive(lcdFree);
  xTaskCreatePinnedToCore(pushTaskFn, "lcd", 4096, nullptr, 3, &pushTask, 0);
  fb->fillScreen(0);
  lcdPush();

  Wire.begin(PIN_I2C_SDA, PIN_I2C_SCL, 400000);
  accelOk = accelInit();

  soundQueue = xQueueCreate(16, sizeof(Note));
  audioInit();
  xTaskCreatePinnedToCore(soundTask, "sound", 4096, nullptr, 2, nullptr, 0);
  return true;
}

}  // namespace board

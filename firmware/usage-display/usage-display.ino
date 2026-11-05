#define LGFX_USE_V1
#include <ArduinoJson.h>
#include <ESPmDNS.h>
#include <LovyanGFX.hpp>
#include <WebServer.h>
#include <WiFi.h>
#include <time.h>

#include "wifi_secrets.h"

constexpr const char *HOSTNAME = "llmusage-display";

constexpr int PIN_LCD_SCLK = 39;
constexpr int PIN_LCD_MOSI = 38;
constexpr int PIN_LCD_DC = 42;
constexpr int PIN_LCD_CS = 45;
constexpr int PIN_LCD_RST = 0;
constexpr int PIN_LCD_BL = 1;
constexpr int PIN_SD_CS = 41;

constexpr int SCREEN_W = 320;
constexpr int SCREEN_H = 240;
constexpr int NAME_X = 6;
constexpr int NAME_W = 64;
constexpr int LABEL_X = 74;
constexpr int BAR_X = 86;
constexpr int BAR_W = 134;
constexpr int BAR_H = 12;
constexpr int PERCENT_RIGHT = 268;
constexpr int TIME_RIGHT = 314;

constexpr uint32_t COLOR_BG = 0x000000;
constexpr uint32_t COLOR_TEXT = 0xFFFFFF;
constexpr uint32_t COLOR_DIM = 0x8E8E93;
constexpr uint32_t COLOR_TRACK = 0x2C2C2E;
constexpr uint32_t COLOR_DIVIDER = 0x3A3A3C;
constexpr uint32_t COLOR_OK = 0x30D158;
constexpr uint32_t COLOR_WARN = 0xFF9F0A;
constexpr uint32_t COLOR_HIGH = 0xFF453A;

constexpr uint8_t BRIGHTNESS_FRESH = 200;
constexpr uint8_t BRIGHTNESS_STALE = 24;
constexpr uint32_t REDRAW_MS = 30000;
constexpr uint32_t REJOIN_MS = 30000;
constexpr time_t STALE_MIN_SEC = 180;
constexpr time_t STALE_INITIAL_SEC = 2100;

constexpr int MAX_PROVIDERS = 4;
constexpr int MAX_LINES = 3;

struct Line {
  char label;
  int percent;
  time_t resetsAt;
  bool active;
  char text[28];
};

struct Provider {
  char name[16];
  char error[44];
  Line lines[MAX_LINES];
  int lineCount;
};

class Display : public lgfx::LGFX_Device {
  lgfx::Panel_ST7789 panel;
  lgfx::Bus_SPI bus;

 public:
  Display() {
    auto b = bus.config();
    b.spi_host = SPI2_HOST;
    b.spi_mode = 0;
    b.freq_write = 40000000;
    b.pin_sclk = PIN_LCD_SCLK;
    b.pin_mosi = PIN_LCD_MOSI;
    b.pin_miso = -1;
    b.pin_dc = PIN_LCD_DC;
    b.dma_channel = SPI_DMA_CH_AUTO;
    bus.config(b);
    panel.setBus(&bus);

    auto p = panel.config();
    p.pin_cs = PIN_LCD_CS;
    p.pin_rst = PIN_LCD_RST;
    p.panel_width = 240;
    p.panel_height = 320;
    p.invert = true;
    p.readable = false;
    panel.config(p);
    setPanel(&panel);
  }
};

static Display lcd;
static LGFX_Sprite canvas(&lcd);
static WebServer server(80);

static Provider providers[MAX_PROVIDERS];
static int providerCount = 0;
static time_t updatedAt = 0;
static time_t staleAfter = STALE_INITIAL_SEC;
static time_t clockBase = 0;
static uint32_t clockBaseMs = 0;
static uint32_t lastRenderMs = 0;
static bool wifiUp = false;
static bool mdnsUp = false;
static volatile uint8_t disconnectReason = 0;
static uint8_t shownReason = 0;
static uint32_t lastStatusMs = 0;
static uint32_t lastJoinMs = 0;

static time_t nowSeconds() {
  return clockBase + time_t((millis() - clockBaseMs) / 1000);
}

static time_t parseTime(const char *text) {
  if (text == nullptr || text[0] == '\0') return 0;
  struct tm parts = {};
  if (strptime(text, "%Y-%m-%dT%H:%M:%SZ", &parts) == nullptr) return 0;
  return mktime(&parts);
}

static uint32_t barColor(int percent) {
  if (percent >= 90) return COLOR_HIGH;
  if (percent >= 70) return COLOR_WARN;
  return COLOR_OK;
}

static void formatRemaining(const Line &line, char *out, size_t size) {
  if (!line.active || line.resetsAt == 0) {
    snprintf(out, size, "--");
    return;
  }
  const time_t left = line.resetsAt - nowSeconds();
  const long minutes = left > 0 ? (left + 59) / 60 : 0;
  const long days = minutes / 1440;
  const long hours = (minutes % 1440) / 60;
  if (days > 0) {
    snprintf(out, size, "%ldd%ldh", days, hours);
  } else if (hours > 0) {
    snprintf(out, size, "%ldh%ldm", hours, minutes % 60);
  } else {
    snprintf(out, size, "%ldm", minutes);
  }
}

static void drawLine(const Line &line, int y) {
  canvas.setFont(&fonts::DejaVu12);
  canvas.setTextDatum(textdatum_t::middle_left);
  canvas.setTextColor(COLOR_DIM);
  const char label[2] = {line.label, '\0'};
  canvas.drawString(label, LABEL_X, y);

  if (line.percent < 0) {
    canvas.drawString(line.text, BAR_X, y);
    return;
  }

  const int top = y - BAR_H / 2;
  canvas.fillRoundRect(BAR_X, top, BAR_W, BAR_H, 3, COLOR_TRACK);
  const int clamped = constrain(line.percent, 0, 100);
  const int filled = BAR_W * clamped / 100;
  if (filled > 0) {
    canvas.fillRoundRect(BAR_X, top, max(filled, 6), BAR_H, 3, barColor(line.percent));
  }

  char text[12];
  snprintf(text, sizeof(text), "%d%%", line.percent);
  canvas.setFont(&fonts::DejaVu18);
  canvas.setTextDatum(textdatum_t::middle_right);
  canvas.setTextColor(COLOR_TEXT);
  canvas.drawString(text, PERCENT_RIGHT, y);

  formatRemaining(line, text, sizeof(text));
  canvas.setFont(&fonts::DejaVu12);
  canvas.setTextColor(COLOR_DIM);
  canvas.drawString(text, TIME_RIGHT, y);
}

static void drawProvider(const Provider &provider, int top, int height) {
  const int centre = top + height / 2;
  canvas.setFont(&fonts::DejaVu18);
  if (canvas.textWidth(provider.name) > NAME_W) canvas.setFont(&fonts::DejaVu12);
  canvas.setTextDatum(textdatum_t::middle_left);
  canvas.setTextColor(COLOR_TEXT);
  canvas.drawString(provider.name, NAME_X, centre);

  if (provider.error[0] != '\0') {
    canvas.setFont(&fonts::DejaVu12);
    canvas.setTextColor(COLOR_WARN);
    canvas.drawString(provider.error, LABEL_X, centre);
    return;
  }

  const int lineHeight = provider.lineCount > 0 ? height / provider.lineCount : height;
  for (int i = 0; i < provider.lineCount; i++) {
    drawLine(provider.lines[i], top + lineHeight * i + lineHeight / 2);
  }
}

static void render() {
  lastRenderMs = millis();
  canvas.fillScreen(COLOR_BG);

  if (providerCount == 0) {
    canvas.setFont(&fonts::DejaVu18);
    canvas.setTextDatum(textdatum_t::middle_center);
    canvas.setTextColor(COLOR_DIM);
    const String state = wifiUp ? WiFi.localIP().toString() : String("Wi-Fi");
    canvas.drawString(state.c_str(), SCREEN_W / 2, SCREEN_H / 2);
    if (!wifiUp && disconnectReason != 0) {
      canvas.setFont(&fonts::DejaVu12);
      canvas.drawString(WiFi.disconnectReasonName(wifi_err_reason_t(disconnectReason)), SCREEN_W / 2,
                        SCREEN_H / 2 + 22);
    }
  } else {
    const int rowHeight = SCREEN_H / providerCount;
    for (int i = 0; i < providerCount; i++) {
      const int top = rowHeight * i;
      if (i > 0) canvas.drawFastHLine(0, top, SCREEN_W, COLOR_DIVIDER);
      drawProvider(providers[i], top, rowHeight);
    }
  }

  canvas.pushSprite(0, 0);

  const bool stale = updatedAt != 0 && nowSeconds() - updatedAt > staleAfter;
  ledcWrite(PIN_LCD_BL, stale ? BRIGHTNESS_STALE : BRIGHTNESS_FRESH);
}

static bool ingest(const String &body, time_t pushedAt) {
  JsonDocument doc;
  if (deserializeJson(doc, body)) return false;
  JsonArrayConst list = doc["providers"];
  const time_t updated = parseTime(doc["updated_at"] | "");
  if (list.isNull() || updated == 0) return false;

  int count = 0;
  for (JsonObjectConst source : list) {
    if (count == MAX_PROVIDERS) break;
    Provider &target = providers[count++];
    strlcpy(target.name, source["name"] | "?", sizeof(target.name));
    strlcpy(target.error, source["error"] | "", sizeof(target.error));
    target.lineCount = 0;
    for (JsonObjectConst row : source["lines"].as<JsonArrayConst>()) {
      if (target.lineCount == MAX_LINES) break;
      Line &line = target.lines[target.lineCount++];
      const char *label = row["label"] | "?";
      line.label = label[0];
      line.percent = row["used_percent"].is<int>() ? row["used_percent"].as<int>() : -1;
      line.resetsAt = parseTime(row["resets_at"] | "");
      line.active = row["window_is_active"] | true;
      strlcpy(line.text, row["text"] | "", sizeof(line.text));
    }
  }
  providerCount = count;

  if (updated != updatedAt) {
    if (updatedAt != 0 && updated > updatedAt) {
      staleAfter = max(STALE_MIN_SEC, (updated - updatedAt) * 3);
    }
    updatedAt = updated;
  }
  clockBase = pushedAt != 0 ? pushedAt : updated;
  clockBaseMs = millis();
  return true;
}

static void handleUsage() {
  const time_t pushedAt = strtoll(server.header("X-Now").c_str(), nullptr, 10);
  if (!ingest(server.arg("plain"), pushedAt)) {
    server.send(400, "text/plain", "bad usage document\n");
    return;
  }
  server.send(204);
  render();
}

static void handleHealth() {
  JsonDocument doc;
  doc["uptime_s"] = millis() / 1000;
  doc["reset_reason"] = int(esp_reset_reason());
  doc["rssi"] = WiFi.RSSI();
  doc["bssid"] = WiFi.BSSIDstr();
  doc["channel"] = WiFi.channel();
  doc["providers"] = providerCount;
  doc["updated_at"] = updatedAt;
  doc["stale"] = updatedAt != 0 && nowSeconds() - updatedAt > staleAfter;
  String body;
  serializeJson(doc, body);
  server.send(200, "application/json", body);
}

static void handleScan() {
  const int found = WiFi.scanNetworks();
  JsonDocument doc;
  JsonArray aps = doc.to<JsonArray>();
  for (int i = 0; i < found; i++) {
    if (WiFi.SSID(i) != WIFI_SSID) continue;
    JsonObject ap = aps.add<JsonObject>();
    ap["bssid"] = WiFi.BSSIDstr(i);
    ap["channel"] = WiFi.channel(i);
    ap["rssi"] = WiFi.RSSI(i);
  }
  WiFi.scanDelete();
  String body;
  serializeJson(doc, body);
  server.send(200, "application/json", body);
}

// The driver's own connect scan joins a weaker AP on some boots, so pick the BSSID here.
static void joinStrongest() {
  WiFi.disconnect();
  const int found = WiFi.scanNetworks();
  int best = -1;
  for (int i = 0; i < found; i++) {
    if (WiFi.SSID(i) == WIFI_SSID && (best < 0 || WiFi.RSSI(i) > WiFi.RSSI(best))) best = i;
  }
  if (best >= 0) {
    uint8_t bssid[6];
    memcpy(bssid, WiFi.BSSID(best), sizeof(bssid));
    const int32_t channel = WiFi.channel(best);
    WiFi.scanDelete();
    WiFi.begin(WIFI_SSID, WIFI_PASSWORD, channel, bssid);
  } else {
    WiFi.scanDelete();
  }
  lastJoinMs = millis();
}

void setup() {
  Serial.begin(115200);
  setenv("TZ", "UTC0", 1);
  tzset();

  pinMode(PIN_SD_CS, OUTPUT);
  digitalWrite(PIN_SD_CS, HIGH);
  ledcAttach(PIN_LCD_BL, 5000, 8);
  ledcWrite(PIN_LCD_BL, 0);

  lcd.init();
  lcd.setRotation(1);
  canvas.setPsram(true);
  canvas.setColorDepth(16);
  canvas.createSprite(SCREEN_W, SCREEN_H);
  render();

  WiFi.persistent(false);
  WiFi.setHostname(HOSTNAME);
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  WiFi.setAutoReconnect(true);
  WiFi.onEvent(
      [](WiFiEvent_t, WiFiEventInfo_t info) {
        const uint8_t reason = info.wifi_sta_disconnected.reason;
        if (reason != WIFI_REASON_ASSOC_LEAVE) disconnectReason = reason;
      },
      ARDUINO_EVENT_WIFI_STA_DISCONNECTED);
  joinStrongest();

  const char *headers[] = {"X-Now"};
  server.collectHeaders(headers, 1);
  server.on("/usage", HTTP_POST, handleUsage);
  server.on("/health", HTTP_GET, handleHealth);
  server.on("/scan", HTTP_GET, handleScan);
  server.begin();
}

void loop() {
  server.handleClient();

  const bool connected = WiFi.status() == WL_CONNECTED;
  if (connected != wifiUp) {
    wifiUp = connected;
    if (connected) {
      Serial.printf("wifi: %s rssi=%d\n", WiFi.localIP().toString().c_str(), WiFi.RSSI());
      if (!mdnsUp && MDNS.begin(HOSTNAME)) {
        MDNS.addService("http", "tcp", 80);
        mdnsUp = true;
      }
    } else {
      Serial.println("wifi: down");
    }
    render();
  }

  if (disconnectReason != shownReason) {
    shownReason = disconnectReason;
    render();
  }

  if (!connected && millis() - lastStatusMs >= 5000) {
    lastStatusMs = millis();
    const uint8_t reason = disconnectReason;
    Serial.printf("wifi: status=%d reason=%s\n", int(WiFi.status()),
                  reason != 0 ? WiFi.disconnectReasonName(wifi_err_reason_t(reason)) : "-");
  }

  if (!connected && millis() - lastJoinMs >= REJOIN_MS) joinStrongest();

  if (millis() - lastRenderMs >= REDRAW_MS) render();
  delay(2);
}

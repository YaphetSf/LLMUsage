# LLMUsage desk display

```bash
./firmware/flash.sh
./firmware/install-push.sh
curl http://llmusage-display.local/health
curl http://llmusage-display.local/scan
launchctl print gui/$(id -u)/com.dz.llmusage.display
```

A Waveshare ESP32-S3 2-inch 240x320 LCD on the office Wi-Fi that shows the tracker's `usage.json`.

`flash.sh` builds and flashes over USB. It reads `WIFI_SSID` and `WIFI_PASSWORD` from
`~/.keys/env/office-wifi.env` and keeps the build in a temp folder, because the binary holds the password.

`install-push.sh` installs a launchd agent on this Mac that POSTs `usage.json` to the board whenever the file
changes and every minute, so a rebooted board fills in. The Mac opens no port.

The board dims when `updated_at` is older than three refresh intervals, measured from the pushes it has seen.

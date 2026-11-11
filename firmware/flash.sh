#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
wifi_env="$HOME/.keys/env/office-wifi.env"
fqbn="esp32:esp32:esp32s3:USBMode=hwcdc,CDCOnBoot=cdc,FlashSize=16M,PartitionScheme=app3M_fat9M_16MB,PSRAM=opi"

shopt -s nullglob
ports=(/dev/cu.usbmodem*)
if ((${#ports[@]} != 1)); then
  echo "expected one /dev/cu.usbmodem* port, found ${#ports[@]}" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$wifi_env"
set +a

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

python3 -I -c '
import json, os
ssid = json.dumps(os.environ["WIFI_SSID"], ensure_ascii=False)
password = json.dumps(os.environ["WIFI_PASSWORD"], ensure_ascii=False)
print(f"#define WIFI_SSID {ssid}\n#define WIFI_PASSWORD {password}")
' >"$tmp/wifi_secrets.h"

arduino-cli lib install LovyanGFX@1.2.36 ArduinoJson@7.4.3 >/dev/null

# Arduino's bundled ctags is x86_64 only and this Mac has no Rosetta; the sketch needs no generated prototypes.
arduino-cli compile --fqbn "$fqbn" \
  --build-path "$tmp/build" \
  --build-property "compiler.cpp.extra_flags=-I$tmp" \
  --build-property "tools.ctags.pattern=/usr/bin/true" \
  "$here/usage-display"

arduino-cli upload --fqbn "$fqbn" --port "${ports[0]}" --input-dir "$tmp/build" "$here/usage-display"

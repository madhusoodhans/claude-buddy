#!/usr/bin/env bash
# Build / flash / monitor helper for the Cheeko Gotchi.
#   ./pet.sh build              compile the firmware (Claude Buddy, in buddy/)
#   ./pet.sh flash              compile + upload
#   ./pet.sh monitor            serial console (type: help, demo, page 2, status, ...)
#   ./pet.sh port               show the detected device port
set -euo pipefail
cd "$(dirname "$0")"

FQBN="esp32:esp32:XIAO_ESP32S3:PSRAM=opi,PartitionScheme=tinyuf2_noota"
SKETCH="${2:-buddy}"
LIBS=(--library lib/cheeko_board)

port() {
  local p
  p=$(ls /dev/cu.usbmodem* 2>/dev/null | head -1 || true)
  if [[ -z "$p" ]]; then
    echo "No Cheeko Gotchi found on /dev/cu.usbmodem*. Plug it in with a data USB-C cable and power it on." >&2
    exit 1
  fi
  echo "$p"
}

case "${1:-build}" in
  build)   arduino-cli compile --fqbn "$FQBN" "${LIBS[@]}" "$SKETCH" ;;
  flash)   arduino-cli compile --fqbn "$FQBN" "${LIBS[@]}" "$SKETCH" && arduino-cli upload --fqbn "$FQBN" -p "$(port)" "$SKETCH" ;;
  monitor) arduino-cli monitor -p "$(port)" -c baudrate=115200 ;;
  port)    port ;;
  *)       echo "usage: $0 {build|flash|monitor|port}"; exit 1 ;;
esac

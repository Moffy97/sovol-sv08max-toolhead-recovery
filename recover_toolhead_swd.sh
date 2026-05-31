#!/bin/bash
# =============================================================================
#  recover_toolhead_swd.sh
#  Recover a "bricked" STM32F103 MCU (toolhead or filament buffer) of the
#  Sovol SV08 Max, using the printer's internal SBC (BTT CB1 / Allwinner H616)
#  as a bit-bang SWD programmer, via the TX/RX pins of the mainboard's
#  "5V RX TX GND" serial header.
#
#  NO ST-Link, NO Arduino. Just 3 wires and OpenOCD.
#
#  WIRING (printer ON, toolhead powered by its own 24 V):
#     mainboard TX  (PH0/GPIO224 = SWCLK) -> toolhead CK
#     mainboard RX  (PH1/GPIO225 = SWDIO) -> toolhead IO
#     mainboard GND                        -> toolhead G
#     (do NOT connect 3V3/5V; common ground also via the umbilical)
#
#  Run as root:  sudo bash recover_toolhead_swd.sh
# =============================================================================
set -u

# ------------------------------- CONFIG --------------------------------------
# Firmware to write (built for the Katapult 0x2000 offset):
#   Katapult F103 CAN:  make menuconfig -> STM32F103, "8KiB bootloader",
#                       8 MHz crystal, CAN on PB8/PB9, 1 Mbit  -> out/katapult.bin
#   Klipper  F103 CAN:  same "8KiB bootloader" choice (app at 0x08002000)
KATAPULT_BIN="/home/sovol/printer_data/build/toolhead_katapult.bin"   # -> 0x08000000
KLIPPER_BIN="/home/sovol/printer_data/build/extra_mcu_klipper.bin"    # -> 0x08002000

# SBC GPIO lines used for SWD (gpiochip0 lines).
# PH0=224, PH1=225 on the SV08 Max mainboard's UART0 "5V RX TX GND" header.
GPIOCHIP="0"
SWCLK="224"   # = header TX pin  -> toolhead CK pad
SWDIO="225"   # = header RX pin  -> toolhead IO pad

# UART to release (UART0 = 5000000.serial on H616). Driver: dw-apb-uart.
UART_DEV="5000000.serial"
UART_DRV="/sys/bus/platform/drivers/dw-apb-uart"
GETTY="serial-getty@ttyS0.service"

# Services to stop so the system is IDLE (bit-bang is jitter-sensitive):
SERVICES="klipper moonraker crowsnest KlipperScreen"

OPENOCD="openocd"   # system 0.11 is fine (with an idle system)
TARGET_CFG="/usr/share/openocd/scripts/target/stm32f1x.cfg"
# -----------------------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then echo "Run as root/sudo."; exit 1; fi
for f in "$KATAPULT_BIN" "$KLIPPER_BIN"; do
  [ -f "$f" ] || { echo "ERROR: missing firmware: $f"; exit 1; }
done

ocd_opts() {
  echo -n "-c 'adapter driver linuxgpiod' -c 'linuxgpiod_gpiochip $GPIOCHIP'"
  echo -n " -c 'linuxgpiod_swd_nums $1 $2' -c 'transport select swd'"
  echo -n " -c 'adapter speed 100' -f $TARGET_CFG"
}

echo "### 1) Stopping services (idle system for bit-banging)..."
systemctl stop $SERVICES 2>/dev/null
sleep 1
echo "    load: $(cut -d' ' -f1-3 /proc/loadavg)"

echo "### 2) Releasing the UART pins (PH0/PH1) from the serial console..."
systemctl stop "$GETTY" 2>/dev/null
echo "$UART_DEV" > "$UART_DRV/unbind" 2>/dev/null
sleep 1

echo "### 3) SWD connection test (retrying both orientations)..."
FOUND=""
for orient in "$SWCLK $SWDIO" "$SWDIO $SWCLK"; do
  set -- $orient
  for try in 1 2 3; do
    OUT=$(timeout 12 chrt -f 99 $OPENOCD $(ocd_opts "$1" "$2") -c "init" -c "exit" 2>&1)
    if echo "$OUT" | grep -q "DPIDR 0x1ba01477"; then
      echo "    OK! STM32F103 detected with swclk=$1 swdio=$2"
      FOUND="$1 $2"; break 2
    fi
  done
  echo "    no chip with swclk=$1 swdio=$2 (trying the other orientation)"
done

if [ -z "$FOUND" ]; then
  echo "ERROR: SWD did not attach. Check: printer on (toolhead powered),"
  echo "       wires firmly on IO/CK/G (nothing on 3V3), common ground, short wires."
  exit 1
fi
set -- $FOUND

echo "### 4) Flashing: unlock + Katapult @0x08000000 + Klipper @0x08002000 ..."
# NOTE: 'verify' is important — GPIO bit-bang SWD is marginal and can glitch a
# write silently. 'program ... verify' re-reads the flash and fails loudly if wrong.
chrt -f 99 $OPENOCD $(ocd_opts "$1" "$2") \
  -c "init" -c "reset halt" \
  -c "stm32f1x unlock 0" -c "reset halt" \
  -c "program $KATAPULT_BIN 0x08000000 verify" \
  -c "program $KLIPPER_BIN  0x08002000 verify reset" \
  -c "exit" 2>&1 | grep -iE "unlock|wrote|verified|Verified|Error|halted"

echo "### 5) Restoring the UART console..."
echo "$UART_DEV" > "$UART_DRV/bind" 2>/dev/null
systemctl start "$GETTY" 2>/dev/null

echo ""
echo "### DONE. Verify: restart Klipper and check the MCU loads."
echo "    NOTE: align the host firmware (e.g. klippy/extras/ldc1612.py) to the"
echo "    version/branch of the firmware you just flashed, otherwise you'll get"
echo "    'Command format mismatch'."
echo "    Restart services:  sudo systemctl start $SERVICES"

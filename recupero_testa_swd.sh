#!/bin/bash
# =============================================================================
#  recupero_testa_swd.sh
#  Recupero di un MCU STM32F103 "bricckato" (testa o buffer) della Sovol SV08 Max
#  usando l'SBC interno (BTT CB1 / Allwinner H616) come programmatore SWD bit-bang,
#  tramite i pin TX/RX dell'header seriale "5V RX TX GND" della scheda madre.
#
#  NIENTE ST-Link, NIENTE Arduino. Solo 3 fili e OpenOCD.
#
#  CABLAGGIO (stampante ACCESA, testa alimentata dai suoi 24V):
#     madre TX  (PH0/GPIO224 = SWCLK) -> testa CK
#     madre RX  (PH1/GPIO225 = SWDIO) -> testa IO
#     madre GND                        -> testa G
#     (3V3/5V NON si collegano; massa comune anche via umbilical)
#
#  Eseguire come root:  sudo bash recupero_testa_swd.sh
# =============================================================================
set -u

# ----------------------------- CONFIGURAZIONE --------------------------------
# Firmware da scrivere (compilati per offset Katapult 0x2000):
#   Katapult F103 CAN:  make menuconfig -> STM32F103, "8KiB bootloader",
#                       cristallo 8MHz, CAN su PB8/PB9, 1 Mbit  -> out/katapult.bin
#   Klipper  F103 CAN:  stessa scelta "8KiB bootloader" (app a 0x08002000)
KATAPULT_BIN="/home/sovol/printer_data/build/toolhead_katapult.bin"   # -> 0x08000000
KLIPPER_BIN="/home/sovol/printer_data/build/extra_mcu_klipper.bin"    # -> 0x08002000

# Pin GPIO dell'SBC usati per lo SWD (linee del gpiochip0).
# PH0=224, PH1=225 sull'header UART0 "5V RX TX GND" della scheda madre SV08 Max.
GPIOCHIP="0"
SWCLK="224"   # = pin TX dell'header  -> pad CK della testa
SWDIO="225"   # = pin RX dell'header  -> pad IO della testa

# UART da liberare (UART0 = 5000000.serial su H616). Driver: dw-apb-uart.
UART_DEV="5000000.serial"
UART_DRV="/sys/bus/platform/drivers/dw-apb-uart"
GETTY="serial-getty@ttyS0.service"

# Servizi da fermare per avere un sistema SCARICO (bit-bang sensibile al jitter):
SERVIZI="klipper moonraker crowsnest KlipperScreen"

OPENOCD="openocd"   # 0.11 di sistema va bene (con sistema scarico)
TARGET_CFG="/usr/share/openocd/scripts/target/stm32f1x.cfg"
# -----------------------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then echo "Esegui con sudo/root."; exit 1; fi
for f in "$KATAPULT_BIN" "$KLIPPER_BIN"; do
  [ -f "$f" ] || { echo "ERRORE: firmware mancante: $f"; exit 1; }
done

ocd_opts() {
  echo -n "-c 'adapter driver linuxgpiod' -c 'linuxgpiod_gpiochip $GPIOCHIP'"
  echo -n " -c 'linuxgpiod_swd_nums $1 $2' -c 'transport select swd'"
  echo -n " -c 'adapter speed 100' -f $TARGET_CFG"
}

echo "### 1) Fermo i servizi (sistema scarico per il bit-bang)..."
systemctl stop $SERVIZI 2>/dev/null
sleep 1
echo "    load: $(cut -d' ' -f1-3 /proc/loadavg)"

echo "### 2) Libero i pin UART (PH0/PH1) dalla console seriale..."
systemctl stop "$GETTY" 2>/dev/null
echo "$UART_DEV" > "$UART_DRV/unbind" 2>/dev/null
sleep 1

echo "### 3) Test connessione SWD (ritento entrambi gli orientamenti)..."
FOUND=""
for orient in "$SWCLK $SWDIO" "$SWDIO $SWCLK"; do
  set -- $orient
  for try in 1 2 3; do
    OUT=$(timeout 12 chrt -f 99 $OPENOCD $(ocd_opts "$1" "$2") -c "init" -c "exit" 2>&1)
    if echo "$OUT" | grep -q "DPIDR 0x1ba01477"; then
      echo "    OK! STM32F103 rilevato con swclk=$1 swdio=$2"
      FOUND="$1 $2"; break 2
    fi
  done
  echo "    nessun chip con swclk=$1 swdio=$2 (provo l'altro orientamento)"
done

if [ -z "$FOUND" ]; then
  echo "ERRORE: SWD non aggancia. Controlla: stampante accesa (testa alimentata),"
  echo "        fili fermi su IO/CK/G (niente su 3V3), massa comune, fili corti."
  exit 1
fi
set -- $FOUND

echo "### 4) Flash: unlock + Katapult @0x08000000 + Klipper @0x08002000 ..."
chrt -f 99 $OPENOCD $(ocd_opts "$1" "$2") \
  -c "init" -c "reset halt" \
  -c "stm32f1x unlock 0" -c "reset halt" \
  -c "flash write_image erase $KATAPULT_BIN 0x08000000" \
  -c "flash write_image erase $KLIPPER_BIN  0x08002000" \
  -c "reset run" -c "exit" 2>&1 | grep -iE "unlock|wrote|erased|Error|halted"

echo "### 5) Ripristino la console UART..."
echo "$UART_DEV" > "$UART_DRV/bind" 2>/dev/null
systemctl start "$GETTY" 2>/dev/null

echo ""
echo "### FATTO. Verifica: riavvia Klipper e controlla che l'MCU carichi."
echo "    NB: allinea il firmware host (es. klippy/extras/ldc1612.py) alla"
echo "    versione/branch del firmware appena flashato, altrimenti avrai"
echo "    'Command format mismatch'."
echo "    Riavvia i servizi:  sudo systemctl start $SERVIZI"

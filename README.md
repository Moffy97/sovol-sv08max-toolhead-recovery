# Recovering a "bricked" toolhead MCU on the Sovol SV08 Max — with no external hardware

Recover a **print-head** MCU (or the filament-buffer board MCU) of a **Sovol SV08 Max**
when its firmware is corrupted and it no longer communicates over CAN,
**using the printer's own SBC as an SWD programmer** (no ST-Link, no Arduino).

**Author:** Matteo Di Cristoforo
**License:** MIT (see `LICENSE`)

> ⚠️ Advanced technical guide. Working on MCU firmware risks damaging the board.
> Proceed at your own risk and only if you know what you are doing.

---

## 1. Hardware context

The SV08 Max has three microcontrollers plus a small Linux computer:

| Component | What it is | Notes |
|-----------|------------|-------|
| **STM32H750** | Main (motion) MCU on the mainboard | also acts as the USB↔CAN bridge |
| **H616 (BTT CB1)** | Linux SBC (Klipper/Moonraker) | on the mainboard; the "5V RX TX GND" serial header is accessible |
| **STM32F103C8** | **Toolhead** MCU (hotend, extruder, eddy probe) | CAN UUID `61755fe321ac`, connected via the umbilical |
| **STM32F103C8** | **Filament-buffer** board MCU | CAN UUID `704fe1305bd6` |

The two STM32F103 chips run **Katapult** (a CAN bootloader) + Klipper, and expose a 4-pad
**SWD** header labeled `3V3 IO CK G` (IO = SWDIO/PA13, CK = SWCLK/PA14).

## 2. The problem (how it gets bricked)

If you compile the Klipper firmware for these MCUs with the **wrong flash offset**
(application at `0x8000000` instead of `0x8002000`, where Katapult occupies the first 8 KiB),
the Katapult flash "succeeds" but the reset vectors point into Katapult's region → on boot
the MCU jumps to invalid code and **hangs**.

Why it **cannot** be recovered over CAN:
- Katapult only runs for ~1 second at power-up, then jumps to the app (which "looks valid") → no catchable window
- No accessible BOOT/reset button; the double-reset-via-power-cycle trick fails (RAM is cleared on power loss)
- A hung MCU does not ACK on the CAN bus → the whole bus TX stalls

**Conclusion:** you need **SWD**, which accesses the chip directly and ignores the broken app.

## 3. The idea: the SBC as an SWD programmer (zero cost)

The mainboard's **"5V RX TX GND"** serial debug header is the H616's **UART0 console**
on GPIO **PH0 (TX, line 224)** and **PH1 (RX, line 225)**. By releasing those pins from the
UART driver, **OpenOCD** can bit-bang **SWD** through its `linuxgpiod` driver, using the SBC
itself as the probe. You only need 3 wires to the toolhead's SWD pads.

### Wiring (3 wires)
| Mainboard "5V RX TX GND" | → | Toolhead "3V3 IO CK G" |
|:--:|:--:|:--:|
| **TX** (PH0/224 = SWCLK) | → | **CK** |
| **RX** (PH1/225 = SWDIO) | → | **IO** |
| **GND** | → | **G** |

- **Do not connect 3V3/5V**: the toolhead is powered by its own 24 V (printer on). Common ground (also via the umbilical).
- 3.3 V logic on both sides → compatible.

## 4. The three details that make it work

1. **Idle system**: bit-banging depends on software timing. With Klipper/Moonraker running,
   scheduling jitter corrupts the bits and OpenOCD won't attach. **Stop all services** first.
2. **Realtime priority**: launch OpenOCD with `chrt -f 99` to reduce jitter.
3. **The offset is the golden rule**: either **Katapult at `0x8000000` + Klipper at `0x8002000`**,
   or a **standalone Klipper compiled for `0x8000000`** written to `0x8000000`.
   **Never mix the two.** Before writing, the script runs `stm32f1x unlock 0`
   (handles read-out protection / RDP with a mass-erase if needed).

## 5. Using the script

On the SBC (over SSH):
```bash
# 1) build Katapult and Klipper for the F103 with the 0x2000 offset (see comments in the script)
# 2) set the firmware paths in the script and run:
sudo bash recover_toolhead_swd.sh
```
The script: stops services → releases the UART → tests SWD (with retries) → flashes
Katapult+Klipper → restores the UART console. Afterwards, align the host firmware
(e.g. `ldc1612.py`) to the version of the MCU firmware you flashed, then restart Klipper.

## 6. Final notes

- Host side: the MCU's Klipper firmware and the host's Python modules must **match**
  (e.g. the `ldc1612_setup_home` command with/without `homing_method` between the `main`
  and `eddy_contact` branches). A mismatch → "Command format mismatch".
- Once **Katapult** is reinstalled, future flashes are done conveniently over CAN
  (`flash_can.py`), no more SWD needed. **Gotcha:** on Sovol's setup the **Katapult CAN UUID
  differs from the Klipper-app UUID** for the same chip. To flash over CAN: send the bootloader
  request with the Klipper UUID (it "fails" but triggers the reboot), then `flash_can.py -q` to
  read the **Katapult** UUID, then flash using that Katapult UUID.
- Always flash with **`verify`** (`program <bin> <addr> verify`): GPIO bit-bang SWD is marginal
  and a write can glitch silently — verification catches it.
- The exact same procedure works for the **filament-buffer board** (UUID `704fe1305bd6`),
  on its own SWD pads.

## 7. Related guide

- **[Running Klipper `main` with a working eddy-current Z probe](main-with-eddy-current.md)** —
  how to keep the host on `main` while the SV08 Max's eddy-current Z calibration still works
  (no `run_non_contact_calibrate` error).

*Documented after a real recovery, 2026-05-31.*

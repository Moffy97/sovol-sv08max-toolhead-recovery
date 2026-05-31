# Running Klipper `main` on the Sovol SV08 Max with a working eddy-current Z probe

How to run the **`main`** Klipper branch on the host while keeping the SV08 Max's
**eddy-current "virtual contact" Z probe** fully working — **without errors** such as:

```
ZoffsetCalibration: The [run_non_contact_calibrate] in the [non_contact_probe] object is not defined.
```

**Author:** Matteo Di Cristoforo · **License:** MIT

> ⚠️ Advanced. Touching firmware/modules can break your printer. Proceed at your own risk.

---

## 1. Why the error happens

Sovol keeps two branches in their Klipper fork:

- **`main`** — generic; its `z_offset_calibration` expects a physical `[probe_pressure]` probe.
- **`klipper-eddy_contact_probe`** — adds the **eddy-current virtual-contact** Z calibration
  that the SV08 Max actually uses (`run_non_contact_calibrate` / `run_contact_probe`).

If you switch the **host** to `main` but keep the eddy-current `z_offset_calibration.py`, you get a
mismatch: `z_offset_calibration` (eddy) calls methods that the `main` `probe_eddy_current.py` does
not have → the error above. The `main` branch, as-is, **does not support** the SV08 Max eddy Z probe.

There is also a **firmware** side: the eddy homing command differs between branches:

```
# main      (6 args)
ldc1612_setup_home oid=%c clock=%u threshold=%u trsync_oid=%c trigger_reason=%c error_reason=%c
# eddy_contact (7 args, adds homing_method)
ldc1612_setup_home ... error_reason=%c homing_method=%u
```

The **host Python** and the **toolhead MCU firmware** must use the *same* variant, or you get
`Command format mismatch`.

## 2. The fix: keep `main` on the host, but make the eddy-probe stack consistent (eddy_contact)

Bring the eddy-current probe components (host modules **and** toolhead firmware) from the
`eddy_contact` branch, so they all match. Everything else stays on `main`.

### 2a. Restore the eddy-probe host modules (from the eddy_contact branch)

```bash
cd ~/klipper
sudo systemctl stop klipper
for f in ldc1612.py probe.py probe_eddy_current.py probe_pressure.py z_offset_calibration.py; do
    git show klipper-eddy_contact_probe:klippy/extras/$f > klippy/extras/$f
done
rm -f klippy/extras/__pycache__/{ldc1612,probe,probe_eddy_current,probe_pressure,z_offset_calibration}.cpython-39.pyc
```

### 2b. Re-add the eddy parameter in `printer.cfg`

In the `[probe_eddy_current eddy]` section, make sure this line is present (the eddy_contact
module requires it):

```ini
[probe_eddy_current eddy]
...
vir_contact_speed: 3.0
```

### 2c. Build the toolhead firmware from the eddy_contact source (7-arg `ldc1612`)

```bash
cd ~/klipper
git show klipper-eddy_contact_probe:src/sensor_ldc1612.c > src/sensor_ldc1612.c
```

Configure for the toolhead STM32F103 (CAN on PB8/PB9, 8 MHz crystal, **8 KiB bootloader offset**
so the app lands at `0x08002000`). Do **not** rely on `make olddefconfig` from a minimal file —
it tends to pick USB instead of CAN. Use `make menuconfig` (or a full `.config`) and verify you get:

```
CONFIG_MCU="stm32f103xe"
CONFIG_STM32_FLASH_START_2000=y          # app at 0x08002000
CONFIG_STM32_CLOCK_REF_8M=y
CONFIG_STM32_CANBUS_PB8_PB9=y
CONFIG_CANSERIAL=y                        # NOT CONFIG_USBSERIAL
CONFIG_WANT_LDC1612=y
```

Then build:

```bash
make clean && make
# sanity check: the reset vector must be in the 0x08002000+ region
arm-none-eabi-objdump -h out/klipper.elf | grep .text     # VMA 0x08002000
```

### 2d. Flash the toolhead over CAN (Katapult)

The toolhead already has Katapult, so flash over CAN. **Gotcha:** on Sovol's setup the Katapult
CAN UUID is **different** from the Klipper-app UUID for the same chip. So:

```bash
# 1) ask the running app to enter the bootloader (this command "fails" but sends the request):
python3 ~/printer_data/build/flash_can.py -i can0 -u <KLIPPER_UUID> ; true
# 2) discover the Katapult UUID:
python3 ~/printer_data/build/flash_can.py -i can0 -q       # -> "Detected UUID: <KATAPULT_UUID>, Application: Katapult"
# 3) flash using the Katapult UUID:
python3 ~/printer_data/build/flash_can.py -i can0 -f out/klipper.bin -u <KATAPULT_UUID>
```

After flashing, the toolhead boots Klipper again under its normal **Klipper UUID** (the one in your
`printer.cfg` `canbus_uuid`), so no config change is needed.

### 2e. Restart and verify

```bash
sudo systemctl start klipper
```
Klipper should reach **Ready** with no `Command format mismatch` and no `run_non_contact_calibrate`
error. Test the probe:
```
Z_OFFSET_CALIBRATION
```

## 3. TL;DR

| Layer | Use |
|-------|-----|
| Host branch (general) | `main` |
| `ldc1612.py`, `probe.py`, `probe_eddy_current.py`, `probe_pressure.py`, `z_offset_calibration.py` | **eddy_contact** versions |
| `printer.cfg` `[probe_eddy_current eddy]` | add `vir_contact_speed` |
| Toolhead MCU firmware | built from **eddy_contact** `sensor_ldc1612.c` (7-arg) |

The host stays on `main`; the **eddy-current Z probe** works because its host modules *and* the
toolhead firmware are the matching `eddy_contact` variant.

*Documented after a real migration, 2026-05-31.*

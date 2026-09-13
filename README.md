# bc250-monitoring

Hardware monitoring (temp / voltage / fan RPM) for the **AMD BC-250** board, with PWM fan control support.

## Background

The BC-250 exposes CPU temperature (`k10temp`), GPU temperature/power (`amdgpu`) and NVMe temps to Linux,
but **not** the motherboard sensors. Those live behind the board's **Nuvoton NCT6686D** Super I/O chip, which:

- is **not auto-detected** — it needs `force=true`,
- is served by two competing drivers:
  - `nct6683` (in-kernel, read-only),
  - **`nct6687`** (out-of-tree, [Fred78290/nct6687d](https://github.com/Fred78290/nct6687d)) — full read + PWM fan control, and nicer labels.

This repo installs `nct6687` via **DKMS** so the module is rebuilt automatically whenever Pakman
updates the kernel, and applies a small patch that swaps the `CPU Fan` / `Pump Fan` labels
(the physically-connected fan on BC-250 reads on the channel the driver calls `Pump Fan`).

## Usage

```sh
./setup.sh
```

Run it after any Omarchy reinstall. It is idempotent.

## What it installs

| Piece | Details |
|---|---|
| `nct6687d` driver | DKMS-registered, `force=true` |
| `/etc/modprobe.d/sensors.conf` | `blacklist nct6683`, `options nct6687 force=true` |
| `/etc/modules-load.d/99-sensors.conf` | autoload `nct6687` at boot |
| `/etc/sensors3.conf` | friendly fan/voltage labels (appended if missing) |
| packages | `lm_sensors`, `nvtop`, `linux-headers`, `dkms`, `base-devel`, `git` |

## Verify

```sh
sensors          # temps, voltages, CPU/Pump fan RPM
nvtop            # GPU temp, power, clocks
```

## Files

- `setup.sh` — full reproducible setup
- `50-nct6687-labels.patch` — label swap for the driver (default + msi_alt fan configs)

## Notes & gotchas

- **3-pin fans ignore PWM.** The board's 4-pin header sends PWM, but a 3-pin fan is powered
  straight from 12V and runs at a constant speed no matter what — BIOS "fan settings" do not
  actually control it either. For software fan control, fit a **4-pin PWM fan**; the nct6687
  driver then works out of the box (`/sys/class/hwmon/hwmon*/pwm*N`).
- **No ACPI EC, no SMBus Super-I/O.** The chip is on ISA (port `0x2e:0xa20`); that is why
  `ec_sys`, `acpi_call` and `i2cdetect` all come up empty — only `force=true` works.
- The driver taints the kernel (out-of-tree); expected.
- Motorboard VRM voltages may read 0.00 V — the BC-250 shares rails with the VRM/PMIC that
  are not all wired to the Super I/O chip. Voltages +3.3V, AVSB and VBat are the useful ones.

## Updating the label patch

If a new upstream version of `nct6687d` shifts line numbers, regenerate the patch:

```sh
git clone --depth 1 https://github.com/Fred78290/nct6687d.git /tmp/upstream
$EDITOR /tmp/upstream/nct6687.c   # swap the "CPU Fan"/"Pump Fan" .label strings
git -C /tmp/upstream diff > 50-nct6687-labels.patch
```
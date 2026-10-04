# Second unit of the same model: `8E35` with systemd-boot

This is **not** part of the notebook above. It is a second machine, with a different bootloader and a
different implementation of the same two halves, contributed because the maintainer asked for the
per-shutdown timings and the drain figures of another unit. Nothing here replaces anything above, and
no row below may be compared with a row above without rule 1 of [`EVIDENCE.md`](EVIDENCE.md#how-to-read-these-numbers):
raw watts do not survive a change of window length.

## The unit, and where it differs

|  | reference machine (above) | this unit |
|---|---|---|
| board / firmware | HP OMEN 16-ap0xxx (`8E35`), BIOS F.13 | same model, same firmware |
| CPU / dGPU | Ryzen 9 8945HX + RTX 5060 Max-Q | same |
| distribution / kernel | Fedora, akmod | Arch Linux, `7.2.8-arch1-2` |
| bootloader | GRUB2 | **systemd-boot** |
| rare-case fallback | 90 s wait, then a one-shot GRUB `halt` (0.32 W) | **none** |
| shield | `s5_pmrt_arm`, armed by the `99y` shutdown hook | `s5_shield`, armed from the **reboot notifier** inside `kernel_power_off()` |
| measurement | `s5-energy-log` | shutdown/boot witness service + `bin/s5-evidence` |

The implementation, its tooling and its own evidence file live at
<https://github.com/December172/s5-shield> (GPL-2.0).

Two differences matter to this repository:

1. **The wait is not the lever, and `pm_request_idle()` cannot make it one.** Arming here happens in
   `kernel_shutdown_prepare()`, i.e. one step *earlier* than the `99y` hook's `modprobe`, so the wait
   this unit first shipped had even less room to help than the patch proposed for `s5_pmrt_arm` - and
   the source says neither can help:
   `rpm_check_suspend_allowed()` refuses a suspend with `-EACCES` (`disable_depth > 0`), `-EAGAIN`
   (`usage_count > 0`) or `-EBUSY` (`child_count > 0`, which is exactly the dGPU's root port while the
   GPU is awake); a device that *can* suspend has already been idle-notified by the core when its last
   reference was dropped, so the nudge is a no-op there too; and when the request is accepted,
   `rpm_suspend(RPM_AUTO)` waits out the device's autosuspend delay rather than suspending at once.
   Measured on this unit: the wait ran its full 5000 ms with the dGPU still in `D0`, and the off
   window that followed was still ~1 W. The wait has been retired here (`wait_ms=0`).
   A *userspace* nudge does exist for anyone who wants to time the drop on their own machine -
   writing `on` then `auto` to `power/control` is `pm_runtime_forbid()` + `pm_runtime_allow()`, i.e. a
   resume followed by an `rpm_idle()` - but it has the same ceiling, and it *wakes* whatever is asleep,
   so it may only be applied to the device that is already awake.
2. **No GRUB, so no `halt` branch.** On this unit the rare case (a GPU that is genuinely awake or busy
   at poweroff) currently has no safety net at all. What a systemd-boot equivalent needs, and why
   `bootctl set-oneshot` + an EFI halt application is the shape of it, is a separate contribution; it
   is not measured here and no row below covers that case.

## How these rows were taken

* A witness unit (`ExecStart` at boot, `ExecStop` during the shutdown transaction) records the dGPU,
  its audio function, its root port, the port's ACPI power state and the battery at both ends of the
  window. It only reads sysfs: no `lspci`, no `nvidia-smi`, nothing that could wake the device it is
  measuring.
* Both records carry the raw battery registers (`energy_now`, `charge_now`, `voltage_now`, …), so any
  published watt can be recomputed from the log instead of taken on trust.
* A row is **refused**, not guessed, when the charger was connected at either end, the battery went
  up, the boot sample was taken long after boot, the boot record is missing, the window is under
  0.5 h, or the two independent computations of the same window disagree by more than 0.02 W.
* The witness log is capped, which already cost this unit the raw record of the row below; judgeable
  windows are now also appended, never trimmed, to `/var/lib/s5-shield/rows.tsv`.
* Since revision 1.4 the module also prints, in the poweroff path, the runtime PM accounting and the
  blocking reason at arming time, and a `FINAL` line per device from a
  `SYS_OFF_MODE_POWER_OFF_PREPARE` observer - i.e. **after `device_shutdown()`** and before the
  firmware is asked to power off
  (`kernel_power_off()`: notifier + `device_shutdown()` → power-off-prepare → `syscore_shutdown()` →
  `machine_power_off()`). That last line is the one that says whether the rail was actually released,
  instead of inferring it from a state read before the walk.

## Measurements

| date | label | what changed | result | verdict |
|---|---|---|---|---|
| 10-03 | `clean-50min-1.3` | in-kernel shield armed with the dGPU **in `D0`**; the 5 s settle wait ran to its full budget and gave up | ≤1 Wh / 0.83 h ⇒ **≈1 W** (raw window 2.2 Wh, of which 1.2–2.9 Wh is the uptime inside it) | **CLEAN**, n=1 — a 50-minute window; not comparable to the nights above (rule 1). The raw witness record was trimmed by the log cap, so this row is quoted from the project's own README |
| 10-03 | `ac-on-void` | same configuration, charger connected throughout | refused by the gate at both ends | **VOID** — quoted only to show the refusal works |

Planned, not yet measured (each is one poweroff and one window; the windows of a pair are the same
length on purpose):

* `baseline-no-shield` — shield removed, same window as the next row. This unit's **pre-fix drain has
  never been measured**: the ~20 W is the measurement above, from another machine. Until this row
  exists, nothing here may be compared against a "before".
* `clean-night-1.4` — whole night with the shield armed, `wait_ms=0`.
* `wait-5000-1.4` — screening windows, same length, to isolate the retired wait: same code, one
  parameter.

## Two findings worth writing down

1. **`D0` at arming time is not the same thing as `D0` at the moment of no return.** On this unit the
   dGPU *and* its root port were in `D0` when the shield armed (port `child_count=1`: the port cannot
   suspend while the GPU under it is active), and the off window was still ~1 W. The `FINAL` observer
   above exists to settle where the tree actually ends up; the first instrumented run will say whether
   the walk releases it (expected: dGPU `D3cold`, bridge `D3hot`/`D3cold`) or whether something holds
   it to the end. Either reading is a real result, and the second one would mean the rare case is not
   as rare as the arming-time snapshot suggests.
2. **`D0` per se is not the expensive state; a device that is genuinely in use is.** Upstream's
   `gpu-en-uso-v1` (19.38 W) is a GPU pinned awake and working; an idle `D0` device on this unit cost
   nothing measurable over 50 minutes. The two are worth separating in the policy: what the GRUB
   branch protects against is not the state label but a GPU that cannot be let go of - and on a
   systemd-boot machine there is no equivalent branch to fall back to yet.

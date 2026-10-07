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
| CPU / dGPU | Ryzen 9 **8940HX** + RTX 5060 Max-Q | Ryzen 9 **8945HX** + RTX 5060 Max-Q — same model, different SKU |
| distribution / kernel | Fedora, akmod | Arch Linux, `7.2.8-arch1-2` → `7.2.9-arch1-1` (the module is packaged as DKMS and rebuilt itself across the crossing) |
| bootloader | GRUB2 | **systemd-boot** |
| rare-case fallback | 90 s wait, then a one-shot GRUB `halt` (0.32 W) | **none in the policy**; the systemd-boot equivalent has been measured by hand (below), and is the subject of [#4](https://github.com/AnxoCalvo/s5-poweroff-fix/pull/4) |
| shield | `s5_pmrt_arm`, armed by the `99y` shutdown hook | `s5_shield`, armed from the **reboot notifier** inside `kernel_power_off()` |
| measurement | `s5-energy-log` | shutdown/boot witness service + `bin/s5-evidence` |

The implementation, its tooling and its own evidence file live at
<https://github.com/December172/s5-shield> (GPL-2.0).

Two differences matter to this repository:

1. **The wait is the lever here, and this unit measured it the hard way.** Arming here happens in
   `kernel_shutdown_prepare()`, one step *earlier* than the `99y` hook's `modprobe`. Revision 1.3/1.4
   shipped `wait_ms=0`, on the argument that the core lets the subtree go during `device_shutdown()`
   and that a nudge cannot force a suspend. That argument is right about nudges, and it was wrong
   about the wait:
   `rpm_check_suspend_allowed()` refuses a suspend with `-EACCES` (`disable_depth > 0`), `-EAGAIN`
   (`usage_count > 0`) or `-EBUSY` (`child_count > 0`, which is exactly the dGPU's root port while the
   GPU is awake); a device that *can* suspend has already been idle-notified by the core when its last
   reference was dropped, so `pm_request_idle()` is a no-op there too; and when the request is
   accepted, `rpm_suspend(RPM_AUTO)` waits out the device's autosuspend delay rather than suspending
   at once. But arming is not a nudge: `__pm_runtime_disable()` takes the ability to suspend *away*,
   and a port cannot suspend while a device below it is awake, so an awake subtree that gets armed
   stays awake for the whole of S5. The wait is therefore not an attempt to force a suspend at arming
   time - it is the last window in which the subtree is still allowed to suspend by itself.
   Measured with one binary and one parameter (`srcversion 5ABD41F6E01E06E371E5D2F`, the same arm-time
   state: dGPU `D0`, root port `D0`, audio `D3hot`, no holders): `wait_ms=0` drew **18.51 W** over
   0.34 h (ledger `FAIL`, the boot check reporting *the rail was NOT cut*), while `wait_ms=20000` drew
   **0.43 W** over 11.12 h (ledger `OK`). Revision **1.5 consequently ships `wait_ms=20000`**.
   This does not contradict the closure of
   [#2](https://github.com/AnxoCalvo/s5-poweroff-fix/pull/2): the reference policy waits up to 90 s
   *before* its module is loaded, so a wait inside `s5_pmrt_arm` adds nothing there. Both statements
   hold at once - on a unit with no policy layer, the wait is the only step that can settle the
   subtree before arming forecloses it.
   A *userspace* nudge does exist for anyone who wants to time the drop on their own machine -
   writing `on` then `auto` to `power/control` is `pm_runtime_forbid()` + `pm_runtime_allow()`, i.e. a
   resume followed by an `rpm_idle()` - but it has the same ceiling, and it *wakes* whatever is asleep,
   so it may only be applied to the device that is already awake.
2. **No GRUB, so no `halt` branch — but the systemd-boot equivalent exists, and it is measured.**
   On this unit the rare case (a GPU that is genuinely awake or busy at poweroff) still has no safety
   net in the policy. What the equivalent needs is a one-shot systemd-boot entry that powers the
   machine off from the boot loader, with no Linux kernel in that boot; its two windows are in
   [The firmware power-off path](#the-firmware-power-off-path) below, and the mechanism itself is the
   subject of [#4](https://github.com/AnxoCalvo/s5-poweroff-fix/pull/4).

## How these rows were taken

* A witness unit (`ExecStart` at boot, `ExecStop` during the shutdown transaction) records the dGPU,
  its audio function, its root port, the port's ACPI power state and the battery at both ends of the
  window. It only reads sysfs: no `lspci`, no `nvidia-smi`, nothing that could wake the device it is
  measuring.
* Both records carry the raw battery registers (`energy_now`, `charge_now`, `voltage_now`, …), so any
  published watt can be recomputed from the log instead of taken on trust.
* A row is **refused**, not guessed, when the charger was connected at either end, the battery went
  up, the battery reads **exactly the same at both ends** (a gauge that stayed pinned, which is what
  this unit's pack does when the window starts at 100% — it cost one 10.1 h window on 2026-10-06, and
  the zero-delta gate was added because of it), the boot sample was taken long after boot, the boot
  record is missing, the window is under 0.5 h, or the two independent computations of the same window
  disagree by more than 0.02 W.
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
| 10-04 | **`baseline-no-shield`** | in-kernel shield **removed** (`modprobe -r`), charger unplugged, 2.52 h window | **51.242 Wh / 2.52 h ⇒ 20.33 W** | **poisoned** — this unit's own "before", landing in the same 18.7–24 W class measured above on the reference machine |
| 10-03 | `ac-on-void` | same configuration, charger connected throughout | refused by the gate at both ends | **VOID** — quoted only to show the refusal works |
| 10-04 | `diag-1.4-no-wait` | revision 1.4 with `wait_ms=0`, shield armed with the dGPU in `D0` | 6.288 Wh / 0.34 h ⇒ **18.51 W** | **FAIL** — below the 0.5 h publication floor, so it is kept as a diagnostic and not as a row; the ledger keeps its `FAIL` line, and the boot check fired *the rail was NOT cut* |
| 10-04/05 | `probe-wait-20s` | revision 1.4 with `wait_ms=20000` restored — the parameter 1.5 now defaults to | 4.771 Wh / 11.12 h ⇒ **0.43 W** (the boot itself is inside that) | **CLEAN**, n=1, ledger `OK` — not comparable to the 2.52 h baseline under rule 1; it *is* comparable to the reference machine's `nocturna-real-v2` (0.46 W over 8.60 h), which is the closest of its nights to this window |
| 10-06 | **`clean-window-1.5`** | revision 1.5, `wait_ms=20000` (the shipped default); the baseline's window, 2.43 h against its 2.52 h — the shorter side, which reads *higher* for the same S5 | **1.0310 Wh / 2.4278 h ⇒ 0.42 W** | **CLEAN** — ledger `OK`. With `baseline-no-shield` this is the legal pair under rule 1: **20.33 W → 0.42 W**, same machine, same window, shield off against shield on |

Appendix for the two revision-1.4 windows, because they are the whole argument for the default:
same module binary, same arm-time state, one parameter. Raw registers are in the witness log and in
`/var/lib/s5-shield/rows.tsv` (never trimmed).

```
wait_ms=0       window 2026-10-04T23:03:51 -> 23:24:14   0.3397 h   6.2880 Wh   18.51 W  FAIL
                dGPU D0, root port D0, audio D3hot, no holders at arming time
wait_ms=20000   window 2026-10-04T23:37:10 -> 10-05T10:44:18  11.1189 h   4.7710 Wh   0.43 W  OK
                same arm-time state; one parameter differs from the line above
```

Appendix for `baseline-no-shield`, so every figure is recomputable from the witness log and
`/var/lib/s5-shield/rows.tsv`:

```
window    : 2026-10-04T12:06:30+08:00 -> 14:37:42+08:00   (2.5200 h, 51.2420 Wh, 20.33 W)
shutdown  : battery 61.258 Wh (78%), ac_online=0, uptime 8922 s
            s5_shield: NOT loaded -> the poweroff will behave as before
            energy_now=61258000 voltage_now=11462000 energy_full=78466000 capacity=78
            state at entry: dGPU=D0 port=D0 audio=D3hot   (port ACPI=D0)
boot      : battery 10.016 Wh (13%), ac_online=0, uptime 8 s
            s5_shield: loaded, srcversion=5ABD41F6E01E06E371E5D2F wait_ms=0
ledger    : 2026-10-04T14:37:42  2.5200 h  51.2420 Wh  20.33 W  FAIL  baseline-no-shield
```

Two notes on it, both computed and not worded: the window ended with ~10 Wh left, so it measured a
**rate** and not a floor (had the battery been flat at boot, the tail would not have been drawing at
that rate, and `bin/s5-evidence` now says so when it sees ≤ 10%); and the next boot's self-check
**fired as designed** — `FAIL - BACKWARD`, the `check-failed` marker and a `FAIL` line in the ledger.
That is the alarm working, not a fault: an unshielded poweroff is supposed to read like that.

**The pair is now measured, and it is the headline**: `clean-window-1.5` — the baseline's own window
with shield 1.5 at its shipped defaults — read **1.0310 Wh / 2.4278 h ⇒ 0.42 W**, against
`baseline-no-shield`'s **51.2420 Wh / 2.5200 h ⇒ 20.33 W**. Same machine, same 2.5 h window (2.43 h
against 2.52 h, and the shielded one is the shorter of the two, which for the same S5 reads *higher*,
so the residual difference runs against the fix), shield off against shield on: **a 48× drop**, and
this unit's first legal before/after under rule 1.

Why the pair cannot be a whole night here, and why that is a limit of the machine rather than a
choice: unshielded, a ~78 Wh battery lasts ~3–4 h, and past that the EC cuts and the tail is no
longer drawing at that rate, so the row would become a floor instead of a rate. A whole-night row, if
taken, is a different window and is labelled as such — rule 1.

Also for the record, one row that was refused rather than published: a 10.10 h overnight window on
2026-10-06 read **0.00 W** because the pack started at 100% and the gauge stayed pinned at full
(`energy_now` byte-identical at both ends while `voltage_now` moved 0.5 V). The rail was cut — a
~20 W S5 would have flattened the pack in ~4 h and the machine booted after 10 — but the window had
no measurement in it, so the tools now refuse a zero delta by name. It is filed as a diagnostic, not
as a row.

`wait-5000-1.4` — **dropped**, and that is a decision, not an omission. Revision 1.3's 5 s budget ran
out with the dGPU still in `D0`, and the A/B above then showed that the interesting parameter is not
the *length* of the wait but its presence: `0` versus a budget long enough to settle. A screening
window at 5000 ms would say nothing the rows above do not already say.

## The firmware power-off path

The reference machine's rare case diverts the poweroff through GRUB's `halt`, so that no Linux kernel
runs in that boot: `grub-halt` measured 1.05 W over 45 min, and `politica-grub-real-v1` 0.32 W over
9.55 h. This unit has no GRUB. The equivalent here is a one-shot systemd-boot entry — systemd-boot's
own `auto-poweroff` entry, which calls `RT->ResetSystem(EfiResetShutdown)` — armed with
`bootctl set-oneshot auto-poweroff`, so the machine powers off from the boot loader with no kernel in
that boot.

Two windows, deliberately the same length and the same arm-time state: the dGPU pinned in `D0` with
`power/control=on` (the method of `gpu-en-uso-v1`, applied by hand before the shutdown), charger
unplugged at both ends, and the shutdown/boot witness of this unit as the instrument.

| date | label | result | verdict |
|---|---|---|---|
| 10-06 | `halt-path-rare-builtin-1.5` | 3.404 Wh / 0.7628 h ⇒ **4.46 W** | ledger `FAIL`, the row tool graded it `borderline` — **superseded**: `energy_full` moved 4.77 Wh *inside* the window (80.747 → 75.976 Wh), which no other window of this unit has done, and the gauge's own percentages (53 % → 51 %) say about half the absolute figure |
| 10-07 | **`halt-path-rare-builtin-2`** | **1.007 Wh / 0.7622 h ⇒ 1.32 W** | **CLEAN** — ledger `OK`, boot check `FORWARD`, and the `check-failed` marker cleared on that boot |

Three things about the second window, because they are what make it the row and not the first one:

* **It is comparable to the reference `grub-halt` window under rule 1** — 0.7622 h against its 45 min,
  1.32 W against 1.05 W — and to the first pass, which is the same 0.76 h. What it says is that on this
  firmware the EFI `ResetSystem(EfiResetShutdown)` path lands in the same place as GRUB's ACPI `halt`,
  not several times above it.
* **No kernel ran inside it.** The journal's boot list has the boot that shut down ending at 12:12:01
  and the next one starting at 12:57:28, and the witness log holds exactly one shutdown record and one
  boot record for the window. That is the whole point of the path: the firmware does its S5 with the
  hardware as the boot loader left it.
* **It is the hard case, not the benign one.** `power/control=on` forbids runtime suspend on the dGPU
  and its functions, so the subtree is awake when the shield arms, and the witness says what that
  means: `dGPU=D0 port=D0 audio=D0` at entry, still `D0` after 6000 ms (`it does not suspend on its
  own`), and `state=D0 rpm=active` for all three devices in its final block. That is the same arm-time
  state that measured **18.51 W** through a *normal* poweroff with `wait_ms=0` — the case the shield's
  wait exists for. Here the exit path is the boot loader's instead, and that same state ends at
  **1.32 W**.
* **It ran across a kernel crossing** (`7.2.8-arch1-2` → `7.2.9-arch1-1`). The DKMS package rebuilt the
  module for the new kernel (`srcversion` unchanged, `BFE3D9DD62D07BFCBB4003A`), the shield loaded and
  armed, and the row carries the new kernel — the same silent-failure mode the reference machine checks
  after every crossing.

What this does **not** say: the arming here was manual (`bootctl set-oneshot auto-poweroff`). Arming it
from the real shutdown path — after `shutdown.target`, which is where the GRUB branch of PR #4 found
`/boot` already unmounted — is still open.

```
window    : 2026-10-07T12:11:53+08:00 -> 12:57:37+08:00   (0.7622 h, 1.0070 Wh, 1.32 W)
shutdown  : battery 51.808 Wh (68%), ac_online=0, uptime 1884 s
            s5_shield: loaded, srcversion=BFE3D9DD62D07BFCBB4003A devs=0000:01:00.0,0000:01:00.1,0000:00:01.1 wait_ms=20000
            holders at entry: none    energy_full=75849000  voltage_now=11321000
boot      : battery 50.801 Wh (67%), ac_online=0, uptime 9 s
            energy_full=75270000  voltage_now=11094000  check: OK - FORWARD
ledger    : 2026-10-07T12:57:37  0.7622 h  1.0070 Wh  1.32 W  OK    halt-path-rare-builtin-2
first pass: 2026-10-06T23:20:13  0.7628 h  3.4040 Wh  4.46 W  FAIL  halt-path-rare-builtin-1.5
```

## One finding, and one open question

1. **`D0` at arming time is not the same thing as `D0` at the moment of no return — the wait decides
   which one you get.** On this unit the dGPU *and* its root port were in `D0` when the shield armed
   (port `child_count=1`: the port cannot suspend while the GPU under it is active). With no wait in
   front of it that subtree was still `D0` after `device_shutdown()` and the rail stayed on (18.51 W);
   with a wait, the same arming-time state ended in a released rail (0.43 W).
   The arming block of the 2026-10-06 poweroff was photographed, and it is the healthy end of that
   range rather than the dangerous one: the dGPU was **already `D3cold`** when the shield armed, so the
   20 s budget was spent in **100 ms** waiting for the bridge alone, and the dGPU, its audio function
   and the port all read `D3cold` / `rpm=suspended` / `use=0 child=0`. Nothing could have woken that
   subtree; the rail was cut. Which is also the honest limit of the observation: it says the wait costs
   almost nothing when the compositor has already let go, not that it is unnecessary — the poweroff
   where the subtree is still awake is the one measured at 18.51 W.
   The `FINAL` line *after* the walk has never been observed here, and the diagnostic hold is now ruled
   out as the reason. The photograph ends at the shield's `done:` line — the end of the reboot
   notifier, i.e. *before* `device_shutdown()` — and the screen then stays dark **with the backlight
   on** for about five seconds before the machine switches off. That is what it does with
   `final_hold_ms=8000` (5–8 s) and with the default `0` (~5 s), so the interval is this machine's own
   S5 transition, not the hold; and a hold that leaves no trace is a hold that did not run, so there is
   no evidence the `POWER_OFF_PREPARE` observer was called at all. Either the display is already down
   when it is, or the handler is not reached on this path. The end state is therefore read from the
   arming block plus the window, not from a `FINAL` line.
2. **An open question, not a finding: whether an idle `D0` costs anything.** The tempting reading —
   that what costs ~19 W is a GPU *in use* rather than a GPU in `D0` — is not something this unit's
   rows can carry. `gpu-en-uso-v1` (19.38 W over 0.34 h) was a dGPU pinned in `D0` with
   `power/control=on` and deliberately **no load** running on it, so it separates "pinned" from
   "working" not at all; and the only candidate for the opposite claim here, `clean-50min-1.3`, is a
   50-minute window whose S5 share cannot be separated from the uptime inside it — the same reason it
   is filed as a diagnostic rather than a row. It also sits awkwardly next to finding 1, where arming
   in `D0` with no settle cost 18.51 W. Until there is a row that can carry it — a pinned dGPU over a
   window long enough that the uptime does not dominate — this stays open.

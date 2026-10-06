# The evidence base

Extracted from the lab notebook for this case (2026-08-07 → 2026-08-15). What follows
are instrumented measurements, not impressions: every row is a real shutdown with a
battery `energy_now` reading before and after.

> A **second unit** of the same model (`8E35`), with `systemd-boot` instead of GRUB and an
> in-kernel arming module instead of the akmod, is documented separately in
> [`EVIDENCE-second-unit.md`](EVIDENCE-second-unit.md). It is a different machine: its rows
> are not part of the table below and rule 1 applies between the two documents too.

## How to read these numbers

1. **Raw watts are NOT comparable across windows of different length.** Use energy and
   `E = E₀ + P·t`. **E₀ ≈ 1.13 Wh** in the `minimal-init` flow, **≈0.70 Wh** in
   `grub-halt`. With `acpi=off` there is no readable battery, so the window drags in
   TWO boots.
2. **Use `-m 20` windows, never `-m 5`.** Real cost of one cycle: ~22 min. Dropping to
   `-m 10` shrinks the clean/poisoned separation from 3.6× to 2.3×: not worth it.

## All measurements

| date | label | what changed | result | verdict |
|---|---|---|---|---|
| 08-08 | first measurement | normal shutdown | 13.9 Wh / 41 min = **20 W** | poisoned |
| 08-09 | (baseline) | normal shutdown | **20.05 / 19.73 W** | poisoned |
| 08-09 | nvidia blacklist | no nvidia driver (nouveau loaded) | **21.27 W** | poisoned |
| 08-09 | `acpi-osi` | `acpi_osi="!Windows 2020"` | **18.50 W** | poisoned |
| 08-09 | `fix-d3cold` | hook forces GPU+bridge+audio to D3cold | **20.24 W** | poisoned |
| 08-09 | **`grub-halt`** | halt from GRUB, no Linux kernel ever ran | **1.05 W** (0.785 Wh/45 min) | **CLEAN** |
| 08-09 | `gpu-virgen` | pristine dGPU, `module_blacklist=` everything | **18.70 W** | poisoned |
| 08-09 | `efi-poweroff` | module `register_sys_off_handler` → EFI ResetSystem | **19.26 W** | poisoned |
| 08-09 | `minimal-init` | own PID 1, no systemd, no udev, sysrq-o | **19.93 W** | poisoned |
| 08-09 | `pm1a-halt` | flat write to PM1a_CNT | bounced after 30 s | **VOID** |
| 08-09 | `sin-wakeups` | all 18 wake sources disarmed | **21.47 W** | poisoned |
| 08-09 | `solo-nvme` | minimal-init with ONLY 6 modules | **25.79 W** | poisoned |
| 08-09 | `pm1a-acpica` | PM1a_CNT directly, no `_PTS(5)`, no `device_shutdown()` | **26.56 W** (2.649 Wh) | poisoned |
| 08-09 | `legacy-smi` | `acpi_disable()` + SCI_EN=0 verified + flat write | **24.51 W** (2.403 Wh) | poisoned |
| 08-09 | **`acpi-off`** | `acpi=off` + flat write | 8.37 W raw ⇒ **~3-6 W** | **CLEAN** |
| 08-09 | **`grub-halt -m 5`** | control | 4.20 W raw ⇒ **~1 W** (n=2) | **CLEAN** |
| 08-09 | **`acpi-off-20`** | `acpi=off`, 20 min window | **1.262 Wh** / 23.7 min ⇒ 0.40 W | **CLEAN** |
| 08-09 | **`enable-only`** | `acpi=off` + raw ACPI_ENABLE SMI, SCI_EN=1 | **1.155 Wh** / 7.7 min ⇒ 0.30 W | **CLEAN** |
| 08-09 | **`enable-toggle`** | same + ACPI_DISABLE afterwards | **1.186 Wh** / 6.9 min ⇒ 0.67 W | **CLEAN** |
| 08-09 | `no-acpi-init` | `initcall_blacklist=acpi_init` | **2.602 Wh** ⇒ ~17.7 W | poisoned |
| 08-09 | `no-ssdt` | `acpi_no_static_ssdt` (41→18 tables) | **2.063 Wh** ⇒ ~17 W | poisoned |
| 08-09 | `mask-gpe07` | `acpi_mask_gpe=0x07` (sci=0 all session) | **2.110 Wh** ⇒ ~17.5 W | poisoned |
| 08-09 | `irq-legacy` | `nosmp noapic nolapic pci=noacpi acpi=noirq` | **HANG** (7.531 Wh) | **VOID** |
| 08-09 | `nosmp-solo` | `nosmp` | **2.110 Wh** ⇒ ~17.5 W | poisoned |
| 08-09 | `noapic-solo` | `noapic nolapic` | **HANG** (7.161 Wh) | **VOID** |
| 08-10 | `nommconf` | `pci=nommconf` | **2.032 Wh** ⇒ ~22 W raw | poisoned |
| 08-10 | `irq-noacpi` | `pci=noacpi acpi=noirq` | **HANG** | **VOID** |
| 08-10 | `nohpet` | `nohpet` | **2.772 Wh** | poisoned |
| 08-10 | `dsdt-control` | DSDT recompiled unchanged, from initrd | 2.187 Wh — **the override did not take** | **VOID** |
| 08-10 | **`gpe-wipe`** | `acpi=off` + zero PM1_EN/GPE0_EN by hand | **1.524 Wh** / 0.254 h, 2 boots inside | **CLEAN** |
| 08-10 | `dsdt-stub` | 56-byte DSDT with its own OEM ID | 2.403 Wh — **inert extra table** | **VOID** |
| 08-10 | `dsdt-control-v2` | HP's DSDT + `ZZTT`/`TEST0001`, override verified | **6.298 Wh** / 0.34 h ⇒ 18.31 W | poisoned |
| 08-10 | **`dsdt-stub-v2`** | **live 56-byte DSDT** (`bytes=56 upgrade=SI`) | **8.655 Wh** / 0.38 h ⇒ 22.63 W | ⇒ **DSDT cleared** |
| 08-10 | `iommu-off` | `amd_iommu=off`, off and verified | **6.914 Wh** / 0.35 h ⇒ 19.72 W | ⇒ **IOMMU cleared** |
| 08-10 | `sin-aml` | `acpi_no_static_ssdt` + stub-v2: **zero AML** | **9.024 Wh** / 0.38 h ⇒ 24.01 W | ⇒ **AML cleared** |
| 08-10 | `base-7.1.7` | baseline re-measured on kernel **7.1.7-200** | **6.483 Wh** / 0.34 h ⇒ 18.88 W | ⇒ **new kernel fixes nothing** |
| 08-10 | `pstate-off` | `amd_pstate=disable`, CPPC MSR verified 0 | **6.992 Wh** / 0.34 h ⇒ 20.37 W | ⇒ **CPPC cleared** |
| 08-10 | `acpi-off-cppc` | `acpi=off` to read the MSR in the clean state | 4.281 Wh / 0.06 h | **VOID**, but gave `cppc_msr=0` |
| 08-10 | `fadt-control` | FADT replaced by itself, override verified | **6.453 Wh** / 0.34 h ⇒ 18.80 W | ⇒ **valid control** |
| 08-10 | **`fadt-hwreduced`** | `HW_REDUCED_ACPI`: no ACPICA hardware layer, no SCI handler | **7.777 Wh** / 0.34 h ⇒ 22.65 W | ⇒ **SCI cleared** |
| 08-10 | `gpu-d3cold-pm1a` v1/v2 | hook arms D3cold + halts via PM1a | 18.48 / 18.78 W — **no attempt actually halted** (SELinux) | **VOID** |
| 08-10 | **`gpu-d3cold-pm1a-v3`** | trio **in D3cold** + `PM1a_CNT`, no `device_shutdown()` | **0.708 Wh** / 0.34 h ⇒ **2.09 W** ≈ 0.2 W net | **CLEAN** |
| 08-10 | `gpu-d0-pm1a-control` v1/v2 | the control, dGPU in D0 | 1.91 / 2.05 W — **arrived in D3cold both times** | **VOID** |
| 08-10 | **`gpu-d0-pm1a-control-v3`** | **same as v3 but dGPU in D0** (7 witnesses ok) | **6.915 Wh** / 0.3483 h ⇒ **19.85 W** | ⇒ **CONFIRMS THE dGPU** |
| 08-10 | **`pmrt-clean-v1/v2/v3`** | the clean path, **normal systemd shutdown** | **1.77 / 2.04 / 2.00 W** | **CLEAN** |
| 08-10 | **`mitigacion-permanente-v1`** | **normal `poweroff`, NOTHING armed** | **0.709 Wh** / 0.34 h ⇒ **2.09 W** | **CLEAN** |
| 08-10 | **`gpu-en-uso-v1`** | dGPU pinned in D0 + mitigation in place | **6.638 Wh** / 0.34 h ⇒ **19.38 W** | ⇒ **the gap is real** |
| 08-11 | `pmrt-solo-a` v1/v2 | only half (a) of the shield | **HUNG both times** (30.93 / 35.92 W = machine awake) | **VOID** (see below) |
| 08-11 | **`nocturna-real-v1`** | **a whole night of normal use**, nothing armed, no measurement window | **3.295 Wh** / 7.23 h ⇒ **0.46 W** raw (~0.36 net) | **CLEAN** |
| 08-12 | **`nocturna-real-v2`** | the same whole night, repeated | **3.942 Wh** / 8.60 h ⇒ **0.46 W** | **CLEAN** (exact replica) |
| 08-13 | **`tras-actualizar-kernel`** | first shutdown on **7.1.8-200**, akmod rebuilt itself | **0.724 Wh** / 0.46 h ⇒ 1.58 W raw (~0.5 net) | **CLEAN** |
| 08-13 | **`nocturna-real-v3`** | **a whole night, now on the NEW kernel** | **3.480 Wh** / 7.39 h ⇒ **0.47 W** | **CLEAN** |
| 08-14 | **`politica-grub-real-v1`** | **dGPU pinned in D0**: the policy waited 90 s, it never fell, and it diverted the shutdown through GRUB | **3.034 Wh** / 9.55 h ⇒ **0.32 W** | **CLEAN** ⇒ **the rare case works** |
| 08-15 | **`nocturna-real-v4`** | **a whole night**, nothing armed, nothing changed since v3 | **3.265 Wh** / 7.31 h ⇒ **0.45 W** | **CLEAN** |
| 08-15 | **`hook-reordenado-v1`** | first shutdown after `99y` was reordered to source the discovery **before** the handbrake branch | **0.632 Wh** / 0.41 h ⇒ **1.52 W** | **CLEAN** — a 20-min window, compare against `pmrt-clean` (1.77-2.09 W), **not** against the nights (rule 1) |
| 08-21 | **`nocturna-real-v5`** | **a whole night**, nothing armed, nothing changed since v4 | **2.880 Wh** / 6.94 h ⇒ **0.41 W** | **CLEAN** |
| 08-22 | **`nocturna-real-v6`** | **a whole night**, nothing armed, nothing changed since v5 | **3.558 Wh** / 8.52 h ⇒ **0.42 W** | **CLEAN** |
| 08-23 | **`nocturna-real-v7`** | **a whole night**, nothing armed, nothing changed since v6 | **3.203 Wh** / 7.38 h ⇒ **0.43 W** | **CLEAN** |
| 08-24 | **`nocturna-real-v8`** | **a whole night, now on kernel 7.1.9-200** (akmod rebuilt itself again) | **3.249 Wh** / 7.22 h ⇒ **0.45 W** | **CLEAN** |
| 08-26 | **`tras-actualizar-kernel-v2`** | first shutdown on **7.1.10-200** (crossed from 7.1.9-200), akmod rebuilt itself | **0.786 Wh** / 0.71 h ⇒ **1.10 W** | **CLEAN** |
| 09-03 | **`tras-actualizar-kernel-v3`** | a whole night, first shutdown on **7.1.12-200**, akmod rebuilt itself | **3.064 Wh** / 7.44 h ⇒ **0.41 W** | **CLEAN** |
| 09-06 | **`tras-actualizar-kernel-v4`** | a whole night, first shutdown on **7.1.13-200** | **3.803 Wh** / 8.51 h ⇒ **0.45 W** | **CLEAN** |
| 09-13 | **`tras-actualizar-kernel-v5`** | a whole night on **7.2.4-200** — **the 7.1 → 7.2 jump**; the first shutdown on it (09-12) was plugged in and cannot be scored | **1.740 Wh** / 7.10 h ⇒ **0.24 W** | **CLEAN** (low regime, see below) |
| 09-14 | **`tras-actualizar-kernel-v6`** | a whole night, first shutdown on **7.2.5-200** | **2.017 Wh** / 9.33 h ⇒ **0.22 W** | **CLEAN** (low regime, see below) |
| 09-23 | `tras-actualizar-kernel-v7` | a whole night, first shutdown on **7.2.6-200** | 0.000 Wh / 7.69 h — gauge pinned at 100 % at both ends | **NOT SCORABLE** (shield ran: `disable=3 shutdown_anulados=2`) |
| 09-24 | **`tras-actualizar-kernel-v8`** | a whole night on **7.2.7-200** (the first shutdown on it, 09-23, lasted 3.5 min and is all E₀) | **3.512 Wh** / 8.55 h ⇒ **0.41 W** | **CLEAN** |

**The eight `nocturna-real` rows are the ones that count** — not because the wattage is lower
than the 20-minute windows (it is the same figure, with E₀ amortised over a window 20×
longer, rule 1) but because they are long and real. On 08-07 the machine went from full
to **0% in ~8 h**; across these eight it spent 3.3 / 3.9 / 3.5 / 3.3 / 2.9 / 3.6 / 3.2 / 3.2 Wh.

**The third one closes the most likely failure mode of all.** A hand-built `.ko` carries
its kernel's `vermagic`, `insmod` rejects it, and the mitigation dies **silently**: the
shutdown looks just as good and costs 19 W again. On 2026-08-13 the machine actually
crossed `7.1.7-200` → `7.1.8-200`, akmods rebuilt the module by itself, and the following
night — **entirely on the new kernel** — measured 0.47 W. Not "the module loaded": the
saving was still there.

**The eighth repeats that same check across a second kernel crossing.** On 2026-08-24 the
machine crossed `7.1.8-200` → `7.1.9-200`; `s5-mitigacion-check` confirmed the akmod
rebuilt clean for the new `uname -r` with no build failures, and that same night — again
entirely on the new kernel — measured 0.45 W. Same silent-failure mode, checked again,
still not triggered.

**The third crossing repeats the same check with a cleaner number.** On 2026-08-26 the
machine crossed `7.1.9-200` → `7.1.10-200`; `s5-mitigacion-check` confirmed the akmod
rebuilt clean for the new `uname -r` with no build failures, and the first shutdown on the
new kernel measured **0.786 Wh over 0.71 h ⇒ 1.10 W**, comparable to the 1.58 W raw of the
first crossing (`tras-actualizar-kernel`, 08-13). Third crossing, same silent-failure mode,
still not triggered.

**Six more crossings, one of them a minor-series jump.** Between 2026-09-02 and 2026-09-23
the machine went through `7.1.12`, `7.1.13`, `7.2.4`, `7.2.5`, `7.2.6` and `7.2.7` (all
`-200.fc44`). Each time akmods built `kmod-s5-pmrt-arm` for the new `uname -r` within two
minutes of the kernel transaction (`dnf history`), and every poweroff on every one of them
loaded it (`PMRT insmod rc=0 via=akmod`) and shielded all three devices
(`disable=3 shutdown_anulados=2`), per `/var/log/s5-shutdown-pci.log`. On the last one,
`s5-mitigacion-check` (2026-09-24) confirmed the akmod module for `7.2.7-200` with no build
failures and came back all in order (it only looks at the running kernel, so for the other
five the witnesses are the log and `dnf history`). Five of the six have a
whole scorable night on battery. `7.2.6` does not: the battery started the night at 100 %,
and while it sits there the gauge reports no drop at all (the 09-22 night on `7.2.5` read
0.000 Wh for the same reason). That row proves the shield ran, not what it saved.

**The 0.22-0.24 W nights are not the 7.2 kernel.** From 09-09 to 09-18 every scorable night
came out at about half the usual figure (0.20-0.24 W). That regime began on `7.1.13` — the
same kernel that measured 0.45 W on 09-06 — and ended on `7.2.5`, which measured 0.47 W on
09-20; since then the series is back at 0.41-0.47 W. It does not follow any kernel, and its
cause is not known. The gauge is a suspect: in the middle of it, the 09-15 night reported
**+0.662 Wh gained** over 10.89 h on battery while the percentage fell 74 → 71 %, which is not
physical. Either way, all of it sits well under the 1 W success line.

**None of these kernels fixes the bug itself.** That was checked in the source, not in the
wattage — the wattage cannot tell, because the shield ran on every one of these shutdowns.
`pci_device_shutdown()` in `drivers/pci/pci-driver.c` is identical in the stable tags
`v7.1.10`, `v7.1.13` and `v7.2.7` and in mainline (`7.3-rc4`, fetched 2026-09-24): it still
calls `pm_runtime_resume(dev)` unconditionally before `drv->shutdown()`. Its caller,
`device_shutdown()` in `drivers/base/core.c`, is identical between `v7.1.10` and `v7.2.7`, and
`kernel_power_off()` still goes through it. The shield is still needed.

## The rare case, rehearsed end to end (`politica-grub-real-v1`)

Every other clean row above is the shield doing its job on a dGPU that had already fallen
asleep. But the shield only works if the dGPU reaches D3cold *before* it is applied, and
nothing guarantees that: something can be holding the GPU awake at shutdown time. That is
what `s5-gpu-politica` exists for — wait up to 90 s, and if it still has not fallen, do not
take the 19 W shutdown, **divert through GRUB's own `halt` instead**. Until 08-14 that
branch had only ever been rehearsed dry, or fired on 20-minute windows too short to price.

On 2026-08-14 it ran for real, on the worst case, for a whole night:

- The dGPU was **deliberately pinned in D0** (`s5-gpu-en-uso-arm`), the state that costs
  19.85 W (`gpu-d0-pm1a-control-v3`). The hook honoured the guard and let it reach S5 awake
  — `power_now` read **20.266 W** on the way down.
- The policy waited its 90 s. `la dGPU NO cayo a D3cold en 90.0s (traza: 0:D0)`. It mounted
  `/boot` **itself** in rw (rule 28), wrote `next_entry` plus a one-shot `custom.cfg`,
  unmounted it again, and rebooted.
- GRUB ran `halt`. **No Linux kernel ever executed.** The machine sat without power for
  **9.52 h**, until it was switched on by hand.
- **3.034 Wh over 9.55 h ⇒ 0.32 W** — the lowest figure in the whole series, against the
  ~19 W that same shutdown would have cost. Over that night the difference is not a
  percentage: it is a flat battery by morning versus 3 Wh gone.

Two things about the instrument were confirmed by the same run, both of them fixes that had
never been exercised in production: the GRUB branch got `/boot` mounted on its own during
the shutdown, and **`s5-gpu-politica-cleanup` actually ran** on the next boot and deleted
the entry.

The verifier's timing reconstruction agrees independently: `34277 s between the reset and
the next power-on, against 10.5 s for one POST+GRUB pass` — 9.52 h of machine with no power
that a menu timeout could not fake.

**Caveat that applies to this row and not to the others.** Its window contains the whole
manoeuvre — up to 90 s of policy wait at ~19 W, a reboot and two POSTs — so 0.32 W is a
**ceiling**, not a point estimate: everything outside the real S5 is time spent awake, and
can only push the average up. Here the manoeuvre is under 0.4 % of the window and the
distinction is academic; on a 20-minute window it is not, which is why the verifier scores
this kind of window only when the real S5 covers ≥95 % of it (see rule 31).

## Why both halves of the shield are inseparable

Half (a) is `__pm_runtime_disable()`; half (b) is nulling `drv->shutdown` for the
whitelist. An attempt to isolate (a) alone (`pmrt-solo-a`, two replicas) **hung the
machine both times**: black screen, box still powered, only the power button left. The
30.93 W and 35.92 W in the table above are not S5 measurements — they are a machine that
never went to sleep. `pstore` was empty, so it was a bus lockup rather than an oops.

The reason is ordering: `pm_runtime_resume()` runs **before** `drv->shutdown()`. So (a)
alone leaves `nv_pci_shutdown()` executing against a GPU in D3cold — MMIO into the void.
**`nv_pci_shutdown()` genuinely touches hardware.** If it were a no-op there would be no
hang. Nulling it is not skipping something harmless — it works because power is cut
immediately afterwards.

Independent confirmation that the risk is real: the `rtx-laptop-linux` project ships a
service that deliberately does the *opposite*, waking the NVIDIA GPU **before** shutdown,
because from D3cold the driver does not unload cleanly and the shutdown hangs.

## The ACPI bisection harness, and why it is NOT published

Many rows above (`minimal-init`, `solo-nvme`, `pm1a-acpica`, `legacy-smi`, `acpi-off`,
`enable-only`, `gpe-wipe`…) came from a harness this repo **deliberately omits**. Two
pieces:

- **`s5-minimal-init`** — a custom PID 1 that booted the machine **without systemd,
  without udev and without journald**, to ask whether userspace caused the drain.
- **`s5_pm1a_off`** — a module that enters S5 by writing `PM1a_CNT` raw, **bypassing
  `_PTS(5)` and `device_shutdown()` entirely**, plus variants that left ACPI mode via SMI
  or zeroed `PM1_EN`/`GPE0_EN`.

**Two reasons for dropping them.** First: **their question is already answered**, and the
answer was no — userspace, ACPI, the AML, the DSDT, the SCI, the GPEs and the IOMMU are
all cleared (next section). Publishing the instrument adds nothing to the conclusions,
which are what is actually here.

The second reason weighs more: **it was the only part of this that could break something.**
The rest of the project fails safe by design — if the module will not load or `/boot`
cannot be mounted, you lose the saving and the shutdown carries on. Bypassing
`device_shutdown()` and writing raw I/O ports does not: on this very machine several of
those variants **hung the box** (`irq-legacy`, `noapic-solo`, `irq-noacpi`; `pm1a-halt`
bounced after 30 s). On firmware other than the one it was tested against, that is a bet
nobody should take without knowing exactly what they are doing.

**What is kept is the genuinely reusable part:** `tools/s5-grub-halt`, which measures the
platform's clean S5 using GRUB's own `halt` — **no module, nothing bypassed**. It is the
control that produced the 1.05 W figure, and it is what you should use to find out what
your S5 *ought* to cost.

## What has been cleared, and by which measurement

> **The NVIDIA dGPU was on this list and its clearance WAS WITHDRAWN.** The measurements
> that cleared it (`gpu-virgen` 18.70 W, `fix-d3cold` 20.24 W, nouveau 21.27 W) all went
> down **systemd's normal path**, where `pci_device_shutdown()` returns it to D0 no matter
> what came before: all three measured the dGPU **awake**. It was not cleared, it was
> unmeasured. What does still hold: the state the driver leaves it in does **not** matter
> (a pristine dGPU poisons too). The only thing that matters is the **D-state it arrives
> in**.

- **The WQBZ/WQBE AML bug** and **upgrading the BIOS** — F.13 changed nothing.
- **`acpi_osi` and the whole `_OSI` AML branch** — 18.50 W with
  `ACPI: Deleted _OSI(Windows 2020)` verified.
- **`amdgpu.dcdebugmask=0x10`** — the drain predates it (~17 W in an 08-07 gap
  reconstructed from upower history).
- **The SP5100 TCO watchdog** — `watchdog did not stop!` appears in some shutdowns and not
  others, with identical drain.
- **EFI-vs-ACPI as the shutdown method** — `efi-poweroff` 19.26 W. And the premise was
  wrong anyway: **GRUB's `halt` is ACPI, not EFI** (`halt.mod` carries
  `grub_acpi_halt`/`\_S5_`).
- **All of userspace and systemd** — `minimal-init` 19.93 W with a custom PID 1, no udev,
  no journald.
- **The drivers udev loads** — `solo-nvme` 25.79 W with ONLY 6 modules. By magnitude,
  neither nvme nor xhci burns 20 W.
- **Armed wake sources** — `sin-wakeups` 21.47 W with all 18 disarmed.
- **`_PTS(5)` and `device_shutdown()`** — `pm1a-acpica` 26.56 W bypassing both. **`_GTS`**
  does not exist here.
- **The entire SCI_EN hypothesis, from both sides** — `legacy-smi` 24.51 W (SCI_EN=0
  verified) and `enable-only`/`enable-toggle` ~0.3-0.7 W. **Entering ACPI mode does not
  poison anything.**
- **ALL of `acpi_init` / `acpi_bus_init`** — `no-acpi-init` 2.602 Wh with no EC, no `_OSC`,
  no `_INI`/`_STA`, no GPEs, no ACPI bus and none of its 204 devices. Side finding: it
  powered off with **SCI_EN=1** ⇒ `ACPI_ENABLE` is done by `acpi_early_init()`, not
  `acpi_init()`.
- **All 23 static SSDTs** (including the `PEGP`/`NVOP`/GC6 one) — `no-ssdt` 2.063 Wh.
- **The EC's GPE07** — `mask-gpe07` 2.110 Wh with **0 SCIs** in the whole session.
- **SMP/IOAPIC/interrupt remapping** — `nosmp-solo` 2.110 Wh. Bonus: **on x86 `nosmp`
  implies `noapic`**.
- **MCFG/ECAM** — `nommconf` 2.032 Wh. **HPET** — `nohpet` 2.772 Wh.
- **ACPICA's wiping of PM1_EN and GPE0_EN** — `gpe-wipe` clean.
- **The entire DSDT and its AML** — `dsdt-stub-v2` 22.63 W with a **live, verified 56-byte
  DSDT**.
- **AMD's IOMMU (AMD-Vi/IVRS), entirely** — `iommu-off` 19.72 W with the IOMMU off and
  verified. **The perfect correlation across 25 measurements was spurious** (see
  Methodology, rule 19 — a permanent lesson).
- **ALL AML, wherever it comes from** — `sin-aml` 24.01 W, the highest of all, with
  `acpi_no_static_ssdt` **and** the 56-byte stub at once.
- **`amd_pstate` and the `MSR_AMD_CPPC_ENABLE` bit** — cleared from both sides:
  `pstate-off` 20.37 W with the MSR at 0, and the clean `acpi=off` boot **also** reports
  `cppc_msr=0`.
- **The LAPIC** — the clean boot logged `lapic=si`. No APIC state separates the two cases:
  **a forged MADT no longer deserves a round.**
- **The FADT, ACPICA's hardware layer and the SCI handler** — `fadt-control` 18.80 W and
  `fadt-hwreduced` 22.65 W with behavioural witness `handler=0 ficheros_irq=0`. **Do not
  bisect `SCI_INT`.**
- **pstore/ramoops as a discriminator in a `poweroff`** — a cold POST retrains the DRAM;
  it only works across warm reboots.
- **`acpi=ht`, `hpet=disable`, `maxcpus=`** — do not exist in this kernel. **`nolapic`,
  `pci=noacpi`, `acpi=noirq`** — hang the boot on this Zen.

---

## Methodology: rules earned by losing measurements

1. **Raw watts are NOT comparable across windows of different length.** Use energy and
   `E = E₀ + P·t`. **E₀ ≈ 1.13 Wh** in the `minimal-init` flow, **≈0.70 Wh** in
   `grub-halt`. With `acpi=off` there is no readable battery ⇒ the window drags in TWO
   boots.
2. **Use `-m 20` windows, never `-m 5`.** Real cost of a cycle: ~22 min. `-m 10` shrinks
   the clean/poisoned separation from 3.6× to 2.3×: not worth it.
3. **The RTC "golden rule" is REFUTED.** Waking up does **not** distinguish a real S5 from
   a fake one; **only energy discriminates.**
4. **Hang witness = the intermediate `APAGADO` line missing** from `s5-energy.log`. A
   window with the machine awake reads 30-65 W: that is a hang, not a measurement.
5. **Verify EVERY parameter against vmlinux (`strings`) or `/proc/kallsyms` BEFORE
   queueing it.** A nonexistent parameter is silently ignored and the test reads as a
   negative.
6. **A witness you have never seen change between two boots is not a witness.** This cost
   three rounds (`mmconf=` looked for `MMCONFIG` when the kernel prints `ECAM`).
7. **A control that is behaviourally indistinguishable from the original validates
   nothing.** Good witnesses are behavioural, not textual.
8. **Group and bisect; do not go one at a time.** Each measurement costs a cycle and
   **cannot be parallelised.**
9. **Do NOT touch the lid during a measurement**: opening it powers the machine on (a
   firmware feature).
10. **The thermal signature on wake does NOT discriminate** clean from poisoned: 41 °C
    clean, 55 °C another clean, 66 °C poisoned. Only energy does.
11. **After EVERY kernel update, rebuild out-of-tree modules before queueing anything.**
    The old `.ko` carries the previous `vermagic`, `insmod` rejects it, and the test
    **degrades silently** down a different shutdown path. *(The akmod covers this now.)*
    Also check that ramoops' `memmap=` survived in `/proc/cmdline`.
12. **A kernel change invalidates the baseline, not just the modules.** Re-measure it
    before resuming.
13. **A new instrument only measures on the boot path where it was installed.** When you
    add a witness, check WHICH paths it runs on. Corollary: **with `acpi=off` almost no
    sensor exists** ⇒ contrast against `grub-halt`, which boots with normal ACPI.
14. **The queue only fires at boot.** Anything queued *during* a boot waits for the next
    one; to fire immediately, `sudo s5-queue next`.
15. **THE QUEUE'S THRESHOLD IS EVALUATED AGAINST THE PREVIOUS MEASUREMENT, NOT THE ONE IT
    IS ABOUT TO TAKE.** With the mitigation working, the last measurement is always under
    8 W, so **the queue refuses to launch anything**. While the working line measures ~2 W,
    `queue-umbral` has to be 0.
16. **RAMOOPS DOES NOT SURVIVE A REAL POWEROFF.** It only works for tests that reboot. ⇒
    **Capture shutdown diagnostics from userspace**, announcing each attempt BEFORE
    executing it: the last line in the log is the one that says who powered off.
17. **Never leave a backup inside a hooks directory**: `*.bak-*` **gets executed too**. It
    already sank one control by running **in parallel** with the good one. Cheap detector:
    count `=====` headers per shutdown; more than one per hook means there is an extra
    executable.
18. **On the shutdown path `/` is read-only: every `rm`/`echo` outside an `rw` remount can
    fail SILENTLY, and INTERMITTENTLY.** It is not predictable; you have to **look**. When
    writing a hook, either everything goes through the remount helper or nothing does. And
    **verify the deletion inside the hook itself and log it**, because afterwards there is
    nobody left to ask.
19. **Only a measurement that ISOLATES is evidence.** A perfect correlation over a variable
    that is only ever disabled *together with* everything else is worthless (the IOMMU
    lesson: perfect correlation across 25 measurements, and spurious). Applied
    successfully: the single-variable control is what closed this case.
20. **READING THE DISCRETE GPU'S SUBTREE WAKES IT**, and not only with `lspci`:
    `cat /proc/asound/cards` and `nvidia-smi` do it too, both with their
    `Enabling HDA controller` in `dmesg`. **Take state from sysfs and nothing else.**
    Corollary: **`runtime_active_time` is the good witness** — `power_state` can lie to you
    because of your own reading; the counter cannot.
21. **A dry run leaves the module loaded**: the second `insmod` says `File exists` and
    reads as a failure. ⇒ **`rmmod` between rehearsals.** The corollary that matters more:
    **`s5_pmrt_arm_exit()` is EMPTY on purpose** ⇒ the shield is **not** undone by
    unloading the module, only by rebooting.
22. **`modprobe` RETURNS 0 IF THE MODULE WAS ALREADY LOADED** — a false success worse than
    `File exists`, because it is indistinguishable from a good load. And **moving a module
    aside by renaming its directory INSIDE `/lib/modules` does not hide it: `depmod`
    reindexes it.** To simulate "no module", move it OUT of the tree. **General corollary,
    and the reason this rule is cited all over the code: a state you cannot inject, you
    cannot rehearse.** Faking it half way — a rename, a mount namespace, a mock the real
    lookup walks straight past — buys you a green run that proves nothing. So every path a
    test has to reach here is overridable by an environment variable, tagged in the source
    as `overridable SOLO para ensayar (regla 22)`, and those variables exist for the tests
    and for nothing else.
23. **A dry run from a root shell proves nothing**: the SELinux domain depends on the
    caller. Rehearse under `systemd-run`, never under `sudo`.
24. **Rehearse EVERY branch, not just the green one.** Guards are tested by provoking the
    failure. That is how the `abortar()` bug surfaced — it deleted a file belonging to
    something else.
25. **`Before=X` does NOT order you against the services `X` requires.** If `X` is
    `After=S`, setting `Before=X` makes you **a sibling of `S` with no ordering between
    you**, and systemd starts you both at once. During shutdown that means `S` —
    `systemd-poweroff.service`, with `SuccessAction=poweroff-force` — kills you mid-job.
    **Order against the service, not the target.** The three shutdown milestones, in order:
    **`shutdown.target`** (everything stopped, filesystems still mounted) →
    **`umount.target`** (nothing left mounted but `/`) → **`final.target`**.
26. **A rehearsal under `systemd-run` CANNOT validate an assumption about the ORDER of the
    shutdown sequence**: on a live machine everything is mounted and nobody kills you, so
    the green branch comes out green regardless. Rehearse anyway (it catches logic bugs),
    but **a window assumption is only closed by a real shutdown** ⇒ plant a witness in the
    log **and make the verifier read it for you**, because otherwise nobody will.
27. **A false FAILURE in the verifier is expensive.** It once cried FAILURE over 35.92 W
    that came from **a different test, 43 minutes earlier, and was a hang rather than a
    measurement** — while the real shutdown afterwards had gone perfectly. **Tie the
    measurement to the shutdown that produced it**, and **>30 W is not an S5 measurement,
    it is a hang** (rule 4; the highest legitimate figure ever measured was 26.56 W).
    Crying wolf is the fastest way to make sure nobody reads your report again.
28. **ON SHUTDOWN, MOUNTS DIE BEFORE `shutdown.target`, and no ordering preserves them.**
    If a unit that is **started** during the shutdown transaction needs `/boot` (or any
    filesystem other than `/`), **it has to mount it itself**: `mount /boot` via fstab, a
    flag so it only unmounts what it mounted, and fail safe if it cannot. Ordering against
    `boot.mount` does not work — with one stop job and one start job, the stop goes first
    whether you write `After=` or `Before=` (`systemd.unit(5)`). And **`umount.target` is
    not "when things get unmounted"**: it is an end-of-sequence synchronisation point.
    Method corollary: when a witness tells you something strange twice, the second time is
    not "the same bug again" — it means your explanation of the first one was wrong.
29. **To rehearse "without a filesystem", unmount it for real; `unshare -m` will not do.**
    In a namespace the superblock is still live on the host, so the `mount` inside attaches
    to it and **you are not testing a cold mount** (fresh superblock + ext4 journal replay),
    which is what will happen at shutdown. Unmounting for real on the host is cheap and
    safe with a `trap` that restores it; verify afterwards in `dmesg`.
30. **A test whose verdict depends on the real clock is not a test.** One section here
    derived the boot instant from `date` and `/proc/uptime`, so its verdict depended on how
    long the machine had actually been off — the one thing fixtures cannot fabricate. After
    a long night the gap came out in hours and **the branch that must warn came out green**:
    the test passed or failed depending on what time of day you ran it. If a verdict depends
    on time, **time has to be injectable**, and each case must be built as a whole scenario
    rather than by fudging one magnitude until the number comes out right.
31. **A caveat hardcoded for one regime lies in the other.** The verifier refused to score
    *any* shutdown diverted through GRUB, explaining that the window "is almost entirely
    awake and the real S5 lasted seconds". True for the 20-minute windows it was written
    against; false for a whole night, where the manoeuvre is 0.4 % of the window. So
    `politica-grub-real-v1` — the best measurement of the series, and the only one that
    exercises the rare case end to end — was published as **"threshold does not apply"**,
    while the same report printed the 9.52 h gap three lines above. **If a caveat depends on
    a magnitude, compute the magnitude; do not word it.** Corollary earned immediately
    afterwards, when the rehearsal caught the first version of the fix approving a window at
    **23795 %**: the guard has to reject the *impossible* as firmly as the bad. The energy
    window contains the S5 by construction, so a fraction above 100 % does not mean
    "very clean" — it means the two sources are not describing the same shutdown, and the
    only honest answer is to abstain.

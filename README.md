# s5-poweroff-fix

**Your laptop is switched off, and it still burns 18-20 W. By morning the battery is
flat.** This fixes it: measured **~20 W → 0.46 W**. The culprit is the discrete
GPU, which Linux **wakes up** on its way into S5.

If you are here because you searched for *laptop drains battery when powered off*,
*battery dead after shutdown Linux*, *high power consumption S5*, or *laptop hot
after shutdown* — yes, this is probably your bug, and no, you are not imagining it.

> **Language:** everything written *for a reader* is in English — this README,
> [`docs/EVIDENCE.md`](docs/EVIDENCE.md), [`kmod/REBUILDING.md`](kmod/REBUILDING.md)
> and the annotated [`s5-poweroff-fix.conf.example`](s5-poweroff-fix.conf.example).
> Everything written *for the machine* is in Spanish: code comments, commit messages,
> and **all program output** (the `s5-mitigacion-check` report, the log files, the
> systemd unit descriptions). The samples below are real output, so they are in
> Spanish too.

---

## Does this affect me?

**The test takes one night and costs nothing.** Unplug the charger, shut the machine
down completely (not suspend, not hibernate — a real `poweroff`), note the battery
percentage, and look again in the morning. If it dropped more than 5-10%, you have it.

Two more tells:

- **Windows on the same machine is fine.** That is the whole point: the hardware can
  do a clean S5, so this is not a broken laptop.
- **The chassis is warm** hours after you shut it down, and the fans are off.

Typical profile: hybrid-graphics laptop (Intel or AMD + a discrete GPU), EFI boot,
Linux. Most reports involve **NVIDIA Optimus**, but the underlying kernel bug is not
NVIDIA-specific — upstream reports also blame **Thunderbolt/USB4 docks**, xHCI
controllers, and PCIe ports themselves.

**There is no error message.** Nothing appears in `dmesg`, nothing fails, no service
crashes. The shutdown looks perfect. That is exactly why this is hard to find, and why
this repo exists.

## What is actually happening

Linux's shutdown path, in `drivers/pci/pci-driver.c`, does this to every PCI device:

```c
static void pci_device_shutdown(struct device *dev)
{
        ...
        pm_runtime_resume(dev);          /* <-- wakes the dGPU, which was in D3cold */
        if (drv && drv->shutdown)
                drv->shutdown(pci_dev);  /* <-- and nv_pci_shutdown finishes the job */
}
```

That `pm_runtime_resume()` is **unconditional**, and it runs **after** every userspace
shutdown hook. So no script can fix this: you can put the dGPU to sleep a millisecond
before poweroff and the kernel will wake it right back up. It enters S5 powered on and
sits there drawing ~19 W until the battery is gone.

It has been there since 2012 ([commit `3ff2de9ba1a2`][c2012], *"PCI/PM: Resume device
before shutdown"*), and the reason is **kexec**: after a kexec the device will not
enumerate if its bridge is not in D0. On a real poweroff there is no kexec — and
`pci_device_shutdown()` already tests `kexec_in_progress` a few lines below, to decide
whether to clear Bus Master. The kernel knows which case it is in; the resume just does
not ask.

**The platform is not at fault.** Halting straight from GRUB — so that no Linux kernel
ever runs the shutdown path — the same machine measures **1.05 W**. The firmware's S5
is clean. What poisons it is what Linux leaves behind on the way out.

[c2012]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=3ff2de9ba1a2e22e548979dbcd46e999b22c93d8

## What this patch does

A tiny GPL kernel module (`s5_pmrt_arm`, ~180 lines) is loaded at the very last moment
of shutdown and shields the discrete GPU's subtree against both halves of the problem:

- **`__pm_runtime_disable(dev, false)`** → the `pm_runtime_resume()` bounces with
  `-EACCES` and the device stays in D3cold.
- **`drv->shutdown = NULL`**, and only for a whitelist (`nvidia`, `snd_hda_intel`).
  **Never for `pcieport`**, which governs every port on the machine.

systemd then powers off through its **normal path**, with `_PTS(5)` and
`device_shutdown()`. The only thing that changes is that the dGPU does not wake up.

**Both halves are inseparable.** Doing only the first one leaves `nv_pci_shutdown()`
running against a GPU that has no power, and **that hangs the machine** — measured
here, twice. See [`docs/EVIDENCE.md`](docs/EVIDENCE.md).

### The rare case, and its safety net

The shield only works **if the dGPU arrives asleep**. If it arrives awake (external
HDMI monitor, live CUDA, PRIME offload), shielding freezes it *awake* and S5 costs
19.38 W again. A policy handles that at shutdown time:

```
dGPU awake at poweroff
   ├── drops to D3cold within 90 s ──> normal poweroff             ~0.46 W
   └── still in D0 after 90 s ───────> reboot, GRUB halts instead  ~0.32 W  (visible POST)
```

**Both numbers are whole nights**, and that is the point: they are rows in the table
below (`nocturna-real` and `politica-grub-real-v1`), measured over windows of the same
order, so they can be compared with each other and with the ~19 W they replace. Rule 1 in
[`docs/EVIDENCE.md`](docs/EVIDENCE.md) — raw watts do not survive a change of window
length — applies to this diagram as much as to the table. Elsewhere this project uses
"~2 W" as shorthand for a mitigated shutdown; that is the same result read off a
20-minute window, where the fixed energy cost of shutting down and booting again —
rule 1's `E₀` — has not yet been amortised. Same shutdown, shorter ruler.

It has **never been needed on its own** across every real shutdown measured here: once
userspace lets go, runtime PM puts the GPU to sleep well inside the 90 s budget. The only
times the GRUB branch has fired were **deliberately forced** controls, pinning the dGPU to
D0 to provoke it. It is insurance, not the mechanism — but it has now been measured over a
whole night, and it works: see `politica-grub-real-v1` below.

**Everything fails safe.** If the module will not load, if `/boot` cannot be mounted, if
this GRUB has no `halt` command — it gets logged and the shutdown proceeds normally. You
lose the saving; you do not lose the shutdown.

## Install

> **What this does to your machine, before you run it.** It installs two systemd
> shutdown hooks and four units, all as root; it loads an out-of-tree kernel module
> during shutdown; and in its rare-case branch it **writes a one-shot entry into your
> bootloader** (`custom.cfg` + `next_entry` in `/boot/grub2`) and reboots. Every one of
> those paths is written to fail safe — if the module will not load, if `/boot` cannot be
> mounted, if GRUB has no `halt`, it gets logged and the shutdown carries on normally —
> and `uninstall.sh` sweeps the bootloader entry back out. But it is your boot path, and
> it has only ever run on the one machine described under *Status and limits*.
> `./install.sh --check` writes nothing, so you can look first. **No warranty**; see
> [`LICENSE`](LICENSE) (GPL-2.0).

```bash
sudo ./install.sh --check     # writes nothing: shows which devices it detects
sudo ./install.sh             # install
cd kmod/ && cat REBUILDING.md   # the module, via akmod
sudo s5-mitigacion-check      # must report TODO EN ORDEN
```

The first thing `install.sh --check` does is show you **what it is going to shield**:

```
dGPU           : 0000:01:00.0
audio          : 0000:01:00.1
puente PCIe    : 0000:00:01.1
```

Check that against `lspci -D` before continuing. If your topology is unusual, pin it by
hand in `/etc/s5-poweroff-fix.conf` (see `s5-poweroff-fix.conf.example`).

**The module ships as an `akmod` on purpose**, rather than hand-compiled: that way it is
rebuilt automatically on every kernel update. A loose `.ko` carries the `vermagic` of the
kernel it was built against, and after the first `dnf update` the mitigation would **die
silently**.

Uninstall: `sudo ./uninstall.sh` (add `--purge` to remove the logs too).

**Distro note:** the GRUB branch detects the local flavour at run time — `grub2-reboot`
and `/boot/grub2/` on Fedora/RHEL/SUSE, `grub-reboot` and `/boot/grub/` on
Debian/Ubuntu/Arch. Commands and directory are looked up **independently**, so mixed
installs work too, and the directory only counts if it actually holds a `grubenv`. Run
`sudo s5-descubre-grub` to see what it picked; pin it with `S5_GRUB_DIR`,
`S5_GRUB_REBOOT` and `S5_GRUB_EDITENV` if yours lives somewhere else. If nothing usable
turns up the branch self-disables and the shutdown just proceeds normally. Only the
Fedora path has run on real hardware here; the Debian one is covered by fixtures in
`tests/ensayo-ramas.sh`. Everything else — which is where the 19 W actually comes from —
is distro-agnostic.

## Checking it is still alive

`s5-mitigacion-check` runs itself on every boot and looks both ways: whether you will be
protected on the **next** shutdown, and whether you were on the **last** one and what it
cost. It drops `/var/lib/s5-test/mitigacion-ROTA` and shouts via `wall` if anything is
wrong.

This exists because the natural failure mode here is **silent**: if the module does not
load, the shutdown still looks perfect and burns 19 W.

## The measurements

| | |
|---|---|
| Normal shutdown, no patch (baseline, n=2) | **20.05 / 19.73 W** — the battery does not survive the night |
| The single-variable control that pins it on the dGPU | **19.85 W** |
| Patched, four real nights (7.2 / 8.6 / 7.4 / 7.3 h) | **0.46 / 0.46 / 0.47 / 0.45 W** |
| GRUB `halt` (clean control) | **1.05 W** |
| dGPU **awake** at poweroff (the rare case) | **19.38 W** |
| …and the policy catching that rare case, over a whole night | **0.32 W** |

The 19.85 W row is **not** a plain unpatched shutdown, and the distinction matters: it is
`gpu-d0-pm1a-control-v3`, with the dGPU pinned in D0 and the poweroff going through
`PM1a_CNT` so that `device_shutdown()` never runs. That is what makes it evidence — it
changes one variable against its own twin — but the number you would actually measure on
an unpatched machine is the baseline above.

The third night came **after a real kernel upgrade** (`7.1.7-200` → `7.1.8-200`): akmods
rebuilt the module on its own and the saving was still there.

Over 30 instrumented measurements in [`docs/EVIDENCE.md`](docs/EVIDENCE.md), including
every **ruled-out** hypothesis (the DSDT, wakeup sources, `acpi=off`, a genuine AML bug
in the BIOS, upgrading the BIOS). Those are half the value here: they save you from
walking down dead ends that have already been walked.

## Status and limits

Honestly:

- Measured on **one machine** (HP OMEN 16-ap0xxx, Fedora 44, RTX + integrated Radeon).
  The mechanism is generic; the numbers are not.
- The overnight measurement is at **n=4** (0.46 / 0.46 / 0.47 / 0.45 W), but all four are
  the same laptop: they repeat the measurement, they do not make it independent.
- The **GRUB branch** has now been measured over a whole night (`politica-grub-real-v1`,
  2026-08-14: 0.32 W over 9.55 h), but at **n=1**, and only ever with the dGPU pinned to
  D0 by hand to force it. Nobody has yet seen it fire because a real workload held the
  GPU awake.
- It **has** survived a kernel upgrade (2026-08-13). That was the most likely silent
  failure. It is still the thing to watch after every kernel update, which is what
  `s5-mitigacion-check` is for.
- This is a **userspace mitigation of a kernel problem**, not the fix. The real fix
  belongs upstream: `pci_device_shutdown()` should not resurrect devices that are already
  in D3cold and whose driver does not need `shutdown()`.

No distribution carries a fix for this, and there is no DMI quirk for S5 power in the
kernel — hence this repo.

## Layout

```
system/     what gets installed: shutdown hooks, scripts, units, logrotate
  bin/s5-descubre-dgpu   finds the dGPU via sysfs (no hardcoded paths)
kmod/       module source (plain .c) + the akmod spec that packages it
tools/      measurement and diagnostic instruments (install.sh --tools)
tests/      92-branch test: verifier, uninstaller, device and GRUB-flavour
            detection and the rare-case policy — all with generated fixtures
docs/       the evidence base
```

## License

GPL-2.0. The module is kernel code; the rest follows for consistency.

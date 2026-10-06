# Powering off from the firmware on a machine with `systemd-boot`

This is the piece the **rare case** is missing on a machine without GRUB. There are no new
measurements here yet: what there is is the mechanism, its brakes, and what is still to be
tested. Once there is a real poweroff, its row goes into `docs/EVIDENCE.md`.

## Why it is needed

The rare-case branch of `s5-gpu-politica` (the dGPU did not fall asleep within 90 s) powers
off from GRUB with `halt`: in that boot **no Linux kernel ever gets to run**, the firmware
does its own S5 with the hardware just as POST left it, and the measurement comes out clean
(`grub-halt`, 1.05 W, 2026-08-09).

On a machine with `systemd-boot` there is no `halt` to fall back on, and doing it from a live
kernel **is not equivalent** — already measured in `docs/EVIDENCE.md`:

| attempt from a live kernel | result |
|---|---|
| module calling `ResetSystem` through EFI (`efi-poweroff`) | 19.26 W |
| direct write to `PM1a_CNT`, without `_PTS(5)` or `device_shutdown()` (`pm1a-acpica`) | 26.56 W |

What saves the measurement is not "powering off through the firmware", it is that **no kernel
ever got to boot**: that way the dGPU never wakes up and there is no rail to cut.

## What this piece does

```
system/efi/s5-halt.c        minimal EFI application: deletes the variable and ResetSystem(EfiResetShutdown)
system/efi/Makefile         two build routes: gnu-efi+objcopy, or clang+lld-link
system/bin/s5-descubre-boot discovers ESP, bootctl, one-shot entry support, efivarfs
system/bin/s5-politica-boot the branch: discover, arm, verify and reboot (the policy calls it)
tools/s5-boot-halt          instalar / armar / abortar / estado (builds, signs and installs to the ESP)
```

`s5-gpu-politica` gains a block at the start of its rare-case branch: if there is **no usable
GRUB** (`grub*-reboot` or `grub*-editenv` are not there), it tries this route before going on
with the GRUB path, which does not change a single line. If the systemd-boot route cannot do it
either, it records that and the poweroff continues as normal. `uninstall.sh` sweeps away the
entry, the application and the arming.

The application **does not use the gnu-efi library** (only its headers): it is thirty lines, and
that way the same source builds through both routes, which are not available on the same
machines:

| route | when |
|---|---|
| `make` (gnu-efi + `objcopy --target=efi-app-x86_64`) | the normal one, and what Fedora ships |
| `make clang` (`clang --target=x86_64-pc-win32-coff` + `lld-link /subsystem:efi_application`) | when the distribution's binutils does not carry the EFI target (`objcopy --info | grep efi-app-x86_64` returns nothing) |

`make check` says which one is available and, if neither is, how to install it.

* The **entry is permanent** (`$ESP/EFI/s5-halt/s5-halt.efi` +
  `$ESP/loader/entries/s5-halt.conf`, type `efi`). Without the one-shot variable it is just
  another entry in the menu: it never fires on its own.
* **Arming means writing an EFI variable** (`bootctl set-oneshot s5-halt`). Nothing has to mount
  `/boot` or write to the ESP during the poweroff window, which is precisely the problem the
  GRUB branch has (mounts die before `shutdown.target`, which is why it mounts `/boot` by hand).
  Here the ESP is only touched at install time.
* **Anti-loop, with two barriers**: the first is the boot loader itself, which consumes
  `LoaderEntryOneShot` when it uses the entry —it is "for the next boot", and systemd-boot
  deletes it—; the second is the application, which deletes it before powering off. Measured on
  2026-10-06: with the poweroff already done, the application's delete returned an error because
  systemd-boot had taken it first, and there was no loop. The entry's file stays on purpose and
  the boot cleanup sweeps it, exactly as the GRUB branch already does with its `custom.cfg`.
* **Fail safe, always**: without `ResetSystem`, or if it returns without powering off, the
  application returns `EFI_SUCCESS` and `systemd-boot` carries on with its menu and its default
  entry. What is lost is that poweroff's saving, not the boot. Same with the discovery script:
  whatever is missing is named out loud and the command is not carried out.
* **It makes itself visible**: before powering off it writes the firmware's time stamp (**in
  UTC, with the `Z`**: this machine's RTC runs in UTC, and the first version stored `05:50:24`
  for a poweroff at `13:50` local) into a variable of its own (`S5HaltLastRun`). It is needed
  because a poweroff from the boot loader **leaves no kernel log** —no journal, no `dmesg`, not
  even the witness—: without that marker, telling "the application ran" from "the firmware
  rebooted and nobody noticed" depends on the memory of whoever ran the rehearsal, and that is
  not evidence. `s5-boot-halt estado` reads it and translates it to local time
  (`ultimo apagado : SI, por firmware, el 2026-10-06 13:50:24 CST`), `armar` deletes it so that
  what is read belongs to that rehearsal, and `uninstall.sh` takes it away. The application also
  prints the `EFI_STATUS` in hexadecimal when something fails: that number on screen is the only
  clue left. The console of a real rehearsal, in
  [`docs/img/rehearsal-2026-10-06.jpg`](img/rehearsal-2026-10-06.jpg), is this text and nothing
  else: there is no kernel behind it to tell the story.
* **It touches nothing that already exists**: it adds a new entry and an EFI variable. It does
  not change the boot loader, the kernel, or any previous entry. `uninstall.sh` and
  `s5-boot-halt abortar` leave it as it was.

## Secure Boot

With Secure Boot on, the firmware only loads images signed by a key it knows. The application is
signed **by the user with their own keys** (`sbctl sign` or `sbsign`); this project installs no
keys and touches no database. Unsigned, `systemd-boot` will not load it, the menu comes back and
the usual thing boots: nothing breaks, but nothing is saved either. That is why `instalar`
checks the signature (`sbctl verify`) and refuses to go on if it cannot sign it.

## What is tested and what is not (2026-10-06)

* **Tested**: the discovery script and the failure branches of everything else, on an `8E35`
  with `systemd-boot` 262 (ESP at `/boot`, one-shot entry supported, Secure Boot on). `estado`
  reports everything, `make check` says which build route there is, and both `s5-politica-boot`
  and the tool refuse to go on without the application installed (tested: they log the reason
  and return 1, without touching the ESP or efivarfs).
* **Tested**: building the application through the clang + lld-link route, on that same machine:
  out comes a 3 KB PE32+, subsystem `EFI application` (0x0a) and with a `.reloc` relocation
  directory. The gnu-efi route **cannot** be tested there because its `objcopy` does not carry
  the `efi-app-x86_64` target — which is exactly why the second route exists.
* **Tested end to end on 2026-10-06**: signing with the user's `sbctl` keys, installing the
  application and its entry to the ESP, arming the one-shot variable, and a real poweroff. The
  boot loader consumed `LoaderEntryOneShot`, the application ran, the firmware powered the
  machine off **with no kernel in that boot**, `S5HaltLastRun` was written and read back, and the
  next boot was the normal one (console in
  [`docs/img/rehearsal-2026-10-06.jpg`](img/rehearsal-2026-10-06.jpg)). The second version of the
  delete-warning is also covered by that run: systemd-boot had already taken the variable, the
  delete returned an error, and there was no loop.
* **Measured once, pending a repeat**: the rare case (dGPU pinned in D0 with `power/control=on`)
  powered off through systemd-boot's built-in `auto-poweroff` entry, with no kernel in that boot,
  gave 3.404 Wh over 0.7628 h ⇒ 4.46 W. It is a single window, the tool grades it `borderline`,
  and `energy_full` moved inside the window, so the figure is being repeated before it is treated
  as settled. The row goes into `docs/EVIDENCE.md`.
* **Open question, not a defect**: the built-in `auto-poweroff` entry makes this whole
  application optional. It powers off the same way at the same stage with no build, no signature
  and no write to the ESP — the price is the `S5HaltLastRun` marker. Which of the two should be
  the default is a call for the maintainer, not a settled one.
* **Not tested on other machines**: the ESP layout (`/boot`, `/efi`) is this one's; the discovery
  script asks `bootctl` and tries several, but it has only been seen on one.
* **Not tested**: that firmware and boot loaders from other vendors accept the `efi` entry and
  the variable delete from the application. Here the `efi` entry is the one the system itself
  uses to boot, and deleting variables from an application is what any UEFI installer does, but
  it has not been exercised.

## How it would be tested

```bash
# 1. the build route this machine has (it says so itself)
make -C system/efi check
# 2. build, sign (Secure Boot) and install to the ESP
sudo tools/s5-boot-halt instalar
# 3. that everything is in place and nothing is armed
sudo tools/s5-boot-halt estado
# 4. arm and power off
sudo tools/s5-boot-halt armar        # or: sudo system/bin/s5-politica-boot --armar-solo
```

What is expected: the firmware powers off without booting anything, the machine goes cold and
the S5 lands in `grub-halt` territory (1.05 W over 45 min) rather than in the ~19 W one. If it
goes wrong, the signal is clear: the menu comes up and the normal boot continues, or
`s5-halt.efi` runs and the menu comes back — in both cases there is a trace on the console and
in the policy log.

**Disarming, if you change your mind before powering off**: `sudo tools/s5-boot-halt abortar`.
Mind the detail that cost a while: EFI variables are **immutable** (`----i----` in `lsattr`), so
a plain `rm` fails with `EPERM`; the attribute has to be removed first (`chattr -i`), which is
what `bootctl` does internally and what the tool does now.

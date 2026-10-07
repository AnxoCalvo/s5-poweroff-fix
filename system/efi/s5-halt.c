// SPDX-License-Identifier: GPL-2.0
/*
 * s5-halt.efi — power the machine off from the FIRMWARE, with no kernel involved.
 *
 * WHY. In this project the rare case (the dGPU does not fall asleep and S5 would
 * come out at ~19 W) is covered by powering off from GRUB with `halt`: in THAT
 * boot no Linux kernel ever runs, the firmware does its own S5 with the hardware
 * exactly as POST left it, and the measurement comes out clean (1.05 W). On a
 * machine with systemd-boot there is no `halt` to be had, and this is the
 * equivalent: a three-instruction EFI application that systemd-boot starts like
 * any other entry, with `bootctl set-oneshot` to make it one-shot.
 *
 * WHY DOING IT FROM THE KERNEL IS NOT EQUIVALENT, which would be more convenient.
 * It has been measured and it is in docs/EVIDENCE.md: a module that calls
 * ResetSystem through EFI from a live kernel leaves S5 at 19.26 W, and writing
 * PM1a_CNT by hand without `_PTS(5)` or `device_shutdown()` leaves it at 26.56 W.
 * What saves the measurement is not "powering off through the firmware" but that
 * no kernel ever got to boot: that way the dGPU never wakes up and there is no
 * rail to cut.
 *
 * NO LIBRARY, ON PURPOSE: only the gnu-efi headers are used (the types and the
 * system table), not libefi or libgnuefi. It is thirty lines and there is nothing
 * a library would add here; in exchange, the same source builds through the TWO
 * known routes, which are not available on the same machines:
 *
 *   gnu-efi + objcopy with efi-app-x86_64   (the normal one; see system/efi/Makefile)
 *   clang --target=x86_64-pc-win32-coff + lld-link /subsystem:efi_application
 *
 * The second is the one needed when the distribution's binutils does not carry the
 * EFI target (check it with `objcopy --info | grep efi-app-x86_64`). On the machine
 * where this was written that is exactly the case, and clang+lld produces a valid
 * and smaller PE image. Both are documented in docs/systemd-boot-halt.md.
 *
 * ANTI-LOOP. It deletes the `LoaderEntryOneShot` EFI variable before calling
 * ResetSystem, as a second barrier: the first is the boot loader itself, which
 * consumes it when it uses the entry (measured on 2026-10-06: with the poweroff
 * already done, the delete here returned an error because systemd-boot had taken
 * it first). Both point at the same thing — if the firmware did not power off, or
 * if ResetSystem returned, the next boot is the normal one — and the entry's file
 * stays on the ESP on purpose: once the variable is consumed it is just another
 * menu entry, and uninstall.sh sweeps it, exactly as the GRUB branch already does
 * with its custom.cfg.
 *
 * SAY IT OUT LOUD. Everything that happens here is printed to the firmware
 * console, which is the only place anything can be recorded: in that boot there is
 * no kernel, so there is no journal, no dmesg, no witness. That is why the
 * run marker is written too (see marcar()).
 *
 * FAIL SAFE, ALWAYS. If there is no ResetSystem, or if it returns without powering
 * off, this returns EFI_SUCCESS and systemd-boot carries on with its menu and its
 * default entry: what is lost is that poweroff's saving, not the boot.
 *
 * SIGNING. With Secure Boot enabled the firmware only loads images signed by a key
 * it knows. This one has to be signed (tools/s5-boot-halt does it with sbctl if the
 * user's keys are where they are expected). Unsigned, systemd-boot will not load
 * it, stays in the menu and boots the usual thing: nothing breaks, but nothing is
 * saved either - which is why the installation checks it and says so.
 *
 * IT SHOWS ITSELF. Before powering off it writes the firmware's time into
 * `S5HaltLastRun` (its own GUID): a poweroff from the boot loader leaves no kernel
 * log, so without that marker there is no way to tell "the application ran" from
 * "the firmware rebooted and nobody noticed". `s5-boot-halt estado` reads it and
 * `armar` deletes it, so what is read belongs to THIS rehearsal.
 */

#include <efi.h>

/* systemd's GUID for the Loader* variables: the same one that shows up in
 * /sys/firmware/efi/efivars/LoaderEntryOneShot-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f */
static EFI_GUID loader_guid = {
	0x4a67b082, 0x0a4c, 0x41cf,
	{ 0xb6, 0xc7, 0x44, 0x0b, 0x29, 0xbb, 0x8c, 0x4f }
};

/* This project's own GUID for the run marker. In efivarfs the variable appears as
 * S5HaltLastRun-8b8c1b5e-2f1a-4b3c-9a7d-512c6e0a3f11 */
static EFI_GUID s5_guid = {
	0x8b8c1b5e, 0x2f1a, 0x4b3c,
	{ 0x9a, 0x7d, 0x51, 0x2c, 0x6e, 0x0a, 0x3f, 0x11 }
};

/*
 * Its own Print() instead of libefi's: it calls the system table's console
 * service, which is all that is needed. Without a console it stays quiet instead
 * of crashing - the poweroff does not depend on being able to tell anyone.
 */
static void decir(EFI_SYSTEM_TABLE *st, CHAR16 *texto)
{
	if (st && st->ConOut && st->ConOut->OutputString)
		st->ConOut->OutputString(st->ConOut, texto);
}

/* An EFI_STATUS in hexadecimal: if something fails, that number is the only clue
 * left on screen, and "could not delete X" without the code forces guessing. */
static void decir_status(EFI_SYSTEM_TABLE *st, EFI_STATUS rc)
{
	static const char hex[] = "0123456789ABCDEF";
	CHAR16 b[12];
	int i;

	b[0] = '0';
	b[1] = 'x';
	for (i = 0; i < 8; i++)
		b[2 + i] = (CHAR16)hex[((unsigned)rc >> ((7 - i) * 4)) & 0xf];
	b[10] = '\0';
	decir(st, b);
}

/*
 * RUN MARKER. A poweroff from the boot loader leaves NO kernel log at all: no
 * journal, no dmesg, no witness. Without something written from here, knowing
 * whether the rehearsal worked depends on the memory of whoever ran it, and that
 * is not evidence. The firmware's time is left in a variable of its own;
 * `s5-boot-halt estado` reads it and `armar` deletes it, so its content speaks of
 * the last rehearsal and not of any other one.
 *
 * IT IS NOT CRITICAL: if this fails it says so on the console and the poweroff
 * continues.
 */
static EFI_STATUS marcar(EFI_SYSTEM_TABLE *st)
{
	static const char dig[] = "0123456789";
	EFI_TIME t;
	CHAR16 buf[32];
	char iso[24];
	EFI_STATUS rc;
	int i = 0, n;

	if (!st->RuntimeServices || !st->RuntimeServices->GetTime)
		return EFI_UNSUPPORTED;
	if (EFI_ERROR(st->RuntimeServices->GetTime(&t, NULL)))
		return EFI_UNSUPPORTED;

#define DIG2(v) do { iso[i++] = dig[((v) / 10) % 10]; iso[i++] = dig[(v) % 10]; } while (0)
	iso[i++] = dig[(t.Year / 1000) % 10];
	iso[i++] = dig[(t.Year / 100) % 10];
	DIG2(t.Year % 100);
	iso[i++] = '-';
	DIG2(t.Month);
	iso[i++] = '-';
	DIG2(t.Day);
	iso[i++] = ' ';
	DIG2(t.Hour);
	iso[i++] = ':';
	DIG2(t.Minute);
	iso[i++] = ':';
	DIG2(t.Second);
#undef DIG2
	/* This machine's RTC runs in UTC (timedatectl: RTC time = Universal time),
	 * so the firmware's time is stored as it comes and with the Z: whoever reads
	 * it knows it is UTC and translates. On 2026-10-06 "05:50:24" was stored for
	 * a poweroff at 13:50 local, and that confusion is what the Z prevents. */
	iso[i++] = 'Z';
	iso[i] = '\0';

	for (n = 0; n <= i; n++)
		buf[n] = (CHAR16)iso[n];

	rc = st->RuntimeServices->SetVariable(L"S5HaltLastRun", &s5_guid,
					      EFI_VARIABLE_NON_VOLATILE |
					      EFI_VARIABLE_BOOTSERVICE_ACCESS |
					      EFI_VARIABLE_RUNTIME_ACCESS,
					      (UINTN)(i + 1) * sizeof(CHAR16), buf);
	if (!EFI_ERROR(rc)) {
		decir(st, L"s5-halt: run marker written to S5HaltLastRun (");
		decir(st, buf);
		decir(st, L")\r\n");
	}
	return rc;
}

EFI_STATUS efi_main(EFI_HANDLE imagen, EFI_SYSTEM_TABLE *st)
{
	EFI_STATUS rc;

	(void)imagen;

	decir(st, L"s5-halt: powering off from the firmware, no kernel involved...\r\n");

	if (!st || !st->RuntimeServices) {
		decir(st, L"s5-halt: no runtime services; going back to the menu\r\n");
		return EFI_SUCCESS;
	}

	/*
	 * ANTI-LOOP, and a measurement in passing. On 2026-10-06, with the entry
	 * consumed and the poweroff done, this delete returned an error: systemd-boot
	 * had already deleted LoaderEntryOneShot when it used it (the variable "is for
	 * the next boot", and the boot loader consumes it). So this call is a second
	 * barrier, not the only one, and the earlier warning ("if this does not power
	 * off, the next boot may repeat it") was too alarming for a normal case. Now
	 * the code and what it means are stated.
	 */
	rc = st->RuntimeServices->SetVariable(L"LoaderEntryOneShot", &loader_guid,
					      0, 0, NULL);
	if (EFI_ERROR(rc)) {
		decir(st, L"s5-halt: LoaderEntryOneShot was already gone (status ");
		decir_status(st, rc);
		decir(st, L"); the boot loader consumes it when it uses the entry, so\r\n");
		decir(st, L"         the next boot is the normal one even if this does not power off\r\n");
	}

	/* The marker goes after the delete: that way, if the poweroff happens, what
	 * is written says "the application got this far", not "somebody armed it". */
	rc = marcar(st);
	if (EFI_ERROR(rc))
		decir(st, L"s5-halt: warning: could not leave the run marker (does not affect the poweroff)\r\n");

	if (!st->RuntimeServices->ResetSystem) {
		decir(st, L"s5-halt: this firmware does not offer ResetSystem; going back to the menu (normal boot)\r\n");
		return EFI_SUCCESS;
	}

	st->RuntimeServices->ResetSystem(EfiResetShutdown, EFI_SUCCESS, 0, NULL);

	/*
	 * If this is reached, ResetSystem returned without powering off. A normal
	 * boot is better than a hang: it says so and returns control to the boot
	 * loader.
	 */
	decir(st, L"s5-halt: ResetSystem returned without powering off; going back to the menu (normal boot)\r\n");
	return EFI_SUCCESS;
}

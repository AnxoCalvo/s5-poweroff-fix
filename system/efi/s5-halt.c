// SPDX-License-Identifier: GPL-2.0
/*
 * s5-halt.efi — apagar desde el FIRMWARE, sin kernel de por medio.
 *
 * PARA QUE. En esta casa el caso raro (la dGPU no se duerme y el S5 saldria a
 * ~19 W) se cubre apagando desde GRUB con `halt`: en ESE arranque no llega a
 * ejecutarse ningun kernel de Linux, el firmware hace su propio S5 con el
 * hardware tal y como lo dejo el POST, y la medida sale limpia (1,05 W). En una
 * maquina con systemd-boot no hay `halt` que valga, y esto es el equivalente:
 * una aplicacion EFI de tres instrucciones que systemd-boot arranca como
 * cualquier otra entrada, con `bootctl set-oneshot` para que sea de un solo uso.
 *
 * POR QUE NO VALE HACERLO DESDE EL KERNEL, que seria mas comodo. Ya se midio y
 * esta en docs/EVIDENCE.md: un modulo que llama a ResetSystem por EFI desde un
 * kernel vivo deja el S5 en 19,26 W, y escribir PM1a_CNT a mano sin `_PTS(5)` ni
 * `device_shutdown()` lo deja en 26,56 W. Lo que salva la medida no es "apagar
 * por el firmware" sino que no haya llegado a arrancar un kernel: asi la dGPU
 * nunca se enciende y no hay riel que cortar.
 *
 * SIN LIBRERIA, A PROPOSITO: solo se usan las cabeceras de gnu-efi (los tipos y
 * la tabla de sistema), no libefi ni libgnuefi. Son treinta lineas y no hay nada
 * que una libreria aporte aqui; a cambio, el mismo fuente se puede compilar por
 * las DOS vias conocidas, que no estan disponibles en las mismas maquinas:
 *
 *   gnu-efi + objcopy con efi-app-x86_64   (lo normal; ver system/efi/Makefile)
 *   clang --target=x86_64-pc-win32-coff + lld-link /subsystem:efi_application
 *
 * La segunda es la que hace falta cuando el binutils de la distribucion no trae
 * el objetivo EFI (comprobarlo: `objcopy --info | grep efi-app-x86_64`). En la
 * maquina donde se escribio esto pasa justo eso, y con clang+lld sale una imagen
 * PE valida y mas pequena. Las dos estan documentadas en docs/systemd-boot-halt.md.
 *
 * ANTI-BUCLE. Borra la variable EFI `LoaderEntryOneShot` antes de llamar a
 * ResetSystem, como segunda barrera: la primera es el propio cargador, que la
 * consume al usar la entrada (medido el 2026-10-06: con el apagado hecho, el
 * borrado de aqui devolvio error porque systemd-boot ya se la habia llevado). Las
 * dos apuntan a lo mismo —si el firmware no llegara a apagarse, o si ResetSystem
 * volviera, el arranque siguiente es el normal—, y el fichero de la entrada se
 * queda en la ESP a proposito: una vez consumida la variable es una entrada mas
 * del menu, y la barre el uninstall.sh, como ya hace la rama de GRUB con su
 * custom.cfg.
 *
 * DILO EN VOZ ALTA. Todo lo que pasa aqui se imprime en la consola del firmware,
 * que es el unico sitio donde puede quedar constancia: en ese arranque no hay
 * kernel, asi que no hay journal, ni dmesg, ni testigo. Por eso se escribe tambien
 * la marca de ejecucion (ver marcar()).
 *
 * FALLO SEGURO, SIEMPRE. Si no hay ResetSystem, o si vuelve sin apagar, esto
 * devuelve EFI_SUCCESS y systemd-boot sigue con su menu y su entrada por defecto:
 * se pierde el ahorro de ese apagado, no el arranque.
 *
 * FIRMA. Con Secure Boot activado el firmware solo carga imagenes firmadas por
 * una clave que conozca. Esta hay que firmarla (tools/s5-boot-halt lo hace con
 * sbctl si las claves del usuario estan donde se esperan). Sin firmar,
 * systemd-boot no la carga, se queda en el menu y arranca lo de siempre: no rompe
 * nada, pero tampoco ahorra — por eso la instalacion lo comprueba y lo avisa.
 *
 * SE DEJA VER. Antes de apagar escribe en `S5HaltLastRun` (GUID propio) la hora
 * del firmware: un apagado desde el cargador no deja log del kernel, asi que sin
 * esa marca no hay forma de distinguir "la aplicacion se ejecuto" de "el firmware
 * reinicio y nadie se entero". `s5-boot-halt estado` la lee y `armar` la borra,
 * de modo que lo que se lee es de ESTE ensayo.
 */

#include <efi.h>

/* El GUID de systemd para las variables Loader*: el mismo que aparece en
 * /sys/firmware/efi/efivars/LoaderEntryOneShot-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f */
static EFI_GUID loader_guid = {
	0x4a67b082, 0x0a4c, 0x41cf,
	{ 0xb6, 0xc7, 0x44, 0x0b, 0x29, 0xbb, 0x8c, 0x4f }
};

/* GUID propio para la marca de ejecucion. En efivarfs la variable aparece como
 * S5HaltLastRun-8b8c1b5e-2f1a-4b3c-9a7d-512c6e0a3f11 */
static EFI_GUID s5_guid = {
	0x8b8c1b5e, 0x2f1a, 0x4b3c,
	{ 0x9a, 0x7d, 0x51, 0x2c, 0x6e, 0x0a, 0x3f, 0x11 }
};

/*
 * Un Print() propio en vez del de libefi: se llama al servicio de consola de la
 * tabla de sistema, que es lo unico que hace falta. Si no hubiera consola, se
 * calla en vez de caerse — el apagado no depende de poder contar nada.
 */
static void decir(EFI_SYSTEM_TABLE *st, CHAR16 *texto)
{
	if (st && st->ConOut && st->ConOut->OutputString)
		st->ConOut->OutputString(st->ConOut, texto);
}

/* Un EFI_STATUS en hexadecimal: si algo falla, ese numero es la unica pista que
 * queda en pantalla, y "no pude borrar X" sin el codigo obliga a adivinar. */
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
 * MARCA DE EJECUCION. Un apagado desde el cargador no deja NINGUN log del kernel:
 * ni journal, ni dmesg, ni el testigo. Sin algo escrito desde aqui, saber si el
 * ensayo paso depende de la memoria de quien lo hizo, y eso no vale como
 * evidencia. Se deja la hora del firmware en una variable propia; la lee
 * `s5-boot-halt estado` y la borra `armar`, de modo que su contenido habla del
 * ultimo ensayo y no de uno cualquiera.
 *
 * NO ES CRITICO: si esto falla se avisa por consola y el apagado sigue.
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
	/* La RTC de esta maquina va en UTC (timedatectl: RTC time = Universal time),
	 * asi que la hora del firmware se guarda tal cual y con la Z: quien la lea
	 * sabe que es UTC y la traduce. El 2026-10-06 se guardo "05:50:24" para un
	 * apagado de las 13:50 locales, y ese despiste es el que evita la Z. */
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
		decir(st, L"s5-halt: marca de ejecucion en S5HaltLastRun (");
		decir(st, buf);
		decir(st, L")\r\n");
	}
	return rc;
}

EFI_STATUS efi_main(EFI_HANDLE imagen, EFI_SYSTEM_TABLE *st)
{
	EFI_STATUS rc;

	(void)imagen;

	decir(st, L"s5-halt: apagando desde el firmware, sin kernel de por medio...\r\n");

	if (!st || !st->RuntimeServices) {
		decir(st, L"s5-halt: no hay servicios de runtime; vuelvo al menu\r\n");
		return EFI_SUCCESS;
	}

	/*
	 * ANTI-BUCLE, y de paso una medicion. El 2026-10-06, con la entrada
	 * consumida y el apagado hecho, este borrado devolvio error: systemd-boot
	 * ya habia borrado LoaderEntryOneShot al usarla (la variable "es para el
	 * arranque siguiente", y el cargador la consume). O sea que esta llamada es
	 * una segunda barrera, no la unica, y el aviso de antes ("si esto no apaga,
	 * el proximo arranque puede repetirlo") era demasiado alarmante para un
	 * caso normal. Ahora se dice el codigo y lo que significa.
	 */
	rc = st->RuntimeServices->SetVariable(L"LoaderEntryOneShot", &loader_guid,
					      0, 0, NULL);
	if (EFI_ERROR(rc)) {
		decir(st, L"s5-halt: LoaderEntryOneShot ya no estaba (status ");
		decir_status(st, rc);
		decir(st, L"); el cargador la consume al usar la entrada, asi que\r\n");
		decir(st, L"         el arranque siguiente es el normal aunque esto no apague\r\n");
	}

	/* La marca va despues del borrado: asi, si el apagado ocurre, lo que queda
	 * escrito es "la aplicacion llego hasta aqui", no "alguien la armo". */
	rc = marcar(st);
	if (EFI_ERROR(rc))
		decir(st, L"s5-halt: aviso: no pude dejar la marca de ejecucion (no afecta al apagado)\r\n");

	if (!st->RuntimeServices->ResetSystem) {
		decir(st, L"s5-halt: este firmware no ofrece ResetSystem; vuelvo al menu (arranque normal)\r\n");
		return EFI_SUCCESS;
	}

	st->RuntimeServices->ResetSystem(EfiResetShutdown, EFI_SUCCESS, 0, NULL);

	/*
	 * Si se llega aqui, ResetSystem volvio sin apagar. Un arranque normal es
	 * mejor que un cuelgue: se dice y se devuelve el control al cargador.
	 */
	decir(st, L"s5-halt: ResetSystem volvio sin apagar; vuelvo al menu (arranque normal)\r\n");
	return EFI_SUCCESS;
}

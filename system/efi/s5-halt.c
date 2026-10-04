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
 * ANTI-BUCLE, y es lo unico que hace aparte de apagar: borra la variable EFI
 * `LoaderEntryOneShot` ANTES de llamar a ResetSystem. Si el firmware no llegara a
 * apagarse (o ResetSystem volviera), el arranque siguiente es el normal; sin ese
 * borrado, una aplicacion rota y una variable olvidada serian un bucle de
 * arranques que solo se arregla desde otra maquina. El fichero de la entrada se
 * queda en la ESP a proposito —una vez consumida la variable es una entrada mas
 * del menu— y lo barre el uninstall.sh, como ya hace la rama de GRUB con su
 * custom.cfg.
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
 */

#include <efi.h>

/* El GUID de systemd para las variables Loader*: el mismo que aparece en
 * /sys/firmware/efi/efivars/LoaderEntryOneShot-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f */
static EFI_GUID loader_guid = {
	0x4a67b082, 0x0a4c, 0x41cf,
	{ 0xb6, 0xc7, 0x44, 0x0b, 0x29, 0xbb, 0x8c, 0x4f }
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
	 * ANTI-BUCLE. Se borra la variable de un solo uso y se dice si no se pudo:
	 * un testigo que no se lee no sirve de nada, pero uno que miente es peor.
	 */
	rc = st->RuntimeServices->SetVariable(L"LoaderEntryOneShot", &loader_guid,
					      0, 0, NULL);
	if (EFI_ERROR(rc))
		decir(st, L"s5-halt: aviso: no pude borrar LoaderEntryOneShot; si esto no apaga, el proximo arranque puede repetirlo\r\n");

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

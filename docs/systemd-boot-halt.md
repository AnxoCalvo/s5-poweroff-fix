# Apagar desde el firmware en una maquina con `systemd-boot`

Esta es la pieza que le falta al **caso raro** en una maquina sin GRUB. Aqui no hay
medidas nuevas todavia: lo que hay es el mecanismo, sus frenos y lo que falta por probar.
Cuando haya un apagado real, su fila va a `docs/EVIDENCE.md`.

## Por que hace falta

La rama del caso raro de `s5-gpu-politica` (la dGPU no se durmio en 90 s) apaga desde GRUB
con `halt`: en ese arranque **no llega a ejecutarse ningun kernel de Linux**, el firmware
hace su propio S5 con el hardware tal y como lo dejo el POST, y la medida sale limpia
(`grub-halt`, 1,05 W, 2026-08-09).

En una maquina con `systemd-boot` no hay `halt` que valga, y hacerlo desde un kernel vivo
**no es equivalente** — ya esta medido en `docs/EVIDENCE.md`:

| intento desde un kernel vivo | resultado |
|---|---|
| modulo que llama a `ResetSystem` por EFI (`efi-poweroff`) | 19,26 W |
| escritura directa a `PM1a_CNT`, sin `_PTS(5)` ni `device_shutdown()` (`pm1a-acpica`) | 26,56 W |

Lo que salva la medida no es "apagar por el firmware", es que **no haya llegado a arrancar
un kernel**: asi la dGPU no se enciende nunca y no hay riel que cortar.

## Que hace esta pieza

```
system/efi/s5-halt.c        aplicacion EFI minima: borra la variable y ResetSystem(EfiResetShutdown)
system/efi/Makefile         dos vias de compilacion: gnu-efi+objcopy, o clang+lld-link
system/bin/s5-descubre-boot descubre ESP, bootctl, soporte de entrada de un solo uso, efivarfs
system/bin/s5-politica-boot la rama: descubre, arma, verifica y reinicia (la llama la politica)
tools/s5-boot-halt          instalar / armar / abortar / estado (compila, firma e instala en la ESP)
```

`s5-gpu-politica` gana un bloque al principio de su rama del caso raro: si **no hay GRUB
utilizable** (`grub*-reboot` o `grub*-editenv` no estan), prueba esta via antes de seguir con el
camino de GRUB, que no cambia ni una linea. Si la via de systemd-boot tampoco puede, lo registra y
el apagado sigue su curso normal. `uninstall.sh` barre la entrada, la aplicacion y el armado.

La aplicacion **no usa la libreria de gnu-efi** (solo sus cabeceras): son treinta lineas y asi el
mismo fuente se compila por las dos vias, que no estan disponibles en las mismas maquinas:

| via | cuando |
|---|---|
| `make` (gnu-efi + `objcopy --target=efi-app-x86_64`) | lo normal, y lo que trae Fedora |
| `make clang` (`clang --target=x86_64-pc-win32-coff` + `lld-link /subsystem:efi_application`) | cuando el binutils de la distribucion no trae el objetivo EFI (`objcopy --info | grep efi-app-x86_64` no devuelve nada) |

`make check` dice cual esta disponible y, si no hay ninguna, como instalarla.

* La **entrada es permanente** (`$ESP/EFI/s5-halt/s5-halt.efi` +
  `$ESP/loader/entries/s5-halt.conf`, tipo `efi`). Sin la variable de un solo uso es una
  entrada mas del menu: no se dispara sola nunca.
* **Armar es escribir una variable EFI** (`bootctl set-oneshot s5-halt`). No hay que montar
  `/boot` ni escribir en la ESP durante la ventana de apagado, que es justo el problema que
  tiene la rama de GRUB (los montajes mueren antes de `shutdown.target`, y por eso ella
  monta `/boot` a mano). Aqui la ESP solo se toca al instalar.
* **Anti-bucle, con dos barreras**: la primera es el propio cargador, que consume
  `LoaderEntryOneShot` al usar la entrada —es "para el arranque siguiente", y systemd-boot la
  borra—; la segunda es la aplicacion, que la borra antes de apagar. Medido el 2026-10-06: con
  el apagado ya hecho, el borrado de la aplicacion devolvio error porque systemd-boot se la
  habia llevado antes, y no hubo bucle. El fichero de la entrada se queda a proposito y lo
  barre la limpieza del arranque, como ya hace la rama de GRUB con su `custom.cfg`.
* **Fallo seguro, siempre**: sin `ResetSystem`, o si vuelve sin apagar, la aplicacion
  devuelve `EFI_SUCCESS` y `systemd-boot` sigue con su menu y su entrada por defecto. Se
  pierde el ahorro de ese apagado, no el arranque. Lo mismo con el descubridor: lo que falte
  se dice con nombre y apellido y la orden no se lleva a cabo.
* **Se deja ver**: antes de apagar escribe la hora del firmware (**en UTC, con la `Z`**: la RTC
  de esta maquina va en UTC, y la primera version guardaba `05:50:24` para un apagado de las
  `13:50` locales) en una variable propia (`S5HaltLastRun`). Hace falta porque un apagado desde
  el cargador **no deja log del kernel** —ni journal, ni `dmesg`, ni el testigo—: sin esa
  marca, distinguir "la aplicacion se ejecuto" de "el firmware reinicio y nadie se entero"
  depende de la memoria de quien hizo el ensayo, y eso no es evidencia. `s5-boot-halt estado`
  la lee y la traduce a hora local (`ultimo apagado : SI, por firmware, el 2026-10-06
  13:50:24 CST`), `armar` la borra para que lo que se lea sea de ese ensayo, y `uninstall.sh`
  se la lleva. La aplicacion tambien imprime el `EFI_STATUS` en hexadecimal cuando algo falla:
  ese numero en pantalla es la unica pista que queda. La consola de un ensayo real, en
  [`docs/img/rehearsal-2026-10-06.jpg`](img/rehearsal-2026-10-06.jpg), es este texto y nada
  mas: no hay kernel detras que lo cuente.
* **No toca nada que ya exista**: anade una entrada nueva y una variable EFI. No cambia el
  cargador, ni el kernel, ni las entradas previas. `uninstall.sh` y `s5-boot-halt abortar`
  lo dejan como estaba.

## Secure Boot

Con Secure Boot activado el firmware solo carga imagenes firmadas por una clave que conozca.
La aplicacion la firma **el usuario con sus claves** (`sbctl sign` o `sbsign`); este proyecto
no instala claves ni toca la base de datos. Sin firmar, `systemd-boot` no la carga, se vuelve
al menu y arranca lo de siempre: no rompe nada, pero tampoco ahorra. Por eso `instalar`
comprueba la firma (`sbctl verify`) y se niega a seguir si no puede firmarla.

## Que esta probado y que no (2026-10-04)

* **Probado**: el descubridor y las ramas de fallo de todo lo demas, en una `8E35` con
  `systemd-boot` 262 (ESP en `/boot`, entrada de un solo uso soportada, Secure Boot activado).
  `estado` informa de todo, `make check` dice que via de compilacion hay, y tanto
  `s5-politica-boot` como la herramienta se niegan a seguir sin la aplicacion instalada
  (probado: registran el motivo y devuelven 1, sin tocar la ESP ni efivarfs).
* **Probado**: la compilacion de la aplicacion por la via de clang + lld-link, en esa misma
  maquina: sale un PE32+ de 3 KB, subsistema `EFI application` (0x0a) y con directorio de
  reubicaciones `.reloc`. La via de gnu-efi **no** se puede probar ahi porque su `objcopy` no
  trae el objetivo `efi-app-x86_64` — que es justo por lo que existe la segunda via.
* **No probado todavia**: firmar, instalar, armar y apagar. Hace falta la clave de Secure Boot
  del usuario (`sbctl`) y un apagado real; esta seccion se actualiza con la medida del S5, y su
  fila va a `docs/EVIDENCE.md`.
* **No probado en otras maquinas**: el reparto de la ESP (`/boot`, `/efi`) es el de esta; el
  descubridor pregunta a `bootctl` y prueba varios, pero solo se ha visto en una.
* **No probado**: que firmware y cargador de otras marcas acepten la entrada `efi` y el borrado
  de la variable desde la aplicacion. Aqui la entrada `efi` es la que usa el propio sistema
  para arrancar, y borrar variables desde una aplicacion es lo que hace cualquier instalador
  de UEFI, pero no se ha ejercitado.

## Como se probaria

```bash
# 1. la via de compilacion que tenga esta maquina (lo dice ella misma)
make -C system/efi check
# 2. compilar, firmar (Secure Boot) e instalar en la ESP
sudo tools/s5-boot-halt instalar
# 3. que todo este en su sitio y sin armar
sudo tools/s5-boot-halt estado
# 4. armar y apagar
sudo tools/s5-boot-halt armar        # o: sudo system/bin/s5-politica-boot --armar-solo
```

Lo que se espera: el firmware apaga sin arrancar nada, la maquina queda fria y el S5 sale en el
entorno de `grub-halt` (1,05 W en 45 min) y no en el de los ~19 W. Si sale mal, la señal es
clara: arranca el menu y sigue el arranque normal, o arranca `s5-halt.efi` y vuelve al menu —
en los dos casos queda testigo en la consola y en el registro de la politica.

**Desarmar, si te arrepientes antes de apagar**: `sudo tools/s5-boot-halt abortar`. Ojo con el
detalle que costo un rato: las variables EFI son **inmutables** (`----i----` en `lsattr`), asi
que `rm` a secas falla con `EPERM`; hay que quitarles el atributo antes (`chattr -i`), que es lo
que hace `bootctl` por dentro y lo que hace ahora la herramienta.

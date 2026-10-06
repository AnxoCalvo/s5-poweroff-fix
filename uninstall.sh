#!/bin/bash
# uninstall.sh — retira s5-poweroff-fix y deja la maquina como estaba.
#
# ORDEN IMPORTA: primero se desactivan las unidades y se retira el hook de
# apagado, y solo despues se borran los scripts. Al reves quedaria un hook
# apuntando a un script que ya no existe, justo en la fase del apagado donde
# menos se mira.
#
# NO borra los logs (/var/log/s5-*.log): son medidas de consumo que costaron
# noches enteras de apagado y no se pueden rehacer sin repetirlas. Se dice donde
# estan y se deja la decision a quien desinstala.
#
#   sudo ./uninstall.sh [--purge]     --purge borra tambien estado y logs

set -u
PURGE=0
[ "${1:-}" = --purge ] && PURGE=1
[ "$(id -u)" = 0 ] || { echo "hay que ejecutarlo como root (sudo)" >&2; exit 1; }

# TODAS LAS RUTAS SON OVERRIDABLES, Y SOLO PARA ENSAYAR (regla 22). Este script
# borra ficheros, desarma el gestor de arranque y toca el RTC: es justo el que no
# se puede publicar sin ensayar, y es justo el que no se puede ensayar de verdad
# contra las rutas reales. Con esto, tests/ensayo-ramas.sh lo corre entero contra
# un /boot, un /var y un /sys de mentira. Ojo con el purgado de mas abajo: sin
# LOGDIR parametrizado, un ensayo se llevaria por delante las medidas de verdad.
BIN=${BIN:-/usr/local/bin}
HOOKS=${HOOKS:-/usr/lib/systemd/system-shutdown}
UNITS=${UNITS:-/etc/systemd/system}
LOGROTATE=${LOGROTATE:-/etc/logrotate.d}
STATEDIR=${STATEDIR:-/var/lib/s5-test}
ENERGYDIR=${ENERGYDIR:-/var/lib/s5-energy}
LOGDIR=${LOGDIR:-/var/log}
WAKEALARM=${WAKEALARM:-/sys/class/rtc/rtc0/wakealarm}
# los dos sabores de GRUB, en una variable para poder apuntarlos a un /boot falso
GRUBCFGS=${GRUBCFGS:-"/boot/grub2/custom.cfg /boot/grub/custom.cfg"}
S5_CONF=${S5_CONF:-/etc/s5-poweroff-fix.conf}
# shellcheck source=/dev/null
[ -r "$S5_CONF" ] && . "$S5_CONF"   # por S5_BLS_DIR y S5_GRUB_DIR
BLS_DIR=${S5_BLS_DIR:-/boot/loader/entries}
BLS_BAK=${BLS_BAK:-$STATEDIR/bls-backup}
# Y EL SITIO QUE FIJE LA CONFIGURACION, que puede no ser ninguno de los dos de
# arriba. Quien ESCRIBE la entrada (s5-gpu-politica, s5-grub-halt) usa el
# $GRUB_CUSTOM que descubre s5-descubre-grub, y ese SI obedece a S5_GRUB_DIR;
# aqui la lista de sitios donde barrer estaba clavada. Con la perilla puesta a
# otro directorio —esta documentada en s5-poweroff-fix.conf.example— el
# custom.cfg de un solo uso no lo barria NADIE: ni el arranque siguiente ni esta
# desinstalacion, y quedaba una entrada huerfana en el menu para siempre. Es la
# misma constante clavada que este repo lleva cuatro pasadas quitando, esta vez
# en el unico script que existe para dejar la maquina como estaba.
#
# Va DESPUES del `.` de la configuracion, que es de donde sale la variable, y se
# ANADE en vez de sustituir: barrer de mas en una desinstalacion no duele, y si
# S5_GRUB_DIR resulta ser uno de los dos estandar el segundo pase no encuentra
# ya nada. El `:-` es por el `set -u` de arriba.
[ -n "${S5_GRUB_DIR:-}" ] && GRUBCFGS="$GRUBCFGS $S5_GRUB_DIR/custom.cfg"

echo "== desactivando unidades"
# LAS DOS ULTIMAS NO LAS INSTALA install.sh: las crean y activan en caliente
# s5-test y s5-grub-halt. Si no se desactivan aqui, el `rm -f "$UNITS"/s5-*.service`
# de mas abajo se lleva el fichero pero NO el enlace de multi-user.target.wants,
# y systemd se queja del symlink roto para siempre.
for u in s5-mitigacion-check s5-gpu-politica s5-gpu-politica-cleanup s5-energy-log \
         s5-queue-next s5-test-report s5-test-run s5-grub-halt-cleanup; do
    systemctl disable --now "$u.service" >/dev/null 2>&1 && echo "   $u"
done

echo "== retirando hooks de apagado"
for f in 99y-s5-gpu-pmrt.shutdown 99-s5-pci-state.shutdown; do
    [ -e "$HOOKS/$f" ] && { rm -f "$HOOKS/$f"; echo "   $f"; }
done

echo "== retirando unidades y scripts"
rm -f "$UNITS"/s5-*.service
rm -f "$BIN"/s5-*
rm -f "$LOGROTATE"/s5-poweroff-fix
systemctl daemon-reload

# Residuos que, si se quedan, actuarian en el proximo arranque: una entrada de
# GRUB de un solo uso ya armada apagaria el equipo nada mas encenderlo.
#
# HAY DOS COSAS QUE ARMAN GRUB, Y AQUI SOLO SE BARRIA UNA. La politica escribe
# `# s5-gpu-politica` y next_entry=s5politica; s5-grub-halt (--tools) escribe su
# propia marca y next_entry=s5halt. Como unos pasos mas arriba se borran el
# binario Y su unidad de limpieza, si alguien desinstalaba con una prueba armada
# no quedaba NADIE que pudiera barrerla: el equipo se apagaba solo nada mas
# encenderlo. Es exactamente el accidente que este bloque existe para evitar, y
# se le escapaba por la rama de las herramientas.
echo "== barriendo residuos de la rama de systemd-boot"
# La entrada y la aplicacion viven en la ESP; el armado, en una variable EFI. Se
# pregunta a bootctl donde esta la ESP y, si no esta, se prueba la lista de
# siempre: es una desinstalacion y barrer de mas no duele.
esp_list="${S5_ESP_DIRS:-}"
if command -v bootctl >/dev/null 2>&1; then
    p=$(bootctl --print-esp-path 2>/dev/null) && esp_list="$p ${esp_list:-/boot /efi /boot/efi}"
fi
[ -n "$esp_list" ] || esp_list="/boot /efi /boot/efi"
for esp in $esp_list; do
    [ -d "$esp" ] || continue
    if [ -e "$esp/EFI/s5-halt/s5-halt.efi" ] || [ -e "$esp/loader/entries/s5-halt.conf" ]; then
        rm -f "$esp/loader/entries/s5-halt.conf" "$esp/EFI/s5-halt/s5-halt.efi"
        rmdir "$esp/EFI/s5-halt" 2>/dev/null || true
        echo "   entrada y aplicacion retiradas de $esp"
    fi
done
# Y si quedo ARMADA, desarmarla: si no, el proximo apagado reiniciaria para
# arrancar una aplicacion que ya no esta (seguiria el menu, pero es un POST
# regalado y un susto). OJO: las variables EFI son INMUTABLES (----i---- en
# lsattr) y `rm` a secas falla con EPERM; hay que quitarles el atributo antes,
# que es lo que hace bootctl por dentro.
for v in /sys/firmware/efi/efivars/LoaderEntryOneShot-*; do
    [ -e "$v" ] || continue
    # Los 4 primeros bytes son los atributos de la variable en efivarfs, no su
    # contenido: sin saltarlos el valor leido es "\x07s5-halt" y esta condicion no
    # se cumple nunca, asi que el desarmado se saltaba en silencio.
    [ "$(tail -c +5 <"$v" 2>/dev/null | tr -d '\0')" = s5-halt ] || continue
    chattr -i "$v" 2>/dev/null || true
    if rm -f "$v" 2>/dev/null; then
        echo "   armado de un solo uso desarmado (apuntaba a s5-halt)"
    else
        echo "   !! no pude desarmar $v: quitale el atributo con 'chattr -i' y borralo" >&2
    fi
done

echo "== barriendo residuos de la rama de GRUB"
# el sabor de GRUB: puede que el descubridor ya no este (se borra arriba), asi
# que se prueban los dos a pelo. Es una desinstalacion: barrer de mas no duele.
# shellcheck disable=SC2086  # GRUBCFGS es una lista de rutas, se quiere partir
for c in $GRUBCFGS; do
    [ -e "$c" ] && grep -qE '# s5-gpu-politica|# Generado por s5-grub-halt' "$c" 2>/dev/null && {
        rm -f "$c"; echo "   $c retirado"; }
done
for e in grub2-editenv grub-editenv; do
    command -v "$e" >/dev/null 2>&1 || continue
    "$e" - list 2>/dev/null | grep -qE '^next_entry=(s5politica|s5halt)$' && {
        "$e" - unset next_entry; echo "   next_entry desarmado ($e)"; }
done
# Y el despertador que arma s5-grub-halt: si se queda puesto, enciende el equipo
# solo a una hora cualquiera. Escribir 0 lo desarma; si no existe, no pasa nada.
if [ -w "$WAKEALARM" ]; then
    read -r _al < "$WAKEALARM" 2>/dev/null || _al=0
    [ "${_al:-0}" != 0 ] && { echo 0 > "$WAKEALARM" 2>/dev/null && \
        echo "   despertador RTC desarmado (estaba puesto)"; }
fi

# Y LAS ENTRADAS DE ARRANQUE PARCHEADAS, que es el mismo accidente que el de
# GRUB pero permanente. `s5-test -a` respalda $BLS_DIR/*.conf en $BLS_BAK y le
# anade los args de kernel a TODAS las entradas; quien las restaura es el propio
# s5-test en el arranque siguiente. Solo que aqui arriba se ha desactivado
# s5-test-run y se ha borrado el binario, asi que no queda nadie que pueda
# hacerlo: quien desinstalase con una prueba de args armada se quedaba con, por
# ejemplo, `rd.driver.blacklist=amdgpu` clavado en todos los arranques. Y con
# --purge se borraba ademas el respaldo, o sea sin vuelta atras.
if [ -d "$BLS_BAK" ] && ls "$BLS_BAK"/*.conf >/dev/null 2>&1; then
    if [ -d "$BLS_DIR" ] && cp -a "$BLS_BAK"/*.conf "$BLS_DIR"/ 2>/dev/null; then
        rm -rf "$BLS_BAK"
        echo "   entradas de arranque restauradas ($BLS_DIR): habia una prueba de args armada"
    else
        # No se puede restaurar y el respaldo es lo unico que queda: NO se borra
        # ni con --purge, y se dice como hacerlo a mano.
        PURGE=0
        echo "   !! HABIA UNA PRUEBA DE ARGS ARMADA y no he podido restaurar $BLS_DIR" >&2
        echo "   !! tus entradas de arranque siguen parcheadas. El respaldo esta en:" >&2
        echo "   !!   $BLS_BAK" >&2
        echo "   !! restauralo con: sudo cp -a $BLS_BAK/*.conf $BLS_DIR/" >&2
        echo "   !! (no purgo $STATEDIR para no llevarme ese respaldo)" >&2
    fi
fi

if [ "$PURGE" = 1 ]; then
    # /var/lib/s5-energy lo crea s5-energy-log y no lo borraba nadie; y los
    # rotados (s5-energy.log.1.gz...) no los pillaba el glob, con lo que "estado
    # y logs borrados" no era del todo cierto.
    rm -rf "$STATEDIR" "$ENERGYDIR" "$LOGDIR"/s5-*.log "$LOGDIR"/s5-*.log.*
    echo "== purgado: estado y logs borrados (incluidos los rotados)"
else
    echo
    echo "Se conservan (borralos a mano si quieres, o usa --purge):"
    echo "   $LOGDIR/s5-energy.log       <- las medidas de consumo; esto es la evidencia"
    echo "   $LOGDIR/s5-shutdown-pci.log"
    echo "   $STATEDIR/  $ENERGYDIR/"
    echo "   $S5_CONF    <- tu configuracion; ni --purge la toca"
fi

echo
echo "El modulo del kernel va aparte:  sudo dnf remove akmod-s5-pmrt-arm"

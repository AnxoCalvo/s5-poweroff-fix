#!/bin/bash
# install.sh — instala s5-poweroff-fix desde este repo a las rutas del sistema.
#
# POR QUE HAY UN INSTALADOR Y NO SE TRABAJA "EN SU SITIO": las piezas viven
# donde el sistema EXIGE que vivan (systemd solo ejecuta hooks de apagado de
# /usr/lib/systemd/system-shutdown, akmods solo reconstruye desde
# /usr/src/akmods), asi que no se pueden tener dentro de un repo. Este script
# es lo que mantiene el repo como fuente de la verdad.
#
#   sudo ./install.sh            instala el arreglo (+ herramientas con --tools)
#   sudo ./install.sh --check    solo comprueba: no escribe nada
#   sudo ./install.sh --tools    ademas, las herramientas de medida
#
# El modulo del kernel NO lo instala este script: va por akmod para sobrevivir a
# las actualizaciones de kernel, y eso es `dnf install` de un rpm. Ver kmod/.

set -u
cd "$(dirname "$(readlink -f "$0")")" || { echo "install.sh: no pude entrar en mi propio directorio" >&2; exit 1; }

CHECK=0; TOOLS=0
for a in "$@"; do
    case "$a" in
        --check) CHECK=1 ;;
        --tools) TOOLS=1 ;;
        -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
        *) echo "opcion desconocida: $a" >&2; exit 2 ;;
    esac
done

BIN=/usr/local/bin
HOOKS=/usr/lib/systemd/system-shutdown
UNITS=/etc/systemd/system
LOGROTATE=/etc/logrotate.d

die() { echo "install.sh: $*" >&2; exit 1; }
paso() { printf '\n== %s\n' "$*"; }
pon() {  # pon <modo> <origen> <destino>
    if [ "$CHECK" = 1 ]; then printf '   [seco] %s -> %s\n' "$2" "$3"; return; fi
    install -D -m "$1" -o root -g root "$2" "$3" || die "no pude instalar $3"
    printf '   %s\n' "$3"
}

[ "$CHECK" = 1 ] || [ "$(id -u)" = 0 ] || die "hay que ejecutarlo como root (sudo), o usar --check"

# --- 1. comprobar la maquina ANTES de tocar nada ----------------------------
# Instalar a ciegas es como se blinda el dispositivo equivocado. El descubridor
# se ejecuta primero y se ensena lo que ha encontrado.
paso "Que dispositivos se van a blindar en ESTA maquina"
if ! bash system/bin/s5-descubre-dgpu; then
    echo
    echo "   No hay GPU discreta del vendor buscado."
    echo "   Si tu discreta no es NVIDIA, o la topologia es rara, fija los valores"
    echo "   a mano en /etc/s5-poweroff-fix.conf (ver s5-poweroff-fix.conf.example)"
    echo "   y vuelve a lanzar esto. Sin eso, el arreglo no hace nada."
    die "abortado: no hay nada que blindar"
fi

paso "Requisitos"
[ -d /sys/firmware/efi ] || echo "   AVISO: esto no ha arrancado por EFI; la rama de GRUB (halt) puede comportarse distinto"
[ -d /sys/firmware/acpi/fpdt/boot ] || echo "   AVISO: sin ACPI FPDT, el verificador no podra confirmar que GRUB apago (se abstiene)"
grep -q ' /boot ' /etc/fstab 2>/dev/null || echo "   AVISO: /boot no aparece en /etc/fstab; la rama de GRUB no podra montarlo y abortara (seguro)"
echo "   ok"

# EL SABOR DE GRUB, ENSENADO igual que la dGPU: no se adivina, se dice lo que se
# ha encontrado en ESTA maquina. Si falta algo NO se aborta — a diferencia del
# descubridor de la dGPU, sin el cual no hay arreglo, aqui solo se pierde la
# rama de GRUB (el salvavidas del caso raro), que se autodesactiva sola.
paso "Sabor de GRUB en esta maquina"
salida_grub="$(bash system/bin/s5-descubre-grub 2>&1)"; rc_grub=$?
printf '%s\n' "$salida_grub" | sed 's/^/   /'
# EL AVISO SOLO SI VALE ALGO. Sin root no se puede leer /boot/grub2 (drwx------),
# asi que un `--check` de usuario da "no encontrado" por permisos y no por falta
# de GRUB: gritar ahi seria el aviso-que-no-significa-nada de la regla 27. El
# propio descubridor ya explica arriba que hay que repetirlo con sudo.
if [ "$rc_grub" != 0 ] && [ "$(id -u)" = 0 ]; then
    echo "   AVISO: la rama de GRUB se autodesactiva (falla segura: apaga normal). El resto del arreglo NO depende de ella."
fi

# THE OTHER RARE-CASE ROUTE, the systemd-boot one. It is shown for the same reason
# as the GRUB one — it is not guessed, what is there is stated — and with the same doctrine:
# that it is missing does NOT abort the installation, it only leaves the rare case without a lifeline.
# NOTE: the discovery script succeeding does NOT mean the route is ready; the
# EFI application has to be built, signed (if Secure Boot is on) and installed
# separately with `s5-boot-halt instalar`, and that is why that is stated too.
paso "systemd-boot route for the rare case"
salida_boot="$(bash system/bin/s5-descubre-boot 2>&1)"; rc_boot=$?
printf '%s\n' "$salida_boot" | sed 's/^/   /'
if [ "${S5_BOOT_RUTA:-app}" = builtin ]; then
    echo "   builtin ROUTE: it powers off with the boot loader's built-in entry ('Power Off The System')."
    echo "         There is no EFI application to build, sign or install, and arming only"
    echo "         writes an EFI variable: the ESP is not touched in the poweroff window."
    echo "         Requires 'auto-poweroff yes' in loader.conf (systemd 255+)."
elif [ "$rc_boot" = 0 ] && [ ! -e /boot/EFI/s5-halt/s5-halt.efi ]; then
    echo "   NOTE: the EFI application is missing; the rare case will stay without a lifeline until"
    echo "         'sudo s5-boot-halt instalar' (needs gnu-efi and, with Secure Boot, signing it)."
fi

# --- 2. las piezas del arreglo ----------------------------------------------
paso "Descubridor de dispositivos"
pon 0755 system/bin/s5-descubre-dgpu "$BIN/s5-descubre-dgpu"

paso "Hooks de apagado"
for f in system/shutdown/*.shutdown; do pon 0755 "$f" "$HOOKS/$(basename "$f")"; done

paso "Scripts"
for f in system/bin/*; do
    [ "$(basename "$f")" = s5-descubre-dgpu ] && continue
    pon 0755 "$f" "$BIN/$(basename "$f")"
done

paso "Unidades systemd"
for f in system/systemd/*.service; do pon 0644 "$f" "$UNITS/$(basename "$f")"; done

paso "Rotacion de logs"
pon 0644 system/logrotate/s5-poweroff-fix "$LOGROTATE/s5-poweroff-fix"

if [ "$TOOLS" = 1 ]; then
    paso "Herramientas de medida y diagnostico"
    for f in tools/*; do
        case "$f" in
            *.service) pon 0644 "$f" "$UNITS/$(basename "$f")" ;;
            *)         pon 0755 "$f" "$BIN/$(basename "$f")" ;;
        esac
    done
fi

if [ "$CHECK" = 1 ]; then
    paso "ENSAYO EN SECO: no se ha escrito nada"
    exit 0
fi

# --- 3. activar --------------------------------------------------------------
paso "Activando"
mkdir -p /var/lib/s5-test
restorecon -F "$BIN"/s5-* "$HOOKS"/*.shutdown "$UNITS"/s5-*.service 2>/dev/null   # SELinux: bin_t / systemd_unit_file_t
systemctl daemon-reload || die "daemon-reload fallo"
for u in s5-energy-log s5-gpu-politica s5-gpu-politica-cleanup s5-mitigacion-check; do
    systemctl enable "$u.service" >/dev/null 2>&1 && printf '   %s activada\n' "$u"
done
# EL MEDIDOR HAY QUE ARRANCARLO AHORA, no solo activarlo. s5-energy-log.service es
# Type=oneshot con RemainAfterExit y la medida del apagado vive en su ExecStop, y
# systemd solo ejecuta el ExecStop de una unidad ACTIVA. Con `enable` a secas la
# unidad no se activaba hasta el arranque siguiente, asi que si instalabas y
# apagabas, ese apagado NO se media: ni linea APAGADO ni delta al arrancar. Y es
# justo el apagado del que habla el mensaje del final ("El primer apagado real es
# el que da el numero").
# SOLO esta: s5-gpu-politica es WantedBy=poweroff.target y arrancarla ahora
# significaria ejecutar la politica de apagado con el equipo encendido.
systemctl start s5-energy-log.service >/dev/null 2>&1 \
    && printf '   %s en marcha (asi el PROXIMO apagado ya se mide)\n' s5-energy-log

# EL AVISO DEL MODULO SOLO SI DE VERDAD FALTA. Antes se imprimia siempre, asi que
# una instalacion perfecta —con el akmod ya puesto y el .ko construido para este
# kernel— terminaba gritando "FALTA EL MODULO". Un aviso que salta cuando no pasa
# nada es la forma mas rapida de que nadie lea los que si importan (regla 27).
if ls /lib/modules/"$(uname -r)"/extra/s5-pmrt-arm/s5_pmrt_arm.ko* >/dev/null 2>&1; then
    cat <<EOF

== El modulo del kernel ya esta
   /lib/modules/$(uname -r)/extra/s5-pmrt-arm/  (por akmod: se recompila solo)
EOF
else
    cat <<'EOF'

== FALTA EL MODULO DEL KERNEL
El blindaje lo hace un modulo minusculo (s5_pmrt_arm). Va por akmod A PROPOSITO:
asi akmods lo recompila solo en cada actualizacion de kernel. Sin el, todo lo
demas corre pero NO ahorra nada.

    cd kmod/ && cat REBUILDING.md
EOF
fi

cat <<'EOF'

== COMPROBAR
    sudo s5-mitigacion-check

Tiene que decir TODO EN ORDEN. Si el modulo aun no esta, lo dira ahi.
El primer apagado real es el que da el numero: `s5-mitigacion-check` lo lee del
arranque siguiente.
EOF

#!/bin/bash
# Ensaya las ramas de `s5-mitigacion-check` con fixtures, sin tocar nada del
# sistema. Regla del proyecto: se ensayan TODAS las ramas, tambien las que NO
# deben sonar, y sobre todo la que SI debe sonar — un verificador que solo se ha
# probado en verde no verifica nada.
#
#     ./tests/ensayo-ramas.sh
#
# QUE CUBRE
#   9ter  ¿apago GRUB de verdad? (por los tiempos de ACPI FPDT)
#   10    la energia: cuando el umbral de vatios aplica y cuando hay que abstenerse
#
# POR QUE LOS FIXTURES SE GENERAN Y NO ESTAN GUARDADOS: las dos secciones
# correlacionan POR FECHA el bloque de la politica con el resumen del log de
# energia y con el fin del journal del arranque anterior. Unas fechas escritas a
# mano solo valdrian en la maquina donde se escribieron. Aqui se derivan del
# reloj —del journal vivo si lo hay— asi que el ensayo vale en cualquier maquina
# y de paso comprueba que la correlacion aguanta fechas que nunca ha visto.
#
# ES HERMETICO: no necesita nada de esta maquina, ni siquiera que tenga journal
# del arranque anterior (ver "el ancla" mas abajo). La unica rama que depende del
# entorno es la ultima, que comprueba la invocacion real de journalctl.
set -u

# CINTURON DE SEGURIDAD: este ensayo no puede tumbar la maquina, pase lo que
# pase. El 2026-08-14 una tanda de corridas solapadas dejo miles de procesos
# sueltos y el kernel acabo matando por OOM cosas que no tenian nada que ver
# (una sesion de trabajo entera). Nunca se reprodujo, asi que no hay una linea
# concreta que arreglar — pero un script de PRUEBAS que puede llevarse por
# delante el escritorio de quien lo ejecuta es inaceptable se reproduzca o no,
# y el arreglo no depende de saber la causa.
#
# RLIMIT_NPROC es POR USUARIO, no por arbol de procesos, asi que no vale un
# numero fijo: hay que contar lo que ya hay y dejar margen.
#
# Y CUENTA HILOS, NO PROCESOS. Aqui se metio la pata al escribir esto: se conto
# con `ps -u` (101 procesos) cuando el kernel cuenta tareas (603 hilos en el
# mismo instante — un escritorio moderno va lleno). El limite quedaba por DEBAJO
# del uso real y el ensayo no arrancaba, con un `fork: Recurso no disponible`
# que no explica nada. De ahi el `-L`.
#
# Margen de 500 y no de 50: los hilos de un escritorio suben y bajan solos
# —abrir el navegador son cientos— y un ensayo que falla porque abriste una
# pestaña seria peor que el problema que evita. Con un pico normal de 10, 500 de
# margen no se roza nunca, y una fuga se queda en 500 tareas en vez de las 4352
# que provocaron el OOM. Solo afecta a este shell y a sus hijos.
_tareas=$(ps -u "$(id -u)" -L --no-headers 2>/dev/null | wc -l)
[ "${_tareas:-0}" -gt 0 ] && ulimit -S -u $((_tareas + 500)) 2>/dev/null
unset _tareas

D="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
CHK="${CHK:-$D/../system/bin/s5-mitigacion-check}"
[ -r "$CHK" ] || { echo "no encuentro el verificador en $CHK" >&2; exit 2; }

# UNA SOLA CORRIDA A LA VEZ. $F es fijo y lo primero que se hace con el es un
# `rm -rf`: dos ensayos simultaneos se borran las fixtures el uno al otro y el
# que pierde la carrera saca [MAL] en ramas que estan perfectamente bien
# (comprobado: de dos corridas a la vez, una acaba con rc=1). Lo grave no es que
# falle, es lo que PARECE — un [MAL] que no viene de ninguna rama rota manda a
# quien lo lea a buscar un problema que no existe, que es el aviso sin
# significado de la regla 27 en su peor version: dentro del propio ensayo.
#
# flock y no un cerrojo de fichero hecho a mano: este script se queda a medias
# a menudo (Ctrl-C, un timeout, un OOM), y un cerrojo de los de crear-fichero se
# quedaria puesto para siempre obligando a borrarlo a mano. El del kernel lo
# suelta el propio final del proceso, muera como muera. Si no hay flock no se
# bloquea el ensayo por eso: se avisa y se sigue.
LOCK="${TMPDIR:-/tmp}/s5-ensayo-ramas-$UID.lock"
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK" || { echo "ensayo-ramas: no pude abrir el cerrojo $LOCK" >&2; exit 2; }
    flock -n 9 || {
        echo "ensayo-ramas: ya hay otra corrida en marcha; las dos usan $D/fixtures" >&2
        echo "              y se pisarian. Espera a que acabe. Aborto sin tocar nada." >&2
        exit 2; }
else
    echo "ensayo-ramas: sin flock, no puedo impedir dos corridas a la vez (no lances otra)" >&2
fi

F="$D/fixtures"; rm -rf "$F"; mkdir -p "$F/bin"

# --- el ancla: fin del journal del arranque anterior -------------------------
# EL ANCLA TAMBIEN ES UN FIXTURE, y esto es lo ultimo que le quedaba de local a
# este ensayo. §9ter reconstruye si GRUB apago de verdad tomando como origen el
# FIN DEL JOURNAL DEL ARRANQUE ANTERIOR, asi que las tres ramas que AFIRMAN o
# AVISAN solo se podian ensayar en una maquina que tuviera arranque anterior:
# ni en un contenedor recien hecho, ni con el journal en volatil, ni tras un
# `journalctl --vacuum-*` (paso el 2026-08-13: un vacuum depurando otra cosa
# dejo el journal con un solo arranque y 4 ramas sin poder ensayarse).
#
# Se sintetiza y se le da al verificador por un `journalctl` de mentira en el
# PATH — la misma tecnica que ya usaba la rama de "sin journal", solo que al
# reves. Ademas de hacer el ensayo hermetico quita una fragilidad: antes el
# script y el verificador leian el journal en INSTANTES DISTINTOS, con lo que
# nada garantizaba que vieran la misma ancla.
#
# Se sigue prefiriendo el ancla de verdad cuando la hay: son fechas que el
# ensayo no ha visto nunca, y esa es la gracia de derivar los fixtures.
FIN="$(journalctl -b -1 -n1 -o short-unix --no-pager 2>/dev/null | awk 'END{printf "%d", $1}')"
JOURNAL_REAL=1
if [ -z "$FIN" ] || [ "$FIN" = 0 ]; then
    JOURNAL_REAL=0
    FIN=$(( $(date +%s) - 14400 ))   # un apagado plausible: hace 4 h
fi
f() { date -d "@$1" '+%F %T'; }   # epoch -> el formato de los logs

# El ancla de mentira. `short-unix` pone el epoch en el primer campo, que es lo
# unico que miran el verificador y este script (`awk '{print $1}'`).
# HEREDOC SIN COMILLAS: $FIN tiene que expandirse aqui dentro.
mkdir -p "$F/bin-ancla"
cat > "$F/bin-ancla/journalctl" <<EOF
#!/bin/sh
echo "$FIN.000000 fedora systemd-journald[820]: Journal stopped"
EOF
chmod +x "$F/bin-ancla/journalctl"
ANCLA=(PATH="$F/bin-ancla:$PATH")

POL_TS="$(f $((FIN - 92)))"       # la politica entra ~92 s antes de que muera el journal
APAG_TS="$(f $((FIN - 94)))"      # s5-energy-log escribe su linea 2 s antes que ella
VIEJO_TS="$(f $((FIN - 950000)))" # el mismo desvio, pero de hace 11 dias
POST_TS="$(f $((FIN + 10000)))"   # un apagado POSTERIOR al desvio

# --- fixtures de $PCILOG ----------------------------------------------------
# EL BLOQUE DEL HOOK. Lleva el dmesg del modulo porque de ahi saca §9 CUANTOS
# dispositivos habia que blindar. ES UN PARAMETRO, no un adorno, y por la misma
# razon que la duracion de la ventana en mk_elog: mientras aqui estuvo cableado
# `disable=3 shutdown_anulados=2`, el ensayo repetia el mismo literal que el
# verificador tenia clavado y por eso no pudo cazar que ese literal era la
# topologia de UNA maquina. Una discreta sin audio HDMI da 2 y 1, y eso daba
# FALLO, mitigacion-ROTA y `wall` en cada arranque de una maquina sana.
PMRT_DEVS3='0000:00:01.1,0000:01:00.0,0000:01:00.1'
pmrt_ok() {   # pmrt_ok <fecha> [devs] [disable] [anulados] [linea de pcieport]
    # `${2-...}` y no `${2:-...}`: hay un caso que necesita pasar una lista VACIA
    # a proposito (el bloque sin devs= legible), y con `:-` la cadena vacia se
    # trataba como "no me lo han pasado" y volvia la lista de tres.
    local devs="${2-$PMRT_DEVS3}" dis="${3:-3}" anul="${4:-2}"
    local pcie="${5:-SE RESPETA (fuera de la lista blanca)}"
    cat <<EOF
===== $1  PASO 1 (pmrt: disable+noshutdown)  accion=poweroff  dryrun=0
PMRT MODO=permanente (no requiere armado; freno en /var/lib/s5-test/gpu-pmrt-disabled)
PMRT TESTIGO justo antes de blindar: dGPU=D3cold/suspended audio=D3cold/suspended puente=D3cold/suspended  (espera 0s)
PMRT insmod rc=0  via=akmod  stderr=''
PMRT estado tras blindar: dGPU=D3cold/unsupported audio=D3cold/unsupported puente=D3cold/unsupported
PMRT dmesg del modulo:
[   12.345678] s5-pmrt-arm: ===== arm=1 devs=$devs noshut=nvidia,snd_hda_intel
EOF
    [ -n "$pcie" ] && printf '[   12.345679] s5-pmrt-arm: 0000:00:01.1   .shutdown de %s\n' "'pcieport' $pcie"
    printf '[   12.345680] s5-pmrt-arm: FIN  disable=%s shutdown_anulados=%s  => systemd apaga por el camino NORMAL\n' "$dis" "$anul"
}
pol_grub() {  # la politica desviando por GRUB, entera y con exito
    cat <<EOF
===== $1  POLITICA GPU  dryrun=0  maxwait=90s  root=rw boot=DESMONTADO
POLITICA dGPU despierta al entrar: dGPU=D0/active audio=D0/active puente=D0/active — esperando hasta 90s
POLITICA !!! la dGPU NO cayo a D3cold en 90.0s (traza: 0:D0)
POLITICA estado: dGPU=D0/active audio=D0/active puente=D0/active
POLITICA => el apagado normal costaria ~19 W; enrutando por GRUB (halt, ~0,32 W)
POLITICA /boot: estaba desmontado (lo esperado); montado por nosotros en rw
POLITICA armada: next_entry=s5politica, /boot/grub2/custom.cfg escrito (boot_montado_por_nosotros=1)
POLITICA reiniciando para que GRUB apague (veras un POST; es lo esperado)
EOF
}
{ pmrt_ok "$APAG_TS"; pol_grub "$POL_TS";   } > "$F/pol-grub.log"
# El mismo desvio real, pero seguido de un ENSAYO EN SECO posterior. Este es el
# que se colo el 2026-08-11: al ser el ultimo bloque uno de dryrun=1, la
# correlacion se perdia y reaparecia el falso FALLO de vatios.
{ pmrt_ok "$APAG_TS"; pol_grub "$POL_TS"
  echo "===== $(f $((FIN + 3000)))  POLITICA GPU  dryrun=1  maxwait=2s  root=rw boot=rw"
  echo "POLITICA sin riesgo: dGPU=D3cold/suspended => apagado normal (~2 W), no se toca nada"
} > "$F/pol-grub-y-ensayo.log"
{ pmrt_ok "$APAG_TS"; pol_grub "$VIEJO_TS"; } > "$F/pol-viejo.log"
{ pmrt_ok "$APAG_TS"
  echo "===== $POL_TS  POLITICA GPU  dryrun=0  maxwait=90s  root=rw boot=DESMONTADO"
  echo "POLITICA sin riesgo: dGPU=D3cold/suspended => apagado normal (~2 W), no se toca nada"
} > "$F/pol-normal.log"

# --- fixtures de $ELOG ------------------------------------------------------
# LA DURACION DE LA VENTANA ES UN PARAMETRO, no un adorno: es lo unico que
# separa un desvio por GRUB que se comio la medida (ventana corta, la maniobra
# pesa) de uno que no la toco (noche entera, la maniobra es ruido). Con "0.04 h"
# cableado aqui, la rama que aprueba la noche larga no se podia ensayar.
mk_elog() {  # mk_elog <fichero> <fecha del apagado> <vatios> [horas de ventana]
    local h="${4:-0.04}"
    { echo "$2  APAGADO     37.191 Wh   54%  Discharging  (bateria)"
      echo "$(f $((FIN + 60)))  ARRANQUE    36.143 Wh   53%  Discharging  (bateria)"
      # los Wh se derivan de h*W para que el fixture sea coherente consigo mismo
      echo "          => APAGADO $h h a bateria: -$(awk -v h="$h" -v w="$3" 'BEGIN{printf "%.3f", h*w}') Wh  =  $3 W medios en S5"
    } > "$1"
}
mk_elog "$F/e-grub.log"  "$APAG_TS" 26.38    # el apagado que se desvio (ventana corta)
mk_elog "$F/e-alto.log"  "$APAG_TS" 19.40    # apagado normal y caro
mk_elog "$F/e-bajo.log"  "$APAG_TS" 0.46     # apagado normal y mitigado
mk_elog "$F/e-post.log"  "$POST_TS" 19.40    # caro, pero POSTERIOR al desvio
# La noche del 2026-08-14: desviada por GRUB, pero 9,55 h de las que 9,52 fueron
# S5 de verdad. La maniobra no llega al 0,4% de la ventana.
mk_elog "$F/e-noche.log" "$APAG_TS"  0.32 9.55
# La misma noche larga pero CARA: existe para que la rama nueva no pueda
# convertirse en un aprobado automatico. Si desviar por GRUB tapara los vatios,
# esta saldria verde — y tiene que FALLAR.
mk_elog "$F/e-noche-cara.log" "$APAG_TS" 19.40 9.55

# --- fixtures de FPDT -------------------------------------------------------
# Se copia el valor real de esta maquina si existe; si no, uno representativo
# (11,5 s de POST+GRUB).
if [ -r /sys/firmware/acpi/fpdt/boot/exitbootservice_end_ns ]; then
    cat /sys/firmware/acpi/fpdt/boot/exitbootservice_end_ns > "$F/fpdt-ok"
else
    echo 11526108720 > "$F/fpdt-ok"
fi
echo 0     > "$F/fpdt-cero"
echo 'n/a' > "$F/fpdt-basura"

# --- el instante de arranque, que es lo que separa los dos escenarios --------
# 9ter decide por los tiempos de firmware, y hasta el 2026-08-13 los tomaba de
# `date` y `/proc/uptime` a pelo. Eso hacia que el veredicto dependiera de
# CUANTO ESTUVO EL EQUIPO APAGADO DE VERDAD, que es lo unico que unos fixtures
# no pueden fabricar: tras una noche larga el hueco sale de horas y la rama que
# DEBE avisar salia verde. El ensayo pasaba o fallaba segun la hora a la que se
# corriera — y eso no es un ensayo. Ahora el verificador acepta `ARRANQUE` y
# cada escenario se construye ENTERO, en vez de falsear la duracion de la pasada.
#
# La reconstruccion, con FIN = el reset que dio la politica:
#
#   GRUB APAGO:   reset -> pasada -> halt -> N s sin corriente -> boton
#                       -> pasada -> arranca el kernel      = FIN + 2*pasada + N
#   GRUB NO APAGO: reset -> pasada -> arranca el kernel     = FIN + cola + pasada
#                  (el menu expiro y Fedora arranco directa: NO hay pasada extra
#                   ni hueco sin corriente; el fallo benigno e invisible que
#                   esta seccion existe para cazar)
# PRECISION COMPLETA, Y NO ES COSMETICA. El verificador recalcula la pasada
# desde los ns del FPDT sin redondear. Si aqui se redondea a 0,1 s, el fixture y
# el verificador dejan de hablar del mismo numero y la diferencia entra DOBLADA,
# porque el escenario lleva dos pasadas. Con el FPDT de esta maquina
# (11,245913 s) `sobra` salia 17,9 s en vez de los 18 que promete el comentario
# de aqui abajo, y §10 imprimia "12.4%" donde el caso esperaba "12.5%".
#
# Lo grave es que el FPDT se copia del arranque VIVO: el redondeo cae de un lado
# o de otro segun el arranque, asi que el ensayo pasaba o fallaba segun cuando se
# corriera —y en otra maquina, segun su firmware—. Es el mismo defecto que el
# recuento del blindaje que ensaya §9 mas abajo (un literal que solo valia aqui),
# esta vez en el fixture en vez de en el verificador.
PASADA="$(awk 'BEGIN{ while ((getline l < ARGV[1]) > 0) ns = l; printf "%.6f", ns/1000000000 }' "$F/fpdt-ok")"
arranque() { awk -v f="$FIN" -v p="$PASADA" -v n="$1" -v x="$2" 'BEGIN{ printf "%.3f", f + x*p + n }'; }
ARR_APAGO="$(arranque 18 2)"    # 18 s sin corriente: sobran 18 s, muy por encima del margen de 5
ARR_DIRECTO="$(arranque 2 1)"   # una sola pasada + 2 s de cola de systemd-shutdown
ARR_JUSTO="$(arranque 2 2)"     # apago, pero solo 2 s: por DEBAJO del margen de 5 s => no se afirma
# 34267 s = 9,52 h sin corriente, la noche del 2026-08-14. Contra la ventana de
# 9,55 h de $F/e-noche.log da el 99,7% (34267/34380), muy por encima del 95% que
# pide §10. El numero es el que IMPRIME el verificador, comprobado ejecutandolo:
# aqui decia 99,6% y no cuadraba con su propia salida.
ARR_NOCHE="$(arranque 34267 2)"

printf '#!/bin/sh\nexit 1\n' > "$F/bin/journalctl"; chmod +x "$F/bin/journalctl"

# --- ejecutor ---------------------------------------------------------------
n=0; malas=0; saltadas=0
# QUE se salto, no solo CUANTAS. El cierre de este fichero daba por hecho que la
# unica saltable era el ancla real y anunciaba "1 saltada: sin arranque
# anterior..." fuese cual fuese la causa — y ya habia otra (correrlo como root
# salta la del directorio ilegible), asi que correr esto con sudo terminaba
# culpando al journal de algo que no habia pasado. Es el aviso que no significa
# nada de la regla 27, dentro del propio ensayo. Cada salto se apunta con su
# motivo y el resumen los lee de aqui.
SALTOS=()
salta() { saltadas=$((saltadas+1)); SALTOS+=("$1"); printf '  [salta] %s\n' "$1"; }
caso() {  # caso <titulo> <esperado(regex)> <VAR=val>...
    local titulo="$1" esperado="$2"; shift 2
    n=$((n+1))
    local out linea
    out="$(env "$@" bash "$CHK" 2>&1)"
    linea="$(printf '%s\n' "$out" | grep -E 'politica: GRUB|politica: NO se ve|se DESVIO POR GRUB|se desvio por GRUB|ultimo apagado|ACPI FPDT|sin journal del arranque|desvio por GRUB no fue|de la ventana, solo el|no se ha podido medir cuanto|NO CUADRAN' | head -3)"
    if printf '%s' "$linea" | grep -qE "$esperado"; then
        printf '  [ok]    %s\n' "$titulo"
    else
        printf '  [MAL]   %s\n          esperaba /%s/\n          obtuvo:  %s\n' \
               "$titulo" "$esperado" "${linea:-(nada)}"
        malas=$((malas+1))
    fi
}
# S5_DESCUBRE A UNA RUTA QUE NO EXISTE, EN TODOS: §9 puede caer al descubridor
# vivo para saber cuantos dispositivos deberia haber blindado, y en esta maquina
# ese descubridor encuentra una dGPU de verdad. Dejarlo suelto seria colar el
# hardware real en escenarios que dicen no depender de el — el mismo escape que
# ya costo un caso mal fiado en la seccion de GRUB. Los fixtures traen su propio
# `devs=`, que es la fuente buena.
G=(PCILOG="$F/pol-grub.log" ELOG="$F/e-grub.log" FPDT="$F/fpdt-ok" ARRANQUE="$ARR_APAGO" S5_DESCUBRE="$F/no-existe")
N=(PCILOG="$F/pol-normal.log" FPDT="$F/fpdt-ok" ARRANQUE="$ARR_APAGO" S5_DESCUBRE="$F/no-existe")
DESVIO=(PCILOG="$F/pol-grub.log" ELOG="$F/e-grub.log" S5_DESCUBRE="$F/no-existe")   # sin FPDT ni ARRANQUE: los pone cada caso
# OJO: NO llamar `D` a esto. `D` es el directorio de este script, y darle un
# array del mismo nombre lo pisa en silencio — `$D` pasa a ser el primer
# elemento. No se noto hasta que algo mas abajo volvio a usar `$D`.

echo "9ter — ¿GRUB apago de verdad?"
caso "GRUB apago: cabe una pasada extra + 18 s sin corriente => AFIRMA"  'GRUB APAGO DE VERDAD' "${G[@]}" "${ANCLA[@]}"
caso "GRUB NO apago: una sola pasada, Fedora directa => AVISA (la que DEBE sonar)" \
                                                                        'NO se ve la pasada extra' "${DESVIO[@]}" "${ANCLA[@]}" FPDT="$F/fpdt-ok" ARRANQUE="$ARR_DIRECTO"
caso "apago pero solo 2 s: por debajo del margen => AVISA, no se afirma" 'NO se ve la pasada extra' "${DESVIO[@]}" "${ANCLA[@]}" FPDT="$F/fpdt-ok" ARRANQUE="$ARR_JUSTO"
caso "sin FPDT en la plataforma => se abstiene"                         'sin ACPI FPDT' "${DESVIO[@]}" FPDT="$F/no-existe" ARRANQUE="$ARR_APAGO"
caso "FPDT a cero => se abstiene"                                       'no trae tiempos utiles' "${DESVIO[@]}" FPDT="$F/fpdt-cero" ARRANQUE="$ARR_APAGO"
caso "FPDT con basura => se abstiene"                                   'no trae tiempos utiles' "${DESVIO[@]}" FPDT="$F/fpdt-basura" ARRANQUE="$ARR_APAGO"
caso "sin /proc/uptime utilizable ni ARRANQUE => se abstiene"           'no trae tiempos utiles' "${DESVIO[@]}" FPDT="$F/fpdt-ok" ARRANQUE='' PROCUPTIME="$F/no-existe"
caso "sin journal del arranque anterior => se abstiene"                 'sin journal del arranque' "${G[@]}" PATH="$F/bin:$PATH"
caso "desvio de hace 11 dias => no lo cubren los tiempos de ahora"      'no fue el apagado inmediatamente anterior' "${ANCLA[@]}" PCILOG="$F/pol-viejo.log" ELOG="$F/e-grub.log" FPDT="$F/fpdt-ok" ARRANQUE="$ARR_APAGO"
caso "apagado normal => 9ter callada, habla la seccion 10"              'ultimo apagado medido: 0.46 W' "${N[@]}" ELOG="$F/e-bajo.log"

echo
echo "10 — la energia: cuando el umbral aplica y cuando no"
# CON ANCLA LAS DOS: llegan a la reconstruccion de §9ter, y el cierre de este
# ensayo promete que "las ramas de 9ter NO dependen del journal: llevan ancla de
# mentira". Estas dos eran las que se habian quedado sin ella, asi que en una
# maquina sin arranque anterior (contenedor, journal en volatil, tras un vacuum)
# la de abajo no encontraba S5 real y decia "no se ha podido medir cuanto".
caso "desviado por GRUB en ventana CORTA => SE ABSTIENE (el falso FALLO que se vino a matar)" 'se DESVIO POR GRUB' "${G[@]}" "${ANCLA[@]}"
caso "...y al abstenerse dice el % real, no 'duro segundos'"                   'de la ventana, solo el 12.5% fue S5 real' "${G[@]}" "${ANCLA[@]}"
caso "apagado normal a 19,4 W => FALLA (no se ha roto lo de siempre)"         'gasto 19.40 W' "${N[@]}" ELOG="$F/e-alto.log"
caso "apagado normal a 0,46 W => OK"                                          'ultimo apagado medido: 0.46 W' "${N[@]}" ELOG="$F/e-bajo.log"
caso "apagado POSTERIOR al desvio y caro => FALLA igual, el desvio no lo tapa" 'gasto 19.40 W' PCILOG="$F/pol-grub.log" ELOG="$F/e-post.log" FPDT="$F/fpdt-ok"
# ARRANQUE FIJADO A PROPOSITO (regla 30): sin el, §10 acaba consultando los
# tiempos que §9ter saca de `date`+`/proc/uptime`, y este caso —que solo quiere
# comprobar la CORRELACION— empezaba a depender de cuanto llevaba encendida la
# maquina de verdad. Asi salio el 23795% que destapo el fallo de la guarda.
caso "un ENSAYO EN SECO posterior no rompe la correlacion del desvio"          'se DESVIO POR GRUB' PCILOG="$F/pol-grub-y-ensayo.log" ELOG="$F/e-grub.log" FPDT="$F/fpdt-ok" ARRANQUE="$ARR_APAGO" "${ANCLA[@]}"
caso "S5 reconstruido MAS LARGO que la ventana => incoherente, no se concluye (no un aprobado)" \
                                        'NO CUADRAN' "${DESVIO[@]}" "${ANCLA[@]}" FPDT="$F/fpdt-ok" ARRANQUE="$ARR_NOCHE"

# LA NOCHE DEL 2026-08-14: desviada por GRUB, pero la maniobra no llega al 0,4%
# de la ventana. Antes esto se despachaba con "el S5 real duro segundos" —falso,
# duro 9,52 h— y la mejor medida de la serie se publicaba como "no aplica".
caso "noche entera desviada por GRUB => la medida VALE (99,7% de S5 real)" \
                                        'la medida SI vale' "${DESVIO[@]}" "${ANCLA[@]}" ELOG="$F/e-noche.log" FPDT="$F/fpdt-ok" ARRANQUE="$ARR_NOCHE"
caso "...y se le aplica el umbral: 0,32 W => OK"                              'ultimo apagado medido: 0.32 W' "${DESVIO[@]}" "${ANCLA[@]}" ELOG="$F/e-noche.log" FPDT="$F/fpdt-ok" ARRANQUE="$ARR_NOCHE"
caso "noche entera desviada pero CARA => FALLA (la rama nueva no es un indulto)" \
                                        'gasto 19.40 W' "${DESVIO[@]}" "${ANCLA[@]}" ELOG="$F/e-noche-cara.log" FPDT="$F/fpdt-ok" ARRANQUE="$ARR_NOCHE"
caso "noche larga pero sin saber cuanto fue S5 (sin FPDT) => se abstiene sin inventarse la cifra" \
                                        'no se ha podido medir cuanto' "${DESVIO[@]}" "${ANCLA[@]}" ELOG="$F/e-noche.log" FPDT="$F/no-existe" ARRANQUE="$ARR_NOCHE"

echo
echo "regla 17 — que hay en el directorio de hooks"
# ESTA SECCION NO EXISTIA, y la rama que faltaba por ensayar era la que mas
# dolia: la lista blanca traia clavados los hooks de la maquina de desarrollo
# (fwupd, mdadm) y CUALQUIER otro ejecutable daba FALLO. O sea que una maquina
# ajena y sana gritaba en cada arranque. Ahora se separan copias sueltas de las
# nuestras (FALLO de verdad) de hooks de terceros (solo se nombran, silenciables).
mkdir -p "$F/hooks-limpio" "$F/hooks-ajeno" "$F/hooks-intruso" "$F/hooks-vacio"
for h in 99-s5-pci-state.shutdown 99y-s5-gpu-pmrt.shutdown; do
    for d in hooks-limpio hooks-ajeno hooks-intruso; do
        printf '#!/bin/sh\nexit 0\n' > "$F/$d/$h"; chmod +x "$F/$d/$h"
    done
done
# la distro de otro: nombres que esta maquina no tiene
for h in zfs.shutdown lvm2.shutdown; do
    printf '#!/bin/sh\nexit 0\n' > "$F/hooks-ajeno/$h"; chmod +x "$F/hooks-ajeno/$h"
done
# el accidente de la regla 17: una copia del NUESTRO que systemd correria a la vez
printf '#!/bin/sh\nexit 0\n' > "$F/hooks-intruso/99y-s5-gpu-pmrt.shutdown.bak-20260809"
chmod +x "$F/hooks-intruso/99y-s5-gpu-pmrt.shutdown.bak-20260809"
H=(PCILOG="$F/pol-normal.log" ELOG="$F/e-bajo.log" FPDT="$F/fpdt-ok" ARRANQUE="$ARR_APAGO" S5_DESCUBRE="$F/no-existe")
# SE ASSERTA SOBRE EL PREFIJO [AVISO]/[FALLO], no sobre el rc del verificador:
# el rc agrega TODAS las comprobaciones, asi que atarlo aqui haria que estos
# casos dependieran de si la maquina donde corre el ensayo tiene el modulo
# cargable, el akmod puesto, etc. Justo la dependencia del entorno que la regla
# 30 prohibe. La distincion que importa es aviso-frente-a-fallo, y esa se ve.
hookcaso() {  # hookcaso <titulo> <regex esperada> <VAR=val>...
    local titulo="$1" esperado="$2"; shift 2
    n=$((n+1))
    local out
    out="$(env "$@" bash "$CHK" 2>&1 | grep -E 'directorio de hooks|COPIAS SUELTAS|hooks de otros paquetes')"
    if printf '%s' "$out" | grep -qE "$esperado"; then printf '  [ok]    %s\n' "$titulo"
    else printf '  [MAL]   %s\n          esperaba /%s/\n          obtuvo:  %s\n' "$titulo" "$esperado" "${out:-(nada)}"
         malas=$((malas+1)); fi
}
hookcaso "solo los nuestros => OK, y cuenta los que hay (no 'los 4 de siempre')" \
    '\[ OK \].*directorio de hooks limpio .*: los 2 nuestros' "${H[@]}" HOOKDIR="$F/hooks-limpio"
hookcaso "hooks de OTRA distro => se nombran, sin aviso ni fallo (la maquina ajena que gritaba)" \
    'y hooks de otros paquetes.*zfs.shutdown' "${H[@]}" HOOKDIR="$F/hooks-ajeno"
hookcaso "...y S5_HOOKS_EXTRA los calla del todo" \
    '\[ OK \].*directorio de hooks limpio' "${H[@]}" HOOKDIR="$F/hooks-ajeno" S5_HOOKS_EXTRA="zfs.shutdown lvm2.shutdown"
hookcaso "una copia .bak de uno NUESTRO => sigue siendo FALLO (el accidente de la regla 17)" \
    '\[FALLO\].*COPIAS SUELTAS' "${H[@]}" HOOKDIR="$F/hooks-intruso"

echo
echo "codigos de salida"
rc() { n=$((n+1)); env "${@:3}" bash "$CHK" -q >/dev/null 2>&1
       [ $? = "$1" ] && printf '  [ok]    %s\n' "$2" || { printf '  [MAL]   %s\n' "$2"; malas=$((malas+1)); }; }
rc 0 "desviado por GRUB => rc=0 (no es un fallo)"  "${G[@]}"
rc 1 "apagado caro de verdad => rc=1"              "${N[@]}" ELOG="$F/e-alto.log"
rc 1 "noche desviada por GRUB pero cara => rc=1 (el desvio no absuelve)" \
    "${DESVIO[@]}" "${ANCLA[@]}" ELOG="$F/e-noche-cara.log" FPDT="$F/fpdt-ok" ARRANQUE="$ARR_NOCHE"

echo
echo "el veredicto — que el recuento de avisos cuadre con los avisos que hay"
# `${avisos:+ ($avisos aviso(s))}` expandia con avisos=0, porque en bash el `0`
# no es nulo: una pasada perfecta terminaba diciendo "TODO EN ORDEN (0 aviso(s))",
# justo la linea que el README y install.sh prometen limpia.
#
# NO se asserta "no digas 0": eso pasaria solo porque la maquina donde corre el
# ensayo tenga algun aviso, y un testigo que nunca ha cambiado no es un testigo.
# Se comprueba la INVARIANTE, que se ejercita salga lo que salga: el numero del
# veredicto tiene que ser el numero de lineas [AVISO], y con cero avisos no puede
# haber sufijo ninguno.
n=$((n+1))
_out="$(env "${N[@]}" ELOG="$F/e-bajo.log" bash "$CHK" 2>&1)"
_nav=$(printf '%s\n' "$_out" | grep -c '\[AVISO\]')
_ver=$(printf '%s\n' "$_out" | grep '^VEREDICTO:' | head -1)
_mal=''
case "$_ver" in
    'VEREDICTO: TODO EN ORDEN'*)
        if [ "$_nav" = 0 ]; then
            case "$_ver" in *aviso*) _mal="sin ningun [AVISO] y el veredicto habla de avisos" ;; esac
        else
            case "$_ver" in *"($_nav aviso(s))"*) ;; *) _mal="$_nav avisos y el veredicto no los cuenta bien" ;; esac
        fi ;;
    *FALLO*)
        case "$_ver" in *"$_nav aviso(s)"*) ;; *) _mal="$_nav avisos y el veredicto no los cuenta bien" ;; esac ;;
    *)  _mal="no hay linea de VEREDICTO" ;;
esac
if [ -z "$_mal" ]; then
    printf '  [ok]    el veredicto cuenta los avisos que hay (%s en esta pasada)\n' "$_nav"
else
    printf '  [MAL]   el veredicto no cuadra: %s\n          veredicto: %s\n' "$_mal" "$_ver"
    malas=$((malas+1))
fi
unset _out _nav _ver _mal

echo
echo "sabor de GRUB — Fedora/RHEL/SUSE (grub2-*) frente a Debian/Ubuntu/Arch (grub-*)"
# POR QUE ESTAS RAMAS SE ENSAYAN CON FIXTURES Y NO EN LA MAQUINA: aqui solo hay
# una distribucion. El camino de Debian no se puede provocar de otra forma, y
# publicar una rama sin ensayar es justo lo que la regla 22 prohibe. Se fabrican
# los dos mundos con directorios de mentira (S5_GRUB_DIRS) y ordenes de mentira
# en el PATH, que es todo lo que mira el descubridor.
DG="$D/../system/bin/s5-descubre-grub"
mkdir -p "$F/fedora/grub2" "$F/debian/grub" "$F/vacio/grub" "$F/bin2" "$F/bin1"
: > "$F/fedora/grub2/grubenv"
: > "$F/debian/grub/grubenv"
# $F/vacio/grub existe pero NO trae grubenv: un /boot/grub a medias, que es real
# —lo dejan instaladores a medio camino— y donde escribir el custom.cfg no
# serviria de nada porque GRUB no lo leeria.
for c in grub2-reboot grub2-editenv; do printf '#!/bin/sh\nexit 0\n' > "$F/bin2/$c"; chmod +x "$F/bin2/$c"; done
for c in grub-reboot  grub-editenv;  do printf '#!/bin/sh\nexit 0\n' > "$F/bin1/$c"; chmod +x "$F/bin1/$c"; done

# EL PATH SOLO LLEVA EL BIN DE MENTIRA, nada del sistema. Primer intento: dejar
# /usr/bin:/bin "pelado" — y ahi es justo donde viven los grub2-* de VERDAD de
# esta maquina, asi que el caso de Debian encontraba grub2-reboot y salia verde
# por accidente. Mismo error que tenia 9ter con el reloj: dejar que la maquina
# real se filtre en un escenario que dice no depender de ella. Se puede porque
# el descubridor no usa ninguna orden externa: `command -v` y `[` son builtins.
mkdir -p "$F/bin-vacio"
grubcaso() {  # grubcaso <titulo> <esperado: DIR|REBOOT|EDITENV=valor...> <VAR=val>...
    local titulo="$1" esperado="$2"; shift 2
    n=$((n+1))
    local out
    # bash POR RUTA ABSOLUTA: el PATH de estos casos solo lleva el bin de
    # mentira, asi que `env` no sabria encontrarlo por nombre.
    out="$(env -i HOME="$HOME" "$@" "$BASH" -c '. '"$DG"' >/dev/null 2>&1; echo "DIR=$GRUB_DIR REBOOT=$GRUB_REBOOT EDITENV=$GRUB_EDITENV"' 2>&1)"
    if printf '%s' "$out" | grep -qF "$esperado"; then
        printf '  [ok]    %s\n' "$titulo"
    else
        printf '  [MAL]   %s\n          esperaba /%s/\n          obtuvo:  %s\n' "$titulo" "$esperado" "$out"
        malas=$((malas+1))
    fi
}

grubcaso "Fedora: grub2-* y /boot/grub2 => elige grub2" \
    "DIR=$F/fedora/grub2 REBOOT=grub2-reboot EDITENV=grub2-editenv" \
    PATH="$F/bin2" S5_GRUB_DIRS="$F/fedora/grub2 $F/fedora/grub" S5_CONF=/dev/null
grubcaso "Debian: solo grub-* y /boot/grub => elige grub (LA QUE NO FUNCIONABA)" \
    "DIR=$F/debian/grub REBOOT=grub-reboot EDITENV=grub-editenv" \
    PATH="$F/bin1" S5_GRUB_DIRS="$F/debian/grub2 $F/debian/grub" S5_CONF=/dev/null
grubcaso "un /boot/grub a medias (sin grubenv) no se elige; gana el que si lo trae" \
    "DIR=$F/fedora/grub2" \
    PATH="$F/bin2" S5_GRUB_DIRS="$F/vacio/grub $F/fedora/grub2" S5_CONF=/dev/null
grubcaso "instalacion mixta: ordenes de Fedora, directorio de Debian (no se deduce uno del otro)" \
    "DIR=$F/debian/grub REBOOT=grub2-reboot" \
    PATH="$F/bin2" S5_GRUB_DIRS="$F/debian/grub" S5_CONF=/dev/null
grubcaso "sin directorio utilizable => vacio, y la politica abortara (falla segura)" \
    "DIR= REBOOT=grub2-reboot" \
    PATH="$F/bin2" S5_GRUB_DIRS="$F/vacio/grub" S5_CONF=/dev/null
grubcaso "sin ninguna orden de GRUB en el PATH => vacias" \
    "REBOOT= EDITENV=" \
    PATH="$F/bin-vacio" S5_GRUB_DIRS="$F/fedora/grub2" S5_CONF=/dev/null
# El escape manual tiene que ganar aunque el descubrimiento acierte, o no sirve
# para nada: existe justo para las topologias que no se adivinan.
echo "S5_GRUB_DIR=$F/debian/grub" > "$F/conf-grub"
echo "S5_GRUB_REBOOT=orden-inventada" >> "$F/conf-grub"
grubcaso "el escape de la config gana al descubrimiento" \
    "DIR=$F/debian/grub REBOOT=orden-inventada" \
    PATH="$F/bin2" S5_GRUB_DIRS="$F/fedora/grub2" S5_CONF="$F/conf-grub"

echo
echo "s5-descubre-dgpu — la pieza que todo lo demas finge, y que no ejercitaba nadie"
# ANADIDO EL 2026-08-15. Todos los casos de arriba apuntan S5_DESCUBRE a una ruta
# que no existe o a un descubridor de mentira, y con razon: dejarlo suelto seria
# colar el hardware real en escenarios que dicen no depender de el. El efecto
# colateral es que el descubridor DE VERDAD —de quien salen los BDF que el modulo
# blinda, o sea la pieza de la que cuelga todo el proyecto— no lo tocaba ni una
# linea de este fichero. El centinela `none`, que s5-poweroff-fix.conf.example
# promete por escrito, tenia n=0.
#
# QUE ES ENSAYABLE AQUI Y QUE NO (regla 22: lo que no se puede inyectar no se
# puede ensayar). La ELECCION de la dGPU vive en un `for d in
# /sys/bus/pci/devices/*` con la ruta clavada, asi que no es inyectable sin un
# sysfs de mentira y no se finge: esa parte la cubre `install.sh --check` en cada
# maquina real. Lo que SI es hermetico es todo lo que pasa despues de leer la
# configuracion, y es justo donde viven las promesas del .conf de ejemplo.
#
# LOS BDF SON INVENTADOS A PROPOSITO: 0000:ff:00.0 y companía no existen en
# NINGUNA maquina, asi que estos casos dan lo mismo aqui que en un contenedor
# pelado, y ninguno puede salir verde por accidente leyendo la GPU de verdad.
DD="${DD:-$D/../system/bin/s5-descubre-dgpu}"   # overridable para mutar el script y ver que el ensayo lo caza

ddcaso() {  # ddcaso <titulo> <esperado literal> <lineas del .conf...>
    local titulo="$1" esperado="$2"; shift 2
    n=$((n+1))
    local out
    printf '%s\n' "$@" > "$F/conf-dd"
    # Sourceado, que es como lo usan el hook y la politica. `env -i` con PATH:
    # el descubridor solo necesita `readlink` de fuera, el resto son builtins.
    out="$(env -i HOME="$HOME" PATH="$PATH" S5_CONF="$F/conf-dd" "$BASH" -c \
        '. '"$DD"' >/dev/null 2>&1; echo "GPU=$GPU AUDIO=$AUDIO BRIDGE=$BRIDGE DEVS=$S5_DEVS"' 2>&1)"
    if printf '%s' "$out" | grep -qF "$esperado"; then
        printf '  [ok]    %s\n' "$titulo"
    else
        printf '  [MAL]   %s\n          esperaba /%s/\n          obtuvo:  %s\n' "$titulo" "$esperado" "$out"
        malas=$((malas+1))
    fi
}

# LA PROMESA DEL .conf DE EJEMPLO, PALABRA POR PALABRA: "to leave a part alone ON
# PURPOSE, set it to `none`. An EMPTY value does not work and never did".
ddcaso "AUDIO=none y BRIDGE=none => se desactivan, y devs= queda solo con la GPU" \
    'GPU=0000:ff:00.0 AUDIO= BRIDGE= DEVS=0000:ff:00.0' \
    'GPU=0000:ff:00.0' 'AUDIO=none' 'BRIDGE=none'
ddcaso "solo AUDIO=none: el puente se sigue intentando descubrir" \
    'AUDIO= BRIDGE= DEVS=0000:ff:00.0' \
    'GPU=0000:ff:00.0' 'AUDIO=none'
# SIN COMAS SUELTAS. El modulo escupe "BDF ilegible" con una lista como
# `,0000:ff:00.0,` y se quedaria sin blindar lo que toca.
ddcaso "falta el puente pero hay audio => devs= sin comas sueltas, y en orden" \
    'DEVS=0000:ff:00.0,0000:ff:00.1' \
    'GPU=0000:ff:00.0' 'AUDIO=0000:ff:00.1' 'BRIDGE=none'
ddcaso "vendor que no tiene nadie => sin GPU y devs= vacio (maquina sin el problema)" \
    'GPU= AUDIO= BRIDGE= DEVS=' \
    'S5_VENDOR=0xdead'
# El escape manual tiene que ganar tambien aqui: si el descubrimiento pudiera
# pisarlo, no serviria para las topologias raras, que es para lo unico que esta.
ddcaso "el GPU= de la config gana al descubrimiento (haya o no discreta de verdad)" \
    'GPU=0000:ff:00.0' \
    'GPU=0000:ff:00.0' 'AUDIO=none' 'BRIDGE=none'

# --- el informe, que es lo que se mira ANTES de instalar ---------------------
# `readlink -f` SOBRE UN SYMLINK QUE NO EXISTE DEVUELVE 0 e imprime la ruta
# igual, asi que el `|| echo '(ninguno)'` que habia no disparaba nunca y una dGPU
# sin driver enlazado se anunciaba como `driver actual  : driver`. Es la linea
# que caza un GPU= mal puesto —diria `nvme` donde esperas `nvidia`— o sea el
# unico testigo del informe que protege de blindar el disco.
n=$((n+1))
printf 'GPU=0000:ff:00.0\n' > "$F/conf-dd"
_o="$(env -i HOME="$HOME" PATH="$PATH" S5_CONF="$F/conf-dd" "$BASH" "$DD" 2>&1)"; _rc=$?
if [ "$_rc" != 0 ] && printf '%s' "$_o" | grep -q 'NO esta en el bus PCI'; then
    printf '  [ok]    GPU= a un BDF que no esta en el bus => lo dice y sale con rc!=0\n'
else
    printf '  [MAL]   GPU= a un BDF que no esta en el bus: deberia decirlo y salir con rc!=0\n          rc=%s  obtuvo: %s\n' \
           "$_rc" "$(printf '%s' "$_o" | tail -3 | tr '\n' ' ')"
    malas=$((malas+1))
fi

# ESTE NECESITA UN DISPOSITIVO DE VERDAD sin driver enlazado — un puente host,
# una funcion sin modulo — y eso no se puede fabricar sin sysfs de mentira. Se
# busca en el bus vivo y, si esta maquina no tiene ninguno, se salta diciendolo
# en vez de fingir que se ha comprobado algo (regla 30).
n=$((n+1))
_sindrv=''
for _d in /sys/bus/pci/devices/*; do
    [ -e "$_d" ] || continue
    [ -e "$_d/driver" ] || { _sindrv="${_d##*/}"; break; }
done
if [ -z "$_sindrv" ]; then
    salta "linea del driver sin driver enlazado: todos los PCI de esta maquina tienen uno"
else
    printf 'GPU=%s\n' "$_sindrv" > "$F/conf-dd"
    _o="$(env -i HOME="$HOME" PATH="$PATH" S5_CONF="$F/conf-dd" "$BASH" "$DD" 2>&1)"
    if printf '%s' "$_o" | grep -q 'driver actual  : (ninguno)'; then
        printf '  [ok]    dispositivo sin driver => "(ninguno)", no el nombre del propio symlink\n'
    else
        printf '  [MAL]   dispositivo sin driver (%s): sigue anunciando el symlink como si fuera un driver\n          obtuvo:  %s\n' \
               "$_sindrv" "$(printf '%s' "$_o" | grep 'driver actual')"
        malas=$((malas+1))
    fi
fi
unset _o _rc _d _sindrv

echo
echo "el verificador lo dice EN FRIO (si no, se descubre la noche que hacia falta)"
# La rama de GRUB de la politica aborta en mitad del apagado, donde nadie mira.
# Estas tres comprueban que `s5-mitigacion-check` lo canta en el arranque.
# Aqui el PATH SI lleva el del sistema (el verificador usa awk, systemctl...),
# solo se le antepone el bin de mentira para que grub2-editenv no sea el de
# verdad de esta maquina.
avisocaso() {  # avisocaso <titulo> <regex esperada | !regex que NO debe salir> <VAR=val>...
    local titulo="$1" esperado="$2"; shift 2
    n=$((n+1))
    local out negada=0
    [ "${esperado#!}" != "$esperado" ] && { negada=1; esperado="${esperado#!}"; }
    out="$(env "$@" bash "$CHK" 2>&1)"
    if printf '%s' "$out" | grep -qE "$esperado"; then
        [ "$negada" = 0 ] && { printf '  [ok]    %s\n' "$titulo"; return; }
        printf '  [MAL]   %s\n          NO debia salir /%s/, y ha salido\n' "$titulo" "$esperado"
    else
        [ "$negada" = 1 ] && { printf '  [ok]    %s\n' "$titulo"; return; }
        printf '  [MAL]   %s\n          esperaba /%s/ y no sale\n' "$titulo" "$esperado"
    fi
    malas=$((malas+1))
}
avisocaso "falta el descubridor => AVISA (la politica abortaria su rama de GRUB)" \
    'no sabra que GRUB tiene esta maquina' \
    "${N[@]}" S5_DESCUBRE_GRUB="$F/no-existe" S5_CONF=/dev/null
avisocaso "hay descubridor pero ningun GRUB usable => AVISA que la rama se autodesactiva" \
    'GRUB incompleto \(dir=no' \
    "${N[@]}" S5_DESCUBRE_GRUB="$DG" S5_GRUB_DIRS="$F/vacio/grub" PATH="$F/bin2:$PATH" S5_CONF=/dev/null
avisocaso "GRUB completo => ni una palabra sobre GRUB (los avisos que no callan no se leen)" \
    '!GRUB incompleto|no sabra que GRUB' \
    "${N[@]}" S5_DESCUBRE_GRUB="$DG" S5_GRUB_DIRS="$F/fedora/grub2" PATH="$F/bin2:$PATH" S5_CONF=/dev/null
# EL DIRECTORIO ESTA PERO NO SE PUEDE LEER. /boot/grub2 es drwx------ root, asi
# que un `s5-mitigacion-check` sin sudo gritaba "GRUB incompleto" en una maquina
# donde la rama de GRUB esta perfecta. No es un problema de GRUB, es de permisos,
# y el propio s5-descubre-grub ya lo distingue.
#
# ROOT NO PUEDE PROVOCAR ESTA RAMA: para root todo es legible, asi que
# GRUB_SIN_PERMISO nunca se rellena. Se salta diciendolo, en vez de fingir que se
# ha comprobado algo (regla 30: un caso que solo vale segun quien lo corra no es
# un caso).
n=$((n+1))
mkdir -p "$F/sinpermiso/grub2"; : > "$F/sinpermiso/grub2/grubenv"; chmod 000 "$F/sinpermiso/grub2"
if [ "$(id -u)" = 0 ]; then
    salta "directorio de GRUB ilegible: como root no hay nada ilegible que provocar"
else
    _o="$(env "${N[@]}" S5_DESCUBRE_GRUB="$DG" S5_GRUB_DIRS="$F/sinpermiso/grub2" \
              PATH="$F/bin2:$PATH" S5_CONF=/dev/null bash "$CHK" 2>&1)"
    if printf '%s' "$_o" | grep -q 'no se puede leer sin root' && ! printf '%s' "$_o" | grep -q 'GRUB incompleto'; then
        printf '  [ok]    directorio de GRUB ilegible => se dice que es por permisos, no "GRUB incompleto"\n'
    else
        printf '  [MAL]   directorio de GRUB ilegible: sigue gritando GRUB incompleto\n          obtuvo:  %s\n' \
               "$(printf '%s' "$_o" | grep -E 'GRUB|permiso' | head -2)"
        malas=$((malas+1))
    fi
    unset _o
fi
chmod 755 "$F/sinpermiso/grub2"   # que el `rm -rf` del final pueda con el

echo
echo "9 — el recuento del blindaje NO puede ser una constante"
# LA RAMA QUE FALTABA, Y LA QUE MAS DOLIA (anadida 2026-08-15). §9 exigia
# literalmente `FIN disable=3 shutdown_anulados=2`: la topologia de la maquina
# donde se midio esto. Una discreta SIN funcion de audio HDMI, un AUDIO=none en
# la configuracion o nouveau en vez de nvidia dan 2 y 1 — y eso daba FALLO,
# fichero mitigacion-ROTA y `wall` EN CADA ARRANQUE de una maquina perfectamente
# sana. Tercera vez que aparece el mismo accidente (los BDF clavados en los
# hooks, la lista blanca de la regla 17, y esto), y la peor de las tres: en el
# informe que la gente usa para decidir si fiarse de todo lo demas.
#
# Y el ensayo no podia cazarlo porque el fixture repetia el mismo literal. Por
# eso ahora la topologia es un parametro de pmrt_ok().
{ pmrt_ok "$APAG_TS" '0000:00:01.1,0000:01:00.0' 2 1; } > "$F/pmrt-2disp.log"  # sin audio HDMI: 2 y 1
{ pmrt_ok "$APAG_TS" "$PMRT_DEVS3" 2 1; } > "$F/pmrt-descuadre.log"          # se pidieron 3, se blindaron 2
{ pmrt_ok "$APAG_TS" '' 0 0;        } > "$F/pmrt-sin-devs.log"               # bloque sin devs= legible
{ pmrt_ok "$APAG_TS" "$PMRT_DEVS3" 3 0; } > "$F/pmrt-sin-anulados.log"       # ningun .shutdown anulado
{ pmrt_ok "$APAG_TS" "$PMRT_DEVS3" 3 3 'ANULADO'; } > "$F/pmrt-pcieport.log" # la linea roja
{ pmrt_ok "$APAG_TS" '0000:01:00.0,0000:01:00.1' 2 2 ''; } > "$F/pmrt-sin-puente.log"  # BRIDGE=none
PM=(ELOG="$F/e-bajo.log" FPDT="$F/fpdt-ok" ARRANQUE="$ARR_APAGO" S5_DESCUBRE="$F/no-existe")

pmrtcaso() {  # pmrtcaso <titulo> <regex esperada | !regex que NO debe salir> <VAR=val>...
    local titulo="$1" esperado="$2"; shift 2
    n=$((n+1))
    local out negada=0
    [ "${esperado#!}" != "$esperado" ] && { negada=1; esperado="${esperado#!}"; }
    out="$(env "$@" bash "$CHK" 2>&1 | grep -E 'blindaje aplicado|con .shutdown anulado|pcieport|recuento del blindaje|shutdown_anulados=0')"
    if printf '%s' "$out" | grep -qE "$esperado"; then
        [ "$negada" = 0 ] && { printf '  [ok]    %s\n' "$titulo"; return; }
        printf '  [MAL]   %s\n          NO debia salir /%s/, y ha salido:  %s\n' "$titulo" "$esperado" "$out"
    else
        [ "$negada" = 1 ] && { printf '  [ok]    %s\n' "$titulo"; return; }
        printf '  [MAL]   %s\n          esperaba /%s/\n          obtuvo:  %s\n' "$titulo" "$esperado" "${out:-(nada)}"
    fi
    malas=$((malas+1))
}

pmrtcaso "topologia de 3 (puente+GPU+audio) => OK, y dice 3" \
    '\[ OK \].*blindaje aplicado a los 3 dispositivos' "${PM[@]}" PCILOG="$F/pol-normal.log"
pmrtcaso "discreta SIN audio HDMI (2 dispositivos) => OK (EL FALLO FALSO QUE SE VINO A MATAR)" \
    '\[ OK \].*blindaje aplicado a los 2 dispositivos' "${PM[@]}" PCILOG="$F/pmrt-2disp.log"
pmrtcaso "...y con 2 dispositivos NO se queja del recuento por ningun lado" \
    '!\[FALLO\]' "${PM[@]}" PCILOG="$F/pmrt-2disp.log"
pmrtcaso "se pidieron 3 y solo se blindaron 2 => FALLO (un dispositivo no aparecio en el bus)" \
    '\[FALLO\].*blindaje aplicado a los 3 dispositivos' "${PM[@]}" PCILOG="$F/pmrt-descuadre.log"
pmrtcaso "sin devs= en el bloque y sin descubridor => AVISA, no se inventa el numero" \
    '\[AVISO\].*no se puede saber cuantos dispositivos' "${PM[@]}" PCILOG="$F/pmrt-sin-devs.log"
pmrtcaso "shutdown_anulados=0 => AVISO (la mitad (a) sola colgo la maquina dos veces)" \
    '\[AVISO\].*shutdown_anulados=0' "${PM[@]}" PCILOG="$F/pmrt-sin-anulados.log"
pmrtcaso "pcieport ANULADO => FALLO: gobierna todos los puertos, es la linea roja" \
    '\[FALLO\].*pcieport' "${PM[@]}" PCILOG="$F/pmrt-pcieport.log"
pmrtcaso "sin linea de pcieport (BRIDGE=none) => ni FALLO ni AVISO, solo se dice" \
    '!\[FALLO\]|\[AVISO\]' "${PM[@]}" PCILOG="$F/pmrt-sin-puente.log"

echo
echo "uninstall.sh — que no deje tocado el arranque"
# EL SCRIPT MAS PELIGROSO DEL REPO Y EL ULTIMO SIN ENSAYAR. Borra ficheros,
# desarma el gestor de arranque, escribe en el RTC y restaura las entradas de
# arranque. Dos accidentes reales salieron de aqui —desinstalar con una prueba
# de GRUB armada dejaba el equipo apagandose solo al encenderlo; con una prueba
# de args armada dejaba el kernel parcheado PARA SIEMPRE— y los dos se colaron
# justo porque esta rama no tenia ensayo. Ahora corre entero contra un /boot, un
# /var y un /sys de mentira (regla 22: todas sus rutas son overridables).
UNI="${UNI:-$D/../uninstall.sh}"   # overridable para poder mutar el script y ver que el ensayo lo caza
U="$F/uni"
# Configuracion que ve uninstall.sh. Vacia = la de mentira que no existe, que es
# lo que quieren casi todos los casos; solo el de S5_GRUB_DIR la necesita.
UNI_CONF=''

# Shims. `id` para el chequeo de root, `systemctl` para no tocar el systemd de
# quien ensaya, y LOS DOS SABORES de grub*-editenv contra un grubenv de mentira.
# Los dos, no solo el de Fedora: si se deja el de Debian al descubierto, en una
# maquina Debian este ensayo le desarmaria a quien lo corre el next_entry DE
# VERDAD. El segundo sabor no encuentra ya nada y no dice nada, asi que la
# comprobacion del desarmado sigue viendo una sola linea.
mkdir -p "$F/bin-uni"
printf '#!/bin/sh\necho 0\n'  > "$F/bin-uni/id"
printf '#!/bin/sh\nexit 0\n'  > "$F/bin-uni/systemctl"
chmod +x "$F/bin-uni/id" "$F/bin-uni/systemctl"
for g in grub2-editenv grub-editenv; do
    cat > "$F/bin-uni/$g" <<'EOF'
#!/bin/sh
case "${2:-}" in
    list)  cat "$GRUBENV" 2>/dev/null ;;
    unset) grep -v "^$3=" "$GRUBENV" > "$GRUBENV.tmp" 2>/dev/null
           mv "$GRUBENV.tmp" "$GRUBENV" ;;
esac
EOF
    chmod +x "$F/bin-uni/$g"
done

uni_arma() {  # uni_arma <marca custom.cfg|-> <next_entry|-> <wakealarm> <respaldo bls: si|no>
    rm -rf "$U"
    mkdir -p "$U/bin" "$U/hooks" "$U/units" "$U/logrotate" "$U/state" \
             "$U/energy" "$U/log" "$U/boot" "$U/bls" "$U/sys"
    : > "$U/bin/s5-test"; : > "$U/units/s5-energy-log.service"
    : > "$U/hooks/99y-s5-gpu-pmrt.shutdown"; : > "$U/logrotate/s5-poweroff-fix"
    printf 'una medida que costo una noche\n' > "$U/log/s5-energy.log"
    if [ "$1" = - ]; then : ; else printf '%s\nmenuentry x {}\n' "$1" > "$U/boot/custom.cfg"; fi
    if [ "$2" = - ]; then : > "$U/grubenv"; else printf 'next_entry=%s\n' "$2" > "$U/grubenv"; fi
    printf '%s\n' "$3" > "$U/sys/wakealarm"
    printf 'options root=UUID=x ro rd.driver.blacklist=amdgpu\n' > "$U/bls/e.conf"
    [ "$4" = si ] && { mkdir -p "$U/state/bls-backup"
                       printf 'options root=UUID=x ro\n' > "$U/state/bls-backup/e.conf"; }
    return 0
}

uni_corre() {  # uni_corre [--purge]; deja la salida en $UNIOUT
    # RED DE SEGURIDAD. Si alguna de estas rutas no se pasara, uninstall.sh
    # usaria su valor de produccion y el `rm -rf` del purgado se llevaria
    # /var/lib/s5-test y las medidas de /var/log. Antes de correrlo se
    # comprueba que el /var de mentira existe de verdad.
    [ -n "${U:-}" ] && [ -d "$U/log" ] || {
        echo "ensayo: \$U sin montar; ABORTO antes de correr uninstall.sh" >&2; exit 1; }
    # shellcheck disable=SC2034  # lo leen las condiciones de `uni`, que van por eval
    UNIOUT="$(env PATH="$F/bin-uni:$PATH" GRUBENV="$U/grubenv" \
        BIN="$U/bin" HOOKS="$U/hooks" UNITS="$U/units" LOGROTATE="$U/logrotate" \
        STATEDIR="$U/state" ENERGYDIR="$U/energy" LOGDIR="$U/log" \
        WAKEALARM="$U/sys/wakealarm" GRUBCFGS="$U/boot/custom.cfg" \
        S5_BLS_DIR="$U/bls" S5_CONF="${UNI_CONF:-$U/conf-que-no-existe}" \
        bash "$UNI" "$@" 2>&1)"
}

uni() {  # uni <titulo> <condicion>
    n=$((n+1))
    if eval "$2"; then printf '  [ok]    %s\n' "$1"
    else printf '  [MAL]   %s\n          fallo la condicion: %s\n' "$1" "$2"; malas=$((malas+1)); fi
}

uni_arma '# s5-gpu-politica' s5politica 0 no; uni_corre
uni "custom.cfg de la POLITICA => retirado"        '[ ! -e "$U/boot/custom.cfg" ]'
uni "next_entry=s5politica => desarmado"           '! grep -q next_entry "$U/grubenv"'

uni_arma '# Generado por s5-grub-halt' s5halt 0 no; uni_corre
uni "custom.cfg de s5-grub-halt => retirado (LA QUE NO SE BARRIA)" '[ ! -e "$U/boot/custom.cfg" ]'
uni "next_entry=s5halt => desarmado (LA QUE NO SE BARRIA)"         '! grep -q next_entry "$U/grubenv"'

uni_arma '# custom.cfg de otro' otracosa 0 no; uni_corre
uni "custom.cfg AJENO => NI SE TOCA (barrer de mas si duele)"  '[ -e "$U/boot/custom.cfg" ]'
uni "next_entry ajeno => se respeta"                           'grep -q "^next_entry=otracosa$" "$U/grubenv"'

# S5_GRUB_DIR FUERA DE LOS DOS SABORES ESTANDAR (anadido 2026-08-15). Quien
# ESCRIBE la entrada usa el $GRUB_CUSTOM que descubre s5-descubre-grub, y ese
# obedece a la perilla; la lista de sitios donde BARRER estaba clavada a
# /boot/grub{,2}. Con S5_GRUB_DIR puesto a otro directorio —lo admite el .conf
# de ejemplo— el custom.cfg de un solo uso no lo barria nadie: ni el arranque
# siguiente (la unidad tenia la misma constante en su ConditionPathExists) ni
# esta desinstalacion, que es la que promete dejar la maquina como estaba.
# Misma constante clavada que los BDF de los hooks y el recuento del blindaje.
#
# LA LISTA ESTANDAR AQUI ES LA DE MENTIRA de uni_corre, no /boot: lo que se
# ensaya es que el directorio de la configuracion se AÑADA a la que haya, y
# nombrar el /boot de verdad en un ensayo es justo lo que la red de seguridad de
# uni_corre existe para impedir.
uni_arma '# s5-gpu-politica' s5politica 0 no
mkdir -p "$U/grub-raro"
printf '# s5-gpu-politica\nmenuentry x {}\n' > "$U/grub-raro/custom.cfg"
printf 'S5_GRUB_DIR=%s\n' "$U/grub-raro" > "$U/conf-raro"
UNI_CONF="$U/conf-raro"; uni_corre; UNI_CONF=''
uni "S5_GRUB_DIR a un directorio no estandar => tambien se barre (LA QUE NO SE BARRIA)" \
    '[ ! -e "$U/grub-raro/custom.cfg" ]'
uni "...y sin dejar de barrer el estandar"     '[ ! -e "$U/boot/custom.cfg" ]'

# Y EN EL SITIO DE LA PERILLA TAMPOCO SE BARRE DE MAS: la guarda de la marca
# tiene que valer igual ahi. Es la direccion peligrosa — borrarle a alguien un
# custom.cfg en un directorio que ha configurado el a mano.
uni_arma - - 0 no
mkdir -p "$U/grub-raro"
printf '# custom.cfg de otro\nmenuentry x {}\n' > "$U/grub-raro/custom.cfg"
printf 'S5_GRUB_DIR=%s\n' "$U/grub-raro" > "$U/conf-raro"
UNI_CONF="$U/conf-raro"; uni_corre; UNI_CONF=''
uni "custom.cfg AJENO en el directorio de la perilla => NI SE TOCA" \
    '[ -e "$U/grub-raro/custom.cfg" ]'

# LA UNIDAD DE LIMPIEZA, EN ESTATICO. Es el otro eslabon del mismo defecto y el
# unico que no se puede ensayar ejecutandolo: un fichero de unidad no lee
# configuracion, asi que una ConditionPathExists sobre una ruta de GRUB clavada
# impide que el script —que SI descubre— llegue siquiera a correr. No se puede
# provocar sin arrancar la maquina, asi que se afirma sobre el fichero.
n=$((n+1))
_u="$D/../system/systemd/s5-gpu-politica-cleanup.service"
if grep -qE '^ConditionPathExists=.*grub' "$_u"; then
    printf '  [MAL]   la unidad de limpieza vuelve a condicionarse a una ruta de GRUB clavada\n          %s\n' \
           "$(grep -nE '^ConditionPathExists=.*grub' "$_u" | tr '\n' ' ')"
    malas=$((malas+1))
else
    printf '  [ok]    la unidad de limpieza no se condiciona a una ruta de GRUB clavada (la guarda es del script, que descubre)\n'
fi
unset _u

uni_arma - - 1786000000 no; uni_corre
uni "despertador RTC puesto => desarmado"          '[ "$(cat "$U/sys/wakealarm")" = 0 ]'
uni "...y se dice"                                 'printf %s "$UNIOUT" | grep -q "despertador RTC desarmado"'
uni_arma - - 0 no; uni_corre
uni "despertador ya a cero => callado (regla 27)"  '! printf %s "$UNIOUT" | grep -q "despertador RTC"'

uni_arma - - 0 si; uni_corre
uni "prueba de args armada => entradas de arranque RESTAURADAS" \
    '! grep -q blacklist "$U/bls/e.conf"'
uni "...y el respaldo se retira"                   '[ ! -d "$U/state/bls-backup" ]'

uni_arma - - 0 no; uni_corre
uni "sin prueba armada => las entradas de arranque no se tocan" \
    'grep -q blacklist "$U/bls/e.conf"'

# El caso feo: hay respaldo pero no se puede restaurar. Lo que NO puede pasar es
# que se purgue el respaldo, porque entonces el parche del kernel se queda sin
# vuelta atras.
uni_arma - - 0 si; rm -rf "$U/bls"; uni_corre --purge
uni "no se puede restaurar => AVISA en vez de callarse" \
    'printf %s "$UNIOUT" | grep -q "HABIA UNA PRUEBA DE ARGS ARMADA"'
uni "...y --purge NO se lleva el respaldo (seria irreversible)" \
    '[ -f "$U/state/bls-backup/e.conf" ]'

uni_arma - - 0 no; uni_corre
uni "sin --purge se conservan las medidas"         '[ -f "$U/log/s5-energy.log" ]'
uni "hooks, unidades, binarios y logrotate retirados" \
    '[ ! -e "$U/hooks/99y-s5-gpu-pmrt.shutdown" ] && [ ! -e "$U/units/s5-energy-log.service" ] &&
     [ ! -e "$U/bin/s5-test" ] && [ ! -e "$U/logrotate/s5-poweroff-fix" ]'

uni_arma - - 0 no; uni_corre --purge
uni "--purge SI borra estado y medidas"            '[ ! -e "$U/log/s5-energy.log" ] && [ ! -d "$U/state" ]'

echo
echo "s5-gpu-politica — el salvavidas del caso raro, con limites"
# ANADIDO EL 2026-08-15. Este script nunca se habia ensayado: ni una linea de
# el corria desde este fichero, solo se imitaba a mano el TEXTO que dejaria en
# el log (ver pol_grub() mas arriba). Sus CINCO abortar() y el fallback
# `reboot -f` — la red de seguridad del caso raro, justo donde el proyecto
# promete "todo falla seguro" — tenian CERO disparos: ni en ensayo, ni en
# ningun apagado real (el unico desvio real, forzado a mano, tuvo exito de
# punta a punta y nunca toco una rama de fallo).
#
# LA GPU SE FINGE, NO SE LEE DE VERDAD. pst()/rst() dentro del script leen
# rutas fijas de /sys/bus/pci/devices, que no se pueden montar de mentira sin
# root y sin hardware que fingir. La salida: S5_DESCUBRE apunta a un
# descubridor de mentira que fija GPU a un BDF que no existe en NINGUNA
# maquina (0000:ff:00.0): `cat` sobre su power_state falla siempre y pst()
# devuelve '?', que nunca es D3cold. La dGPU sale "despierta" siempre, en
# cualquier maquina — la rama que SI cae dormida sola (el camino feliz, ~2 W)
# ya tiene evidencia real de sobra (n=4, cuatro noches) y no se puede fingir sin
# sysfs de verdad; lo que faltaba ensayar era todo lo que pasa cuando NO cae.
#
# `mount`, `umount`, `findmnt`, `systemctl` y `reboot` SI son ensayables sin
# tocar el sistema: el script los llama por PATH, nunca por ruta absoluta.
# Shims de mentira los sustituyen SIEMPRE, con PATH reconstruido desde cero
# (`env -i`, como ya hacia grubcaso) para que el `grub2-reboot` o el `mount`
# de VERDAD de esta maquina no se cuelen por detras del PATH de mentira — el
# mismo escape que ya habia costado un caso mal fiado en la seccion de arriba.
#
# LA LINEA MAS PELIGROSA DE TODO EL REPO ESTA AQUI: `exec reboot -f`, con un
# `mount -o remount,ro /` justo antes. Si el PATH de mentira fallara y el
# `reboot` de verdad se colara, esto no fallaria un ensayo: apagaria la
# maquina de quien lo corre. politica_seguro() lo comprueba ANTES de ejecutar
# nada — aborta el ensayo entero si mount/umount/systemctl/reboot no resuelven
# a un shim dentro de $F — igual que uni_corre() aborta si $U/log no existe.
#
# S5_POLITICA_LOG desvia el log de la rama armada (arriba en el propio script,
# 2026-08-15): sin eso, el unico ensayo que llega a armar de verdad escribiria
# en /var/log/s5-shutdown-pci.log, el log de PRODUCCION — el mismo error que
# la cabecera del propio script ya cuenta que costo un falso FALLO en 2026-08-11.
POL="$D/../system/bin/s5-gpu-politica"
DGR="$D/../system/bin/s5-descubre-grub"   # la version del REPO, no la instalada
POLBASH="$BASH"

politica_seguro() {  # politica_seguro <PATH a probar> -> aborta el ensayo si algo resuelve fuera de $F
    local c old="$PATH"
    PATH="$1"
    for c in mount umount systemctl reboot; do
        case "$(command -v "$c" 2>/dev/null)" in
            "$F"/*) ;;
            *) PATH="$old"
               echo "ensayo: $c no resuelve a un shim de pruebas (PATH=$1); ABORTO sin correr nada" >&2
               exit 1 ;;
        esac
    done
    PATH="$old"
}

mkdir -p "$F/bin-pol-base"
for _c in awk sleep date grep chmod sync cat true false; do
    _p="$(command -v "$_c" 2>/dev/null)" && ln -sf "$_p" "$F/bin-pol-base/$_c"
done
unset _c _p

mkdir -p "$F/bin-pol"
cat > "$F/bin-pol/findmnt" <<'EOF'
#!/bin/sh
# invocado como: findmnt -no OPTIONS <punto>
[ "$3" = / ] && { echo "${POL_ROOTSTATE:-rw}"; exit 0; }
case "$(cat "$POL_BOOTSTATE" 2>/dev/null)" in
    rw) echo rw ;;
    ro) echo ro ;;
    *)  exit 1 ;;
esac
EOF
cat > "$F/bin-pol/mount" <<'EOF'
#!/bin/sh
echo "mount $*" >> "${POL_MNTLOG:-/dev/null}"
case "$*" in
    /boot)
        [ "${POL_MOUNT_FALLA:-0}" = 1 ] && exit 1
        echo rw > "$POL_BOOTSTATE"; exit 0 ;;
    "-o remount,rw /boot")
        [ "${POL_MOUNT_FALLA:-0}" = 1 ] && exit 1
        echo rw > "$POL_BOOTSTATE"; exit 0 ;;
    "-o remount,ro /") exit 0 ;;
    *) exit 1 ;;
esac
EOF
cat > "$F/bin-pol/umount" <<'EOF'
#!/bin/sh
echo "umount $*" >> "${POL_MNTLOG:-/dev/null}"
echo DESMONTADO > "$POL_BOOTSTATE"
exit 0
EOF
cat > "$F/bin-pol/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >> "${POL_SYSTEMCTLLOG:-/dev/null}"
exit 0
EOF
cat > "$F/bin-pol/reboot" <<'EOF'
#!/bin/sh
echo "reboot $*" >> "${POL_REBOOTLOG:-/dev/null}"
exit 0
EOF
chmod +x "$F/bin-pol/"*
mkdir -p "$F/bin-pol-nofindmnt"
cp "$F/bin-pol/mount" "$F/bin-pol/umount" "$F/bin-pol/systemctl" "$F/bin-pol/reboot" "$F/bin-pol-nofindmnt/"

mkdir -p "$F/bin-pol-grub-full"
cat > "$F/bin-pol-grub-full/grub2-reboot" <<'EOF'
#!/bin/sh
printf 'next_entry=%s\n' "$1" > "$GRUBENV"
EOF
cat > "$F/bin-pol-grub-full/grub2-editenv" <<'EOF'
#!/bin/sh
[ "${2:-}" = list ] && cat "$GRUBENV" 2>/dev/null
exit 0
EOF
chmod +x "$F/bin-pol-grub-full/"*
mkdir -p "$F/bin-pol-grub-solo-reboot"
cp "$F/bin-pol-grub-full/grub2-reboot" "$F/bin-pol-grub-solo-reboot/"

FULL_OK="$F/bin-pol:$F/bin-pol-grub-full:$F/bin-pol-base"
FULL_SOLO_REBOOT="$F/bin-pol:$F/bin-pol-grub-solo-reboot:$F/bin-pol-base"
FULL_SIN_GRUBTOOLS="$F/bin-pol:$F/bin-pol-base"
NOFINDMNT="$F/bin-pol-nofindmnt:$F/bin-pol-grub-full:$F/bin-pol-base"

cat > "$F/pol-descubre-gpu" <<'EOF'
#!/bin/sh
# BDF que no existe en NINGUNA maquina: pst()/rst() siempre dan '?', nunca D3cold
GPU='0000:ff:00.0'; AUDIO=''; BRIDGE=''
EOF
cat > "$F/pol-descubre-sin-gpu" <<'EOF'
#!/bin/sh
:
EOF
chmod +x "$F/pol-descubre-gpu" "$F/pol-descubre-sin-gpu"

# LA RAMA DE SYSTEMD-BOOT SE DOBLA. La politica, cuando no hay GRUB utilizable,
# llama a `s5-politica-boot` (la rama del caso raro en una maquina con
# systemd-boot). En un ensayo eso seria el binario DE VERDAD en una maquina que
# tenga la rama instalada —y un ensayo no llama a binarios de verdad, menos a uno
# que arma entradas de arranque—. Se le da un doble que dice que no pudo, que es
# justo el caso que estas pruebas miran: que la politica siga por donde seguia.
# Un caso puede sobreescribirlo pasando S5_POLITICA_BOOT=... entre sus VAR=val,
# porque van despues en la linea de `env`.
cat > "$F/pol-politica-boot-doble" <<'EOF'
#!/bin/sh
echo "DOBLE s5-politica-boot: no puedo armar (esto es un ensayo)"
exit 1
EOF
chmod +x "$F/pol-politica-boot-doble"
POLITICA_BOOT_DOBLE="$F/pol-politica-boot-doble"

politica_arma() {  # politica_arma <estado inicial de /boot: DESMONTADO|rw|ro>
    rm -rf "$F/pol"; mkdir -p "$F/pol"
    echo "$1" > "$F/pol/boot-state"
}
politica_corre() {  # politica_corre <PATH> <VAR=val>...
    local ruta="$1"; shift
    politica_seguro "$ruta"
    env -i HOME="$HOME" PATH="$ruta" \
        S5_CONF=/dev/null S5_DESCUBRE_GRUB="$DGR" \
        S5_POLITICA_BOOT="$POLITICA_BOOT_DOBLE" \
        S5_POLITICA_LOG="$F/pol/log" \
        POL_BOOTSTATE="$F/pol/boot-state" POL_MNTLOG="$F/pol/mount.log" \
        POL_SYSTEMCTLLOG="$F/pol/systemctl.log" POL_REBOOTLOG="$F/pol/reboot.log" \
        "$@" "$POLBASH" "$POL" >"$F/pol/stdout" 2>&1
    POLOUT="$(cat "$F/pol/log" 2>/dev/null; echo; cat "$F/pol/stdout" 2>/dev/null)"
}
politica() {  # politica <titulo> <condicion evaluable, usa $POLOUT y $F>
    n=$((n+1))
    if eval "$2"; then printf '  [ok]    %s\n' "$1"
    else printf '  [MAL]   %s\n          fallo la condicion: %s\n          POLOUT: %s\n' "$1" "$2" "$POLOUT"
         malas=$((malas+1)); fi
}

politica_arma DESMONTADO
politica_corre "$FULL_SIN_GRUBTOOLS" S5_DESCUBRE="$F/pol-descubre-sin-gpu" S5_POLITICA_MAXWAIT=0
politica "sin dGPU localizada => no hay nada que decidir, apagado normal" \
    'printf %s "$POLOUT" | grep -q "POLITICA sin dGPU localizada"'

politica_arma DESMONTADO
politica_corre "$FULL_OK" S5_DESCUBRE="$F/pol-descubre-gpu" S5_POLITICA_MAXWAIT=0 \
    S5_GRUB_DIRS="$F/fedora/grub2" POL_MOUNT_FALLA=1
politica "abortar 1/5: no consigo /boot montado en rw" \
    'printf %s "$POLOUT" | grep -q "POLITICA ABORTADA: no consigo /boot montado en rw"'

politica_arma DESMONTADO
politica_corre "$FULL_SIN_GRUBTOOLS" S5_DESCUBRE="$F/pol-descubre-gpu" S5_POLITICA_MAXWAIT=0 \
    S5_GRUB_DIRS="$F/fedora/grub2"
politica "abortar 2/5: no encuentro grub2-reboot ni grub-reboot" \
    'printf %s "$POLOUT" | grep -q "POLITICA ABORTADA: no encuentro grub2-reboot ni grub-reboot"'

politica_arma DESMONTADO
politica_corre "$FULL_SOLO_REBOOT" S5_DESCUBRE="$F/pol-descubre-gpu" S5_POLITICA_MAXWAIT=0 \
    S5_GRUB_DIRS="$F/fedora/grub2"
politica "abortar 3/5: no encuentro grub2-editenv ni grub-editenv" \
    'printf %s "$POLOUT" | grep -q "POLITICA ABORTADA: no encuentro grub2-editenv ni grub-editenv"'

politica_arma DESMONTADO
politica_corre "$FULL_OK" S5_DESCUBRE="$F/pol-descubre-gpu" S5_POLITICA_MAXWAIT=0 \
    S5_GRUB_DIRS="$F/vacio/grub"
politica "abortar 4/5: no encuentro el directorio de GRUB" \
    'printf %s "$POLOUT" | grep -q "POLITICA ABORTADA: no encuentro el directorio de GRUB"'

mkdir -p "$F/pol-grub-ajeno/grub2"
: > "$F/pol-grub-ajeno/grub2/grubenv"
printf '# no somos nosotros\nmenuentry x {}\n' > "$F/pol-grub-ajeno/grub2/custom.cfg"
politica_arma DESMONTADO
politica_corre "$FULL_OK" S5_DESCUBRE="$F/pol-descubre-gpu" S5_POLITICA_MAXWAIT=0 \
    S5_GRUB_DIRS="$F/pol-grub-ajeno/grub2"
politica "abortar 5/5: ya hay un custom.cfg que no es nuestro; no lo piso" \
    'printf %s "$POLOUT" | grep -q "POLITICA ABORTADA: ya hay un custom.cfg que no es nuestro" &&
     grep -q "no somos nosotros" "$F/pol-grub-ajeno/grub2/custom.cfg"'

politica_arma ro
mkdir -p "$F/pol-grub-ro/grub2"; : > "$F/pol-grub-ro/grub2/grubenv"
politica_corre "$FULL_OK" S5_DESCUBRE="$F/pol-descubre-gpu" S5_POLITICA_MAXWAIT=0 \
    S5_GRUB_DIRS="$F/pol-grub-ro/grub2"
politica "asegurar_boot: estaba en ro, se remonta en rw" \
    'printf %s "$POLOUT" | grep -q "POLITICA /boot: estaba en ro, remontado en rw"'

politica_arma rw
mkdir -p "$F/pol-grub-rw/grub2"; : > "$F/pol-grub-rw/grub2/grubenv"
politica_corre "$FULL_OK" S5_DESCUBRE="$F/pol-descubre-gpu" S5_POLITICA_MAXWAIT=0 \
    S5_GRUB_DIRS="$F/pol-grub-rw/grub2"
politica "asegurar_boot: ya estaba en rw, no se toca (no se llama a mount)" \
    'printf %s "$POLOUT" | grep -q "POLITICA /boot: ya estaba montado en rw, no lo toco" &&
     [ ! -s "$F/pol/mount.log" ]'

politica_arma DESMONTADO
politica_corre "$NOFINDMNT" S5_DESCUBRE="$F/pol-descubre-gpu" S5_POLITICA_MAXWAIT=0 \
    S5_GRUB_DIRS="$F/fedora/grub2"
politica "asegurar_boot: sin findmnt, el testigo esta roto => aborta seguro" \
    'printf %s "$POLOUT" | grep -q "POLITICA ABORTADA: no consigo /boot montado en rw (esta: SIN-FINDMNT)"'

# LA RAMA ARMADA DE VERDAD: custom.cfg real, grub2-reboot real, next_entry real.
# Con systemctl shimado (nunca "vuelve" de verdad, como el de produccion cuando
# funciona), el script SIEMPRE cae al fallback `reboot -f` tras 3 s — no hay
# forma de fingir con un shim que el `systemctl --force reboot` de verdad
# hubiera cortado el proceso ahi mismo. Este caso ensaya de una vez la escritura
# real Y el fallback, con GRUBENV apuntando a un fichero de mentira propio.
mkdir -p "$F/pol-grub-armado/grub2"
GRUBENV="$F/pol-grub-armado/grub2/grubenv"
: > "$GRUBENV"
export GRUBENV
politica_arma DESMONTADO
politica_corre "$FULL_OK" S5_DESCUBRE="$F/pol-descubre-gpu" S5_POLITICA_MAXWAIT=0 \
    S5_GRUB_DIRS="$F/pol-grub-armado/grub2" GRUBENV="$GRUBENV"
unset GRUBENV
politica "armado: custom.cfg escrito con nuestra marca" \
    'grep -q "# s5-gpu-politica" "$F/pol-grub-armado/grub2/custom.cfg"'
politica "armado: next_entry quedo grabado" \
    'grep -q "^next_entry=s5politica$" "$F/pol-grub-armado/grub2/grubenv"'
politica "armado: la politica se dio por armada en el log" \
    'printf %s "$POLOUT" | grep -q "POLITICA armada"'
politica "fallback: systemctl --force reboot no vuelve (shim) => cae a reboot -f" \
    '[ -s "$F/pol/reboot.log" ] && grep -q "^reboot -f$" "$F/pol/reboot.log"'
politica "fallback: antes de reboot -f se intenta remontar / en ro" \
    'grep -q "remount,ro /" "$F/pol/mount.log"'
politica "fallback: se registra en el log que systemctl no dio la vuelta" \
    'printf %s "$POLOUT" | grep -q "systemctl --force reboot no dio la vuelta"'

echo
echo "el ancla DE VERDAD (lo unico que sigue dependiendo de esta maquina)"
# Todo lo de arriba corre contra un journalctl de mentira, asi que la invocacion
# REAL hay que comprobarla aparte: que `journalctl -b -1 -n1 -o short-unix`
# —tal cual la hace el verificador en produccion— siga dando un epoch
# utilizable con el systemd que haya instalado. Es la unica rama que se salta si
# la maquina no tiene arranque anterior, y saltarla NO deja sin ensayar ninguna
# rama del verificador.
n=$((n+1))
if [ "$JOURNAL_REAL" = 1 ]; then
    if [ "$FIN" -gt 1000000000 ] && [ "$FIN" -lt "$(date +%s)" ]; then
        printf '  [ok]    `journalctl -b -1` da un ancla usable: %s\n' "$(f "$FIN")"
    else
        printf '  [MAL]   `journalctl -b -1` dio un epoch imposible: %s\n' "$FIN"
        malas=$((malas+1))
    fi
else
    salta '`journalctl -b -1`: esta maquina no tiene arranque anterior'
    printf '          (las ramas de 9ter de arriba NO dependen de esto: llevan ancla de mentira)\n'
fi

echo
echo "=== $((n-malas-saltadas))/$((n-saltadas)) ramas correctas ==="
if [ "$saltadas" != 0 ]; then
    printf '=== %s saltada(s), y por que:\n' "$saltadas"
    printf '    - %s\n' "${SALTOS[@]}"
fi
[ "$malas" = 0 ] && rm -rf "$F"
exit $((malas > 0))

// SPDX-License-Identifier: GPL-2.0
/*
 * s5_pmrt_arm — PASO 1 de la via limpia (2026-08-10).
 *
 * QUE HACE: justo antes de que systemd llame a reboot(POWEROFF), blinda el
 * subarbol de la discreta contra las DOS cosas que `pci_device_shutdown()` hace
 * y que lo devuelven a D0:
 *
 *   (ESPERA_D3COLD) `pm_request_idle()` + espera acotada a que el subarbol se
 *       asiente (`wait_ms`, 0 = desactivado por defecto) ANTES de (a) y (b).
 *       Blindar una GPU DESPIERTA la congela despierta: con disable_depth > 0 el
 *       nucleo ya no la suspende tampoco, el riel no se corta y el S5 vuelve a
 *       costar ~18-20 W. Ver asentar(), que explica por que esto va en tres
 *       fases y no dentro del bucle que blinda.
 *
 *       Por que 0 por defecto: en el flujo de esta casa la politica ya espero
 *       hasta 90 s y el gancho 20 s mas antes de que el modulo cargue, asi que
 *       aqui no queda nada que ganar — y si 5 s que perder en el caso raro. Se
 *       enciende con wait_ms=<ms> (por ejemplo desde el fichero de override de
 *       parametros que ya existe) para maquinas donde la GPU llega despierta por
 *       otro motivo, que es el caso que midio la aportacion.
 *
 *   (a) `pm_runtime_resume(dev)`  -> se rebota con -EACCES gracias a
 *       `__pm_runtime_disable(dev, false)`. VALIDADO EN CALIENTE EN EL PASO 0
 *       (2026-08-10 20:26): deja el dispositivo en D3cold, rc=-13, y el testigo
 *       duro `activo_ms` no se movio ni un ms.
 *
 *   (b) `drv->shutdown(pci_dev)`  -> se pone a NULL para los drivers que lo
 *       definen. En la dGPU eso es `nv_pci_shutdown`, que llama a
 *       `nv_pci_remove_helper`, o sea la via de teardown del driver: es
 *       exactamente lo que el ensayo del 2026-08-10 18:56 vio DESPERTAR el
 *       subarbol entero. Saltarselo REDUCE el riesgo, no lo aumenta: la
 *       alternativa es ejecutarlo contra una GPU en D3cold.
 *
 * A diferencia del arnes de PM1a_CNT, aqui el apagado lo hace systemd por el
 * camino NORMAL, con `_PTS(5)` y con `device_shutdown()`. Lo unico que cambia
 * es que la dGPU no se despierta. Si la medida sale ~2 W, se retira el modulo
 * PM1a entero.
 *
 * PRUDENCIA DELIBERADA: `struct pci_driver` es POR DRIVER, no por dispositivo,
 * asi que poner su `.shutdown` a NULL afecta a todos los dispositivos de ese
 * driver. Por eso solo se toca en una lista blanca (`nvidia`, `snd_hda_intel`)
 * y NO en `pcieport`, que gobierna todos los puertos de la maquina. El bridge
 * si recibe el disable de runtime PM, que es inofensivo y por dispositivo.
 *
 * arm=0 => ensayo en seco: informa de todo y NO toca nada.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/pci.h>
#include <linux/pm_runtime.h>
#include <linux/delay.h>
#include <linux/jiffies.h>

#define MAX_DEVS 8
#define ESPERA_POLL_MS 100

/*
 * SIN LISTA POR DEFECTO, A PROPOSITO. Aqui habia clavados los tres BDF de la
 * maquina donde se diagnostico esto. El hook siempre pasa `devs=` explicito con
 * lo que descubre s5-descubre-dgpu, asi que en el camino normal no cambia nada;
 * pero un `modprobe s5_pmrt_arm arm=1` a mano en OTRA maquina aplicaba el
 * blindaje a lo que hubiera en esas direcciones, que bien puede ser el NVMe.
 * Ese es exactamente el peligro que s5-descubre-dgpu existe para eliminar, y no
 * tenia sentido dejarlo entrar por la puerta de atras.
 */
static char *devs = "";
static char *noshut = "nvidia,snd_hda_intel";
static int arm;
static unsigned int wait_ms;

/*
 * La lista de dispositivos RESUELTA, que comparten las tres fases de init: A la
 * llena, B espera a que se asiente, C la blinda. Antes se resolvia y se blindaba
 * en el mismo bucle, y por eso la espera no podia funcionar (ver asentar()).
 */
static struct pci_dev *resueltos[MAX_DEVS];
static int n_resueltos;

module_param(devs, charp, 0444);
MODULE_PARM_DESC(devs, "BDFs separados por comas (OBLIGATORIO: sin el no se blinda nada)");
module_param(noshut, charp, 0444);
MODULE_PARM_DESC(noshut, "lista blanca de drivers a los que anular .shutdown");
module_param(arm, int, 0444);
MODULE_PARM_DESC(arm, "0 = ensayo en seco; 1 = actua");
module_param(wait_ms, uint, 0444);
MODULE_PARM_DESC(wait_ms, "ms de espera a que el subarbol se asiente antes de blindar (0 = no esperar, por defecto)");

static const char *rpm_name(enum rpm_status s)
{
	switch (s) {
	case RPM_ACTIVE:	return "active";
	case RPM_RESUMING:	return "resuming";
	case RPM_SUSPENDED:	return "suspended";
	case RPM_SUSPENDING:	return "suspending";
	default:		return "?";
	}
}

static bool en_lista_blanca(const char *drv)
{
	const char *p = noshut;
	size_t n = strlen(drv);

	while (p && *p) {
		if (!strncmp(p, drv, n) && (p[n] == ',' || p[n] == '\0'))
			return true;
		p = strchr(p, ',');
		if (p)
			p++;
	}
	return false;
}

static void informe(const char *cuando, const char *bdf, struct pci_dev *pdev)
{
	struct device *d = &pdev->dev;

	pr_emerg("s5-pmrt-arm: %s %-14s D=%s runtime=%s disable_depth=%d\n",
		 cuando, bdf, pci_power_name(pdev->current_state),
		 rpm_name(d->power.runtime_status), d->power.disable_depth);
}

/*
 * ESPERA_D3COLD — DEJARLA DORMIR ANTES DE BLINDARLA, EN TRES FASES.
 *
 * El gancho de apagado espera en userspace a que la dGPU baje a D3cold, pero si
 * el plazo vence blinda igualmente; y blindar una GPU despierta la CONGELA
 * despierta, asi que ese S5 cuesta otra vez los ~18-20 W. Por eso el modulo pide
 * el idle al nucleo (`pm_request_idle()`, la misma evaluacion que dispara el
 * `pm_runtime_put()` de un driver) y espera a que el subarbol se asiente.
 *
 * LAS FASES NO SON ESTILO: LA PRIMERA VERSION DE ESTO NO FUNCIONABA CON LA LISTA
 * QUE GENERA s5-descubre-dgpu (puente, GPU, audio), por dos motivos que se
 * refuerzan:
 *
 *   - Un puerto PCI NO puede dormir mientras un hijo suyo este despierto, asi que
 *     esperar por el es esperar por definicion. Al hijo que se duerme le avisa el
 *     nucleo solo: rpm_suspend() termina con rpm_idle(parent).
 *   - Peor todavia: `__pm_runtime_disable()` sobre el puente lo deja despierto Y
 *     sin permiso para suspenderse, y con el puente asi la GPU ya no puede
 *     alcanzar D3cold, porque D3cold es que le hayan quitado la alimentacion y
 *     quien la quita es el puerto. Blindar el puente antes de que la GPU duerma
 *     hace IMPOSIBLE lo que esta espera viene a conseguir.
 *
 * Con un plazo COMUN y el bucle de blindaje de por medio, el presupuesto se lo
 * comia el puente y la GPU no llegaba a recibir ni una peticion de idle. De ahi
 * las tres fases: A resuelve y valida la lista, B pide idle a TODOS y espera al
 * CONJUNTO, C blinda. Solo B consume plazo, y lo consume una vez para toda la
 * lista (un plazo por dispositivo multiplicaria la tardanza del peor apagado por
 * el numero de BDF).
 *
 * Nada se fuerza: si un driver mantiene una referencia, el dispositivo se queda
 * despierto, se dice en el log y se blinda igual que antes — el peor caso sigue
 * siendo el de siempre, nunca peor. Con wait_ms=0 (el defecto) la fase B no
 * existe y todo queda como estaba antes de esta aportacion.
 */
static bool es_display(struct pci_dev *pdev)
{
	unsigned int c = pdev->class >> 8;	/* 24 bits -> las macros de 16 de pci_ids.h */

	return c == PCI_CLASS_DISPLAY_VGA || c == PCI_CLASS_DISPLAY_3D ||
	       c == PCI_CLASS_DISPLAY_OTHER;
}

/*
 * Asentado = ningun BDF de la lista en D0 y, si hay una display, esa en D3cold:
 * D3cold es el unico estado que significa "riel cortado"; D3hot sigue alimentado.
 */
static bool asentado(void)
{
	int i;

	for (i = 0; i < n_resueltos; i++) {
		if (es_display(resueltos[i])) {
			if (resueltos[i]->current_state != PCI_D3cold)
				return false;
		} else if (resueltos[i]->current_state == PCI_D0) {
			return false;
		}
	}
	return true;
}

static unsigned int asentar(void)
{
	unsigned long fin = jiffies + msecs_to_jiffies(wait_ms);
	unsigned int esperado = 0;
	int i;

	if (!wait_ms || asentado())
		return 0;

	pr_emerg("s5-pmrt-arm: ESPERA_D3COLD la lista no esta asentada: se pide idle a %d BDF y se espera hasta %u ms\n",
		 n_resueltos, wait_ms);

	/* fase B: una peticion por dispositivo, en cualquier orden */
	for (i = 0; i < n_resueltos; i++)
		pm_request_idle(&resueltos[i]->dev);

	while (time_before(jiffies, fin)) {
		msleep(ESPERA_POLL_MS);
		esperado += ESPERA_POLL_MS;

		if (asentado()) {
			pr_emerg("s5-pmrt-arm: ESPERA_D3COLD asentado tras %u ms\n", esperado);
			return esperado;
		}
	}

	pr_emerg("s5-pmrt-arm: ESPERA_D3COLD no se asento en %u ms:", esperado);
	for (i = 0; i < n_resueltos; i++)
		pr_cont(" %s=%s", pci_name(resueltos[i]),
			pci_power_name(resueltos[i]->current_state));
	pr_cont(" => se blinda igual\n");
	return esperado;
}

static int __init s5_pmrt_arm_init(void)
{
	char *copia, *resto, *bdf;
	int hechos = 0, anulados = 0, i;
	unsigned int esperado_ms = 0;

	pr_emerg("s5-pmrt-arm: ===== arm=%d devs=%s noshut=%s wait_ms=%u\n",
		 arm, devs, noshut, wait_ms);

	/*
	 * Sin lista no hay nada que blindar, y con arm=1 es ademas una llamada
	 * mal hecha: se rechaza en vez de cargar sin efecto, para que quien la
	 * haga se entere. Con arm=0 (el defecto) basta con decirlo y salir: un
	 * ensayo en seco sin lista es inofensivo.
	 */
	if (!devs || !*devs) {
		pr_emerg("s5-pmrt-arm: devs= vacio: no hay nada que blindar. Pasa la lista con devs=<BDF,...> (la calcula s5-descubre-dgpu)\n");
		return arm ? -EINVAL : 0;
	}

	copia = kstrdup(devs, GFP_KERNEL);
	if (!copia)
		return -ENOMEM;
	resto = copia;

	/* ---- fase A: resolver y validar la lista, sin tocar nada todavia ---- */
	while ((bdf = strsep(&resto, ",")) != NULL) {
		unsigned int dom, bus, slot, fn;
		struct pci_dev *pdev;

		if (!*bdf)
			continue;
		if (n_resueltos >= MAX_DEVS) {
			pr_emerg("s5-pmrt-arm: mas de %d BDF en devs=; se ignora el resto\n",
				 MAX_DEVS);
			break;
		}
		if (sscanf(bdf, "%x:%x:%x.%x", &dom, &bus, &slot, &fn) != 4) {
			pr_emerg("s5-pmrt-arm: BDF ilegible '%s'\n", bdf);
			continue;
		}
		pdev = pci_get_domain_bus_and_slot(dom, bus, PCI_DEVFN(slot, fn));
		if (!pdev) {
			pr_emerg("s5-pmrt-arm: no existe %s\n", bdf);
			continue;
		}

		informe("ANTES ", bdf, pdev);
		resueltos[n_resueltos++] = pdev;
	}
	kfree(copia);

	/*
	 * ---- fase B: pedir idle y esperar a que el subarbol se asiente ----
	 * Va ANTES de blindar nada: es la unica forma de que la GPU pueda dormir
	 * (ver asentar()).
	 */
	if (arm && n_resueltos)
		esperado_ms = asentar();

	/* ---- fase C: blindar ---- */
	for (i = 0; i < n_resueltos; i++) {
		struct pci_dev *pdev = resueltos[i];
		struct pci_driver *drv = pdev->driver;
		const char *dname = drv ? drv->name : "(ninguno)";
		const char *nom = pci_name(pdev);

		if (!arm) {
			pr_emerg("s5-pmrt-arm: SECO  %-14s driver=%s shutdown=%s lista_blanca=%s\n",
				 nom, dname,
				 (drv && drv->shutdown) ? "SI" : "no",
				 (drv && en_lista_blanca(dname)) ? "SI" : "no");
			continue;
		}

		/* (a) que el pm_runtime_resume() del apagado rebote */
		__pm_runtime_disable(&pdev->dev, false);
		hechos++;

		/* (b) que no se ejecute el teardown del driver */
		if (drv && drv->shutdown && en_lista_blanca(dname)) {
			drv->shutdown = NULL;
			anulados++;
			pr_emerg("s5-pmrt-arm: %-14s .shutdown de '%s' ANULADO\n", nom, dname);
		} else if (drv && drv->shutdown) {
			pr_emerg("s5-pmrt-arm: %-14s .shutdown de '%s' SE RESPETA (fuera de la lista blanca)\n",
				 nom, dname);
		}

		informe("TRAS  ", nom, pdev);
	}

	/*
	 * Testigo de ESPERA_D3COLD, en linea propia y NUNCA dentro de la linea FIN: hay
	 * herramientas (s5-mitigacion-check) que la parsean con
	 * `FIN +disable=([0-9]+) +shutdown_anulados=([0-9]+)` y anadirle campos
	 * detras rompe esa lectura.
	 */
	if (arm)
		pr_emerg("s5-pmrt-arm: ESPERA_D3COLD total=%u ms (wait_ms=%u)\n",
			 esperado_ms, wait_ms);
	pr_emerg("s5-pmrt-arm: FIN  disable=%d shutdown_anulados=%d  => systemd apaga por el camino NORMAL\n",
		 hechos, anulados);

	/* las referencias se sueltan al final: la fase B necesita los pdev vivos */
	for (i = 0; i < n_resueltos; i++)
		pci_dev_put(resueltos[i]);
	n_resueltos = 0;
	return 0;
}

static void __exit s5_pmrt_arm_exit(void) { }

module_init(s5_pmrt_arm_init);
module_exit(s5_pmrt_arm_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Paso 1: blinda el subarbol de la dGPU contra pci_device_shutdown()");

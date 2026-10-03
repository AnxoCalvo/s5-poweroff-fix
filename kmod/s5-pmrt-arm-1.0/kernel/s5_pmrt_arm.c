// SPDX-License-Identifier: GPL-2.0
/*
 * s5_pmrt_arm — PASO 1 de la via limpia (2026-08-10).
 *
 * QUE HACE: justo antes de que systemd llame a reboot(POWEROFF), blinda el
 * subarbol de la discreta contra las DOS cosas que `pci_device_shutdown()` hace
 * y que lo devuelven a D0:
 *
 *   (ESPERA_D3COLD) `pm_request_idle()` + espera acotada a D3cold (`wait_ms`,
 *       5 s por defecto) ANTES de (a) y (b). Blindar una GPU DESPIERTA la
 *       congela despierta: con disable_depth > 0 el nucleo ya no la suspende
 *       tampoco, el riel no se corta y el S5 vuelve a costar ~18-20 W. No es
 *       teorico — en la maquina de la aportacion (OMEN 16-ap0xxx, 2026-10-03)
 *       la discreta seguia en D0 seis segundos despues de que userspace la
 *       soltara, sin nadie que la tuviera abierta: hay drivers que no la
 *       suspenden solos. Ver espera_d3cold().
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
static unsigned int wait_ms = 5000;

module_param(devs, charp, 0444);
MODULE_PARM_DESC(devs, "BDFs separados por comas (OBLIGATORIO: sin el no se blinda nada)");
module_param(noshut, charp, 0444);
MODULE_PARM_DESC(noshut, "lista blanca de drivers a los que anular .shutdown");
module_param(arm, int, 0444);
MODULE_PARM_DESC(arm, "0 = ensayo en seco; 1 = actua");
module_param(wait_ms, uint, 0444);
MODULE_PARM_DESC(wait_ms, "ms de espera a D3cold antes de blindar cada BDF (0 = no esperar)");

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
 * ESPERA_D3COLD — ESPERA ACTIVA ANTES DE BLINDAR.
 *
 * El gancho de apagado espera en userspace a que la dGPU baje a D3cold, pero si
 * el plazo vence blinda igualmente; y blindar una GPU despierta la CONGELA
 * despierta, asi que ese S5 cuesta otra vez los ~18-20 W. No es hipotetico: en
 * la maquina de la aportacion (OMEN 16-ap0xxx, 2026-10-03) la discreta seguia
 * en D0 seis segundos despues de que userspace la soltara, SIN nadie que la
 * tuviera abierta — hay drivers que no la suspenden solos.
 *
 * Aqui se le PIDE el idle al nucleo (`pm_request_idle()`, la misma evaluacion
 * que dispara el `pm_runtime_put()` de un driver) y se sondea hasta que el
 * dispositivo reporta D3cold o se agota el plazo comun (`wait_ms`). D3cold es
 * el unico estado que significa "riel cortado"; D3hot sigue alimentado.
 *
 * Nada se fuerza: si un driver mantiene una referencia, el dispositivo se queda
 * despierto, se dice en el log y se blinda igual que antes — el peor caso sigue
 * siendo el de siempre, nunca peor. Cuando ya esta en D3cold no se espera nada:
 * la funcion vuelve sin tocar el reloj.
 *
 * TIENE QUE IR ANTES DE __pm_runtime_disable(): con disable_depth > 0 el nucleo
 * ya no suspende al dispositivo tampoco, o sea que deshabilitar el runtime PM
 * con la GPU despierta es justo lo que impide que el riel se corte.
 */
static unsigned int espera_d3cold(const char *bdf, struct pci_dev *pdev,
				  unsigned long fin)
{
	pci_power_t est = pdev->current_state;
	unsigned int esperado = 0;

	if (est == PCI_D3cold || !wait_ms)
		return 0;

	pr_emerg("s5-pmrt-arm: %-14s esta en %s, no dormido: se pide idle y se espera a D3cold\n",
		 bdf, pci_power_name(est));

	while (time_before(jiffies, fin)) {
		pm_request_idle(&pdev->dev);
		msleep(ESPERA_POLL_MS);
		esperado += ESPERA_POLL_MS;

		if (pdev->current_state == PCI_D3cold) {
			pr_emerg("s5-pmrt-arm: %-14s D3cold tras %u ms\n",
				 bdf, esperado);
			return esperado;
		}
		if (pdev->current_state != est) {
			est = pdev->current_state;
			pr_emerg("s5-pmrt-arm: %-14s ahora %s (%u ms)\n",
				 bdf, pci_power_name(est), esperado);
		}
	}

	pr_emerg("s5-pmrt-arm: %-14s sigue en %s tras %u ms: no se espera mas, se blinda igual\n",
		 bdf, pci_power_name(pdev->current_state), esperado);
	return esperado;
}

static int __init s5_pmrt_arm_init(void)
{
	char *copia, *resto, *bdf;
	int hechos = 0, anulados = 0;
	unsigned int esperado_ms = 0;
	unsigned long fin;

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

	/*
	 * Plazo COMUN para toda la lista, no uno por dispositivo: la topologia
	 * viene ordenada de hijo a padre (dGPU, audio, puente) y el puente solo
	 * puede dormir cuando sus hijos ya duermen, asi que esperar por separado
	 * multiplicaria la tardanza del peor apagado por el numero de BDF.
	 */
	fin = jiffies + msecs_to_jiffies(wait_ms);

	while ((bdf = strsep(&resto, ",")) != NULL) {
		unsigned int dom, bus, slot, fn;
		struct pci_dev *pdev;
		struct pci_driver *drv;
		const char *dname;

		if (!*bdf)
			continue;
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

		drv = pdev->driver;
		dname = drv ? drv->name : "(ninguno)";

		if (!arm) {
			pr_emerg("s5-pmrt-arm: SECO  %-14s driver=%s shutdown=%s lista_blanca=%s\n",
				 bdf, dname,
				 (drv && drv->shutdown) ? "SI" : "no",
				 (drv && en_lista_blanca(dname)) ? "SI" : "no");
			pci_dev_put(pdev);
			continue;
		}

		/*
		 * primero dormirla, y solo despues blindarla: con el runtime PM
		 * deshabilitado el nucleo ya no la suspende, asi que blindar una
		 * GPU despierta la deja despierta para todo el S5
		 * (ESPERA_D3COLD, ver arriba).
		 */
		esperado_ms += espera_d3cold(bdf, pdev, fin);

		/* (a) que el pm_runtime_resume() del apagado rebote */
		__pm_runtime_disable(&pdev->dev, false);
		hechos++;

		/* (b) que no se ejecute el teardown del driver */
		if (drv && drv->shutdown && en_lista_blanca(dname)) {
			drv->shutdown = NULL;
			anulados++;
			pr_emerg("s5-pmrt-arm: %-14s .shutdown de '%s' ANULADO\n", bdf, dname);
		} else if (drv && drv->shutdown) {
			pr_emerg("s5-pmrt-arm: %-14s .shutdown de '%s' SE RESPETA (fuera de la lista blanca)\n",
				 bdf, dname);
		}

		informe("TRAS  ", bdf, pdev);
		pci_dev_put(pdev);
	}

	kfree(copia);
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
	return 0;
}

static void __exit s5_pmrt_arm_exit(void) { }

module_init(s5_pmrt_arm_init);
module_exit(s5_pmrt_arm_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Paso 1: blinda el subarbol de la dGPU contra pci_device_shutdown()");

// SPDX-License-Identifier: GPL-2.0
/*
 * s5_pmrt_arm — PASO 1 de la via limpia (2026-08-10).
 *
 * QUE HACE: justo antes de que systemd llame a reboot(POWEROFF), blinda el
 * subarbol de la discreta contra las DOS cosas que `pci_device_shutdown()` hace
 * y que lo devuelven a D0:
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

#define MAX_DEVS 8

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

module_param(devs, charp, 0444);
MODULE_PARM_DESC(devs, "BDFs separados por comas (OBLIGATORIO: sin el no se blinda nada)");
module_param(noshut, charp, 0444);
MODULE_PARM_DESC(noshut, "lista blanca de drivers a los que anular .shutdown");
module_param(arm, int, 0444);
MODULE_PARM_DESC(arm, "0 = ensayo en seco; 1 = actua");

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

static int __init s5_pmrt_arm_init(void)
{
	char *copia, *resto, *bdf;
	int hechos = 0, anulados = 0;

	pr_emerg("s5-pmrt-arm: ===== arm=%d devs=%s noshut=%s\n", arm, devs, noshut);

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
	pr_emerg("s5-pmrt-arm: FIN  disable=%d shutdown_anulados=%d  => systemd apaga por el camino NORMAL\n",
		 hechos, anulados);
	return 0;
}

static void __exit s5_pmrt_arm_exit(void) { }

module_init(s5_pmrt_arm_init);
module_exit(s5_pmrt_arm_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Paso 1: blinda el subarbol de la dGPU contra pci_device_shutdown()");

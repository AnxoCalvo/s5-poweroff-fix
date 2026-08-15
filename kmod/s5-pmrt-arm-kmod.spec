%global debug_package %{nil}
%global buildforkernels akmod

Name:           s5-pmrt-arm-kmod
Version:        1.0
Release:        3%{?dist}
Summary:        Mitigacion del drenaje en S5 causado por la dGPU en portatiles hibridos
License:        GPL-2.0-only
URL:            https://github.com/AnxoCalvo/s5-poweroff-fix
Source0:        s5-pmrt-arm-%{version}.tar.gz

ExclusiveArch:  x86_64

BuildRequires:  %{_bindir}/kmodtool
%{!?kernels:BuildRequires: gcc, make, elfutils-libelf-devel, kernel-devel}

# kmodtool hace su magia aqui: genera akmod-s5-pmrt-arm, kmod-s5-pmrt-arm y,
# cuando akmods define %%{kernels}, el kmod-s5-pmrt-arm-<version-del-kernel>.
%{expand:%(kmodtool --target %{_target_cpu} --kmodname %{name} %{?buildforkernels:--%{buildforkernels}} %{?kernels:--for-kernels "%{?kernels}"} 2>/dev/null) }

%description
Modulo s5_pmrt_arm: justo antes de que systemd llame a reboot(POWEROFF), blinda
el subarbol de la GPU discreta contra las dos cosas que pci_device_shutdown()
hace y que lo devuelven a D0 — el pm_runtime_resume() (rebotado con
__pm_runtime_disable) y el drv->shutdown() de los drivers de la lista blanca.

QUE dispositivos se blindan NO va clavado aqui: el hook de apagado los descubre
por sysfs en cada maquina (s5-descubre-dgpu) y se los pasa al modulo en el
parametro devs=. En el portatil donde se diagnostico el problema son el puente
PCIe, la GPU y su funcion de audio HDMI, y sin el modulo ese S5 gasta 18-20 W en
vez de ~2 W.

Empaquetado como akmod para que SOBREVIVA A LAS ACTUALIZACIONES DE KERNEL: el
.ko compilado a mano lleva el vermagic del kernel viejo, insmod lo rechaza y la
mitigacion muere EN SILENCIO.

%package       common
Summary:        Fuentes y documentacion de s5-pmrt-arm
BuildArch:      noarch

%description   common
Fuentes del modulo s5_pmrt_arm y su documentacion.

%prep
%{?kmodtool_check}
kmodtool --target %{_target_cpu} --kmodname %{name} %{?buildforkernels:--%{buildforkernels}} %{?kernels:--for-kernels "%{?kernels}"} 2>/dev/null
%setup -q -n s5-pmrt-arm-%{version}
for kernel_version in %{?kernel_versions}; do
    cp -a kernel _kmod_build_${kernel_version%%%%___*}
done

%build
for kernel_version in %{?kernel_versions}; do
    make %{?_smp_mflags} -C "${kernel_version##*___}" \
        M=$PWD/_kmod_build_${kernel_version%%%%___*} modules
done

%install
for kernel_version in %{?kernel_versions}; do
    mkdir -p $RPM_BUILD_ROOT%{kmodinstdir_prefix}/${kernel_version%%%%___*}/%{kmodinstdir_postfix}
    install -D -m 755 _kmod_build_${kernel_version%%%%___*}/s5_pmrt_arm.ko \
        $RPM_BUILD_ROOT%{kmodinstdir_prefix}/${kernel_version%%%%___*}/%{kmodinstdir_postfix}/s5_pmrt_arm.ko
done
%{?akmod_install}
mkdir -p $RPM_BUILD_ROOT%{_datadir}/s5-pmrt-arm
install -m 644 kernel/s5_pmrt_arm.c kernel/Makefile $RPM_BUILD_ROOT%{_datadir}/s5-pmrt-arm/

%files         common
%{_datadir}/s5-pmrt-arm/

%changelog
* Fri Aug 14 2026 AnxoCalvo <257994910+AnxoCalvo@users.noreply.github.com> - 1.0-3
- devs= deja de traer una lista por defecto: eran los BDF de la maquina donde se
  diagnostico esto, y un `modprobe arm=1` a mano en otra habria blindado lo que
  hubiera en esas direcciones (posiblemente el NVMe). Sin lista y con arm=1 el
  modulo ahora se niega a cargar (-EINVAL) en vez de no hacer nada en silencio.
- El fuente se versiona suelto en kmod/s5-pmrt-arm-1.0/; el tarball se genera al
  construir.

* Thu Aug 13 2026 AnxoCalvo <257994910+AnxoCalvo@users.noreply.github.com> - 1.0-2
- Reconstruccion de empaquetado. SALIO SIN ENTRADA DE CHANGELOG y esta se anota a
  posteriori (2026-08-15) para que la numeracion no tenga un hueco que parezca una
  entrada perdida. Lo que si consta, leido del rpm que quedo en /var/cache/akmods:
  el modulo no cambio — mismos parametros y misma lista `devs=` clavada por
  defecto que la 1.0-1; esa lista se quita en la 1.0-3.

* Mon Aug 10 2026 AnxoCalvo <257994910+AnxoCalvo@users.noreply.github.com> - 1.0-1
- Empaquetado inicial del modulo s5_pmrt_arm como akmod, para que la mitigacion
  del drenaje en S5 sobreviva a las actualizaciones de kernel.

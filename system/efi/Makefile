# system/efi/Makefile — compila s5-halt.efi.
#
# DOS VIAS, porque no estan disponibles en las mismas maquinas:
#
#   make            gnu-efi + objcopy con el objetivo `efi-app-x86_64`
#   make clang      clang (--target=x86_64-pc-win32-coff) + lld-link
#   make check      dice cual de las dos esta disponible aqui, o por que no hay
#
# La segunda existe porque hay binutils sin el objetivo EFI (comprobarlo:
# `objcopy --info | grep efi-app-x86_64`); en la maquina donde se escribio esto es
# el caso, y con clang+lld sale una imagen PE valida y mas pequena. El fuente no
# usa la libreria de gnu-efi (solo sus cabeceras), asi que las dos vias compilan
# exactamente el mismo codigo.
#
# Rutas sobreescribibles porque no todas las distribuciones las ponen igual
# (Fedora en /usr/lib/gnuefi y /usr/lib64, Debian y Arch en /usr/lib).

EFIINC  ?= /usr/include/efi
EFILIB  ?= /usr/lib
CRTOBJ  ?= $(EFILIB)/crt0-efi-x86_64.o
LDSCRIPT?= $(EFILIB)/elf_x86_64_efi.lds

CC      ?= gcc
LD      ?= ld
OBJCOPY ?= objcopy
CLANG   ?= clang
LLDLINK ?= lld-link

# -fshort-wchar: los literales L"..." de EFI son de 16 bits.
# -mno-red-zone: el firmware puede usar interrupciones y no respeta la red zone.
# -DEFI_FUNCTION_WRAPPER: obliga a pasar por uefi_call_wrapper, que es lo que
#   hace portable la llamada a los servicios de arranque y de runtime.
CFLAGS  += -I$(EFIINC) -I$(EFIINC)/x86_64 -I$(EFIINC)/protocol \
	   -fno-stack-protector -fpic -fshort-wchar -mno-red-zone \
	   -Wall -Wextra -O2 -DEFI_FUNCTION_WRAPPER
LDFLAGS += -nostdlib -znocombreloc -T $(LDSCRIPT) -shared -Bsymbolic \
	   -L$(EFILIB) $(CRTOBJ)
# La via de clang no usa EFI_FUNCTION_WRAPPER: el objetivo win32-coff ya usa la
# convencion de llamada de EFI, y la libreria no se enlaza.
CLANGFLAGS += -I$(EFIINC) -I$(EFIINC)/x86_64 -I$(EFIINC)/protocol \
	      -fno-stack-protector -fshort-wchar -mno-red-zone \
	      -ffreestanding -nostdlib -Wall -Wextra -O2

all: s5-halt.efi

check:
	@ok=0; \
	if [ -e "$(CRTOBJ)" ] && [ -e "$(LDSCRIPT)" ] && \
	   $(OBJCOPY) --info 2>/dev/null | tr ' ' '\n' | grep -qx 'efi-app-x86_64'; then \
		echo "via gnu-efi + objcopy (efi-app-x86_64): LISTA"; ok=1; \
	else \
		echo "via gnu-efi + objcopy: no (falta gnu-efi o el objetivo efi-app-x86_64)"; \
	fi; \
	if command -v $(CLANG) >/dev/null 2>&1 && command -v $(LLDLINK) >/dev/null 2>&1; then \
		if [ -e "$(EFIINC)/efi.h" ]; then \
			echo "via clang + lld-link: LISTA (cabeceras de gnu-efi en $(EFIINC))"; ok=1; \
		else \
			echo "via clang + lld-link: falta solo las cabeceras, no la libreria -> instala gnu-efi"; \
			echo "   ($(EFIINC)/efi.h no existe; sin el, clang falla con: 'efi.h' file not found)"; \
		fi; \
	else \
		echo "via clang + lld-link: no (falta clang o lld-link)"; \
	fi; \
	if [ "$$ok" = 0 ]; then \
		echo; \
		echo "No hay ninguna via para construir la imagen EFI. Instala una de las dos:"; \
		echo "  Arch:   sudo pacman -S gnu-efi          (y comprueba el objcopy de arriba)"; \
		echo "          sudo pacman -S clang lld        (si tu binutils no trae el objetivo EFI)"; \
		echo "  Fedora: sudo dnf install gnu-efi"; \
		exit 1; \
	fi

s5-halt.o: s5-halt.c
	$(CC) $(CFLAGS) -c $< -o $@

s5-halt.so: s5-halt.o
	$(LD) $(LDFLAGS) $< -o $@ -lefi -lgnuefi

s5-halt.efi: s5-halt.so
	$(OBJCOPY) -j .text -j .sdata -j .data -j .dynamic -j .dynsym \
		-j .rel -j .rela -j .reloc -j .eh_frame \
		--target=efi-app-x86_64 $< $@
	@ls -l $@

# La via alternativa produce el mismo $@ desde el mismo fuente.
clang: s5-halt-clang.o
	$(LLDLINK) /subsystem:efi_application /entry:efi_main /nodefaultlib \
		/out:s5-halt.efi $<
	@ls -l s5-halt.efi

s5-halt-clang.o: s5-halt.c
	$(CLANG) --target=x86_64-pc-win32-coff $(CLANGFLAGS) -c $< -o $@

clean:
	rm -f s5-halt.o s5-halt.so s5-halt.efi s5-halt-clang.o

.PHONY: all check clang clean

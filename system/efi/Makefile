# system/efi/Makefile — builds s5-halt.efi.
#
# TWO ROUTES, because they are not available on the same machines:
#
#   make            gnu-efi + objcopy with the `efi-app-x86_64` target
#   make clang      clang (--target=x86_64-pc-win32-coff) + lld-link
#   make check      says which of the two is available here, or why neither is
#
# The second one exists because some binutils lack the EFI target (check it:
# `objcopy --info | grep efi-app-x86_64`); on the machine where this was written
# that is the case, and clang+lld produces a valid and smaller PE image. The
# source does not use the gnu-efi library (only its headers), so both routes
# compile exactly the same code.
#
# Overridable paths because not all distributions put them in the same place
# (Fedora in /usr/lib/gnuefi and /usr/lib64, Debian and Arch in /usr/lib).

EFIINC  ?= /usr/include/efi
EFILIB  ?= /usr/lib
CRTOBJ  ?= $(EFILIB)/crt0-efi-x86_64.o
LDSCRIPT?= $(EFILIB)/elf_x86_64_efi.lds

CC      ?= gcc
LD      ?= ld
OBJCOPY ?= objcopy
CLANG   ?= clang
LLDLINK ?= lld-link

# -fshort-wchar: EFI's L"..." literals are 16-bit.
# -mno-red-zone: the firmware may use interrupts and does not respect the red zone.
# -DEFI_FUNCTION_WRAPPER: forces calls through uefi_call_wrapper, which is what
#   makes calling the boot and runtime services portable.
CFLAGS  += -I$(EFIINC) -I$(EFIINC)/x86_64 -I$(EFIINC)/protocol \
	   -fno-stack-protector -fpic -fshort-wchar -mno-red-zone \
	   -Wall -Wextra -O2 -DEFI_FUNCTION_WRAPPER
LDFLAGS += -nostdlib -znocombreloc -T $(LDSCRIPT) -shared -Bsymbolic \
	   -L$(EFILIB) $(CRTOBJ)
# The clang route does not use EFI_FUNCTION_WRAPPER: the win32-coff target already
# uses the EFI calling convention, and the library is not linked.
CLANGFLAGS += -I$(EFIINC) -I$(EFIINC)/x86_64 -I$(EFIINC)/protocol \
	      -fno-stack-protector -fshort-wchar -mno-red-zone \
	      -ffreestanding -nostdlib -Wall -Wextra -O2

all: s5-halt.efi

check:
	@ok=0; \
	if [ -e "$(CRTOBJ)" ] && [ -e "$(LDSCRIPT)" ] && \
	   $(OBJCOPY) --info 2>/dev/null | tr ' ' '\n' | grep -qx 'efi-app-x86_64'; then \
		echo "gnu-efi + objcopy route (efi-app-x86_64): READY"; ok=1; \
	else \
		echo "gnu-efi + objcopy route: no (missing gnu-efi or the efi-app-x86_64 target)"; \
	fi; \
	if command -v $(CLANG) >/dev/null 2>&1 && command -v $(LLDLINK) >/dev/null 2>&1; then \
		if [ -e "$(EFIINC)/efi.h" ]; then \
			echo "clang + lld-link route: READY (gnu-efi headers in $(EFIINC))"; ok=1; \
		else \
			echo "clang + lld-link route: only the headers are missing, not the library -> install gnu-efi"; \
			echo "   ($(EFIINC)/efi.h does not exist; without it, clang fails with: 'efi.h' file not found)"; \
		fi; \
	else \
		echo "clang + lld-link route: no (missing clang or lld-link)"; \
	fi; \
	if [ "$$ok" = 0 ]; then \
		echo; \
		echo "There is no route to build the EFI image. Install one of the two:"; \
		echo "  Arch:   sudo pacman -S gnu-efi          (and check the objcopy output above)"; \
		echo "          sudo pacman -S clang lld        (if your binutils does not carry the EFI target)"; \
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

# The alternative route produces the same $@ from the same source.
clang: s5-halt-clang.o
	$(LLDLINK) /subsystem:efi_application /entry:efi_main /nodefaultlib \
		/out:s5-halt.efi $<
	@ls -l s5-halt.efi

s5-halt-clang.o: s5-halt.c
	$(CLANG) --target=x86_64-pc-win32-coff $(CLANGFLAGS) -c $< -o $@

clean:
	rm -f s5-halt.o s5-halt.so s5-halt.efi s5-halt-clang.o

.PHONY: all check clang clean

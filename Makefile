# SPDX-License-Identifier: GPL-2.0-only
SHELL := /bin/bash
BASE  := Redmi10c-base
OUT   := $(BASE)/out/ubuntu-dualboot
RUN   := docker run --rm --privileged -v "$(CURDIR)":/src -w /src
SKIP_CUST ?= 0

.PHONY: help doctor patch verify kernel image rootfs adbd test logs android

doctor:          ## what's missing here (images, kernel, phone)
	@tools/doctor.sh

help:            ## list targets
	@grep -E '^[a-z]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/'

patch:           ## apply local kernel patches (idempotent)
	@[ -d $(BASE)/mainline/linux-7.1.y ] || { \
	  echo "kernel tree missing - see RUNBOOK step 1" >&2; exit 1; }
	@if grep -q 'snps,force-32bit-dma' \
	      $(BASE)/mainline/linux-7.1.y/arch/arm64/boot/dts/qcom/sm6225-xiaomi-fog.dts \
	   && grep -q 'snps,force-32bit-dma' \
	      $(BASE)/mainline/linux-7.1.y/drivers/usb/dwc3/core.c; then \
	  echo "fog-adb-usb.patch already applied"; \
	else \
	  patch -p1 -d $(BASE)/mainline/linux-7.1.y < patches/fog-adb-usb.patch; \
	fi

adbd:            ## stage adbd debs + this host's adb public key
	@tools/fetch-adbd-debs.sh
	@mkdir -p docs/.scratch/adbd
	@cp -f "$$HOME/.android/adbkey.pub" docs/.scratch/adbd/adbkey.pub 2>/dev/null \
	  || echo "note: no ~/.android/adbkey.pub - run 'adb keygen' or adb will show unauthorized"

kernel: patch    ## rebuild Image.gz + DTBs
	$(RUN) fog-build:latest make -C $(BASE)/mainline/linux-7.1.y \
	  O=/src/$(BASE)/out/linux-7.1.5 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
	  -j8 olddefconfig Image.gz dtbs

verify:          ## sanity-check the packed boot image (header, dtb, board-id)
	@tools/verify-image.sh

image: patch     ## repack boot-linux.img, then verify it
	$(RUN) fog-build:latest bash $(BASE)/tools/pack-ubuntu-boot.sh
	@tools/verify-image.sh

rootfs:          ## install build/overlay/ + adbd into the cust image
	@ls docs/.scratch/adbd/debs/adbd_*.deb >/dev/null 2>&1 || $(MAKE) --no-print-directory adbd
	@mkdir -p docs/.scratch/adbd
	@cp -f "$$HOME/.android/adbkey.pub" docs/.scratch/adbd/adbkey.pub 2>/dev/null || true
	$(RUN) fog-rootfs:latest bash build/install-overlay.sh

test:            ## flash, boot, wait for self-reboot, pull logs (~4 min)
	SKIP_CUST=$(SKIP_CUST) tools/testboot-loop.sh

logs:            ## summary of the last pulled boot report
	@sed -n '1,12p' docs/.scratch/rain-boot-report.txt 2>/dev/null \
	  || echo "no report yet - run 'make test'"

android:         ## return to stock MIUI (slot A)
	@fastboot devices 2>/dev/null | grep -q . || adb reboot bootloader
	@for i in $$(seq 1 30); do fastboot devices 2>/dev/null | grep -q . && break; sleep 1; done
	fastboot --set-active=a && fastboot reboot

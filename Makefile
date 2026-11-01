# SPDX-License-Identifier: GPL-2.0-only
SHELL := /bin/bash
BASE  := Redmi10c-base
OUT   := $(BASE)/out/ubuntu-dualboot
RUN   := docker run --rm --privileged -v "$(CURDIR)":/src -w /src
SKIP_CUST ?= 0

.PHONY: help doctor verify kernel image rootfs test logs android

doctor:          ## what's missing here (images, kernel, phone)
	@tools/doctor.sh

help:            ## list targets
	@grep -E '^[a-z]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/'

kernel:          ## rebuild Image.gz + DTBs
	$(RUN) fog-build:latest make -C $(BASE)/mainline/linux-7.1.y \
	  O=/src/$(BASE)/out/linux-7.1.5 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
	  -j8 olddefconfig Image.gz dtbs

verify:          ## sanity-check the packed boot image (header, dtb, board-id)
	@tools/verify-image.sh

image:           ## repack boot-linux.img, then verify it
	$(RUN) fog-build:latest bash $(BASE)/tools/pack-ubuntu-boot.sh
	@tools/verify-image.sh

rootfs:          ## install build/overlay/ into the cust image (no reflash)
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

# SPDX-License-Identifier: GPL-2.0-only
SHELL := /bin/bash
BASE  := Redmi10c-base
V730  := $(BASE)/v730
OUT   := $(V730)/rootfs/out
BOOT  := $(OUT)/boot-linux.img
CUST  := $(OUT)/linux_rootfs.sparse.img

.PHONY: help doctor adb base kernel image rootfs verify test test-slot logs android

doctor:          ## what's missing here (images, kernel, phone)
	@tools/doctor.sh

help:            ## list targets
	@grep -E '^[a-z][a-z0-9-]*:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/'

base:            ## fetch v7.3.0 worktree + firmware + cloud rootfs + container
	@tools/v730-build.sh base

kernel:          ## build kernel v7.3 + our fog DTS deltas + modules
	@tools/v730-build.sh kernel

image:           ## pack boot-linux.img (pivot initramfs) and verify it
	@tools/v730-build.sh image

rootfs:          ## build the Ubuntu 26.04 cust image (sparse)
	@tools/v730-build.sh rootfs

verify:          ## sanity-check the packed boot image (header, dtb, board-id)
	@tools/verify-image.sh $(BOOT)

adb:             ## show what adb is talking to + the usage cookbook
	@tools/adb-status.sh

test:            ## RAM-boot the image, check adb/display, return to fastboot
	@BOOT_IMG=$(BOOT) tools/testboot-loop.sh

test-slot:       ## legacy: flash slot B + cust, wait for self-reboot
	@BOOT_IMG=$(BOOT) CUST_IMG=$(CUST) RAM_BOOT=0 tools/testboot-loop.sh

logs:            ## summary of the last pulled boot report
	@sed -n '1,12p' docs/.scratch/rain-boot-report.txt 2>/dev/null \
	  || echo "no report yet - run 'make test'"

android:         ## return to stock MIUI (slot A)
	@fastboot devices 2>/dev/null | grep -q . || adb reboot bootloader
	@for i in $$(seq 1 30); do fastboot devices 2>/dev/null | grep -q . && break; sleep 1; done
	fastboot --set-active=a && fastboot reboot

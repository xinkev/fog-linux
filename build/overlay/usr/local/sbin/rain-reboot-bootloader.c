/* SPDX-License-Identifier: GPL-2.0-only
 *
 * Reboot into the bootloader (fastboot) from Linux.
 *
 * Android's `adb reboot bootloader` works because init passes a reboot
 * reason string to the bootloader via reboot(2) with LINUX_REBOOT_CMD_RESTART2.
 * systemd's /sbin/reboot cannot pass a string, and glibc only exposes the
 * one-argument reboot(3), so issue the syscall directly. ABL on
 * Xiaomi/Qualcomm devices honours the "bootloader" reason and lands in
 * fastboot.
 *
 * Used by rain-autoreboot.service so a test boot returns control to the
 * host without a physical power cycle.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef LINUX_REBOOT_CMD_RESTART2
#define LINUX_REBOOT_CMD_RESTART2 0xa1b2c3d4
#endif
#define RB_MAGIC1 0xfee1dead
#define RB_MAGIC2 672274793
#define RB_MAGIC2A 85072278

int main(int argc, char **argv)
{
	const char *reason = (argc > 1) ? argv[1] : "bootloader";
	long ret;

	sync();

	ret = syscall(SYS_reboot, RB_MAGIC1, RB_MAGIC2,
		      LINUX_REBOOT_CMD_RESTART2, reason);
	if (ret != 0) {
		/* Kernel 4.x and older use the alternative magic. */
		ret = syscall(SYS_reboot, RB_MAGIC1, RB_MAGIC2A,
			      LINUX_REBOOT_CMD_RESTART2, reason);
	}
	if (ret != 0) {
		fprintf(stderr, "reboot(%s) failed: %s\n", reason,
			strerror(errno));
		return 1;
	}
	return 0;
}

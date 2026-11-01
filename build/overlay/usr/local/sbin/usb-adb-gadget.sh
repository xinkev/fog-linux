#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ADB over USB: FunctionFS gadget for adbd.
#
# Flow (same as the proven upstream Redmi10c stack):
#   setup  — tear down the initramfs ACM gadget, build g1 with ffs.adb,
#            mount FunctionFS. Leaves UDC unbound; adbd must write the
#            descriptors first.
#   bind   — called from adbd.service ExecStartPost once ep1 exists.
#
# Do NOT poke the PHY/DCTL here. pivot-init and the femto driver already
# brought the controller up; extra MMIO writes restart dwc3 behind its back
# (event-ring corruption) and can hang SM6225.
set +e
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

LOG=/var/log/usb-adb-gadget.log
G=/sys/kernel/config/usb_gadget/g1
FFS=/dev/usb-ffs/adb

log() {
    echo "$(date -Is) usb-adb: $*" >>"$LOG" 2>/dev/null
    echo "usb-adb: $*" >/dev/kmsg 2>/dev/null
}

ffs_ready()  { [ -e "$FFS/ep0" ]; }
ep_ready()   { [ -e "$FFS/ep1" ] || [ -e "$FFS/ep1out" ]; }
udc_name()   { ls /sys/class/udc 2>/dev/null | head -n 1; }
udc_bound()  { [ -n "$(cat "$G/UDC" 2>/dev/null)" ]; }

do_bind() {
    local udc
    udc=$(udc_name)
    [ -n "$udc" ] || { log "bind: no UDC"; return 1; }
    if udc_bound; then
        log "bind: already $(cat "$G/UDC")"
        return 0
    fi
    if ! echo "$udc" >"$G/UDC" 2>>"$LOG"; then
        log "bind: writing $udc to UDC failed"
        return 1
    fi
    log "bound $udc"
    return 0
}

setup_once() {
    local udc
    modprobe libcomposite 2>/dev/null
    mkdir -p /sys/kernel/config
    mountpoint -q /sys/kernel/config || mount -t configfs configfs /sys/kernel/config 2>/dev/null

    udc=$(udc_name)
    [ -n "$udc" ] || { log "no UDC"; return 1; }

    # Already our ADB gadget and bound: leave it alone.
    if [ -d "$G" ] && [ "$(cat "$G/idProduct" 2>/dev/null)" = "0x4ee7" ] && udc_bound; then
        log "already bound to $(cat "$G/UDC")"
        return 0
    fi

    # The initramfs ACM gadget owns the UDC at this point.
    if [ -d "$G" ] && udc_bound; then
        log "unbinding inherited $(cat "$G/UDC")"
        echo "" >"$G/UDC" 2>/dev/null
        sleep 0.5
    fi

    mkdir -p "$G/strings/0x409" "$G/configs/c.1/strings/0x409"
    rm -f "$G/configs/c.1/acm.usb0" "$G/configs/c.1/rndis.usb0" 2>/dev/null
    rmdir "$G/functions/acm.usb0" "$G/functions/rndis.usb0" 2>/dev/null

    # Google ADB IDs: host-side adb recognises the interface.
    echo 0x18d1 >"$G/idVendor"
    echo 0x4ee7 >"$G/idProduct"
    echo rain >"$G/strings/0x409/serialnumber"
    echo Xiaomi >"$G/strings/0x409/manufacturer"
    echo rain-ubuntu >"$G/strings/0x409/product"
    echo ADB >"$G/configs/c.1/strings/0x409/configuration"
    echo 0xA0 >"$G/configs/c.1/bmAttributes"
    echo 500 >"$G/configs/c.1/MaxPower" 2>/dev/null

    mkdir -p "$G/functions/ffs.adb" "$FFS"
    if ! mountpoint -q "$FFS"; then
        if ! mount -t functionfs adb "$FFS" 2>>"$LOG"; then
            log "functionfs mount failed"
            return 1
        fi
    fi
    [ -e "$G/configs/c.1/ffs.adb" ] || ln -sfn "$G/functions/ffs.adb" "$G/configs/c.1/ffs.adb"

    # ep0 appears when FunctionFS is mounted; ep1 only after adbd writes
    # its descriptors. Leave the UDC unbound in that case — adbd.service's
    # ExecStartPost calls `bind` once it is ready.
    if ! ffs_ready; then
        log "FFS mounted but no ep0 yet"
        return 1
    fi
    if ep_ready; then
        do_bind || return 1
        log "gadget ready (descriptors already present)"
    else
        log "FFS ready; waiting for adbd to write descriptors"
    fi
    return 0
}

bind_udc() {
    local i
    for i in $(seq 1 50); do
        ep_ready && break
        sleep 0.1
    done
    if ! ep_ready; then
        log "bind: no ep1/ep1out after 5s"
        return 1
    fi
    do_bind
}

case "${1:-setup}" in
    setup)
        for _ in $(seq 1 20); do
            setup_once && exit 0
            sleep 1
        done
        exit 1
        ;;
    bind)
        bind_udc
        exit $?
        ;;
    *)
        echo "usage: $0 [setup|bind]" >&2
        exit 2
        ;;
esac

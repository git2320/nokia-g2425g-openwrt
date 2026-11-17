#!/bin/sh
# stage-openwrt-slot.sh - stage the boot flag (and optionally slot A) to boot
# the OpenWrt slot, run FROM THE STOCK FIRMWARE shell (telnet/ssh on the ONT).
#
# Why this exists
#
#   * `oflt change_boot_flag` is a no-op on this firmware: lib/liboflt.so
#     `oflt_change_boot_flag` just runs `swug --im inactive --activate` and
#     `swug` does not exist anywhere in the stock rootfs (verified by a full
#     unsquashfs listing of mtd4). So the "switch" step of the earlier runbook
#     never switched anything.
#   * The stock way to switch is `Imagetool switch` / `swdl_active`, which
#     writes both flag copies with: next_active = other slot, image0_is_valid
#     = 1, image1_is_valid = 1, boot_fail_num = 0. This script writes exactly
#     that state, keeping commit = 0 (stock stays committed, so the CFE
#     auto-revert safety net stays armed) and preserving word 5 (startready)
#     and the version strings at 0x18/0x28.
#   * The GPL bootloader for the EN751221 family has the "A-length bug"
#     (https://econet-linux.pkt.wiki/en/bootloader#a-length-bug): kernel_len
#     is read from slot A even when booting slot B, truncating slot B's LZMA
#     stream. On THIS board the evidence is against it (stock slot B declares
#     a 4,098,754-byte stream > slot A's 0x3ddbae and boots anyway), so the
#     bug probably does not apply — but `--patch-a` raises slot A's kernel_len
#     to a full 4 MiB anyway as harmless insurance. Slot A stays bootable: the
#     LZMA decoder stops at its recorded size, and `Imagetool`'s CRC covers
#     total_len, not kernel_len.
#
# Usage (on the ONT, stock firmware):
#
#   sh stage-openwrt-slot.sh              # stage the boot flag only
#   sh stage-openwrt-slot.sh --patch-a    # + patch slot A kernel_len to 4 MiB
#
# Prerequisites: stock busybox tools (dd/awk/tr/md5sum, all present in the
# mtd4 dump), /tmp writable. --patch-a additionally needs /tmp/fwtool3 (or
# /tmp/fwtool): the flasher that performs the vendor
# begin/MEMERASE/pwrite/verify/end ioctl sequence, because plain MEMERASE
# returns EINVAL on image slots.
#
# After this script: `reboot`. CFE boots the linux slot (OpenWrt). If OpenWrt
# fails N boots in a row, CFE reverts to stock on its own. Once OpenWrt is up,
# /etc/init.d/econet-commit commits the slot so the revert net disarms.

BLK=131072                # flag erase-block size (128 KiB)
PATCH_A=0
# overridable for testing: MTDINFO=/proc/mtd copy, DEVDIR=/dev replacement
MTDINFO=${MTDINFO:-/proc/mtd}
DEVDIR=${DEVDIR:-/dev}
for arg in "$@"; do
    case "$arg" in
    --patch-a) PATCH_A=1 ;;
    *) echo "usage: $0 [--patch-a]" >&2; exit 2 ;;
    esac
done

TMPBLK=/tmp/.flagblk.$$
TMPCMP=/tmp/.flagcmp.$$
cleanup() { rm -f "$TMPBLK" "$TMPCMP"; }
die() { echo "ERROR: $*" >&2; cleanup; exit 1; }

# mtd number for an exact /proc/mtd name (empty if absent)
mtdnum() {
    awk -F'"' -v n="$1" '$2 == n { sub(/^mtd/, "", $1); sub(/:.*/, "", $1); print $1 }' "$MTDINFO"
}

# write a 32-bit little-endian word into a file: set_word <offset> <value> <file>
set_word() {
    _off=$1 _val=$2 _file=$3
    _oct=$(printf '\\%03o\\%03o\\%03o\\%03o' \
        $((_val % 256)) \
        $(((_val / 256) % 256)) \
        $(((_val / 65536) % 256)) \
        $(((_val / 16777216) % 256)))
    printf "$_oct" | dd of="$_file" bs=1 seek=$_off count=4 conv=notrunc 2>/dev/null
}

# read one u32 little-endian word from a file, printed as decimal if we can
get_word() {
    dd if="$1" bs=1 skip=$2 count=4 2>/dev/null | \
        { od -An -tu4 2>/dev/null || hexdump -v 2>/dev/null; } | \
        awk '{for (i = 1; i <= NF; i++) print $i; exit}'
}

show_words() {
    echo "  commit=$(get_word "$1" 0) next_active=$(get_word "$1" 4)"
    echo "  image0_is_valid=$(get_word "$1" 8) image1_is_valid=$(get_word "$1" 12)"
    echo "  boot_fail_num=$(get_word "$1" 16) startready=$(get_word "$1" 20)"
    echo "  image0_version=$(dd if="$1" bs=1 skip=24 count=16 2>/dev/null | tr -d '\000')"
    echo "  image1_version=$(dd if="$1" bs=1 skip=40 count=16 2>/dev/null | tr -d '\000')"
}

FLAG=$(mtdnum flag)
FLAGBACK=$(mtdnum flagback)
IMAGE0=$(mtdnum image0)
[ -n "$FLAG" ] && [ -n "$FLAGBACK" ] || die "flag/flagback not found in /proc/mtd"
echo "flag=mtd$FLAG flagback=mtd$FLAGBACK image0=mtd${IMAGE0:-?}"

stage_one() {
    dev=$1
    echo "--- staging /dev/mtdblock$dev ---"
    dd if="$DEVDIR/mtdblock$dev" of="$TMPBLK" bs=$BLK count=1 2>/dev/null \
        || die "cannot read /dev/mtdblock$dev"
    echo "before:"
    show_words "$TMPBLK"

    # commit=0 (stock stays committed => auto-revert safety net stays armed),
    # next_active=1 (boot the OpenWrt slot), both slots valid, fail counter 0.
    # Word 5 (startready) and the version strings are left untouched.
    set_word  0 0 "$TMPBLK"
    set_word  4 1 "$TMPBLK"
    set_word  8 1 "$TMPBLK"
    set_word 12 1 "$TMPBLK"
    set_word 16 0 "$TMPBLK"

    dd if="$TMPBLK" of="$DEVDIR/mtdblock$dev" bs=$BLK count=1 2>/dev/null \
        || die "cannot write /dev/mtdblock$dev"
    sync
    [ -e /proc/sys/vm/drop_caches ] && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null

    # verify through the char device, which bypasses the block cache
    dd if="$DEVDIR/mtd$dev" of="$TMPCMP" bs=$BLK count=1 2>/dev/null \
        || die "cannot read back /dev/mtd$dev"
    a=$(md5sum < "$TMPBLK" | awk '{print $1}')
    b=$(md5sum < "$TMPCMP" | awk '{print $1}')
    [ "$a" = "$b" ] || die "read-back of /dev/mtd$dev does not match what we wrote"
    echo "after (verified via /dev/mtd$dev):"
    show_words "$TMPCMP"
}

stage_one "$FLAG"
stage_one "$FLAGBACK"

if [ "$PATCH_A" = 1 ]; then
    [ -n "$IMAGE0" ] || die "image0 not found in /proc/mtd"
    TOOL=
    for t in /tmp/fwtool3 /tmp/fwtool /sbin/fwtool3 /sbin/fwtool; do
        [ -x "$t" ] && TOOL="$t" && break
    done
    [ -n "$TOOL" ] || TOOL=$(command -v fwtool3 2>/dev/null || command -v fwtool 2>/dev/null)
    [ -n "$TOOL" ] || die "--patch-a needs /tmp/fwtool3 (vendor ioctl sequence) \
and it is not on the box. Fetch it, or skip this step: it is optional insurance
against the A-length bug, which stock evidence suggests does not apply here."

    IMG=/tmp/.img0blk.$$
    dd if="$DEVDIR/mtd$IMAGE0" of="$IMG" bs=$BLK count=1 2>/dev/null \
        || die "cannot read /dev/mtd$IMAGE0"
    [ "$(dd if="$IMG" bs=1 count=4 2>/dev/null)" = "HDR2" ] \
        || die "$DEVDIR/mtd$IMAGE0 block 0 has no HDR2 magic"
    hlen=$(get_word "$IMG" 4)
    [ "$hlen" = "280" ] || die "unexpected hdr_len=$hlen in slot A (want 280)"
    old=$(get_word "$IMG" 80)
    echo "--- patching slot A kernel_len (mtd$IMAGE0 offset 0x50) ---"
    echo "    old kernel_len: $old (0x$(printf '%x' "$old" 2>/dev/null))"
    set_word 80 4194304 "$IMG"
    "$TOOL" erase  "$DEVDIR/mtd$IMAGE0" 0 $BLK || die "erase of slot A block 0 failed"
    "$TOOL" write  "$DEVDIR/mtd$IMAGE0" 0 "$IMG" || die "write of slot A block 0 failed"
    "$TOOL" verify "$DEVDIR/mtd$IMAGE0" 0 $BLK "$IMG" 2>/dev/null \
        || die "verify of slot A block 0 failed"
    cmpout=$(dd if="$DEVDIR/mtd$IMAGE0" of="$TMPCMP" bs=$BLK count=1 2>/dev/null && \
             cmp -s "$IMG" "$TMPCMP" && echo ok)
    [ "$cmpout" = "ok" ] || die "slot A block 0 read-back differs from what we wrote"
    echo "slot A kernel_len is now 0x400000. Stock slot A stays bootable: the"
    echo "LZMA decoder stops at its recorded size and the CRC is over total_len."
    rm -f "$IMG"
fi

cleanup
echo
echo "Done. Flag staged for the OpenWrt slot on both flag copies."
echo "Next: reboot. CFE boots OpenWrt; if it fails it auto-reverts to stock."
echo "After OpenWrt is up, /etc/init.d/econet-commit commits the slot."

#!/bin/sh
# SPDX-License-Identifier: GPL-2.0

set -e

# Maximum kernel size
# NOTE: We ff-pad the kernel and specify the fully padded length as the kernel
#       size in the TRX header. This works around a bug wherein the bootloader
#       reads the kernel length from the kernel in slot A, when it is booting
#       slot B. By including the padding in the length, the kernel length is
#       always the same, and the LZMA decompressor stops when it's done anyway.
#       See: https://econet-linux.pkt.wiki/en/bootloader#a-length-bug
#
#       The padding only helps when BOTH slots carry a padded length. The
#       A-length bug described at
#       https://econet-linux.pkt.wiki/en/bootloader#a-length-bug makes some
#       bootloaders of this family read kernel_len from slot A even when
#       booting slot B, truncating slot B's LZMA stream. Whether it applies
#       HERE is unclear: stock slot B (mtd3, JJIJ50) declares a 4,098,754-byte
#       stream while slot A (mtd2, HK46) declares kernel_len 0x3ddbae, and
#       stock boots from slot B anyway - so this board's bootloader probably
#       reads the length from the slot it boots. The check below only WARNS
#       (CI stays green); scripts/stage-openwrt-slot.sh --patch-a can raise
#       slot A's kernel_len to a full 4 MiB as harmless insurance.
PAD_ROOTFS_OFFSET_TO=$((4 * 1024 * 1024))

# kernel_len stock firmware declares in slot A ("image0", 3FE49362IJHK46 dump)
SLOT_A_STOCK_LEN=$((0x3ddbae))
# bytes the A-length bug would feed the decoder when booting slot B:
# kernel_len - 0x18, because the bug's end pointer is kernel_len + 0x100 while
# the payload starts at the 280-byte header (see HDRLEN below).
SLOT_B_FEED_LEN=$((SLOT_A_STOCK_LEN - 0x18))

# TRX header size.
#
# The vendor struct is 280 bytes, not the 256 of the classic 2010 trx.h:
#   * stock images for this board (mtd2/mtd3/mtd5 dumps) all declare
#     hdr_len=280 and start the LZMA payload at offset 0x118;
#   * vendor userspace libupgradeimpl.so image_check fread()s exactly 0x118
#     bytes and fails unless it gets them (280-byte struct, magic checked at
#     offset 0);
#   * the bootloader uses the same SDK headers, and a 256-byte header would
#     make it read the LZMA stream 24 bytes too early (0x00 props byte, 0-size
#     field) which cannot boot - yet stock boots.
# So the payload must start at 0x118: write 256 bytes of fields + 24 zero pad.
HDRLEN=280
HDRPAD=$((HDRLEN - 256))

die() {
    echo "$1" >&2
    exit 1
}

usage() {
    cat >&2 <<EOF
SYNTAX: $0 --kernel <file> --rootfs <file> --version <string> [options]

Options:
  --kernel   Path to kernel lzma file (required)
  --rootfs   Path to rootfs squashfs file
  --version  Version string, max 31 chars (required)
  --endian   Endianness: 'be' for big endian, 'le' for little endian (default: be)
  --model    Model/platform name, max 31 chars (default: empty)
  --loadaddr Address the bootloader decompresses the kernel to
             (default: 0x80020000)
EOF
    exit 1
}

# Defaults
kernel=""
rootfs=""
version=""
endian="be"
model=""
loadaddr="0x80020000"

# Parse named arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --kernel)
            kernel="$2"
            shift 2
            ;;
        --rootfs)
            rootfs="$2"
            shift 2
            ;;
        --version)
            version="$2"
            shift 2
            ;;
        --endian)
            endian="$2"
            shift 2
            ;;
        --model)
            model="$2"
            shift 2
            ;;
        --loadaddr)
            loadaddr="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

# Validate required arguments
[ -n "$kernel" ] || die "Missing required argument: --kernel"
[ -n "$version" ] || die "Missing required argument: --version"

# Validate endianness
case "$endian" in
    be|BE) endian="be" ;;
    le|LE) endian="le" ;;
    *) die "Invalid endianness: $endian (must be 'be' or 'le')" ;;
esac

which zytrx >/dev/null || die "zytrx not found in PATH $PATH"
[ -f "$kernel" ] || die "Kernel file not found: $kernel"
[ -z "$rootfs" ] || [ -f "$rootfs" ] || die "Rootfs file not found: $rootfs"
[ "$(echo "$version" | wc -c)" -lt 32 ] || die "Version string too long: $version"
[ -z "$model" ] || [ "$(printf '%s' "$model" | wc -c)" -lt 32 ] || die "Model string too long: $model"

kernel_len=$(stat -c '%s' "$kernel")
header_plus_kernel_len=$(($HDRLEN + $kernel_len))
rootfs_len=0
if [ -f "$rootfs" ]; then
    rootfs_len=$(stat -c '%s' "$rootfs")
fi

[ "$PAD_ROOTFS_OFFSET_TO" -gt "$header_plus_kernel_len" ] || die "kernel is too large"

# Informational only: the A-length bug (documented for the EN751221 GPL
# bootloader) would truncate slot B's stream at SLOT_B_FEED_LEN bytes, but
# stock slot B's stream (4,098,754 bytes) already exceeds that cap and boots,
# so this board's bootloader probably does not have the bug. The warning
# stays as a pointer to the (harmless) insurance patch.
if [ "$kernel_len" -gt "$SLOT_B_FEED_LEN" ]; then
    echo "WARNING: kernel stream is $kernel_len bytes; IF this bootloader has the" >&2
    echo "         A-length bug, slot A (stock, kernel_len 0x3ddbae) would truncate" >&2
    echo "         slot B's stream at $SLOT_B_FEED_LEN bytes. Stock evidence suggests" >&2
    echo "         the bug does not apply here, but running" >&2
    echo "         scripts/stage-openwrt-slot.sh --patch-a before the first reboot" >&2
    echo "         is harmless insurance." >&2
fi

padding_len=$(($PAD_ROOTFS_OFFSET_TO - $header_plus_kernel_len))

echo "endian: $endian" >&2
echo "padding_len: $padding_len" >&2

padded_kernel_len=$(($padding_len + $kernel_len))

total_len=$(($PAD_ROOTFS_OFFSET_TO + $rootfs_len))

echo "total_len: $total_len" >&2

padding() {
    head -c $padding_len /dev/zero | tr '\0' '\377'
}

to_hex() {
    hexdump -v -e '1/1 "%02x"'
}

from_hex() {
    perl -pe 's/\s+//g; s/(..)/chr(hex($1))/ge'
}

# Output a 32-bit value in hex with correct endianness
# Usage: hex32 <value>
hex32() {
    val=$(printf '%08x' "$1")
    if [ "$endian" = "le" ]; then
        # Swap bytes for little endian: AABBCCDD -> DDCCBBAA
        echo "$val" | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/'
    else
        echo "$val"
    fi
}

trx_crc32() {
    tmpfile=$(mktemp)
    outtmpfile=$(mktemp)
    cat "$kernel" > "$tmpfile"
    padding >> "$tmpfile"
    if [ -f "$rootfs" ]; then
        cat "$rootfs" >> "$tmpfile"
    fi
    # We just need a CRC-32/JAMCRC of the concatnated files
    # There's no readily available tool for this, but zytrx does create one when
    # creating their TRX header, so we just use that.
    zytrx \
        -B NR7101 \
        -v x \
        -i "$tmpfile" \
        -o "$outtmpfile" >/dev/null
    crc_hex=$(dd if="$outtmpfile" bs=4 count=1 skip=3 2>/dev/null | to_hex)
    rm "$tmpfile" "$outtmpfile" >/dev/null
    hex32 "0x$crc_hex"
}

tclinux_trx_hdr() {
    # TRX header magic: "2RDH" for big endian, "HDR2" for little endian
    if [ "$endian" = "le" ]; then
        printf 'HDR2' | to_hex
    else
        printf '2RDH' | to_hex
    fi

    # Length of the header
    hex32 "$HDRLEN"

    # Length of header + content
    hex32 "$total_len"

    # crc32 of the content
    trx_crc32

    # version
    printf '%s' "$version" | to_hex
    head -c "$((32 - $(printf '%s' "$version" | wc -c)))" /dev/zero | to_hex

    # customer version
    head -c 32 /dev/zero | to_hex

    # kernel length
    hex32 "$padded_kernel_len"

    # rootfs length
    hex32 "$rootfs_len"

    # romfile length (0)
    hex32 0

    # model (32 bytes, zero-padded)
    if [ -n "$model" ]; then
        printf '%s' "$model" | to_hex
        head -c "$((32 - $(printf '%s' "$model" | wc -c)))" /dev/zero | to_hex
    else
        head -c 32 /dev/zero | to_hex
    fi

    # Address the bootloader decompresses to. Note that some bootloaders
    # read this field from the image in slot A even when booting slot B,
    # so both slots need the same value.
    hex32 "$loadaddr"

    # "reserved" 128 bytes of zeros
    head -c 128 /dev/zero | to_hex

    # trailing header padding up to 280 bytes (vendor struct extension)
    head -c "$HDRPAD" /dev/zero | to_hex
}

tclinux_trx_hdr | from_hex
cat "$kernel"
padding
if [ -f "$rootfs" ]; then
    cat "$rootfs"
fi

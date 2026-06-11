#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/opencca_paths.sh"

OPENCCA_LINUX_DIR="${OPENCCA_LINUX_DIR:-$OPENCCA_WORK_DIR/linux}"
KERNEL_IMAGE_SOURCE="${OPENCCA_KERNEL_IMAGE_SOURCE:-}"
KERNEL_DTB_SOURCE="${OPENCCA_KERNEL_DTB_SOURCE:-}"
KERNEL_INITRD_SOURCE="${OPENCCA_KERNEL_INITRD_SOURCE:-}"
OPENCCA_KERNEL_ROOT="${OPENCCA_KERNEL_ROOT:-PARTLABEL=root}"
OPENCCA_KERNEL_VERSION="${OPENCCA_KERNEL_VERSION:-6.12.0-opencca-wip}"
OPENCCA_KERNEL_CMDLINE="${OPENCCA_KERNEL_CMDLINE:-rootwait isolcpus=1,2,3 maxcpus=2 nohlt cpuidle.off=1 rcupdate.rcu_cpu_st}"
DRY_RUN=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Build the fixed-size OpenCCA RK3588 kernel boot partition image. The output is
an ext4 filesystem that U-Boot can discover through bootflow/extlinux, and is
suitable for rkdeveloptool wl OPENCCA_KERNEL_SLOT_START.

Options:
  --image PATH        Linux Image input. Default: snapshot/Image, then linux tree.
  --dtb PATH          rk3588-rock-5b.dtb input. Default: linux tree, then snapshot.
  --initrd PATH       Initrd image to include. Recommended for OpenCCA Debian.
  --root VALUE        Kernel root= value. Default: $OPENCCA_KERNEL_ROOT
  --version VALUE     Kernel version string used in /boot names.
                     Default: $OPENCCA_KERNEL_VERSION
  --cmdline VALUE     Extra kernel command line after root=VALUE.
  --output PATH       Kernel partition output. Default: $OPENCCA_KERNEL_IMAGE
  --slot-sectors N    Kernel slot sectors. Default: $OPENCCA_KERNEL_SLOT_SECTORS
  --dry-run           Print commands without running them.
  -h, --help          Show this help.

Environment:
  OPENCCA_WORK_DIR              Default: $OPENCCA_WORK_DIR
  OPENCCA_SNAPSHOT_DIR          Default: $OPENCCA_SNAPSHOT_DIR
  OPENCCA_LINUX_DIR             Default: $OPENCCA_LINUX_DIR
  OPENCCA_KERNEL_ROOT           Default: $OPENCCA_KERNEL_ROOT
  OPENCCA_KERNEL_INITRD_SOURCE  Optional initrd input.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)
            shift
            [[ $# -gt 0 ]] || opencca_die "--image requires a path"
            KERNEL_IMAGE_SOURCE="$1"
            ;;
        --dtb)
            shift
            [[ $# -gt 0 ]] || opencca_die "--dtb requires a path"
            KERNEL_DTB_SOURCE="$1"
            ;;
        --initrd)
            shift
            [[ $# -gt 0 ]] || opencca_die "--initrd requires a path"
            KERNEL_INITRD_SOURCE="$1"
            ;;
        --root)
            shift
            [[ $# -gt 0 ]] || opencca_die "--root requires a value"
            OPENCCA_KERNEL_ROOT="$1"
            ;;
        --version)
            shift
            [[ $# -gt 0 ]] || opencca_die "--version requires a value"
            OPENCCA_KERNEL_VERSION="$1"
            ;;
        --cmdline)
            shift
            [[ $# -gt 0 ]] || opencca_die "--cmdline requires a value"
            OPENCCA_KERNEL_CMDLINE="$1"
            ;;
        --output)
            shift
            [[ $# -gt 0 ]] || opencca_die "--output requires a path"
            OPENCCA_KERNEL_IMAGE="$1"
            ;;
        --slot-sectors)
            shift
            [[ $# -gt 0 ]] || opencca_die "--slot-sectors requires a value"
            OPENCCA_KERNEL_SLOT_SECTORS="$1"
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            opencca_die "unknown option: $1"
            ;;
    esac
    shift
done

run_cmd() {
    printf '[opencca-kernel]'
    printf ' %q' "$@"
    printf '\n'
    if [[ "$DRY_RUN" == "0" ]]; then
        "$@"
    fi
}

copy_if_different() {
    local src="$1"
    local dst="$2"
    if [[ "$(readlink -f "$src")" == "$(readlink -m "$dst")" ]]; then
        opencca_log "using existing $dst"
        return 0
    fi
    run_cmd cp -f "$src" "$dst"
}

find_default_image() {
    local candidate
    for candidate in \
        "$OPENCCA_SNAPSHOT_DIR/vmlinuz-$OPENCCA_KERNEL_VERSION" \
        "$OPENCCA_SNAPSHOT_DIR/Image" \
        "$OPENCCA_LINUX_DIR/arch/arm64/boot/Image"; do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

find_default_initrd() {
    local candidate
    for candidate in \
        "$OPENCCA_SNAPSHOT_DIR/initrd.img-$OPENCCA_KERNEL_VERSION" \
        "$OPENCCA_SNAPSHOT_DIR/initrd.img"; do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

find_default_dtb() {
    local candidate
    for candidate in \
        "$OPENCCA_LINUX_DIR/arch/arm64/boot/dts/rockchip/rk3588-rock-5b.dtb" \
        "$OPENCCA_SNAPSHOT_DIR/rk3588-rock-5b.dtb"; do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

if [[ -z "$KERNEL_IMAGE_SOURCE" ]]; then
    KERNEL_IMAGE_SOURCE=$(find_default_image) || opencca_die "missing Linux Image/vmlinuz; build the kernel or pass --image"
fi
if [[ -z "$KERNEL_DTB_SOURCE" ]]; then
    KERNEL_DTB_SOURCE=$(find_default_dtb) || opencca_die "missing rk3588-rock-5b.dtb; build dtbs or pass --dtb"
fi
if [[ -z "$KERNEL_INITRD_SOURCE" ]]; then
    KERNEL_INITRD_SOURCE=$(find_default_initrd || true)
fi

opencca_require_file "$KERNEL_IMAGE_SOURCE"
opencca_require_file "$KERNEL_DTB_SOURCE"
opencca_require_cmd mkfs.ext4 stat truncate sha256sum

slot_bytes=$(( OPENCCA_KERNEL_SLOT_SECTORS * 512 ))
output_dir=$(dirname "$OPENCCA_KERNEL_IMAGE")
tmpdir=""

cleanup() {
    [[ -z "$tmpdir" ]] || rm -rf "$tmpdir"
}
trap cleanup EXIT

run_cmd mkdir -p "$output_dir"
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/opencca-kernel-bootfs.XXXXXX")
staging="$tmpdir/staging"
image_tmp="$tmpdir/kernel.img"
run_cmd mkdir -p \
    "$staging/boot/extlinux" \
    "$staging/usr/lib/linux-image-$OPENCCA_KERNEL_VERSION/rockchip"

copy_if_different "$KERNEL_IMAGE_SOURCE" "$staging/boot/vmlinuz-$OPENCCA_KERNEL_VERSION"
copy_if_different "$KERNEL_DTB_SOURCE" "$staging/usr/lib/linux-image-$OPENCCA_KERNEL_VERSION/rockchip/rk3588-rock-5b.dtb"
initrd_line=""
if [[ -n "$KERNEL_INITRD_SOURCE" ]]; then
    opencca_require_file "$KERNEL_INITRD_SOURCE"
    copy_if_different "$KERNEL_INITRD_SOURCE" "$staging/boot/initrd.img-$OPENCCA_KERNEL_VERSION"
    initrd_line=$'\tinitrd /boot/initrd.img-'"$OPENCCA_KERNEL_VERSION"
else
    opencca_log "building without initrd; pass --initrd for the stock OpenCCA Debian boot path"
fi

if [[ "$DRY_RUN" == "0" ]]; then
    cat >"$staging/boot/extlinux/extlinux.conf" <<EOF
default l0
menu title U-Boot menu
prompt 0
timeout 1

label l0
	menu label OpenCCA RK3588 $OPENCCA_KERNEL_VERSION
	linux /boot/vmlinuz-$OPENCCA_KERNEL_VERSION
$initrd_line
	fdtdir /usr/lib/linux-image-$OPENCCA_KERNEL_VERSION/
	append root=$OPENCCA_KERNEL_ROOT $OPENCCA_KERNEL_CMDLINE

label l0r
	menu label OpenCCA RK3588 $OPENCCA_KERNEL_VERSION rescue
	linux /boot/vmlinuz-$OPENCCA_KERNEL_VERSION
$initrd_line
	fdtdir /usr/lib/linux-image-$OPENCCA_KERNEL_VERSION/
	append root=$OPENCCA_KERNEL_ROOT $OPENCCA_KERNEL_CMDLINE single
EOF
fi

run_cmd truncate -s "$slot_bytes" "$image_tmp"
run_cmd mkfs.ext4 -F -L kernel -m 0 -d "$staging" "$image_tmp"
run_cmd cp -f "$image_tmp" "$OPENCCA_KERNEL_IMAGE"
run_cmd sha256sum "$OPENCCA_KERNEL_IMAGE"

if [[ "$DRY_RUN" == "0" ]]; then
    actual_bytes=$(stat -c%s "$OPENCCA_KERNEL_IMAGE")
    if (( actual_bytes != slot_bytes )); then
        opencca_die "kernel image size mismatch: $actual_bytes != $slot_bytes"
    fi
    opencca_log "wrote ext4 kernel boot partition: $OPENCCA_KERNEL_IMAGE"
fi

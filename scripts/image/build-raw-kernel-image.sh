#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/opencca_paths.sh"

OPENCCA_LINUX_DIR="${OPENCCA_LINUX_DIR:-$OPENCCA_WORK_DIR/linux}"
OPENCCA_UBOOT_DIR="${OPENCCA_UBOOT_DIR:-$OPENCCA_WORK_DIR/u-boot}"
OPENCCA_RKBIN_DIR="${OPENCCA_RKBIN_DIR:-$OPENCCA_WORK_DIR/rkbin}"
KERNEL_IMAGE_SOURCE="${OPENCCA_KERNEL_IMAGE_SOURCE:-}"
KERNEL_DTB_SOURCE="${OPENCCA_KERNEL_DTB_SOURCE:-}"
DRY_RUN=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Build the fixed-size raw OpenCCA RK3588 kernel slot image from a Linux Image
and rk3588-rock-5b.dtb. The output is suitable for rkdeveloptool wl
OPENCCA_KERNEL_SLOT_START.

Options:
  --image PATH        Linux Image input. Default: snapshot/Image, then linux tree.
  --dtb PATH          rk3588-rock-5b.dtb input. Default: linux tree, then snapshot.
  --output PATH       Raw kernel output. Default: $OPENCCA_KERNEL_IMAGE
  --slot-sectors N    Raw slot sectors. Default: $OPENCCA_KERNEL_SLOT_SECTORS
  --load-addr ADDR    FIT load address. Default: $OPENCCA_KERNEL_LOAD_ADDR
  --entry-addr ADDR   FIT entry address. Default: $OPENCCA_KERNEL_ENTRY_ADDR
  --dry-run           Print commands without running them.
  -h, --help          Show this help.

Environment:
  OPENCCA_WORK_DIR              Default: $OPENCCA_WORK_DIR
  OPENCCA_SNAPSHOT_DIR          Default: $OPENCCA_SNAPSHOT_DIR
  OPENCCA_LINUX_DIR             Default: $OPENCCA_LINUX_DIR
  OPENCCA_UBOOT_DIR             Default: $OPENCCA_UBOOT_DIR
  OPENCCA_MKIMAGE               Optional mkimage path.
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
        --load-addr)
            shift
            [[ $# -gt 0 ]] || opencca_die "--load-addr requires a value"
            OPENCCA_KERNEL_LOAD_ADDR="$1"
            ;;
        --entry-addr)
            shift
            [[ $# -gt 0 ]] || opencca_die "--entry-addr requires a value"
            OPENCCA_KERNEL_ENTRY_ADDR="$1"
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

run_cmd_in_dir() {
    local dir="$1"
    shift
    printf '[opencca-kernel] cd %q &&' "$dir"
    printf ' %q' "$@"
    printf '\n'
    if [[ "$DRY_RUN" == "0" ]]; then
        (cd "$dir" && "$@")
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
        "$OPENCCA_SNAPSHOT_DIR/Image" \
        "$OPENCCA_LINUX_DIR/arch/arm64/boot/Image"; do
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

find_mkimage() {
    local candidate
    if [[ -n "${OPENCCA_MKIMAGE:-}" ]]; then
        printf '%s\n' "$OPENCCA_MKIMAGE"
        return 0
    fi
    if command -v mkimage >/dev/null 2>&1; then
        command -v mkimage
        return 0
    fi
    for candidate in \
        "$OPENCCA_UBOOT_DIR/tools/mkimage" \
        "$OPENCCA_RKBIN_DIR/tools/mkimage"; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

if [[ -z "$KERNEL_IMAGE_SOURCE" ]]; then
    KERNEL_IMAGE_SOURCE=$(find_default_image) || opencca_die "missing Linux Image; build the kernel or pass --image"
fi
if [[ -z "$KERNEL_DTB_SOURCE" ]]; then
    KERNEL_DTB_SOURCE=$(find_default_dtb) || opencca_die "missing rk3588-rock-5b.dtb; build dtbs or pass --dtb"
fi
MKIMAGE=$(find_mkimage) || opencca_die "missing mkimage; build U-Boot tools or install u-boot-tools"

opencca_require_file "$KERNEL_IMAGE_SOURCE"
opencca_require_file "$KERNEL_DTB_SOURCE"
opencca_require_cmd stat truncate sha256sum

slot_bytes=$(( OPENCCA_KERNEL_SLOT_SECTORS * 512 ))
output_dir=$(dirname "$OPENCCA_KERNEL_IMAGE")
its_path="${OPENCCA_KERNEL_ITS:-$output_dir/kernel.its}"
itb_path="${OPENCCA_KERNEL_ITB:-$output_dir/kernel.itb}"
image_copy="$output_dir/Image"
dtb_copy="$output_dir/rk3588-rock-5b.dtb"

run_cmd mkdir -p "$output_dir"
copy_if_different "$KERNEL_IMAGE_SOURCE" "$image_copy"
copy_if_different "$KERNEL_DTB_SOURCE" "$dtb_copy"

if [[ "$DRY_RUN" == "0" ]]; then
    cat >"$its_path" <<EOF
/dts-v1/;

/ {
	description = "OpenCCA RK3588 kernel";
	#address-cells = <1>;

	images {
		kernel {
			description = "Linux Image";
			data = /incbin/("Image");
			type = "kernel";
			arch = "arm64";
			os = "linux";
			compression = "none";
			load = <$OPENCCA_KERNEL_LOAD_ADDR>;
			entry = <$OPENCCA_KERNEL_ENTRY_ADDR>;
			hash {
				algo = "sha256";
			};
		};

		fdt {
			description = "Rock 5B device tree";
			data = /incbin/("rk3588-rock-5b.dtb");
			type = "flat_dt";
			arch = "arm64";
			compression = "none";
			hash {
				algo = "sha256";
			};
		};
	};

	configurations {
		default = "conf";
		conf {
			description = "OpenCCA RK3588";
			kernel = "kernel";
			fdt = "fdt";
		};
	};
};
EOF
else
    opencca_log "would write $its_path"
fi

run_cmd_in_dir "$output_dir" "$MKIMAGE" -f "$(basename "$its_path")" "$(basename "$itb_path")"

if [[ "$DRY_RUN" == "0" ]]; then
    itb_bytes=$(stat -c%s "$itb_path")
    if (( itb_bytes > slot_bytes )); then
        opencca_die "$itb_path is too large: $itb_bytes bytes > $slot_bytes bytes"
    fi
fi

run_cmd cp -f "$itb_path" "$OPENCCA_KERNEL_IMAGE"
run_cmd truncate -s "$slot_bytes" "$OPENCCA_KERNEL_IMAGE"
if [[ "$DRY_RUN" == "0" ]]; then
    sha256sum "$OPENCCA_KERNEL_IMAGE"
    opencca_log "raw kernel slot image: $OPENCCA_KERNEL_IMAGE ($slot_bytes bytes, start $OPENCCA_KERNEL_SLOT_START)"
fi

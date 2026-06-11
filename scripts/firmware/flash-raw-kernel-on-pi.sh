#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)

if [[ -z "${OPENCCA_RPI_FLASH_ROOT:-}" ]]; then
    if [[ -x "$SCRIPT_ROOT/tools/rkdeveloptool" && -d "$SCRIPT_ROOT/snapshot" ]]; then
        OPENCCA_RPI_FLASH_ROOT="$SCRIPT_ROOT"
    elif [[ "$(basename "$SCRIPT_ROOT")" == "opencca-scripts" ]]; then
        OPENCCA_RPI_FLASH_ROOT=$(cd -- "$SCRIPT_ROOT/.." && pwd)
    else
        OPENCCA_RPI_FLASH_ROOT="/home/mzh/opencca-flash"
    fi
fi

if [[ -f "$OPENCCA_RPI_FLASH_ROOT/.env" ]]; then
    # shellcheck disable=SC1091
    source "$OPENCCA_RPI_FLASH_ROOT/.env"
fi

SNAPSHOT_DIR="${OPENCCA_SNAPSHOT_DIR:-$OPENCCA_RPI_FLASH_ROOT/snapshot}"
RKDEVELOP_TOOL="${OPENCCA_RKDEVELOP_TOOL:-$OPENCCA_RPI_FLASH_ROOT/tools/rkdeveloptool}"
OPENCCA_SPL_LOADER="${OPENCCA_SPL_LOADER:-$OPENCCA_RPI_FLASH_ROOT/tools/rk3588/rk3588_spl_loader_v1.16.113.bin}"
OPENCCA_KERNEL_IMAGE="${OPENCCA_KERNEL_IMAGE:-$SNAPSHOT_DIR/kernel-extlinux.img}"
OPENCCA_KERNEL_STORAGE_ID="${OPENCCA_KERNEL_STORAGE_ID:-2}"
OPENCCA_SD_STORAGE_ID="${OPENCCA_SD_STORAGE_ID:-2}"
OPENCCA_KERNEL_SLOT_START="${OPENCCA_KERNEL_SLOT_START:-0x8000}"
OPENCCA_KERNEL_SLOT_SECTORS="${OPENCCA_KERNEL_SLOT_SECTORS:-0x40000}"
OPENCCA_KERNEL_GPT_READ_SECTORS="${OPENCCA_KERNEL_GPT_READ_SECTORS:-2048}"
OPENCCA_NO_REBOOT_AFTER_KERNEL_FLASH="${OPENCCA_NO_REBOOT_AFTER_KERNEL_FLASH:-0}"

BOARD_CTRL="$OPENCCA_RPI_FLASH_ROOT/board/board.sh"
MASKROM_CTRL="$OPENCCA_RPI_FLASH_ROOT/board/maskrom/maskrom.sh"
VALIDATOR="$SCRIPT_DIR/validate-gpt-slot.py"

read -r -a RKDEVELOP_CMD <<<"$RKDEVELOP_TOOL"

usage() {
    cat <<EOF
Usage: $(basename "$0")

Flash only the OpenCCA RK3588 kernel boot slot on SD storage.

Environment:
  OPENCCA_RPI_FLASH_ROOT          Default: $OPENCCA_RPI_FLASH_ROOT
  OPENCCA_KERNEL_IMAGE            Default: $OPENCCA_KERNEL_IMAGE
  OPENCCA_KERNEL_STORAGE_ID       Default: $OPENCCA_KERNEL_STORAGE_ID (2=SD)
  OPENCCA_KERNEL_SLOT_START       Default: $OPENCCA_KERNEL_SLOT_START
  OPENCCA_KERNEL_SLOT_SECTORS     Default: $OPENCCA_KERNEL_SLOT_SECTORS
  OPENCCA_KERNEL_GPT_READ_SECTORS Default: $OPENCCA_KERNEL_GPT_READ_SECTORS
  OPENCCA_ALLOW_NON_SD_KERNEL_FLASH=1 to override SD-only guard.
  OPENCCA_SKIP_KERNEL_GPT_CHECK=1 to bypass GPT validation.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

log() {
    printf '[opencca-kernel-flash] %s\n' "$*"
}

die() {
    printf '[opencca-kernel-flash] error: %s\n' "$*" >&2
    exit 1
}

require_file() {
    local file="$1"
    [[ -f "$file" ]] || die "missing expected file: $file"
}

rk() {
    "${RKDEVELOP_CMD[@]}" "$@"
}

if [[ "${EUID:-$(id -u)}" -ne 0 && "${OPENCCA_NO_AUTO_SUDO:-0}" != "1" ]]; then
    exec sudo -E "$0" "$@"
fi

require_file "$OPENCCA_KERNEL_IMAGE"
require_file "$OPENCCA_SPL_LOADER"
require_file "$BOARD_CTRL"
require_file "$MASKROM_CTRL"
require_file "$VALIDATOR"
command -v python3 >/dev/null 2>&1 || die "missing python3 on Raspberry Pi"

if [[ "$OPENCCA_KERNEL_STORAGE_ID" != "$OPENCCA_SD_STORAGE_ID" && "${OPENCCA_ALLOW_NON_SD_KERNEL_FLASH:-0}" != "1" ]]; then
    die "refusing kernel flash to storage ID $OPENCCA_KERNEL_STORAGE_ID; expected SD storage ID $OPENCCA_SD_STORAGE_ID"
fi

kernel_bytes=$(stat -c%s "$OPENCCA_KERNEL_IMAGE")
slot_bytes=$(( OPENCCA_KERNEL_SLOT_SECTORS * 512 ))
if (( kernel_bytes > slot_bytes )); then
    die "kernel image is too large: $kernel_bytes bytes > $slot_bytes bytes"
fi
if (( kernel_bytes % 512 != 0 )); then
    die "kernel image size is not 512-byte aligned: $kernel_bytes bytes"
fi

is_in_maskrom() {
    rk ld 2>/dev/null | grep -iq "maskrom"
}

enter_maskrom() {
    local timeout="${OPENCCA_MASKROM_TIMEOUT:-60}"
    local start_time
    local elapsed
    local pid=""

    if is_in_maskrom; then
        log "device already in Maskrom mode"
        return 0
    fi

    log "entering Maskrom mode"
    bash "$BOARD_CTRL" maskrom &
    pid=$!
    start_time=$(date +%s)
    while ! is_in_maskrom; do
        elapsed=$(( $(date +%s) - start_time ))
        if (( elapsed >= timeout )); then
            wait "$pid" || true
            die "device did not enter Maskrom mode within ${timeout}s"
        fi
        sleep 1
    done
    wait "$pid"
}

transfer_loader() {
    if rk rcb 2>/dev/null | grep -q "Capability:"; then
        log "loader already transferred"
        return 0
    fi

    log "transferring SPL loader: $OPENCCA_SPL_LOADER"
    (cd "$SNAPSHOT_DIR" && rk db "$OPENCCA_SPL_LOADER")
}

select_storage() {
    log "selecting Rockchip storage ID $OPENCCA_KERNEL_STORAGE_ID"
    rk cs "$OPENCCA_KERNEL_STORAGE_ID"
    rk rfi
}

validate_gpt_slot() {
    local tmpdir
    local gpt_dump

    if [[ "${OPENCCA_SKIP_KERNEL_GPT_CHECK:-0}" == "1" ]]; then
        log "GPT validation bypassed by OPENCCA_SKIP_KERNEL_GPT_CHECK=1"
        return 0
    fi

    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/opencca-kernel-gpt.XXXXXX")
    gpt_dump="$tmpdir/gpt.bin"
    cleanup_gpt() {
        rm -rf "$tmpdir"
    }
    trap cleanup_gpt RETURN

    log "reading GPT before kernel boot slot write"
    rk rl 0 "$OPENCCA_KERNEL_GPT_READ_SECTORS" "$gpt_dump"
    python3 "$VALIDATOR" \
        "$gpt_dump" \
        "$OPENCCA_KERNEL_SLOT_START" \
        "$OPENCCA_KERNEL_SLOT_SECTORS" \
        --name kernel
    trap - RETURN
    cleanup_gpt
}

release_maskrom_button() {
    bash "$MASKROM_CTRL" release
}

enter_maskrom
transfer_loader
select_storage
validate_gpt_slot

log "writing $(basename "$OPENCCA_KERNEL_IMAGE") to kernel slot LBA $OPENCCA_KERNEL_SLOT_START"
rk wl "$OPENCCA_KERNEL_SLOT_START" "$OPENCCA_KERNEL_IMAGE"
release_maskrom_button

if [[ "$OPENCCA_NO_REBOOT_AFTER_KERNEL_FLASH" == "1" ]]; then
    log "kernel flash complete; reboot skipped"
else
    rk rd
    log "kernel flash complete; board reset requested"
fi

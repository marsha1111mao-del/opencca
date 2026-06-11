#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/opencca_paths.sh"

DO_SYNC=1
FLASH_COMMAND=""
SYNC_FIRMWARE=1
SYNC_ROOTFS=0
SYNC_KERNEL=0
BUILD_KERNEL_IMAGE=0
ROOTFS_ARG="$OPENCCA_ROOTFS_IMAGE"
KERNEL_ARG="$OPENCCA_KERNEL_IMAGE"
PATCH_ROOTFS_ON_PI=0
WAIT_RK=0
DRY_RUN=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Sync OpenCCA artifacts to the Raspberry Pi flash host and optionally invoke
/home/mzh/opencca-flash/flash.sh.

Options:
  --sync-only          Sync firmware artifacts only. This is the default.
  --sync-rootfs        Also sync OPENCCA_ROOTFS_IMAGE to the Pi snapshot dir.
  --sync-kernel        Sync OPENCCA_KERNEL_IMAGE and Pi kernel-flash helpers.
  --build-kernel-image Build OPENCCA_KERNEL_IMAGE from local Image + DTB first.
  --patch-rootfs-on-pi Patch rootfs image on the Pi before flashing.
  --flash-mmc          Flash SD boot firmware: idbloader.img and u-boot.itb.
  --flash-sd-firmware  Alias for --flash-mmc.
  --flash-kernel       Flash only the SD kernel boot slot.
  --flash-spi          Run: sudo ./flash.sh spi
  --flash-rootfs       Flash full rootfs image to SD.
  --kernel-image PATH  Use PATH for --sync-kernel/--flash-kernel.
  --reboot             Run: sudo ./flash.sh reboot
  --device             Run: sudo ./flash.sh device
  --no-sync            Skip rsync and only run the selected flash command.
  --wait-rk            Wait for RK3588 SSH after the flash command.
  --dry-run            Print commands without running them.
  -h, --help           Show this help.

Environment:
  OPENCCA_RPI_HOST          Default: $OPENCCA_RPI_HOST
  OPENCCA_RPI_PASSWORD      Optional; use SSH keys/agent when unset.
  OPENCCA_RPI_SUDO_PASSWORD Required for sudo flash/rootfs patch commands.
  OPENCCA_RPI_FLASH_ROOT    Default: $OPENCCA_RPI_FLASH_ROOT
  OPENCCA_SNAPSHOT_DIR      Default: $OPENCCA_SNAPSHOT_DIR
  OPENCCA_ROOTFS_IMAGE      Default: $OPENCCA_ROOTFS_IMAGE
  OPENCCA_KERNEL_IMAGE      Default: $OPENCCA_KERNEL_IMAGE
  OPENCCA_KERNEL_SLOT_START Default: $OPENCCA_KERNEL_SLOT_START
  OPENCCA_KERNEL_SLOT_SECTORS Default: $OPENCCA_KERNEL_SLOT_SECTORS
  OPENCCA_FIRMWARE_STORAGE_ID Default: $OPENCCA_FIRMWARE_STORAGE_ID (rkdeveloptool: 2=SD, 1=EMMC)
  OPENCCA_ROOTFS_STORAGE_ID   Default: $OPENCCA_ROOTFS_STORAGE_ID (rkdeveloptool: 2=SD, 1=EMMC)
  OPENCCA_KERNEL_STORAGE_ID   Default: $OPENCCA_KERNEL_STORAGE_ID (rkdeveloptool: 2=SD, 1=EMMC)
  OPENCCA_RK_HOST           Default: $OPENCCA_RK_HOST
  OPENCCA_RK_PASSWORD       Optional; use SSH keys/agent when unset.
  OPENCCA_RK_ROOT_PASSWORD  Required with --patch-rootfs-on-pi.
  OPENCCA_SKIP_RK_KERNEL_LAYOUT_PREFLIGHT=1 skips live RK SSH preflight.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sync-only)
            FLASH_COMMAND=""
            ;;
        --sync-rootfs)
            SYNC_ROOTFS=1
            ROOTFS_ARG="$OPENCCA_ROOTFS_IMAGE"
            ;;
        --sync-kernel)
            SYNC_KERNEL=1
            SYNC_FIRMWARE=0
            KERNEL_ARG="$OPENCCA_KERNEL_IMAGE"
            ;;
        --build-kernel-image)
            BUILD_KERNEL_IMAGE=1
            SYNC_KERNEL=1
            KERNEL_ARG="$OPENCCA_KERNEL_IMAGE"
            ;;
        --patch-rootfs-on-pi)
            PATCH_ROOTFS_ON_PI=1
            ROOTFS_ARG="$OPENCCA_ROOTFS_IMAGE"
            ;;
        --flash-mmc|--flash-sd-firmware)
            FLASH_COMMAND="mmc"
            ;;
        --flash-kernel)
            FLASH_COMMAND="kernel"
            SYNC_KERNEL=1
            SYNC_FIRMWARE=0
            KERNEL_ARG="$OPENCCA_KERNEL_IMAGE"
            ;;
        --flash-spi)
            FLASH_COMMAND="spi"
            ;;
        --flash-rootfs)
            FLASH_COMMAND="rootfs"
            ROOTFS_ARG="$OPENCCA_ROOTFS_IMAGE"
            ;;
        --kernel-image)
            shift
            [[ $# -gt 0 ]] || opencca_die "--kernel-image requires a path"
            KERNEL_ARG="$1"
            OPENCCA_KERNEL_IMAGE="$KERNEL_ARG"
            ;;
        --reboot)
            FLASH_COMMAND="reboot"
            ;;
        --device)
            FLASH_COMMAND="device"
            ;;
        --no-sync)
            DO_SYNC=0
            ;;
        --wait-rk)
            WAIT_RK=1
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

opencca_require_cmd ssh rsync sha256sum
if [[ -n "$OPENCCA_RPI_PASSWORD$OPENCCA_RK_PASSWORD" ]]; then
    opencca_require_cmd sshpass
fi

if [[ "$PATCH_ROOTFS_ON_PI" == "1" && -z "$OPENCCA_RK_ROOT_PASSWORD" ]]; then
    opencca_die "set OPENCCA_RK_ROOT_PASSWORD when using --patch-rootfs-on-pi"
fi

run_cmd() {
    printf '[opencca-flash]'
    printf ' %q' "$@"
    printf '\n'
    if [[ "$DRY_RUN" == "0" ]]; then
        "$@"
    fi
}

require_firmware_artifacts() {
    local name
    for name in idbloader.img u-boot.itb u-boot-rockchip-spi.bin tf-rmm.elf; do
        opencca_require_file "$OPENCCA_SNAPSHOT_DIR/$name"
    done
}

require_kernel_artifacts() {
    opencca_require_file "$KERNEL_ARG"
    opencca_require_file "$OPENCCA_WORK_DIR/scripts/firmware/flash-raw-kernel-on-pi.sh"
    opencca_require_file "$OPENCCA_WORK_DIR/scripts/firmware/validate-gpt-slot.py"
}

require_sd_storage() {
    local storage_id="$1"
    local operation="$2"

    [[ -n "$storage_id" ]] || opencca_die "$operation requires an explicit storage ID"
    if [[ "$storage_id" != "$OPENCCA_SD_STORAGE_ID" ]]; then
        opencca_die "$operation refused: storage ID $storage_id selected; this workflow targets SD storage ID $OPENCCA_SD_STORAGE_ID"
    fi
}

quote_env_assignment() {
    local name="$1"
    local value="$2"
    printf '%q=%q' "$name" "$value"
}

preflight_rk_kernel_layout() {
    local rk_ssh_cmd expected_start expected_sectors remote_script output rc

    if [[ "${OPENCCA_SKIP_RK_KERNEL_LAYOUT_PREFLIGHT:-0}" == "1" ]]; then
        opencca_log "skipping live RK kernel-slot preflight"
        return 0
    fi

    expected_start="$OPENCCA_KERNEL_SLOT_START"
    expected_sectors="$OPENCCA_KERNEL_SLOT_SECTORS"
    rk_ssh_cmd=(
        ssh
        -p "$OPENCCA_RK_SSH_PORT"
        -oBatchMode=no
        -oStrictHostKeyChecking=no
        -oUserKnownHostsFile=/dev/null
        -oConnectTimeout=8
    )
    if [[ -n "$OPENCCA_RK_PASSWORD" ]]; then
        rk_ssh_cmd=(sshpass -p "$OPENCCA_RK_PASSWORD" "${rk_ssh_cmd[@]}")
    fi

    remote_script='
set -euo pipefail
expected_start=$((OPENCCA_KERNEL_SLOT_START))
expected_sectors=$((OPENCCA_KERNEL_SLOT_SECTORS))
root_source=$(findmnt -no SOURCE / 2>/dev/null || true)
if [[ -z "$root_source" ]]; then
    echo "cannot determine root filesystem source" >&2
    exit 43
fi
root_block=$(basename "$(readlink -f "$root_source")")
disk=""
if [[ "$root_block" =~ ^(mmcblk[0-9]+)p[0-9]+$ ]]; then
    disk="${BASH_REMATCH[1]}"
elif [[ "$root_block" =~ ^([a-z]+[0-9]+n[0-9]+)p[0-9]+$ ]]; then
    disk="${BASH_REMATCH[1]}"
fi
if [[ -z "$disk" || ! -d "/sys/class/block/$disk" ]]; then
    echo "root source $root_source is not an SD/eMMC partition" >&2
    exit 43
fi

kernel_ok=0
details=""
for part_path in /sys/class/block/"$disk"p*; do
    [[ -e "$part_path" ]] || continue
    part=$(basename "$part_path")
    label=$(blkid -s PARTLABEL -o value "/dev/$part" 2>/dev/null || true)
    start=$(cat "$part_path/start")
    sectors=$(cat "$part_path/size")
    details="${details}${part} label=${label:-<none>} start=${start} sectors=${sectors}"$'\''\n'\''
    if [[ "$label" == "kernel" && "$start" -eq "$expected_start" && "$sectors" -ge "$expected_sectors" ]]; then
        kernel_ok=1
    fi
done

if [[ "$kernel_ok" -ne 1 ]]; then
    echo "OPENCCA_KERNEL_PREFLIGHT_INCOMPATIBLE=1" >&2
    echo "RK SD layout does not contain a compatible kernel boot slot." >&2
    echo "Expected PARTLABEL=kernel start=$expected_start sectors>=$expected_sectors." >&2
    printf "%s" "$details" >&2
    exit 42
fi
'

    if output=$("${rk_ssh_cmd[@]}" "$OPENCCA_RK_HOST" \
        "OPENCCA_KERNEL_SLOT_START=$(printf '%q' "$expected_start") OPENCCA_KERNEL_SLOT_SECTORS=$(printf '%q' "$expected_sectors") bash -s" \
        <<<"$remote_script" 2>&1); then
        opencca_log "live RK kernel-slot preflight passed"
        [[ -z "$output" ]] || printf '%s\n' "$output"
        return 0
    else
        rc=$?
    fi

    if [[ "$rc" == "42" || "$output" == *"OPENCCA_KERNEL_PREFLIGHT_INCOMPATIBLE=1"* ]]; then
        printf '%s\n' "$output" >&2
        opencca_die "kernel flash refused before Maskrom: current SD layout would not protect rootfs"
    fi

    opencca_log "live RK preflight unavailable; Pi-side GPT validation will be authoritative"
    [[ -z "$output" ]] || printf '%s\n' "$output" >&2
}

pi_ssh_cmd=(
    ssh
    -tt
    -p "$OPENCCA_RPI_SSH_PORT"
    -oBatchMode=no
    -oStrictHostKeyChecking=accept-new
    -oUserKnownHostsFile=/tmp/opencca_known_hosts
)
pi_ssh_for_rsync=(
    ssh
    -p "$OPENCCA_RPI_SSH_PORT"
    -oBatchMode=no
    -oStrictHostKeyChecking=accept-new
    -oUserKnownHostsFile=/tmp/opencca_known_hosts
)
if [[ -n "$OPENCCA_RPI_PASSWORD" ]]; then
    pi_ssh_cmd=(sshpass -p "$OPENCCA_RPI_PASSWORD" "${pi_ssh_cmd[@]}")
    pi_ssh_for_rsync=(sshpass -p "$OPENCCA_RPI_PASSWORD" "${pi_ssh_for_rsync[@]}")
fi

rsync_ssh="$(printf ' %q' "${pi_ssh_for_rsync[@]}")"
rsync_ssh="${rsync_ssh# }"

if [[ "$BUILD_KERNEL_IMAGE" == "1" ]]; then
    run_cmd "$OPENCCA_WORK_DIR/scripts/image/build-raw-kernel-image.sh" --output "$KERNEL_ARG"
fi

if [[ "$FLASH_COMMAND" == "kernel" ]]; then
    require_sd_storage "$OPENCCA_KERNEL_STORAGE_ID" "kernel flash"
    preflight_rk_kernel_layout
fi

if [[ "$DO_SYNC" == "1" ]]; then
    if [[ "$SYNC_FIRMWARE" == "1" ]]; then
        require_firmware_artifacts
        run_cmd rsync -av --checksum -e "$rsync_ssh" \
            "$OPENCCA_SNAPSHOT_DIR/idbloader.img" \
            "$OPENCCA_SNAPSHOT_DIR/u-boot.itb" \
            "$OPENCCA_SNAPSHOT_DIR/u-boot-rockchip-spi.bin" \
            "$OPENCCA_SNAPSHOT_DIR/tf-rmm.elf" \
            "$OPENCCA_RPI_HOST:$OPENCCA_RPI_FLASH_ROOT/snapshot/"
    fi

    if [[ "$SYNC_KERNEL" == "1" ]]; then
        require_kernel_artifacts
        run_cmd rsync -av --checksum -e "$rsync_ssh" \
            "$KERNEL_ARG" \
            "$OPENCCA_RPI_HOST:$OPENCCA_RPI_FLASH_ROOT/snapshot/"
    fi

    if [[ "$SYNC_ROOTFS" == "1" ]]; then
        opencca_require_file "$ROOTFS_ARG"
        run_cmd rsync -av --checksum --progress -e "$rsync_ssh" \
            "$ROOTFS_ARG" \
            "$OPENCCA_RPI_HOST:$OPENCCA_RPI_FLASH_ROOT/snapshot/"
    fi

    if [[ "$PATCH_ROOTFS_ON_PI" == "1" || "$SYNC_KERNEL" == "1" ]]; then
        run_cmd rsync -av --delete --delete-excluded \
            --exclude '__pycache__/' \
            --exclude '*.pyc' \
            -e "$rsync_ssh" \
            "$OPENCCA_WORK_DIR/scripts/" \
            "$OPENCCA_RPI_HOST:$OPENCCA_RPI_FLASH_ROOT/opencca-scripts/"
    fi
fi

if [[ "$PATCH_ROOTFS_ON_PI" == "1" ]]; then
    [[ -n "$OPENCCA_RPI_SUDO_PASSWORD" ]] || opencca_die "set OPENCCA_RPI_SUDO_PASSWORD or OPENCCA_RPI_PASSWORD for sudo on the Pi"
    image_name="$(basename "$ROOTFS_ARG")"
    remote_root_q="$(printf '%q' "$OPENCCA_RPI_FLASH_ROOT")"
    sudo_pass_q="$(printf '%q' "$OPENCCA_RPI_SUDO_PASSWORD")"
    rk_root_password_q="$(printf '%q' "$OPENCCA_RK_ROOT_PASSWORD")"
    rk_iface_q="$(printf '%q' "$OPENCCA_RK_ETH_IFACE")"
    rk_ip_q="$(printf '%q' "$OPENCCA_RK_STATIC_IP")"
    rk_gateway_q="$(printf '%q' "$OPENCCA_RK_GATEWAY")"
    rk_dns_q="$(printf '%q' "$OPENCCA_RK_DNS")"
    remote_cmd="set -euo pipefail; cd $remote_root_q; printf '%s\n' $sudo_pass_q | sudo -S env OPENCCA_WORK_DIR=$remote_root_q OPENCCA_SNAPSHOT_DIR=$remote_root_q/snapshot OPENCCA_ROOTFS_IMAGE=$remote_root_q/snapshot/$image_name OPENCCA_RK_ROOT_PASSWORD=$rk_root_password_q OPENCCA_RK_ETH_IFACE=$rk_iface_q OPENCCA_RK_STATIC_IP=$rk_ip_q OPENCCA_RK_GATEWAY=$rk_gateway_q OPENCCA_RK_DNS=$rk_dns_q $remote_root_q/opencca-scripts/image/patch-opencca-rootfs-image.sh"
    run_cmd "${pi_ssh_cmd[@]}" "$OPENCCA_RPI_HOST" "$remote_cmd"
fi

if [[ -n "$FLASH_COMMAND" ]]; then
    [[ -n "$OPENCCA_RPI_SUDO_PASSWORD" ]] || opencca_die "set OPENCCA_RPI_SUDO_PASSWORD or OPENCCA_RPI_PASSWORD for sudo on the Pi"
    remote_root_q="$(printf '%q' "$OPENCCA_RPI_FLASH_ROOT")"
    sudo_pass_q="$(printf '%q' "$OPENCCA_RPI_SUDO_PASSWORD")"
    case "$FLASH_COMMAND" in
        mmc|firmware)
            require_sd_storage "$OPENCCA_FIRMWARE_STORAGE_ID" "firmware flash"
            firmware_storage_env="$(quote_env_assignment OPENCCA_FIRMWARE_STORAGE_ID "$OPENCCA_FIRMWARE_STORAGE_ID")"
            remote_cmd="set -euo pipefail; cd $remote_root_q; printf '%s\n' $sudo_pass_q | sudo -S env $firmware_storage_env ./flash.sh mmc"
            ;;
        rootfs)
            require_sd_storage "$OPENCCA_ROOTFS_STORAGE_ID" "rootfs flash"
            image_name="$(basename "$ROOTFS_ARG")"
            rootfs_storage_env="$(quote_env_assignment OPENCCA_ROOTFS_STORAGE_ID "$OPENCCA_ROOTFS_STORAGE_ID")"
            remote_cmd="set -euo pipefail; cd $remote_root_q; printf '%s\n' $sudo_pass_q | sudo -S env $rootfs_storage_env ./flash.sh rootfs snapshot/$image_name --yes"
            ;;
        kernel)
            image_name="$(basename "$KERNEL_ARG")"
            kernel_image_env="$(quote_env_assignment OPENCCA_KERNEL_IMAGE "$OPENCCA_RPI_FLASH_ROOT/snapshot/$image_name")"
            kernel_storage_env="$(quote_env_assignment OPENCCA_KERNEL_STORAGE_ID "$OPENCCA_KERNEL_STORAGE_ID")"
            sd_storage_env="$(quote_env_assignment OPENCCA_SD_STORAGE_ID "$OPENCCA_SD_STORAGE_ID")"
            slot_start_env="$(quote_env_assignment OPENCCA_KERNEL_SLOT_START "$OPENCCA_KERNEL_SLOT_START")"
            slot_sectors_env="$(quote_env_assignment OPENCCA_KERNEL_SLOT_SECTORS "$OPENCCA_KERNEL_SLOT_SECTORS")"
            remote_cmd="set -euo pipefail; cd $remote_root_q; printf '%s\n' $sudo_pass_q | sudo -S env OPENCCA_RPI_FLASH_ROOT=$remote_root_q $kernel_image_env $kernel_storage_env $sd_storage_env $slot_start_env $slot_sectors_env $remote_root_q/opencca-scripts/firmware/flash-raw-kernel-on-pi.sh"
            ;;
        *)
            flash_cmd_q="$(printf '%q' "$FLASH_COMMAND")"
            remote_cmd="set -euo pipefail; cd $remote_root_q; printf '%s\n' $sudo_pass_q | sudo -S ./flash.sh $flash_cmd_q"
            ;;
    esac
    run_cmd "${pi_ssh_cmd[@]}" "$OPENCCA_RPI_HOST" "$remote_cmd"
fi

if [[ "$WAIT_RK" == "1" ]]; then
    rk_ssh_cmd=(
        ssh
        -p "$OPENCCA_RK_SSH_PORT"
        -oBatchMode=no
        -oStrictHostKeyChecking=accept-new
        -oUserKnownHostsFile=/tmp/opencca_known_hosts
        -oConnectTimeout=8
    )
    if [[ -n "$OPENCCA_RK_PASSWORD" ]]; then
        rk_ssh_cmd=(sshpass -p "$OPENCCA_RK_PASSWORD" "${rk_ssh_cmd[@]}")
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        run_cmd "${rk_ssh_cmd[@]}" "$OPENCCA_RK_HOST" "hostname; uname -a"
    else
        opencca_log "waiting for RK3588 SSH: $OPENCCA_RK_HOST"
        for _ in $(seq 1 80); do
            if "${rk_ssh_cmd[@]}" "$OPENCCA_RK_HOST" "hostname; uname -a" >/tmp/opencca-rk-ssh.out 2>/dev/null; then
                cat /tmp/opencca-rk-ssh.out
                exit 0
            fi
            sleep 3
        done
        opencca_die "RK3588 did not come back over SSH"
    fi
fi

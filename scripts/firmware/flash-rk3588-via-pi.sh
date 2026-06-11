#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/opencca_paths.sh"

DO_SYNC=1
FLASH_COMMAND=""
SYNC_ROOTFS=0
ROOTFS_ARG="$OPENCCA_ROOTFS_IMAGE"
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
  --patch-rootfs-on-pi Patch rootfs image on the Pi before flashing.
  --flash-mmc          Flash SD boot firmware: idbloader.img and u-boot.itb.
  --flash-sd-firmware  Alias for --flash-mmc.
  --flash-spi          Run: sudo ./flash.sh spi
  --flash-rootfs       Flash full rootfs image to SD.
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
  OPENCCA_FIRMWARE_STORAGE_ID Default: $OPENCCA_FIRMWARE_STORAGE_ID (rkdeveloptool: 2=SD, 1=EMMC)
  OPENCCA_ROOTFS_STORAGE_ID   Default: $OPENCCA_ROOTFS_STORAGE_ID (rkdeveloptool: 2=SD, 1=EMMC)
  OPENCCA_RK_HOST           Default: $OPENCCA_RK_HOST
  OPENCCA_RK_PASSWORD       Optional; use SSH keys/agent when unset.
  OPENCCA_RK_ROOT_PASSWORD  Required with --patch-rootfs-on-pi.
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
        --patch-rootfs-on-pi)
            PATCH_ROOTFS_ON_PI=1
            ROOTFS_ARG="$OPENCCA_ROOTFS_IMAGE"
            ;;
        --flash-mmc|--flash-sd-firmware)
            FLASH_COMMAND="mmc"
            ;;
        --flash-spi)
            FLASH_COMMAND="spi"
            ;;
        --flash-rootfs)
            FLASH_COMMAND="rootfs"
            ROOTFS_ARG="$OPENCCA_ROOTFS_IMAGE"
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

if [[ "$DO_SYNC" == "1" ]]; then
    require_firmware_artifacts
    run_cmd rsync -av --checksum -e "$rsync_ssh" \
        "$OPENCCA_SNAPSHOT_DIR/idbloader.img" \
        "$OPENCCA_SNAPSHOT_DIR/u-boot.itb" \
        "$OPENCCA_SNAPSHOT_DIR/u-boot-rockchip-spi.bin" \
        "$OPENCCA_SNAPSHOT_DIR/tf-rmm.elf" \
        "$OPENCCA_RPI_HOST:$OPENCCA_RPI_FLASH_ROOT/snapshot/"

    if [[ "$SYNC_ROOTFS" == "1" ]]; then
        opencca_require_file "$ROOTFS_ARG"
        run_cmd rsync -av --checksum --progress -e "$rsync_ssh" \
            "$ROOTFS_ARG" \
            "$OPENCCA_RPI_HOST:$OPENCCA_RPI_FLASH_ROOT/snapshot/"
    fi

    if [[ "$PATCH_ROOTFS_ON_PI" == "1" ]]; then
        run_cmd rsync -av --delete -e "$rsync_ssh" \
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

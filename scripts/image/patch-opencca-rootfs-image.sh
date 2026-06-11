#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/opencca_paths.sh"

PATCH_DTB=1
PATCH_LOGIN=1
PATCH_NETWORK=1
WRITE_LOADER=1
DRY_RUN=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] [image]

Patch a ROCK5B/RK3588 OpenCCA rootfs image with locally built bootloader
artifacts and board bring-up settings.

Options:
  --no-loader        Do not write idbloader.img/u-boot.itb into the image.
  --no-dtb           Do not patch rk3588-rock-5b.dtb.
  --no-login         Do not configure root password/SSH login.
  --no-network       Do not configure static systemd-networkd settings.
  --dry-run          Print what would be done.
  -h, --help         Show this help.

Environment:
  OPENCCA_SNAPSHOT_DIR       Default: $OPENCCA_SNAPSHOT_DIR
  OPENCCA_ROOTFS_IMAGE       Default: $OPENCCA_ROOTFS_IMAGE
  OPENCCA_RK_ROOT_PASSWORD   Required unless --no-login is used.
  OPENCCA_RK_ETH_IFACE       Default: $OPENCCA_RK_ETH_IFACE
  OPENCCA_RK_STATIC_IP       Default: $OPENCCA_RK_STATIC_IP
  OPENCCA_RK_GATEWAY         Default: $OPENCCA_RK_GATEWAY
  OPENCCA_RK_DNS             Default: $OPENCCA_RK_DNS
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-loader)
            WRITE_LOADER=0
            ;;
        --no-dtb)
            PATCH_DTB=0
            ;;
        --no-login)
            PATCH_LOGIN=0
            ;;
        --no-network)
            PATCH_NETWORK=0
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            usage >&2
            opencca_die "unknown option: $1"
            ;;
        *)
            OPENCCA_ROOTFS_IMAGE="$1"
            ;;
    esac
    shift
done

run_cmd() {
    printf '[opencca-image]'
    printf ' %q' "$@"
    printf '\n'
    if [[ "$DRY_RUN" == "0" ]]; then
        "$@"
    fi
}

write_loader_into_image() {
    local image="$1"

    opencca_require_file "$OPENCCA_SNAPSHOT_DIR/idbloader.img"
    opencca_require_file "$OPENCCA_SNAPSHOT_DIR/u-boot.itb"
    run_cmd dd if="$OPENCCA_SNAPSHOT_DIR/idbloader.img" of="$image" bs=512 seek=64 conv=notrunc status=none
    run_cmd dd if="$OPENCCA_SNAPSHOT_DIR/u-boot.itb" of="$image" bs=512 seek=16384 conv=notrunc status=none
    opencca_log "wrote idbloader.img at LBA 0x40 and u-boot.itb at LBA 0x4000"
}

patch_dts_file() {
    local dts="$1"

    python3 - "$dts" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()

node = re.search(r'(?ms)(^\s*mmc@fe2c0000\s*\{.*?^\s*\};)', text)
if not node:
    raise SystemExit("mmc@fe2c0000 node not found")

body = node.group(1)
indent_match = re.search(r'(?m)^(\s*)compatible\s*=', body)
indent = indent_match.group(1) if indent_match else "\t\t"

body = re.sub(r'(?m)^\s*sd-uhs-sdr104;\n', '', body)
body = re.sub(r'(?m)^\s*gpio-cd\s*=.*?;\n', '', body)

if re.search(r'(?m)^\s*max-frequency\s*=', body):
    body = re.sub(r'(?m)^\s*max-frequency\s*=.*?;\n', f'{indent}max-frequency = <0x17d7840>;\n', body)
else:
    body = body.replace('\n' + indent + 'pinctrl-names', f'\n{indent}max-frequency = <0x17d7840>;\n{indent}pinctrl-names', 1)

insert_at = re.search(r'(?m)^\s*vmmc-supply\s*=', body)
props = []
if not re.search(r'(?m)^\s*broken-cd;', body):
    props.append(f'{indent}broken-cd;\n')
if not re.search(r'(?m)^\s*no-1-8-v;', body):
    props.append(f'{indent}no-1-8-v;\n')

if props and insert_at:
    body = body[:insert_at.start()] + ''.join(props) + body[insert_at.start():]
elif props:
    body = body.replace('\n\t};', '\n' + ''.join(props) + '\t};', 1)

text = text[:node.start(1)] + body + text[node.end(1):]

rfkill = re.search(r'(?ms)^\s*rfkill\s*\{.*?^\s*\};\n?', text)
if rfkill:
    text = text[:rfkill.start()] + text[rfkill.end():]

path.write_text(text)
PY
}

patch_dtb_in_mount() {
    local mnt="$1"
    local dtb dts patched

    opencca_require_cmd dtc python3
    dtb=$(sudo find "$mnt/usr/lib" "$mnt/boot" -path '*/rockchip/rk3588-rock-5b.dtb' -type f 2>/dev/null | head -n 1 || true)
    [[ -n "$dtb" ]] || opencca_die "missing rk3588-rock-5b.dtb under mounted image"

    dts=$(mktemp /tmp/rk3588-rock-5b.XXXXXX.dts)
    patched=$(mktemp /tmp/rk3588-rock-5b.XXXXXX.dtb)
    run_cmd sudo dtc -I dtb -O dts -o "$dts" "$dtb"
    printf '[opencca-image] patch_dts_file %q\n' "$dts"
    if [[ "$DRY_RUN" == "0" ]]; then
        patch_dts_file "$dts"
    fi
    run_cmd dtc -I dts -O dtb -o "$patched" "$dts"
    run_cmd sudo install -m0644 "$patched" "$dtb"
    rm -f "$dts" "$patched"
    opencca_log "patched $(realpath --relative-to="$mnt" "$dtb") for SD 3.6V/basic-speed mode and removed wlan rfkill"
}

patch_login_in_mount() {
    local mnt="$1"
    local hash

    [[ -n "$OPENCCA_RK_ROOT_PASSWORD" ]] || opencca_die "set OPENCCA_RK_ROOT_PASSWORD or use --no-login"
    opencca_require_cmd openssl
    hash=$(openssl passwd -6 "$OPENCCA_RK_ROOT_PASSWORD")
    run_cmd sudo sed -i -E "s#^root:[^:]*:#root:${hash}:#" "$mnt/etc/shadow"
    run_cmd sudo install -d -m0755 "$mnt/etc/ssh/sshd_config.d"
    if [[ "$DRY_RUN" == "0" ]]; then
        printf '%s\n' \
            'PasswordAuthentication yes' \
            'PermitRootLogin yes' \
            'PubkeyAuthentication yes' \
            'PermitEmptyPasswords no' |
            sudo tee "$mnt/etc/ssh/sshd_config.d/99-opencca-root-login.conf" >/dev/null
    else
        opencca_log "would write $mnt/etc/ssh/sshd_config.d/99-opencca-root-login.conf"
    fi
    opencca_log "configured root SSH login"
}

patch_network_in_mount() {
    local mnt="$1"

    run_cmd sudo install -d -m0755 "$mnt/etc/systemd/network"
    if [[ "$DRY_RUN" == "0" ]]; then
        cat <<EOF | sudo tee "$mnt/etc/systemd/network/10-opencca-lan.network" >/dev/null
[Match]
Name=$OPENCCA_RK_ETH_IFACE

[Network]
DHCP=no
Address=$OPENCCA_RK_STATIC_IP
Gateway=$OPENCCA_RK_GATEWAY
DNS=$OPENCCA_RK_DNS

[Link]
        RequiredForOnline=yes
EOF
        sudo rm -f "$mnt/etc/resolv.conf"
        printf 'nameserver %s\n' "$OPENCCA_RK_DNS" | sudo tee "$mnt/etc/resolv.conf" >/dev/null
    else
        opencca_log "would write static network config for $OPENCCA_RK_ETH_IFACE"
    fi
    opencca_log "configured static network: $OPENCCA_RK_ETH_IFACE $OPENCCA_RK_STATIC_IP via $OPENCCA_RK_GATEWAY"
}

patch_rootfs_partition() {
    local image="$1"
    local loop="" mnt

    opencca_require_cmd sudo losetup mount umount findmnt
    mnt=$(mktemp -d /tmp/opencca-rootfs.XXXXXX)

    cleanup() {
        set +e
        if [[ -n "${mnt:-}" ]]; then
            sudo umount "$mnt" >/dev/null 2>&1
            rmdir "$mnt" >/dev/null 2>&1
        fi
        if [[ -n "${loop:-}" ]]; then
            sudo losetup -d "$loop" >/dev/null 2>&1
        fi
    }
    trap cleanup RETURN

    loop=$(sudo losetup --find --show -P "$image")
    run_cmd sudo mount "${loop}p3" "$mnt"

    if [[ "$PATCH_DTB" == "1" ]]; then
        patch_dtb_in_mount "$mnt"
    fi
    if [[ "$PATCH_LOGIN" == "1" ]]; then
        patch_login_in_mount "$mnt"
    fi
    if [[ "$PATCH_NETWORK" == "1" ]]; then
        patch_network_in_mount "$mnt"
    fi

    run_cmd sync
}

opencca_require_file "$OPENCCA_ROOTFS_IMAGE"

if [[ "$WRITE_LOADER" == "1" ]]; then
    write_loader_into_image "$OPENCCA_ROOTFS_IMAGE"
fi

if [[ "$PATCH_DTB" == "1" || "$PATCH_LOGIN" == "1" || "$PATCH_NETWORK" == "1" ]]; then
    patch_rootfs_partition "$OPENCCA_ROOTFS_IMAGE"
fi

sha256sum "$OPENCCA_ROOTFS_IMAGE"

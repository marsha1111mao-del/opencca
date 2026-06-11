#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/opencca_paths.sh"

OPENCCA_UBOOT_DIR="${OPENCCA_UBOOT_DIR:-$OPENCCA_WORK_DIR/u-boot}"
OPENCCA_DEBIAN_IMAGE_RECIPES_DIR="${OPENCCA_DEBIAN_IMAGE_RECIPES_DIR:-$OPENCCA_WORK_DIR/debian-image-recipes}"
DRY_RUN=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Patch local OpenCCA source checkouts for the SD raw-kernel-slot layout.
This edits nested source trees; commit those repositories separately if needed.

Options:
  --dry-run     Print target files and exit.
  -h, --help    Show this help.

Environment:
  OPENCCA_UBOOT_DIR                 Default: $OPENCCA_UBOOT_DIR
  OPENCCA_DEBIAN_IMAGE_RECIPES_DIR  Default: $OPENCCA_DEBIAN_IMAGE_RECIPES_DIR
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
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

uboot_config="$OPENCCA_UBOOT_DIR/rk3588_fragment.config"
recipe="$OPENCCA_DEBIAN_IMAGE_RECIPES_DIR/opencca-image-rockchip-rk3588.yaml"
bootcommand='CONFIG_BOOTCOMMAND="mmc dev 0; if mmc read 0x50000000 0x8000 0x40000; then setenv bootargs root=PARTLABEL=root rootwait isolcpus=1,2,3 maxcpus=2 nohlt cpuidle.off=1 rcupdate.rcu_cpu_st; bootm 0x50000000; fi; bootflow scan"'

opencca_require_file "$uboot_config"
opencca_require_file "$recipe"

if [[ "$DRY_RUN" == "1" ]]; then
    opencca_log "would update $uboot_config"
    opencca_log "would update $recipe"
    exit 0
fi

if grep -q '^CONFIG_BOOTCOMMAND=' "$uboot_config"; then
    sed -i "s#^CONFIG_BOOTCOMMAND=.*#$bootcommand#" "$uboot_config"
else
    printf '%s\n' "$bootcommand" >>"$uboot_config"
fi

python3 - "$recipe" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

old_root = """      - name: root
        fs: ext4
        start: 32768s  # 16M
        end: 100%
        flags: [ boot ]
"""
new_root = """      - name: kernel
        fs: none
        start: 32768s  # 16M
        end: 294911s
      - name: root
        fs: ext4
        start: 294912s  # 144M
        end: 100%
        flags: [ boot ]
"""

if "name: kernel" not in text:
    if old_root not in text:
        raise SystemExit("could not find old root partition block")
    text = text.replace(old_root, new_root, 1)

text = text.replace("ROOT_START_SECTOR=32768", "ROOT_START_SECTOR=294912")
path.write_text(text)
PY

opencca_log "configured U-Boot raw-kernel boot command"
opencca_log "configured debian-image-recipes root start at 0x48000"

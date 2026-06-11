#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/opencca_paths.sh"

OPENCCA_UBOOT_DIR="${OPENCCA_UBOOT_DIR:-$OPENCCA_WORK_DIR/u-boot}"
OPENCCA_DEBIAN_IMAGE_RECIPES_DIR="${OPENCCA_DEBIAN_IMAGE_RECIPES_DIR:-$OPENCCA_WORK_DIR/debian-image-recipes}"
DRY_RUN=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Patch local OpenCCA source checkouts for the SD kernel-boot-slot layout.
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
bootcommand="CONFIG_BOOTCOMMAND=\"bootflow scan\""

opencca_require_file "$uboot_config"
opencca_require_file "$recipe"

if [[ "$DRY_RUN" == "1" ]]; then
    opencca_log "would update $uboot_config"
    opencca_log "would update $recipe"
    exit 0
fi

python3 - "$uboot_config" "$bootcommand" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
bootcommand = sys.argv[2]
lines = path.read_text().splitlines()
lines = [line for line in lines if not line.startswith("CONFIG_BOOTCOMMAND=")]
lines.append(bootcommand)
path.write_text("\n".join(lines) + "\n")
PY

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
        fs: ext4
        start: 32768s  # 16M
        end: 294911s
        flags: [ boot ]
      - name: root
        fs: ext4
        start: 294912s  # 144M
        end: 100%
"""

if "name: kernel" not in text:
    if old_root not in text:
        raise SystemExit("could not find old root partition block")
    text = text.replace(old_root, new_root, 1)

old_existing = """      - name: kernel
        fs: none
        start: 32768s  # 16M
        end: 294911s
      - name: root
        fs: ext4
        start: 294912s  # 144M
        end: 100%
        flags: [ boot ]
"""
if old_existing in text:
    text = text.replace(old_existing, new_root, 1)

text = text.replace("ROOT_START_SECTOR=32768", "ROOT_START_SECTOR=294912")
path.write_text(text)
PY

opencca_log "configured U-Boot bootflow command"
opencca_log "configured debian-image-recipes root start at 0x48000"

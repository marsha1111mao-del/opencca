# OpenCCA RK3588 Workspace

This repository records the local RK3588/OpenCCA workspace used for rebuilding
firmware, patching the ROCK 5B rootfs image, and flashing the target board from
the Raspberry Pi flash host.

Large generated artifacts are intentionally not tracked. Rebuild firmware
locally, and fetch full rootfs images from release artifacts or the Raspberry Pi
flash host when needed.

## Layout

- `scripts/`: reusable local helpers for rootfs image patching and Raspberry Pi
  flashing.
- `patches/`: local changes that were applied on top of upstream OpenCCA
  components.
- `manifests/component-revisions.md`: upstream component URLs and revisions
  captured from this workspace.
- component directories such as `linux/`, `u-boot/`, and `opencca-build/`:
  upstream source checkouts tracked as submodules.
- `tf-rmm/`: independent submodule hosted at
  `git@github.com:marsha1111mao-del/tf-rmm.git`.

The source trees are not vendored into this superproject as ordinary files.
They are tracked as submodule gitlinks, while local changes on top of upstream
components are recorded under `patches/`.

## RK3588 Flash Target

This workflow flashes SD-card boot storage, not eMMC. `rkdeveloptool --help`
documents the Rockchip storage IDs as:

```text
1=EMMC, 2=SD, 9=SPINOR
```

The wrapper script therefore defaults `OPENCCA_FIRMWARE_STORAGE_ID=2` and
`OPENCCA_ROOTFS_STORAGE_ID=2`, and refuses rootfs/firmware writes to any other
storage ID.

## Rebuild And Flash

Build firmware from the local OpenCCA sources:

```bash
make -C opencca-build/buildconf -f firmware_opencca.mk build
make -C opencca-build/buildconf -f linux.mk kernel
```

Patch a rootfs image with local boot firmware, DTB fixes, root SSH, and static
network configuration:

```bash
./scripts/image/patch-opencca-rootfs-image.sh
```

Patch the image on the Raspberry Pi flash host and flash the SD card:

```bash
OPENCCA_RPI_PASSWORD="$PI_PASSWORD" \
OPENCCA_RPI_SUDO_PASSWORD="$PI_SUDO_PASSWORD" \
OPENCCA_RK_PASSWORD="$RK_PASSWORD" \
OPENCCA_RK_ROOT_PASSWORD="$RK_ROOT_PASSWORD" \
  ./scripts/firmware/flash-rk3588-via-pi.sh \
  --patch-rootfs-on-pi --flash-rootfs --wait-rk
```

See `docs/SD_CARD_FLASH_RUNBOOK.md` for the standalone SD-card flash notes.

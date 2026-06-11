# RK3588 SD Card Flash Notes

This OpenCCA workspace targets SD-card boot, not eMMC.

`rkdeveloptool --help` reports the Rockchip storage IDs as:

```text
ChangeStorage: cs [storage: 1=EMMC, 2=SD, 9=SPINOR]
```

Use storage ID `2` for SD-card firmware/rootfs writes:

```bash
OPENCCA_RPI_PASSWORD="$PI_PASSWORD" \
OPENCCA_RPI_SUDO_PASSWORD="$PI_SUDO_PASSWORD" \
OPENCCA_RK_PASSWORD="$RK_PASSWORD" \
  ./scripts/firmware/flash-rk3588-via-pi.sh \
  --flash-rootfs --no-sync --wait-rk
```

The wrapper defaults are:

```text
OPENCCA_FIRMWARE_STORAGE_ID=2
OPENCCA_ROOTFS_STORAGE_ID=2
OPENCCA_KERNEL_STORAGE_ID=2
```

The wrapper refuses rootfs, SD firmware, and raw-kernel writes when the selected
storage ID does not match `OPENCCA_SD_STORAGE_ID`.

Direct Raspberry Pi command equivalent:

```bash
cd /home/mzh/opencca-flash
printf "%s\n" "$PI_SUDO_PASSWORD" | sudo -S env OPENCCA_ROOTFS_STORAGE_ID=2 \
  ./flash.sh rootfs snapshot/opencca-image-rockchip-rock5b-rk3588.img --yes
```

After flashing, verify the board boots from SD:

```bash
ssh root@192.168.31.18 'hostname; uname -a; findmnt -no SOURCE,TARGET,FSTYPE /'
```

Expected root source for the current ROCK 5B setup:

```text
/dev/mmcblk1p3 / ext4
```

## Raw Kernel Slot

The single-kernel flash path is also SD-only. It expects an OpenCCA-compatible
GPT layout with a dedicated raw kernel partition:

```text
loader1 start=0x40
loader2 start=0x4000
kernel start=0x8000 size>=0x40000 sectors
root   start>=0x48000
```

Build the raw kernel artifact locally from the current Linux `Image` and
`rk3588-rock-5b.dtb`:

```bash
./scripts/image/build-raw-kernel-image.sh
```

This writes `snapshot/kernel.img` as a fixed 128 MiB FIT image. The file is a
build product and is intentionally ignored by Git.

Flash only the SD raw kernel slot:

```bash
OPENCCA_RPI_PASSWORD="$PI_PASSWORD" \
OPENCCA_RPI_SUDO_PASSWORD="$PI_SUDO_PASSWORD" \
OPENCCA_RK_PASSWORD="$RK_PASSWORD" \
  ./scripts/firmware/flash-rk3588-via-pi.sh \
  --flash-kernel --wait-rk
```

The wrapper performs a live RK partition preflight before entering Maskrom, and
the Pi-side helper reads GPT through `rkdeveloptool rl` before issuing
`rkdeveloptool wl 0x8000 snapshot/kernel.img`. If the SD card still uses the
older layout where `root` starts at `0x8000`, the command is refused because
writing a raw kernel there would overwrite rootfs.

Current board note, recorded on 2026-06-11: `/dev/mmcblk1p3` starts at sector
`32768` (`0x8000`) and there is no `PARTLABEL=kernel`, so this board must first
be initialized with a compatible SD image before `--flash-kernel` can be used.

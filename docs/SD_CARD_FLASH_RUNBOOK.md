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
```

The wrapper refuses rootfs and SD firmware writes when the selected storage ID
does not match `OPENCCA_SD_STORAGE_ID`.

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

# Captured Component Revisions

Captured from `/home/mzh/RK3588/gpu/opencca` on 2026-06-11.

| Component | Remote | Revision |
| --- | --- | --- |
| buildroot | `https://github.com/buildroot/buildroot.git` | `d8ce1def` |
| debian-image-recipes | `https://github.com/opencca/debian-image-recipes` | `9262b4d` |
| kvmtool | `https://github.com/opencca/kvmtool` | `54241e3` |
| linux | `https://github.com/opencca/linux` | `6d37f0d15` |
| opencca-assets | `https://github.com/opencca/opencca-assets` | `f75c95d` |
| opencca-build | `https://github.com/opencca/opencca-build` | `d691ada` |
| opencca-flash | `https://github.com/opencca/opencca-flash` | `5014217` |
| opencca-manifest | `https://github.com/opencca/opencca-manifest` | `043a44a` |
| rkbin | `https://github.com/opencca/rkbin` | `b0c100f` |
| trusted-firmware-a | `https://github.com/opencca/arm-trusted-firmware` | `fb03b9e` |
| u-boot | `https://github.com/opencca/u-boot` | `a515a10c` |
| armbian-rkbin | `https://github.com/armbian/rkbin.git` | `6ead9fd` |
| tf-rmm | `git@github.com:marsha1111mao-del/tf-rmm.git` | `72c3c99` |

## Local Patch Notes

- `patches/opencca-build/rk3588-local-build.patch`: switches the U-Boot TPL to
  the RK3588 SPL/DDR v1.16 asset and makes duplicate Debian package copies
  non-fatal.
- `patches/opencca-assets/rk3588-v1.16-assets.md`: records the v1.16 loader
  assets and SHA-256 values used in the local build.
- `tf-rmm/patches/submodules/*.patch`: records local patches applied inside
  dirty third-party `tf-rmm` submodules.

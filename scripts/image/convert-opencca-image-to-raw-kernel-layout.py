#!/usr/bin/env python3
import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


SECTOR_SIZE = 512
LOADER1_START = 0x40
LOADER1_SIZE = 7105
LOADER2_START = 0x4000
LOADER2_SIZE = 0x2000
KERNEL_START = 0x8000
KERNEL_SIZE = 0x40000
ROOT_START = 0x48000


def run(args, **kwargs):
    print("+", " ".join(str(a) for a in args), file=sys.stderr)
    return subprocess.run(args, check=True, text=True, **kwargs)


def require_tool(name):
    if shutil.which(name) is None:
        raise SystemExit("missing required tool: {}".format(name))


def sectors_for_bytes(size):
    return (size + SECTOR_SIZE - 1) // SECTOR_SIZE


def image_sectors(path):
    size = path.stat().st_size
    if size % SECTOR_SIZE:
        raise SystemExit("{} size is not sector aligned".format(path))
    return size // SECTOR_SIZE


def partition_table(path):
    result = run(["sfdisk", "--json", str(path)], stdout=subprocess.PIPE)
    return json.loads(result.stdout)["partitiontable"]["partitions"]


def find_partition(parts, name):
    matches = [part for part in parts if part.get("name") == name]
    if len(matches) != 1:
        raise SystemExit("expected one {!r} partition, found {}".format(name, len(matches)))
    return matches[0]


def copy_range(src, dst, src_sector, dst_sector, sectors):
    run(
        [
            "dd",
            "if={}".format(src),
            "of={}".format(dst),
            "bs={}".format(SECTOR_SIZE),
            "skip={}".format(src_sector),
            "seek={}".format(dst_sector),
            "count={}".format(sectors),
            "conv=notrunc",
            "status=none",
        ]
    )


def extract_range(src, dst, start, sectors):
    run(
        [
            "dd",
            "if={}".format(src),
            "of={}".format(dst),
            "bs={}".format(SECTOR_SIZE),
            "skip={}".format(start),
            "count={}".format(sectors),
            "status=none",
        ]
    )


def write_file_to_sector(src, dst, dst_sector):
    run(
        [
            "dd",
            "if={}".format(src),
            "of={}".format(dst),
            "bs={}".format(SECTOR_SIZE),
            "seek={}".format(dst_sector),
            "conv=notrunc",
            "status=none",
        ]
    )


def run_e2fsck_repair(rootfs):
    print("+ e2fsck -fy {}".format(rootfs), file=sys.stderr)
    result = subprocess.run(["e2fsck", "-fy", str(rootfs)], text=True)
    if result.returncode not in (0, 1):
        raise subprocess.CalledProcessError(result.returncode, result.args)


def shrink_ext4(rootfs):
    run_e2fsck_repair(rootfs)
    run(["resize2fs", "-M", str(rootfs)])
    run_e2fsck_repair(rootfs)


def make_partition_table(out, total_sectors, kernel_type):
    root_size = total_sectors - ROOT_START - 34
    if root_size <= 0:
        raise SystemExit("output image is too small for root start sector {:#x}".format(ROOT_START))

    table = (
        "label: gpt\n"
        "unit: sectors\n"
        "first-lba: 34\n"
        "sector-size: 512\n"
        "start={}, size={}, type=linux, name=loader1\n"
        "start={}, size={}, type=linux, name=loader2\n"
        "start={}, size={}, type={}, name=kernel\n"
        "start={}, size={}, type=linux, name=root\n"
    ).format(
        LOADER1_START,
        LOADER1_SIZE,
        LOADER2_START,
        LOADER2_SIZE,
        KERNEL_START,
        KERNEL_SIZE,
        kernel_type or "linux",
        ROOT_START,
        root_size,
    )
    run(["sfdisk", "--quiet", str(out)], input=table)
    return root_size


def convert_image(source, output, kernel, idbloader, uboot):
    source = source.resolve()
    output = output.resolve()
    kernel = kernel.resolve()

    if source == output:
        raise SystemExit("source and output image paths must differ")
    if not source.is_file():
        raise SystemExit("missing source image: {}".format(source))
    if not kernel.is_file():
        raise SystemExit("missing kernel image: {}".format(kernel))

    source_sectors = image_sectors(source)
    kernel_sectors = sectors_for_bytes(kernel.stat().st_size)
    if kernel_sectors > KERNEL_SIZE:
        raise SystemExit(
            "kernel image too large: {} bytes > {} bytes".format(
                kernel.stat().st_size, KERNEL_SIZE * SECTOR_SIZE
            )
        )

    parts = partition_table(source)
    loader1 = find_partition(parts, "loader1")
    loader2 = find_partition(parts, "loader2")
    root = find_partition(parts, "root")

    if int(root["start"]) >= ROOT_START:
        raise SystemExit("{} already appears to use the raw-kernel layout".format(source))

    with tempfile.TemporaryDirectory(prefix="opencca-raw-kernel-layout.") as tmp:
        tmpdir = Path(tmp)
        rootfs = tmpdir / "rootfs.ext4"
        extract_range(source, rootfs, int(root["start"]), int(root["size"]))
        shrink_ext4(rootfs)

        rootfs_sectors = sectors_for_bytes(rootfs.stat().st_size)
        output_sectors = max(source_sectors, ROOT_START + rootfs_sectors + 34)
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, output)
        run(["truncate", "-s", str(output_sectors * SECTOR_SIZE), str(output)])

        root_capacity = make_partition_table(output, output_sectors, root.get("type") or "linux")
        if idbloader:
            write_file_to_sector(idbloader.resolve(), output, LOADER1_START)
        else:
            copy_range(source, output, int(loader1["start"]), LOADER1_START, int(loader1["size"]))
        if uboot:
            write_file_to_sector(uboot.resolve(), output, LOADER2_START)
        else:
            copy_range(source, output, int(loader2["start"]), LOADER2_START, int(loader2["size"]))
        write_file_to_sector(kernel, output, KERNEL_START)
        write_file_to_sector(rootfs, output, ROOT_START)

    print("wrote compatible image: {}".format(output))
    print("kernel boot slot: start={:#x}, sectors={:#x}".format(KERNEL_START, KERNEL_SIZE))
    print("rootfs: start={:#x}, capacity_sectors={:#x}".format(ROOT_START, root_capacity))


def main():
    for tool in ("sfdisk", "dd", "truncate", "e2fsck", "resize2fs"):
        require_tool(tool)

    parser = argparse.ArgumentParser(
        description="Convert an old OpenCCA RK3588 image to the SD kernel-boot-slot layout"
    )
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--kernel", type=Path, default=Path("snapshot/kernel-extlinux.img"))
    parser.add_argument("--idbloader", type=Path, help="Optional idbloader.img to write at LBA 0x40")
    parser.add_argument("--u-boot", type=Path, help="Optional u-boot.itb to write at LBA 0x4000")
    args = parser.parse_args()

    try:
        convert_image(args.source, args.output, args.kernel, args.idbloader, args.u_boot)
    except subprocess.CalledProcessError as exc:
        print("command failed: {}".format(" ".join(str(a) for a in exc.cmd)), file=sys.stderr)
        raise SystemExit(exc.returncode)


if __name__ == "__main__":
    main()

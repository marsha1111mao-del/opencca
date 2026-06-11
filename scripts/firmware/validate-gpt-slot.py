#!/usr/bin/env python3
import argparse
import struct
import sys
from pathlib import Path


SECTOR_SIZE = 512
GPT_HEADER_LBA = 1
GPT_SIGNATURE = b"EFI PART"
PARTITION_NAME_OFFSET = 56
PARTITION_NAME_SIZE = 72
MIN_GPT_ENTRY_SIZE = 128


def parse_int(value):
    return int(value, 0)


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


def partition_name(entry):
    raw = entry[PARTITION_NAME_OFFSET : PARTITION_NAME_OFFSET + PARTITION_NAME_SIZE]
    return raw.decode("utf-16le", errors="ignore").rstrip("\x00")


def validate_named_slot(gpt_path, expected_name, expected_start, slot_sectors, required_bytes):
    expected_end = expected_start + slot_sectors - 1
    data = Path(gpt_path).read_bytes()

    if len(data) < (GPT_HEADER_LBA + 1) * SECTOR_SIZE:
        fail("GPT read is shorter than the primary header")

    header_offset = GPT_HEADER_LBA * SECTOR_SIZE
    header = data[header_offset : header_offset + SECTOR_SIZE]
    if header[:8] != GPT_SIGNATURE:
        fail("No GPT header found")

    entries_lba = struct.unpack_from("<Q", header, 72)[0]
    entry_count = struct.unpack_from("<I", header, 80)[0]
    entry_size = struct.unpack_from("<I", header, 84)[0]
    if entry_size < MIN_GPT_ENTRY_SIZE:
        fail("Unsupported GPT entry size {}".format(entry_size))

    entries_offset = entries_lba * SECTOR_SIZE
    entries_end = entries_offset + entry_count * entry_size
    if entries_end > len(data):
        fail("GPT partition entries extend beyond the read buffer")

    slot_ok = False
    bad_named_entries = []
    overlaps = []

    for index in range(entry_count):
        offset = entries_offset + index * entry_size
        entry = data[offset : offset + entry_size]
        if len(entry) < MIN_GPT_ENTRY_SIZE or entry[:16] == b"\x00" * 16:
            continue

        first_lba = struct.unpack_from("<Q", entry, 32)[0]
        last_lba = struct.unpack_from("<Q", entry, 40)[0]
        if last_lba < first_lba:
            continue

        name = partition_name(entry)
        overlaps_slot = first_lba <= expected_end and last_lba >= expected_start

        if name == expected_name:
            if first_lba != expected_start:
                bad_named_entries.append("{} [{:#x}-{:#x}]".format(name, first_lba, last_lba))
                continue
            if required_bytes is not None:
                available_bytes = (last_lba - first_lba + 1) * SECTOR_SIZE
                if available_bytes < required_bytes:
                    fail(
                        "{} partition is too small: {} bytes < {} bytes".format(
                            name, available_bytes, required_bytes
                        )
                    )
            if last_lba >= expected_end:
                slot_ok = True
            else:
                bad_named_entries.append("{} [{:#x}-{:#x}]".format(name, first_lba, last_lba))
        elif overlaps_slot:
            overlaps.append("{} [{:#x}-{:#x}]".format(name or "<unnamed>", first_lba, last_lba))

    if not slot_ok:
        detail = " Found: {}.".format(", ".join(bad_named_entries)) if bad_named_entries else ""
        fail(
            "Expected GPT {} partition at {:#x} covering at least {:#x} sectors.{}".format(
                expected_name, expected_start, slot_sectors, detail
            )
        )

    if overlaps:
        fail("{} slot overlaps other partitions: {}".format(expected_name, ", ".join(overlaps)))


def main():
    parser = argparse.ArgumentParser(description="Validate an OpenCCA raw GPT partition slot")
    parser.add_argument("gpt_dump", type=Path)
    parser.add_argument("start", type=parse_int)
    parser.add_argument("sectors", type=parse_int)
    parser.add_argument("--name", default="kernel")
    parser.add_argument("--required-bytes", type=parse_int)
    args = parser.parse_args()

    validate_named_slot(args.gpt_dump, args.name, args.start, args.sectors, args.required_bytes)


if __name__ == "__main__":
    main()

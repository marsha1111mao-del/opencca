#!/usr/bin/env python3
"""Reject overlapping RK3588 RMM/U-Boot runtime memory, including zeroed BSS."""
import argparse
import hashlib
import json
from pathlib import Path
import struct


def memory_ranges(path, base=0):
    data = path.read_bytes()
    if data[:6] != b'\x7fELF\x02\x01' or struct.unpack_from('<H', data, 18)[0] != 183:
        raise ValueError(f'{path}: expected little-endian AArch64 ELF64')
    phoff, shoff = struct.unpack_from('<QQ', data, 32)
    phsize, phnum, shsize, shnum = struct.unpack_from('<HHHH', data, 54)
    ranges = []
    for i in range(phnum):
        kind, flags, offset, va, pa, filesz, memsz, align = struct.unpack_from(
            '<IIQQQQQQ', data, phoff + i * phsize)
        if kind == 1 and memsz:
            if filesz > memsz or offset + filesz > len(data):
                raise ValueError(f'{path}: invalid LOAD segment')
            ranges.append((base + pa, base + pa + memsz))
    # U-Boot's linker script can place BSS outside its LOAD program headers.
    for i in range(shnum):
        name, kind, flags, addr, offset, size, link, info, align, entsize = struct.unpack_from(
            '<IIQQQQIIQQ', data, shoff + i * shsize)
        if kind == 8 and flags & 2 and size:
            ranges.append((base + addr, base + addr + size))
    if not ranges:
        raise ValueError(f'{path}: no allocated memory')
    return sorted(set(ranges))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--rmm', type=Path, required=True)
    p.add_argument('--uboot', type=Path, required=True)
    p.add_argument('--rmm-base', type=lambda x: int(x, 0), default=0x201000)
    p.add_argument('--rmm-size', type=lambda x: int(x, 0), default=0x25ff000)
    a = p.parse_args()
    try:
        rmm = memory_ranges(a.rmm, a.rmm_base)
        uboot = memory_ranges(a.uboot)
        for start, end in rmm:
            if start < a.rmm_base or end > a.rmm_base + a.rmm_size:
                raise ValueError('RMM exceeds its reserved memory')
            for other_start, other_end in uboot:
                if start < other_end and other_start < end:
                    raise ValueError(f'RMM {start:#x}..{end:#x} overlaps U-Boot '
                                     f'{other_start:#x}..{other_end:#x}')
    except (OSError, ValueError, struct.error) as error:
        p.exit(1, f'FIRMWARE_LAYOUT=FAIL {error}\n')
    print(json.dumps({'status': 'PASS', 'rmm': rmm, 'uboot': uboot,
                      'sha256': {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                                 for path in (a.rmm, a.uboot)}}, indent=2))


if __name__ == '__main__':
    main()

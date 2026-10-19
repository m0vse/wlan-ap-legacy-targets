#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Append one named E410B 5 GHz BDF entry; never alter shared defaults.

Only hashes, selection logic and validation are distributable source here.
The candidate data must be supplied explicitly as a private build input.
Possession/hash validity does not establish permission to redistribute it.
"""
import argparse
import hashlib
import os
from pathlib import Path
import struct
import tempfile

BASE_SHA256 = '94b66aa4ddbed5110a96364d3c7b4ebcb320e3ac4e8697660b277e76077bc338'
ASSET_SHA256 = 'ad5358d27065bba71fa9269634221ca47eefc827ccf39d0e9bc141e4141e8854'
VARIANT = 'Cambium-E410B-5G'
NAME = 'bus=ahb,bmi-chip-id=0,bmi-board-id=17,variant=' + VARIANT
MAGIC = b'QCA-ATH10K-BOARD\0'
CELL_SIZE = 12064


def tlvs(blob, offset=0):
    while offset < len(blob):
        if offset + 8 > len(blob):
            raise ValueError('truncated TLV header')
        tag, size = struct.unpack_from('<II', blob, offset)
        start = offset + 8
        end = start + size
        padded = start + ((size + 3) & ~3)
        if padded > len(blob):
            raise ValueError('truncated TLV payload')
        yield tag, blob[start:end]
        offset = padded


def encode(tag, blob):
    return struct.pack('<II', tag, len(blob)) + blob + b'\0' * (-len(blob) % 4)


def entries(blob):
    if not blob.startswith(MAGIC):
        raise ValueError('not an ath10k board archive')
    result = {}
    for tag, data in tlvs(blob, (len(MAGIC) + 3) & ~3):
        if tag != 0:
            raise ValueError('unexpected top-level IE')
        names = []
        for kind, value in tlvs(data):
            if kind == 0:
                names.append(value.decode('ascii'))
            elif kind == 1:
                if not names:
                    raise ValueError('board data without name')
                for name in names:
                    if name in result:
                        raise ValueError('duplicate board name')
                    result[name] = value
                names = []
            else:
                raise ValueError('unexpected board IE')
        if names:
            raise ValueError('board name without data')
    return result


def prepare(base, asset, model, radio, board_id):
    if (model, radio, board_id) != ('E410B', '5g', 17):
        raise ValueError('only E410B 5 GHz board ID17 is supported')
    if hashlib.sha256(base).hexdigest() != BASE_SHA256:
        raise ValueError('base BDF does not match qualified public archive')
    original = entries(base)
    if len(asset) != CELL_SIZE or struct.unpack_from('<H', asset)[0] != CELL_SIZE:
        raise ValueError('candidate calibration length mismatch')
    xor = 0
    for word in struct.unpack('<' + 'H' * (CELL_SIZE // 2), asset):
        xor ^= word
    if xor != 0xffff:
        raise ValueError('candidate checksum mismatch')
    if hashlib.sha256(asset).hexdigest() != ASSET_SHA256:
        raise ValueError('candidate does not match reviewed OEM Y9803 5 GHz data')
    if NAME in original:
        raise ValueError('variant already exists')
    result = base + encode(0, encode(0, NAME.encode('ascii')) + encode(1, asset))
    updated = entries(result)
    if updated != dict(original, **{NAME: asset}):
        raise ValueError('existing board entries changed')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ('base', 'asset', 'output', 'model', 'radio'):
        parser.add_argument('--' + arg, required=True)
    parser.add_argument('--board-id', required=True, type=int)
    args = parser.parse_args()
    temporary = None
    try:
        if not args.asset:
            raise ValueError('CAMBIUM_E410B_5G_BDF private input is required; no fallback release')
        output = Path(args.output)
        if output.is_symlink():
            raise ValueError('refusing symlink output')
        result = prepare(Path(args.base).read_bytes(), Path(args.asset).read_bytes(),
                         args.model, args.radio, args.board_id)
        fd, temporary = tempfile.mkstemp(prefix='.e410b-bdf-', dir=output.parent)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(result)
            os.fchmod(stream.fileno(), 0o644)
        os.replace(temporary, output)
        temporary = None
    except (OSError, ValueError, UnicodeError, struct.error) as error:
        parser.exit(1, 'E410B board-data packaging refused: ' + str(error) + '\n')
    finally:
        if temporary:
            os.unlink(temporary)


if __name__ == '__main__':
    main()

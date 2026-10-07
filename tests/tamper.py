#!/usr/bin/env python3
"""Makes altered copies of one box.efi for the integrity tests. Everything except the named
change stays as it is.

  tamper.py osrel  BOX.efi OUT.efi   one byte of the os-release text (.osrel)
  tamper.py linux  BOX.efi OUT.efi   one byte of the kernel's version string (.linux)
  tamper.py code   BOX.efi OUT.efi   one byte in a comment of the box's command script inside the
                                     initramfs; the image is reassembled from its own sections
  tamper.py repack BOX.efi OUT.efi   the same reassembly without any change (the control: it must
                                     give back BOX.efi byte for byte)
"""
import hashlib
import subprocess
import sys
import tempfile
from pathlib import Path

import pefile

STUB = '/usr/lib/systemd/boot/efi/linuxx64.efi.stub'


def sections(path):
    pe = pefile.PE(path, fast_load=True)
    out = {}
    for s in pe.sections:
        name = s.Name.rstrip(b'\0').decode()
        out[name] = (s.PointerToRawData, s.Misc_VirtualSize)
    return out


def section_bytes(data, secs, name):
    off, size = secs[name]
    return data[off:off + size]


def patch_once(data, secs, name, old, new, first=False):
    """Replace the occurrence of `old` inside section `name` by `new` (same length, one byte
    apart): the only one, or with first=True the first one."""
    assert len(old) == len(new) and sum(a != b for a, b in zip(old, new)) == 1, 'exactly one byte must change'
    off, size = secs[name]
    body = data[off:off + size]
    assert body.count(old) == 1 or (first and body.count(old) > 1), f'{old!r} occurs {body.count(old)} times in {name}'
    at = off + body.index(old)
    return data[:at] + new + data[at + len(old):]


def reassemble(box, out, change=None):
    data = Path(box).read_bytes()
    secs = sections(box)
    with tempfile.TemporaryDirectory() as t:
        t = Path(t)
        for name in ('.linux', '.cmdline', '.osrel', '.uname'):
            (t / name).write_bytes(section_bytes(data, secs, name))
        cpio = subprocess.run(['zstd', '-q', '-d', '-c'], input=section_bytes(data, secs, '.initrd'),
                              capture_output=True, check=True).stdout
        if change:
            old, new = change
            assert cpio.count(old) == 1, f'{old!r} occurs {cpio.count(old)} times in the initramfs'
            cpio = cpio.replace(old, new)
        (t / 'initrd').write_bytes(subprocess.run(['zstd', '-q', '-T16', '-9', '-c'], input=cpio,
                                                  capture_output=True, check=True).stdout)
        cmdline = (t / '.cmdline').read_bytes().rstrip(b'\0').decode()
        uname = (t / '.uname').read_bytes().rstrip(b'\0').decode()
        subprocess.run(['ukify', 'build', '--linux', str(t / '.linux'), '--initrd', str(t / 'initrd'), '--cmdline', cmdline,
                        '--os-release', f"@{t / '.osrel'}", '--uname', uname, '--stub', STUB, '--output', out],
                       check=True, capture_output=True)


def main():
    mode, box, out = sys.argv[1:4]
    data = Path(box).read_bytes()
    secs = sections(box)
    if mode == 'osrel':
        Path(out).write_bytes(patch_once(data, secs, '.osrel', b'NAME="escrow box"', b'NAME="Escrow box"'))
    elif mode == 'linux':
        # The kernel_version string of the bzImage setup header (uncompressed, read only by loaders).
        ver = section_bytes(data, secs, '.uname').rstrip(b'\0') + b' ('
        kernel = section_bytes(data, secs, '.linux')
        assert kernel.index(ver) < (kernel[0x1f1] + 1) * 512, 'not in the setup sectors'
        Path(out).write_bytes(patch_once(data, secs, '.linux', ver, ver[:-2] + b'X(', first=True))
    elif mode == 'code':
        reassemble(box, out, (b'Escrow box: the only commands of the sealed VM',
                              b'Escrow box: the only commands of the sealed vM'))
    elif mode == 'repack':
        reassemble(box, out)
    else:
        sys.exit(__doc__)
    a, b = Path(box).read_bytes(), Path(out).read_bytes()
    diff = sum(x != y for x, y in zip(a, b)) + abs(len(a) - len(b))
    print(f'{mode}: {out} sha256 {hashlib.sha256(b).hexdigest()[:16]}..., differs from the original in {diff} bytes')


if __name__ == '__main__':
    main()

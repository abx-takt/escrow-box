#!/bin/bash
# A self-contained demo "deal" for the escrow box: a tiny C program as the escrowed source, with a
# BUILD.txt that says how to rebuild it, and the "delivered" artifact's SHA-256 computed the same
# way so `verify` reproduces it byte for byte.
#
#   tests/demo-source.sh OUT
#
# Writes OUT/source.tar (the escrowed source) and OUT/delivered (NAME:SHA256). The build is made
# deterministic (static link, no build-id, no .comment/.note, stripped, SOURCE_DATE_EPOCH) so the
# box's rebuild inside the image matches this one, as long as the box's compiler is the same distro
# toolchain as here — both are stock Ubuntu 24.04 in the reference setup.
set -euo pipefail
OUT=${1:?output dir}; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/src/prog"
cat > "$W/src/prog/hello.c" <<'C'
#include <stdio.h>
int main(void) { puts("escrow-box demo artifact v1"); return 0; }
C
cat > "$W/src/prog/BUILD.txt" <<'TXT'
How to rebuild the delivered artifact from this source.

Command:
  cc -O2 -static -fno-ident -Wl,--build-id=none -o prog hello.c && strip -R .comment -R .note prog

Artifact: prog

The same compiler toolchain as the escrow box (here: stock Ubuntu 24.04 gcc) reproduces the
delivered artifact byte for byte.
TXT
find "$W/src" -exec touch -h -d @1700000000 {} +
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@1700000000 -C "$W/src" -cf "$OUT/source.tar" prog

# The "delivered" artifact: a fresh unpack built exactly as BUILD.txt says.
mkdir -p "$W/b"; tar -xf "$OUT/source.tar" -C "$W/b"
( cd "$W/b/prog" && env -i PATH=/usr/bin:/bin SOURCE_DATE_EPOCH=1700000000 LC_ALL=C TZ=UTC \
    sh -c 'cc -O2 -static -fno-ident -Wl,--build-id=none -o prog hello.c && strip -R .comment -R .note prog' )
echo "prog:$(sha256sum "$W/b/prog/prog" | cut -d' ' -f1)" > "$OUT/delivered"
cat "$OUT/delivered"

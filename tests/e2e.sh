#!/bin/bash
# End-to-end test of the escrow box in QEMU + OVMF + swtpm. Exercises the deterministic, offline
# core: provisioning, the role/command boundary, verify-by-rebuild (byte for byte), and that the
# sealed key opens only on an unmodified image and only on its own TPM.
#
#   tests/e2e.sh WORK
#
# The release rule's evidence (company register, heartbeat) is live and deployment-specific, so
# `status` here is only printed, not asserted; the reference setup exercises the full release path
# separately (see README).
set -uo pipefail
export PATH=$PATH:/usr/sbin:/sbin
P=$(cd "$(dirname "$0")/.." && pwd)
RUN=$P/run.sh
W=$(cd "${1:?work dir}" && pwd)
export ESCROW_BOX_MACHINES=$W/machines
pass=0; failed=0
ok(){ echo "PASS  $*"; pass=$((pass+1)); }
bad(){ echo "FAIL  $*"; failed=$((failed+1)); }
box(){ "$RUN" ssh "$@"; }
expect(){ local want=$1 what=$2; shift 3; "$@" >"$W/out" 2>"$W/err"; local got=$?
  if [ "$got" = "$want" ]; then ok "$what"; else bad "$what (exit $got, wanted $want): $(tail -c 300 "$W/err")"; fi; }

# keys, a (throwaway) heartbeat key, a syntactically valid rule, and the demo deal
for k in provider client; do [ -f "$W/$k" ] || ssh-keygen -q -t ed25519 -N '' -C "$k" -f "$W/$k"; done
[ -f "$W/hb" ] || ssh-keygen -q -t ed25519 -N '' -C hb -f "$W/hb"
python3 - "$W" > "$W/rule.json" <<'PY'
import json, sys
w=sys.argv[1]
pub=open(f"{w}/hb.pub").read().split(); allowed=f'heartbeat@example.com namespaces="heartbeat" {pub[0]} {pub[1]}\n'
print(json.dumps({"heartbeat":{"repository":"example/heartbeat","path":"heartbeats","days":90,"max_future_hours":1,
  "missing_grace_days":14,"signer":"heartbeat@example.com","namespace":"heartbeat","allowed_signers":allowed},
  "companies_house":{"page":"https://find-and-update.company-information.service.gov.uk/company/SC000000",
  "name":"EXAMPLE","terminal":["Dissolved","Liquidation"]}}))
PY
[ -f "$W/source.tar" ] || "$P/tests/demo-source.sh" "$W" >/dev/null
build(){ [ -f "$W/$1/box.efi" ] && return
  "$P/build.sh" --order "demo-$1" --source "$W/source.tar" --delivered "$(cat "$W/delivered")" --rule "$W/rule.json" \
    --provider-key "$W/provider.pub" --client-key "$W/client.pub" --out "$W/$1" ${ESCROW_BOX_KERNEL:+--kernel "$ESCROW_BOX_KERNEL"} ${2:+--cmdline-extra "$2"} >"$W/build-$1.log" 2>&1 \
    || { echo "build $1 failed"; tail "$W/build-$1.log"; exit 1; }; }
build A
build A2 "escrow.variant=2"
for m in m1 m2; do "$RUN" destroy "$m" 2>/dev/null; done
trap 'for m in m1 m2; do "$RUN" stop "$m" 2>/dev/null; done' EXIT

echo "== machine m1, image A"
"$RUN" start m1 "$W/A/box.efi" 18501 >/dev/null || { bad "m1 boots A"; exit 1; }
box m1 "$W/provider" provision < "$W/A/order.key" >"$W/H1" 2>"$W/err" && grep -q '^ey' "$W/H1" && ok "provider provisions: H sealed to m1's TPM" || bad "provision: $(cat "$W/err")"
box m1 "$W/client" sealed </dev/null >"$W/H1c" && cmp -s "$W/H1" "$W/H1c" && ok "client gets H (sealed)" || bad "sealed mismatch"
expect 1 "a second provision is refused" -- box m1 "$W/provider" provision < "$W/A/order.key"
expect 1 "the client key cannot provision" -- box m1 "$W/client" provision < "$W/A/order.key"
expect 1 "the provider key cannot run client commands" -- box m1 "$W/provider" check </dev/null
expect 1 "no shell: an arbitrary command is refused" -- box m1 "$W/client" "cat /etc/shadow" </dev/null
expect 0 "check: H opens here and opens the escrowed source" -- box m1 "$W/client" check </dev/null
expect 0 "check with H on stdin" -- box m1 "$W/client" check - <"$W/H1"
expect 0 "verify: the source rebuilds the delivered artifact byte for byte" -- box m1 "$W/client" verify </dev/null
grep -q '"verify": "PASS"' "$W/out" && ok "verify says PASS" || bad "verify: $(cat "$W/out")"
box m1 "$W/client" status </dev/null >"$W/status" 2>/dev/null; echo "      status (not asserted): $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["decision"])' "$W/status" 2>/dev/null || echo unavailable)"

echo "== m1 booted with image A2 (one boot parameter changed)"
"$RUN" start m1 "$W/A2/box.efi" 18501 >/dev/null || bad "m1 boots A2"
expect 2 "check fails: H does not open under another image" -- box m1 "$W/client" check - <"$W/H1"

echo "== m2 (another TPM), image A, H of m1"
"$RUN" start m2 "$W/A/box.efi" 18502 >/dev/null || bad "m2 boots A"
expect 2 "check fails: H is bound to m1's TPM" -- box m2 "$W/client" check - <"$W/H1"
"$RUN" stop m2

echo "== altered copies of the same box.efi"
python3 "$P/tests/tamper.py" repack "$W/A/box.efi" "$W/A-repack.efi" >/dev/null
cmp -s "$W/A/box.efi" "$W/A-repack.efi" && ok "control: reassembling A from its sections gives A byte for byte" || bad "reassembly not exact"
for m in osrel:"os-release" linux:"the kernel" code:"the box script in the initramfs"; do
  t=${m%%:*}
  python3 "$P/tests/tamper.py" "$t" "$W/A/box.efi" "$W/A-$t.efi" >/dev/null || { bad "tamper $t"; continue; }
  "$RUN" start m1 "$W/A-$t.efi" 18501 >/dev/null || { bad "m1 boots A-$t"; continue; }
  expect 2 "check fails: one byte changed in ${m#*:}" -- box m1 "$W/client" check - <"$W/H1"
done

echo "== $pass passed, $failed failed"
[ "$failed" = 0 ]

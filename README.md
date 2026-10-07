# Escrow box

A way to escrow source code so that **neither the vendor nor the customer can cheat**:

- the customer receives the source **only** when an agreed release event has happened (the vendor
  is gone, a deadline passed, a signature lapsed — whatever rule you choose);
- **before** that, the customer can prove to itself, as often as it likes, that the escrowed source
  is exactly the source of the binary it was given — **without ever seeing the source**;
- the vendor cannot quietly escrow the wrong thing, and cannot stop the release once the event has
  happened;
- there is no trusted third-party escrow agent holding a key that either side could lean on.

The trick: the escrow is a small **sealed virtual machine image**. A decryption key is sealed, with
a TPM, to the *measured boot of that exact image*. The image exposes only a few fixed commands and
no shell. The key unseals **only** on an unmodified image, and the image hands out the source
**only** when the release rule — evaluated inside the box against public, signed evidence — says the
event has occurred.

This is the classic "TPM / Clevis sealed secret" pattern (as used for disk unlock), turned into a
conditional, self-contained, auditable source-escrow box.

> Status: **prototype**, adversarially reviewed. It runs today on a local QEMU + swtpm harness and
> boots on a cloud Shielded VM. Several items are required before production use — see
> [Limitations](#limitations). Nothing here promises a guarantee that has not been measured.

---

## The problem

"Source escrow" is an old idea: a customer buying a binary wants the source released if the vendor
disappears, so they can keep maintaining what they depend on. The usual answer is a third-party
escrow agent. That has three weaknesses:

1. **The agent is a trusted party.** It holds a key; it can be pressured, hacked, or go out of
   business. Both sides have to trust it.
2. **The customer cannot check the deposit.** A vendor can deposit an empty archive, or last year's
   code. The customer only finds out when it's too late to matter.
3. **Release is a human/legal process**, slow and disputable, exactly when the vendor is gone and
   can no longer cooperate.

The escrow box removes the agent, lets the customer verify the deposit continuously, and makes
release a mechanical consequence of an observable fact.

## The idea

```
   vendor                          one image per deal                      customer
  ────────                      ───────────────────────                   ──────────
  builds the image   ────────▶  UKI: kernel + whole system (initramfs)     runs it in a VM
  (encrypted source,            + encrypted source + build environment      with a TPM, on a
   build env, rule)             + release rule + two SSH keys               platform both agree

                                measured boot  ──▶  PCRs in the TPM

  provisions once    ────────▶  seals the decryption key to THIS TPM   ───▶ keeps the sealed
  (sends the key)               and THIS measured image  (Clevis tpm2)      key "H"

                                the box accepts only fixed commands, no shell:
                                  check   — the sealed key opens here and opens the source
                                  verify  — rebuild the binary from the source, compare byte-for-byte
                                  status  — what the release rule decides right now, with evidence
                                  unlock  — give out the source IFF the release event has occurred
```

- The **image** is one bootable EFI binary (a [UKI](https://uapi-group.org/specifications/specs/unified_kernel_image/):
  stub + kernel + an initramfs holding the entire system). The vendor builds one per deal. Inside
  it: the encrypted source, the exact build environment, the release rule, and two SSH public keys
  (vendor's and customer's).
- The customer gets the image and may inspect **every byte of it except the encrypted source**.
- **Measured boot** records a hash of the image into the TPM's PCRs. The vendor **provisions** the
  box once: it seals the source's decryption key to those PCRs and that TPM with
  [Clevis](https://github.com/latchset/clevis)' `tpm2` pin. The sealed blob **H** is kept by the
  customer. After provisioning the vendor has no further access.
- From then on the customer drives the box through its commands. Each one unseals inside the box
  (`clevis decrypt`) and does exactly one job. Nothing but hashes, decisions and — after release —
  the source itself ever leaves the box.

Because the key is sealed to the measured image:

- change one byte of the image, boot a different kernel, add a kernel parameter, or move H to
  another machine — and **H does not open**;
- so the customer cannot tamper the rule out of the box and still unseal, and cannot run the box
  somewhere it could read around it.

## Verifying the deposit, before any release

Two commands let the customer trust the deposit without seeing it:

- **`check`** confirms the sealed key opens *here* and decrypts the escrowed archive to the SHA-256
  recorded in the manifest.
- **`verify`** goes further: it rebuilds the delivered binary from the escrowed source, offline,
  exactly as the build instructions say, and compares the result with the delivered binary
  **byte for byte**. It prints only the two hashes and PASS/DIFFERENT; the source and the build log
  never leave the box.

So "is the right source really in here, and does it really produce my binary?" is answered by the
customer, as often as it wants, years before any release — and answered by *building*, not by
trusting a checksum someone handed over.

## The procedure, step by step

A typical deal between a vendor and a customer (in the box's SSH roles, `provider` and `client`):

1. **Agree.** Vendor and customer agree the release rule and how it is checked automatically
   (`box/rule.py` + its config), and choose the platform the box will run on — one where the
   customer cannot read the VM's memory or vTPM (a cloud Shielded VM, or a confidential VM; see
   [What you must trust](#what-you-must-trust)).

2. **Vendor prepares the box.** The vendor runs `build.sh` to produce one `box.efi` with the
   encrypted source, the build environment and the agreed rule inside, and hands it to the customer.
   The vendor keeps `order.key` (the escrow key) and gives it to no one. `box.json` lists the image
   and source hashes and the PCRs the key will be sealed to.

3. **Customer inspects and records the hash.** The customer reads the rule and configuration out of
   the image (`box/rule.py`, `/etc/escrow-box/config.json` in the initramfs) and confirms they are
   the agreed ones, then records `sha256(box.efi)` — this is the exact image that must run. Nothing
   is sealed yet; the source stays encrypted.

4. **Vendor deploys and provisions.** The customer provides the VM on the agreed platform and grants
   the vendor access to it. The vendor deploys the `box.efi` it built onto that VM and confirms, from
   the platform's attestation, that the VM is the agreed confidential / Shielded instance — so the
   key it is about to seal cannot be read from RAM or the vTPM. It boots the image and runs
   `provision`: the box checks the key opens the source, seals it to this VM's TPM and measured boot,
   and returns the Clevis blob **H** to the customer. The vendor knows exactly which image it
   deployed and sealed.

5. **Customer takes over and checks.** The customer revokes the vendor's access. Because it owns the
   platform account, it reads the VM's boot disk and confirms the loaded EFI image hashes to the
   value it recorded in step 3 — so the running box is the one it inspected, not a substitute — and
   runs `pcrs` as a live cross-check (PCRs 9 and 11 measure only the image, so they match the agreed
   `box.efi` whatever the platform; PCR 4 also folds in the firmware's boot events). Then `check` and
   `verify` confirm H opens here and the source rebuilds the delivered artifact byte for byte, and
   `status` shows the rule's current decision. A second `provision` is refused while H exists; from
   now on the vendor has no access.

6. **Done.** The box sits on the customer's VM. The customer can re-run `check` / `verify` / `status`
   any time, and `unlock` yields the source the moment the rule's release event occurs.

> This split needs no trusted third party and no "did the key reach the right endpoint" assumption:
> the vendor deploys the image, so it knows what it sealed; the customer owns the platform and
> recorded the image hash, so it confirms the running box is that one. The one external trust is the
> platform's attestation that the VM is a genuine confidential / Shielded instance — a check the
> vendor makes before sealing (see [Limitations](#limitations)).

## The release rule

The rule is **pluggable**: it is just code inside the box that returns *hold* / *release* /
*no-decision* from public, signed evidence. The reference rule is a vendor-liveness ("dead man's
switch") rule, and shows the shape a good rule has:

The box **holds** while all of these are true, and **releases** otherwise:

- the vendor's entry in a public company register is **not** terminal (dissolved, in liquidation,
  administration, receivership, insolvency, struck off, …);
- a **recent, validly signed heartbeat** is present in a public repository (the vendor publishes a
  short signed statement on a schedule);

with the careful edges a real rule needs:

- a **grace period** before a deleted/hidden heartbeat repository counts as release (an
  administrative mistake should not trigger escrow);
- a **latch**: a heartbeat signed for the *future* (an attempt to pre-stage liveness) arms release
  for good;
- **time comes only from the TLS `Date` headers** of the evidence sources, which must agree within
  a few minutes — never from the VM's own clock, which the operator controls;
- **transport failure is never a decision**: if the sources can't be read, the box holds.

Design your own rule for your situation — a fixed date, a court-order attestation, a multi-party
signal — as long as it rests on evidence the box can fetch and authenticate, and on time it does not
control.

### What the rule cannot do, and what the contract is for

A rule evaluated from public signals cannot tell "the vendor is actively serving customers" from "a
script is still publishing heartbeats on the vendor's behalf." That gap is closed by contract, not
by code: the agreement obliges the vendor to hand over the key or the source on request in the
cases the box cannot distinguish. The box is the automatic, un-cheatable path for the clear cases;
the contract covers the rest.

## Beyond source code: escrowing any secret

Nothing in the box is specific to source. The same skeleton — **provision** (put a secret in, seal
it to the measured image on a confidential VM), the client's checks, and **unlock** on an agreed
event — escrows any secret whose release should be mechanical and un-cheatable.

**Example: a wallet key in a sale.** A buyer pays into an escrow wallet; the seller should get
control of the funds only once an agreed, checkable event occurs (say a change of title in a public
registry). Mapped onto the box:

- **provision** generates a fresh wallet key pair *inside the box*, prints the public address, and
  seals the private key to the measured image and the VM's TPM. The box does the sealing; no human
  ever handles the private key — not the buyer who runs provision (the confidential VM keeps it off
  the operator), not the seller. The key has no copy anywhere outside the sealed VM.
- Both parties **verify the image** (hash the boot disk, cross-check `pcrs`) against the agreed,
  open-source box *before any money moves*. This is what assures each side that the box neither
  leaks the key to the other nor kept a copy — the whole deal rests on it.
- The **buyer funds** the printed address; the **seller confirms** the funds on the public chain.
- On the agreed event the rule flips to release and **unlock** hands the private key to the seller —
  or, in a safer variant, the box itself signs a sweep to the seller's address, so the key never
  leaves the box at all.

What each side cannot do mirrors the source case: the seller cannot take the funds before the event
(the key is sealed; `unlock` refuses), and the buyer cannot claw them back (it cannot read the key
either) — the worst either can do is destroy the VM, which freezes the funds for everyone including
itself, so neither gains.

A one-time **test transfer** makes the whole chain checkable before the real money: `provision` can
expose a single-use command that signs and broadcasts a tiny amount to a *pre-agreed* return
address and then disables itself (a latch on the authenticated state). It proves the sealed key
really controls the published address and that signing works, without putting the deal's funds at
risk — the destination is fixed in advance and the command runs exactly once.

Extra care this use needs, because the sealed secret now controls money: prefer a **confidential
VM** (the key is kept even from the cloud, not only from the operator); **both** parties must verify
the image before funds move; availability is sharper (a frozen VM freezes real money — pick the
operator, add redundancy, or make a timeout-refund part of the rule); and the rule is only as
trustworthy as the authenticated, machine-checkable evidence of the event — where no signed feed
exists, fall back to a multi-party or contractual signal as the rule's input.

> This describes an application of the same `provision` / verify / `unlock` skeleton; the wallet
> key generation, signing and test-transfer command are the box's payload for that flavour, not part
> of the source-escrow reference here.

## What you must trust

The box binds the key to an *unmodified image*. It does **not**, by itself, stop whoever runs the VM
from reading the key out of RAM or the vTPM state. That is a property of the **platform**:

| Where you run it | Who can read the running key |
|---|---|
| Your own hardware / your own hypervisor | you can — **not suitable** for escrow against yourself |
| A cloud VM with a vTPM (e.g. a Shielded VM) | nobody but the cloud — you trust the cloud |
| A confidential VM whose vTPM lives inside the TEE | nobody but the CPU vendor — you trust the silicon |

For escrow, the customer runs the box on a platform where **the customer cannot read the VM's memory
or TPM** — a cloud Shielded VM, or a confidential VM. That is the one external trust the design
requires, and you choose how strong it is.

Two integrity properties hold regardless of platform:

- **The sealed-key envelope is validated before it is ever unsealed.** The box checks that H is a
  `tpm2` blob with exactly this deal's policy (bank, PCR set) and nothing else, so a crafted
  envelope cannot steer the unseal to leak key material.
- **The box's on-disk state is authenticated** (a MAC under a key derived from the sealed secret),
  so whoever controls the disk can delete or roll it back, but cannot forge a release.

## What is sealed to what

Clevis `tpm2`, SHA-256 bank, bound to the PCRs that describe *the image*, not the platform:

- **PCR 4** — the firmware's hash of every EFI binary it starts (here, the whole UKI, and any loader
  placed before it).
- **PCR 9** — the initramfs and kernel command line, measured by the kernel itself.
- **PCR 11** — the UKI's sections, measured by the boot stub.
- **PCR 12 / 13** — kernel parameters, credentials and system extensions injected from *outside* the
  image; these must stay empty.

Firmware/platform PCRs (secure-boot state, platform config, partition table) are **deliberately not
bound**: a cloud can change them with a firmware or dbx update, which would make the key
permanently unsealable with no tampering involved. Bind only what identifies your image.

## Building and running

The reference harness runs locally with QEMU + OVMF + swtpm — no cloud account needed — so you can
develop and test the whole flow on one machine, then move the same image to a cloud Shielded VM or a
confidential VM. In outline:

1. **Build** one UKI per deal: kernel + an initramfs containing the hardened system, the encrypted
   source, the build environment, the rule, and the two SSH keys. Boot it with measured boot; no
   shell, SSH forced-commands only; the kernel locked down (no hibernation, kexec, ptrace, module
   loading, `/dev/mem`).
2. **Provision** once (vendor): send the decryption key over SSH; the box checks it opens the
   source, seals it to the TPM + measured boot, and returns H.
3. **Operate** (customer): `check`, `verify`, `status`, `unlock` over SSH, any time.

Cloud notes that bite in practice:

- Pick a machine type and image whose **disk and NIC drivers are in your kernel** (a module-less
  initramfs sees only built-in drivers — e.g. prefer virtio over NVMe/gVNIC unless you build those
  in).
- Clouds that hand out a **/32 address** (so the gateway is off-link) need a host route to the
  gateway before the default route.
- An unsigned UKI boots with **Secure Boot off**; that is fine for the key binding (PCR 4 covers the
  image). Sign the UKI with your own key if your platform requires Secure Boot on.

## Repository layout

| Path | What |
|---|---|
| `build.sh` | build one box image for a deal (`box.efi`, `box.json`, `order.key`) |
| `run.sh` | local VM: QEMU + OVMF + swtpm per machine — `start` / `stop` / `ssh` / `destroy` |
| `box/escrow-box` | the box's only commands (provision / check / verify / status / unlock / sealed / pcrs) |
| `box/rule.py` | the example release rule (swap it for your own) |
| `box/init`, `box/sshd_config`, `box/udhcpc.script` | PID 1 (measured-boot hardening), key-only forced-command sshd, DHCP hook |
| `gcp/` | build a GCE image and a Shielded VM with a real vTPM — see `gcp/README.md` |
| `tests/demo-source.sh` | a self-contained demo deal (a tiny C program + `BUILD.txt`) |
| `tests/e2e.sh` | end-to-end in QEMU: provision, verify-by-rebuild, tamper, TPM binding |
| `tests/test_box.py` | offline unit tests for the rule, the envelope check and the state MAC |
| `tests/example-rule.json` | a template for the example rule's configuration |

## Quick start (local, QEMU + swtpm)

Needs a Linux host with KVM and: `qemu-system-x86_64`, `swtpm`, OVMF, `systemd-ukify`
(`systemd-boot-efi`), `clevis`/`clevis-tpm2`, `tpm2-tools`, `age`, `sgdisk`, `mkfs.vfat`, `mtools`,
plus passwordless `sudo` (the image is built in a chroot). Then:

```bash
tests/e2e.sh /tmp/escrow-demo          # builds a base image, a demo deal, boots it, runs the checks
python3 tests/test_box.py              # offline unit tests (no VM, no network)
```

`tests/e2e.sh` boots the demo box, has the **provider** provision it, then — as the **client** —
runs `check`, `verify` (rebuilds the demo binary byte for byte), proves a one-byte change to the
image stops the unseal, and proves the sealed key does not open on a second machine's TPM. Pass your
own kernel with `ESCROW_BOX_KERNEL=/path/to/vmlinuz` if the host has none under `/boot`.

## Limitations

This is a prototype. Before relying on it in production:

- **Platform attestation.** Before sealing, the vendor must confirm the VM is a genuine confidential
  / Shielded instance on the agreed platform — otherwise the customer could read the key from RAM.
  Because the vendor deploys the image itself (see the procedure above), this is a check the vendor
  performs at deploy time, not an unsolved "did the key reach the right endpoint" problem; it is
  strongest when it rests on the platform's hardware attestation (a vTPM quote / confidential-VM
  report) rather than the cloud console.
- **Availability.** H lives and dies with that VM's vTPM. Deleting the VM or its vTPM loses the
  escrow. Provision more than one, or keep a contractual fallback, while the vendor exists.
- **Reproducible image.** Make the image byte-reproducible so the customer can confirm it was built
  from public inputs.
- **State freshness.** The on-disk state is authentic but not fresh: disk rollback can remove a
  latch or restart a grace period, so a grace period is not a guaranteed wall-clock bound without a
  freshness anchor (e.g. a TPM NV counter).
- **Secure Boot / UKI signing**, and binding the escrowed build to the delivered artifact in your
  own pipeline.

None of these are hidden: name them in whatever agreement wraps the box.

## Why this shape

- **No escrow agent** to trust, pressure, or outlive.
- **The customer verifies by building**, continuously, not by trusting a deposit.
- **Release is mechanical** and happens exactly when an observable, signed fact says so — including
  when the vendor is gone and can no longer cooperate.
- **The vendor's know-how stays sealed** until the event; the customer only ever sees hashes and
  decisions before then.

## License

Apache License 2.0 — see [LICENSE](LICENSE).

The idea and this write-up come out of real source-escrow work; the design was refined through
rounds of adversarial review. Contributions and independent implementations are welcome.

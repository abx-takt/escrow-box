# Escrow box

A way to put **any secret in escrow** so that **neither party can cheat**: the secret is used or
handed over **only** when an agreed, checkable event has happened, nobody can take it early, nobody
can stop it once the event occurs, and there is no trusted third-party escrow agent holding a key
that either side could lean on.

The secret can be anything. Two examples, equally:

- **Source code** — the customer gets the source only if the vendor disappears, and *before* that
  can prove to itself, as often as it likes, that the escrowed source really is the source of its
  binary, **without ever seeing it**. ([walkthrough](#the-procedure-step-by-step))
- **A crypto-wallet key in a sale** — the buyer funds a wallet; the seller gets the money only once
  an agreed on-chain or registry event occurs; until then neither side can move the funds, and the
  key is **never disclosed to anyone**. ([walkthrough](#example-a-wallet-key-in-a-sale))

The trick is the same for both: the escrow is a small **sealed virtual machine image**. A key is
sealed, with a TPM, to the *measured boot of that exact image*. The image exposes only a few fixed
commands and no shell. The sealed key is usable **only** on an unmodified image, and the box acts on
it — decrypting the source, or signing a payment — **only** when the release rule, evaluated inside
the box against public, signed evidence, says the event has occurred.

This is the classic "TPM / Clevis sealed secret" pattern (as used for disk unlock), turned into a
conditional, self-contained, auditable escrow box for whatever you put inside.

> Status: **prototype**, adversarially reviewed. It runs today on a local QEMU + swtpm harness and
> boots on a cloud Shielded VM. Several items are required before production use — see
> [Limitations](#limitations). Nothing here promises a guarantee that has not been measured.

---

## The problem

Escrow — leaving a secret with a neutral party to be released on an agreed condition — is an old
idea. Source code released if a vendor disappears, a payment released when goods are delivered, a
credential released on a deadline: all the same shape, and all usually answered by a **third-party
escrow agent**, which has three weaknesses:

1. **The agent is a trusted party.** It holds the secret; it can be pressured, hacked, or go out of
   business. Both sides have to trust it.
2. **The recipient cannot check the deposit.** The depositor can lodge the wrong thing — an empty
   archive, last year's code, an address it secretly kept the key to — and the recipient finds out
   only when it is too late to matter.
3. **Release is a human/legal process**, slow and disputable, exactly when the depositor may be gone
   and can no longer cooperate.

The escrow box removes the agent, lets the recipient verify the deposit continuously — as far as the
secret allows (source that must rebuild the delivered binary; a wallet key that must control a
published address) — and makes release a mechanical consequence of an observable, signed fact. The
two examples above, source code and a wallet key, are instances of this one mechanism.

## The idea

The two parties are the **provider** (deposits the secret) and the **client** (receives it on the
event) — the box's two SSH roles. (In the source example they are the vendor and the customer; in
the wallet example, the setup and payout sides.)

```
   provider                        one image per deal                      client
  ──────────                    ───────────────────────                   ────────
  builds the image   ────────▶  UKI: kernel + whole system (initramfs)     runs it in a VM
  (encrypted secret,            + encrypted secret + what verify needs      with a TPM, on a
   verify data, rule)           + release rule + two SSH keys               platform both agree

                                measured boot  ──▶  PCRs in the TPM

  provisions once    ────────▶  seals the secret's key to THIS TPM     ───▶ keeps the sealed
  (sets up the key)             and THIS measured image  (Clevis tpm2)      blob "H"

                                the box accepts only fixed commands, no shell:
                                  check   — the sealed key opens here, against this deal
                                  verify  — prove the deposit is the agreed one, without revealing it
                                  status  — what the release rule decides right now, with evidence
                                  release — act on the secret IFF the event occurred
                                            (hand out the source; sign the agreed payment)
```

- The **image** is one bootable EFI binary (a [UKI](https://uapi-group.org/specifications/specs/unified_kernel_image/):
  stub + kernel + an initramfs holding the entire system). The provider builds one per deal. Inside
  it: the encrypted secret, whatever `verify` needs (e.g. the build environment, for source), the
  release rule, and two SSH public keys (the provider's and the client's).
- The client gets the image and may inspect **every byte of it except the encrypted secret**.
- **Measured boot** records a hash of the image into the TPM's PCRs. The box is **provisioned** once:
  the key that opens or uses the secret is sealed to those PCRs and that TPM with
  [Clevis](https://github.com/latchset/clevis)' `tpm2` pin. The sealed blob **H** stays on the box.
  After provisioning the provider has no further access.
- From then on the client drives the box through its commands. Each one unseals inside the box
  (`clevis decrypt`) and does exactly one job. Nothing but hashes, decisions and — after release —
  the released result ever leaves the box.

Because the key is sealed to the measured image:

- change one byte of the image, boot a different kernel, add a kernel parameter, or move H to
  another machine — and **H does not open**;
- so neither party can tamper the rule out of the box and still unseal, nor run the box somewhere it
  could be read around.

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

4. **Vendor provisions in its own account.** The vendor creates the VM — a genuine confidential /
   Shielded instance — in **its own account** at the agreed provider, deploys `box.efi`, boots it,
   and provisions it: the box seals the escrow key to that running image's TPM and measured boot.
   Because the whole provisioning happens inside the vendor's own account, with no other party in the
   path, the vendor knows the key was sealed to the agreed image on the agreed platform — there is no
   foreign endpoint to substitute and nothing to intercept. This is the account that will be handed
   over; the customer pays for it.

5. **Handover, then the customer takes exclusive control and verifies.** The vendor transfers the
   account — with the VM and its vTPM, carrying the sealed key **H** — to the customer. The customer
   then takes **exclusive** control: it rotates *every* credential (password, 2FA, API keys, service
   accounts, OS/SSH access, recovery contacts) and audits that no vendor principal or token remains.
   Only once the vendor is fully locked out does the customer **cold-boot the VM itself** and verify:
   the boot image hashes to the value recorded in step 3; `check` and `verify` pass (H opens on this
   boot, and the source rebuilds the delivered artifact byte for byte); and `pcrs` matches the
   expected measurements of that image. Because the customer initiated the boot with the vendor
   locked out, the box answering is the one that booted from the verified image — the hash and `pcrs`
   are conclusive here precisely because of the exclusive control and the fresh boot. Only then does
   the customer sign the acceptance act.

6. **Done.** The box runs on the account the customer now controls. The customer can re-run
   `check` / `verify` / `status` any time, and `unlock` yields the source (or, for a wallet, the box
   signs the payment) the moment the rule's release event occurs.

> This ordering is the approach a review accepted for removing the third-party agent and closing the
> two provisioning/handover gaps — the vendor provisions with **exclusive control of the deployment
> path** (nothing it does not control is in that path, so the key cannot be diverted — step 4), and
> the customer takes **exclusive** control and re-verifies from a **fresh boot it initiated** (so no
> leftover process can lie about the running image — step 5) — **provided** two conditions are met,
> which the reference does not yet implement: the image and boot configuration are verified through
> the platform's control plane *before* boot and the channel is bound to that verified VM/boot, and
> the handover rotates the box's own SSH host key (or uses a trusted resource-bound channel) so a
> retained key cannot let the vendor pass off another server. It also rests on the VM being a genuine
> confidential / Shielded instance, so the escrow key cannot be read from memory or the vTPM by
> whoever controls the account (see [What you must trust](#what-you-must-trust) and
> [Limitations](#limitations)).

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

## Example: a wallet key in a sale

The second example, a co-equal use of the same box. A buyer pays into an escrow wallet; the seller
should get the money only once an agreed, checkable event occurs (say a change of title in a public
registry). Mapped onto the box:

- **provision** generates a fresh wallet key pair *inside the box*, prints the public address, and
  seals the private key to the measured image and the VM's TPM. The box does the sealing; the key
  has no copy anywhere outside the sealed VM. Note this is a **different protocol** from the source
  reference, whose `provision` receives the key from the vendor: a genuinely *vendor-blind* generated
  key needs a confidential VM (so the vendor, who controls the account while provisioning, cannot
  read the key as it is made) **and** a separate generation-and-provenance proof. The reference box
  does not provide that; it is noted here as what the use would require.
- Both parties **verify the image** against the agreed, open-source box *before any money moves* (the
  same independent image check as in the source procedure). This is what assures each side that the
  box neither leaks the key to the other nor kept a copy — the whole deal rests on it.
- The **buyer funds** the printed address; the **seller confirms** the funds on the public chain.
- **The key is never disclosed to anyone.** On the agreed event the box itself signs a transaction
  that sends the balance to the **recipient address recorded at provision**, and broadcasts it. That
  fixed destination is the only thing the box will ever pay to, so *whoever* manages to trigger a
  transfer — buyer, seller, or anyone else — the money can only go to the agreed recipient. Releasing
  a raw key is deliberately **not** an option.

What each side cannot do: the seller cannot take the funds before the event (the box won't sign
until the rule releases), the buyer cannot claw them back (it never holds the key, and any transfer
the box makes goes to the recipient, not back to the buyer) — the worst either can do is destroy the
VM, which freezes the funds for everyone including itself, so neither gains.

A one-time **test transfer** makes the whole chain checkable before the real money: `provision` can
expose a single-use command that signs and broadcasts a tiny amount to the *same pre-agreed
recipient address* and then disables itself (a latch on the authenticated state). It proves the
sealed key really controls the published address and that signing works, without any way to divert
funds — the destination is fixed in advance and the command runs exactly once.

Extra care this use needs, because the sealed secret now controls money: prefer a **confidential
VM** (the key is kept even from the cloud, not only from the operator); **both** parties must verify
the image before funds move; availability is sharper (a frozen VM freezes real money — pick the
operator, add redundancy, or make a timeout-refund part of the rule); and the rule is only as
trustworthy as the authenticated, machine-checkable evidence of the event — where no signed feed
exists, fall back to a multi-party or contractual signal as the rule's input.

> This describes an application of the same provision / verify / release skeleton; the wallet key
> generation, the sign-to-recipient release and the test-transfer command are the box's payload for
> that flavour, not part of the source-escrow reference implementation here.

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

- **Trusted provisioning and handover (the key binding).** The [procedure above](#the-procedure-step-by-step)
  (vendor provisions in its own account → transfers the account → customer takes exclusive control
  and re-verifies from a fresh boot) is what gives the two bindings a sound provisioning needs: no
  foreign endpoint in the provisioning path, and a customer-initiated boot after full lockout so no
  leftover process can misreport the running image. It rests on completeness, not on extra
  attestation machinery: the customer must rotate *every* credential and access path and verify only
  after a cold boot it initiated. The prototype does not automate or test this handover end to end,
  and binding it additionally to the platform's hardware attestation (a vTPM quote bound to a fresh
  nonce) would make the image check cryptographic rather than procedural.
- **Platform trust model and lifetime.** The key re-enters RAM on every `check` / `verify` /
  `unlock`, so "sealed to the TPM" is not "never in memory"; the chosen platform must keep memory and
  TPM state confidential across every such operation and across the allowed restart, recovery and
  migration paths — not merely carry a confidential-VM label at first boot. Record the trust model
  (whom you rely on) and these requirements per platform, and re-provision if a configuration change
  cannot preserve them.
- **Availability.** H lives and dies with that VM's vTPM. Deleting the VM or its vTPM loses the
  escrow. Provision more than one, or keep a contractual fallback, while the vendor exists.
- **Reproducible image.** Make the image byte-reproducible so the client can confirm it was built
  from public inputs.
- **State freshness.** The on-disk state is authentic but not fresh: disk rollback can remove a
  latch or restart a grace period, so a grace period is not a guaranteed wall-clock bound without a
  freshness anchor (e.g. a TPM NV counter).
- **Secure Boot / UKI signing**, and binding the deposit to what was promised (the escrowed source
  to the delivered binary, the escrowed key to the published address) in your own pipeline.

None of these are hidden: name them in whatever agreement wraps the box.

## Why this shape

- **No escrow agent** to trust, pressure, or outlive.
- **The client verifies the deposit itself**, continuously — by rebuilding, by the published
  address, by whatever the secret allows — not by trusting what was lodged.
- **Release is mechanical** and happens exactly when an observable, signed fact says so — including
  when the provider is gone and can no longer cooperate.
- **The secret stays sealed** until the event; before then the client only ever sees hashes and
  decisions.

## License

Apache License 2.0 — see [LICENSE](LICENSE).

The idea and this write-up come out of real source-escrow work; the design was refined through
rounds of adversarial review. Contributions and independent implementations are welcome.

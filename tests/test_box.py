#!/usr/bin/env python3
"""Tests of the escrow box's release rule and its authenticated state, outside the VM: real
ssh-keygen signatures, the network replaced by a fake GitHub and Companies House.

  python3 escrow-box/tests/test_box.py < /dev/null
"""
import email.utils
import importlib.machinery
import importlib.util
import io
import json
import multiprocessing
import os
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from pathlib import Path

BOX = Path(__file__).resolve().parent.parent / 'box'
sys.path.insert(0, str(BOX))
import rule  # noqa: E402

NOW, DAY = 1_800_000_000, 86400
TMP = Path(tempfile.mkdtemp(prefix='escrow-box-test-'))
SIGNER, NS = 'heartbeat@example.com', 'heartbeat'
SHA = 'abc1234' + '0' * 33
KEY = TMP / 'signer'
subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(KEY)], check=True, stdin=subprocess.DEVNULL)
ALLOWED = f'{SIGNER} namespaces="{NS}" ' + ' '.join(Path(f'{KEY}.pub').read_text().split()[:2]) + '\n'
RULE = {'heartbeat': {'repository': 'owner/heartbeat', 'path': 'heartbeats', 'days': 90, 'max_future_hours': 1,
                      'missing_grace_days': 14, 'signer': SIGNER, 'namespace': NS, 'allowed_signers': ALLOWED},
        'companies_house': {'page': 'https://find-and-update.company-information.service.gov.uk/company/SO301872',
                            'name': 'ABX DEVELOPMENT LLP', 'terminal': ['Dissolved', 'Liquidation']},
        'time': {'max_skew_seconds': 600}, 'max_tarball_bytes': 100 << 20, 'self_check_minutes': 60}

# The box's command file, loaded as a module with its configuration and /data in a temp dir.
DATA = TMP / 'data'
DATA.mkdir()
(TMP / 'config.json').write_text(json.dumps({'order': 't', 'pcr_bank': 'sha256', 'pcr_ids': '4', 'source': {'sha256': ''},
                                             'delivered': {'name': 'bin/x', 'sha256': ''}, 'rule': RULE}))
os.environ.update(ESCROW_BOX_CONFIG=str(TMP / 'config.json'), ESCROW_BOX_DATA=str(DATA))
_loader = importlib.machinery.SourceFileLoader('escrow_box', str(BOX / 'escrow-box'))
box = importlib.util.module_from_spec(importlib.util.spec_from_loader('escrow_box', _loader))
_loader.exec_module(box)
IDENT = b'AGE-SECRET-KEY-1' + b'Q' * 58


def beat(issued, name_time=None):
    stamp = time.strftime('%Y-%m-%dT%H%M%SZ', time.gmtime(name_time if name_time is not None else issued))
    text = f"heartbeat\nIssued (UTC): {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(issued))}\n".encode()
    f = Path(tempfile.mkdtemp(dir=TMP)) / 'hb'
    f.write_bytes(text)
    subprocess.run(['ssh-keygen', '-q', '-Y', 'sign', '-f', str(KEY), '-n', NS, str(f)], check=True, stdin=subprocess.DEVNULL)
    return f'heartbeats/{stamp[:4]}/{stamp}.txt', text, Path(f'{f}.sig').read_bytes()


def beat_raw(name, issued_text):
    """A heartbeat with an arbitrary name and issue text, signed with the real key (lets a test
    present a record the Provider could sign but whose date is impossible)."""
    text = f"heartbeat\nIssued (UTC): {issued_text}\n".encode()
    f = Path(tempfile.mkdtemp(dir=TMP)) / 'hb'
    f.write_bytes(text)
    subprocess.run(['ssh-keygen', '-q', '-Y', 'sign', '-f', str(KEY), '-n', NS, str(f)], check=True, stdin=subprocess.DEVNULL)
    return name, text, Path(f'{f}.sig').read_bytes()


def envelope(**tpm2):
    """A clevis tpm2 JWE whose protected header can be bent field by field. Defaults match the test
    order (pcr_bank sha256, pcr_ids '4')."""
    t = {'hash': 'sha256', 'key': 'ecc', 'pcr_bank': 'sha256', 'pcr_ids': '4', 'jwk_pub': 'AAAA', 'jwk_priv': 'BBBB'}
    t.update(tpm2)
    header = {'alg': 'dir', 'enc': 'A256GCM', 'clevis': {'pin': 'tpm2', 'tpm2': t}}
    import base64 as b64
    h = b64.urlsafe_b64encode(json.dumps(header).encode()).rstrip(b'=')
    return h + b'.AA.BB.CC.DD'


def tarball(beats):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w:gz') as tf:
        for name, text, sig in beats:
            for n, data in ((name, text), (name + '.sig', sig)):
                info = tarfile.TarInfo(f'owner-heartbeat-{SHA[:7]}/{n}')
                info.size = len(data)
                tf.addfile(info, io.BytesIO(data))
    return buf.getvalue()


class FakeNet:
    def __init__(self, beats=(), ch='Active', repo=True, t=NOW, down=False):
        self.beats, self.ch, self.repo, self.t, self.down = beats, ch, repo, t, down

    def get(self, url, headers=None, limit=None):
        if self.down:
            raise rule.Unreachable('connection refused')
        d = {'Date': email.utils.formatdate(self.t, usegmt=True)}
        if 'company-information' in url:
            return 200, d, (f'<h1 class="heading-xlarge">ABX DEVELOPMENT LLP</h1><dd id="company-status">{self.ch}</dd>').encode()
        if '/tarball/' in url:
            return 200, d, tarball(self.beats)
        if '/commits/' in url:
            return 200, d, json.dumps({'sha': SHA}).encode()
        return (200, d, json.dumps({'default_branch': 'main'}).encode()) if self.repo else (404, d, b'')


def clean():
    for f in DATA.iterdir():
        f.unlink()


def decide(net, ident=IDENT):
    store = box.Store(ident)
    return rule.Rule(RULE, store, net).evaluate(), store


class Rule(unittest.TestCase):
    def setUp(self):
        clean()

    def test_alive_holds(self):
        self.assertEqual(decide(FakeNet([beat(NOW - 3 * DAY)]))[0]['decision'], 'hold')

    def test_stale_heartbeat_releases(self):
        self.assertEqual(decide(FakeNet([beat(NOW - 91 * DAY)]))[0]['decision'], 'release')

    def test_terminal_company_releases(self):
        self.assertEqual(decide(FakeNet([beat(NOW)], ch='Dissolved'))[0]['decision'], 'release')

    def test_no_heartbeat_releases(self):
        self.assertEqual(decide(FakeNet([]))[0]['decision'], 'release')

    def test_network_down_is_no_decision(self):
        self.assertEqual(decide(FakeNet([beat(NOW)], down=True))[0]['decision'], 'none')

    def test_lost_repository_waits_out_the_grace(self):
        self.assertEqual(decide(FakeNet(repo=False))[0]['decision'], 'none')
        self.assertEqual(decide(FakeNet(repo=False, t=NOW + 13 * DAY))[0]['decision'], 'none')
        self.assertEqual(decide(FakeNet(repo=False, t=NOW + 15 * DAY))[0]['decision'], 'release')

    def test_predated_heartbeat_arms_a_latch_that_outlives_it(self):
        net = FakeNet([beat(NOW - DAY), beat(NOW + 120 * DAY)])
        rule.Rule(RULE, box.Store(IDENT), net).self_check()
        later = FakeNet([beat(NOW - DAY), beat(NOW + 120 * DAY)], t=NOW + 121 * DAY)
        self.assertEqual(rule.Rule(RULE, box.Store(None), later).evaluate()['decision'], 'hold')  # the bare rule
        self.assertEqual(decide(later)[0]['decision'], 'release')                                  # with the latch


class State(unittest.TestCase):
    """The state on /data: whoever runs the VM can delete or roll it back, not forge it."""

    def setUp(self):
        clean()

    def test_forged_latch_is_ignored(self):
        (DATA / 'state.json').write_text(json.dumps({'state': {'latch': {'reason': 'forged'}}, 'mac': '00' * 32}))
        ev, store = decide(FakeNet([beat(NOW - DAY)]))
        self.assertEqual(ev['decision'], 'hold')
        self.assertTrue(store.rejected)

    def test_state_copied_from_another_order_is_ignored(self):
        other = box.Store(b'AGE-SECRET-KEY-1' + b'P' * 58)
        other.update(lambda st: st.setdefault('latch', {'reason': 'other order'}))
        self.assertEqual(decide(FakeNet([beat(NOW - DAY)]))[0]['decision'], 'hold')

    def test_own_latch_is_honoured_and_cannot_be_removed(self):
        s = box.Store(IDENT)
        s.update(lambda st: st.setdefault('latch', {'reason': 'seen'}))
        s.update(lambda st: st.clear())
        self.assertEqual(decide(FakeNet([beat(NOW - DAY)]))[0]['decision'], 'release')

    def test_concurrent_processes_never_lose_the_latch(self):
        procs = [multiprocessing.Process(target=_toggle_grace) for _ in range(3)]
        for p in procs:
            p.start()
        box.Store(IDENT).update(lambda st: st.setdefault('latch', {'reason': 'seen'}))
        for p in procs:
            p.join()
        self.assertEqual(box.Store(IDENT).load().get('latch'), {'reason': 'seen'})
        self.assertEqual([f.name for f in DATA.iterdir() if f.name.startswith('.state.json-')], [])


class Envelope(unittest.TestCase):
    """R35-01: the sealed-key envelope is checked before clevis sees it. An untrusted header field
    cannot pick another backend, add a command-line option, choose an output path or move key
    material. Here the parse-and-reject happens before any unseal call."""

    def test_the_order_envelope_is_accepted(self):
        self.assertTrue(box.valid_envelope(envelope()))

    def test_injected_option_in_the_pcr_field_is_rejected(self):
        # the pcr_ids field must equal the order's exactly; an appended option changes it
        self.assertFalse(box.valid_envelope(envelope(pcr_ids='4 -o /data/H.jwe')))

    def test_a_different_pcr_set_is_rejected(self):
        self.assertFalse(box.valid_envelope(envelope(pcr_ids='4,9,11,12,13')))
        self.assertFalse(box.valid_envelope(envelope(pcr_bank='sha1')))

    def test_another_backend_is_rejected(self):
        import base64 as b64
        header = {'alg': 'dir', 'enc': 'A256GCM', 'clevis': {'pin': 'sss', 'sss': {'url': 'http://x'}}}
        h = b64.urlsafe_b64encode(json.dumps(header).encode()).rstrip(b'=') + b'.AA.BB.CC.DD'
        self.assertFalse(box.valid_envelope(h))

    def test_a_non_base64_sealed_half_is_rejected(self):
        self.assertFalse(box.valid_envelope(envelope(jwk_pub='AA/BB=')))

    def test_extra_fields_are_rejected(self):
        import base64 as b64
        header = {'alg': 'dir', 'enc': 'A256GCM', 'clevis': {'pin': 'tpm2', 'surprise': 1,
                  'tpm2': {'hash': 'sha256', 'key': 'ecc', 'pcr_bank': 'sha256', 'pcr_ids': '4',
                           'jwk_pub': 'AA', 'jwk_priv': 'BB'}}}
        h = b64.urlsafe_b64encode(json.dumps(header).encode()).rstrip(b'=') + b'.AA.BB.CC.DD'
        self.assertFalse(box.valid_envelope(h))

    def test_wrong_shape_is_rejected(self):
        self.assertFalse(box.valid_envelope(b'not.a.jwe'))
        self.assertFalse(box.valid_envelope(envelope()[:-3]))   # four segments, not five


class Robustness(unittest.TestCase):
    """R35-02: a bad record or a failed observation is never a release, never cancels an
    authenticated latch, and never stops the periodic self-check."""

    def setUp(self):
        clean()

    def test_impossible_calendar_date_is_inadmissible_not_an_error(self):
        bad = beat_raw('heartbeats/2027/2027-13-01T000000Z.txt', '2027-13-01T00:00:00Z')
        ev = decide(FakeNet([beat(NOW - 3 * DAY), bad]))[0]
        self.assertEqual(ev['decision'], 'hold')   # the good one holds; the impossible one is skipped

    def test_a_bad_record_cannot_cancel_an_armed_latch(self):
        box.Store(IDENT).update(lambda st: st.setdefault('latch', {'reason': 'seen earlier'}))
        bad = beat_raw('heartbeats/2027/2027-13-01T000000Z.txt', '2027-13-01T00:00:00Z')
        ev = decide(FakeNet([bad]))[0]
        self.assertEqual(ev['decision'], 'release')

    def test_a_throwing_observation_keeps_the_latch_and_does_not_raise(self):
        box.Store(IDENT).update(lambda st: st.setdefault('latch', {'reason': 'seen earlier'}))

        class Boom:
            def get(self, *a, **k):
                raise RuntimeError('unexpected')
        ev = rule.Rule(RULE, box.Store(IDENT), Boom()).evaluate()
        self.assertEqual(ev['decision'], 'release')

    def test_a_throwing_observation_without_a_latch_is_no_decision(self):
        class Boom:
            def get(self, *a, **k):
                raise RuntimeError('unexpected')
        ev = rule.Rule(RULE, box.Store(IDENT), Boom()).evaluate()
        self.assertEqual(ev['decision'], 'none')

    def test_status_observation_records_the_predated_release(self):
        net = FakeNet([beat(NOW - DAY), beat(NOW + 120 * DAY)])
        ev = rule.Rule(RULE, box.Store(IDENT), net).evaluate()   # a status/check-style read, not self_check
        self.assertEqual(ev['decision'], 'release')
        self.assertIsNotNone(box.Store(IDENT).load().get('latch'))


def _toggle_grace():
    s = box.Store(IDENT)
    for i in range(100):
        s.update(lambda st: st.__setitem__('missing_since', i) if i % 2 else st.pop('missing_since', None))


if __name__ == '__main__':
    unittest.main(verbosity=2)

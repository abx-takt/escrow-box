"""Reference release rule for the escrow box: a provider-liveness ("dead man's switch") rule.

This is an example; replace it with whatever rule fits your situation (a fixed date, a court-order
attestation, a multi-party signal), as long as it rests on evidence the box can fetch and
authenticate and on time it does not control. The box's command layer does not depend on this rule.

The box holds while the provider's company-register status is NOT terminal AND a heartbeat is
present. Anything else releases:
  - the company register shows a terminal status (dissolved, liquidation, …), or
  - no admissible heartbeat newer than `days`, or
  - the heartbeat repository deleted or hidden for missing_grace_days in a row, or
  - a validly signed heartbeat dated in the future is present (pre-signed heartbeats cannot be
    staged in advance to extend the hold: staging them releases; a latch keeps it armed).
A transport failure is never a decision: nothing is released on it.

Time never comes from this machine's clock (whoever runs the VM controls it): every answer's Date
header (the heartbeat repository, branch head, tarball, the company register) must agree within
max_skew_seconds; the decision time is the earliest of them.

The state (latch, start of an absence) lives in a store the caller gives; in the box it is
authenticated with a key only the sealed box can derive, so the VM's operator cannot forge it.
"""
import calendar
import email.utils
import io
import json
import re
import subprocess
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

DAY = 86400
ALLOWED_HOSTS = {'api.github.com', 'codeload.github.com', 'find-and-update.company-information.service.gov.uk'}


class Unreachable(Exception):
    """A transport failure or an answer that cannot be trusted: no decision may rest on it."""


def allowed(url):
    u = urllib.parse.urlsplit(url or '')
    return u.scheme == 'https' and u.hostname in ALLOWED_HOSTS


class Redirects(urllib.request.HTTPRedirectHandler):
    """Every redirect is checked before it is followed."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not allowed(newurl):
            raise Unreachable(f'redirect to a disallowed source: {newurl}')
        return super().redirect_request(req, fp, code, msg, headers, newurl)


OPENER = urllib.request.build_opener(Redirects)


class Net:
    """HTTPS to the allowed hosts only, every redirect included, through the measured trust store.
    Successful and error answers obey the same origin policy."""

    def get(self, url, headers=None, limit=10 << 20):
        if not allowed(url):
            raise Unreachable(f'{url}: not an allowed HTTPS source')
        req = urllib.request.Request(url, headers={'User-Agent': 'escrow-box', **(headers or {})})
        try:
            with OPENER.open(req, timeout=60) as r:
                if not allowed(r.geturl()):
                    raise Unreachable(f'{url}: answered by {r.geturl()}')
                body = r.read(limit + 1)
                if len(body) > limit:
                    raise Unreachable(f'{url}: answer larger than {limit} bytes')
                return r.status, dict(r.headers), body
        except urllib.error.HTTPError as e:
            if not allowed(e.geturl() or url):
                raise Unreachable(f'{url}: error answer from a disallowed source {e.geturl()}') from e
            return e.code, dict(e.headers or {}), b''
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            raise Unreachable(f'{url}: {e}') from e


def server_time(headers):
    d = {k.lower(): v for k, v in headers.items()}.get('date')
    if not d:
        raise Unreachable('an answer without a Date header')
    return int(email.utils.parsedate_to_datetime(d).timestamp())


class Rule:
    """`store` has load() -> dict and update(change) -> dict (read-modify-write under a lock;
    an armed latch is monotonic)."""

    def __init__(self, cfg, store, net=None):
        self.cfg, self.store, self.net = cfg, store, net or Net()
        root = re.escape(cfg['heartbeat']['path'].strip('/'))
        # The only admissible place: <path>/<YYYY>/<YYYY-MM-DDTHHMMSSZ>.txt at the repository root.
        self.beat_re = re.compile(rf'^{root}/(\d{{4}})/((\d{{4}})-\d\d-\d\dT\d{{6}}Z)\.txt$')

    # --- evidence --------------------------------------------------------------------------

    def heartbeat(self, times):
        """The newest admissible heartbeat of the branch head, from its complete tarball."""
        hb = self.cfg['heartbeat']
        repo, api = hb['repository'], {'Accept': 'application/vnd.github+json'}
        status, headers, body = self.net.get(f'https://api.github.com/repos/{repo}', api)
        times.append(server_time(headers))
        if status == 404:
            return {'state': 'missing', 'detail': f'{repo} does not exist or is not public'}
        if status != 200:
            raise Unreachable(f'GitHub answered {status} for {repo}')
        branch = json.loads(body)['default_branch']
        status, headers, body = self.net.get(f'https://api.github.com/repos/{repo}/commits/{urllib.parse.quote(branch)}', api)
        times.append(server_time(headers))
        if status != 200:
            raise Unreachable(f'GitHub answered {status} for the head of {repo}')
        sha = json.loads(body)['sha']
        if not re.fullmatch(r'[0-9a-f]{40}', sha):
            raise Unreachable('bad commit id')
        status, headers, tarball = self.net.get(f'https://api.github.com/repos/{repo}/tarball/{sha}', limit=self.cfg['max_tarball_bytes'])
        times.append(server_time(headers))
        if status != 200:
            raise Unreachable(f'GitHub answered {status} for the tarball of {sha}')
        files = {}
        with tarfile.open(fileobj=io.BytesIO(tarball), mode='r:gz') as tf:
            for m in tf.getmembers():
                top, _, rel = m.name.partition('/')
                if not top.endswith('-' + sha[:7]):
                    raise Unreachable('the tarball is not the tree of the commit asked for')
                if m.isfile():
                    f = tf.extractfile(m)
                    files[rel] = f.read() if f else b''
        return {**self.admissible(files, min(times)), 'commit': sha}

    def admissible(self, files, now):
        """Maximum admissible signed issue time over the canonical heartbeat records."""
        hb = self.cfg['heartbeat']
        best, future = None, None
        with tempfile.TemporaryDirectory() as t:
            signers = Path(t) / 'allowed_signers'
            signers.write_text(hb['allowed_signers'])
            for name, text in files.items():
                m = self.beat_re.match(name)
                if not m or m.group(1) != m.group(3) or name + '.sig' not in files:
                    continue
                (Path(t) / 'sig').write_bytes(files[name + '.sig'])
                if subprocess.run(['ssh-keygen', '-Y', 'verify', '-f', str(signers), '-I', hb['signer'], '-n', hb['namespace'],
                                   '-s', str(Path(t) / 'sig')], input=text, capture_output=True).returncode:
                    continue
                stated = re.search(r'^Issued \(UTC\): (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)$', text.decode(errors='replace'), re.M)
                if not stated:
                    continue
                try:                             # an impossible calendar date (e.g. month 13, signed
                    issued = calendar.timegm(time.strptime(stated.group(1), '%Y-%m-%dT%H:%M:%SZ'))
                except ValueError:               # by the key owner) is simply inadmissible, not an error
                    continue
                if time.strftime('%Y-%m-%dT%H%M%SZ', time.gmtime(issued)) != m.group(2):
                    continue                     # the name must state the signed time
                if issued > now + hb['max_future_hours'] * 3600:
                    future = name                # signed for the future: staged in advance
                    continue
                if best is None or issued > best[1]:
                    best = (name, issued)
        if future:
            return {'state': 'predated', 'detail': f'a heartbeat signed for the future is present ({future})'}
        if best is None:
            return {'state': 'empty', 'detail': 'no admissible heartbeat in the repository'}
        return {'state': 'valid', 'file': best[0], 'issued': best[1]}

    def companies_house(self, times):
        ch = self.cfg['companies_house']
        status, headers, body = self.net.get(ch['page'])
        times.append(server_time(headers))
        if status != 200:
            raise Unreachable(f'Companies House answered {status}')
        html = body.decode(errors='replace')
        name = re.search(r'<h1[^>]*>\s*([^<]+?)\s*<', html)
        st = re.search(r'id="company-status"[^>]*>\s*([^<]+?)\s*<', html)
        if not (name and st) or ' '.join(name.group(1).split()).upper() != ch['name'].upper():
            raise Unreachable('the Companies House page could not be read')
        s = ' '.join(st.group(1).split())
        return {'status': s, 'terminal': any(s.lower().startswith(x.lower()) for x in ch['terminal'])}

    # --- the decision ----------------------------------------------------------------------

    def _observe_and_arm(self):
        """Observe, and if the observation is itself a fully validated release on a heartbeat signed
        for the future, record the latch. Only such a decision arms it: rejected, incomplete or
        time-inconsistent evidence ("none") never does. Any observation — status, check, unlock or
        the hourly self-check — records it, so what is observed and what is recorded agree."""
        ev = self.observe()
        if ev['decision'] == 'release' and ev.get('heartbeat', {}).get('state') == 'predated':
            latch = {'reason': ev['reason'], 'time_utc': ev.get('time_utc'), 'evidence': ev}
            self.store.update(lambda st: st.setdefault('latch', latch))
        return ev

    def evaluate(self):
        # Read the authenticated latch first: a failed or throwing observation must never cancel a
        # release that was validly recorded earlier (R35-02).
        latch = self.store.load().get('latch')
        try:
            ev = self._observe_and_arm()
        except Exception as e:
            ev = {'decision': 'none', 'release_event': False, 'reason': f'no decision: {e}'}
        latch = self.store.load().get('latch') or latch
        if ev['decision'] != 'release' and latch:
            return {**ev, 'decision': 'release', 'release_event': True, 'reason': f"armed earlier: {latch['reason']}", 'latch': latch}
        return ev

    def self_check(self):
        return self._observe_and_arm()

    def observe(self):
        out, times = {}, []
        try:
            ch = self.companies_house(times)
            beat = self.heartbeat(times)
        except Unreachable as e:
            return {**out, 'decision': 'none', 'release_event': False, 'reason': f'no decision: {e}'}
        out.update(heartbeat=beat, companies_house=ch)
        if max(times) - min(times) > self.cfg['time']['max_skew_seconds']:
            return {**out, 'decision': 'none', 'release_event': False, 'reason': f'no decision: answer times disagree ({min(times)}..{max(times)})'}
        now = min(times)
        out['time_utc'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(now))
        days = self.cfg['heartbeat']['days']
        if ch['terminal']:
            return {**out, 'decision': 'release', 'release_event': True, 'reason': f"Companies House: {ch['status']}"}
        # Owner's decision: a deleted or hidden heartbeat repository releases only if it has stayed
        # away for missing_grace_days (protection against an administrative mistake).
        if beat['state'] == 'missing':
            since = self.store.update(lambda st: st.setdefault('missing_since', now))['missing_since']
            gone = (now - since) / DAY
            grace = self.cfg['heartbeat']['missing_grace_days']
            if gone < grace:
                return {**out, 'decision': 'none', 'release_event': False,
                        'reason': f'no decision: heartbeat repository unavailable for {gone:.1f} days (grace {grace})'}
            return {**out, 'decision': 'release', 'release_event': True,
                    'reason': f'heartbeat repository unavailable for {gone:.1f} days (grace {grace})'}
        self.store.update(lambda st: st.pop('missing_since', None))
        if beat['state'] == 'valid':
            age = (now - beat['issued']) / DAY
            if age > days:
                return {**out, 'decision': 'release', 'release_event': True, 'reason': f'no admissible heartbeat for {age:.1f} days (limit {days})'}
            return {**out, 'decision': 'hold', 'release_event': False, 'reason': f"alive: heartbeat {age:.1f} days old, company {ch['status']}"}
        return {**out, 'decision': 'release', 'release_event': True, 'reason': f"heartbeat absent: {beat['detail']}"}

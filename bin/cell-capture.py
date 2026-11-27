#!/usr/bin/env python3
"""Get a cell's newest capture of its live changes with the developer's own Solution Console sign-in (#1421).

pull-back.sh --cell runs it; in the partner kit it is bin/cell-capture.py, next to bin/pull-back.sh. Standard library only.

    cell-capture.py --cell https://<cell>/solution-console/ --out <zip> [--capture] [--follows <json>]
    cell-capture.py --cell https://<cell>/solution-console/ --out <json> --workflows

With --workflows (#1597, pull-back-workflows.sh), steps 1 and 2 as below, then the workflows' and functions' live
changes as the Local changes tab's Workflows side has them (GET /portal/workflow-changes/export): the changed
definitions with the cell's values turned back into placeholders, and the changed functions' memory and timeout, as
JSON into --out. Exit 3 when nothing differs.

1. Reads https://<cell>/solution-console/cli.json, which scripts/publish-app.sh writes with the console: the cell's login
   address, the Solution Console's app client, its identity provider, the cell's API. Nothing in it is a secret.
   Before anyone signs in, the token's way is tied to the cell (#1441): the login address must be a Cognito domain, and
   that sign-in must list https://<cell>/solution-console/ as its client's own (the console's callback,
   lib/tenant-stack.ts): Cognito answers any other host with redirect_mismatch, so a look-alike address serving a copy
   of cli.json with its own `api` is refused here. cli.json then comes from the cell itself, and its `api` and
   `customerApi` are the cell's. Nothing is followed to a redirect but the presigned S3 download, which carries no token.
   Not checked: a look-alike address whose cli.json names a Cognito pool of its own. Its token opens nothing on the
   cell, but a Lambda trigger on that pool sees the password typed there; the login host is printed before the browser
   opens (docs/CELL-CAPTURE.md).
2. Signs in as the Solution Console does (authorization code with PKCE, lib/tenant-stack.ts): the browser opens the
   cell's own sign-in and comes back to http://127.0.0.1:40010/callback (40011 when 40010 is taken), the client's two
   loopback addresses (RFC 8252). The tokens stay in this process; nothing is written to disk. The id token must be
   that client's (aud) from a user pool in the login address's region (iss) before its first use.
3. With --capture, makes a capture first (POST /api/capture, as the Local changes tab's Capture now). Then the newest kept
   capture (GET /portal/changes) and its download link (GET /portal/changes/<at>/zip, an audit record under the
   developer's name), and the zip itself.
4. With --follows, the repository and branch the cell follows (#1207 slice 3), from the customer API with the same
   sign-in (GET <customerApi>/portal/<sourceKey>/source, as the Deployments tab reads it), into that file as
   {"repository", "branch"}, {"none": true} when the cell follows none yet, or {"error": "<why>"}. Only when cli.json
   names the customer API and the cell is a dev cell: its sourceKey, else, for a console built without a stage, the
   capture's own stage when it is dev (as the Deployments tab falls back to the cell's stage, #1467 review). Nothing is
   written otherwise, and a read that fails stops nothing.

Without --capture it refuses a newest capture that no longer says what differs: the cell booted another release since,
its live status lists other changes, or a file's sha256 there differs from the capture's (edited again since, #1442).
Who may is the Local changes tab's rule, which the cell applies.

Exit: 0 the zip is at --out; 1 refused (the reason is printed); 2 could not run; 3 the cell is in sync, nothing to get.
"""
import argparse, base64, datetime, hashlib, http.server, json, os, re, secrets, shlex, subprocess, sys, threading, time
import urllib.error, urllib.parse, urllib.request, webbrowser, zipfile

PORTS = (40010, 40011)          # the Solution Console client's loopback callbacks (lib/cell-capture.ts, CLI_CALLBACK_URLS)
SIGN_IN_S = 300                 # how long the browser has to come back
LIVE_MAX_AGE_S = 20 * 60        # the tab's "not checked" (app/src/changesData.ts, LIVE_MAX_AGE_MS)
TIMEOUT_S = 60
# The cell's login address: Cognito's own domain (lib/tenant-stack.ts, pool.addDomain with a cognitoDomain prefix).
COGNITO_DOMAIN = re.compile(r'[a-z0-9-]{1,63}\.auth\.([a-z]{2}(?:-[a-z]+)+-\d)\.amazoncognito\.com')
SOURCE_KEY = re.compile(r'[a-z0-9][a-z0-9-]{0,62}')            # a stage (dev) or an extra dev cell's id
SOURCE_NAME = re.compile(r'[A-Za-z0-9][A-Za-z0-9._/-]{0,199}')  # the customer API's plain names (app/src/deploymentsData.ts)


class Refused(Exception):
    pass


class Failed(Exception):
    pass


class Redirected(Refused):
    pass


def https_or_loopback(url, what):
    """An https address, or http on this machine (a test's fake cell). Anything else is refused before it is called."""
    u = urllib.parse.urlsplit(url or '')
    if u.scheme == 'https' and u.hostname:
        return u
    if u.scheme == 'http' and u.hostname in ('127.0.0.1', 'localhost'):
        return u
    raise Refused(f'{what} must be an https address, got {url!r}')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """No call is followed anywhere: urllib would send the token on to the new host, and cli.json or the sign-in's
    answer from another host would no longer be the cell's (#1441)."""
    def redirect_request(self, *a, **k):
        return None


NO_REDIRECTS = urllib.request.build_opener(NoRedirect)


def cell_base(url):
    """The cell's address as its sign-in client lists it (scheme://host[:port]): the host in lower case and punycode,
    without a trailing dot, no user, no default port. Cognito matches a callback exactly, so an address typed differently is not taken for a look-alike."""
    u = https_or_loopback(url, '--cell')
    try:
        port = u.port
    except ValueError:
        raise Refused(f'--cell has a port this kit does not read: {url!r}')
    host = u.hostname.rstrip('.')   # a fully qualified name's trailing dot: Cognito lists the name without it
    if ':' in host:
        host = f'[{host}]'
    else:
        try:   # a name typed in Unicode as Cognito lists it, in punycode (review of #1472)
            host = host.encode('idna').decode('ascii')
        except UnicodeError:
            raise Refused(f'--cell has a host name this kit does not read: {url!r}')
    default = {'https': 443, 'http': 80}[u.scheme]
    return f'{u.scheme}://{host}' + (f':{port}' if port and port != default else '')


def cognito_region(login, cell_on_this_machine):
    """The region of a Cognito login address (https://<prefix>.auth.<region>.amazoncognito.com, nothing more); None for
    a login on this machine, which is taken only for a cell on this machine (the tests' fake cell). Anything else is
    refused."""
    u = https_or_loopback(login, 'cli.json\'s loginDomain')
    if u.scheme == 'http':
        if not cell_on_this_machine:
            raise Refused(f'cli.json\'s loginDomain {login!r} is on this machine, and the cell is not')
        return None
    m = COGNITO_DOMAIN.fullmatch(u.netloc)
    if not m or u.path not in ('', '/') or u.query or u.fragment:
        raise Refused(f'cli.json\'s loginDomain {login!r} is not a Cognito sign-in address; a cell signs in only there')
    return m.group(1)


def check_token(cfg, bearer):
    """The id token is cli.json's client's, from a Cognito user pool in the login address's region (#1441). Its
    signature is not checked: it came straight from that login address's token endpoint, which is what would sign it."""
    try:
        part = bearer.split('.')[1]
        claims = json.loads(base64.urlsafe_b64decode(part + '=' * (-len(part) % 4)))
    except (IndexError, ValueError, TypeError):
        raise Refused('the sign-in answered a token this kit does not read')
    if not isinstance(claims, dict) or claims.get('token_use') != 'id':
        raise Refused('the sign-in answered no id token')
    if claims.get('aud') != cfg['clientId']:
        raise Refused('the sign-in answered a token for another app client than the one the cell\'s cli.json names')
    # cell_config refused a login on this machine for a cell elsewhere, so a None region here is the tests' fake cell.
    region = cognito_region(cfg['loginDomain'], True)
    m = re.fullmatch(r'https://cognito-idp\.([a-z0-9-]+)\.amazonaws\.com/([a-z0-9-]+)_[A-Za-z0-9]+', str(claims.get('iss', '')))
    if not m or m.group(1) != m.group(2) or (region and m.group(1) != region):
        raise Refused('the sign-in answered a token not issued by a Cognito user pool of the cell\'s login address')


def own_host(cfg, base):
    """Cognito at the login address lists base/solution-console/ as the client's callback, so this host is that cell's
    (#1441). Asked as the sign-in would, without the sign-in, and taken only on an answer that says so (review of #1472;
    as cell juan's Cognito answers): its sign-in page (/login on the login address), or an error sent to that callback
    itself, which Cognito does only for a callback the client lists. /error?error=redirect_mismatch is a look-alike
    address; any other answer is the cell's sign-in failing the check (a stale cli.json, a client recreated), never a
    pass."""
    console = f'{base}/solution-console/'
    q = urllib.parse.urlencode({'client_id': cfg['clientId'], 'response_type': 'code', 'scope': 'openid',
                                'redirect_uri': console})
    login = cfg['loginDomain'].rstrip('/')
    try:
        NO_REDIRECTS.open(urllib.request.Request(f'{login}/oauth2/authorize?{q}'), timeout=TIMEOUT_S).close()
        raise Failed('the cell\'s sign-in did not answer as Cognito does (no redirect)')
    except urllib.error.HTTPError as e:
        code, location = e.code, e.headers.get('Location') or ''
    except (urllib.error.URLError, OSError) as e:
        raise Failed(f'could not reach {urllib.parse.urlsplit(login).netloc}: {getattr(e, "reason", e)}')
    to = urllib.parse.urlsplit(urllib.parse.urljoin(f'{login}/oauth2/authorize', location))
    on_login = (to.scheme, to.netloc) == tuple(urllib.parse.urlsplit(login)[:2])
    if code in (302, 303) and on_login and to.path == '/login':
        return
    if code in (302, 303) and f'{to.scheme}://{to.netloc}{to.path}' == console:
        return
    why = (dict(urllib.parse.parse_qsl(to.query)) or dict(urllib.parse.parse_qsl(to.fragment))).get('error', '')
    if code in (302, 303) and on_login and to.path.rstrip('/') == '/error' and why == 'redirect_mismatch':
        raise Refused(f'{base} is not a cell of the sign-in it names (redirect_mismatch): its Solution Console client does '
                      f'not list {console}. Use the address the Local changes tab copies')
    if why:
        raise Failed(f'the cell\'s sign-in answered {why[:100]} when asked whether {console} is its console, so the host is '
                     f'not checked: the cell\'s cli.json may be out of date (republish its console), or its sign-in is not set up')
    raise Failed(f'the cell\'s sign-in did not answer as Cognito does ({code} to {to.path or "nowhere"})')


def call(method, url, bearer=None, data=None, follow=False):
    """(status, headers, body bytes) of a call; a 4xx is refused with the cell's own reason, anything else fails. Only
    follow (the presigned S3 download: no token, nothing the cell vouches for in the answer) goes on to a redirect."""
    req = urllib.request.Request(url, data=data, method=method)
    if bearer:
        req.add_header('Authorization', f'Bearer {bearer}')
    if data is not None:
        req.add_header('Content-Type', 'application/x-www-form-urlencoded')
    try:
        with (urllib.request.urlopen if follow and not bearer else NO_REDIRECTS.open)(req, timeout=TIMEOUT_S) as r:
            return r.status, r.headers, r.read()
    except urllib.error.HTTPError as e:
        body = e.read()
        try:
            reason = json.loads(body).get('error') or ''
        except (ValueError, AttributeError):
            reason = ''
        path = urllib.parse.urlsplit(url).path
        if 300 <= e.code < 400:
            if path.endswith('/cli.json'):
                raise Redirected(f'cli.json was redirected ({e.code}); the cell serves it itself, so it is not followed')
            if bearer:
                raise Failed(f'{method} {path} was redirected ({e.code}); a call with your sign-in is not followed elsewhere')
            raise Failed(f'{method} {path} was redirected ({e.code}); the cell answers it itself, so it is not followed')
        if 400 <= e.code < 500:
            raise Refused(f'the cell refused {method} {path} ({e.code}){": " + str(reason)[:300] if reason else ""}')
        raise Failed(f'the cell did not answer {method} {path} ({e.code}){": " + str(reason)[:300] if reason else ""}')
    except (urllib.error.URLError, OSError) as e:
        raise Failed(f'could not reach {urllib.parse.urlsplit(url).netloc}: {getattr(e, "reason", e)}')


def get_json(url, bearer=None):
    _, _, body = call('GET', url, bearer)
    try:
        return json.loads(body)
    except ValueError:
        raise Failed(f'{urllib.parse.urlsplit(url).path} did not answer JSON')


def cell_config(cell_url):
    base = cell_base(cell_url)
    try:
        cfg = get_json(f'{base}/solution-console/cli.json')
    except Redirected:
        raise
    except Refused:
        raise Refused(f'{base} has no solution-console/cli.json: is it a cell\'s address, and is its console published '
                      f'by a build that writes it (scripts/publish-app.sh)? Until then, download the capture in the '
                      f'Local changes tab and use --from')
    if not isinstance(cfg, dict) or cfg.get('format') != 1:
        raise Refused('the cell\'s cli.json is in a format this kit does not read: use the kit of the edition the cell runs')
    if not re.fullmatch(r'[A-Za-z0-9]{1,128}', str(cfg.get('clientId', ''))):
        raise Refused('the cell\'s cli.json names no Solution Console client')
    for k in ('loginDomain', 'api'):
        https_or_loopback(cfg.get(k), f'cli.json\'s {k}')
    cognito_region(cfg['loginDomain'], urllib.parse.urlsplit(base).scheme == 'http')
    if cfg.get('customerApi') or cfg.get('sourceKey'):
        https_or_loopback(cfg.get('customerApi'), 'cli.json\'s customerApi')
        if 'sourceKey' in cfg and not SOURCE_KEY.fullmatch(str(cfg['sourceKey'])):
            raise Refused('the cell\'s cli.json names a cell key this kit does not read')
    own_host(cfg, base)
    return cfg


def source_key(cfg, zip_path):
    """The key the customer API knows this cell by: cli.json's, else dev when the capture says the cell is a dev cell."""
    if cfg.get('sourceKey'):
        return cfg['sourceKey']
    try:
        with zipfile.ZipFile(zip_path) as z:
            stage = json.loads(z.read('capture.json')).get('stage')
    except (OSError, KeyError, ValueError, AttributeError, zipfile.BadZipFile):
        return None
    return 'dev' if stage == 'dev' else None


def follows(cfg, bearer, key):
    """What the cell follows, as --follows writes it. The main dev cell: the repository and branch its newest delivery
    reported; an extra dev cell: the ones saved for it (lambda/customer-api/index.mjs, source)."""
    try:
        answer = get_json(f'{cfg["customerApi"].rstrip("/")}/portal/{key}/source', bearer)
    except (Refused, Failed) as e:
        return {'error': str(e).replace('the cell refused', 'the customer API refused')
                .replace('the cell did not answer', 'the customer API did not answer')[:300]}
    # Any shape but the one expected is a note for pull-back, never a stop: the capture is already taken (#1467 review).
    cell = answer.get('cell') if isinstance(answer, dict) else None
    if not isinstance(cell, dict):
        return {'error': 'the customer API answered no source'}
    got = answer.get('source') if cell.get('devCell') else answer.get('main')
    if not got:
        return {'none': True}
    if not isinstance(got, dict):
        return {'error': 'the customer API answered a source this kit does not read'}
    repository, branch = str(got.get('repository', '')), str(got.get('branch', ''))
    if not (SOURCE_NAME.fullmatch(repository) and SOURCE_NAME.fullmatch(branch)) or '..' in branch:
        return {'error': 'the customer API named a repository or branch this kit does not take'}
    return {'repository': repository, 'branch': branch}


def open_browser(url):
    """PULLBACK_BROWSER (a command, the address appended) when set, else the system's browser; never waited for."""
    cmd = os.environ.get('PULLBACK_BROWSER')
    if cmd:
        try:
            subprocess.Popen(shlex.split(cmd) + [url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except (OSError, ValueError) as e:
            print(f'note: PULLBACK_BROWSER could not be started ({e}); open the address above', file=sys.stderr)
        return
    try:
        webbrowser.open(url)
    except webbrowser.Error:
        pass


def sign_in(cfg):
    """The id token of the developer's Solution Console sign-in."""
    server = None
    for port in PORTS:
        try:
            server = http.server.HTTPServer(('127.0.0.1', port), Callback)
            break
        except OSError:
            continue
    if server is None:
        raise Failed(f'ports {" and ".join(map(str, PORTS))} on 127.0.0.1 are both taken; the sign-in comes back to one of them')
    redirect = f'http://127.0.0.1:{server.server_port}/callback'
    state = secrets.token_urlsafe(24)
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b'=').decode()
    q = {'client_id': cfg['clientId'], 'response_type': 'code', 'scope': 'openid email profile',
         'redirect_uri': redirect, 'state': state, 'code_challenge': challenge, 'code_challenge_method': 'S256'}
    if cfg.get('idp'):
        q['identity_provider'] = cfg['idp']   # straight to the customer's directory, as the console on that cell
    url = f'{cfg["loginDomain"].rstrip("/")}/oauth2/authorize?{urllib.parse.urlencode(q)}'
    # Where the token will go, before anyone signs in: the API of the cli.json the cell itself served (own_host, #1441).
    print(f'The sign-in goes to {urllib.parse.urlsplit(cfg["api"]).netloc}, the API {cfg.get("cell") or "the cell"}\'s cli.json names.',
          file=sys.stderr)
    print(f'Sign in to the Solution Console in the browser, at {urllib.parse.urlsplit(cfg["loginDomain"]).netloc} '
          f'(the cell\'s sign-in). If it does not open, open:\n  {url}', file=sys.stderr)
    server.answer = None
    deadline = time.monotonic() + SIGN_IN_S

    def serve():
        # Until the sign-in comes back to /callback: anything else that reaches the port first (a favicon, a prefetch, a
        # stray tab) gets a 404 and the wait goes on.
        while server.answer is None and time.monotonic() < deadline:
            server.timeout = max(0.1, deadline - time.monotonic())
            server.handle_request()

    done = threading.Thread(target=serve, daemon=True)
    done.start()
    open_browser(url)
    done.join(SIGN_IN_S + 5)
    server.server_close()
    got = server.answer
    if not got:
        raise Refused(f'no sign-in came back within {SIGN_IN_S // 60} minutes')
    if got.get('state') != state:
        raise Refused('the sign-in that came back is not the one this run started (state differs); run it again')
    if got.get('error'):
        raise Refused(f'the sign-in was refused: {got.get("error_description") or got["error"]}'[:300])
    if not got.get('code'):
        raise Refused('the sign-in came back without a code')
    form = urllib.parse.urlencode({'grant_type': 'authorization_code', 'client_id': cfg['clientId'], 'code': got['code'],
                                   'redirect_uri': redirect, 'code_verifier': verifier}).encode()
    _, _, body = call('POST', f'{cfg["loginDomain"].rstrip("/")}/oauth2/token', data=form)
    try:
        bearer = json.loads(body)["id_token"]
    except (ValueError, KeyError, TypeError):
        raise Failed('the cell\'s sign-in answered no id token')
    return bearer


class Callback(http.server.BaseHTTPRequestHandler):
    timeout = 5   # a connection that sends nothing (a browser's speculative one) gives way to the next

    def do_GET(self):
        u = urllib.parse.urlsplit(self.path)
        if u.path != '/callback':
            self.send_response(404); self.end_headers(); return
        self.server.answer = {k: v[0] for k, v in urllib.parse.parse_qs(u.query).items()}
        ok = 'code' in self.server.answer
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write(('<!doctype html><title>censhare pull-back</title><p>'
                          + ('Signed in. You can close this tab and go back to the terminal.' if ok
                             else 'The sign-in did not complete. Go back to the terminal.') + '</p>').encode())

    def log_message(self, *a):
        pass


def changed_set(x):
    files = {(f.get('path'), f.get('change')) for f in (x.get('files') or []) if isinstance(f, dict)}
    return files, bool((x.get('settings') or {}).get('ingest'))


def changed_again(live, latest):
    """The files edited again since the capture (#1442): listed in both under the same path, the live status with another
    sha256. A file without both digests (a bridge before #1442; a file larger than a capture carries, or left when the
    bridge's minute ran out) is never claimed; whether those were edited again is not known."""
    def digests(x):
        return {f.get('path'): f.get('sha256') for f in (x.get('files') or []) if isinstance(f, dict)}
    then, now = digests(latest), digests(live)
    unknown = [p for p in now if not now[p] or not then.get(p)]
    if unknown:
        # Either side may lack one: the live status (an older bridge) or the capture (an older format).
        print(f'note: no digest to compare for {len(unknown)} file(s), so whether a file was edited again since the '
              'capture is not known for those: run with --capture when in doubt', file=sys.stderr)
    return sorted(p for p in now if now[p] and then.get(p) and now[p] != then[p])


def when(x):
    """An ISO time as an aware datetime, or None."""
    try:
        return datetime.datetime.fromisoformat(str(x).replace('Z', '+00:00'))
    except ValueError:
        return None


def stale_reason(answer):
    """Why the newest capture no longer says what differs now, or None. The live status when it is fresh, compared and
    checked after the capture (the bridge checks about once a minute, so it can be older than a capture just made)."""
    latest, live = answer.get('latest'), answer.get('live')
    if (answer.get('running') or {}).get('safeMode'):
        return 'safe-mode'
    if latest.get('current') is False:
        return 'the cell has booted another release since that capture'
    if not isinstance(live, dict):
        return None
    at, captured = when(live.get('checkedAt')), when(latest.get('capturedAt'))
    age = (datetime.datetime.now(datetime.timezone.utc) - at).total_seconds() if at else None
    if age is None or age > LIVE_MAX_AGE_S or not live.get('comparable') or (captured and at <= captured):
        print('note: the cell\'s live status is not current, or older than the capture, so whether it changed since the '
              'capture is not known', file=sys.stderr)
        return None
    if live.get('inSync'):
        return 'in-sync'
    cut = max(int(x.get('filesCut') or 0) for x in (live, latest))
    if cut:
        # The cell's function lists at most MAX_FILES files (#1577 review): those past it are not compared, by path or
        # digest, so whether they changed since the capture is not known.
        print(f'note: the cell lists only the first {len(live.get("files") or [])} of {cut} changed files, so the ones past '
              'them are not compared with the capture: run with --capture when in doubt', file=sys.stderr)
    if changed_set(live) != changed_set(latest):
        return 'the cell\'s live changes differ from that capture now'
    again = changed_again(live, latest)
    if again:
        more = f' and {len(again) - 3} more' if len(again) > 3 else ''
        return f'{", ".join(again[:3])}{more} changed again since that capture'
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--cell', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--capture', action='store_true')
    ap.add_argument('--follows')
    ap.add_argument('--workflows', action='store_true')
    a = ap.parse_args()
    if a.workflows and (a.capture or a.follows):
        raise Failed('--workflows takes neither --capture nor --follows')
    cfg = cell_config(a.cell)
    bearer = sign_in(cfg)
    check_token(cfg, bearer)
    if a.workflows:
        return take_workflows(cfg, bearer, a.out)
    rc = take(cfg, bearer, a)
    key = source_key(cfg, a.out) if rc == 0 and a.follows and cfg.get('customerApi') else None
    if key:
        with open(a.follows, 'w') as fh:
            json.dump(follows(cfg, bearer, key), fh)
    return rc


def take_workflows(cfg, bearer, out):
    """The workflows' live changes into out (#1597): 0, or 3 when nothing differs that goes back to git."""
    api = cfg['api'].rstrip('/')
    x = get_json(f'{api}/portal/workflow-changes/export', bearer)
    if not isinstance(x, dict) or not isinstance(x.get('flows'), list) or not isinstance(x.get('functions'), list):
        raise Failed('the cell answered its workflows\' changes in a form this kit does not read')
    with open(out, 'w') as fh:
        json.dump(x, fh)
    taken = [f for f in x['flows'] if 'definition' in f] + [f for f in x['functions'] if 'memoryMb' in f or 'timeoutSeconds' in f]
    return 0 if taken or any('refused' in f for f in x['flows']) else 3


def take(cfg, bearer, a):
    """The capture into a.out: 0, or 3 when the cell is in sync."""
    api = cfg['api'].rstrip('/')
    if a.capture:
        _, headers, body = call('POST', f'{api}/api/capture', bearer, data=b'')
        kept = headers.get('X-Capture-Kept-At') or ''
        if not kept:
            # A cell that keeps no captures answers the zip itself (the tab saves it in the browser then).
            with open(a.out, 'wb') as fh:
                fh.write(body)
            print('captured (the cell keeps no captures: this zip is the only copy)', file=sys.stderr)
            return 0
        print(f'captured: {kept}', file=sys.stderr)
        # This run's capture, by its stamp: the newest in the list may already be someone else's, or the list may not
        # read it yet. pull-back says so when it is in sync.
        m = re.fullmatch(r'captures/[a-z0-9][a-z0-9-]*/(\d{8}T\d{9}Z)/?', kept)
        if not m:
            raise Failed('the cell named its capture in a form this kit does not read')
        return download(api, bearer, m.group(1), a.out, f'the capture this run made ({m.group(1)})')
    answer = get_json(f'{api}/portal/changes', bearer)
    latest = answer.get('latest') if isinstance(answer, dict) else None
    if not latest:
        raise Refused('the cell keeps no capture to pull back' + ('' if a.capture else ': make one with --capture, or with '
                      'Capture now in the Local changes tab'))
    if not a.capture:
        why = stale_reason(answer)
        if why == 'safe-mode':
            raise Refused('the cell runs in safe mode, so it is not compared with its release and its captures may be out of '
                          'date. Once it runs its release again, run this with --capture')
        if why == 'in-sync':
            print(f'{answer.get("cell", "the cell")} is in sync with its release now: nothing to pull back', file=sys.stderr)
            return 3
        if why:
            raise Refused(f'the newest capture ({latest.get("capturedAt")}) no longer says what differs: {why}. Run again '
                          f'with --capture to capture the cell first')
    if latest.get('inSync'):
        print(f'the newest capture of {answer.get("cell", "the cell")} is in sync: nothing to pull back', file=sys.stderr)
        return 3
    at = str(latest.get('at', ''))
    if not re.fullmatch(r'\d{8}T\d{9}Z', at):
        raise Failed('the cell named its newest capture in a form this kit does not read')
    return download(api, bearer, at, a.out, f'the capture of {latest.get("capturedAt")}')


def download(api, bearer, at, out, what):
    """The capture `at` through the audited link (an audit record under the developer's name), then S3 without the token."""
    link = get_json(f'{api}/portal/changes/{at}/zip', bearer)
    https_or_loopback(link.get('url'), 'the download link')
    _, _, zipped = call('GET', link['url'], follow=True)   # S3 may send it on (307); it carries no token
    with open(out, 'wb') as fh:
        fh.write(zipped)
    print(f'downloaded {what} ({link.get("fileName", "capture.zip")})', file=sys.stderr)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Refused as e:
        print(f'refused: {e}', file=sys.stderr); sys.exit(1)
    except Failed as e:
        print(f'error: {e}', file=sys.stderr); sys.exit(2)
    except KeyboardInterrupt:
        sys.exit(2)

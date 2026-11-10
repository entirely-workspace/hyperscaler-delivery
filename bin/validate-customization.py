#!/usr/bin/env python3
"""Check a customer's customization package offline, before anything is uploaded (#385, T9).

    validate-customization.py <customer repo> [--product <censhare-Server dir> | --product-index <file>]
                              [--skip-refcheck] [--files-json <out>] [--strict-fields]
    validate-customization.py --write-product-index <out> --product <censhare-Server dir>
    validate-customization.py --credentials <dir>

The customer repository's customization.json declares the package (docs/CUSTOMIZATION-DELIVERY.md §1.2, §6):

    vendor, package, source, owns, excludes      what scripts/publish-customization.sh has always read
    censhareVersion      a range, e.g. ">=2026.2 <2027.1"     \\
    hyperscalerContract  the edition's delivery contract (1)   |  the package's label (§6). Optional for now: missing
    activation           "refresh" or "boot"                   |  is a warning (an error with --strict-fields), wrong
    touchesMasterdata    true when the package carries any     |  is an error. Their enforcement against a cell comes
                         masterdata                            |  with the activation Lambda (T10).
    arch                 "arm64" or "any"                      |
    requiresServices     censhare services the package needs  /
    replaces             {"<censhare resource key>": "<sha256 of censhare's asset file>"} for each censhare asset a
                         variant in the package replaces (variant.resource.replace.)

Errors refuse the package (exit 1); warnings are printed and pass (exit 0). No AWS, no network: the customer's or
partner's CI runs it, and publish-customization.sh runs it before it uploads anything.

  * owns: the same rules as publish-customization.sh's own_ok and the cell's entrypoint _own_ok (kept identical;
    tests/test-validate-customization.sh compares all three), every owned path present, and every exclude inside an
    owned path.
  * touchesMasterdata false with masterdata in the package is an error: masterdata cannot be rolled back by files
    (§5.3), so carrying it must be declared.
  * Credentials in the package's files: a private key or an AWS access key is an error, anything that looks like a
    password a warning. The package is copied to the cell as it is.
  * Resource keys the package defines outside its vendor's namespace are a warning (§6: "a resource-key prefix per
    vendor, never censhare:").
  * activation "refresh" with jars, .ts or .scss in the package is an error: those only take effect at a boot.
  * A jar with native libraries but none for linux-aarch64 is an error when the package declares arch, a warning when
    it does not: the cells run arm64.
  * A variant of a censhare asset (variant.resource.replace.) records the checksum of the asset it was made from in
    "replaces". With --product, a different checksum is an error: censhare changed the asset since, and the variant
    would silently drop censhare's change. A missing one is a warning naming the value to record.
  * With --product (and not --skip-refcheck), the masterdata reference check (scripts/lib/masterdata-refcheck.py),
    including the import order: a warning, as in publish-customization.sh.
  * --files-json writes {"<owned path>/<file>": "<sha256>"} for every file the package delivers (excludes applied),
    which publish-customization.sh records in manifest.json.

--credentials <dir> applies broader credential rules (CRED_FORMS, TOKEN below) to EVERY file under <dir>, and to the
files inside its jars and zips (not only owned paths; .git and symbolic links left out); any hit is an error. scripts/onboard-partner.sh runs
it on a snapshot of a partner's censhare-Custom before it goes into a repository (#461): app/config and app/services,
which a package never delivers, are where such a snapshot keeps its credentials.
"""
import hashlib, json, os, re, subprocess, sys, zipfile
import xml.etree.ElementTree as ET

V2_FIELDS = ('censhareVersion', 'hyperscalerContract', 'activation', 'touchesMasterdata', 'arch', 'requiresServices')
KNOWN = {'vendor', 'package', 'source', 'owns', 'excludes', 'replaces', 'settings', 'secrets', 'client', *V2_FIELDS}   # settings: #343,
# checked by docker/censhare-server/customer-settings.sh in publish-customization.sh and at boot; secrets: #450, below
NAME = re.compile(r'^[a-z0-9_-]+$')
VERSION_RANGE = re.compile(r'^(?:(?:>=|<=|>|<|=)?\d{4}\.\d+(?:\.\d+)*)(?: (?:>=|<=|>|<|=)?\d{4}\.\d+(?:\.\d+)*)*$')
CONTRACT = 1   # the delivery contract this edition implements; publish-customization.sh writes it into manifest.json

def own_ok(p):
    """publish-customization.sh's own_ok and entrypoint.sh's _own_ok, rule for rule."""
    if p == '' or p.startswith('/') or p.endswith('/') or '..' in p or '//' in p:
        return False
    if p in ('app/masterdata', 'app/assets'):
        return True
    if p in ('app', 'app/modules', 'app/web', 'app/web/src'):
        return False
    if p == 'app/services/scriptlet/lib' or p.startswith('app/services/scriptlet/lib/'):
        return True
    if p in ('app/services', 'app/config') or p.startswith(('app/services/', 'app/config/')):
        return False
    if p == 'app/modules/hyperscaler' or p.startswith('app/modules/hyperscaler/'):
        return False
    if p.startswith(('app/web/src/hyperscaler', 'app/web/src/acme', 'app/web/src/ng1', 'app/web/sass')) \
            or p == 'app/web/cs' or p.startswith('app/web/cs/'):
        return False
    return re.match(r'^app/[^/]+/.+$', p) is not None

PRIVATE_KEY = re.compile(rb'-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----')
AWS_KEY_ID = re.compile(rb'\b(?:AKIA|ASIA)[0-9A-Z]{16}\b')
# A password-like name with a LITERAL value: password="x", "password": "x", password = "x" (code),
# <password>x</password>. Not an expression (password = settings.get()), and not a placeholder: what a redacted
# snapshot holds (Migros: REDACTED).
PASSWORD = re.compile(rb'(?i)\b(?:pass(?:word|wd)?|secret)"?\s*[=:]\s*"([^"\n]{4,})"'
                      rb'|<(?:pass(?:word|wd)?|secret)>([^<\n]{4,})</')
PLACEHOLDER = re.compile(rb'(?i)^(?:redacted|todo|changeme|change_me|change-me|secret|password|x+|\*+'
                         rb'|<[^>]*>|.*[{}$].*)$')
# --credentials (a snapshot of a partner's whole censhare-Custom, #461) reads more forms than a package check: a name
# that CONTAINS a credential word (keyStorePassword, db.password, secretKey, bynder-access-token, password-digest), with
# its value as an attribute, a quoted or unquoted key=value / key: value, an element's text, or the value of a
# name="..."/key="..." entry; and tokens recognisable by their own shape.
CRED_NAME = rb'[A-Za-z0-9_.\-]*(?:pass(?:word|wd|phrase)?|secret|token|api[_-]?key|credential|private[_-]?key)[A-Za-z0-9_.\-]*'
CRED_FORMS = [re.compile(x, re.I | re.M) for x in (
    rb'(?<![A-Za-z0-9_.\-])(' + CRED_NAME + rb')["\']?\s*[=:]\s*"([^"\n]*)"',             # name="v", "name": "v"
    rb"(?<![A-Za-z0-9_.\-])(" + CRED_NAME + rb")[\"']?\s*[=:]\s*'([^'\n]*)'",            # name='v'
    rb'^[ \t-]*(' + CRED_NAME + rb')[ \t]*[=:][ \t]*([^\s"\'#<>][^\s#<>]*)',             # name=v, name: v (lines)
    rb'<(' + CRED_NAME + rb')(?:\s[^>]*)?>([^<\n]+)</',                                   # <name>v</name>
    rb'<[^>]*?\b(?:name|key|id)\s*=\s*["\'](' + CRED_NAME + rb')["\']'                  # <x name="name" value="v">
    rb'[^>]*?\b(?:value|select|content)\s*=\s*"([^"\n]*)"',
    rb'<[^>]*?\b(?:value|select|content)\s*=\s*"([^"\n]*)"[^>]*?\b(?:name|key|id)\s*=\s*["\']'  # value first
    rb'(' + CRED_NAME + rb')["\']',
    rb'<\w+\b[^>]*?\b(?:name|key)\s*=\s*["\'](' + CRED_NAME + rb')["\'][^>]*>([^<\n]+)</',  # <Set name="name">v</Set>
)]
TOKEN = re.compile(rb'\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,}|glpat-[A-Za-z0-9_-]{20,}'
                   rb'|xox[abprs]-[A-Za-z0-9-]{10,})|(?i:\bbearer\s+[A-Za-z0-9._~+/-]{20,})')
# Not a credential: a placeholder, a reference to one (${...}, $var), an expression, a switch or an empty value.
# Only a WHOLE value that is a reference is one (${db.password}, %{env}, $var, %VAR%, @token@): P@ssw0rd or Avon(2019)
# is not.
CRED_NOT = re.compile(rb'(?i)^(?:|redacted|todo|changeme|change_me|change-me|x+|\*+|true|false|yes|no|on|off|none|null'
                      rb'|<[^>]*>|[$%#]\{[^}]*\}|\$[\w.]+|%\w+%|@\w+@|.{1,3})$')
# A password in a URL's query or a JDBC/ODBC connection string: ...?user=app&password=v, ...;password=v
URL_PASSWORD = re.compile(rb'(?i)[?&;](pass(?:word|wd)?|pwd)=([^&;\s"\'<>]+)')

# A name that says where a credential is or how it behaves, not what it is: censhare.vault.token.path, secretFile.
CRED_ABOUT = re.compile(rb'(?i)(?:path|file|dir|url|uri|type|length|size|policy|enabled|mode|name|timeout|expiry)$')

def snapshot_credentials(data):
    """--credentials: what in a file's bytes looks like a credential, the broader rules above, as readable strings."""
    hits = credential_hits(data)
    names = set()
    for m in URL_PASSWORD.finditer(data):
        if not CRED_NOT.match(m.group(2)):
            names.add(m.group(1).decode('utf-8', 'replace') + ' in a URL')
    for i, form in enumerate(CRED_FORMS):
        for m in form.finditer(data):
            name, value = (m.group(2), m.group(1)) if i == 5 else (m.group(1), m.group(2))
            if not CRED_NOT.match(value.strip().strip(b"'").strip()) and not CRED_ABOUT.search(name):
                names.add(name.decode('utf-8', 'replace'))
    hits += [f'a credential-like value ({n})' for n in sorted(names)]
    if TOKEN.search(data):
        hits.append('a token')
    return hits

RK_DEF = re.compile(rb'<asset_feature\b[^>]*\bfeature="censhare:resource-key"[^>]*\bvalue_string="([^"]+)"')
# A variant that replaces a censhare asset: <parent_asset_rel key="variant.resource.replace."
# parent_asset_ref_resource_key="censhare:..."/> (attribute order varies).
VARIANT = re.compile(rb'<parent_asset_rel\b(?=[^>]*\bkey="variant\.resource\.replace\.")[^>]*'
                     rb'\bparent_asset_ref_resource_key="([^"]+)"')
SHA256 = re.compile(r'^[0-9a-f]{64}$')
# What only a boot takes (§2.2, §2.3): jars on the classpath, and frontend sources the image builds.
BOOT_ONLY = re.compile(r'\.(?:jar|ts|scss)$')
NATIVE = re.compile(r'\.(?:so(?:\.\d+)*|dll|dylib|jnilib)$')
# linux-aarch64 (JNA), linux_aarch_64 (netty), linux/arm64, aarch64-linux ...
ARM64_LINUX = re.compile(r'(?i)(?:linux[-_/.]?(?:aarch_?64|arm64)|(?:aarch_?64|arm64)[-_/.]?linux)')

def native_entries(path):
    """The native libraries inside a jar, or None when it cannot be read as a zip."""
    try:
        with zipfile.ZipFile(path) as z:
            return [n for n in z.namelist() if NATIVE.search(n)]
    except (zipfile.BadZipFile, OSError):
        return None

def product_assets(product):
    """resource key -> the censhare asset file that defines it, from the vendored product tree."""
    index = {}
    for dirpath, dirs, files in os.walk(product):
        dirs.sort()   # the first definition wins, so the walk is in a fixed order
        for f in sorted(files):
            if f.endswith('.asset.xml'):
                p = os.path.join(dirpath, f)
                for k in RK_DEF.findall(open(p, 'rb').read()):
                    index.setdefault(k.decode('utf-8', 'replace'), p)
    return index

def product_index(opts):
    """resource key -> (censhare file, sha256), from --product (the vendored tree) or --product-index (a file written by
    --write-product-index, for where the tree is not at hand: the partner intake Lambda, #345)."""
    if opts.get('--product-index'):
        data = json.load(open(opts['--product-index'], encoding='utf-8'))
        return {k: (v['file'], v['sha256']) for k, v in data.items()}
    if opts.get('--product'):
        return {k: (os.path.relpath(p, opts['--product']), file_sha256(p))
                for k, p in product_assets(opts['--product']).items()}
    return None

def file_sha256(path):
    """The asset file's checksum, line endings normalised so a checkout's autocrlf does not change it."""
    return hashlib.sha256(open(path, 'rb').read().replace(b'\r\n', b'\n')).hexdigest()

class Report:
    def __init__(self): self.errors, self.warnings = [], []
    def error(self, m): self.errors.append(m)
    def warn(self, m): self.warnings.append(m)

def check_fields(spec, r, strict_fields):
    for k in ('vendor', 'package', 'source'):
        if not isinstance(spec.get(k), str) or not spec.get(k):
            r.error(f'customization.json needs "{k}" (a string)')
    for k in ('vendor', 'package'):
        if isinstance(spec.get(k), str) and spec[k] and not NAME.match(spec[k]):
            r.error(f'"{k}" must be lower-case [a-z0-9_-], not "{spec[k]}"')
    for k in ('owns', 'excludes'):
        if k in spec and not (isinstance(spec[k], list) and all(isinstance(x, str) for x in spec[k])):
            r.error(f'"{k}" must be a list of paths')
    for k in sorted(k for k in set(spec) - KNOWN if not k.startswith('_')):
        r.warn(f'"{k}" is not a customization.json field; it is ignored')
    missing = [k for k in V2_FIELDS if k not in spec and k != 'requiresServices']
    if missing:
        (r.error if strict_fields else r.warn)(
            f'the package does not declare {", ".join(missing)} (docs/CUSTOMIZATION-DELIVERY.md §6)')
    v = spec.get('censhareVersion')
    if v is not None and not (isinstance(v, str) and VERSION_RANGE.match(v)):
        r.error(f'"censhareVersion" must be a range like ">=2026.2 <2027.1", not {json.dumps(v)}')
    v = spec.get('hyperscalerContract')
    if v is not None:
        if not (isinstance(v, int) and not isinstance(v, bool) and v >= 1):
            r.error(f'"hyperscalerContract" must be a whole number from 1 up, not {json.dumps(v)}')
        elif v > CONTRACT:
            r.error(f'"hyperscalerContract" is {v}, but this edition implements contract {CONTRACT}')
    for k, allowed in (('activation', ('refresh', 'boot')), ('arch', ('arm64', 'any'))):
        v = spec.get(k)
        if v is not None and v not in allowed:
            r.error(f'"{k}" must be one of {", ".join(allowed)}, not {json.dumps(v)}')
    v = spec.get('touchesMasterdata')
    if v is not None and not isinstance(v, bool):
        r.error(f'"touchesMasterdata" must be true or false, not {json.dumps(v)}')
    v = spec.get('replaces')
    if v is not None and not (isinstance(v, dict)
                              and all(isinstance(x, str) and SHA256.match(x) for x in v.values())):
        r.error('"replaces" must map each replaced censhare resource key to the sha256 of its asset file')
    v = spec.get('requiresServices')
    if v is not None and not (isinstance(v, list) and all(isinstance(x, str) and NAME.match(x) for x in v)):
        r.error('"requiresServices" must be a list of service names like ["renderer"]')

SECRETS_MAX = 20   # CUSTOMER_SECRETS_MAX in docker/censhare-server/customer-secrets.sh
SECRET_NAME = re.compile(r'^[a-z0-9][a-z0-9-]{0,62}$')
SECRET_FILE = re.compile(r'^app/[A-Za-z0-9._/ -]+\.xml$')
SECRET_ATTR = re.compile(r'^[A-Za-z_][A-Za-z0-9_.-]{0,63}$')

CLIENT_COLOURS = ('color20', 'color21', 'color22', 'color23', 'color20_dark', 'color21_dark', 'color22_dark', 'color23_dark')


# What the censhare server and the client build write into app/web themselves: never frontend source.
GENERATED_WEB = ('src/ng1/client/config/translations', 'src/generated')


def client_problems(client, repo, source_rel):
    """The rules of scripts/build-customer-client.sh (#495) for `client`: a customer's own web client, built from their
    repository laid out as classic's censhare-Custom ("Create custom branding(s)", Censhare WP): custom/<my-branding>.json
    with custom/assets/images/logo_<my-branding>.png and _dark.png, and censhare-Server/app/web (frontend source).
    Checked here, offline and at the partner intake, as the build checks them before Docker runs. Without `client` a
    branding in custom/ is found and checked as the build finds it (classic: a branding is on because it is there);
    a repository without one has nothing to check."""
    auto = client is None
    if auto:
        client = {}
    if not isinstance(client, dict):
        return ['client must be an object']
    extra = sorted(set(client) - {'branding'})
    if extra:
        return [f'client has {", ".join(extra)}: only branding (the rest follows classic\'s censhare-Custom layout)']
    if not isinstance(source_rel, str) or os.path.basename(source_rel.rstrip('/')) != 'censhare-Server':
        return [] if auto else ["client needs the package's source to be a censhare-Server folder (classic's censhare-Custom layout)"]
    root = os.path.dirname(source_rel.rstrip('/'))
    custom = os.path.join(root, 'custom')
    has_custom = os.path.isdir(os.path.join(repo, custom))
    # Frontend source: app/web without what censhare writes itself (build-customer-client.sh leaves those out).
    web = os.path.join(repo, source_rel, 'app', 'web')
    generated = [os.path.join(web, *g.split('/')) for g in GENERATED_WEB]
    has_web = os.path.isdir(web) and any(
        not any(os.path.join(d, f) == g or os.path.join(d, f).startswith(g + os.sep) for g in generated)
        for d, _, files in os.walk(web) for f in files)

    def brandings(path):
        try:
            cfg = json.load(open(path, encoding='utf-8'))
        except Exception:
            return None
        rel = cfg.get('release') if isinstance(cfg, dict) else None
        items = rel.get('brandings') if isinstance(rel, dict) else None
        return [b for b in (items or []) if isinstance(b, dict) and b.get('name') != 'censhare5']

    branding = client.get('branding')
    if branding is None and has_custom:
        found = sorted(f for f in os.listdir(os.path.join(repo, custom))
                       if f.endswith('.json') and brandings(os.path.join(repo, custom, f)))
        if len(found) > 1:
            return [f'{custom} holds several branding configurations ({" ".join(found)}): name one with client.branding']
        branding = found[0] if found else None
    if branding is None:
        return [] if auto or has_web else [f'client has nothing to build: no branding configuration in {custom} and no '
                                   f'frontend source in {source_rel}/app/web (censhare\'s own generated files do not count)']
    if not (isinstance(branding, str) and branding and '/' not in branding and not branding.startswith('.')):
        return [f'client.branding must be a file name in {custom}']
    if not has_custom or not os.path.isfile(os.path.join(repo, custom, branding)):
        return [f'branding {branding} is not in {custom}']
    own = brandings(os.path.join(repo, custom, branding))
    if own is None:
        return [f'branding {branding} is not JSON']
    if len(own) != 1:
        return [f'branding {branding} needs exactly one branding besides censhare5 (one cell, one look), found {len(own)}']
    b, out = own[0], []
    name = b.get('name')
    if not (isinstance(name, str) and re.match(r'^[A-Za-z0-9]+$', name)) or name == 'client':
        return ['the branding name must be letters and digits only, and not client']
    bad = [k for k in CLIENT_COLOURS if not (isinstance(b.get(k), str) and re.match(r'^#([0-9A-Fa-f]{3}){1,2}$', b[k]))]
    if bad:
        out.append(f'branding {name}: not a #rgb or #rrggbb colour: {" ".join(bad)}')
    for logo in (f'logo_{name}.png', f'logo_{name}_dark.png'):
        path = os.path.join(repo, custom, 'assets', 'images', logo)
        if not (os.path.isfile(path) and open(path, 'rb').read(8) == b'\x89PNG\r\n\x1a\n'):
            out.append(f'branding {name}: {custom}/assets/images/{logo} is missing or not a PNG')
    return out


def secrets_problems(secrets, owns):
    """The rules of secrets_check in docker/censhare-server/customer-secrets.sh (#450), which publish-customization.sh
    and the cell apply too (tests/test-customer-secrets.sh compares them): a package names its secrets, each into an XML
    file inside a path it owns; it never carries a value."""
    if secrets is None:
        return []
    if not isinstance(secrets, list):
        return ['secrets must be a list']
    if len(secrets) > SECRETS_MAX:
        return [f'secrets lists {len(secrets)} entries; at most {SECRETS_MAX}']
    out = []
    for i, e in enumerate(secrets):
        if not isinstance(e, dict):
            out.append(f'secrets[{i}] is not an object'); continue
        extra = sorted(set(e) - {'name', 'file', 'attribute'})
        name, f, attr = e.get('name'), e.get('file'), e.get('attribute')
        if extra:
            out.append(f'secrets[{i}] has {", ".join(extra)}: only name, file and attribute (a package never carries a value)')
        elif not isinstance(name, str) or not SECRET_NAME.match(name):
            out.append(f'secrets[{i}].name must be lower-case a-z, 0-9 and -, at most 63 characters')
        elif not isinstance(f, str) or not SECRET_FILE.match(f) or re.search(r'(^|/)\.\.(/|$)|//', f):
            out.append(f'secrets[{i}].file must be the path of an XML file under app/, without .. or //')
        elif not any(f.startswith(o + '/') for o in owns if isinstance(o, str)):
            out.append(f'secrets[{i}].file {f} is not inside a path the package owns')
        elif not isinstance(attr, str) or not SECRET_ATTR.match(attr):
            out.append(f'secrets[{i}].attribute must be an XML attribute name')
    objs = [e for e in secrets if isinstance(e, dict)]
    names = [e.get('name') for e in objs]
    out += [f'secrets name {n} appears more than once' for n in sorted({n for n in names if names.count(n) > 1}, key=str)]
    pairs = [(e.get('file'), e.get('attribute')) for e in objs]
    out += [f'secrets put two values into {f} config@{a}' for f, a in sorted({p for p in pairs if pairs.count(p) > 1}, key=str)]
    return out

def credential_hits(data):
    """What in a file's bytes looks like a credential: 'a private key', 'an AWS access key id', 'a password-like value'
    (a literal, not a placeholder such as REDACTED)."""
    hits = []
    if PRIVATE_KEY.search(data):
        hits.append('a private key')
    if AWS_KEY_ID.search(data):
        hits.append('an AWS access key id')
    if any(not PLACEHOLDER.match((m.group(1) or m.group(2)).strip()) for m in PASSWORD.finditer(data)):
        hits.append('a password-like value')
    return hits

def credentials_report(root):
    """--credentials: every file under root, each hit an error. Returns the exit code."""
    if not os.path.isdir(root):
        print(f'error: {root} is not a directory'); return 2
    hits, n = [], 0
    for dirpath, dirs, files in os.walk(root):
        dirs[:] = sorted(d for d in dirs if d != '.git')
        for f in sorted(files):
            path = os.path.join(dirpath, f)
            if os.path.islink(path):
                continue
            n += 1
            rel = os.path.relpath(path, root)
            for what in snapshot_credentials(open(path, 'rb').read()):
                hits.append(f'{rel}: {what}')
            # Inside a jar or zip too, one level deep: a properties file in a jar is still in the repository.
            if zipfile.is_zipfile(path):
                try:
                    with zipfile.ZipFile(path) as z:
                        for info in z.infolist():
                            if info.is_dir() or info.file_size > 20 * 1024 * 1024:
                                continue
                            for what in snapshot_credentials(z.read(info)):
                                hits.append(f'{rel}!{info.filename}: {what}')
                except (zipfile.BadZipFile, OSError, RuntimeError, NotImplementedError):
                    hits.append(f'{rel}: an archive that cannot be read (check it by hand)')
    for h in hits: print(f'credential: {h}')
    print(f'{root}: {"credentials found" if hits else "ok"} - {n} files, {len(hits)} finding(s)')
    return 1 if hits else 0

def package_files(source, owns, excludes):
    """(owned path, path relative to source) for every file the package delivers, excludes applied."""
    for own in owns:
        base = os.path.join(source, own)
        for dirpath, dirs, files in os.walk(base):
            rel_dir = os.path.relpath(dirpath, source)
            dirs[:] = sorted(d for d in dirs if not any(
                os.path.join(rel_dir, d) == ex or os.path.join(rel_dir, d).startswith(ex + '/') for ex in excludes))
            for f in sorted(files):
                yield own, os.path.normpath(os.path.join(rel_dir, f))

def main(argv):
    args = [a for a in argv if not a.startswith('--')]
    opts = {a: argv[i + 1] if i + 1 < len(argv) else None
            for i, a in enumerate(argv)
            if a in ('--product', '--files-json', '--product-index', '--write-product-index', '--credentials')}
    args = [a for a in args if a not in opts.values()]
    if '--credentials' in opts:
        if not opts['--credentials'] or args:
            print('--credentials takes one directory and nothing else', file=sys.stderr); return 2
        return credentials_report(opts['--credentials'])
    if opts.get('--write-product-index'):
        if not opts.get('--product'):
            print('--write-product-index needs --product <censhare-Server dir>', file=sys.stderr); return 2
        index = product_index({'--product': opts['--product']})
        with open(opts['--write-product-index'], 'w', encoding='utf-8') as fh:
            json.dump({k: {'file': f, 'sha256': h} for k, (f, h) in sorted(index.items())}, fh, indent=0)
        print(f'product index: {len(index)} resource keys -> {opts["--write-product-index"]}'); return 0
    if len(args) != 1:
        print(__doc__.strip(), file=sys.stderr); return 2
    repo, r = args[0], Report()
    spec_path = os.path.join(repo, 'customization.json')
    try:
        spec = json.load(open(spec_path, encoding='utf-8'))
    except FileNotFoundError:
        print(f'error: {repo} has no customization.json; nothing declares what to publish'); return 1
    except json.JSONDecodeError as e:
        print(f'error: customization.json is not JSON: {e}'); return 1
    if not isinstance(spec, dict):
        print('error: customization.json must be an object'); return 1

    check_fields(spec, r, '--strict-fields' in argv)
    owns = [o for o in spec.get('owns') or [] if isinstance(o, str)]
    excludes = [e for e in spec.get('excludes') or [] if isinstance(e, str)]
    source = os.path.join(repo, spec['source']) if isinstance(spec.get('source'), str) and spec.get('source') else None
    files = []
    if source and not os.path.isdir(os.path.join(source, 'app')):
        r.error(f'source {spec["source"]} has no app/ directory')
    elif source:
        if not owns:
            r.error('customization.json owns nothing')
        bad = [o for o in owns if not own_ok(o)]
        if bad:
            r.error(f'claims paths a package may not own: {", ".join(bad)}')
        missing = [o for o in owns if own_ok(o) and not os.path.isdir(os.path.join(source, o))]
        if missing:
            r.error(f'owned paths missing under {spec["source"]}: {", ".join(missing)}')
        owns = [o for o in owns if own_ok(o) and o not in missing]
        for ex in excludes:
            if not any(ex.startswith(o + '/') for o in owns):
                r.error(f'exclude {ex} is not inside an owned path, so it excludes nothing')
            elif not os.path.exists(os.path.join(source, ex)):
                r.warn(f'exclude {ex} does not exist under {spec["source"]}')
        files = list(package_files(source, owns, excludes))

        has_md = any(rel.startswith('app/masterdata/') for _, rel in files)
        if spec.get('touchesMasterdata') is False and has_md:
            r.error('"touchesMasterdata" is false, but the package carries app/masterdata')
        elif spec.get('touchesMasterdata') is True and not has_md:
            r.warn('"touchesMasterdata" is true, but the package carries no masterdata')

        # Secrets (#450): the rules, then what only the package itself can show: each named file is delivered (excludes
        # applied) and has a <config> under its root, where the cell sets the attribute at boot.
        problems = secrets_problems(spec.get('secrets'), owns)
        for m in problems:
            r.error(m)
        for m in client_problems(spec.get('client'), repo, spec.get('source')):
            r.error(m)
        if not problems and spec.get('secrets'):
            delivered = {rel for _, rel in files}
            for e in spec['secrets']:
                if e['file'] not in delivered:
                    r.error(f'secret {e["name"]}: {e["file"]} is not a file the package delivers')
                    continue
                try:
                    root = ET.parse(os.path.join(source, e['file'])).getroot()
                except Exception as x:
                    r.error(f'secret {e["name"]}: {e["file"]} is not well-formed XML ({x})'); continue
                if root.find('config') is None:
                    r.error(f'secret {e["name"]}: {e["file"]} has no <config> under its root <{root.tag}>, where the '
                            'cell sets the attribute')

        vendor = spec.get('vendor') if isinstance(spec.get('vendor'), str) else ''
        foreign, variants = {}, {}
        for _, rel in files:
            data = open(os.path.join(source, rel), 'rb').read()
            hits = credential_hits(data)
            for what in ('a private key', 'an AWS access key id'):
                if what in hits:
                    r.error(f'{rel} contains {what}')
            if 'a password-like value' in hits:
                r.warn(f'{rel} may contain a password (check it is not a real credential)')
            if rel.endswith('.xml'):
                for k in VARIANT.findall(data):
                    variants.setdefault(k.decode('utf-8', 'replace'), rel)
                for k in RK_DEF.findall(data):
                    k = k.decode('utf-8', 'replace')
                    if vendor and not k.startswith(vendor + ':'):
                        foreign.setdefault(k.split(':', 1)[0] if ':' in k else '(none)', []).append(rel)
        if foreign:
            counts = ', '.join(f'{ns} {len(w)}' for ns, w in sorted(foreign.items(), key=lambda x: (-len(x[1]), x[0])))
            first = sorted(foreign.items(), key=lambda x: -len(x[1]))[0][1][0]
            r.warn(f'{sum(len(w) for w in foreign.values())} resource key(s) outside "{vendor}:", by namespace: '
                   f'{counts} (e.g. {first})')

        # activation: a package that says `refresh` must not carry what only a boot takes, or a partner reports a
        # change as live that is not (§3.3).
        boot_only = [rel for _, rel in files if BOOT_ONLY.search(rel)]
        if spec.get('activation') == 'refresh' and boot_only:
            r.error(f'"activation" is refresh, but {len(boot_only)} file(s) only take effect at a boot '
                    f'(jars, .ts, .scss; e.g. {boot_only[0]}): declare "activation": "boot"')
        # arch: cells run arm64 (Graviton). A jar's native library must have a linux-aarch64 build, or the class that
        # loads it fails on the cell (hunspell, §6).
        for _, rel in files:
            if not rel.endswith('.jar'):
                continue
            libs = native_entries(os.path.join(source, rel))
            if libs is None:
                r.warn(f'{rel} is not a readable jar')
            elif libs and not any(ARM64_LINUX.search(n) for n in libs):
                (r.warn if spec.get('arch') is None else r.error)(
                    f'{rel} has native libraries but none for linux-aarch64 (e.g. {libs[0]}); the cells run arm64')

        # A variant copies a censhare asset and changes it, so a censhare upgrade that changes the original is silently
        # lost on this cell unless someone re-diffs (ASK-WIDGET.md §1 for our own dashboard). The package records the
        # checksum of each original it replaced; with --product, a different checksum means censhare changed it.
        replaces = spec.get('replaces') if isinstance(spec.get('replaces'), dict) else {}
        index = product_index(opts) if variants else None
        for key, rel in sorted(variants.items()):
            recorded = replaces.get(key)
            if index is not None:
                if key not in index:
                    r.warn(f'{rel} replaces {key}, which this censhare version does not ship')
                    continue
                where, now = index[key]
                if recorded is None:
                    r.warn(f'{rel} replaces {key} without recording its checksum: add "replaces": '
                           f'{{"{key}": "{now}"}} ({where})')
                elif recorded != now:
                    r.error(f'censhare changed {key} ({where}) since {rel} was made from it: compare the two, carry '
                            f'censhare\'s changes into the variant, then record "{key}": "{now}"')
            elif recorded is None:
                r.warn(f'{rel} replaces {key} without recording its checksum '
                       f'("replaces"; run with --product or --product-index to get it)')
        for key in sorted(set(replaces) - set(variants)):
            r.warn(f'"replaces" names {key}, but no asset in the package replaces it')

        if opts.get('--product') and '--skip-refcheck' not in argv:
            chk = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'lib', 'masterdata-refcheck.py')
            out = subprocess.run([sys.executable, chk, os.path.join(source, 'app'), opts['--product']],
                                 capture_output=True, text=True)
            if 'refcheck: OK' not in out.stdout:
                r.warn('masterdata reference check:\n' + '\n'.join('    ' + l for l in out.stdout.rstrip().split('\n')))

        if opts.get('--files-json'):
            digest = {rel: hashlib.sha256(open(os.path.join(source, rel), 'rb').read()).hexdigest()
                      for _, rel in files}
            with open(opts['--files-json'], 'w', encoding='utf-8') as fh:
                json.dump(digest, fh, indent=0, sort_keys=True)

    for m in r.warnings: print(f'warning: {m}')
    for m in r.errors: print(f'error: {m}')
    name = f'{spec.get("vendor")}/{spec.get("package")}'
    print(f'{name}: {"refused" if r.errors else "ok"} - {len(files)} files, '
          f'{len(r.errors)} error(s), {len(r.warnings)} warning(s)')
    return 1 if r.errors else 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

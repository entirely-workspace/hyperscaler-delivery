"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.MANIFEST_IN_FOLDER = exports.ManifestError = exports.DEFAULT_FUNCTION_RATE = exports.MAX_FUNCTION_RATE = exports.MAX_CELL_CONCURRENCY = exports.MAX_FUNCTION_CONCURRENCY = exports.MAX_SCHEDULES = exports.MAX_DETAIL_TYPES = exports.PACKAGE_NAME_RE = exports.HOOK_ROUTE_PREFIX = exports.MANIFEST_FILE = void 0;
exports.isRegistryImage = isRegistryImage;
exports.webhookAuthOf = webhookAuthOf;
exports.parseWebhookTrigger = parseWebhookTrigger;
exports.validateManifest = validateManifest;
exports.manifestFile = manifestFile;
exports.readManifest = readManifest;
const fs = require("fs");
const path = require("path");
const catalogue_filter_1 = require("./catalogue-filter");
exports.MANIFEST_FILE = 'functions.json';
const NAME_RE = /^[a-z][a-z0-9-]{1,39}$/;
const MODULE_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const BEAN_RE = /^[A-Za-z_$][A-Za-z0-9_$]{0,127}$/;
const CLASS_RE = /^([a-zA-Z_$][a-zA-Z0-9_$]*\.)+[A-Z][a-zA-Z0-9_$]*$/;
const PATH_RE = /^\/solution\/functions\/[a-z0-9][a-z0-9-]{0,62}$/;
exports.HOOK_ROUTE_PREFIX = '/solution/hooks/';
const HOOK_PATH_RE = /^\/solution\/hooks\/[a-z0-9][a-z0-9-]{0,62}$/;
const HOOK_AUTH = ['hmac', 'jwt'];
const ISSUER_RE = /^https:\/\/[a-z0-9.-]+(?::\d{1,5})?(?:\/[A-Za-z0-9._~%!$&'()*+,;=:@-]+)*\/?$/;
const CLAIM_RE = /^[\x21-\x7e]{1,256}$/;
const ENV_KEY_RE = /^[A-Z][A-Z0-9_]{0,63}$/;
const BUILD_ROOT_RE = /^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$/;
const IMAGE_RE = /^[a-z0-9][a-z0-9._-]{0,63}$/;
const IMAGE_REF_RE = /^(?:[a-z0-9-]+\.)+[a-z0-9-]+(?::[0-9]{1,5})?(?:\/[a-z0-9]+(?:[._-][a-z0-9]+)*)+@sha256:[0-9a-f]{64}$/;
const IMAGE_HINT = 'must be the image name the CI built (lower case letters, digits, ".", "_", "-"), with no registry or tag, '
    + 'or an image in your registry by digest (<registry>/<name>@sha256:<64 hex>)';
function isRegistryImage(image) {
    return image.includes('/');
}
function imageOf(value, where) {
    if (typeof value !== 'string')
        fail(where, `${IMAGE_HINT}, got ${JSON.stringify(value)}`);
    if (!isRegistryImage(value))
        return str(value, where, IMAGE_RE, IMAGE_HINT);
    const why = (reason) => fail(where, `${IMAGE_HINT}, got ${JSON.stringify(value)}: ${reason}`);
    if (/[A-Z]/.test(value))
        why('a registry reference is lower case');
    const [name, digest] = value.split('@');
    if (digest !== undefined && /:[^/]*$/.test(name))
        why('give a digest, not a tag and a digest');
    if (digest === undefined || !/^sha256:[0-9a-f]{64}$/.test(digest))
        why('a registry reference needs a digest (@sha256:<64 hex>): a tag can move, a digest cannot');
    const host = name.split('/')[0];
    if (!host.includes('.') && !host.includes(':'))
        why(`name the registry, e.g. docker.io/${name}@${digest}`);
    if (!IMAGE_REF_RE.test(value))
        why('not a registry reference');
    return value;
}
exports.PACKAGE_NAME_RE = /^[a-z0-9][a-z0-9_-]*$/;
const RESERVED_ENV = new Set(['MAIN_CLASS', 'SPRING_CLOUD_FUNCTION_DEFINITION', 'CENSHARE_BASE_URL', 'JAVA_TOOL_OPTIONS',
    'JAVA_HOME', 'LANG', 'PATH', 'TZ']);
const RESERVED_ENV_PREFIXES = ['AWS_', 'LAMBDA_', 'CENSHARE_FUNCTION_', '_'];
const PLANNED_TRIGGERS = new Set(['file']);
const TRIGGER_TYPES = ['http', 'event', 'schedule', 'webhook'];
exports.MAX_DETAIL_TYPES = 10;
exports.MAX_SCHEDULES = 5;
const CRON_FIELD = /^[0-9A-Za-z*?,/#-]+$/;
const CRON_SUFFIXES = ['minutes', 'hours', 'day-of-month', 'month', 'day-of-week', 'year'];
function canonicalTimeZone(zone) {
    if (!/^[A-Za-z][A-Za-z0-9_+-]*(\/[A-Za-z0-9_+-]+)*$/.test(zone))
        return undefined;
    try {
        return new Intl.DateTimeFormat('en', { timeZone: zone }).resolvedOptions().timeZone;
    }
    catch {
        return undefined;
    }
}
const MAX_ENV_BYTES = 2048;
exports.MAX_FUNCTION_CONCURRENCY = 20;
exports.MAX_CELL_CONCURRENCY = 50;
exports.MAX_FUNCTION_RATE = 50;
exports.DEFAULT_FUNCTION_RATE = 10;
class ManifestError extends Error {
}
exports.ManifestError = ManifestError;
function fail(where, message) {
    throw new ManifestError(`${exports.MANIFEST_FILE}: ${where}: ${message}`);
}
function str(value, where, re, hint) {
    if (typeof value !== 'string' || !re.test(value))
        fail(where, `${hint}, got ${JSON.stringify(value)}`);
    return value;
}
function int(value, where, min, max, fallback) {
    if (value === undefined && fallback !== undefined)
        return fallback;
    if (typeof value !== 'number' || !Number.isInteger(value) || value < min || value > max) {
        fail(where, `must be a whole number from ${min} to ${max}, got ${JSON.stringify(value)}`);
    }
    return value;
}
function onlyKeys(obj, allowed, where) {
    for (const k of Object.keys(obj)) {
        if (!allowed.includes(k))
            fail(where, `unknown field "${k}" (allowed: ${allowed.join(', ')})`);
    }
}
function isObject(v) {
    return typeof v === 'object' && v !== null && !Array.isArray(v);
}
function eventTrigger(t, where) {
    onlyKeys(t, ['type', 'detailTypes', 'filter', 'includeOwnWrites'], where);
    const types = t.detailTypes;
    if (!Array.isArray(types) || types.length === 0 || types.length > exports.MAX_DETAIL_TYPES) {
        fail(`${where}.detailTypes`, `must be a list of 1 to ${exports.MAX_DETAIL_TYPES} of censhare's events, e.g. ["asset.changed"]`);
    }
    for (const d of types) {
        if (!(0, catalogue_filter_1.isCatalogueEvent)(d)) {
            fail(`${where}.detailTypes`, `must be ${catalogue_filter_1.CATALOGUE_EVENTS.join(', ')} or custom.<name>, got ${JSON.stringify(d)} (docs/EVENTS.md)`);
        }
    }
    if (new Set(types).size !== types.length)
        fail(`${where}.detailTypes`, 'names a detail type twice');
    const filter = t.filter === undefined ? undefined
        : (0, catalogue_filter_1.checkCatalogueFilter)(t.filter, types, `${where}.filter`, (at, message) => fail(at, message));
    if (t.includeOwnWrites !== undefined && typeof t.includeOwnWrites !== 'boolean')
        fail(`${where}.includeOwnWrites`, 'must be true or false');
    const unnamed = types.filter((d) => catalogue_filter_1.UNNAMED_WRITER_EVENTS.includes(d));
    if (unnamed.length && t.includeOwnWrites !== true) {
        fail(`${where}.detailTypes`, `${unnamed.join(', ')} never ${unnamed.length > 1 ? 'say' : 'says'} who made the change, so the `
            + 'function\'s own writes cannot be left out and could start it again; make sure it does not cause '
            + `${unnamed.join(' or ')} itself, then set "includeOwnWrites": true to say so`);
    }
    return { type: 'event', detailTypes: [...types], ...(filter ? { filter } : {}), includeOwnWrites: t.includeOwnWrites === true };
}
function scheduleTrigger(t, where) {
    onlyKeys(t, ['type', 'cron', 'timezone'], where);
    const hint = 'must be a cron of six fields, minutes hours day-of-month month day-of-week year, e.g. "0 2 * * ? *" (every night at 2)';
    if (typeof t.cron !== 'string' || t.cron.length > 256)
        fail(`${where}.cron`, `${hint}, got ${JSON.stringify(t.cron)}`);
    const fields = t.cron.trim().split(/\s+/);
    if (fields.length !== 6)
        fail(`${where}.cron`, `${hint}; got ${fields.length} field${fields.length === 1 ? '' : 's'} in "${t.cron}"`);
    fields.forEach((f, i) => { if (!CRON_FIELD.test(f))
        fail(`${where}.cron`, `${CRON_SUFFIXES[i]} "${f}" is not a cron field`); });
    if ((fields[2] === '?') === (fields[4] === '?')) {
        fail(`${where}.cron`, `one of day-of-month and day-of-week must be "?", the other not, got "${t.cron}" (e.g. "0 2 * * ? *")`);
    }
    const zone = typeof t.timezone === 'string' ? canonicalTimeZone(t.timezone) : undefined;
    if (!zone)
        fail(`${where}.timezone`, `must be an IANA time zone such as "Europe/Berlin" or "UTC", got ${JSON.stringify(t.timezone)}`);
    if (zone !== t.timezone && zone.toLowerCase() === t.timezone.toLowerCase()) {
        fail(`${where}.timezone`, `write it as the IANA database does, "${zone}", not ${JSON.stringify(t.timezone)}`);
    }
    return { type: 'schedule', cron: fields.join(' '), timezone: t.timezone };
}
function webhookAuthOf(t) {
    return t.auth === 'jwt' ? { type: 'jwt', issuer: t.issuer, audience: t.audience, ...(t.scope ? { scope: t.scope } : {}) } : { type: 'hmac' };
}
function webhookTrigger(t, where) {
    return parseWebhookTrigger(t, where, fail);
}
function parseWebhookTrigger(t, where, fail) {
    const str = (value, at, re, hint) => {
        if (typeof value !== 'string' || !re.test(value))
            fail(at, `${hint}, got ${JSON.stringify(value)}`);
        return value;
    };
    const onlyKeys = (allowed) => {
        for (const k of Object.keys(t))
            if (!allowed.includes(k))
                fail(where, `unknown field "${k}" (allowed: ${allowed.join(', ')})`);
    };
    const p = str(t.path, `${where}.path`, HOOK_PATH_RE, 'must be /solution/hooks/<lower-case name>');
    if (t.auth !== undefined && (typeof t.auth !== 'string' || !HOOK_AUTH.includes(t.auth))) {
        fail(`${where}.auth`, `must be ${HOOK_AUTH.map((a) => `"${a}"`).join(' or ')}, got ${JSON.stringify(t.auth)}`);
    }
    if (t.auth !== 'jwt') {
        onlyKeys(['type', 'path', 'auth']);
        return { type: 'webhook', path: p, auth: 'hmac' };
    }
    onlyKeys(['type', 'path', 'auth', 'issuer', 'audience', 'scope']);
    if (typeof t.issuer !== 'string' || t.issuer.length > 256 || !ISSUER_RE.test(t.issuer)) {
        fail(`${where}.issuer`, `must be the partner's issuer as its tokens name it, an https URL without query or fragment, e.g. "https://login.example.com", got ${JSON.stringify(t.issuer)}`);
    }
    const audience = str(t.audience, `${where}.audience`, CLAIM_RE, 'must be what the partner\'s tokens are for (their "aud"), e.g. "censhare-hooks"');
    const scope = t.scope === undefined ? undefined : str(t.scope, `${where}.scope`, CLAIM_RE, 'must be one scope the token must carry, e.g. "censhare/webhook"');
    return { type: 'webhook', path: p, auth: 'jwt', issuer: t.issuer, audience, ...(scope ? { scope } : {}) };
}
function validateManifest(raw) {
    if (!isObject(raw))
        fail('root', 'must be a JSON object');
    onlyKeys(raw, ['$schema', 'version', 'vendor', 'package', 'build', 'functions'], 'root');
    if (raw.version !== 1)
        fail('version', `must be 1, got ${JSON.stringify(raw.version)}`);
    for (const key of ['vendor', 'package']) {
        const v = raw[key];
        if (v !== undefined && (typeof v !== 'string' || !exports.PACKAGE_NAME_RE.test(v))) {
            fail(key, `must be lower-case [a-z0-9_-], starting with a letter or digit, not ${JSON.stringify(v)} (the name censhare gave at onboarding)`);
        }
    }
    const build = raw.build === undefined ? {} : raw.build;
    if (!isObject(build))
        fail('build', 'must be an object');
    onlyKeys(build, ['root'], 'build');
    const buildRoot = build.root === undefined ? 'functions'
        : str(build.root, 'build.root', BUILD_ROOT_RE, 'must be a relative directory');
    if (buildRoot.split('/').includes('..'))
        fail('build.root', 'must stay inside the repository');
    if (!Array.isArray(raw.functions) || raw.functions.length === 0)
        fail('functions', 'must list at least one function');
    if (raw.functions.length > 50)
        fail('functions', 'at most 50 functions per repository');
    const names = new Set();
    const paths = new Set();
    const functions = raw.functions.map((f, i) => {
        const at = `functions[${i}]`;
        if (!isObject(f))
            fail(at, 'must be an object');
        onlyKeys(f, ['name', 'module', 'bean', 'mainClass', 'description', 'memoryMb', 'timeoutSeconds', 'concurrency',
            'rateLimit', 'environment', 'triggers', 'image', 'command'], at);
        const name = str(f.name, `${at}.name`, NAME_RE, 'must be 2-40 lower-case letters, digits or dashes, starting with a letter');
        const where = `function "${name}"`;
        if (names.has(name))
            fail(where, 'the name is used twice');
        names.add(name);
        const description = f.description === undefined ? `censhare function ${name}` : f.description;
        if (typeof description !== 'string' || description.length > 256)
            fail(`${where}.description`, 'must be text of at most 256 characters');
        const environment = {};
        if (f.environment !== undefined) {
            if (!isObject(f.environment))
                fail(`${where}.environment`, 'must be an object of NAME: "value"');
            for (const [k, v] of Object.entries(f.environment)) {
                if (!ENV_KEY_RE.test(k))
                    fail(`${where}.environment`, `"${k}" must be upper case letters, digits and _`);
                if (RESERVED_ENV.has(k) || RESERVED_ENV_PREFIXES.some((p) => k.startsWith(p))) {
                    fail(`${where}.environment`, `"${k}" is set by the platform and cannot be overridden`);
                }
                if (typeof v !== 'string')
                    fail(`${where}.environment.${k}`, 'must be a string');
                environment[k] = v;
            }
            if (Buffer.byteLength(JSON.stringify(environment)) > MAX_ENV_BYTES) {
                fail(`${where}.environment`, `is larger than ${MAX_ENV_BYTES} bytes; keep large configuration out of environment variables`);
            }
        }
        const rawTriggers = f.triggers === undefined ? [] : f.triggers;
        if (!Array.isArray(rawTriggers))
            fail(`${where}.triggers`, 'must be a list of triggers, or left out for a function only workflows call');
        const triggers = rawTriggers.map((t, j) => {
            const tat = `${where}.triggers[${j}]`;
            if (!isObject(t))
                fail(tat, 'must be an object');
            if (typeof t.type !== 'string' || !TRIGGER_TYPES.includes(t.type)) {
                if (typeof t.type === 'string' && PLANNED_TRIGGERS.has(t.type)) {
                    fail(tat, `trigger type "${t.type}" is planned but not available yet; ${TRIGGER_TYPES.map((x) => `"${x}"`).join(', ')} are (docs/FUNCTIONS-ON-LAMBDA.md)`);
                }
                fail(tat, `type must be one of ${TRIGGER_TYPES.map((x) => `"${x}"`).join(', ')}, got ${JSON.stringify(t.type)}`);
            }
            if (t.type === 'event')
                return eventTrigger(t, tat);
            if (t.type === 'schedule')
                return scheduleTrigger(t, tat);
            if (t.type === 'webhook') {
                const hook = webhookTrigger(t, tat);
                if (paths.has(hook.path))
                    fail(tat, `path ${hook.path} is used by another function`);
                paths.add(hook.path);
                return hook;
            }
            onlyKeys(t, ['type', 'path'], tat);
            const p = str(t.path, `${tat}.path`, PATH_RE, 'must be /solution/functions/<lower-case name>');
            if (paths.has(p))
                fail(tat, `path ${p} is used by another function`);
            paths.add(p);
            return { type: 'http', path: p };
        });
        if (triggers.filter((t) => t.type === 'event').length > 1) {
            fail(`${where}.triggers`, 'has more than one "event" trigger: list the detail types in one ("detailTypes": [...]), with one filter');
        }
        if (triggers.filter((t) => t.type === 'webhook').length > 1) {
            fail(`${where}.triggers`, 'has more than one "webhook" trigger: a function has one secret, so one webhook');
        }
        if (triggers.filter((t) => t.type === 'schedule').length > exports.MAX_SCHEDULES) {
            fail(`${where}.triggers`, `has more than ${exports.MAX_SCHEDULES} "schedule" triggers`);
        }
        if (name.endsWith('-dlq') && triggers.some((t) => t.type === 'event' || t.type === 'schedule')) {
            fail(`${where}.name`, 'a function with an event or schedule trigger may not end in "-dlq": its queues are named after it');
        }
        const triggered = triggers.some((t) => t.type === 'event' || t.type === 'schedule');
        if (triggered && typeof f.concurrency === 'number' && f.concurrency < 2) {
            fail(`${where}.concurrency`, 'must be at least 2 for a function with an event or schedule trigger: Lambda reads its queue at least 2 at a time');
        }
        const image = f.image === undefined ? undefined : imageOf(f.image, `${where}.image`);
        let command;
        if (f.command !== undefined) {
            if (image === undefined)
                fail(`${where}.command`, 'is for a function with an image');
            if (!Array.isArray(f.command) || !f.command.length || f.command.length > 10
                || f.command.some((c) => typeof c !== 'string' || !c || c.length > 256)) {
                fail(`${where}.command`, 'must be a list of 1 to 10 strings, e.g. ["app.handler"]');
            }
            command = f.command;
        }
        if (image !== undefined && f.module !== undefined)
            fail(`${where}.module`, 'is for a function the cell builds; one with an image has no module');
        if (image !== undefined && (f.bean === undefined) !== (f.mainClass === undefined)) {
            fail(where, 'bean and mainClass go together (the censhare Java runtime), or neither');
        }
        const java = image === undefined || f.bean !== undefined;
        return {
            name,
            ...(image !== undefined ? { image } : {}),
            ...(command !== undefined ? { command } : {}),
            ...(image === undefined ? { module: str(f.module, `${where}.module`, MODULE_RE, 'must be a Maven module directory name') } : {}),
            ...(java ? {
                bean: str(f.bean, `${where}.bean`, BEAN_RE, 'must be a Spring bean name'),
                mainClass: str(f.mainClass, `${where}.mainClass`, CLASS_RE, 'must be a fully qualified class name'),
            } : {}),
            description,
            memoryMb: int(f.memoryMb, `${where}.memoryMb`, 512, 10240, 1024),
            timeoutSeconds: int(f.timeoutSeconds, `${where}.timeoutSeconds`, 3, 29, 29),
            concurrency: f.concurrency === undefined
                ? fail(`${where}.concurrency`, `is required: the most requests the function may run at once, 1 to ${exports.MAX_FUNCTION_CONCURRENCY}`)
                : int(f.concurrency, `${where}.concurrency`, 1, exports.MAX_FUNCTION_CONCURRENCY),
            rateLimit: int(f.rateLimit, `${where}.rateLimit`, 1, exports.MAX_FUNCTION_RATE, exports.DEFAULT_FUNCTION_RATE),
            environment,
            triggers,
        };
    });
    const total = functions.reduce((sum, f) => sum + f.concurrency, 0);
    if (total > exports.MAX_CELL_CONCURRENCY) {
        fail('functions', `reserve ${total} concurrent executions together; a cell may reserve at most ${exports.MAX_CELL_CONCURRENCY}`);
    }
    return { version: 1, ...(raw.vendor !== undefined ? { vendor: raw.vendor } : {}),
        ...(raw.package !== undefined ? { package: raw.package } : {}), buildRoot, functions };
}
exports.MANIFEST_IN_FOLDER = `functions/${exports.MANIFEST_FILE}`;
function manifestFile(repo) {
    const found = [exports.MANIFEST_IN_FOLDER, exports.MANIFEST_FILE].filter((f) => fs.existsSync(path.join(repo, f)));
    if (found.length > 1) {
        throw new ManifestError(`${repo} has both ${exports.MANIFEST_IN_FOLDER} and ${exports.MANIFEST_FILE}: keep ${exports.MANIFEST_IN_FOLDER} `
            + 'and delete the one at the root');
    }
    return found[0];
}
function readManifest(repo) {
    const found = manifestFile(repo);
    if (!found)
        throw new ManifestError(`${repo} has no ${exports.MANIFEST_IN_FOLDER} (or, until it is retired, ${exports.MANIFEST_FILE} at its root)`);
    const file = path.join(repo, found);
    let raw;
    try {
        raw = JSON.parse(fs.readFileSync(file, 'utf8'));
    }
    catch (e) {
        throw new ManifestError(`${file} is not valid JSON: ${e.message}`);
    }
    return validateManifest(raw);
}

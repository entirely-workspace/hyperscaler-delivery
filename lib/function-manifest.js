"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.ManifestError = exports.DEFAULT_FUNCTION_RATE = exports.MAX_FUNCTION_RATE = exports.MAX_CELL_CONCURRENCY = exports.MAX_FUNCTION_CONCURRENCY = exports.MANIFEST_FILE = void 0;
exports.validateManifest = validateManifest;
exports.readManifest = readManifest;
const fs = require("fs");
const path = require("path");
exports.MANIFEST_FILE = 'functions.json';
const NAME_RE = /^[a-z][a-z0-9-]{1,39}$/;
const MODULE_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const BEAN_RE = /^[A-Za-z_$][A-Za-z0-9_$]{0,127}$/;
const CLASS_RE = /^([a-zA-Z_$][a-zA-Z0-9_$]*\.)+[A-Z][a-zA-Z0-9_$]*$/;
const PATH_RE = /^\/solution\/functions\/[a-z0-9][a-z0-9-]{0,62}$/;
const ENV_KEY_RE = /^[A-Z][A-Z0-9_]{0,63}$/;
const BUILD_ROOT_RE = /^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$/;
const RESERVED_ENV = new Set(['MAIN_CLASS', 'SPRING_CLOUD_FUNCTION_DEFINITION', 'CENSHARE_BASE_URL', 'JAVA_TOOL_OPTIONS',
    'JAVA_HOME', 'LANG', 'PATH', 'TZ']);
const RESERVED_ENV_PREFIXES = ['AWS_', 'LAMBDA_', 'CENSHARE_FUNCTION_', '_'];
const PLANNED_TRIGGERS = new Set(['event', 'schedule', 'webhook', 'file']);
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
function validateManifest(raw) {
    if (!isObject(raw))
        fail('root', 'must be a JSON object');
    onlyKeys(raw, ['$schema', 'version', 'build', 'functions'], 'root');
    if (raw.version !== 1)
        fail('version', `must be 1, got ${JSON.stringify(raw.version)}`);
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
            'rateLimit', 'environment', 'triggers'], at);
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
        if (!Array.isArray(f.triggers) || f.triggers.length === 0)
            fail(`${where}.triggers`, 'must list at least one trigger');
        const triggers = f.triggers.map((t, j) => {
            const tat = `${where}.triggers[${j}]`;
            if (!isObject(t))
                fail(tat, 'must be an object');
            if (t.type !== 'http') {
                if (typeof t.type === 'string' && PLANNED_TRIGGERS.has(t.type)) {
                    fail(tat, `trigger type "${t.type}" is planned but not available yet; only "http" is (docs/FUNCTIONS-ON-LAMBDA.md)`);
                }
                fail(tat, `type must be "http", got ${JSON.stringify(t.type)}`);
            }
            onlyKeys(t, ['type', 'path'], tat);
            const p = str(t.path, `${tat}.path`, PATH_RE, 'must be /solution/functions/<lower-case name>');
            if (paths.has(p))
                fail(tat, `path ${p} is used by another function`);
            paths.add(p);
            return { type: 'http', path: p };
        });
        return {
            name,
            module: str(f.module, `${where}.module`, MODULE_RE, 'must be a Maven module directory name'),
            bean: str(f.bean, `${where}.bean`, BEAN_RE, 'must be a Spring bean name'),
            mainClass: str(f.mainClass, `${where}.mainClass`, CLASS_RE, 'must be a fully qualified class name'),
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
    return { version: 1, buildRoot, functions };
}
function readManifest(repo) {
    const file = path.join(repo, exports.MANIFEST_FILE);
    if (!fs.existsSync(file))
        throw new ManifestError(`${repo} has no ${exports.MANIFEST_FILE}`);
    let raw;
    try {
        raw = JSON.parse(fs.readFileSync(file, 'utf8'));
    }
    catch (e) {
        throw new ManifestError(`${file} is not valid JSON: ${e.message}`);
    }
    return validateManifest(raw);
}

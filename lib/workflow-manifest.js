"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.RESERVED_SUFFIXES = exports.FlowManifestError = exports.PACKAGE_NAME_RE = exports.DEDUPE_DONE = exports.DEDUPE_STATE = exports.MAX_MAP_CONCURRENCY = exports.MAX_STATES = exports.MAX_FLOWS = exports.CENSHARE_LOGIN = exports.CENSHARE_REST = exports.HTTP_INVOKE = exports.PUT_EVENTS = exports.MAX_TIMEOUT_MINUTES = exports.MAX_WAIT_SECONDS = exports.LAMBDA_INVOKE_WAIT = exports.LAMBDA_INVOKE = exports.RESERVED_DETAIL_TYPES = exports.FLOW_SOURCE_PREFIX = exports.UNNAMED_WRITER_EVENTS = exports.TRIGGER_SOURCES = exports.MAX_FILTER_VALUES = exports.CATALOGUE_DIR = exports.CUSTOM_EVENT_RE = exports.CATALOGUE_EVENTS = exports.CATALOGUE_SOURCE = exports.TRIGGER_EVENTS = exports.SERVER_SOURCE = exports.FLOWS_FILE = exports.WORKFLOWS_DIR = void 0;
exports.isWebhookTrigger = isWebhookTrigger;
exports.checkDefinition = checkDefinition;
exports.catalogueMembers = catalogueMembers;
exports.validateFlows = validateFlows;
exports.readFlows = readFlows;
exports.workflowResourceNames = workflowResourceNames;
exports.maxFlowNameLength = maxFlowNameLength;
exports.checkFlowNames = checkFlowNames;
exports.withDedupe = withDedupe;
exports.releaseDefinition = releaseDefinition;
exports.resolveDefinition = resolveDefinition;
const fs = require("fs");
const path = require("path");
const function_manifest_1 = require("./function-manifest");
Object.defineProperty(exports, "PACKAGE_NAME_RE", { enumerable: true, get: function () { return function_manifest_1.PACKAGE_NAME_RE; } });
const cell_names_1 = require("./cell-names");
const catalogue_filter_1 = require("./catalogue-filter");
Object.defineProperty(exports, "CATALOGUE_DIR", { enumerable: true, get: function () { return catalogue_filter_1.CATALOGUE_DIR; } });
Object.defineProperty(exports, "CATALOGUE_EVENTS", { enumerable: true, get: function () { return catalogue_filter_1.CATALOGUE_EVENTS; } });
Object.defineProperty(exports, "CATALOGUE_SOURCE", { enumerable: true, get: function () { return catalogue_filter_1.CATALOGUE_SOURCE; } });
Object.defineProperty(exports, "CUSTOM_EVENT_RE", { enumerable: true, get: function () { return catalogue_filter_1.CUSTOM_EVENT_RE; } });
Object.defineProperty(exports, "MAX_FILTER_VALUES", { enumerable: true, get: function () { return catalogue_filter_1.MAX_FILTER_VALUES; } });
Object.defineProperty(exports, "UNNAMED_WRITER_EVENTS", { enumerable: true, get: function () { return catalogue_filter_1.UNNAMED_WRITER_EVENTS; } });
exports.WORKFLOWS_DIR = 'workflows';
exports.FLOWS_FILE = 'workflows.json';
exports.SERVER_SOURCE = 'censhare.hyperscaler';
exports.TRIGGER_EVENTS = ['asset.created', 'asset.preview-ready', 'hotfolder.imported', 'hotfolder.failed',
    'hotfolder.duplicate'];
exports.TRIGGER_SOURCES = [exports.SERVER_SOURCE, catalogue_filter_1.CATALOGUE_SOURCE];
exports.FLOW_SOURCE_PREFIX = 'customer.';
exports.RESERVED_DETAIL_TYPES = ['asset.', 'hotfolder.', 'workflow.', 'masterdata.', 'relation.', 'custom.'];
const DETAIL_TYPE_RE = /^[a-z][a-z0-9-]*(\.[a-z0-9-]+)+$/;
exports.LAMBDA_INVOKE = 'arn:aws:states:::lambda:invoke';
exports.LAMBDA_INVOKE_WAIT = 'arn:aws:states:::lambda:invoke.waitForTaskToken';
exports.MAX_WAIT_SECONDS = 30 * 24 * 3600;
exports.MAX_TIMEOUT_MINUTES = 365 * 24 * 60;
exports.PUT_EVENTS = 'arn:aws:states:::events:putEvents';
exports.HTTP_INVOKE = 'arn:aws:states:::http:invoke';
exports.CENSHARE_REST = '${censhare}/ws/rest/';
exports.CENSHARE_LOGIN = '${censhare-login}';
exports.MAX_FLOWS = 20;
exports.MAX_STATES = 100;
exports.MAX_MAP_CONCURRENCY = 10;
function isWebhookTrigger(t) {
    return t.type === 'webhook';
}
exports.DEDUPE_STATE = 'Dedupe: seen before?';
exports.DEDUPE_DONE = 'Dedupe: already handled';
const DEDUPE_BY_RE = /^(id|detail\.[A-Za-z][A-Za-z0-9]{0,63})$/;
const MAX_DEDUPE_BY = 4;
const MAX_DEDUPE_DAYS = 365;
function checkDedupe(d, where) {
    if (!isObject(d))
        fail(where, 'must be { "by": ["detail.<member>", ...], "days": <optional> }');
    onlyKeys(d, ['by', 'days'], where);
    if (!Array.isArray(d.by) || d.by.length === 0 || d.by.length > MAX_DEDUPE_BY) {
        fail(`${where}.by`, `must list 1 to ${MAX_DEDUPE_BY} event members, e.g. ["detail.assetId"]`);
    }
    for (const m of d.by) {
        if (typeof m !== 'string' || !DEDUPE_BY_RE.test(m))
            fail(`${where}.by`, `must be "id" or "detail.<member>", got ${JSON.stringify(m)}`);
    }
    if (new Set(d.by).size !== d.by.length)
        fail(`${where}.by`, 'names a member twice');
    if (d.days !== undefined && (typeof d.days !== 'number' || !Number.isInteger(d.days) || d.days < 1 || d.days > MAX_DEDUPE_DAYS)) {
        fail(`${where}.days`, `must be a whole number from 1 to ${MAX_DEDUPE_DAYS}, or left out to remember a key for good`);
    }
    return { by: d.by, ...(d.days !== undefined ? { days: d.days } : {}) };
}
class FlowManifestError extends Error {
}
exports.FlowManifestError = FlowManifestError;
function fail(where, message) {
    throw new FlowManifestError(`${where}: ${message}`);
}
function isObject(v) {
    return typeof v === 'object' && v !== null && !Array.isArray(v);
}
function onlyKeys(obj, allowed, where) {
    for (const k of Object.keys(obj)) {
        if (!allowed.includes(k))
            fail(where, `unknown field "${k}" (allowed: ${allowed.join(', ')})`);
    }
}
const NAME_RE = /^[a-z][a-z0-9-]{1,39}$/;
const DEFINITION_RE = /^[a-z0-9][a-z0-9-]{0,62}\.asl\.json$/;
const FUNCTION_PLACEHOLDER_RE = /^\$\{function:([a-z][a-z0-9-]{1,39})\}$/;
const STATE_TYPES = ['Pass', 'Task', 'Choice', 'Wait', 'Succeed', 'Fail', 'Parallel', 'Map'];
const COMMON = ['Type', 'Comment', 'InputPath', 'OutputPath'];
const MOVES = ['Next', 'End'];
const RESULTS = ['ResultPath', 'ResultSelector', 'Retry', 'Catch'];
const STATE_FIELDS = {
    Pass: [...COMMON, ...MOVES, 'Parameters', 'Result', 'ResultPath'],
    Task: [...COMMON, ...MOVES, ...RESULTS, 'Resource', 'Parameters', 'TimeoutSeconds', 'HeartbeatSeconds'],
    Choice: [...COMMON, 'Choices', 'Default'],
    Wait: [...COMMON, ...MOVES, 'Seconds', 'Timestamp', 'SecondsPath', 'TimestampPath'],
    Succeed: [...COMMON],
    Fail: ['Type', 'Comment', 'Error', 'Cause'],
    Parallel: [...COMMON, ...MOVES, ...RESULTS, 'Branches', 'Parameters'],
    Map: [...COMMON, ...MOVES, ...RESULTS, 'ItemProcessor', 'Iterator', 'ItemsPath', 'ItemSelector', 'Parameters',
        'MaxConcurrency'],
};
const MACHINE_FIELDS = ['Comment', 'StartAt', 'States', 'TimeoutSeconds', 'Version', 'QueryLanguage'];
const BRANCH_FIELDS = ['Comment', 'StartAt', 'States'];
const PROCESSOR_FIELDS = ['Comment', 'StartAt', 'States', 'ProcessorConfig'];
const TASK_PARAMETERS = {
    [exports.LAMBDA_INVOKE]: ['FunctionName', 'Payload', 'Payload.$'],
    [exports.LAMBDA_INVOKE_WAIT]: ['FunctionName', 'Payload', 'Payload.$'],
    [exports.PUT_EVENTS]: ['Entries'],
    [exports.HTTP_INVOKE]: ['ApiEndpoint', 'ApiEndpoint.$', 'Method', 'Authentication', 'Headers', 'QueryParameters',
        'QueryParameters.$', 'RequestBody', 'RequestBody.$', 'Transform'],
};
const ENTRY_FIELDS = ['EventBusName', 'Source', 'DetailType', 'Detail', 'Detail.$'];
const LEAVES_REST = /\.\.|%2e|%2f|%5c|\\/i;
function checkDefinition(asl, where, functions) {
    return check(asl, where, functions).functions;
}
function check(asl, where, functions) {
    if (!isObject(asl))
        fail(where, 'must be a JSON object (the state machine as Workflow Studio exports it)');
    if (asl.QueryLanguage !== undefined && asl.QueryLanguage !== 'JSONPath') {
        fail(where, 'QueryLanguage must be JSONPath for now');
    }
    for (const m of JSON.stringify(asl).matchAll(/\$\{([^}]*)\}/g)) {
        const key = m[1];
        if (key === 'bus' || key === 'censhare' || key === 'censhare-login')
            continue;
        const fn = /^function:(.*)$/.exec(key);
        if (!fn)
            fail(where, `unknown placeholder \${${key}}; use \${bus}, \${censhare}, \${censhare-login} or \${function:<name>}`);
        if (!functions.has(fn[1]))
            fail(where, `\${${key}}: "${fn[1]}" is not a function in functions.json`);
    }
    const used = new Set();
    let count = 0;
    const walk = (machine, at, fields) => {
        if (!isObject(machine) || typeof machine.StartAt !== 'string' || !isObject(machine.States)) {
            fail(at, 'needs StartAt and States');
        }
        onlyKeys(machine, fields, at);
        for (const [name, s] of Object.entries(machine.States)) {
            const st = `${at} state "${name}"`;
            if (++count > exports.MAX_STATES)
                fail(where, `has more than ${exports.MAX_STATES} states`);
            if (!isObject(s) || typeof s.Type !== 'string' || !STATE_TYPES.includes(s.Type)) {
                fail(st, `Type must be one of ${STATE_TYPES.join(', ')}`);
            }
            if (s.Credentials !== undefined)
                fail(st, 'Credentials (another role or account) is not allowed');
            if (s.QueryLanguage !== undefined)
                fail(st, 'a state may not set its own QueryLanguage; flows are JSONPath');
            if (s.ItemReader !== undefined || s.ResultWriter !== undefined)
                fail(st, 'ItemReader/ResultWriter (S3) are not allowed');
            onlyKeys(s, STATE_FIELDS[s.Type], st);
            if (s.Type === 'Task')
                checkTask(s, st, used);
            if (s.Type === 'Parallel') {
                if (!Array.isArray(s.Branches))
                    fail(st, 'needs Branches');
                s.Branches.forEach((b, i) => walk(b, `${st} branch ${i}`, BRANCH_FIELDS));
            }
            if (s.Type === 'Map') {
                if (s.ItemProcessor !== undefined && s.Iterator !== undefined)
                    fail(st, 'has both ItemProcessor and Iterator; use ItemProcessor');
                const processor = s.ItemProcessor ?? s.Iterator;
                if (isObject(processor) && processor.ProcessorConfig !== undefined) {
                    const config = processor.ProcessorConfig;
                    if (!isObject(config) || config.Mode === 'DISTRIBUTED')
                        fail(st, 'a distributed Map is not allowed; use an inline Map');
                    onlyKeys(config, ['Mode'], `${st} ProcessorConfig`);
                    if (config.Mode !== undefined && config.Mode !== 'INLINE')
                        fail(`${st} ProcessorConfig`, 'Mode must be INLINE');
                }
                if (typeof s.MaxConcurrency !== 'number' || s.MaxConcurrency < 1 || s.MaxConcurrency > exports.MAX_MAP_CONCURRENCY) {
                    fail(st, `MaxConcurrency is required, 1 to ${exports.MAX_MAP_CONCURRENCY}`);
                }
                walk(processor, `${st} items`, PROCESSOR_FIELDS);
            }
        }
    };
    walk(asl, where, MACHINE_FIELDS);
    const callsCenshare = used.delete(exports.HTTP_INVOKE);
    return { functions: [...used].sort(), callsCenshare };
}
function checkTask(s, st, used) {
    const p = isObject(s.Parameters) ? s.Parameters : {};
    const allowed = typeof s.Resource === 'string' ? TASK_PARAMETERS[s.Resource] : undefined;
    if (allowed)
        onlyKeys(p, allowed, `${st} Parameters`);
    if (s.Resource === exports.LAMBDA_INVOKE || s.Resource === exports.LAMBDA_INVOKE_WAIT) {
        const m = typeof p.FunctionName === 'string' ? FUNCTION_PLACEHOLDER_RE.exec(p.FunctionName) : null;
        if (!m)
            fail(st, 'Parameters.FunctionName must be ${function:<name>}, one of the functions in functions.json');
        used.add(m[1]);
        if (s.Resource === exports.LAMBDA_INVOKE_WAIT) {
            const payload = isObject(p.Payload) ? p.Payload : {};
            if (!Object.values(payload).includes('$$.Task.Token')) {
                fail(st, 'a wait for a callback must pass the token: "taskToken.$": "$$.Task.Token" in Parameters.Payload');
            }
            if (typeof s.TimeoutSeconds !== 'number' || s.TimeoutSeconds < 1 || s.TimeoutSeconds > exports.MAX_WAIT_SECONDS) {
                fail(st, `a wait for a callback needs TimeoutSeconds, 1 to ${exports.MAX_WAIT_SECONDS}, so it cannot wait forever`);
            }
        }
        return;
    }
    if (s.Resource === exports.PUT_EVENTS) {
        if (!Array.isArray(p.Entries) || p.Entries.length === 0)
            fail(st, 'Parameters.Entries must list at least one event');
        p.Entries.forEach((e, i) => {
            const at = `${st} Entries[${i}]`;
            if (!isObject(e))
                fail(at, 'must be an object');
            onlyKeys(e, ENTRY_FIELDS, at);
            if (e.EventBusName !== '${bus}')
                fail(at, 'EventBusName must be ${bus}, the cell\'s bus');
            if (typeof e.Source !== 'string' || !e.Source.startsWith(exports.FLOW_SOURCE_PREFIX)) {
                fail(at, `Source must be a fixed text starting with ${exports.FLOW_SOURCE_PREFIX}, so the event cannot pose as the server`);
            }
            if (typeof e.DetailType !== 'string' || !DETAIL_TYPE_RE.test(e.DetailType)) {
                fail(at, 'DetailType must be a fixed lower-case name with a dot, e.g. image.shoppable');
            }
            const detailType = e.DetailType;
            if (exports.RESERVED_DETAIL_TYPES.some((prefix) => detailType.startsWith(prefix))) {
                fail(at, `DetailType ${detailType} is the server's (${exports.RESERVED_DETAIL_TYPES.map((x) => `${x}*`).join(', ')}); `
                    + 'name the flow\'s own event, e.g. image.shoppable');
            }
        });
        return;
    }
    if (s.Resource === exports.HTTP_INVOKE) {
        if (p.ApiEndpoint !== undefined && p['ApiEndpoint.$'] !== undefined)
            fail(st, 'has both ApiEndpoint and ApiEndpoint.$');
        const fixed = typeof p.ApiEndpoint === 'string' && p.ApiEndpoint.startsWith(exports.CENSHARE_REST);
        const formatted = typeof p['ApiEndpoint.$'] === 'string' && p['ApiEndpoint.$'].startsWith(`States.Format('${exports.CENSHARE_REST}`);
        if (!fixed && !formatted) {
            fail(st, `ApiEndpoint must start with ${exports.CENSHARE_REST} (or be States.Format('${exports.CENSHARE_REST}...', ...)): a flow `
                + 'may call only its cell\'s censhare REST API');
        }
        const template = fixed ? p.ApiEndpoint : p['ApiEndpoint.$'].slice('States.Format('.length).split("'")[1] ?? '';
        if (LEAVES_REST.test(template))
            fail(st, 'ApiEndpoint may not hold "..", "%2e", "%2f", "%5c" or a backslash');
        if (p.Method !== undefined && typeof p.Method !== 'string')
            fail(st, 'Method must be a fixed text');
        const auth = isObject(p.Authentication) ? p.Authentication : {};
        if (auth.ConnectionArn !== exports.CENSHARE_LOGIN || Object.keys(auth).length !== 1) {
            fail(st, `Authentication must be { "ConnectionArn": "${exports.CENSHARE_LOGIN}" }, the workflows' login`);
        }
        if (p.Headers !== undefined && !isObject(p.Headers))
            fail(st, 'Headers must be an object');
        if (isObject(p.Headers) && Object.keys(p.Headers).some((h) => h.replace(/\.\$$/, '').toLowerCase() === 'authorization')) {
            fail(st, 'Headers may not set Authorization; the workflows\' login does');
        }
        used.add(exports.HTTP_INVOKE);
        return;
    }
    fail(st, `calls ${JSON.stringify(s.Resource)}; a flow may call its own functions (${exports.LAMBDA_INVOKE}, or `
        + `${exports.LAMBDA_INVOKE_WAIT} to wait for a callback), the censhare REST API (${exports.HTTP_INVOKE} with ${exports.CENSHARE_LOGIN}) `
        + `and put events on the cell bus (${exports.PUT_EVENTS})`);
}
function catalogueMembers(event) {
    return (0, catalogue_filter_1.catalogueMembers)(event, (m) => { throw new FlowManifestError(m); });
}
function checkTrigger(t, where) {
    if (t.type === 'webhook')
        return (0, function_manifest_1.parseWebhookTrigger)(t, where, fail);
    if (t.type !== undefined)
        fail(`${where}.type`, `must be "webhook", or left out for an event, got ${JSON.stringify(t.type)}`);
    onlyKeys(t, ['source', 'event', 'filter', 'includeOwnWrites'], where);
    const source = t.source ?? exports.SERVER_SOURCE;
    if (typeof source !== 'string' || !exports.TRIGGER_SOURCES.includes(source)) {
        fail(`${where}.source`, `must be one of ${exports.TRIGGER_SOURCES.join(', ')}, got ${JSON.stringify(t.source)}`);
    }
    if (source === exports.SERVER_SOURCE) {
        if (typeof t.event !== 'string' || !exports.TRIGGER_EVENTS.includes(t.event)) {
            fail(`${where}.event`, `must be one of ${exports.TRIGGER_EVENTS.join(', ')}, got ${JSON.stringify(t.event)} `
                + `(for the censhare event catalogue, set "source": "${catalogue_filter_1.CATALOGUE_SOURCE}")`);
        }
        if (t.filter !== undefined || t.includeOwnWrites !== undefined) {
            fail(where, `filter and includeOwnWrites are for "source": "${catalogue_filter_1.CATALOGUE_SOURCE}" only`);
        }
        return { source, event: t.event, includeOwnWrites: false };
    }
    if (!(0, catalogue_filter_1.isCatalogueEvent)(t.event)) {
        fail(`${where}.event`, `must be one of ${catalogue_filter_1.CATALOGUE_EVENTS.join(', ')} or custom.<name>, got ${JSON.stringify(t.event)}`);
    }
    const event = t.event;
    const filter = t.filter === undefined ? undefined : (0, catalogue_filter_1.checkCatalogueFilter)(t.filter, [event], `${where}.filter`, fail);
    if (t.includeOwnWrites !== undefined && typeof t.includeOwnWrites !== 'boolean') {
        fail(`${where}.includeOwnWrites`, 'must be true or false');
    }
    return { source, event, filter, includeOwnWrites: t.includeOwnWrites === true };
}
function validateFlows(raw, functions, readDefinition, functionHookPaths = new Set()) {
    if (!isObject(raw))
        fail(exports.FLOWS_FILE, 'must be a JSON object');
    onlyKeys(raw, ['$schema', 'version', 'vendor', 'package', 'flows'], exports.FLOWS_FILE);
    if (raw.version !== 1)
        fail(`${exports.FLOWS_FILE}: version`, `must be 1, got ${JSON.stringify(raw.version)}`);
    for (const key of ['vendor', 'package']) {
        const v = raw[key];
        if (v !== undefined && (typeof v !== 'string' || !function_manifest_1.PACKAGE_NAME_RE.test(v))) {
            fail(`${exports.FLOWS_FILE}: ${key}`, `must be lower-case [a-z0-9_-], starting with a letter or digit, not ${JSON.stringify(v)} `
                + '(the name censhare gave at onboarding)');
        }
    }
    if (!Array.isArray(raw.flows) || raw.flows.length === 0)
        fail(`${exports.FLOWS_FILE}: flows`, 'must list at least one flow');
    if (raw.flows.length > exports.MAX_FLOWS)
        fail(`${exports.FLOWS_FILE}: flows`, `at most ${exports.MAX_FLOWS} flows`);
    const names = new Set();
    const hookPaths = new Set();
    const flows = raw.flows.map((f, i) => {
        const at = `${exports.FLOWS_FILE}: flows[${i}]`;
        if (!isObject(f))
            fail(at, 'must be an object');
        if ('identity' in f)
            fail(`${at}.identity`, 'is gone: the cell\'s workflows share one login and one censhare person (#1102)');
        onlyKeys(f, ['name', 'description', 'definition', 'trigger', 'timeoutMinutes', 'dedupe'], at);
        if (typeof f.name !== 'string' || !NAME_RE.test(f.name)) {
            fail(`${at}.name`, 'must be 2-40 lower-case letters, digits or dashes, starting with a letter');
        }
        const where = `flow "${f.name}"`;
        if (names.has(f.name))
            fail(where, 'the name is used twice');
        const suffix = exports.RESERVED_SUFFIXES.find((s) => f.name.endsWith(s));
        if (suffix)
            fail(`${where}.name`, `may not end in ${suffix}: the deploy names a flow's own resources so`);
        names.add(f.name);
        const description = f.description ?? `censhare flow ${f.name}`;
        if (typeof description !== 'string' || description.length > 256)
            fail(`${where}.description`, 'must be text of at most 256 characters');
        if (typeof f.definition !== 'string' || !DEFINITION_RE.test(f.definition)) {
            fail(`${where}.definition`, 'must be <name>.asl.json, a file in workflows/');
        }
        if (!isObject(f.trigger))
            fail(`${where}.trigger`, 'must be { "event": "<event>" }');
        const trigger = checkTrigger(f.trigger, `${where}.trigger`);
        if (isWebhookTrigger(trigger)) {
            if (functionHookPaths.has(trigger.path))
                fail(`${where}.trigger.path`, `${trigger.path} is a function's webhook in functions.json`);
            if (hookPaths.has(trigger.path))
                fail(`${where}.trigger.path`, `${trigger.path} is another flow's webhook`);
            hookPaths.add(trigger.path);
        }
        const timeoutMinutes = f.timeoutMinutes ?? 15;
        if (typeof timeoutMinutes !== 'number' || !Number.isInteger(timeoutMinutes) || timeoutMinutes < 1
            || timeoutMinutes > exports.MAX_TIMEOUT_MINUTES) {
            fail(`${where}.timeoutMinutes`, `must be a whole number from 1 to ${exports.MAX_TIMEOUT_MINUTES} (a year)`);
        }
        const dedupe = f.dedupe === undefined ? undefined : checkDedupe(f.dedupe, `${where}.dedupe`);
        const definition = readDefinition(f.definition);
        const used = check(definition, `${where} (${f.definition})`, functions);
        if (dedupe && isObject(definition) && isObject(definition.States)
            && (exports.DEDUPE_STATE in definition.States || exports.DEDUPE_DONE in definition.States)) {
            fail(`${where} (${f.definition})`, `the states "${exports.DEDUPE_STATE}" and "${exports.DEDUPE_DONE}" are the deploy's, for dedupe`);
        }
        if (!isWebhookTrigger(trigger) && used.callsCenshare && !trigger.includeOwnWrites && catalogue_filter_1.UNNAMED_WRITER_EVENTS.includes(trigger.event)) {
            fail(`${where}.trigger`, `${trigger.event} never says who made the change, so the flow's own writes cannot be left `
                + `out and could start it again; make sure the flow does not cause ${trigger.event} itself, then set `
                + '"includeOwnWrites": true to say so');
        }
        return {
            name: f.name, description, definitionFile: f.definition, definition: definition,
            trigger, timeoutMinutes, functions: used.functions,
            callsCenshare: used.callsCenshare,
            ...(dedupe ? { dedupe } : {}),
        };
    });
    return { version: 1, ...(raw.vendor !== undefined ? { vendor: raw.vendor } : {}),
        ...(raw.package !== undefined ? { package: raw.package } : {}), flows };
}
function readJson(file) {
    if (!fs.existsSync(file))
        throw new FlowManifestError(`${file} does not exist`);
    let text;
    try {
        text = fs.readFileSync(file, 'utf8');
    }
    catch (e) {
        throw new Error(`${file} could not be read: ${e.message}`);
    }
    try {
        return JSON.parse(text);
    }
    catch (e) {
        throw new FlowManifestError(`${file} is not valid JSON: ${e.message}`);
    }
}
function readFlows(repo) {
    const fns = (0, function_manifest_1.manifestFile)(repo) ? (0, function_manifest_1.readManifest)(repo).functions : [];
    const functions = new Set(fns.map((f) => f.name));
    const hooks = new Set(fns.flatMap((f) => f.triggers.flatMap((t) => (t.type === 'webhook' ? [t.path] : []))));
    const dir = path.join(repo, exports.WORKFLOWS_DIR);
    return validateFlows(readJson(path.join(dir, exports.FLOWS_FILE)), functions, (file) => readJson(path.join(dir, file)), hooks);
}
function workflowResourceNames(prefix, flow) {
    const name = `${prefix}${flow}`;
    return {
        stateMachine: name, role: name, trigger: name, connection: name,
        release: `${name}-release`, releaseRole: `${name}-release`, failedRule: `${name}-failed`, dlq: `${name}-dlq`,
        startRole: `${name}-start`,
    };
}
const NAME_KINDS = {
    stateMachine: 'stateMachine', role: 'role', trigger: 'rule', connection: 'connection',
    release: 'stateMachine', releaseRole: 'role', failedRule: 'rule', dlq: 'queue', startRole: 'role',
};
exports.RESERVED_SUFFIXES = ['-release', '-failed', '-dlq', '-start'];
function maxFlowNameLength(prefix) {
    const probe = workflowResourceNames(prefix, '');
    return Math.min(...Object.keys(probe)
        .map((k) => cell_names_1.NAME_LIMITS[NAME_KINDS[k]] - probe[k].length));
}
function checkFlowNames(manifest, prefix) {
    const max = maxFlowNameLength(prefix);
    for (const flow of manifest.flows) {
        if (flow.name.length > max) {
            fail(`flow "${flow.name}".name`, `is ${flow.name.length} characters; on this cell (${prefix}) a flow's name may have `
                + `at most ${max}, so its resources' names stay within AWS's limits`);
        }
    }
}
function dedupeKey(flow, by, source, onMissing) {
    const parts = by.map((m) => `'#' & ($exists($e.${m}) ? $string($e.${m}) : ${onMissing(m)})`).join(' & ');
    return `($e := ${source}; '${flow}' & ${parts})`;
}
function withDedupe(definition, flow, dedupe) {
    const key = `{% ${dedupeKey(flow, dedupe.by, '$states.input', (m) => `$error('dedupe: the event has no ${m}, so its key cannot be made')`)} %}`;
    const item = { key: { S: key } };
    if (dedupe.days)
        item.expires = { N: `{% $string($floor($millis() / 1000) + ${dedupe.days * 86400}) %}` };
    const condition = dedupe.days
        ? { ConditionExpression: 'attribute_not_exists(#k) OR #e < :now', ExpressionAttributeNames: { '#k': 'key', '#e': 'expires' },
            ExpressionAttributeValues: { ':now': { N: '{% $string($floor($millis() / 1000)) %}' } } }
        : { ConditionExpression: 'attribute_not_exists(#k)', ExpressionAttributeNames: { '#k': 'key' } };
    const states = definition.States;
    return {
        ...definition,
        StartAt: exports.DEDUPE_STATE,
        States: {
            [exports.DEDUPE_STATE]: {
                Type: 'Task',
                QueryLanguage: 'JSONata',
                Comment: `Added by the deploy (#764): run once per ${dedupe.by.join(' + ')}${dedupe.days ? `, remembered ${dedupe.days} days` : ''}`,
                Resource: 'arn:aws:states:::dynamodb:putItem',
                Arguments: { TableName: '${dedupe-table}', Item: item, ...condition },
                Output: '{% $states.input %}',
                Retry: [{ ErrorEquals: DEDUPE_RETRY, IntervalSeconds: 2, MaxAttempts: 3, BackoffRate: 2 }],
                Catch: [{ ErrorEquals: ['DynamoDB.ConditionalCheckFailedException'], Next: exports.DEDUPE_DONE }],
                Next: definition.StartAt,
            },
            [exports.DEDUPE_DONE]: { Type: 'Succeed', Comment: 'This event, or this asset, was handled before (#764)' },
            ...states,
        },
    };
}
const DEDUPE_RETRY = ['DynamoDB.ProvisionedThroughputExceededException', 'DynamoDB.ThrottlingException',
    'DynamoDB.InternalServerErrorException'];
function releaseDefinition(flow, dedupe) {
    return {
        Comment: `Deletes the dedupe key of a failed run of ${flow} (#764)`,
        QueryLanguage: 'JSONata',
        StartAt: 'Release the dedupe key',
        States: {
            'Release the dedupe key': {
                Type: 'Task',
                Resource: 'arn:aws:states:::dynamodb:deleteItem',
                Arguments: {
                    TableName: '${dedupe-table}',
                    Key: { key: { S: `{% ${dedupeKey(flow, dedupe.by, '$parse($states.input.detail.input)', () => "'\\u0000missing'")} %}` } },
                },
                Retry: [{ ErrorEquals: DEDUPE_RETRY, IntervalSeconds: 2, MaxAttempts: 5, BackoffRate: 2 }],
                End: true,
            },
        },
    };
}
function resolveDefinition(definition, values) {
    return JSON.stringify(definition).replace(/\$\{([^}]*)\}/g, (whole, key) => {
        if (!(key in values))
            throw new FlowManifestError(`no value for \${${key}}`);
        return values[key];
    });
}

"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.MAX_FILTER_VALUES = exports.CATALOGUE_DIR = exports.CUSTOM_EVENT_RE = exports.UNNAMED_WRITER_EVENTS = exports.CATALOGUE_EVENTS = exports.CATALOGUE_SOURCE = void 0;
exports.isCatalogueEvent = isCatalogueEvent;
exports.catalogueMembers = catalogueMembers;
exports.checkCatalogueFilter = checkCatalogueFilter;
exports.skipOwnWrites = skipOwnWrites;
const fs = require("fs");
const path = require("path");
exports.CATALOGUE_SOURCE = 'censhare.server';
exports.CATALOGUE_EVENTS = ['asset.created', 'asset.changed', 'asset.deleted', 'workflow.step-changed',
    'workflow.state-changed', 'workflow.assignee-changed', 'relation.created', 'relation.deleted', 'masterdata.changed'];
exports.UNNAMED_WRITER_EVENTS = ['asset.deleted', 'relation.created', 'relation.deleted', 'masterdata.changed'];
exports.CUSTOM_EVENT_RE = /^custom\.[a-z0-9][a-z0-9.-]{0,62}$/;
exports.CATALOGUE_DIR = path.join(__dirname, '..', 'docs', 'events');
const UNFILTERED = ['version', 'serviceIdentity'];
const DOTTED_MEMBERS = ['type', 'domain', 'domain2'];
exports.MAX_FILTER_VALUES = 50;
function isCatalogueEvent(event) {
    return typeof event === 'string' && (exports.CATALOGUE_EVENTS.includes(event) || exports.CUSTOM_EVENT_RE.test(event));
}
let catalogue;
function catalogueMembers(event, fail = (m) => { throw new Error(m); }) {
    if (!catalogue) {
        const read = new Map();
        for (const file of fs.readdirSync(exports.CATALOGUE_DIR).filter((n) => n.endsWith('.schema.json'))) {
            const schema = JSON.parse(fs.readFileSync(path.join(exports.CATALOGUE_DIR, file), 'utf8'));
            const members = {};
            for (const [k, v] of Object.entries(schema.properties ?? {})) {
                if (!UNFILTERED.includes(k) && (v.type === 'string' || v.type === 'integer'))
                    members[k] = v.type;
            }
            read.set(file.replace(/\.schema\.json$/, ''), members);
        }
        catalogue = read;
    }
    const members = catalogue.get(exports.CUSTOM_EVENT_RE.test(event) ? 'custom' : event);
    if (!members)
        fail(`${exports.CATALOGUE_DIR} has no schema for ${event}`);
    return members;
}
function isObject(v) {
    return typeof v === 'object' && v !== null && !Array.isArray(v);
}
function checkCatalogueFilter(raw, events, where, fail) {
    if (!isObject(raw) || Object.keys(raw).length === 0) {
        fail(where, 'must be an object from a detail member to the values it may have, e.g. { "type": ["picture."] }');
    }
    const schemas = events.map((e) => [e, catalogueMembers(e, (m) => fail(where, m))]);
    const filter = {};
    for (const [member, values] of Object.entries(raw)) {
        const at = `${where}.${member}`;
        let type;
        for (const [event, members] of schemas) {
            const t = Object.prototype.hasOwnProperty.call(members, member) ? members[member] : undefined;
            if (!t)
                fail(at, `${event} has no member "${member}" to filter on (it has: ${Object.keys(members).join(', ')})`);
            if (type && t !== type)
                fail(at, `"${member}" is a ${type} in one detail type and a ${t} in another: list them in two triggers`);
            type = t;
        }
        if (!Array.isArray(values) || values.length === 0 || values.length > exports.MAX_FILTER_VALUES) {
            fail(at, `must be a list of 1 to ${exports.MAX_FILTER_VALUES} values`);
        }
        for (const v of values) {
            if (type === 'integer') {
                if (!Number.isSafeInteger(v))
                    fail(at, `${member} is a whole number, got ${JSON.stringify(v)}`);
                continue;
            }
            const prefix = isObject(v) && Object.keys(v).length === 1 ? v.prefix : undefined;
            const text = prefix ?? v;
            if (typeof text !== 'string' || text.length === 0 || text.length > 256) {
                fail(at, `${member} is a text (1-256 characters) or { "prefix": "<text>" }, got ${JSON.stringify(v)}`);
            }
            if (DOTTED_MEMBERS.includes(member) && !text.endsWith('.')) {
                fail(at, `"${text}" never matches: censhare's ${member} values end with a dot, e.g. "${text}."`);
            }
            if (member === 'type' && text !== text.toLowerCase()) {
                fail(at, `"${text}" never matches: censhare's asset types are lower case, e.g. "${text.toLowerCase()}"`);
            }
        }
        filter[member] = [...values];
    }
    return filter;
}
function skipOwnWrites(clientId) {
    return { $or: [{ serviceIdentity: [{ exists: false }] }, { serviceIdentity: [{ 'anything-but': clientId }] }] };
}

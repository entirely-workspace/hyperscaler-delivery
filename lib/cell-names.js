"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.NAME_LIMITS = void 0;
exports.cellPrefix = cellPrefix;
exports.flowLogPrefix = flowLogPrefix;
exports.workflowsStackName = workflowsStackName;
exports.functionLogPrefix = functionLogPrefix;
exports.portalFunctionListPath = portalFunctionListPath;
exports.cellName = cellName;
exports.workflowPrefixes = workflowPrefixes;
const crypto_1 = require("crypto");
function cellPrefix(project, tenant) {
    if (!/^[a-z0-9][a-z0-9-]*$/i.test(project))
        throw new Error(`a project id is letters, digits and hyphens, got ${JSON.stringify(project)}`);
    if (!/^[a-z][a-z0-9-]{0,31}$/.test(tenant))
        throw new Error(`a tenant id is lower case letters, digits and hyphens, got ${JSON.stringify(tenant)}`);
    const h6 = (0, crypto_1.createHash)('sha256').update(`${project}/${tenant}`).digest('hex').slice(0, 6);
    return `cs_${tenant}_${h6}_`;
}
function flowLogPrefix(project, tenant) {
    cellPrefix(project, tenant);
    return `/censhare/${project}/${tenant}/flows/`;
}
function workflowsStackName(project, tenant) {
    return `${cellPrefix(project, tenant).replace(/_/g, '-')}workflows`;
}
function functionLogPrefix(project, tenant) {
    cellPrefix(project, tenant);
    return `/censhare/${project}/${tenant}/functions/`;
}
function portalFunctionListPath(project, tenant) {
    cellPrefix(project, tenant);
    return `/censhare/${project}/${tenant}/portal/functions`;
}
exports.NAME_LIMITS = { stateMachine: 80, queue: 80, rule: 64, role: 64, function: 64, table: 255, connection: 64 };
function cellName(prefix, name, kind) {
    if (!/^[a-z][a-z0-9-]*$/.test(name))
        throw new Error(`a name is lower case letters, digits and hyphens, got ${JSON.stringify(name)}`);
    const full = `${prefix}${name}`;
    if (full.length > exports.NAME_LIMITS[kind]) {
        throw new Error(`${full} has ${full.length} characters; a ${kind} name takes at most ${exports.NAME_LIMITS[kind]}`);
    }
    return full;
}
function workflowPrefixes(project, tenant) {
    return [cellPrefix(project, tenant)];
}

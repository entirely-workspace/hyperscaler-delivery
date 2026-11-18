"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.validateWorkflows = validateWorkflows;
const fs = require("fs");
const path = require("path");
const function_manifest_1 = require("./function-manifest");
const workflow_manifest_1 = require("./workflow-manifest");
function validateWorkflows(args, io) {
    if (args.includes('-h') || args.includes('--help')) {
        io.out('usage: workflow-validate [<folder with workflows/>]   (exit 0 passes, 1 refused, 2 could not check)');
        return 0;
    }
    if (args.length > 1) {
        io.err('usage: workflow-validate [<folder with workflows/>]');
        return 2;
    }
    const repo = path.resolve(args[0] ?? '.');
    const file = path.join(repo, workflow_manifest_1.WORKFLOWS_DIR, workflow_manifest_1.FLOWS_FILE);
    if (!fs.existsSync(file)) {
        io.err(`error: no ${workflow_manifest_1.WORKFLOWS_DIR}/${workflow_manifest_1.FLOWS_FILE} in ${repo}`);
        return 2;
    }
    try {
        const manifest = (0, workflow_manifest_1.readFlows)(repo);
        const missing = ['vendor', 'package'].filter((k) => manifest[k] === undefined);
        if (missing.length) {
            io.err(`error: ${workflow_manifest_1.WORKFLOWS_DIR}/${workflow_manifest_1.FLOWS_FILE} has no ${missing.map((k) => `"${k}"`).join(' and ')}: delivery stores the `
                + 'package under them (the names censhare gave at onboarding, as in customization.json)');
            return 1;
        }
        io.out(`ok: ${manifest.vendor}/${manifest.package}, ${manifest.flows.length} workflow(s): `
            + manifest.flows.map((f) => f.name).join(', '));
        return 0;
    }
    catch (e) {
        if (e instanceof workflow_manifest_1.FlowManifestError || e instanceof function_manifest_1.ManifestError) {
            io.err(`error: ${e.message}`);
            return 1;
        }
        io.err(`error: could not check the workflows: ${e.message}`);
        return 2;
    }
}
if (require.main === module) {
    process.exitCode = validateWorkflows(process.argv.slice(2), { out: (l) => console.log(l), err: (l) => console.error(l) });
}

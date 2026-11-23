"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.dockerInspect = exports.MAX_IMAGE_BYTES = void 0;
exports.validateFunctions = validateFunctions;
const child_process_1 = require("child_process");
const fs = require("fs");
const path = require("path");
const function_manifest_1 = require("./function-manifest");
exports.MAX_IMAGE_BYTES = 10 * 1024 * 1024 * 1024;
const dockerInspect = (image) => {
    const r = (0, child_process_1.spawnSync)('docker', ['image', 'inspect', '--format', '{{.Os}} {{.Architecture}} {{.Size}}', image], { encoding: 'utf8' });
    if (r.error)
        throw new Error(`docker is needed to check the functions' images: ${r.error.message}`);
    if (r.status !== 0)
        return undefined;
    const [os, architecture, size] = r.stdout.trim().split(' ');
    return { os, architecture, size: Number(size) };
};
exports.dockerInspect = dockerInspect;
function validateFunctions(args, io, inspect = exports.dockerInspect) {
    const usage = 'usage: function-validate [--list] [<folder with functions/>]   (exit 0 passes, 1 refused, 2 could not check)';
    if (args.includes('-h') || args.includes('--help')) {
        io.out(usage);
        return 0;
    }
    const list = args.includes('--list');
    const rest = args.filter((a) => a !== '--list');
    if (rest.length > 1 || rest.some((a) => a.startsWith('-'))) {
        io.err(usage);
        return 2;
    }
    const repo = path.resolve(rest[0] ?? '.');
    const file = path.join(repo, function_manifest_1.MANIFEST_IN_FOLDER);
    if (!fs.existsSync(file)) {
        io.err(`error: no ${function_manifest_1.MANIFEST_IN_FOLDER} in ${repo}`);
        return 2;
    }
    let raw;
    try {
        raw = JSON.parse(fs.readFileSync(file, 'utf8'));
    }
    catch (e) {
        io.err(`error: ${function_manifest_1.MANIFEST_IN_FOLDER} is not valid JSON: ${e.message}`);
        return 1;
    }
    try {
        const manifest = (0, function_manifest_1.validateManifest)(raw);
        const missing = ['vendor', 'package'].filter((k) => manifest[k] === undefined);
        if (missing.length) {
            io.err(`error: ${function_manifest_1.MANIFEST_IN_FOLDER} has no ${missing.map((k) => `"${k}"`).join(' and ')}: delivery stores the `
                + 'package under them (the names censhare gave at onboarding, as in customization.json)');
            return 1;
        }
        const problems = [];
        const noImage = manifest.functions.filter((f) => f.image === undefined).map((f) => f.name);
        for (const n of noImage)
            problems.push(`function "${n}" has no "image": the kit delivers functions as container images`);
        const images = [...new Set(manifest.functions.map((f) => f.image).filter((i) => i !== undefined))];
        for (const image of images) {
            const facts = inspect(image);
            const users = manifest.functions.filter((f) => f.image === image).map((f) => `"${f.name}"`).join(', ');
            if (!facts) {
                problems.push((0, function_manifest_1.isRegistryImage)(image)
                    ? `image "${image}" (for ${users}) could not be pulled: sign in to its registry before the kit's step (docker login), and check that the digest exists`
                    : `image "${image}" (for ${users}) is not there: build it before the kit's step (docker build -t ${image} ...)`);
                continue;
            }
            if (facts.os !== 'linux' || facts.architecture !== 'arm64') {
                problems.push(`image "${image}" is ${facts.os}/${facts.architecture}: the cells run linux/arm64 (docker build --platform linux/arm64)`);
            }
            if (!(facts.size > 0) || facts.size > exports.MAX_IMAGE_BYTES) {
                problems.push(`image "${image}" is ${Math.ceil(facts.size / 1024 / 1024)} MB; Lambda takes at most 10 GB`);
            }
        }
        if (problems.length) {
            for (const p of problems)
                io.err(`error: ${p}`);
            return 1;
        }
        io.out(`ok: ${manifest.vendor}/${manifest.package}, ${manifest.functions.length} function(s) in ${images.length} image(s): `
            + manifest.functions.map((f) => f.name).join(', '));
        if (list)
            for (const i of images)
                io.out(i);
        return 0;
    }
    catch (e) {
        if (e instanceof function_manifest_1.ManifestError) {
            io.err(`error: ${e.message}`);
            return 1;
        }
        io.err(`error: could not check the functions: ${e.message}`);
        return 2;
    }
}
if (require.main === module) {
    process.exitCode = validateFunctions(process.argv.slice(2), { out: (l) => console.log(l), err: (l) => console.error(l) });
}

# Reference

The fields, variables and commands of the censhare HyperScaler partner kit, in one place. How to start is in
[README.md](README.md); how delivery works, from dev to prod and back, in [GUIDE.md](GUIDE.md).

## customization.json
The package: who it is, where its files are, and the folders it owns.

```json
{
  "vendor": "acme",
  "package": "acme-custom",
  "source": "censhare-Custom/censhare-Server",
  "owns": ["app/modules/acme", "app/masterdata"],
  "censhareVersion": ">=2026.2",
  "hyperscalerContract": 1,
  "activation": "boot",
  "touchesMasterdata": true,
  "arch": "any"
}
```

| Field | What it is |
|---|---|
| `vendor` | Your vendor id from censhare: lower-case letters, digits, `-` and `_`. |
| `package` | Your package's name. |
| `source` | The folder with your files, usually `censhare-Custom/censhare-Server`. |
| `owns` | The folders under `source` the package owns. Only their files are delivered, and the cell makes each one match your commit exactly, deleting files you deleted. |
| `excludes` | Paths inside an owned folder that are not delivered. |
| `censhareVersion` | The censhare versions the package runs on, such as `>=2026.2`. |
| `hyperscalerContract` | The delivery contract, `1`. |
| `activation` | `boot` (at the next restart) or `refresh` (no restart). `refresh` is refused if the package has jars, `.ts` or `.scss`. |
| `touchesMasterdata` | `true` if the package carries masterdata: masterdata can't be rolled back by files, so it must be declared. |
| `arch` | `any`, or `arm64` if it has native code: the cells run linux/arm64. |
| `requiresServices` | censhare services the package needs. |
| `replaces` | For each censhare asset a variant of yours replaces, the checksum of the asset it was made from. |
| `parameters`, `secrets` | Values that differ per cell, which the customer sets (below). |
| `settings` | Server settings the package can't own as files. |
| `client` | The customer's own web client: `{ "branding": "<name>" }`, with `custom/<name>.json` and its logos laid out as in classic's censhare-Custom. Without it, a branding in `custom/` is found and checked as it is. |

**What a package may own.** A folder of its own, such as `app/modules/acme` or `app/web/src/acme-dam`, and
`app/masterdata` or `app/assets` as a whole. Not `app` or `app/modules` themselves (too broad), not `app/config` or
`app/services` (the cell generates them), and no folder another package on the cell owns. `bin/validate.sh` tells you.

**Only committed files are delivered**, and only the tip of the branch: a re-run or a late run of an older push ends
green and delivers nothing, since a newer push is on its way.

### Values that differ per cell
A value that differs between dev, test and prod (an SAP URL, a host) is never in your files: name it, and the customer
sets it on each cell. Leave the attribute out of the file; the cell fills it in. A password or token is a secret
(`secrets`, the same shape), never a value.
```json
"parameters": [ { "name": "sap-url", "file": "app/modules/acme/sap/aa-acme-sap.xml", "attribute": "sap-url" } ]
```
`attribute` sets an attribute of the first `<config>` in that file (an XSL reads `$config/config/@sap-url`); `path`
instead, such as `"/mail/account/property[@key='mail.smtp.host']/@value"`, sets another element's. For a censhare
service's configuration, such as the mail service's SMTP host, name `"service": "mail"` and a `path` instead of a
file: only the paths censhare lists for the edition are taken. A version naming a value the cell doesn't have yet is
refused, and the cell keeps what it runs: ask the customer to set it first. A cell whose edition can't set parameters
refuses a package that names them, and the run says why.

## workflows/workflows.json
A customer's automations repository delivers its workflows (the kit's `automations/`). The package is the
`workflows/` folder, checked with the same rules as the cell's deploy:
```json
{ "version": 1, "vendor": "acme", "package": "acme-automations",
  "flows": [{ "name": "new-picture", "definition": "new-picture.asl.json",
              "trigger": { "source": "censhare.server", "event": "asset.created" }, "timeoutMinutes": 5 }] }
```
The customer must allow workflows for your repository; without it the package is stored and its activation is refused
with `AccessDenied`. It takes longer than a customization, so the wait is 40 minutes unless you set it.

## functions/functions.json
**Deliver these functions**: a package of its own, next to the workflows that call them.
```json
{ "version": 1, "vendor": "acme", "package": "acme-automations",
  "functions": [{ "name": "hello", "image": "hello", "memoryMb": 512, "timeoutSeconds": 10, "concurrency": 1 }] }
```
- `image` is a folder `functions/<image>/` with a `Dockerfile` (lower case letters, digits, `.`, `_` and `-`). With
  `BUILD_IMAGES=yes` in the job's environment the kit builds each one for linux/arm64, as the kit's `automations/` and
  the CodeCommit build do; otherwise your CI builds it before the kit's step, tagged with that name. Or `image` is a
  registry image by digest, `<registry>/<name>@sha256:...`, which the kit pulls (sign in to that registry first).
- Use one of AWS's Lambda base images on `public.ecr.aws`, and build with `--provenance=false`: Lambda runs a single
  image, at most 10 GB, and ECR's scan must be able to read it.
- `functions/build.sh`, if there is one, runs first: what the images need that a commit doesn't hold (a Java build).
- With `workflows/` next to it, one run delivers the functions first, then the workflows. To remove a function a
  workflow calls, push the workflows without the call first, then remove the function.
- The customer must allow functions for your repository (allowing workflows doesn't).

`PACKAGE_TYPE` says which kind a run checks or delivers: `censhare-custom`, `workflows` or `functions`. A repository
with both `customization.json` and `workflows/workflows.json` must set it. In an automations repository, `validate.sh`
checks the workflows by default; check the functions with `PACKAGE_TYPE=functions` (the pipeline delivers both).

## Variables
Every variable the examples' pipelines read, with the values the customer gives you. On GitHub they are repository
variables (Settings → Secrets and variables → Actions → Variables); on GitLab, CI/CD variables (Settings → CI/CD →
Variables), unprotected unless the branch is protected. None of them is a secret: your CI's OIDC token proves which
repository and branch is delivering, and no key is stored.

| Variable | Value | Needed |
|---|---|---|
| `CENSHARE_CUSTOMER` | The customer id. | always |
| `CENSHARE_PACKAGES_BUCKET` | The customer's package store. | always |
| `CENSHARE_PUBLISHER_ROLE` | The publisher role for `main`. Each delegated branch has its own role, which trusts that branch only. | always |
| `CENSHARE_PUBLISHER_ROLE_TEST` | The publisher role for `test`. | if test is delegated to you |
| `CENSHARE_DEV_CELLS_ROLE` | The role of the customer's delegation to their extra dev cells. | if they are delegated to you |
| `CENSHARE_STAGE` | GitLab: `dev` or `test`. Each job of the example sets it: don't set it on the project, which would win. | set by the jobs |
| `CENSHARE_ACTIVATE` | GitLab: `next-boot` (default) or `now`. | optional |
| `CENSHARE_REASON` | GitLab: why now. Needed with `now`, and kept in the cell's record. | with `now` |
| `CENSHARE_REGION` | GitLab: the package store's region, `eu-central-1` by default. | optional |

CodeCommit has no variables of yours: the customer's CodeBuild has them.

## The GitHub Action
`entirely-workspace/hyperscaler-delivery@<kit version>`, with `permissions: { id-token: write, contents: read }`:

| Input | What it is |
|---|---|
| `customer`, `packages-bucket`, `publisher-role` | Required: the variables above. |
| `stage` | `dev` (default) or `test`, as delegated. |
| `activate` | `next-boot` (default) or `now`, which needs `reason`. |
| `reason` | Why now; kept in the cell's record. |
| `region` | The package store's region, `eu-central-1` by default. |
| `working-directory` | The folder with `customization.json`, `.` by default. |
| `wait-minutes` | How long to wait for the cell's answer: 20 minutes for a customization, 40 for workflows or functions. |
| `dev-cells` | `true`: deliver to the extra dev cells that follow this branch, never to a stage. |

The job fails when the cell refuses the package, with the cell's reason. GitHub's own runners have everything it
needs; a self-hosted runner needs bash, git, jq, python3, Node (for workflows) and the AWS CLI.

## The GitLab template
`gitlab/deliver.gitlab-ci.yml` of the kit, included by URL at the kit's version and extended by your jobs
(the kit's `gitlab/example/.gitlab-ci.yml`): `.censhare-deliver` for a stage, `.censhare-deliver-dev-cells` for the extra dev
cells. It runs the kit's `bin/deliver.sh` at its own version, and reads the branch and the push from GitLab's own
variables. It has no Docker, so it delivers customizations and workflows, but not functions yet.

## Commands
Clone the kit at its version to run them on your own machine:
```sh
git clone --depth 1 --branch <kit version> https://github.com/entirely-workspace/hyperscaler-delivery.git /tmp/censhare-kit
```

| Command | What it does |
|---|---|
| `bash /tmp/censhare-kit/bin/validate.sh [folder]` | The checks the cell runs on your package, with no AWS and no network: python3 for a customization, Node for workflows, and for functions (`PACKAGE_TYPE=functions`) Node and Docker with each image built for linux/arm64. Exit 1 when the cell would refuse it. The pipelines run it before they store anything. |
| `bash /tmp/censhare-kit/bin/deliver.sh --customer … --packages-bucket … --stage dev --publisher-role …` | What the Action runs, for any other CI with OIDC sign-in to AWS. It signs in with the token in `AWS_WEB_IDENTITY_TOKEN_FILE`; without `--publisher-role` it uses the AWS credentials already set. `--help` lists every flag. |
| `bash /tmp/censhare-kit/bin/pull-back.sh --cell https://<cell>/solution-console/ [--capture] [--into <branch>]` | Takes a cell's live changes (commands saved in the Admin Client, hotfolder rules) into a branch and a pull request. `--from capture-<cell>-<time>.zip` takes a capture you downloaded instead. |
| `bash /tmp/censhare-kit/bin/pull-back-workflows.sh --cell https://<cell>/solution-console/ [--into <branch>]` | The same for workflows and functions changed live, in your clone of the automations repository. |

A few checks need the cell and run only there: the censhare assets your variants replace, the customer's settings and
secrets, and the packages already active in the cell.

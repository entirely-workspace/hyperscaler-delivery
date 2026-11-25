# Deliver to censhare HyperScaler

Your customization package goes from **your** git and CI to the censhare HyperScaler cells of the customer you work
for. censhare keeps no copy of your source. Each push stores the package once, by its digest, in the customer's
package store, and activates it in the cell of the stage the customer delegated to you: **dev**, or **test**.
Prod is never delivered by a pipeline. It runs only a package test accepted, once the customer approves it.

This kit is versioned with each censhare edition: use the tag of the edition your customer runs.

The whole path, from getting a delegation to promotion, hotfix and rollback, is in [GUIDE.md](GUIDE.md).

## Start from the starter
The kit's `starter/` folder is a repository to copy into your own git, on GitHub or GitLab: a package to rename
(`customization.json`, `censhare-Custom/censhare-Server/app/modules/your-vendor/`) and both pipelines, already at this
kit's version. `main` delivers to dev; `test` to test, if the customer delegated test to you. Its `README.md` says
what to rename and which three variables to set.

## What you get from the customer
- **customer**: the customer id.
- **packages-bucket**: the package store.
- **publisher-role**: the role delegated to your repository and branch, for the stages the customer chose. Nothing
  else can use it, and it can do nothing else: store your package, start your stages' activations.

## GitHub Actions
```yaml
name: Deliver to censhare
on:
  push:
    branches: [main]          # the branch the customer delegated
# GitHub vouches for this workflow with its OIDC token; no key is stored.
permissions: { id-token: write, contents: read }
jobs:
  deliver:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: entirely-workspace/hyperscaler-delivery@<edition tag>
        with:
          customer: ${{ vars.CENSHARE_CUSTOMER }}
          packages-bucket: ${{ vars.CENSHARE_PACKAGES_BUCKET }}
          publisher-role: ${{ vars.CENSHARE_PUBLISHER_ROLE }}
          stage: dev
```

Inputs: `customer`, `packages-bucket`, `publisher-role` (required); `stage` (`dev`, or `test`), `activate`
(`next-boot`, or `now` with a `reason`), `region` (`eu-central-1`), `working-directory` (the folder with
`customization.json`), `wait-minutes` (`20`). The job fails when the cell refuses the package, with the cell's reason.
GitHub's own runners have everything the Action needs; a self-hosted runner needs bash, git, jq, python3 and the AWS
CLI (python3 for the check before anything is stored).

## Your package
`customization.json` names your vendor id, the package and the folder with your files:
```json
{ "vendor": "acme", "package": "pkg", "source": "censhare-Custom/censhare-Server" }
```
Only committed files are delivered, and only the tip of the branch: a re-run or a late run of an older push ends green
and delivers nothing, since a newer push is on its way.

A value that differs between dev, test and prod (an SAP URL, a host) is never in your files: name it, and the customer
sets it on each cell. Leave the attribute out of the file; the cell fills it in. A password or token is a secret
(`secrets`, the same shape), never a value.
```json
"parameters": [ { "name": "sap-url", "file": "app/modules/acme/sap/aa-acme-sap.xml", "attribute": "sap-url" } ]
```
`attribute` sets an attribute of the first `<config>` in that file (an XSL reads `$config/config/@sap-url`); `path`
instead, such as `"/mail/account/property[@key='mail.smtp.host']/@value"`, sets another element's. A version naming
a value the cell does not have yet is refused, and the cell keeps what it runs: ask the customer to set it first.
For a censhare service's configuration, such as the mail service's SMTP host, name `"service": "mail"` and a `path`
instead of a file: only paths on the edition's list are taken (docs/CUSTOMIZATION-DELIVERY.md).

Before a package reaches a cell, the delivery checks that the cell can apply what it uses: a package naming
environment values (`parameters`) is refused for a cell whose edition cannot set them, and the run says why.

## Workflows
A customer's automations repository delivers its workflows the same way. `workflows/workflows.json` names the vendor id
and the package, next to its workflows:
```json
{ "version": 1, "vendor": "acme", "package": "acme-automations", "flows": [ ... ] }
```
The package is the `workflows/` folder. It is checked with the same rules as the cell's deploy, using the function names
in `functions/functions.json`, stored, and activated in the stage's cell by its own activation, which builds and deploys
the workflows there; the job reports the cell's answer, as for a customization. The customer must allow
workflows for your repository (`"types"` with `workflows`, in its delegation or once for all the customer's
delegations); without it the package is stored, and its
activation is refused with `AccessDenied`. It can take longer than a
customization, so the wait is 40 minutes unless you set it. A repository that has both `customization.json` and
`workflows/workflows.json` sets `PACKAGE_TYPE` to `censhare-custom` or `workflows` to say which one it delivers.

## Functions
`functions/functions.json` in an automations repository means **deliver these functions**: it is a package of its own,
not only the list of names workflows may call. It names the vendor id and the package, and each function's zip, which
**your CI builds before the kit's step** (the kit builds nothing):
```json
{ "version": 1, "vendor": "acme", "package": "acme-automations", "build": { "root": "functions" },
  "functions": [{ "name": "picture-label", "module": "picture-label", "bean": "pictureLabel", "mainClass": "...", "concurrency": 2 }] }
```
A function's zip is `functions/<module>/target/<module>-lambda.zip` (the Maven build's), or the path in its `zip`. Each
zip must be a real zip, not a link, inside the repository, and unpack to at most 250 MB, as the zip declares it. Set a
fixed build time (`project.build.outputTimestamp`), so one commit always builds the same zip: a commit keeps the package
first stored for it, and a later build of the same commit is not stored again. With `workflows/` next to it, one run
delivers the functions first, then the workflows. The customer must allow functions for your repository (`"types"` with
`functions`; `workflows` never implies it), and only functions that workflows call (no `triggers`) are deployed for now.

## GitLab CI
GitLab vouches for the job with its OIDC token, which becomes the publisher role; no key is stored. The customer
delegates your project's path and branch (or tag) the same way. Include the kit's template and extend its job:
```yaml
include:
  - remote: https://raw.githubusercontent.com/entirely-workspace/hyperscaler-delivery/<edition tag>/gitlab/deliver.gitlab-ci.yml

deliver-to-censhare:
  extends: .censhare-deliver
  rules:
    - if: $CI_COMMIT_BRANCH == "main"      # the branch the customer delegated
```
Set `CENSHARE_CUSTOMER`, `CENSHARE_PACKAGES_BUCKET` and `CENSHARE_PUBLISHER_ROLE` as CI/CD variables of your project.
Optional: `CENSHARE_STAGE` (`dev`, or `test`), `CENSHARE_ACTIVATE` (`next-boot`, or `now` with `CENSHARE_REASON`),
`CENSHARE_REGION` (`eu-central-1`). The template runs the kit's `bin/deliver.sh` at its own version; `deliver.sh` reads
the branch and the push from GitLab's own variables (`CI_COMMIT_BRANCH`, `CI_PIPELINE_SOURCE`).

## Extra dev cells
A customer's extra dev cells each follow a repository and branch that their developer sets in the cell's Solution
Console. With the customer's delegation to the extra dev cells (`CENSHARE_DEV_CELLS_ROLE`), a push to any branch goes
to the cells that follow it, at once, never to a stage:
- **GitHub Actions:** the starter's `.github/workflows/deliver-dev-cells.yml`, which runs this Action with
  `dev-cells: true` and `publisher-role: ${{ vars.CENSHARE_DEV_CELLS_ROLE }}`.
- **GitLab CI:** extend `.censhare-deliver-dev-cells` in a job that runs on every branch push, with
  `CENSHARE_PUBLISHER_ROLE` set to `CENSHARE_DEV_CELLS_ROLE` (the starter's `deliver-dev-cells` job).

`deliver.sh` starts each cell as that cell's own role, with the same OIDC token: the role trusts only the branch the cell
follows. GitHub Enterprise Server and GHE.com work the same way, once the customer's delegation names your
host.

## Check your package first
`bin/validate.sh [folder]` runs the checks the cell runs on your package when it arrives, on your own checkout: no AWS,
no network, only python3 (Node for workflows). It prints each problem and exits 1 when the cell would refuse the package. The Action and the
GitLab template run it before they store anything, so a package that would be refused fails your pipeline instead:
```sh
git clone --depth 1 --branch <edition tag> https://github.com/entirely-workspace/hyperscaler-delivery.git /tmp/censhare-kit
bash /tmp/censhare-kit/bin/validate.sh .
```
A few checks need the cell and run only there: the censhare assets your variants replace, the customer's settings and
secrets, and packages already active in the cell.

## Take live changes back to git
Command configuration saved in the Admin Client and hotfolder rules saved on the Hotfolder page change a cell live,
outside your git. In your clone, `bin/pull-back.sh` takes the cell's newest capture with your Solution Console sign-in
(in the browser) and turns it into a branch and a pull request, with your own git credentials. The Solution Console's
**Local changes** tab shows the command for its cell:
```sh
bash /tmp/censhare-kit/bin/pull-back.sh --cell https://<cell>/solution-console/ [--capture] [--into <branch>]
```
A capture downloaded in that tab, or exported by an admin of the cell (**Export changes**, Settings › Customizations),
goes in with `--from capture-<cell>-<time>.zip` instead.
The guide says what it does, and what goes where from a test or prod cell.

## Without the Action
`bin/deliver.sh` is what the Action runs. Any CI can run it, with flags or with the same names as variables
(`CUSTOMER`, `PACKAGES_BUCKET`, `STAGE`, ...). It needs bash, git, jq, python3 and the AWS CLI, and Node for workflows:
```sh
bash /tmp/censhare-kit/bin/deliver.sh --customer <customer> --packages-bucket <bucket> --stage dev \
  --publisher-role <publisher role ARN>
```
`--publisher-role` signs in as the role with your CI's OIDC token, from the file in `AWS_WEB_IDENTITY_TOKEN_FILE`.
Without it, `deliver.sh` uses the AWS credentials already in the environment. `bin/deliver.sh --help` lists every flag.
Prod is never delivered this way either.

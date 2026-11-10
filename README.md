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

## Check your package first
`bin/validate.sh [folder]` runs the checks the cell runs on your package when it arrives, on your own checkout: no AWS,
no network, only python3. It prints each problem and exits 1 when the cell would refuse the package. The Action and the
GitLab template run it before they store anything, so a package that would be refused fails your pipeline instead:
```sh
git clone --depth 1 --branch <edition tag> https://github.com/entirely-workspace/hyperscaler-delivery.git /tmp/censhare-kit
bash /tmp/censhare-kit/bin/validate.sh .
```
A few checks need the cell and run only there: the censhare assets your variants replace, the customer's settings and
secrets, and packages already active in the cell.

## Without the Action
`bin/deliver.sh` is what the Action runs. Any CI can run it, with flags or with the same names as variables
(`CUSTOMER`, `PACKAGES_BUCKET`, `STAGE`, ...). It needs bash, git, jq, python3 and the AWS CLI:
```sh
bash /tmp/censhare-kit/bin/deliver.sh --customer <customer> --packages-bucket <bucket> --stage dev \
  --publisher-role <publisher role ARN>
```
`--publisher-role` signs in as the role with your CI's OIDC token, from the file in `AWS_WEB_IDENTITY_TOKEN_FILE`.
Without it, `deliver.sh` uses the AWS credentials already in the environment. `bin/deliver.sh --help` lists every flag.
Prod is never delivered this way either.

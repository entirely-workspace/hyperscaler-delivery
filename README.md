# Deliver to censhare HyperScaler

Your customization package goes from **your** git and CI to the censhare HyperScaler cells of the customer you work
for. censhare keeps no copy of your source. Each push stores the package once, by its digest, in the customer's
package store, and activates it in the cell of the stage the customer delegated to you: **dev**, or **test**.
Prod is never delivered by a pipeline. It runs only a package test accepted, once the customer approves it.

This kit is versioned with each censhare edition: use the tag of the edition your customer runs.

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

## Your package
`customization.json` names your vendor id, the package and the folder with your files:
```json
{ "vendor": "acme", "package": "pkg", "source": "censhare-Custom/censhare-Server" }
```
Only committed files are delivered, and only the tip of the branch: a re-run or a late run of an older push ends green
and delivers nothing, since a newer push is on its way.

## Without the Action
`bin/deliver.sh` is what the Action runs. Any CI that can sign in as the publisher role can run it with `CUSTOMER`,
`PACKAGES_BUCKET` and `STAGE` set. It needs bash, git, jq and the AWS CLI.

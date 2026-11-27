# Partner guide: delivering customizations to censhare HyperScaler

This guide is for partners who build censhare customizations, and for the customers they work for. It covers the
whole path: from a commit in your git to the customer's cells, and back out when something goes wrong. To set up your
repository, start from your git's example ([README.md](README.md)); every field, variable and command is in
[REFERENCE.md](REFERENCE.md).

## How it works
- **Your source stays with you.** You keep it in your own git and build with your own CI. censhare never receives a
  copy of your repository. It receives only the package your pipeline delivers.
- **Each package is stored once, by its digest**, in the customer's own package store. Every stage runs those exact
  bytes: dev, test and prod. Nothing is ever rebuilt between stages.
- **The customer decides who delivers what.** They delegate one repository and branch of yours to one package, for
  the stages they choose (dev, or dev and test). That delegation is the only thing your pipeline can use. No password
  or key is stored anywhere: your CI's own sign-in token proves which repository and branch is delivering.
- **Prod is never delivered by a pipeline.** The customer approves a package that test accepted, and puts it live
  themselves.

## Ways in, by what you have
| You have | Your way in |
|---|---|
| GitHub, with Actions | Copy [github/](github/README.md), rename the package, set the variables, and push. Each push to the delegated branch delivers. |
| GitLab on gitlab.com, with CI | Copy [gitlab/example/](gitlab/example/README.md), the same way. |
| Workflows and functions | Copy [automations/](automations/README.md), a repository of its own next to the customization's. |
| Another CI with OIDC sign-in to AWS | The same kit, without the Action: `bin/deliver.sh` with `--publisher-role` ([REFERENCE.md](REFERENCE.md#commands)). |
| No CI of your own | The customer can host the repository in AWS CodeCommit, in their own AWS account, where a ready-made pipeline delivers each push. Ask censhare to set it up with the customer ([codecommit/](codecommit/README.md)). |
| No delivery work on your side at all | censhare professional services can build and deliver the package for the customer, through the same path. |

**Not offered yet:**
- uploading a package by hand in the customer's administration;
- GitLab self-managed (your own GitLab server). It needs AWS to reach your GitLab's sign-in keys over the internet,
  and support for it on our side.

Until then, mirror the repository to gitlab.com or GitHub, or use CodeCommit.

## Getting started
1. **Agree on the package with the customer.** It needs:
   - your vendor id: lower-case letters, digits, `-` and `_`, starting with a letter or digit, for example `acme`
     (`censhare`, `hyperscaler`, `incoming`, `incoming-workflows`, `incoming-functions` and `workflows-deployer` are taken). censhare checks
     these when it sets up the delegation;
     `bin/validate.sh` checks only the characters;
   - a package name;
   - the folders it owns under `censhare-Custom/censhare-Server/`, for example `app/modules/acme`.

   A package may change only what it owns, and two packages can't own the same folder.
2. **Tell the customer which repository and branch delivers.** For GitHub that's `<owner>/<repository>`, for GitLab
   `<group>/<project>`, and in either case usually `main` for dev. A second branch, usually `test`, can deliver to test
   if the customer delegates test to you too.
3. **The customer asks censhare for the delegation.** You then get three values:
   - the customer id;
   - the package store (bucket);
   - the publisher role, for `main`.

   If test is delegated to you too, you get a second publisher role, for `test`. Each role can do one thing only:
   store your package and start that stage's activations. And only your repository and that branch can use it.
4. **Set the values as CI variables, then push:** `CENSHARE_CUSTOMER`, `CENSHARE_PACKAGES_BUCKET`,
   `CENSHARE_PUBLISHER_ROLE`, and `CENSHARE_PUBLISHER_ROLE_TEST` for `test`'s role. Set them before your first push,
   since the first push delivers. On GitLab, leave them unprotected unless the branch is protected: a protected
   variable is empty on any other branch. If the customer delegates its extra dev cells to you too, you also get
   `CENSHARE_DEV_CELLS_ROLE`. All of them, with where to set them, are in your example's README and in
   [REFERENCE.md](REFERENCE.md#variables). On CodeCommit there's nothing to set: the customer's pipeline has them.

## Delivering a change
- **Push to the delegated branch.** The pipeline:
  1. checks the package with the same checks the cell runs (`bin/validate.sh`);
  2. stores it once, by digest;
  3. activates it in the stage's cell;
  4. waits for the cell's answer.

  The job fails when the cell refuses the package, and it prints the cell's reason.
- **Check before you push**, on your own machine, with `bin/validate.sh .`. It needs no AWS and no network.
- **Workflows** from an automations repository (`workflows/workflows.json` with your vendor and package) go the same
  way, checked against the cell's deploy rules, stored, and activated in the stage's cell, which builds and deploys
  them; they go live at once, with no restart. A rollback is delivering the earlier commit again. The customer must
  allow workflows for your repository (`"types"` in its delegation, or for all of the customer's delegations); without it, the package is stored but the activation is
  refused (`AccessDenied` on `StartBuild`).
- **Functions** (`functions/functions.json` with your vendor, package and, per function, the container `image` your CI
  builds first, in any language, with Lambda's Runtime Interface Client; AWS's base images have it) go the same way,
  before the workflows of the same push. The kit checks each image is there, linux/arm64 and at most 10 GB, pushes it
  into your repository in censhare's ECR (scanned on push), then stores and activates the functions in the stage's
  cell, which refuses an image with critical scan findings and runs each other image by its digest. The customer must allow `functions` for your
  repository too. Build reproducibly, so a commit always gives the same images.
  An image can also come from your own registry, by digest: `"image": "ghcr.io/acme/asset-check@sha256:..."`. The kit
  pulls it for linux/arm64 with your job's own registry login, so sign in to that registry before the kit's step
  (`docker login`, or `docker/login-action`; on GitHub, `GITHUB_TOKEN` with `packages: read` reads GHCR). Your login
  stays in your CI: censhare never sees it and never contacts your registry. A tag is refused: a tag can move, a digest
  cannot. One `functions.json` may mix both kinds.
  **From CodeCommit**, with no CI of your own to build the images (#1526): the customer deploys the CodeCommit template
  with `Functions=yes`, and its build builds each image you name plainly (`"image": "checks"`) from `functions/checks/`
  (its `Dockerfile`), for linux/arm64, after `functions/build.sh` if you have one (to package a Java function, say), then
  goes on as above. Start each `Dockerfile` from AWS's Lambda base images on `public.ecr.aws`
  (`public.ecr.aws/lambda/python`, `…/java`, `…/nodejs`), not Docker Hub's (`python:…`, `node:…`): the build
  pulls anonymously from shared addresses, and Docker Hub's rate limit can then fail a delivery (429). Workflows
  alone need no `Functions=yes`: they may call functions delivered another way, by their names in a
  `functions.json` at the repository's root.
  A function workflows call needs no `triggers`: a workflow calls it directly (`lambda:invoke` on
  `${function:<name>}`, docs/FUNCTIONS-CONTRACT.md §2). To let callers outside the workflows reach it too (censhare,
  a person, another system), add `"triggers": [{ "type": "http", "path": "/solution/functions/<route>" }]`:
  it answers at `POST https://<cell>/solution/functions/<route>`, your cell's own address, to a person's or an
  automation's token, and gets
  API Gateway's HTTP event (docs/FUNCTIONS-CONTRACT.md, "Over HTTP").
  To run it on censhare's events or on a schedule, add an `event` or `schedule` trigger:
  `{ "type": "event", "detailTypes": ["asset.changed"], "filter": { "type": ["product."], "domain": ["root.marketing."] } }`
  runs it for each change of a product asset in that domain (the filter is applied before your function runs, so other
  changes cost nothing), and `{ "type": "schedule", "cron": "0 2 * * ? *", "timezone": "Europe/Berlin" }` every night
  at 2 in Berlin. The detail types and filter members are censhare's event catalogue's (docs/EVENTS.md); a value of
  `type` or `domain` ends with a dot, `{ "prefix": "root.marketing." }` takes a whole subtree. Your function gets the
  same HTTP event as on a route, with the event (or the schedule's message) as its body and a token of the cell's
  workflows' login, and runs as the workflows do (docs/FUNCTIONS-CONTRACT.md, "On an event or a schedule"). A message
  may come twice, so make the work safe to repeat. It shares that login with the cell's workflows, so neither starts
  the other on a change it made: a change your function makes starts no workflow, and a workflow's change does not start
  your function. Its own changes don't start it again (set `"includeOwnWrites": true`
  if they should; `asset.deleted`, `relation.*` and `masterdata.changed` don't say who made a change, so a trigger on
  them needs `"includeOwnWrites": true`, and your function must not cause them itself). A call that fails, or answers
  400 or more, is tried five times, then kept in the function's
  dead-letter queue, which pages the cell's operators; ask them to send it back once your fix is delivered. So answer
  2xx for an event your function skips or cannot act on (an asset deleted a second later): only a retry that can
  succeed should fail.
  To let a partner's system call it (a marketing tool, a DAM, a PIM, anything without a censhare login), add
  `{ "type": "webhook", "path": "/solution/hooks/<route>" }`: it answers at `POST https://<cell>/solution/hooks/<route>`
  to calls signed with the function's secret, as [Standard Webhooks](https://www.standardwebhooks.com) signs them
  (`webhook-id`, `webhook-timestamp`, `webhook-signature`; libraries exist for most languages). An unsigned call, a wrong
  signature, one older than five minutes, or a `webhook-id` with a `.` in it is refused with 401 before your function
  runs. The secret is set on each
  cell, never in your repository: the customer's admin generates it in the Solution Console (Environment values,
  "Webhook secrets") and gives it to the partner, or pastes the one the partner's tool made, for each cell apart
  (docs/FUNCTIONS-ON-LAMBDA.md, "Webhook triggers"). Each webhook gets a secret of its own, never one used on another:
  the signature covers the id, the time and the body but not the address, so a call signed for one webhook would be
  accepted by the other within those five minutes. Your function gets the same HTTP event as on a route, the
  partner's body as it came and a token of the cell's workflows' login, and its answer goes back to the partner. The
  same call may come twice within those five minutes: `webhook-id` tells a repeat (a function on the censhare Java
  runtime gets the body alone, which must be JSON, so it tells a repeat by the body). Whoever has the secret can call your
  function with any body, and it runs with the workflows' rights: check the body and do only what the webhook is for.
  A partner with its own login (an OpenID Connect issuer: Okta, Entra ID, Auth0, Cognito ...) can call with its token
  instead of a secret: add `"auth": "jwt", "issuer": "<its issuer>", "audience": "<what its tokens are for>"` and, if
  its tokens carry one, `"scope": "<the scope to require>"`. Nothing is kept on the cell. The partner's tokens must live
  60 minutes or less: some issuers' defaults are longer (check the access-token lifetime of the partner's app in Entra
  ID or Auth0), and a longer one is refused with the same 401 as any other (docs/FUNCTIONS-ON-LAMBDA.md, "Webhook
  triggers").
  A workflow can be started by a webhook too: in `workflows/workflows.json`, give the flow
  `"trigger": { "type": "webhook", "path": "/solution/hooks/<route>" }` (or `"auth": "jwt"` as above). The call is
  checked the same way; the partner is answered 202 with the run's name at once, and the run gets the partner's JSON
  body as `$.detail` and the `webhook-id` as `id` (with a partner's login, an id made of the caller and the
  `webhook-id`), so `dedupe` works as for an event. The same `webhook-id` sent again
  starts no second run. A path is one function's or one flow's, never both.
  To remove a function that a deployed workflow calls, remove the calls first, in a push that still has the function,
  then the function in a later push. The functions go first, so a push that drops both is refused.
  On test, the workflows of a commit wait until test has taken your functions as of the last commit that changed them,
  so a push that only changes workflows doesn't wait for functions nobody promotes. "Changed" means anything outside
  `workflows/` by default; set `FUNCTIONS_PATHS` (git paths, for example `functions src`) in your CI to name what the
  functions are built from. This needs your history: the GitHub examples check out with `fetch-depth: 0`. A shallow clone
  works too, but then every push's workflows wait for that push's functions.
- **When it takes effect.** By default, the cell takes the package at its next restart (`next-boot`). `now` restarts
  the customer's server straight away, so it needs a reason, which is kept in the cell's record. Warn the people
  working on that cell before you use it, also on dev and test. Workflows go live as soon as the cell has deployed
  them, with no restart: `activate` does not apply to them. They are delivered to dev and test; prod comes later.
- **Only the tip of the branch is delivered.** A re-run of an older push, or a run that a newer push overtook, ends
  green and delivers nothing. The newer push is on its way.
- **The result** shows in your pipeline. The customer's chosen contacts also get an email for each activation.

## Extra dev cells
A customer may have extra dev cells besides its dev stage, for example one per developer or per feature. Each one
follows a repository and a branch that its developer chooses in that cell's Solution Console (Deployments tab).
- **Push to any branch.** The kit's second pipeline (`deliver-dev-cells.yml` on GitHub, the `deliver-dev-cells` job on
  GitLab) delivers the push to every extra dev cell that follows that repository and branch, and activates it at
  once. A branch that no cell follows ends green, and nothing is delivered.
- **What it needs from the customer:** a delegation to the extra dev cells for your repository. Its role is
  `CENSHARE_DEV_CELLS_ROLE`. It trusts any branch of your repository, but it may only store the package and read which
  cell follows which branch. Each extra dev cell has its own role, which trusts only the branch the cell follows, and
  only that role can start the cell. Your pipeline's OIDC token proves the branch, so nothing here can be pointed at a
  cell by editing the pipeline on another branch. GitHub Enterprise Server and GHE.com work the same way, once the
  customer's delegation names your host.
- **Nothing is promoted from an extra dev cell.** Test and prod still take what dev accepted.
- **"does not trust ... save its source again"**: the cell's record says it follows your branch, but its role does
  not trust that branch. The customer's developer saves the cell's source again in its Solution Console.

## From dev to test to prod
| Stage | Who moves a package there | What it takes |
|---|---|---|
| dev | your pipeline, on a push to `main` | a package that passes the check |
| test | your pipeline on `test`, if test is delegated to you; otherwise the customer's developer, in the Solution Console | **a package dev already accepted**, for the same commit, if the customer has a dev stage: deliver to dev first, then push the same commit to `test`. Without a dev stage, test takes the package as it is. Either way, only a build of the customer's release refs (`main`, unless the customer names others) reaches test; a customer who delegates test to your `test` branch lists both. A customer may also list hotfix branches (`refs/heads/hotfix/*`): their builds reach test too, and the Solution Console marks them as not from `main` until `main` delivers the same code. |
| prod | the customer's release owner, in the Solution Console | a package test accepted, which the release owner approves and then puts live |

A promotion moves the same digest. What goes live in prod is byte for byte what test accepted.

What differs per stage is not in the package: a value it names (`parameters`, such as the SAP URL) is set on each
stage's cell by the customer, in the Solution Console's Environment values tab, before the version is promoted there.
A stage that lacks one refuses the version and keeps the one it runs.

## Hotfix
A hotfix takes the same path: dev, then test, then the customer's approval for prod. Only the speed differs, with
`now` and a reason where the cell allows it (it restarts the server, see above). Prod takes exactly the commit test
accepted. So build the fix on a commit that holds only what may go live: if `main` carries work that isn't ready,
revert it on `main` first.

## Rolling back
- **dev:** revert the change on the delegated branch and push. That delivers the reverted tip.
- **test:** the customer's developer promotes an earlier package, by its digest, in the Solution Console. Like any
  promotion to test, it must be one dev accepted (if the customer has a dev stage).
- **prod:** the customer's release owner rolls back to an earlier release in the Solution Console. Prod keeps every
  release it ran, and what each one replaced. A rollback is a promotion like any other: the earlier package must be
  one test accepted and the customer approved, or it is refused
  (`test has not accepted`, `the customer has not approved`).
- **A cell that won't start with its packages** can be booted without them by censhare (safe mode), while the package
  is fixed.

## Taking live changes back to git
People change a cell live: command configuration saved in the Admin Client, hotfolder rules saved on the Hotfolder
page. Those changes are in no package, so the next release doesn't carry them to the other cells, and nothing in
your git shows them. The cell's Settings › Customizations page says whether the cell is in sync with its release.

1. **An admin of the cell exports them**: **Export changes** on that page downloads `capture-<cell>-<time>.zip`, the
   changed files and `capture.json` (which release the cell runs, what changed). Secrets and environment values are
   never in it. The cell keeps each capture 30 days. The Solution Console's **Local changes** tab shows what differs
   now, captures and downloads: for the cell's admins and release owners on every stage, and for its developers on a dev
   cell, with no admin needed. The tab also shows the command below, ready to copy. The zip is yours: apply it to your
   package however you like, by hand or with the helper below.
2. **You pull them back**, optionally with the kit's helper, in a clean clone of the package's repository:
   `bash /tmp/censhare-kit/bin/pull-back.sh --cell https://<cell>/solution-console/ [--capture] [--into <branch>]`,
   the command the Local changes tab shows. It opens the cell's sign-in in your browser (the Solution Console's, with
   the same access as the tab), takes the cell's newest capture, and records the download under your name. `--capture`
   captures the cell first and takes that capture; without it, a newest capture the cell has changed since is refused.
   That check also sees a file edited again after the capture, by its content's digest, and names it; on a cell whose
   admin bridge is older it compares the files' names only, and says so. Before you sign in it checks with the cell's
   own sign-in that the address you gave is that cell's (a look-alike address is refused), and it names the API your
   sign-in goes to. Your sign-in stays in memory for the run and is never written to disk. With a zip you downloaded or
   exported, use `--from capture-<cell>-<time>.zip` instead. It:
   - starts a branch `pullback/<cell>/<vendor>/<package>/<yyyymmdd-hhmmss>` from the commit the cell runs, so the pull request holds
     only the live changes, and a later change to the same file on your branch is a conflict there, never lost. That
     commit must be on the branch the pull request goes into;
   - copies each file into your package's source folder, adds its folder to `owns`, and writes the hotfolder rules
     into `settings.ingest`. A folder in `owns` is replaced on every cell the package reaches: a file there that the
     package doesn't hold is removed, live edits made on a test or prod cell included. The pull request names each
     folder it adds;
   - checks the package (`bin/validate.sh`), commits and pushes with your own git credentials. On CodeCommit it
     opens the pull request with your AWS credentials (`aws codecommit create-pull-request`, with the region and
     profile of origin's address). On GitHub or GitLab, hosted or self-hosted, and any other host, the repository is
     yours to drive: it names the branch and shows how to open the pull request, the web page (on a GitHub or a
     GitLab) and the `gh pr create … --fill` or `glab mr create … --fill` command, and you open, review and merge it
     there. If it stops
     on the way, your clone is back where it was, except when the package check fails: then the branch stays checked
     out with the files, uncommitted, for you to fix.
3. **Merge and deliver** as usual. From then on your package owns those paths, and the cell is in sync again.

Where the pull request goes: from a dev cell, into `--into`, else, with `--cell`, the branch the cell follows (the
one its deliveries come from, as its Deployments tab shows it), else the default branch. From a test or prod cell, it
always goes into the default branch, by a pull request. `--package` picks the package when the
cell runs several, and one capture goes into one package; `--no-push` only commits. censhare never writes to your git.
Master data (`app/masterdata/`) is never pulled back: a package carries it only with `"touchesMasterdata": true`.

**Workflows and functions changed live** (a state machine saved in the AWS console or Workflow Studio, a function's
memory or timeout changed in the Lambda console) are on the same tab's **Workflows** side. In your clone of the
automations repository, the kit's `bin/pull-back-workflows.sh` takes them back:
`bash /tmp/censhare-kit/bin/pull-back-workflows.sh --cell https://<cell>/solution-console/ [--into <branch>]`.
- It writes them into the files `workflows.json` names and into `functions/functions.json`, on a branch from the
  commit the cell was delivered from, with the cell's own values turned back into placeholders: `${function:<name>}`,
  `${bus}`, `${censhare}`, `${censhare-login}`.
- An image or an environment variable changed live is named, not taken back: the image is built from your repository.
- A function's `concurrency` changed in the AWS console is not seen at all: Lambda keeps no delivered value to compare
  with. Change it in `functions.json`; the next delivery sets it back to that.

## When something fails
| You see | It means | Do |
|---|---|---|
| The check fails with reasons (for example `owns nothing`) | The cell would refuse the package | Fix what it says. Nothing was stored. |
| `no longer says what differs` (pull-back) | The cell changed after its newest capture | Run it again with `--capture`, or capture in the Local changes tab first |
| `is not a cell of the sign-in it names` (pull-back) | The address isn't one the cell's sign-in knows: a mistyped or look-alike address | Use the address the Local changes tab copies |
| `has no solution-console/cli.json` (pull-back) | The address is not a cell's Solution Console, or its console is older than `--cell` | Check the address the Local changes tab shows; until then, download the capture there and use `--from` |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | This repository, branch or role isn't the delegated one | Check that the branch is the delegated one and the role variable is that branch's role |
| `Set the CI/CD variable` (GitLab) or `Set the repository variable` (GitHub), naming `CENSHARE_PUBLISHER_ROLE`, or `CENSHARE_PUBLISHER_ROLE_TEST` on `test` | That branch's role variable is missing, or empty on this branch | Set it. On GitLab, check that it isn't protected. |
| `dev has not accepted` | A promotion to test of a package dev never accepted | Deliver that commit to dev first |
| Test refuses the package as no release branch's build | Test takes only builds of the customer's release refs (`main` unless the customer names others) | Merge to `main`, deliver, and promote that build |
| The Solution Console shows no "on main" or "not on main" beside your build | The kit records it only when your checkout has `origin/main` and is not shallow | Fetch `main` with full history before the kit's step (GitHub: `actions/checkout` with `fetch-depth: 0`); it is shown as reported, and changes nothing about what reaches test |
| The cell refused the package, with a reason | The cell's own checks refused it: a collision with another package, a missing setting or a missing asset | Fix it and push again. Ask the customer if it's their setting. |
| Green, but "superseded" | A newer push is delivering | Nothing to do |
| `runs several packages` (pull-back) | The cell runs more than one package | Name the one the changes belong in with `--package` |
| `can be owned only as a file` (pull-back) | A live switch of the EventBridge publisher; a package can't own those files yet | Switch it on in your package's copy by hand, or on each cell in the Admin Client |
| `would carry other commits too` (pull-back) | The commit the cell runs isn't on the branch the pull request would go into | Name the branch the cell delivers from with `--into` |
| `is master data` or `would own the whole of` (pull-back) | A live change to master data, or to a file directly in `app/masterdata` or `app/assets` | Add it to your package by hand |
| `is in no path a package may own` or `which no package may own` (pull-back) | A live change to what stays the cell's (its configuration, services, the image's own files) | Nothing to pull back: ask censhare if it must change |
| `set PACKAGE_TYPE to censhare-custom or workflows` | The repository has both `customization.json` and `workflows/workflows.json` | Set `PACKAGE_TYPE` to the one this pipeline delivers |
| The functions check says `functions/functions.json` has no "vendor" and "package" | `functions/functions.json` now means "deliver these functions", which needs both | Add the names censhare gave you |
| `is not there: build it before the kit's step` | Your CI didn't build that image, or under another name | Build it first, under the name `image` gives |
| `could not pull` and `sign in to its registry before the kit's step` | The job has no login that can read that registry, or the digest isn't there | Sign in before the kit's step, and check the digest in `image` |
| `a registry reference needs a digest` | `image` names a registry image by tag | Use its digest: `<registry>/<name>@sha256:...` |
| `the cells run linux/arm64` | The image was built for another platform | Build with `docker build --platform linux/arm64` |
| `Lambda takes at most 10 GB` | The image is larger than Lambda takes | Make the image smaller |
| `was pushed as an image index` | Your build pushed a list of images (buildx's default provenance), and Lambda runs a single image | Build with `docker buildx build --platform linux/arm64 --provenance=false` |
| The cell refused the functions, naming critical findings in ECR's scan | ECR's scan found a critical vulnerability in the image | Update the base image or the package it names, and push again |
| The cell refused the functions: ECR's scan of an image ended other than complete (such as UNSUPPORTED_IMAGE or FAILED) | ECR couldn't scan the image, for example one with no package list ECR knows, such as a `scratch` or distroless base | Build it on a base image ECR can scan, such as an AWS Lambda base image |
| The activation failed: `has not ended; activate again in a few minutes` | ECR's scan of the image hadn't ended within 5 minutes, or never will for a base ECR can't scan | Activate again in a few minutes; if it keeps failing, build on an AWS Lambda base image |
| The cell refuses functions.json: it leaves out a function the cell's deployed workflows still call | A workflow the cell runs calls a function this push removes | Push the workflows without the call first (keep the function), then remove the function |
| `already; this build` or `another run stored this commit first` | This commit was stored before, from another build of it | Nothing to do: the first package is the commit's. A fixed build time avoids a second build |

## If the customer revokes your delegation
No activation of yours starts again, and no package you stored reaches a cell, whoever promotes it. Your pipeline may
still sign in and store until censhare's next deploy removes the role, but nothing it stores goes anywhere. To deliver
again, the customer asks censhare for a new delegation.

## For customers: where the source should live
Keep your customization's source in a repository **you** own, and give your partner access to it. Changing partners
then means changing who has access, not moving the code. The delegation names the repository and branch, so you
decide which ones may deliver. You can revoke one at any time: in the Solution Console once your cells run it, or by
asking censhare.

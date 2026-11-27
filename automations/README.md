# Your censhare automations, on GitHub

Copy this folder into a new GitHub repository of yours. It holds workflows that react to censhare's events and the
functions they call, and delivers both from GitHub Actions to the customer's cells, without a restart. This is a
repository of its own, next to your customization's (the kit's `github/`). From the `automations/` folder of
the censhare partner kit v2026.11.27-a09bd908.

```
workflows/workflows.json         which workflows, the event that starts each one, its timeout
workflows/<name>.asl.json        each workflow's definition (a Workflow Studio export)
functions/functions.json         which functions, their image, memory, timeout and concurrency
functions/<image>/Dockerfile     each function's image, with its code next to it
.github/workflows/deliver.yml    main → dev, test → test; the kit builds the images first
```

`workflows/example` and `functions/hello` are placeholders, so the first push delivers: the example workflow calls
`hello`, and only a `custom.example` event starts it, which nothing sends. Replace them with your own.

## 1. Make it yours
- In `workflows/workflows.json` and `functions/functions.json`, set `vendor` to the vendor id censhare gave you and
  `package` to your package's name.
- A **function** is a Lambda container image, in any language, built for linux/arm64. Give it a folder
  `functions/<image>/` with its code and a `Dockerfile` from one of AWS's Lambda base images on `public.ecr.aws`
  (`public.ecr.aws/lambda/python`, `…/java`, `…/nodejs`), and an entry in `functions/functions.json` whose `image` is
  the folder's name: lower case letters, digits, `.`, `_` and `-`. The pipeline has the kit build each one
  (`BUILD_IMAGES`). What the images need that a commit doesn't hold (a Java build) goes in `functions/build.sh`, which
  runs first.
- A **workflow** calls a function by name: `"FunctionName": "${function:<name>}"` in a `Task` state
  (see `workflows/example.asl.json`). The cell fills in the function when it deploys the workflow.

The fields are in `REFERENCE.md` of the kit.

## 2. Set the variables
The customer gives you these values when they delegate your repository, and must allow workflows and functions for it.
Set them in **Settings → Secrets and variables → Actions → Variables** (none of them is a secret).

| Variable | Value | Needed |
|---|---|---|
| `CENSHARE_CUSTOMER` | the customer id | always |
| `CENSHARE_PACKAGES_BUCKET` | the package store | always |
| `CENSHARE_PUBLISHER_ROLE` | the publisher role for `main` | always |
| `CENSHARE_PUBLISHER_ROLE_TEST` | the publisher role for `test` | if the customer delegated test to you |

## 3. Push
`main` delivers to dev, and `test` to test if the customer delegated it. Each push builds the images, then delivers the
functions first and the workflows that call them second.

## 4. Read the run
Open **Actions → Deliver to censhare**. A green run means both were stored and the cell deployed them. Workflows start
on censhare's events, which are off on a new cell: the customer switches on the Event Forwarder in the Admin Client.

## 5. When the run is red
The reason is in the run's log. The common ones:
- **`there is no functions/<image>/Dockerfile to build it from`**: an `image` in `functions.json` has no folder of that
  name, or the folder has no `Dockerfile`.
- **`is not a folder name next to functions/functions.json`**: an `image` with upper case or other characters a
  folder name can't have. Rename the folder and the `image`.
- **`could not be built from functions/<image>`**: Docker's own error is just above it.
- **A workflow names a function `functions.json` doesn't list**: add the function, or fix the name.
- **`Set the repository variable …`** or **`Not authorized …`**: as for a customization (the kit's `github/`).

Check before you push, with no AWS. `validate.sh` checks one kind at a time: the workflows by default here, and the
functions with `PACKAGE_TYPE=functions`, which needs Docker with the image built for linux/arm64 (Docker Desktop
builds it):

```sh
git clone --depth 1 --branch v2026.11.27-a09bd908 https://github.com/entirely-workspace/hyperscaler-delivery.git /tmp/censhare-kit
python3 -m unittest discover -s functions/hello
docker build --platform linux/arm64 -t hello functions/hello
bash /tmp/censhare-kit/bin/validate.sh .
PACKAGE_TYPE=functions bash /tmp/censhare-kit/bin/validate.sh .
```

## On GitLab or CodeCommit
- **GitLab:** the kit's GitLab template delivers workflows, but not functions yet: it runs without Docker, which
  building and pushing the images needs. For a repository with workflows only, start from the kit's
  `gitlab/example/.gitlab-ci.yml` as it is: the kit sees `workflows/workflows.json` and delivers the workflows.
  Deliver functions from GitHub for now, or ask censhare.
- **CodeCommit:** the customer's CodeBuild builds the images for you, once the customer's delivery stack is deployed
  with functions on (the kit's `codecommit/`).

Everything else, from promotion to rollback, is in `GUIDE.md` of the kit.

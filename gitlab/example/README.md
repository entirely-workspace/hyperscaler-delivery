# Your censhare customization, on GitLab

Copy this folder into a new project of yours on gitlab.com. It holds your censhare customization package and delivers
it, from GitLab CI, to the censhare HyperScaler cells of the customer you work for. censhare never gets a copy of your
repository, only the package each push delivers. From the `gitlab/example/` folder of the censhare partner kit
v2026.11.27-a09bd908.

```
customization.json                        what the package is, and the folders it owns
censhare-Custom/censhare-Server/app/...   your files, as in censhare-Custom today
.gitlab-ci.yml                            main → dev, test → test, any branch → the extra dev cells (optional)
```

`.gitlab-ci.yml` includes the kit's template at this kit's version, `gitlab/deliver.gitlab-ci.yml`, and extends it.
GitLab self-managed is not supported yet: mirror the project to gitlab.com or GitHub (`GUIDE.md`, "Ways in").

## 1. Make the package yours
- In `customization.json`, set `vendor` to the vendor id censhare gave you and `package` to your package's name.
- Rename `censhare-Custom/censhare-Server/app/modules/your-vendor/` to your vendor id and put your files there.
- List every folder your package owns in `owns`. Files outside them are never delivered.
- Set `touchesMasterdata` to `true` if you deliver masterdata. Set `activation` to `refresh` only if nothing needs a
  restart (no jars, `.ts` or `.scss`).

The fields are in `REFERENCE.md` of the kit.

## 2. Set the variables
The customer gives you these values when they delegate your project. Set them in **Settings → CI/CD → Variables**.
None of them is a secret, and no key is stored: GitLab's OIDC token proves which project and branch is delivering.
Leave them **unprotected** unless the branch is protected: a protected variable is empty on any other branch.

| Variable | Value | Needed |
|---|---|---|
| `CENSHARE_CUSTOMER` | the customer id | always |
| `CENSHARE_PACKAGES_BUCKET` | the package store | always |
| `CENSHARE_PUBLISHER_ROLE` | the publisher role for `main` | always |
| `CENSHARE_PUBLISHER_ROLE_TEST` | the publisher role for `test` | if the customer delegated test to you |
| `CENSHARE_DEV_CELLS_ROLE` | the role for the customer's extra dev cells | if the customer delegated them to you |

Optional: `CENSHARE_ACTIVATE` (`next-boot`, or `now` with `CENSHARE_REASON`) and `CENSHARE_REGION` (`eu-central-1`).
`now` restarts the cell's server. Don't set it on the project, where it would restart the server on every push: set it
for one push only, with GitLab's push options:

```sh
git push -o ci.variable="CENSHARE_ACTIVATE=now" -o ci.variable="CENSHARE_REASON=<why now>"
```

Don't set `CENSHARE_STAGE`: each job sets it (`dev` or `test`). Set the others before your first push: the first push
delivers.

## 3. Push
| Branch | Job | Delivers to |
|---|---|---|
| `main` | `deliver-dev` | dev |
| `test` | `deliver-test` | test, if the customer delegated test to you |
| any branch | `deliver-dev-cells` | the extra dev cells that follow that branch, at once (with `CENSHARE_DEV_CELLS_ROLE`) |

Prod is never delivered by a pipeline: the customer approves the package that test accepted.

## 4. Read the job
Open **Build → Pipelines** and the job of your branch. A green job means the package was stored and the cell answered,
for example `dev: published (build SUCCEEDED)`. With `next-boot` (the default) the package goes live at the cell's
next restart.

## 5. When the job is red
The reason is in the job's log, not in the cell's Logs page:
- **The package check failed** (`refused - … error(s)`, then `nothing was stored`): the cell would refuse the package,
  for example a folder in `owns` that a package may not own. Fix what it names and push again. Nothing reached the cell.
- **`Set the CI/CD variable …`**: that branch's role variable is missing, or protected and so empty on this branch.
- **`Not authorized to perform sts:AssumeRoleWithWebIdentity`**: this project or branch isn't the one the customer
  delegated, or the variable holds another branch's role.
- **The cell refused the package, with a reason**: fix it and push again. Ask the customer if it's their setting.

Check the package on your own machine before you push, with no AWS (only python3):

```sh
git clone --depth 1 --branch v2026.11.27-a09bd908 https://github.com/entirely-workspace/hyperscaler-delivery.git /tmp/censhare-kit
bash /tmp/censhare-kit/bin/validate.sh .
```

Everything else, from promotion to rollback and taking live changes back to git, is in `GUIDE.md` of the kit.

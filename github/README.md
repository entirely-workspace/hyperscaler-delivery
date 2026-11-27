# Your censhare customization, on GitHub

Copy this folder into a new GitHub repository of yours. It holds your censhare customization package and delivers it,
from GitHub Actions, to the censhare HyperScaler cells of the customer you work for. censhare never gets a copy of your
repository, only the package each push delivers. From the `github/` folder of the censhare partner kit
v2026.11.27-a09bd908.

```
customization.json                        what the package is, and the folders it owns
censhare-Custom/censhare-Server/app/...   your files, as in censhare-Custom today
.github/workflows/deliver.yml             main → dev, test → test
.github/workflows/deliver-dev-cells.yml   any branch → the extra dev cells that follow it (optional)
```

## 1. Make the package yours
- In `customization.json`, set `vendor` to the vendor id censhare gave you and `package` to your package's name.
- Rename `censhare-Custom/censhare-Server/app/modules/your-vendor/` to your vendor id and put your files there.
- List every folder your package owns in `owns`. Files outside them are never delivered.
- Set `touchesMasterdata` to `true` if you deliver masterdata. Set `activation` to `refresh` only if nothing needs a
  restart (no jars, `.ts` or `.scss`).

The fields are in `REFERENCE.md` of the kit.

## 2. Set the variables
The customer gives you these values when they delegate your repository. Set them in **Settings → Secrets and variables
→ Actions → Variables** (variables, not secrets: none of them is a secret, and no key is stored).

| Variable | Value | Needed |
|---|---|---|
| `CENSHARE_CUSTOMER` | the customer id | always |
| `CENSHARE_PACKAGES_BUCKET` | the package store | always |
| `CENSHARE_PUBLISHER_ROLE` | the publisher role for `main` | always |
| `CENSHARE_PUBLISHER_ROLE_TEST` | the publisher role for `test` | if the customer delegated test to you |
| `CENSHARE_DEV_CELLS_ROLE` | the role for the customer's extra dev cells | if the customer delegated them to you |

Set them before your first push: the first push delivers.

## 3. Push
| Branch | Delivers to |
|---|---|
| `main` | dev |
| `test` | test, if the customer delegated test to you |
| any branch | the extra dev cells that follow that branch, at once (with `CENSHARE_DEV_CELLS_ROLE`) |

Prod is never delivered by a pipeline: the customer approves the package that test accepted.

## 4. Read the run
Open **Actions → Deliver to censhare**. A green run means the package was stored and the cell answered, for example
`dev: published (build SUCCEEDED)`. With `next-boot` (the default) the package goes live at the cell's next restart.
To make it live at once, run the workflow by hand (**Run workflow**) with `now` and a reason.

## 5. When the run is red
The reason is in the run's log, not in the cell's Logs page:
- **The package check failed** (`refused - … error(s)`, then `nothing was stored`): the cell would refuse the package,
  for example a folder in `owns` that a package may not own. Fix what it names and push again. Nothing reached the cell.
- **`Set the repository variable …`**: that branch's role variable is missing (step 2).
- **`Not authorized to perform sts:AssumeRoleWithWebIdentity`**: this repository or branch isn't the one the customer
  delegated, or the variable holds another branch's role.
- **The cell refused the package, with a reason**: fix it and push again. Ask the customer if it's their setting.

Check the package on your own machine before you push, with no AWS (only python3):

```sh
git clone --depth 1 --branch v2026.11.27-a09bd908 https://github.com/entirely-workspace/hyperscaler-delivery.git /tmp/censhare-kit
bash /tmp/censhare-kit/bin/validate.sh .
```

Everything else, from promotion to rollback and taking live changes back to git, is in `GUIDE.md` of the kit.

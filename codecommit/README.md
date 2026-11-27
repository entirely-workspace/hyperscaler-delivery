# Your censhare customization, on AWS CodeCommit

For a partner with no CI of their own. The customer hosts the repository in AWS CodeCommit, in their own AWS account,
with a pipeline (AWS CodeBuild) that delivers each push. censhare sets both up with the customer. There's nothing to
copy from this folder: you get a repository that is ready to push to. From the `codecommit/` folder of the
censhare partner kit v2026.11.27-a09bd908.

The package is the same as on GitHub or GitLab (the kit's `github/`). Only who runs the pipeline differs:

| | GitHub or GitLab | CodeCommit |
|---|---|---|
| Who hosts the repository | you | the customer, in their AWS account |
| Who runs the pipeline | your CI, with the kit's Action or template | CodeBuild, in the customer's account |
| What you set up | the CI variables | nothing: the customer and censhare do |
| How you sign in to git | your own git account | AWS credentials the customer gives you |

## What you get
- The repository's name and region, and the branch that delivers, for example `main` to dev.
- AWS credentials or a role in the customer's account that can push to that repository. Ask the customer.

The repository already holds a package to start from:

```
customization.json                        what the package is, and the folders it owns
censhare-Custom/censhare-Server/app/...   your files, as in censhare-Custom today
tools/                                    the kit's scripts the pipeline runs: don't edit them
```

## 1. Clone
With AWS's git helper `git-remote-codecommit` (or AWS's credential helper for HTTPS), and your AWS credentials:

```sh
pip install git-remote-codecommit
git clone --branch <branch> codecommit::<region>://<repository>
```

## 2. Make the package yours
- `customization.json` already names your `vendor` and `package`. Add every folder your package owns to `owns`. Files
  outside them are never delivered.
- Put your files under `censhare-Custom/censhare-Server/`, in the owned folders, as in censhare-Custom today.
- Set `touchesMasterdata` to `true` if you deliver masterdata.

The fields are in `REFERENCE.md` of the kit.

## 3. Push the delivering branch
Each push to that branch starts CodeBuild, which checks the package, stores it once, by its digest, in the customer's
package store, and activates it in the branch's stage. There are no variables to set: the pipeline has them.

## 4. Read the build
In the AWS console of the customer's account, open **CodeBuild → Build projects**, the delivery project the customer
names, and its newest build. A green build means the package was stored and the cell answered, for example
`dev: published (build SUCCEEDED)`. With `next-boot` (the default) the package goes live at the cell's next restart.

## 5. When the build is red
The reason is in the build's log, not in the cell's Logs page:
- **The package check failed** (`refused - … error(s)`, then `nothing was stored`): the cell would refuse the package,
  for example a folder in `owns` that a package may not own. Fix what it names and push again. Nothing reached the cell.
- **The cell refused the package, with a reason**: fix it and push again. Ask the customer if it's their setting.

Check the package on your own machine before you push, with no AWS (only python3), with the kit's check the
repository already has in `tools/`:

```sh
bash tools/validate.sh .
```

## Workflows and functions
They're in a second CodeCommit repository, with `workflows/` and `functions/` (the kit's `automations/` shows both).
CodeBuild builds the functions' images for you there, so you need no Docker, once the customer's delivery stack for
that repository is deployed with functions on: ask the customer if a build says Docker is needed. Push its delivering
branch the same way.

Everything else, from promotion to rollback, is in `GUIDE.md` of the kit.

# Deliver to censhare HyperScaler

Your censhare customization goes from **your** git and CI to the censhare HyperScaler cells of the customer you work
for. censhare keeps no copy of your source: each push stores your package once, by its digest, in the customer's
package store, and activates it in the cell of the stage the customer delegated to you (dev, or test). Prod is never
delivered by a pipeline: the customer approves it.

Use the kit's tag for the edition your customer runs; ask censhare which one. `VERSION` names this copy of the kit.

## Which git do you use?
One folder per git. Copy yours into your own repository: it's complete, with one pipeline and a README of five
steps (make the package yours, set the variables, push, read the run, what to do when it's red). Copy nothing else:
your pipeline fetches the kit's scripts at the version it names.

| You use | Copy | Start here |
|---|---|---|
| **GitHub** | `github/` | [github/README.md](github/README.md) |
| **GitLab** (gitlab.com) | `gitlab/example/` | [gitlab/example/README.md](gitlab/example/README.md) |
| **AWS CodeCommit**, no CI of your own: the customer hosts the repository, censhare sets it up | nothing | [codecommit/README.md](codecommit/README.md) |
| **Workflows and functions** (automations), on GitHub | `automations/` | [automations/README.md](automations/README.md) |
| **Another CI** with OIDC sign-in to AWS | nothing | `bin/deliver.sh`, in [REFERENCE.md](REFERENCE.md#commands) |

GitLab self-managed isn't supported yet: mirror to gitlab.com or GitHub, or use CodeCommit.

## Before your first push
1. Agree with the customer on your vendor id, the package name, and the folders it owns.
2. Tell the customer which repository and branch delivers (usually `main` for dev, `test` for test).
3. The customer asks censhare for the delegation, and gives you the values your pipeline needs: the customer id, the
   package store and a publisher role per branch.
4. Set them as your CI's variables (your example's README says where), then push.

## What else is here
To read:

| | |
|---|---|
| [GUIDE.md](GUIDE.md) | How delivery works: dev → test → prod, hotfix, rollback, taking live changes back to git, what each failure means |
| [REFERENCE.md](REFERENCE.md) | Every `customization.json` field, every variable, the Action's inputs, the GitLab template and the commands |

What your pipeline runs. Don't copy it: it's fetched at the version your pipeline names.

| | |
|---|---|
| `action.yml` | The GitHub Action: `uses: entirely-workspace/hyperscaler-delivery@<kit version>` |
| `gitlab/deliver.gitlab-ci.yml` | The GitLab template the GitLab example includes |
| `bin/`, `lib/`, `docs/events/` | The scripts and checks the pipelines run. `bin/validate.sh` checks your package on your own machine, with no AWS |

**Copied the `starter/` folder from an older kit?** It's now `github/` and `gitlab/example/`, one CI each.
Your repository keeps working: nothing in it changes.

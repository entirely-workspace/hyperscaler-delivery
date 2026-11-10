# Your censhare customization

This repository is yours: it holds your censhare customization package and delivers it, from your own CI, to the
censhare HyperScaler cells of the customer you work for. censhare keeps no copy of your source. Copied from the
`starter/` folder of the censhare partner kit v2026.11.10-5175fe78.

## Make it yours
1. In `customization.json`, set `vendor` to the vendor id censhare gave you and `package` to your package's name.
2. Rename `censhare-Custom/censhare-Server/app/modules/your-vendor/` to your vendor id and put your files there, as
   in `censhare-Custom` today. List every folder your package owns in `owns`; nothing outside them is delivered.
   Set `touchesMasterdata` to `true` if you deliver masterdata, and `activation` to `refresh` only if nothing needs a
   restart (no jars, `.ts` or `.scss`).
3. Keep the pipeline for your CI and delete the other one: `.github/workflows/deliver.yml` (GitHub) or
   `.gitlab-ci.yml` (GitLab).
4. Set these variables from what the customer gives you: `CENSHARE_CUSTOMER`, `CENSHARE_PACKAGES_BUCKET`,
   `CENSHARE_PUBLISHER_ROLE` (`main`'s role), and `CENSHARE_PUBLISHER_ROLE_TEST` if the customer delegated `test` too:
   each delegated branch has its own role, which trusts that branch only (GitHub: Settings → Secrets and variables →
   Actions → Variables; GitLab: Settings → CI/CD → Variables). None of them is a secret: GitHub or GitLab vouch for
   your pipeline, no key is stored. If the branch's role is not set, the pipeline stops first and names the variable.

## Branches
| Branch | Delivers to |
|---|---|
| `main` | dev |
| `test` | test, only if the customer delegated test to you |

Each push stores the package once, by its digest, and activates it in the branch's stage. Only the tip of the branch
is delivered: a re-run of an older push ends green and delivers nothing. Prod is never delivered by a pipeline: the
customer approves the package test ran. The pipeline fails with the cell's reason when the cell refuses a package.

The guide: `GUIDE.md` of the partner kit, at the same version (wiring up the pipeline: its `README.md`).

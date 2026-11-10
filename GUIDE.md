# Partner guide: delivering customizations to censhare HyperScaler

This guide is for partners who build censhare customizations, and for the customers they work for. It covers the
whole path: from a commit in your git to the customer's cells, and back out when something goes wrong. For wiring up
your pipeline, see [README.md](README.md).

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
| GitHub, or GitLab on gitlab.com, with CI | Copy the kit's `starter/`, rename the package, set three variables (four if test is delegated too), and push. Each push to the delegated branch delivers. See [README.md](README.md). |
| Another CI with OIDC sign-in to AWS | The same kit, without the Action: `bin/deliver.sh` with `--publisher-role`. See README, "Without the Action". |
| No CI of your own | The customer can host the repository in AWS CodeCommit, in their own AWS account, where a ready-made pipeline delivers each push. Ask censhare to set it up with the customer. |
| No delivery work on your side at all | censhare professional services can build and deliver the package for the customer, through the same path. |

**Not offered yet:**
- uploading a package by hand in the customer's administration;
- GitLab self-managed (your own GitLab server). It needs AWS to reach your GitLab's sign-in keys over the internet,
  and support for it on our side.

Until then, mirror the repository to gitlab.com or GitHub, or use CodeCommit.

## Getting started
1. **Agree on the package with the customer.** It needs:
   - your vendor id: lower-case letters, digits, `-` and `_`, starting with a letter or digit, for example `acme`
     (`censhare`, `hyperscaler` and `incoming` are taken). censhare checks these when it sets up the delegation;
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
   variable is empty on any other branch.

## Delivering a change
- **Push to the delegated branch.** The pipeline:
  1. checks the package with the same checks the cell runs (`bin/validate.sh`);
  2. stores it once, by digest;
  3. activates it in the stage's cell;
  4. waits for the cell's answer.

  The job fails when the cell refuses the package, and it prints the cell's reason.
- **Check before you push**, on your own machine, with `bin/validate.sh .`. It needs no AWS and no network.
- **When it takes effect.** By default, the cell takes the package at its next restart (`next-boot`). `now` restarts
  the customer's server straight away, so it needs a reason, which is kept in the cell's record. Warn the people
  working on that cell before you use it, also on dev and test.
- **Only the tip of the branch is delivered.** A re-run of an older push, or a run that a newer push overtook, ends
  green and delivers nothing. The newer push is on its way.
- **The result** shows in your pipeline. The customer's chosen contacts also get an email for each activation.

## From dev to test to prod
| Stage | Who moves a package there | What it takes |
|---|---|---|
| dev | your pipeline, on a push to `main` | a package that passes the check |
| test | your pipeline on `test`, if test is delegated to you; otherwise the customer's developer, in the Control Center | **a package dev already accepted**, for the same commit, if the customer has a dev stage: deliver to dev first, then push the same commit to `test`. Without a dev stage, test takes the package as it is. |
| prod | the customer's release owner, in the Control Center | a package test accepted, which the release owner approves and then puts live |

A promotion moves the same digest. What goes live in prod is byte for byte what test accepted.

## Hotfix
A hotfix takes the same path: dev, then test, then the customer's approval for prod. Only the speed differs, with
`now` and a reason where the cell allows it (it restarts the server, see above). Prod takes exactly the commit test
accepted. So build the fix on a commit that holds only what may go live: if `main` carries work that isn't ready,
revert it on `main` first.

## Rolling back
- **dev:** revert the change on the delegated branch and push. That delivers the reverted tip.
- **test:** the customer's developer promotes an earlier package, by its digest, in the Control Center. Like any
  promotion to test, it must be one dev accepted (if the customer has a dev stage).
- **prod:** the customer's release owner rolls back to an earlier release in the Control Center. Prod keeps every
  release it ran, and what each one replaced. A rollback is a promotion like any other: the earlier package must be
  one test accepted and the customer approved, or it is refused
  (`test has not accepted`, `the customer has not approved`).
- **A cell that won't start with its packages** can be booted without them by censhare (safe mode), while the package
  is fixed.

## When something fails
| You see | It means | Do |
|---|---|---|
| The check fails with reasons (for example `owns nothing`) | The cell would refuse the package | Fix what it says. Nothing was stored. |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | This repository, branch or role isn't the delegated one | Check that the branch is the delegated one and the role variable is that branch's role |
| `Set the CI/CD variable` (GitLab) or `Set the repository variable` (GitHub), naming `CENSHARE_PUBLISHER_ROLE`, or `CENSHARE_PUBLISHER_ROLE_TEST` on `test` | That branch's role variable is missing, or empty on this branch | Set it. On GitLab, check that it isn't protected. |
| `dev has not accepted` | A promotion to test of a package dev never accepted | Deliver that commit to dev first |
| The cell refused the package, with a reason | The cell's own checks refused it: a collision with another package, a missing setting or a missing asset | Fix it and push again. Ask the customer if it's their setting. |
| Green, but "superseded" | A newer push is delivering | Nothing to do |

## If the customer revokes your delegation
No activation of yours starts again, and no package you stored reaches a cell, whoever promotes it. Your pipeline may
still sign in and store until censhare's next deploy removes the role, but nothing it stores goes anywhere. To deliver
again, the customer asks censhare for a new delegation.

## For customers: where the source should live
Keep your customization's source in a repository **you** own, and give your partner access to it. Changing partners
then means changing who has access, not moving the code. The delegation names the repository and branch, so you
decide which ones may deliver. You can revoke one at any time: in the Control Center once your cells run it, or by
asking censhare.

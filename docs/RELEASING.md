# Releasing

Releases are automatic and there is one series, `v0.1.<n>`. A commit on `main` that passes CI and changes `src/` or `install.ps1` becomes the next release. Nobody tags or edits a version by hand. The commit subjects are the release notes, so write each subject as `area: what the user now sees` ([CONTRIBUTING.md](../CONTRIBUTING.md)).

## What triggers a release

The CI run of a push to `main` ends with the job `Release` (`ci.yml`), after `CI ok` passed. It calls `publish.yml`, which runs inside the concurrency group `release`: one release at a time, whether it came from a push or from a manual run. Inside that lock `.github/scripts/plan-release.sh` decides:

1. Only the newest commit of `main` releases. If `origin/main` is not the commit CI tested, a newer push exists and its own run releases this commit too.
2. If a `v0.1.<n>` tag already points at the commit, that tag is used again (a rerun). Otherwise the commit is released only if `src/` or `install.ps1` differ from the last published release; with no published release, it is released.
3. The version is one above the highest `v0.1.<n>` tag, published or not, so a number is never reused. The tag is annotated, points at the tested commit and is never moved.

Then `publish.yml` builds the files, signs them, and `.github/scripts/publish-release.sh` creates the release as a **draft**, downloads it, checks it, and only then publishes it. Nobody sees a release that failed a check; a failed run leaves a tag and an invisible draft.

The checks on the draft: exactly four files (`install.ps1`, `ssh-paste.ps1`, `ssh-paste.cmd`, `SHA256SUMS`), the sums match, the files are the built ones, `ssh-paste.ps1` says the version of the tag (`$script:Version` is `0.0.0-dev` in the repository, and the build stamps the release copy), and every file has a valid build provenance attestation. `install.ps1` on the release installs the files of that release and checks them against its `SHA256SUMS`.

The newest published version gets the Latest mark, so `releases/latest/download/install.ps1` and `ssh-paste --update` always see it.

If CI of a newer push fails, nothing is released for it; the next green commit releases everything since the last published release, docs-only commits included.

## See a release

```sh
gh run list --workflow CI --branch main --limit 5     # the Release job is part of the CI run
gh release list --limit 5                             # a Draft here is a release that failed a check
gh release view v0.1.7
```

In the run, `Plan the release` prints why a commit was or was not released.

## Release by hand, and rerun

- **Manual run.** Actions, CI, Run workflow, on `main`. It runs CI and then the same release job for the newest commit of `main`; if nothing changed since the last release, it does nothing.
- **Rerun.** After a failure from outside the repository (GitHub outage, a late attestation), use "Re-run failed jobs" on the CI run. The run finds the tag, and the existing draft or release, and continues: a draft is created again and checked, a published release is only checked.
- **Fix forward.** If the cause is in the repository, fix it in a new commit. The next green commit releases.

Never move, delete or reuse a pushed tag. A draft you do not want (an old failed run) can be deleted in the GitHub UI or with `gh release delete vX.Y.Z`; leave the tag. To take a bad published release out of use, publish a fixed one: the highest version is Latest.

## Check what users get

```sh
mkdir verify && cd verify
gh release download vX.Y.Z
sha256sum -c SHA256SUMS
for f in install.ps1 ssh-paste.ps1 ssh-paste.cmd SHA256SUMS; do
  gh attestation verify "$f" -R xuing/ssh-please-paste-picture
done
```

`sha256sum -c` must print `OK` three times and `gh attestation verify` must succeed four times. The release run did the same, so a failure here means the release changed after publishing. On Windows:

```powershell
irm https://github.com/xuing/ssh-please-paste-picture/releases/latest/download/install.ps1 | iex
ssh-paste --version
```

`SHA256SUMS` only tells a user that the files match the release; the attestation tells them that `publish.yml` in this repository built them from a tagged commit.

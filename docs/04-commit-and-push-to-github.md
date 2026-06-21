# Step 04 — Commit the foundation and push to GitHub

## What we were trying to accomplish
Commit the Terraform foundation files plus the Step 03 docs, then publish the
repo to GitHub (account `Emmakices`) so the work is backed up and shareable.

## What we did, command by command

### 1. Commit the foundation (no Claude co-author, per request)
```powershell
git status --short        # see what's staged/untracked
git add -A                # stage everything non-ignored
git commit -m "Add Terraform foundation: versions, provider, variables ..."
```
- Files committed: `versions.tf`, `provider.tf`, `variables.tf`,
  `.terraform.lock.hcl`, `docs/03-terraform-foundation.md`, and the updated
  `docs/00-build-log.md`. The `.terraform/` cache did NOT appear because it's
  gitignored — confirming our ignore rules work.
- Commit: `8a8f70a` (6 files, 263 insertions).
- The commit message intentionally contains **no** `Co-Authored-By` trailer.

### 2. Connect the GitHub remote
A "remote" is a named link to a hosted copy of the repo; `origin` is the
conventional name for the primary one.
```powershell
git remote -v                                  # none configured yet
git remote add origin https://github.com/Emmakices/AWS-Datalake.git
git remote set-url origin https://github.com/Emmakices/AWS-Datalake.git  # fix owner
```

### 3. Push
```powershell
git push -u origin main
```
- `-u` sets `origin/main` as the upstream, so later `git push` / `git pull`
  need no arguments.
- Final result: `* [new branch] main -> main` — success.

## What went wrong (and the fixes)
We hit THREE auth/remote issues before the push worked. All are common.

1. **403 Permission denied.** First remote pointed at
   `Terraboganalytics/AWS-Datalake`, but the machine is authenticated as
   `Emmakices`, who lacks write access there. A `403` means "repo exists, you're
   not allowed." Fix: repoint the remote to the account we actually use.
   ```powershell
   git remote set-url origin https://github.com/Emmakices/AWS-Datalake.git
   ```

2. **404 Repository not found.** Right after repointing, the push failed because
   the new repo hadn't been created on GitHub yet (a `404`/"not found" means the
   repo isn't there — or is private and the login can't see it). Fix: create the
   empty repo under `Emmakices` on github.com/new (no README/》gitignore/license
   so the first push doesn't conflict).

3. **Transient 404 on first try after creating it.** Immediately retrying the
   push succeeded — the brand-new repo just needed a moment.

### How to read these errors
- **403** = authenticated but not authorized (wrong/insufficient permissions).
- **404** = target not found (wrong name/owner, repo not created, or a private
  repo your current login can't see).

## Key concepts a beginner should understand
- **Remote / origin:** a named URL pointing to a hosted copy of your repo.
- **Upstream tracking (`-u`):** links your local branch to a remote branch so
  push/pull need no extra arguments.
- **403 vs 404:** authorization failure vs. "not found" — different fixes.
- **Empty remote for first push:** create the GitHub repo WITHOUT initializing
  files, so your local history pushes cleanly without merge conflicts.
- **Credential Manager:** Windows stores your GitHub login; a stale/wrong cached
  account is a common cause of 403/404 on push.

## Review questions
1. **Q:** What's the difference between a `403` and a `404` when pushing to
   GitHub?
   **A:** `403` means you're authenticated but not authorized (no write access
   to that repo). `404` means the repo wasn't found — wrong owner/name, not
   created yet, or a private repo your login can't see.
2. **Q:** Why create the GitHub repo *empty* (no README/license) before the
   first push?
   **A:** So there's no divergent history on the remote; your local commits push
   cleanly without a merge conflict on the very first push.
3. **Q:** What does the `-u` in `git push -u origin main` do?
   **A:** It sets `origin/main` as the upstream for your local `main`, so future
   `git push` and `git pull` work without specifying the remote and branch.

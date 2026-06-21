# Build Log — verafin AWS/Terraform project

A one-paragraph-per-step timeline of the whole project. Newest steps appended at
the bottom.

---

**Step 01 — Connect machine to AWS and Terraform (2026-06-21).** Set up a
Windows machine to talk to AWS and run Terraform before building anything. Checked
existing tools: AWS CLI `2.0.30` and Terraform `1.14.3` were already installed, so
no installation was needed (both a bit old but functional). The user ran
`aws configure` themselves (so the Secret Access Key never passed through chat),
setting region `us-east-2` and output `json`. Verified the connection with
`aws sts get-caller-identity`, which returned the IAM user `terraform-admin` in
account `539555553835` — confirming the credentials work end-to-end. Noted that
credentials live in `C:\Users\User\.aws\credentials` (outside the project) and
must never be committed to git. See `docs/01-connect-machine-to-aws.md`.

**Step 02 — git init and .gitignore (2026-06-21).** Put the project under version
control before writing Terraform. Confirmed git `2.49.0` was installed and the
folder wasn't yet a repo, then ran `git init -b main` to create the repository
with a `main` branch. Wrote a Terraform-focused `.gitignore` whose most important
rules block `*.tfstate` (state files that can contain secrets), `.terraform/`
(plugin cache), and `*.tfvars` (often secret), while deliberately keeping
`.terraform.lock.hcl` tracked for reproducible provider versions. Verified with
`git status` (only `.gitignore` and `docs/` are untracked) and proved the ignore
works by creating a throwaway `terraform.tfstate` and watching `git check-ignore`
block it via rule `*.tfstate`. No first commit made yet. See
`docs/02-git-init-and-gitignore.md`.

**Step 03 — Baseline commit + first real Terraform (2026-06-21).** Confirmed the
global git identity was already set (`Emmakices` / `ihetuemmanuel@gmail.com`),
explained `--global` vs `--local`, then made the baseline commit `15a01c4`
("Initial project setup: docs and gitignore", 4 files). Wrote the minimal
Terraform foundation: `versions.tf` (pins Terraform `>= 1.5.0` and AWS provider
`~> 5.0`), `provider.tf` (AWS provider using `var.aws_region` with `default_tags`),
and `variables.tf` (`aws_region` defaulting to `us-east-2`, `project_name`
defaulting to `verafin-data-lake`). `terraform init` first failed with a
`zip: checksum error` (corrupted download); deleting `.terraform/` and re-running
fixed it, installing `hashicorp/aws v5.100.0` and creating the lock file. Verified
`.terraform.lock.hcl` is tracked while `.terraform/` is ignored. `terraform plan`
reported "No changes" because no resources are declared yet — a working,
authenticated, initialized project with zero AWS resources created. See
`docs/03-terraform-foundation.md`.

**Step 04 — Commit foundation and push to GitHub (2026-06-21).** Committed the
Terraform foundation and Step 03 docs as `8a8f70a` (6 files), deliberately with
no Claude co-author trailer. Adding the remote and pushing took three tries:
first a `403` because the remote pointed at `Terraboganalytics/AWS-Datalake`
(the authenticated user `Emmakices` had no write access there); repointing the
remote to `Emmakices/AWS-Datalake` then gave a `404` because that repo didn't
exist yet; after creating an empty repo under `Emmakices` and retrying,
`git push -u origin main` succeeded and `main` now tracks `origin/main` at
https://github.com/Emmakices/AWS-Datalake. Key lesson: `403` = authorized-but-
denied, `404` = not-found/wrong-owner-or-uncreated. See
`docs/04-commit-and-push-to-github.md`.

# Step 03 — First real Terraform: a working, initialized foundation

## What we were trying to accomplish
Two things:
1. Make our **baseline git commit** (a clean starting snapshot).
2. Write the **minimal correct Terraform foundation** for an AWS data-lake
   project in `us-east-2`: pin versions, configure the AWS provider, use
   variables instead of hardcoded values, initialize the project, and confirm a
   `terraform plan` runs with **no resources** created yet.

We deliberately created NO AWS resources this step.

## Part 1 — Git identity and baseline commit

### --global vs --local (key concept)
Git stamps each commit with a name + email. It reads them from:
- `git config --global` → stored in `C:\Users\User\.gitconfig`; applies to ALL
  repos on this machine.
- `git config --local` → stored in this repo's `.git/config`; applies to THIS
  repo only and overrides the global value here.
Use `--global` for a single-user machine (one identity everywhere). Use
`--local` only when a specific project needs a different identity (e.g. work vs
personal email).

### Commands
```powershell
# Check current global identity (read-only)
git config --global user.name
git config --global user.email
```
Already set: `Emmakices` / `ihetuemmanuel@gmail.com` — so nothing to configure.

```powershell
git add -A          # stage all tracked/untracked, non-ignored files
git status --short  # show what's staged (A = added)
git commit -m "Initial project setup: docs and gitignore"
```
- `git add -A` → marks files for the next commit. Ignored files (e.g. *.tfstate)
  are skipped automatically.
- `git commit -m "..."` → saves a permanent snapshot with a message.
Result: root-commit `15a01c4`, 4 files, 295 insertions.

Note: a harmless `LF will be replaced by CRLF` warning appeared — just git
normalizing Windows line endings. Nothing to fix.

## Part 2 — Terraform foundation files

### Why pin versions (key concept)
Terraform and the AWS provider update often, sometimes with breaking changes.
Pinning fixes known-good versions so the project behaves the same today, on a
teammate's machine, and next year. Two layers:
- **Constraints** (hand-written in versions.tf) = the acceptable range.
- **Lock file** (.terraform.lock.hcl, generated) = the exact version chosen,
  committed so everyone gets identical providers.

### versions.tf
```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```
- `required_version = ">= 1.5.0"` → this Terraform version or newer.
- `version = "~> 5.0"` → the "pessimistic" operator: >= 5.0.0 AND < 6.0.0.
  Accept any 5.x update, never auto-jump to 6.0 (possible breaking changes).
- `source = "hashicorp/aws"` → where to download the provider from.

### provider.tf
```hcl
provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "Terraform"
    }
  }
}
```
- The provider is the plugin that turns Terraform resources into AWS API calls.
- `region` reads a variable instead of a hardcoded string.
- `default_tags` will auto-tag every future resource (cost tracking / ownership).
  Does nothing until resources exist, but it's good foundation.

### variables.tf (role of variables)
```hcl
variable "aws_region" {
  description = "AWS region where all resources will be created."
  type        = string
  default     = "us-east-2"
}
variable "project_name" {
  description = "Short name for this project; used to name and tag resources."
  type        = string
  default     = "verafin-data-lake"
}
```
Variables are the project's input "knobs": a `description` (docs), a `type`
(validation), and a `default` (used if not overridden). Reading `var.aws_region`
in provider.tf means region is defined in ONE place and easily changed/reused.

### terraform init
```powershell
terraform init
```
What it does:
1. Reads the .tf files to find required providers (hashicorp/aws ~> 5.0).
2. Downloads that provider into the local **.terraform/** folder (the big cache;
   gitignored; regenerated anytime).
3. Writes **.terraform.lock.hcl** = exact version + checksums chosen (committed,
   NOT ignored).
Result: installed `hashicorp/aws v5.100.0`, lock file created, "successfully
initialized".

### terraform plan
```powershell
terraform plan
```
A plan is a **dry run**: Terraform compares your code, its state, and real AWS,
then prints what it WOULD add/change/destroy. It changes nothing (that's
`terraform apply`). With zero resources declared, it printed:
`No changes. Your infrastructure matches the configuration.` — i.e. 0 to add,
which is correct at this stage.

### Verified gitignore behavior
```powershell
git check-ignore -v .terraform.lock.hcl   # -> NOT ignored (will be committed)
git check-ignore -v .terraform/           # -> ignored by .gitignore:21
```

## What went wrong (and the fix)
First `terraform init` FAILED with:
`Error while installing hashicorp/aws v5.100.0: zip: checksum error`.
This means the downloaded provider zip was corrupted in transit (flaky network /
antivirus / partial download) — NOT a code problem. Fix: delete the partial
`.terraform/` folder and re-run init:
```powershell
if (Test-Path ".terraform") { Remove-Item -Recurse -Force ".terraform" }
terraform init
```
The retry downloaded a clean copy and succeeded.

## Key concepts a beginner should understand
- **Provider:** a plugin (here AWS) that lets Terraform talk to a specific
  platform's API.
- **Version pinning + lock file:** how Terraform stays reproducible over time.
- **Variables:** named, typed inputs with defaults, so values aren't hardcoded.
- **init vs plan vs apply:** init = set up/download; plan = preview changes (no
  effect); apply = actually make changes (not run yet).
- **.terraform/ vs .terraform.lock.hcl:** the first is a disposable cache
  (ignored); the second pins exact versions (committed).

## Review questions
1. **Q:** What's the difference between `git config --global` and `--local`,
   and which did we rely on?
   **A:** `--global` sets identity for every repo on the machine (stored in
   `~/.gitconfig`); `--local` sets it for just one repo (in `.git/config`) and
   overrides global there. We relied on the already-set `--global` identity.
2. **Q:** What does `~> 5.0` mean, and why prefer it over no constraint?
   **A:** It allows any 5.x version (>= 5.0.0, < 6.0.0) but blocks an automatic
   jump to 6.0. It lets you get safe bug fixes while preventing surprise
   breaking changes from a new major version.
3. **Q:** Why did `terraform plan` show "No changes," and what would running
   `terraform apply` have done at this point?
   **A:** We declared no resources, so there's nothing to create — code already
   matches reality. `apply` would also do nothing here, because there are no
   resources to build yet.

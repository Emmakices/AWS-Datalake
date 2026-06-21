# Step 01 — Connect my machine to AWS and Terraform

## What we were trying to accomplish
Get this Windows machine able to (1) talk to AWS from the command line and
(2) run Terraform, so that later steps can actually build cloud infrastructure.
This step is purely about **getting connected and authenticated** — we did not
build any AWS resources yet.

## Background: AWS CLI vs Terraform (and why you need both)
- **AWS CLI** = a remote control for AWS. One command does one thing *right now*
  ("list my buckets", "who am I?"). It is *imperative* and *immediate*. It also
  stores the credentials that other tools (like Terraform) reuse.
- **Terraform** = infrastructure-as-code. You write files describing the
  infrastructure you *want*, and Terraform makes reality match. It is
  *declarative* and remembers what it built in a "state file".
- **Why both:** the CLI gets the machine connected/authenticated to AWS;
  Terraform borrows that connection to build things. The CLI is also great for
  quick checks and debugging.

## What we did, command by command

### 1. Check what's already installed (read-only, safe)
```powershell
aws --version
terraform --version
```
- `aws --version` → prints the AWS CLI version, or errors if not installed.
- `terraform --version` → prints the Terraform version.

Results on this machine:
- AWS CLI `2.0.30` (old — from 2020 — but functional)
- Terraform `1.14.3` (one minor version behind latest `1.15.6`)

Because **both were already installed**, we skipped installation entirely.
(If either had been missing: install AWS CLI via the MSI installer from
aws.amazon.com or `winget install Amazon.AWSCLI`; install Terraform from
developer.hashicorp.com or `winget install HashiCorp.Terraform`.)

### 2. Configure AWS credentials (run by the USER, not by Claude)
```powershell
aws configure
```
Answered the four interactive prompts:
1. AWS Access Key ID  → the IAM user's access key (starts with `AKIA...`)
2. AWS Secret Access Key → the long secret (like a password)
3. Default region name → `us-east-2`  (Ohio data-center region)
4. Default output format → `json`

**Why the user ran this, not Claude:** the Secret Access Key is a password.
It must never be pasted into a chat or passed through an assistant. Typing it
into your own terminal keeps it on your machine only.

### 3. Verify the connection (read-only, safe)
```powershell
aws sts get-caller-identity
```
This asks AWS "who am I, based on the stored credentials?" A valid answer proves
the keys are correct AND the machine can reach AWS.

Output we got:
```json
{
    "UserId": "AIDAX3IAEMIVV73PKF7MD",
    "Account": "539555553835",
    "Arn": "arn:aws:iam::539555553835:user/terraform-admin"
}
```
- **UserId** — the unique internal ID AWS assigns to this IAM user. Stable even
  if the user is renamed. You rarely use it directly.
- **Account** — your 12-digit AWS account number. Every resource you create
  lives under this account; it's also what appears on the bill.
- **Arn** — the *Amazon Resource Name*, a globally unique address for this
  identity. Read it as: `arn:aws:iam::<account>:user/<name>`. Here it confirms
  we're authenticated as the IAM user **terraform-admin** in account
  **539555553835**.

We also listed (names only, not contents) the files the CLI created:
```powershell
Get-ChildItem "$env:USERPROFILE\.aws" | Select-Object Name, Length, LastWriteTime
```
Confirmed two files exist in `C:\Users\User\.aws\`: `config` and `credentials`.

## Where credentials are stored — and why they must never hit git
- `C:\Users\User\.aws\credentials` → holds the Access Key ID + Secret Access
  Key **in plain text**.
- `C:\Users\User\.aws\config` → holds the default region and output format.

These live in your home folder, **outside** the project folder
(`C:\Users\User\Desktop\verafin`), so the project's git cannot see them — good.
If a secret key ever lands in a git repo (especially public GitHub), bots scan
for and steal AWS keys within seconds, and can run up huge bills or steal data.
Backstop for later: a project `.gitignore` that blocks `*.tfstate`,
`.terraform/`, and any `.env`/credentials files.

## What went wrong
Nothing went wrong this step. The only surprises were that both tools were
already installed (so no install needed) and that they're slightly old
(acceptable for now; upgrade later).

## Key concepts a beginner should understand
- **Authentication chain:** keys stored by `aws configure` → tools read them →
  AWS verifies them. `get-caller-identity` tests this whole chain at once.
- **IAM user:** a non-root identity with its own keys; safer than using the AWS
  account root login for everyday work.
- **Region:** AWS is split into independent geographic regions; resources and
  defaults are region-scoped (`us-east-2` = Ohio here).
- **ARN:** a unique address for any AWS thing (users, buckets, servers, etc.).
- **Secret hygiene:** the secret key is a password; never commit it, never paste
  it into chats.

## Review questions
1. **Q:** What's the core difference between the AWS CLI and Terraform?
   **A:** The CLI runs single, immediate commands and stores your credentials;
   Terraform declares desired infrastructure as code and makes AWS match it,
   reusing the CLI's stored credentials.
2. **Q:** Where does `aws configure` save your keys on Windows, and why is that
   location convenient for safety?
   **A:** In `C:\Users\User\.aws\credentials` (and `config`). It's in your home
   folder, outside the project, so project git can't accidentally commit it.
3. **Q:** What does `aws sts get-caller-identity` prove, and what are its three
   output fields?
   **A:** It proves your credentials are valid and your machine can reach AWS.
   Fields: UserId (internal unique ID), Account (12-digit account number), and
   Arn (the unique address of the authenticated identity).

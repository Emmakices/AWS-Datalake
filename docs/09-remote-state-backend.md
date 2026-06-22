# Step 09 — Remote state backend (S3 + DynamoDB locking)

## What we were trying to accomplish
Move Terraform's state off the local laptop into a shared, durable, lockable
remote backend: an **S3 bucket** for storage and a **DynamoDB table** for locking.
This protects the project's "memory" and makes safe collaboration possible.

## Concepts

### What state is, and why local state is risky
The **state file** (terraform.tfstate) is Terraform's memory: a JSON map from each
resource in your code to the real AWS object it created (IDs, ARNs, attributes).
Terraform reads it every plan/apply to compute the diff. Local state has three
problems:
1. **Durability:** it's one file on one disk. Lose/corrupt it and Terraform forgets
   everything it built — it may try to recreate existing resources or orphan them.
2. **Sharing:** teammates and CI can't reach state on your laptop, so no one else
   can plan/apply against the same infrastructure.
3. **No locking:** two applies at once both read state and the second write
   clobbers the first → corrupted state and possibly damaged infra.

### What a remote backend solves — two pieces
- **S3 bucket (storage):** central, highly durable state. With **versioning** on,
  every prior state is kept (roll back a bad apply). Encrypted + private because
  state can contain secrets. Fixes durability + sharing.
- **DynamoDB table (locking):** before mutating state, Terraform writes a lock
  item; while it exists, other applies are refused. Fixes concurrency.

### How locking works — the LockID
The lock table has one required attribute: a hash key named **`LockID`** (string).
On each operation Terraform does a **conditional PutItem**: "create an item with
this LockID **only if one doesn't already exist**."
- Succeeds -> it holds the lock (item records who/when/what).
- Fails (item exists) -> someone else holds it -> Terraform errors out.
- On finish, Terraform **deletes** the item, releasing the lock.
The atomic "create only if absent" is what makes locking reliable. (Terraform
1.10+ can alternatively lock via an S3-native lockfile (`use_lockfile`), making
DynamoDB optional — but DynamoDB is the classic, interview-standard pattern.)

### The chicken-and-egg problem
The backend resources (the S3 bucket + DynamoDB table) can't be managed by the
state they store, because the bucket must EXIST before state can live in it.
Common solutions:
- **(a) Bootstrap with local state, then migrate** (what we did): create the
  bucket+table while state is local, then add the backend block and migrate local
  state into the bucket. They end up managed by the very state they store — fine
  for create/update; teardown needs care.
- **(b) Create them manually** (console/CLI), unmanaged by Terraform.
- **(c) A separate bootstrap project** with its own local state that creates the
  backend infra for the main project (the most rigorous, for big orgs).

## Code

### state-backend.tf (the two pieces)
- `aws_s3_bucket.tfstate` (+ versioning, AES-256 encryption, public-access-block)
  named `verafin-data-lake-tfstate-<account_id>`.
- `aws_dynamodb_table.tflock`: `billing_mode = "PAY_PER_REQUEST"`,
  `hash_key = "LockID"`, with an `attribute { name = "LockID", type = "S" }`.

### versions.tf — the backend block (added AFTER the resources existed)
```hcl
terraform {
  backend "s3" {
    bucket         = "verafin-data-lake-tfstate-539555553835"
    key            = "data-lake/terraform.tfstate"
    region         = "us-east-2"
    dynamodb_table = "verafin-data-lake-tflock"
    encrypt        = true
  }
}
```
IMPORTANT: a backend block CANNOT use variables/interpolation — every value must
be a hardcoded literal (it's read before the rest of the config). That's why the
account ID is written out in the bucket name.

## Commands

### 1. Bootstrap: create the bucket + table with local state
```powershell
terraform apply -auto-approve   # 5 added (bucket + 3 security resources + table)
```

### 2. Migrate local state into S3
After adding the backend block:
```powershell
terraform init -migrate-state -force-copy
```
- `terraform init` detects the backend changed from local -> s3 and asks:
  "Pre-existing state was found ... Do you want to copy this state to the new
  's3' backend? Enter 'yes' to copy and 'no' to start with an empty state."
- Meaning: "copy your existing local state (the record of everything built) up to
  S3 (yes), or start empty in S3 (no)?" You want YES. NO would make Terraform
  forget all resources and try to recreate them.
- `-force-copy` answers "yes" non-interactively.

### 3. Verify
```powershell
aws s3 ls s3://verafin-data-lake-tfstate-539555553835/data-lake/   # state object present
terraform state list                                               # reads from S3 (38 items)
```
Results: `terraform.tfstate` (~62 KB) is in S3; the local `terraform.tfstate` is
now 0 bytes and `terraform.tfstate.backup` holds the pre-migration copy.

### 4. Prove locking
Manually hold a lock, then try to plan:
```powershell
# put an item with LockID = "<bucket>/<key>"
aws dynamodb put-item --table-name verafin-data-lake-tflock --item file://lock-item.json
terraform plan -lock-timeout=0     # FAILS: "Error acquiring the state lock"
aws dynamodb delete-item --table-name verafin-data-lake-tflock --key file://lock-key.json
terraform plan -lock-timeout=0     # works again: "no changes"
```
The failure showed `ConditionalCheckFailedException: The conditional request
failed` — i.e. Terraform's conditional PutItem was rejected because a lock item
with that LockID already existed. That IS the locking mechanism. After deleting
the item, plan succeeded again.

## What went wrong
Nothing broke. Two things to note:
- In the locking demo, the error also printed `invalid character 'm' looking for
  beginning of value`. That's only because the hand-written `Info` field wasn't
  valid Terraform lock JSON; the meaningful part is the
  `ConditionalCheckFailedException` proving the lock blocked acquisition.
- The PowerShell wrapper showed a `NativeCommandError` because terraform wrote to
  stderr and exited non-zero — expected when a command intentionally fails.

## Cost note
- **S3 state bucket:** ~62 KB versioned object — storage cost is a fraction of a
  cent per month.
- **DynamoDB lock table:** `PAY_PER_REQUEST` (on-demand) means you pay only per
  lock read/write request and there's no provisioned/idle capacity charge — about
  $0 for occasional Terraform runs.
So standing cost is negligible (cents/month at most). Keep it — this is
infrastructure you WANT to persist.

## Destroy guidance (special — do NOT casually destroy this)
Unlike data resources, the backend is self-referential: it stores/locks the very
state that manages it. Do NOT `terraform destroy` the bucket/table while they're
the active backend. To fully tear down the project you would:
1. `terraform destroy` the data-lake resources (after emptying the data buckets),
2. remove the `backend "s3"` block and `terraform init -migrate-state` to bring
   state back local,
3. then destroy/delete the backend bucket + table.
For session end: LEAVE THE BACKEND IN PLACE — negligible cost, and it's the thing
protecting your state.

## Review questions
1. **Q:** Name the three problems with local state and which backend piece solves
   each.
   **A:** Durability (lose the file = lose Terraform's memory) and sharing
   (others can't reach it) are solved by the S3 bucket (durable, versioned,
   shared). Concurrency (simultaneous applies corrupt state) is solved by the
   DynamoDB lock table.
2. **Q:** How does DynamoDB state locking actually work?
   **A:** Terraform does a conditional PutItem keyed by `LockID` that succeeds
   only if no item with that LockID exists. Success = lock held; failure
   (ConditionalCheckFailedException) = someone else holds it, so Terraform
   refuses. The item is deleted to release the lock.
3. **Q:** What is the chicken-and-egg problem with a remote backend, and how did
   we handle it?
   **A:** The bucket/table can't be stored in the state they hold because the
   bucket must exist before state can live in it. We bootstrapped: created them
   with local state first, then added the backend block and migrated local state
   up to S3 with `terraform init -migrate-state`.

# Step 05 — First real AWS resources: the S3 data-lake buckets

## What we were trying to accomplish
Create the storage foundation of the data lake: three S3 buckets following the
bronze/silver/gold pattern, each secured with versioning, encryption at rest,
and a full public-access block — built with a `for_each` loop instead of
copy-paste. Then plan, apply (our FIRST real billable resources), and verify.

## The bronze/silver/gold pattern (medallion architecture)
Data flows through three progressively cleaner tiers:
- **Bronze (raw):** data exactly as ingested from source; untouched, immutable.
  Your "source of truth as received" — re-processable if anything downstream
  breaks.
- **Silver (cleaned/conformed):** validated, de-duplicated, type-cast, joined
  into a consistent schema. Trustworthy and queryable.
- **Gold (curated):** aggregated/modeled for business consumption — dashboards,
  reports, ML features, KPIs.
Why it matters: reprocessing safety (raw is immutable), incremental quality &
clear contracts per layer, per-layer access control & cost policies, and easy
lineage/debugging (trace a bad gold number back through silver to bronze).

## The code (s3.tf)

### Globally-unique bucket names
S3 bucket names are unique across ALL AWS accounts worldwide. We derive names as
`${project_name}-${zone}-${account_id}`, e.g.
`verafin-data-lake-bronze-539555553835`. We use the **account ID** (looked up via
a data source) rather than a random suffix because it is deterministic (stable,
predictable names) yet still globally unique (no other account shares your ID).

```hcl
data "aws_caller_identity" "current" {}   # reads the current account ID

locals {
  zones = toset(["bronze", "silver", "gold"])
}

resource "aws_s3_bucket" "zone" {
  for_each = local.zones
  bucket   = "${var.project_name}-${each.key}-${data.aws_caller_identity.current.account_id}"
  tags     = { Zone = each.key }
}
```

### for_each — loop instead of repetition
`for_each` creates ONE resource instance per item in a collection.
- `each.key` is the current item ("bronze"/"silver"/"gold"); for a set,
  `each.value` == `each.key`.
- Instances are addressed by key: `aws_s3_bucket.zone["bronze"]`, etc.
- The dependent resources loop over the buckets themselves
  (`for_each = aws_s3_bucket.zone`) and attach via `each.value.id`.
Why better than copy-paste: DRY (change once, applies to all), scalable (add a
zone = add one word), and **keyed addressing** (reordering the list never
destroys/recreates the wrong bucket — the big advantage over `count`, which keys
by fragile numeric index).

### The three security settings (and why each matters for a data lake)
```hcl
resource "aws_s3_bucket_versioning" "zone" {                 # keep every version
  for_each = aws_s3_bucket.zone
  bucket   = each.value.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "zone" {  # encrypt at rest
  for_each = aws_s3_bucket.zone
  bucket   = each.value.id
  rule { apply_server_side_encryption_by_default { sse_algorithm = "AES256" } }
}

resource "aws_s3_bucket_public_access_block" "zone" {        # never public
  for_each                = aws_s3_bucket.zone
  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```
- **Versioning:** keeps every version of an object, so accidental overwrites or
  deletes are recoverable — vital when bronze is your immutable source of truth.
- **Encryption at rest (SSE-S3/AES-256):** data lakes often hold sensitive or
  regulated data; encrypting on disk is a baseline security/compliance control
  (and free with SSE-S3).
- **Block all public access:** a hard guardrail so a future bad ACL/policy can't
  expose the data. Public S3 buckets are a classic breach cause; this makes that
  mistake impossible.

## Commands and how to read them

### terraform plan
```powershell
terraform plan
```
Symbols: `+` create, `-` destroy, `~` change in place, `-/+` replace.
Output ended with `Plan: 12 to add, 0 to change, 0 to destroy` = 4 resource
types x 3 zones. `(known after apply)` = values AWS assigns at create time.
`tags_all` showed default_tags (Project, ManagedBy) merged with the Zone tag.

### terraform apply
```powershell
terraform apply -auto-approve
```
- `apply` executes the plan against AWS, creating the real resources.
- Normally apply is INTERACTIVE: it reprints the plan and waits for you to type
  `yes`. We passed `-auto-approve` to skip the prompt; when running by hand, omit
  it and type `yes` so you consciously review first.
- Result: `Apply complete! Resources: 12 added, 0 changed, 0 destroyed.`
- This was the FIRST time we created real, billable AWS resources.

### The state file
After apply, Terraform recorded each resource's real-world IDs/attributes in
`terraform.tfstate` (e.g. `id=verafin-data-lake-bronze-539555553835`). State is
Terraform's memory of what it built; it uses it to compute future diffs. It is
gitignored because it can contain sensitive data.

### Verify with the AWS CLI (independent of Terraform)
```powershell
aws s3 ls | Select-String "verafin-data-lake"
aws s3api get-bucket-versioning   --bucket verafin-data-lake-bronze-539555553835
aws s3api get-public-access-block --bucket verafin-data-lake-bronze-539555553835
```
Confirmed all three buckets exist, versioning = Enabled, and all four
public-access-block protections = true.

## Cost check
Empty S3 buckets cost **effectively nothing**. S3 charges for (a) storage used,
(b) requests, and (c) data transfer out. With no objects and no traffic, all
three are ~$0. Versioning adds cost only when stored object versions accumulate;
empty buckets store nothing. So it is safe to leave these running.

## terraform destroy habit (end-of-session)
For resources that DO cost money, get in the habit of tearing down a learning
environment when you're done:
```powershell
terraform destroy   # type "yes" to confirm; deletes everything in state
```
These empty buckets are free, so destroying is optional today — but the habit
prevents surprise bills once we add billable services (compute, NAT gateways,
etc.). `destroy` removes exactly what Terraform created (tracked in state).

## What went wrong
Nothing went wrong this step. Plan, apply, and verification all succeeded on the
first try, and `for_each` produced the expected 3-of-each (12 total) resources.

## Review questions
1. **Q:** Explain bronze/silver/gold and one reason the layers are kept separate.
   **A:** Bronze = raw as-ingested (immutable source of truth), silver =
   cleaned/conformed/queryable, gold = curated business-ready. Separation lets
   you reprocess silver/gold from immutable raw data if logic changes or a bug is
   found (also: per-layer access/cost control, clear quality contracts, lineage).
2. **Q:** Why use `for_each` over copy-pasting the bucket block, and why is it
   safer than `count`?
   **A:** `for_each` is DRY and scalable (one definition, change once, add a zone
   by adding a list item). It keys instances by name (`["bronze"]`), so changing
   the collection doesn't destroy/recreate the wrong resource — unlike `count`,
   which keys by numeric index and shifts everything when the list changes.
3. **Q:** What does `terraform apply` do that `plan` doesn't, and what gets
   written to the state file?
   **A:** `apply` actually creates/changes/destroys real AWS resources (plan only
   previews). After apply, the state file records the real resource IDs and
   attributes Terraform created, which it uses to compute future diffs.

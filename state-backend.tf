# state-backend.tf
# The two pieces of a remote state backend:
#   - an S3 bucket to STORE terraform.tfstate (durability + sharing)
#   - a DynamoDB table to LOCK state (prevents concurrent applies corrupting it)
#
# NOTE on chicken-and-egg: these resources are created FIRST while state is still
# local. Only AFTER they exist do we add the `backend "s3"` block (below, once
# applied) and migrate local state into the bucket. They then end up managed by
# the very state they store — fine for create/update; teardown needs care.

# --- Piece A: S3 bucket that stores the state file ---
resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.project_name}-tfstate-${data.aws_caller_identity.current.account_id}"
  tags   = { Purpose = "terraform-remote-state" }
}

# Versioning: keep every prior version of state so a bad apply can be rolled back.
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Encrypt at rest — state can contain secrets in plain text.
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# State must never be public.
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- Piece B: DynamoDB table for state locking ---
# Terraform writes a lock item keyed by LockID before mutating state, and deletes
# it after. LockID is the REQUIRED hash key. PAY_PER_REQUEST = no idle cost.
resource "aws_dynamodb_table" "tflock" {
  name         = "${var.project_name}-tflock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S" # string
  }

  tags = { Purpose = "terraform-state-lock" }
}

# Ephemeral Cloud Desktop — Plan 1: Foundation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the public repository, a working CI gate, Terraform remote state in AWS, and GitHub Actions authenticating to AWS via OIDC with no static credentials.

**Architecture:** A one-off `terraform/bootstrap` stack (local state, gitignored) creates two S3 buckets — one for Terraform remote state, one for persistent desktop data — plus a GitHub OIDC provider and a CI role. The main stack then consumes that state bucket as its backend. CI gates every pull request with formatting, validation, linting, security scanning, and secret scanning.

**Tech Stack:** Terraform 1.15.7, AWS provider ~> 5.0, GitHub Actions, tflint, Checkov, Gitleaks, shellcheck.

## Global Constraints

- **AWS region is `me-central-1`** everywhere. Never `eu-central-1` — that is the other project.
- **Terraform `required_version >= 1.5`**; local toolchain is 1.15.7.
- **No static AWS credentials in CI, ever.** GitHub Actions authenticates by OIDC role assumption only.
- **State locking uses the S3 backend's `use_lockfile = true`.** Do not create a DynamoDB lock table; DynamoDB-based locking is the deprecated legacy pattern.
- **No NAT Gateway and no Elastic IP** anywhere in this project, in any plan.
- **All S3 buckets:** versioning enabled, server-side encryption enabled, all four public-access blocks enabled.
- **Bucket names are derived from the AWS account ID** for global uniqueness: `ephemeral-desktop-<account_id>-tfstate` and `ephemeral-desktop-<account_id>-data`.
- **GitHub repo is `mn0ur/ephemeral-cloud-desktop`, public.**
- **Every `.sh` file must pass `shellcheck`** with no findings.
- **Commit at the end of every task.** Never batch multiple tasks into one commit.
- Author identity for commits: `Mohamed Nour <mnuowr@gmail.com>`.

---

### Task 1: Repository skeleton and GitHub publication

**Files:**
- Create: `README.md`
- Modify: `.gitignore` (already exists — verify contents)
- Verify: git remote and GitHub repository

**Interfaces:**
- Consumes: nothing.
- Produces: a public GitHub repository at `mn0ur/ephemeral-cloud-desktop` with `main` as the default branch. Task 4 depends on this exact repository path for the OIDC trust policy.

- [ ] **Step 1: Verify `.gitignore` covers Terraform state and secrets**

Read the existing `.gitignore`. It must contain exactly these lines (add any that are missing):

```gitignore
terraform/bootstrap/.terraform/
terraform/bootstrap/*.tfstate*
.terraform/
*.tfstate
*.tfstate.backup
*.tfvars
tfplan
.DS_Store
```

Rationale: bootstrap state is local by necessity (it creates the bucket the remote backend lives in — a chicken-and-egg problem), so it must never be committed. `*.tfvars` is excluded because it will later hold a Tailscale auth key.

- [ ] **Step 2: Verify no secret would be committed**

Run:
```bash
git -C /c/Users/MN/Documents/Code/ephemeral-cloud-desktop status --porcelain
```
Expected: no `.tfstate`, `.tfvars`, or `.terraform/` paths listed.

- [ ] **Step 3: Write `README.md`**

```markdown
# Ephemeral Cloud Desktop

A full Linux desktop, streamed to the browser over WebRTC, provisioned on AWS
entirely with Terraform. One command up, one command down. Your data survives
teardown. When it is down, AWS bills effectively nothing.

## Why this exists

I wanted a disposable cloud desktop I could actually use — with working audio
and video — without paying for an idle instance. The interesting engineering is
not the desktop; it is making compute genuinely disposable while keeping state.

## How it works

    PERSISTENT (pennies/month)          EPHEMERAL (created and destroyed)
    S3: terraform state                 VPC → public subnet → IGW
    S3: desktop data                    Security group: zero inbound rules
    IAM: GitHub OIDC + CI role          EC2 c7i.xlarge SPOT
                                          Docker → neko:xfce
              ▲                             Tailscale → tailnet + HTTPS
              └──── restore / save ────────  systemd → save handlers

Access is over Tailscale only. The security group has **no inbound rules at
all** — not a locked-down range, none. The desktop is reachable from devices on
my tailnet and from nowhere else.

## Design decisions worth defending

**No NAT Gateway.** A NAT Gateway costs $0.045/hr plus data processing — more
than the instance it would serve. A public subnet with a public IP used for
egress only does the job.

**No Elastic IP.** An EIP bills whether attached or not. In an earlier project
of mine the EIP cost more per month ($3.40) than the instance it served
($3.26). Here the public address is ephemeral, and nothing needs to reach it
inbound, so there is nothing to reserve.

**No DNS management.** Because the address changes each boot and nothing
connects inbound, Tailscale MagicDNS provides a stable name for free. That
removed an entire moving part and one credential.

**Spot instances.** ~$0.0878/hr against ~$0.185 on-demand. Spot's two-minute
interruption warning triggers the same save path a clean shutdown uses, so
adopting spot cost almost no extra design.

**Non-burstable instance family.** `t3` is cheaper but burstable: sustained
video encoding exhausts CPU credits and the desktop degrades exactly when in
use. Dedicated vCPU is a requirement, not a preference.

**Region `me-central-1`.** I am in Abu Dhabi. ~5–15ms to the UAE region against
~110–130ms to Frankfurt, and measured spot pricing is 16% cheaper. Region
follows the workload.

**The environment is rebuilt, not preserved.** Installed software lives in
`packages.txt` and is reinstalled from the Dockerfile every boot. Mid-session
`apt install`s are captured and raised as a pull request against that file, so
the machine never holds git credentials and every environment change is
reviewable.

## Cost

| State | Cost |
|---|---|
| Running (`c7i.xlarge` spot, me-central-1) | ~$0.0878/hr |
| 2 hr/day × 20 days | ~$3.51/month |
| Destroyed | ~$0.12/month (S3 storage only) |

## Status

Plan 1 (foundation) in progress. See `docs/superpowers/`.
```

- [ ] **Step 4: Commit**

```bash
cd /c/Users/MN/Documents/Code/ephemeral-cloud-desktop
git add README.md .gitignore
git -c user.name="Mohamed Nour" -c user.email="mnuowr@gmail.com" \
  commit -m "docs: add README with architecture and cost rationale"
```

- [ ] **Step 5: Create the public GitHub repository and push**

```bash
cd /c/Users/MN/Documents/Code/ephemeral-cloud-desktop
git branch -M main
gh repo create ephemeral-cloud-desktop --public --source=. --remote=origin \
  --description "On-demand full Linux desktop on AWS. Terraform, spot instances, zero cost when destroyed." \
  --push
```

- [ ] **Step 6: Verify the repository is live and public**

```bash
gh repo view mn0ur/ephemeral-cloud-desktop --json name,visibility,defaultBranchRef,url
```
Expected: `"visibility":"PUBLIC"`, `"defaultBranchRef":{"name":"main"}`.

- [ ] **Step 7: Add repository topics for discoverability**

```bash
gh api -X PUT repos/mn0ur/ephemeral-cloud-desktop/topics \
  -f names[]=terraform -f names[]=aws -f names[]=infrastructure-as-code \
  -f names[]=devops -f names[]=webrtc -f names[]=spot-instances \
  -f names[]=tailscale -f names[]=docker --jq '.names'
```
Expected: the eight topics echoed back.

---

### Task 2: Bootstrap stack — state and data buckets

**Files:**
- Create: `terraform/bootstrap/versions.tf`
- Create: `terraform/bootstrap/variables.tf`
- Create: `terraform/bootstrap/main.tf`
- Create: `terraform/bootstrap/outputs.tf`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: two S3 buckets. Output names `state_bucket_name` and `data_bucket_name` (both `string`), and `account_id` (`string`). Task 3 lints these files; Task 4 extends this same stack; Task 5 wires `state_bucket_name` into the main stack's backend.

- [ ] **Step 1: Write `terraform/bootstrap/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "bootstrap"
    }
  }
}
```

- [ ] **Step 2: Write `terraform/bootstrap/variables.tf`**

```hcl
variable "region" {
  description = "AWS region for all persistent resources."
  type        = string
  default     = "me-central-1"
}

variable "project" {
  description = "Name prefix for all resources."
  type        = string
  default     = "ephemeral-desktop"
}

variable "github_repo" {
  description = "GitHub repository allowed to assume the CI role, as owner/name."
  type        = string
  default     = "mn0ur/ephemeral-cloud-desktop"
}
```

- [ ] **Step 3: Write `terraform/bootstrap/main.tf`**

```hcl
data "aws_caller_identity" "current" {}

locals {
  account_id    = data.aws_caller_identity.current.account_id
  state_bucket  = "${var.project}-${local.account_id}-tfstate"
  data_bucket   = "${var.project}-${local.account_id}-data"
}

# ---------------------------------------------------------------------------
# Terraform remote state bucket.
#
# This stack keeps LOCAL state on purpose: it creates the bucket that every
# other stack uses as its backend, so it cannot use that backend itself.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "tfstate" {
  bucket = local.state_bucket
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# Desktop data bucket. Survives every terraform destroy of the compute stack.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "data" {
  bucket = local.data_bucket
}

resource "aws_s3_bucket_versioning" "data" {
  bucket = aws_s3_bucket.data.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket                  = aws_s3_bucket.data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning protects against a bad sync destroying good data, but old
# versions must not accumulate forever and quietly grow the bill.
resource "aws_s3_bucket_lifecycle_configuration" "data" {
  bucket = aws_s3_bucket.data.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}
```

- [ ] **Step 4: Write `terraform/bootstrap/outputs.tf`**

```hcl
output "account_id" {
  description = "AWS account ID these resources live in."
  value       = local.account_id
}

output "state_bucket_name" {
  description = "S3 bucket holding Terraform remote state."
  value       = aws_s3_bucket.tfstate.id
}

output "data_bucket_name" {
  description = "S3 bucket holding persistent desktop data."
  value       = aws_s3_bucket.data.id
}
```

- [ ] **Step 5: Format and validate before applying anything**

```bash
cd /c/Users/MN/Documents/Code/ephemeral-cloud-desktop
terraform fmt -recursive
terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap validate
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 6: Plan and read the plan before applying**

```bash
terraform -chdir=terraform/bootstrap plan -out=tfplan
```
Expected: `Plan: 9 to add, 0 to change, 0 to destroy.`

If the count differs, stop and reconcile against the resources above rather than applying.

- [ ] **Step 7: Apply**

```bash
terraform -chdir=terraform/bootstrap apply tfplan
```
Expected: `Apply complete! Resources: 9 added, 0 changed, 0 destroyed.` followed by the three outputs.

- [ ] **Step 8: Verify the buckets exist with the expected protections**

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
for B in "ephemeral-desktop-${ACCT}-tfstate" "ephemeral-desktop-${ACCT}-data"; do
  echo "=== $B ==="
  aws s3api get-bucket-versioning --bucket "$B" --query Status --output text
  aws s3api get-public-access-block --bucket "$B" \
    --query 'PublicAccessBlockConfiguration.BlockPublicAcls' --output text
done
```
Expected: `Enabled` and `True` for both buckets.

- [ ] **Step 9: Commit**

```bash
cd /c/Users/MN/Documents/Code/ephemeral-cloud-desktop
git add terraform/bootstrap
git -c user.name="Mohamed Nour" -c user.email="mnuowr@gmail.com" \
  commit -m "feat: bootstrap stack for remote state and desktop data buckets

Local state on purpose - this stack creates the bucket every other
stack uses as its backend. No DynamoDB lock table: S3 native
use_lockfile replaces it in current Terraform."
git push
```

---

### Task 3: CI gate

**Files:**
- Create: `.github/workflows/ci.yml`
- Create: `.tflint.hcl`

**Interfaces:**
- Consumes: the Terraform files from Task 2 (they are what CI has to gate).
- Produces: a required-status-check pipeline named `CI`. Tasks 4 and 5 rely on it running on every pull request.

This task is deliberately test-first: prove the gate rejects bad input *before* trusting it.

- [ ] **Step 1: Write `.tflint.hcl`**

```hcl
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.32.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
```

- [ ] **Step 2: Write `.github/workflows/ci.yml`**

```yaml
name: CI

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  terraform:
    name: terraform fmt + validate
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.15.7

      - name: fmt
        run: terraform fmt -check -recursive

      # -backend=false: validation must not need AWS credentials or touch
      # remote state.
      - name: validate bootstrap
        run: |
          terraform -chdir=terraform/bootstrap init -backend=false
          terraform -chdir=terraform/bootstrap validate

  tflint:
    name: tflint
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: terraform-linters/setup-tflint@v4
      - run: tflint --init
      - run: tflint --recursive

  checkov:
    name: checkov
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: bridgecrewio/checkov-action@master
        with:
          directory: terraform
          framework: terraform
          quiet: true
          output_format: cli

  gitleaks:
    name: gitleaks
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: gitleaks/gitleaks-action@v2
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

  shellcheck:
    name: shellcheck
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: install shellcheck
        run: sudo apt-get update && sudo apt-get install -y shellcheck
      - name: run shellcheck
        run: |
          mapfile -d '' FILES < <(find . -name '*.sh' -not -path './.git/*' -print0)
          if [ ${#FILES[@]} -eq 0 ]; then
            echo "no shell scripts yet"
            exit 0
          fi
          shellcheck "${FILES[@]}"
```

- [ ] **Step 3: Break formatting on purpose, to prove the gate works**

Append a deliberately misformatted block to `terraform/bootstrap/outputs.tf`:

```hcl
output "ci_gate_probe" {
        description   = "Temporary. Deliberately misformatted to prove CI rejects it."
  value = local.account_id
}
```

- [ ] **Step 4: Confirm the gate fails locally first**

```bash
cd /c/Users/MN/Documents/Code/ephemeral-cloud-desktop
terraform fmt -check -recursive
```
Expected: **non-zero exit**, printing `terraform/bootstrap/outputs.tf`. If this passes, the probe is not actually misformatted — fix the probe, not the gate.

- [ ] **Step 5: Push on a branch and confirm CI fails**

```bash
git checkout -b ci-gate
git add .github/workflows/ci.yml .tflint.hcl terraform/bootstrap/outputs.tf
git -c user.name="Mohamed Nour" -c user.email="mnuowr@gmail.com" \
  commit -m "test: prove CI rejects misformatted terraform"
git push -u origin ci-gate
gh pr create --fill --base main
```

Then watch it:
```bash
gh pr checks --watch
```
Expected: the `terraform fmt + validate` job **fails**. This is the point of the task.

- [ ] **Step 6: Remove the probe and confirm CI goes green**

Delete the entire `ci_gate_probe` output block from `terraform/bootstrap/outputs.tf`, then:

```bash
terraform fmt -recursive
git add terraform/bootstrap/outputs.tf
git -c user.name="Mohamed Nour" -c user.email="mnuowr@gmail.com" \
  commit -m "test: remove CI probe now that the gate is proven"
git push
gh pr checks --watch
```
Expected: all five jobs pass.

- [ ] **Step 7: Merge**

```bash
gh pr merge --squash --delete-branch
git checkout main && git pull
```

- [ ] **Step 8: Make CI a required status check on `main`**

```bash
gh api -X PUT repos/mn0ur/ephemeral-cloud-desktop/branches/main/protection \
  --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["terraform fmt + validate", "tflint", "checkov", "gitleaks", "shellcheck"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null
}
JSON
```
Expected: JSON describing the protection rule. If this returns 403, the repository plan does not permit protection on private repos — it is public, so it should succeed.

---

### Task 4: GitHub OIDC provider and CI role

**Files:**
- Modify: `terraform/bootstrap/main.tf` (append)
- Modify: `terraform/bootstrap/outputs.tf` (append)
- Create: `.github/workflows/oidc-check.yml`

**Interfaces:**
- Consumes: `var.github_repo` and `local.account_id` from Task 2; the repository from Task 1.
- Produces: an IAM role whose ARN is exported as output `ci_role_arn` (`string`). Task 5 and all later workflows assume this role. The role name is `ephemeral-desktop-ci`.

- [ ] **Step 1: Append the OIDC provider and role to `terraform/bootstrap/main.tf`**

```hcl
# ---------------------------------------------------------------------------
# GitHub Actions OIDC.
#
# CI assumes this role with a short-lived token minted per run. No access key
# is ever created, stored, or rotated. This exists because a previous project
# of mine hit a silently truncated IAM secret key pasted by hand - the fix is
# to stop having one.
# ---------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

data "aws_iam_policy_document" "ci_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Scoped to this repository only. Without this condition ANY GitHub
    # repository in the world could assume the role.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "ci" {
  name               = "${var.project}-ci"
  description        = "Assumed by GitHub Actions via OIDC to manage the desktop stack."
  assume_role_policy = data.aws_iam_policy_document.ci_assume.json
}

data "aws_iam_policy_document" "ci_permissions" {
  # Remote state access.
  statement {
    sid    = "TerraformState"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.tfstate.arn}/*"]
  }

  statement {
    sid       = "TerraformStateList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.tfstate.arn]
  }

  # Desktop data - CI needs this for the package-capture download in Plan 3.
  statement {
    sid    = "DesktopData"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.data.arn,
      "${aws_s3_bucket.data.arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "ci" {
  name   = "${var.project}-ci"
  role   = aws_iam_role.ci.id
  policy = data.aws_iam_policy_document.ci_permissions.json
}
```

**Note on scope:** this policy intentionally grants only S3 access for now. EC2, VPC, and IAM permissions needed to build the compute stack are added in Plan 3, alongside the resources that need them — granting them now would be permissions for code that does not exist.

- [ ] **Step 2: Append to `terraform/bootstrap/outputs.tf`**

```hcl
output "ci_role_arn" {
  description = "IAM role GitHub Actions assumes via OIDC."
  value       = aws_iam_role.ci.arn
}
```

- [ ] **Step 3: Format, validate, plan**

```bash
cd /c/Users/MN/Documents/Code/ephemeral-cloud-desktop
terraform fmt -recursive
terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap validate
terraform -chdir=terraform/bootstrap plan -out=tfplan
```
Expected: `Plan: 3 to add, 0 to change, 0 to destroy.` — the OIDC provider, the role, and the role policy. Data sources are not resources and do not appear in the count. No bucket should change; if the plan proposes altering or replacing a bucket, stop, because that risks the state file.

If validation fails with a parse error, check the `TerraformState` statement's `actions` list — it must contain exactly three quoted strings (`s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`) and nothing else. `s3:ListBucket` belongs in the separate `TerraformStateList` statement because it applies to the bucket ARN, not to objects within it.

- [ ] **Step 4: Apply and capture the role ARN**

```bash
terraform -chdir=terraform/bootstrap apply tfplan
terraform -chdir=terraform/bootstrap output -raw ci_role_arn
```
Expected: an ARN of the form `arn:aws:iam::<account>:role/ephemeral-desktop-ci`.

- [ ] **Step 5: Write `.github/workflows/oidc-check.yml`**

This proves OIDC works before anything depends on it.

```yaml
name: OIDC check

on:
  workflow_dispatch:

permissions:
  contents: read
  id-token: write # required to mint the OIDC token

jobs:
  whoami:
    name: assume role and identify
    runs-on: ubuntu-latest
    steps:
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_CI_ROLE_ARN }}
          aws-region: me-central-1

      - name: sts get-caller-identity
        run: aws sts get-caller-identity

      - name: confirm state bucket is reachable
        run: aws s3 ls "s3://${{ vars.STATE_BUCKET }}" || echo "bucket empty (expected on first run)"
```

- [ ] **Step 6: Set the repository variables the workflow reads**

```bash
cd /c/Users/MN/Documents/Code/ephemeral-cloud-desktop
ROLE=$(terraform -chdir=terraform/bootstrap output -raw ci_role_arn)
BUCKET=$(terraform -chdir=terraform/bootstrap output -raw state_bucket_name)
gh variable set AWS_CI_ROLE_ARN --body "$ROLE"
gh variable set STATE_BUCKET --body "$BUCKET"
gh variable list
```
Expected: both variables listed. These are **variables, not secrets** — a role ARN is not sensitive, and pretending it is makes debugging harder.

- [ ] **Step 7: Commit, push, and run the check**

```bash
git add terraform/bootstrap .github/workflows/oidc-check.yml
git -c user.name="Mohamed Nour" -c user.email="mnuowr@gmail.com" \
  commit -m "feat: GitHub OIDC provider and CI role

CI assumes a role with a per-run short-lived token. No static AWS
access key exists anywhere in this project. Trust policy is scoped to
this repository only - without the sub condition any repo on GitHub
could assume it."
git push
gh workflow run "OIDC check"
sleep 20
gh run list --workflow="OIDC check" --limit 1
```

- [ ] **Step 8: Verify the assumed identity is the CI role, not a user**

```bash
gh run view --log --job=whoami 2>/dev/null | grep -A3 '"Arn"' || \
  gh run view --log | grep -i 'assumed-role'
```
Expected: an ARN containing `assumed-role/ephemeral-desktop-ci`. If it shows `user/mnour`, static credentials are leaking in from somewhere — stop and find them.

---

### Task 5: Main stack backend wiring

**Files:**
- Create: `terraform/versions.tf`
- Create: `terraform/backend.tf`
- Create: `terraform/variables.tf`
- Create: `terraform/main.tf`
- Modify: `.github/workflows/ci.yml` (add a plan job)

**Interfaces:**
- Consumes: `state_bucket_name` from Task 2, `ci_role_arn` from Task 4.
- Produces: an initialised remote backend at state key `desktop/terraform.tfstate`, and variables `region` (`string`) and `project` (`string`) that every resource in Plan 3 uses. Plan 3 adds resources to `terraform/main.tf`.

- [ ] **Step 1: Write `terraform/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "desktop"
    }
  }
}
```

- [ ] **Step 2: Write `terraform/backend.tf`**

The bucket name contains the account ID, so it cannot be a variable — backend blocks do not accept interpolation. It is written literally, and Step 3 replaces the placeholder with the real value.

```hcl
terraform {
  backend "s3" {
    bucket = "REPLACE_WITH_STATE_BUCKET"
    key    = "desktop/terraform.tfstate"
    region = "me-central-1"

    # S3 native locking. Replaces the legacy DynamoDB lock table, which is
    # deprecated in current Terraform - one less resource to create and bill.
    use_lockfile = true

    encrypt = true
  }
}
```

- [ ] **Step 3: Substitute the real bucket name**

```bash
cd /c/Users/MN/Documents/Code/ephemeral-cloud-desktop
BUCKET=$(terraform -chdir=terraform/bootstrap output -raw state_bucket_name)
sed -i "s/REPLACE_WITH_STATE_BUCKET/${BUCKET}/" terraform/backend.tf
grep bucket terraform/backend.tf
```
Expected: `bucket = "ephemeral-desktop-<account_id>-tfstate"` with no placeholder remaining.

- [ ] **Step 4: Write `terraform/variables.tf`**

```hcl
variable "region" {
  description = "AWS region the desktop runs in. Chosen for latency from Abu Dhabi."
  type        = string
  default     = "me-central-1"
}

variable "project" {
  description = "Name prefix for all resources."
  type        = string
  default     = "ephemeral-desktop"
}
```

- [ ] **Step 5: Write `terraform/main.tf`**

Plan 3 fills this stack with real resources. For now it must be valid and plannable so the backend and CI can be proven in isolation.

```hcl
data "aws_caller_identity" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  data_bucket = "${var.project}-${local.account_id}-data"
}

# Compute resources are added in Plan 3 (VPC, security group, spot instance).
# This stack is intentionally empty of resources at the end of Plan 1: the
# deliverable here is a proven backend and a proven CI identity, not compute.

output "data_bucket" {
  description = "Bucket the desktop restores from and saves to."
  value       = local.data_bucket
}
```

- [ ] **Step 6: Initialise the remote backend locally**

```bash
terraform -chdir=terraform init
```
Expected: `Successfully configured the backend "s3"!` and `Terraform has been successfully initialized!`

If it errors on `use_lockfile`, the installed Terraform predates native S3 locking. Verify with `terraform version`; anything ≥ 1.10 supports it.

- [ ] **Step 7: Confirm state is genuinely remote**

```bash
terraform -chdir=terraform plan
ACCT=$(aws sts get-caller-identity --query Account --output text)
aws s3 ls "s3://ephemeral-desktop-${ACCT}-tfstate/desktop/"
```
Expected: `plan` reports `No changes.` and the `aws s3 ls` lists `terraform.tfstate`. A local `terraform/terraform.tfstate` file must **not** exist.

- [ ] **Step 8: Add a plan job to `.github/workflows/ci.yml`**

Append this job to the `jobs:` map:

```yaml
  plan:
    name: terraform plan (desktop)
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write
    steps:
      - uses: actions/checkout@v4

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_CI_ROLE_ARN }}
          aws-region: me-central-1

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.15.7

      - name: init
        run: terraform -chdir=terraform init

      # Plan only. Applying from a pull request would let a PR change
      # infrastructure before review.
      - name: plan
        run: terraform -chdir=terraform plan -no-color
```

- [ ] **Step 9: Open a pull request and confirm every check passes**

```bash
git checkout -b backend-wiring
git add terraform .github/workflows/ci.yml
git -c user.name="Mohamed Nour" -c user.email="mnuowr@gmail.com" \
  commit -m "feat: wire main stack to S3 remote backend with native locking

CI plans the desktop stack using an OIDC-assumed role. Plan only on
pull requests - apply never runs from an unreviewed branch."
git push -u origin backend-wiring
gh pr create --fill --base main
gh pr checks --watch
```
Expected: all six jobs pass, including `terraform plan (desktop)`.

- [ ] **Step 10: Add the new check to branch protection, then merge**

```bash
gh api -X PUT repos/mn0ur/ephemeral-cloud-desktop/branches/main/protection \
  --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["terraform fmt + validate", "tflint", "checkov", "gitleaks", "shellcheck", "terraform plan (desktop)"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null
}
JSON

gh pr merge --squash --delete-branch
git checkout main && git pull
```

---

## Definition of done for Plan 1

- [ ] `mn0ur/ephemeral-cloud-desktop` is public with topics set and `main` protected.
- [ ] Six CI checks run on every pull request and are required to merge.
- [ ] The CI gate has been **proven** to reject bad input, not merely assumed to.
- [ ] Two S3 buckets exist in `me-central-1`, both versioned, encrypted, and public-access-blocked.
- [ ] The data bucket expires non-current versions after 30 days.
- [ ] Terraform state for the desktop stack lives in S3 with native locking; no local state file exists.
- [ ] GitHub Actions authenticates to AWS by OIDC. **No AWS access key exists anywhere** — not in secrets, not in a file, not in the repo.
- [ ] The trust policy is scoped to this one repository.
- [ ] Running cost of everything created in Plan 1: **$0 compute**, a few cents of S3.

## What Plan 1 deliberately does not do

No compute, no VPC, no Docker image, no desktop. Those are Plans 2 and 3. Plan 1's value is that everything after it is gated, credential-free, and has somewhere safe to keep state — which is exactly the groundwork most portfolio Terraform repositories skip.

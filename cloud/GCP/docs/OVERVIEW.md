# CloudBooter GCP — Overview

## What It Does

CloudBooter GCP automates the provisioning of Google Compute Engine instances within
GCP's Always Free Tier, eliminating the usual cycle of:

1. Navigating the GCP Console
2. Manually constructing Terraform HCL
3. Discovering which region / machine type / disk size qualifies for zero-cost usage
4. Dealing with quota or capacity errors

The toolkit generates validated, idempotent Terraform files and deploys them with
automatic retry on quota-exhaustion errors.

---

## Architecture

```
User runs script
  ↓
[Prerequisites]  ──── install gcloud SDK (3-tier) + Terraform
  ↓
[Auth Detection] ──── SA key | WIF | Impersonation | ADC
  ↓
[Resource Inventory] ── VPCs, subnets, firewalls, instances, disks, static IPs, GCS
  ↓
[Free-Tier Validation] ─ reject configs that exceed hard limits
  ↓
[Terraform Generation] ─ provider.tf, variables.tf, data_sources.tf, main.tf, cloud-init.yaml
  ↓
[Deployment] ─────────── terraform init → plan → apply (retry on quota errors)
```

---

## Layers

| Layer | Description |
|---|---|
| `setup_gcp_terraform.sh` | Primary — Bash orchestrator, all logic inline + calls Python renderer |
| `setup_gcp_terraform.ps1` | Windows — PowerShell equivalent |
| `src/cloudbooter/` | Python package — renderers, auth, inventory, validation |
| Generated `.tf` files | Terraform HCL written to the output directory |

---

## Auth Patterns (in precedence order)

1. **SA Key** — `GCP_CREDENTIALS_FILE` points to a `service_account` JSON
2. **WIF** — `GCP_CREDENTIALS_FILE` points to an `external_account` JSON
3. **Impersonation** — `GCP_IMPERSONATE_SA` set to a service account email
4. **ADC** — `gcloud auth application-default login` or metadata server

---

## GCP Mode

| `GCP_MODE` | Behaviour |
|---|---|
| `gcloud` (default) | Uses `gcloud` CLI for all API calls |
| `python` | Uses Google Python SDK — no `gcloud` required |

The Bash script automatically falls back to `python` mode if gcloud cannot be installed.

---

## Key Design Decisions

- **Idempotent** — running the script twice with the same config is safe
- **Free-tier enforcement** — three layers of checks (Bash → Python → Terraform `check` blocks)
- **No committed Terraform files** — all `.tf` files are generated on the fly
- **Retry on quota errors** — exponential backoff up to `RETRY_MAX_ATTEMPTS` attempts
- **Billing trap warnings** — reserved-but-unattached static IPs are flagged immediately

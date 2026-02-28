# GCP Always Free Tier Limits

Reference for all GCP Always Free Tier limits enforced by CloudBooter.
These constants are the **canonical source of truth** — every layer must stay in sync:
`free_tier.py` → `setup_gcp_terraform.sh` → `variables.tf` check blocks.

---

## Compute Engine (e2-micro)

| Resource | Free Limit | Notes |
|---|---|---|
| Machine type | `e2-micro` only | Any other type incurs charges |
| vCPUs | Shared (0.25 burst) | Part of e2-micro spec |
| RAM | 1 GB | Part of e2-micro spec |
| Combined compute hours | **744 hrs/month** | Covers 1 instance running 24/7 |
| Eligible regions | **us-central1, us-west1, us-east1** | Must be in one of these three |
| Standard persistent disk | **30 GB total** | `pd-standard` only |
| Snapshots | 5 GB | Free across all regions |
| Network egress | 1 GB/month | To most destinations |

## Cloud Storage (GCS)

| Resource | Free Limit | Notes |
|---|---|---|
| Storage | **5 GB** | US multi-region or specific US regions |
| Eligible storage regions | **us-east1, us-west1, us-central1** | Must store in one of these |
| Class A operations | 5,000/month | |
| Class B operations | 50,000/month | |
| Network egress (US) | 1 GB/month | |

## Secret Manager

| Resource | Free Limit | Notes |
|---|---|---|
| Active secret versions | **6** | Across all secrets in the project |
| Operations | **10,000/month** | Access + create combined |

## Cloud Build

| Resource | Free Limit | Notes |
|---|---|---|
| Build minutes | **2,500 min/month** | First-gen machines |

## Artifact Registry

| Resource | Free Limit | Notes |
|---|---|---|
| Storage | **0.5 GB** | Per region |

## Cloud Logging

| Resource | Free Limit | Notes |
|---|---|---|
| Log ingestion | **50 GiB/project/month** | |
| Log retention | 30 days | |

---

## Cost Traps — Resources That Are NOT Free

> These are zero-cost to create but will incur charges once used.
> CloudBooter warns on all of these.

| Resource | Issue |
|---|---|
| External Static IP (reserved, unattached) | ~$0.01/hr while not attached to a running instance |
| Cloud NAT | Charged per gateway per hour |
| Cloud DNS Managed Zone | $0.20/zone/month (after first 25 queries) |
| Load Balancer forwarding rules | Charged per rule per hour |
| Filestore | No free tier |
| Cloud SQL | No free tier |
| Cloud Spanner | No free tier |

---

## Idle Instance Reclamation

> GCP may reclaim Always Free `e2-micro` instances if CPU utilization stays below
> **2% for 15 minutes, 3 times over a 7-day period** (based on rolling average).

Mitigation: run a lightweight cron task or use the `unattended-upgrades` package
installed by the default cloud-init to keep mild background activity.

---

## Synchronization Checklist

When GCP limits change, update **all four** locations:

- [ ] `src/cloudbooter/free_tier.py` — Python frozen dataclass `GCPFreeTierLimits`
- [ ] `setup_gcp_terraform.sh` — `readonly FREE_*` constants (Section 1)
- [ ] `setup_gcp_terraform.ps1` — `$FREE_*` variables
- [ ] `Terraform check blocks` — generated in `render_variables()` / `generate_variables_tf()`

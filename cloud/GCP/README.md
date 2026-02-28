# CloudBooter GCP

> Automated Google Cloud Platform Always-Free-Tier provisioner.
> Generates validated Terraform files and deploys an `e2-micro` instance at zero cost.

---

## Quick Start

```bash
export GCP_PROJECT_ID="my-project"
./setup_gcp_terraform.sh
```

For Windows, use `setup_gcp_terraform.ps1`.

See [docs/QUICKSTART.md](docs/QUICKSTART.md) for full options.

---

## What Gets Created

| Resource | Type | Free? |
|---|---|---|
| VPC | `google_compute_network` | ✅ |
| Subnet | `google_compute_subnetwork` | ✅ |
| SSH firewall rule | `google_compute_firewall` | ✅ |
| ICMP firewall rule | `google_compute_firewall` | ✅ |
| Boot disk (≤ 30 GB pd-standard) | `google_compute_disk` | ✅ |
| Instance (`e2-micro` in us-*) | `google_compute_instance` | ✅ |

---

## Free Tier Guardrails

Three independent layers prevent accidental paid usage:

1. **Bash constants** (`readonly FREE_*`) — validation before Terraform generation
2. **Python dataclass** (`GCPFreeTierLimits`) — used by the Python CLI and tests
3. **Terraform `check` blocks** — enforced at plan/apply time by Terraform itself

See [docs/FREE_TIER_LIMITS.md](docs/FREE_TIER_LIMITS.md) for the full limits reference.

---

## Directory Structure

```
cloud/GCP/
├── setup_gcp_terraform.sh      Main Bash orchestrator
├── setup_gcp_terraform.ps1     Windows PowerShell equivalent
├── requirements.txt            Python dependencies
├── pyproject.toml              Python package metadata
├── pytest.ini                  Test configuration
├── main.py                     Direct invocation wrapper
├── run_tests.py                Test runner wrapper
├── src/cloudbooter/
│   ├── free_tier.py            GCP free-tier constants & validation
│   ├── renderers.py            Terraform HCL generators
│   ├── installer.py            3-tier gcloud + terraform installer
│   ├── auth.py                 Auth pattern detection & credential building
│   ├── inventory.py            Resource discovery (gcloud + SDK fallback)
│   └── cli.py                  Click CLI: deploy, validate, inventory
├── tests/
│   ├── conftest.py             Shared fixtures
│   ├── test_renderers.py       HCL output validation
│   ├── test_free_tier.py       Validation logic tests
│   ├── test_integration.py     Auth → inventory → render pipeline
│   └── test_e2e_workflow.py    Full dry-run end-to-end tests
└── docs/
    ├── OVERVIEW.md
    ├── QUICKSTART.md
    └── FREE_TIER_LIMITS.md
```

---

## Non-Interactive (CI/CD)

```bash
GCP_PROJECT_ID=my-proj \
GCP_CREDENTIALS_FILE=/path/to/sa-key.json \
NON_INTERACTIVE=true \
AUTO_DEPLOY=true \
./setup_gcp_terraform.sh
```

---

## Running Tests

```bash
cd cloud/GCP
pip install -e ".[dev]"
pytest
```

Tests requiring a live GCP project are automatically skipped unless
`GOOGLE_CLOUD_PROJECT` and valid credentials are present.

Tests requiring `terraform` on `PATH` are skipped if it is not installed.

---

## License

See the root [LICENSE](../../LICENSE) file.

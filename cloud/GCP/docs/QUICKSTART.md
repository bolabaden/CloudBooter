# CloudBooter GCP — Quick Start

## Prerequisites

- A GCP project with billing enabled (free tier still requires a billing account)
- One of: `gcloud` CLI, or Python 3.9+ with `pip`
- `terraform` >= 1.6 (auto-installed if missing)

---

## 5-Minute Deployment

### Linux / macOS / WSL

```bash
# 1  Clone the repo
git clone https://github.com/your-org/cloudcradle.git
cd cloudcradle/cloud/GCP

# 2  (Optional) set your project ID in the environment
export GCP_PROJECT_ID="my-gcp-project"

# 3  Run the script
./setup_gcp_terraform.sh
```

The script will:
- Install `gcloud` and `terraform` if not present
- Open a browser window for `gcloud auth application-default login` if needed
- Discover existing resources in your project
- Prompt for region / zone / instance name (or use defaults)
- Generate all Terraform files
- Ask to run `terraform apply`

### Windows (PowerShell)

```powershell
# 1  Set project ID
$env:GCP_PROJECT_ID = "my-gcp-project"

# 2  Run the script (allow execution policy if needed)
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\setup_gcp_terraform.ps1
```

---

## Non-Interactive (CI/CD)

```bash
export GCP_PROJECT_ID="my-proj"
export GCP_CREDENTIALS_FILE="/path/to/sa-key.json"
export NON_INTERACTIVE=true
export AUTO_DEPLOY=true
./setup_gcp_terraform.sh
```

---

## Python CLI

```bash
pip install -e .          # from cloud/GCP/

# Deploy
cloudbooter-gcp deploy --project my-proj --region us-central1

# Just validate your config
cloudbooter-gcp validate --project my-proj --region us-central1 --disk-gb 20

# Show existing resources
cloudbooter-gcp inventory --project my-proj --region us-central1
```

---

## Common Options

| Environment Variable | Default | Description |
|---|---|---|
| `GCP_PROJECT_ID` | (required) | GCP project ID |
| `GCP_REGION` | `us-central1` | Compute region |
| `GCP_ZONE` | `us-central1-a` | Compute zone |
| `GCP_INSTANCE_NAME` | `cloudbooter-vm` | Instance name |
| `GCP_BOOT_DISK_GB` | `20` | Boot disk (max 30) |
| `GCP_CREDENTIALS_FILE` | — | SA key or WIF JSON path |
| `GCP_SSH_KEY_FILE` | `~/.ssh/cloudbooter_gcp` | SSH key path (generates if missing) |
| `NON_INTERACTIVE` | `false` | Skip all prompts |
| `AUTO_DEPLOY` | `false` | Auto `terraform apply` |
| `RETRY_MAX_ATTEMPTS` | `8` | Max apply retries |
| `RETRY_BASE_DELAY` | `15` | Backoff base (seconds) |
| `TF_BACKEND` | `local` | `local` or `gcs` |
| `TF_BACKEND_BUCKET` | — | GCS bucket for remote state |

---

## SSH into Your Instance

After a successful apply, Terraform outputs the external IP and SSH command:

```
Outputs:
  instance_external_ip = "34.X.Y.Z"
  ssh_command = "ssh -i ~/.ssh/cloudbooter_gcp ubuntu@34.X.Y.Z"
```

---

## Teardown

```bash
terraform destroy -var="project_id=my-proj"
```

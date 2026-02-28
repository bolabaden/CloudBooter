# CloudCradle OCI Setup Scripts

CloudCradle provides automated Oracle Cloud Infrastructure (OCI) provisioning scripts in both **Bash** and **PowerShell** implementations. Both scripts offer feature parity and can deploy resources with consistent stable workflows.

## Table of Contents

- [CloudCradle OCI Setup Scripts](#cloudcradle-oci-setup-scripts)
  - [Table of Contents](#table-of-contents)
  - [Overview](#overview)
  - [Quick Start by Operating System](#quick-start-by-operating-system)
    - [Linux](#linux)
    - [macOS](#macos)
    - [Windows](#windows)
  - [Implementation Comparison](#implementation-comparison)
  - [Features](#features)
  - [Prerequisites](#prerequisites)
    - [For Bash Script](#for-bash-script)
    - [For PowerShell Script](#for-powershell-script)
  - [Usage](#usage)
    - [Bash Script](#bash-script)
    - [PowerShell Script](#powershell-script)
    - [Environment Variables](#environment-variables)
  - [What It Does](#what-it-does)
  - [Output](#output)
  - [Troubleshooting](#troubleshooting)
    - [Session Token Expired](#session-token-expired)
    - [Out of Capacity Errors](#out-of-capacity-errors)
    - [WSL Issues](#wsl-issues)
    - [PowerShell Execution Policy](#powershell-execution-policy)
  - [Documentation](#documentation)
  - [See Also](#see-also)

## Overview

CloudCradle automates the deployment of Oracle Cloud Infrastructure Always Free Tier resources. Both implementations:

- Detect and respect Free Tier limits automatically by default.
- Handle transient "Out of Capacity" errors with retry logic
- Generate production-ready Terraform configurations
- Support non-interactive/CI mode via environment variables

Choose the implementation that best matches your environment and workflow preferences.

## Quick Start by Operating System

### Linux

**Recommended: Bash script**

```bash
cd cloud/OCI
chmod +x setup_oci_terraform.sh
./setup_oci_terraform.sh
```

**Alternative: PowerShell (requires PowerShell Core)**

```bash
# Install PowerShell if needed:
# Ubuntu/Debian: sudo apt install -y powershell
# RHEL/CentOS: sudo dnf install -y powershell

pwsh ./setup_oci_terraform.ps1
```

### macOS

**Recommended: Bash script**

```bash
cd cloud/OCI
chmod +x setup_oci_terraform.sh
./setup_oci_terraform.sh
```

**Alternative: PowerShell (requires PowerShell Core)**

```bash
# Install PowerShell if needed:
# brew install --cask powershell

pwsh ./setup_oci_terraform.ps1
```

### Windows

**Recommended: PowerShell script**

```powershell
cd cloud\OCI
.\setup_oci_terraform.ps1
```

**Alternative: Bash (requires WSL, Git Bash, or Cygwin)**

```bash
# Using WSL (Windows Subsystem for Linux):
cd /mnt/c/GitHub/CloudCradle/cloud/OCI
./setup_oci_terraform.sh

# Using Git Bash:
cd /c/GitHub/CloudCradle/cloud/OCI
./setup_oci_terraform.sh
```

**Note for Windows users**: The Bash script automatically detects WSL and handles browser authentication appropriately.

## Implementation Comparison

| Feature | Bash | PowerShell |
|---------|------|------------|
| **OS Support** | Linux, macOS, WSL, Git Bash, Cygwin | Windows, Linux, macOS (via PowerShell Core) |
| **Maturity** | Original implementation (3,063 lines) | Full feature parity (3,261 lines) |
| **Dependencies** | Bash 4.0+, jq, curl | PowerShell 5.1+ / PowerShell Core 7+ |
| **Auto-installs** | OCI CLI, Terraform | OCI CLI, Terraform |
| **Free Tier Validation** | ✅ Full | ✅ Full |
| **Retry Logic** | ✅ Exponential backoff | ✅ Exponential backoff |
| **Non-interactive Mode** | ✅ Via env vars | ✅ Via env vars |
| **Resource Inventory** | ✅ 8 resource types | ✅ 8 resource types |
| **Windows Native** | ⚠️ Requires WSL/Git Bash | ✅ Native |

## Features

- **Full Free Tier Support**: Automatically provisions AMD and ARM instances within Always Free limits
- **Cross-platform**: Works on Linux, macOS, Windows (with appropriate script choice)
- **Idempotent Design**: Safe to run multiple times; detects existing resources
- **Automatic Tooling Setup**: Installs OCI CLI and Terraform if missing
- **Comprehensive Error Handling**: Retry logic with exponential backoff for transient failures
- **Resource Discovery**: Inventories existing VCNs, subnets, instances, volumes before changes
- **SSH Key Generation**: Creates and manages SSH keypairs in `./ssh_keys/`
- **Terraform Generation**: Produces production-ready IaC files
- **Session Token Auth**: Browser-based authentication flow (no API keys in files)
- **Non-interactive Mode**: Full automation support for CI/CD pipelines

## Prerequisites

### For Bash Script

- Bash 4.0+ (pre-installed on Linux/macOS; available via WSL/Git Bash on Windows)
- OCI CLI (auto-installed if missing)
- Terraform (auto-installed if missing)
- `jq` (JSON processor)
- `curl`
- Internet connection for OCI API calls

### For PowerShell Script

- PowerShell 5.1+ (Windows) or PowerShell Core 7+ (cross-platform)
- OCI CLI (auto-installed if missing)
- Terraform (auto-installed if missing)
- Internet connection for OCI API calls

Both scripts will check for and install missing dependencies automatically.

## Usage

### Bash Script

**Basic interactive mode:**

```bash
./setup_oci_terraform.sh
```

**Non-interactive automation:**

```bash
NON_INTERACTIVE=true AUTO_USE_EXISTING=true AUTO_DEPLOY=true ./setup_oci_terraform.sh
```

**Use specific OCI profile:**

```bash
OCI_PROFILE=MyProfile ./setup_oci_terraform.sh
```

**Force re-authentication:**

```bash
FORCE_REAUTH=true ./setup_oci_terraform.sh
```

### PowerShell Script

**Basic interactive mode:**

```powershell
.\setup_oci_terraform.ps1
```

**Non-interactive automation:**

```powershell
$env:NON_INTERACTIVE='true'
$env:AUTO_USE_EXISTING='true'
$env:AUTO_DEPLOY='true'
.\setup_oci_terraform.ps1
```

**Use specific OCI profile:**

```powershell
$env:OCI_PROFILE='MyProfile'
.\setup_oci_terraform.ps1
```

**Force re-authentication:**

```powershell
$env:FORCE_REAUTH='true'
.\setup_oci_terraform.ps1
```

### Environment Variables

Both implementations support the same environment variables for automation:

| Variable | Description | Default |
|----------|-------------|---------|
| `NON_INTERACTIVE` | Run without prompts | `false` |
| `AUTO_USE_EXISTING` | Automatically use existing instances | `false` |
| `AUTO_DEPLOY` | Automatically deploy without confirmation | `false` |
| `FORCE_REAUTH` | Force browser re-authentication | `false` |
| `OCI_PROFILE` | Use specific OCI profile | `DEFAULT` |
| `OCI_AUTH_REGION` | Skip region selection (e.g., `us-chicago-1`) | (prompt) |
| `RETRY_MAX_ATTEMPTS` | Max retry attempts for capacity errors | `8` |
| `RETRY_BASE_DELAY` | Base retry delay in seconds | `15` |
| `DEBUG` | Enable verbose debugging output | `false` |
| `TF_BACKEND` | Terraform backend type (`local` or `oci`) | `local` |
| `TF_BACKEND_BUCKET` | OCI Object Storage bucket for remote state | (none) |

## What It Does

Both scripts follow the same workflow:

1. **Installs Dependencies**
   - OCI CLI (if not present)
   - Terraform (if not present)
   - Required JSON processors

2. **Sets Up Authentication**
   - Browser-based session tokens (primary method)
   - Instance Principal authentication (for compute instances)

3. **Discovers Existing Resources**
   - VCNs and networking components
   - Compute instances (AMD and ARM)
   - Storage volumes (boot and block)
   - Validates against Free Tier limits

4. **Generates SSH Keys**
   - Creates RSA keypair in `./ssh_keys/`
   - Configures public key for instance access

5. **Creates Terraform Files**
   - `provider.tf` - OCI provider with session token authentication
   - `variables.tf` - Free Tier limit checks using Terraform `check` blocks
   - `main.tf` - VCN, subnets, security lists, compute instances
   - `data_sources.tf` - Dynamic data queries (images, availability domains)
   - `block_volumes.tf` - Optional additional storage configurations
   - `cloud-init.yaml` - Instance initialization scripts

6. **Validates Configuration**
   - Ensures requested resources fit within Always Free Tier limits
   - Prevents over-provisioning before deployment

7. **Deploys Infrastructure** (if AUTO_DEPLOY=true)
   - Runs `terraform init`, `plan`, and `apply`
   - Handles "Out of Capacity" errors with automatic retries

## Output

After successful execution, you'll see:

```
[SUCCESS] ==================== SETUP COMPLETE ====================
[SUCCESS] OCI Terraform setup completed successfully!
[INFO] Next steps:
[INFO]   1. terraform init
[INFO]   2. terraform plan
[INFO]   3. terraform apply
```

Generated files will be in the current directory:

```
cloud/OCI/
├── provider.tf          # OCI provider configuration
├── variables.tf         # Free Tier validation checks
├── main.tf             # Infrastructure resources
├── data_sources.tf     # OCI data sources
├── block_volumes.tf    # Storage configurations
├── cloud-init.yaml     # Instance initialization
├── terraform.tfstate   # Terraform state (after apply)
└── ssh_keys/           # Generated SSH keypairs
    ├── oci_rsa
    └── oci_rsa.pub
```

## Troubleshooting

### Session Token Expired

OCI session tokens expire after a period of inactivity. Refresh your token:

**Bash:**
```bash
oci session refresh --profile DEFAULT
```

**PowerShell:**
```powershell
oci session refresh --profile DEFAULT
```

### Out of Capacity Errors

OCI Always Free Tier regions frequently experience capacity constraints. Both scripts include retry logic with exponential backoff (default: 8 attempts, 15-second base delay).

**Manual retry with Terraform:**
```bash
# Bash
terraform apply

# PowerShell
terraform apply
```

**Adjust retry parameters:**
```bash
# Bash
RETRY_MAX_ATTEMPTS=12 RETRY_BASE_DELAY=30 ./setup_oci_terraform.sh

# PowerShell
$env:RETRY_MAX_ATTEMPTS='12'
$env:RETRY_BASE_DELAY='30'
.\setup_oci_terraform.ps1
```

### WSL Issues

The Bash script automatically detects Windows Subsystem for Linux and handles browser authentication appropriately. If you encounter issues:

1. Ensure WSL 2 is installed: `wsl --status`
2. Verify network connectivity: `curl -I https://cloud.oracle.com`
3. Use native Windows PowerShell script as alternative

### PowerShell Execution Policy

If you see "script cannot be loaded because running scripts is disabled":

```powershell
# Check current policy
Get-ExecutionPolicy

# Allow local scripts (recommended)
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# Or bypass for single execution
powershell -ExecutionPolicy Bypass -File .\setup_oci_terraform.ps1
```

## Documentation

- **[QUICKSTART.md](docs/QUICKSTART.md)** - Step-by-step walkthrough for manual OCI console setup
- **[OVERVIEW.md](docs/OVERVIEW.md)** - Comprehensive guide to OCI Always Free Tier with technical details
- **[FREE_TIER_LIMITS.md](docs/FREE_TIER_LIMITS.md)** - Complete reference for Always Free resource limits and maximization strategies

## See Also

- [Main Repository README](../../README.md)
- [Oracle Cloud Always Free Documentation](https://www.oracle.com/cloud/free/)
- [OCI CLI Documentation](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/cliconcepts.htm)
- [Terraform OCI Provider](https://registry.terraform.io/providers/oracle/oci/latest/docs)

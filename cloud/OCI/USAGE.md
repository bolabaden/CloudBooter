# Bash Implementation

The Bash implementation is the original and most mature version of Cloudbooter. It's recommended for Linux and macOS users.

## Features

- Full-featured implementation with all Cloudbooter capabilities
- Cross-platform support (Linux, macOS, WSL)
- No dependencies beyond standard Unix tools and OCI CLI
- Comprehensive error handling and retry logic

## Prerequisites

- Bash 4.0+
- OCI CLI (will be installed automatically)
- Terraform (will be installed if missing)
- `jq` (JSON processor)
- `curl`

## Usage

### Basic Usage

```bash
./setup_oci_terraform.sh
```

### Environment Variables

- `FORCE_REAUTH=true` - Force browser re-authentication
- `OCI_PROFILE=PROFILENAME` - Use specific OCI profile
- `OCI_AUTH_REGION=us-chicago-1` - Skip region selection
- `NON_INTERACTIVE=true` - Run without prompts
- `AUTO_USE_EXISTING=true` - Automatically use existing instances
- `AUTO_DEPLOY=true` - Automatically deploy without confirmation

### Windows Support

For Windows users, use the PowerShell or Batch wrappers:

```powershell
# PowerShell
.\setup_oci_terraform.ps1

# Batch
setup_oci_terraform.bat
```

## What It Does

1. **Installs OCI CLI** (if not present)
2. **Sets up authentication** via browser-based session tokens
3. **Discovers resources** (instances, VCNs, storage)
4. **Generates SSH keys** in `./ssh_keys/`
5. **Creates Terraform files**:
   - `provider.tf` - OCI provider configuration
   - `variables.tf` - Instance configuration
   - `main.tf` - Infrastructure resources
   - `data_sources.tf` - OCI data sources
   - `block_volumes.tf` - Optional block volumes
   - `cloud-init.yaml` - Instance initialization

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

## Troubleshooting

### Session Token Expired

```bash
oci session refresh --profile DEFAULT
```

### Out of Capacity Errors

Use the retry helper:
```bash
make apply-retry
```

### WSL Issues

The script automatically detects WSL and handles browser authentication appropriately.

## See Also

- [Main README](../../README.md)
- [Free Tier Guide](FREE_TIER_LIMITS.md)

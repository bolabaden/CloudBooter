# CloudBooter Copilot Instructions

## Project Overview

**CloudBooter** is an automated Oracle Cloud Infrastructure (OCI) provisioning toolkit that abstracts the complexity of deploying instances within OCI's Always Free Tier limits. It primarily consists of a comprehensive Bash script that orchestrates OCI CLI, Terraform file generation, and infrastructure deployment.

## Architecture & Data Flow

### Core Components

1. **setup_oci_terraform.sh** - Main orchestrator (3,063 lines)
   - Handles OCI authentication via browser-based session tokens
   - Discovers existing resources across 8 tracking maps (`EXISTING_VCNS`, `EXISTING_SUBNETS`, etc.)
   - Generates idempotent Terraform files dynamically based on user configuration
   - Implements retry logic with exponential backoff for transient "Out of Capacity" errors
2. **Terraform Files (Generated Outputs)**
   - `provider.tf` - OCI provider with session token authentication
   - `main.tf` - VCN, subnets, security lists, compute instances
   - `variables.tf` - Free Tier limit checks using Terraform `check` blocks
   - `data_sources.tf` - Dynamic data queries (availability domains, regions, etc.)
   - `block_volumes.tf` - (Optional) additional storage configurations
   - `cloud-init.yaml` - Instance initialization scripts

3. **Documentation**
   - `OCI_FREE_TIER_GUIDE.md` - Complete limits reference (canonical source for constraints)
   - `BASH_OCI_SETUP_USAGE.md` - User-facing workflows

### Data Flow

```
User runs script
  ↓
[Auth Detection] → Browser session token OR Instance Principal
  ↓
[Resource Inventory] → Query existing VCNs, instances, volumes
  ↓
[Config Prompts/Env Vars] → AMD count, ARM OCPUs/memory, hostnames
  ↓
[Free Tier Validation] → Reject configs exceeding hard limits
  ↓
[Terraform Generation] → Create provider.tf, main.tf, etc.
  ↓
[Deployment] → terraform init → plan → apply (with retry loop for Out-of-Capacity)
```

## Critical Design Patterns

### 1. Idempotency & Existing Resource Handling

The script is designed to be run repeatedly safely. Key mechanisms:

- **Inventory maps** (`EXISTING_AMD_INSTANCES`, `EXISTING_ARM_INSTANCES`) are populated before any modifications
- **User can choose**: use existing instances or provision new ones
- Functions like `configure_from_existing_instances()` allow importing already-created resources into Terraform state
- Never assumes a clean environment; always validates what's already there

**When modifying**: Always call the appropriate inventory function (`inventory_compute_instances()`, `inventory_networking_resources()`, etc.) before making decisions.

### 2. Free Tier Constraint Enforcement

Hard limits are embedded as Bash readonly constants (lines 71-79) and replicated in Terraform checks:

```bash
FREE_TIER_MAX_AMD_INSTANCES=2
FREE_TIER_MAX_ARM_OCPUS=4
FREE_TIER_MAX_ARM_MEMORY_GB=24
FREE_TIER_MAX_STORAGE_GB=200
```

**Critical**: These must stay synchronized between Bash and Terraform. Update both when OCI changes limits.

The `validate_proposed_config()` function prevents over-provisioning before Terraform generation.

### 3. Out-of-Capacity Retry Strategy

OCI frequently signals "Out of Capacity" for Always Free VMs. The script handles this via:

```bash
out_of_capacity_auto_apply()  # Automatically retries terraform apply
run_cmd_with_retries_and_check()  # General retry wrapper
RETRY_MAX_ATTEMPTS=8  # Default (can override)
RETRY_BASE_DELAY=15  # Exponential backoff in seconds
```

These functions detect capacity errors and auto-retry with backoff. When modifying deployment logic, preserve this retry layer.

### 4. Environment Variable Extensibility

The script supports extensive non-interactive modes via environment variables (see lines 26-39):

```bash
NON_INTERACTIVE=true AUTO_USE_EXISTING=true AUTO_DEPLOY=true ./setup_oci_terraform.sh
OCI_PROFILE=PROFILENAME ./setup_oci_terraform.sh
TF_BACKEND=oci TF_BACKEND_BUCKET=my-bucket ./setup_oci_terraform.sh
```

This design allows CI/CD integration and testing. Always document new configurable behavior via environment variables.

## Developer Workflows

### Common Tasks

**Run in interactive mode** (full prompts):

```bash
./setup_oci_terraform.sh
```

**Non-interactive deployment** (for automation):

```bash
NON_INTERACTIVE=true AUTO_USE_EXISTING=true AUTO_DEPLOY=true ./setup_oci_terraform.sh
```

**Use existing instances** (skip new provisioning):

```bash
AUTO_USE_EXISTING=true ./setup_oci_terraform.sh
```

**Force re-authentication**:

```bash
FORCE_REAUTH=true ./setup_oci_terraform.sh
```

**Debug mode** (uncomment `set -x` in script):

```bash
DEBUG=true ./setup_oci_terraform.sh
```

### Terraform Workflow After Script

```bash
cd g:\GitHub\CloudBooter
terraform init
terraform plan
terraform apply
```

Terraform state defaults to local (`terraform.tfstate`). Optional remote backend via `TF_BACKEND=oci`.

## Code Organization & Patterns

### Function Grouping (Search by Section Headers)

The script uses `# ===...===` delimiters to organize ~60+ functions into logical zones:

- **Lines 121–190**: Logging functions (`print_status`, `print_error`, `prompt_with_default`)
- **Lines 197–274**: Utility functions (`command_exists`, `oci_cmd`, `safe_jq`)
- **Lines 348–492**: Command execution with retries (`oci_cmd`, `retry_with_backoff`)
- **Lines 593–745**: Prerequisites & Terraform installation
- **Lines 752–1138**: OCI authentication (`setup_oci_config`, session token flow)
- **Lines 1175–1306**: Resource discovery (`fetch_oci_config_values`, `generate_ssh_keys`)
- **Lines 1313–1645**: Resource inventory (`inventory_compute_instances`, `inventory_networking_resources`)
- **Lines 1652–1719**: Free Tier validation (`calculate_available_resources`, `validate_proposed_config`)
- **Lines 1726–1980**: User configuration (`prompt_configuration`, `configure_custom_instances`)
- **Lines 2024–2200+**: Terraform file generation (`create_terraform_provider`, `create_terraform_main`)

### Global State Variables

All state is in global associative arrays or scalar variables (lines 87–118). This design allows passing state between functions without subshells:

```bash
declare -gA EXISTING_VCNS=()  # Map: OCID → display_name
declare -gA EXISTING_SUBNETS=()
declare -g tenancy_ocid=""    # Scalar state
declare -g region=""
```

When adding new tracking, follow this pattern.

### Key Helper Functions

- `oci_cmd()` (line 348) - Wraps OCI CLI with auth, timeout, and error handling
- `safe_jq()` (line 386) - JSON parsing with error recovery
- `retry_with_backoff()` (line 407) - Exponential backoff retry loop
- `confirm_action()` (line 567) - Yes/no prompts (respects `NON_INTERACTIVE`)

## Integration Points & External Dependencies

### Oracle Cloud Infrastructure (OCI) CLI

- **Installed automatically** if missing (lines 636–682)
- **Config location**: `~/.oci/config` (overridable via `OCI_CONFIG_FILE`)
- **Auth methods**: Session token (primary) or Instance Principal (for compute)
- **Session refresh**: Users must run `oci session refresh --profile DEFAULT` if token expires

### Terraform

- **Installed automatically** if missing (lines 685–745)
- **Files generated dynamically** → no committed Terraform code (files listed in `.gitignore`)
- **Backend**: Local state by default; optional S3-compatible remote backend for OCI Object Storage
- **Validation**: Terraform checks replicate Free Tier limits as guardrails

### OCI Auth Token Refresh

Session tokens expire. Users see prompts to refresh:

```bash
oci session refresh --profile DEFAULT
```

The script handles this gracefully but users must manage token lifecycle.

## Special Cases & Edge Cases

1. **Windows (WSL/PowerShell)**: Script auto-detects WSL via `is_wsl()` and handles browser auth appropriately. Windows-only users can use wrapper scripts (referenced in docs but not present in repo yet).

2. **Capacity Exhaustion**: OCI Free Tier regions frequently hit "Out of Capacity" errors. The retry loop (15s base delay, 8 max attempts = ~32 minutes max) is intentional.

3. **Idle Instance Reclamation**: OCI reclaims Free Tier VMs if usage < 20% for 7 days. This is a constraint, not a bug.

4. **Home Region Requirement**: Always Free resources must stay in the user's home region. The script enforces this via `OCI_AUTH_REGION`.

5. **Conflicting Configurations**: If user requests 3 AMD instances but limit is 2, `validate_proposed_config()` rejects silently (non-interactive) or prompts interactively.

## Testing & Debugging

- **Dry-run**: Use `terraform plan` after script generates Terraform files
- **Debug mode**: Uncomment `set -x` in line 23 for full bash tracing
- **Retry troubleshooting**: Adjust `RETRY_MAX_ATTEMPTS` and `RETRY_BASE_DELAY` environment variables
- **SSH key verification**: Generated keys stored in `./ssh_keys/` (in `.gitignore`)

## Key Files Reference

- [setup_oci_terraform.sh](../cloud/OCI/setup_oci_terraform.sh) - Main script (source of truth for logic)
- [FREE_TIER_LIMITS.md](../cloud/OCI/FREE_TIER_LIMITS.md) - Limits documentation
- [main.tf](../main.tf) - Example generated Terraform (auto-generated, do not edit)
- [.gitignore](../.gitignore) - Lists sensitive/generated files (terraform.tfstate, ssh_keys, *.tf)

## Contributing Conventions

- **Bash style**: Use `set -euo pipefail`; avoid subshells for state; use local variables in functions
- **Comments**: Section headers with `===` separators; inline comments for non-obvious logic
- **Testing**: Verify idempotency (run twice, expect same result); test with `NON_INTERACTIVE=true`
- **Documentation**: Update both Bash constants and `.md` files when limits change
- **Error handling**: Use `print_error()` for user-facing errors; let `set -e` propagate critical failures

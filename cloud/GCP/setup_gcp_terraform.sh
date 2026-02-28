#!/usr/bin/env bash
# =============================================================================
# setup_gcp_terraform.sh — CloudBooter GCP Provisioner
# =============================================================================
# Automated GCP Always-Free-Tier provisioning toolkit.
# Mirrors the design of setup_oci_terraform.sh but targets GCP.
#
# Usage:
#   ./setup_gcp_terraform.sh
#   NON_INTERACTIVE=true AUTO_DEPLOY=true GCP_PROJECT_ID=my-proj ./setup_gcp_terraform.sh
#
# Environment variables:
#   GCP_PROJECT_ID            — GCP project ID (required; prompted if missing)
#   GCP_REGION                — Compute region (default: us-central1)
#   GCP_ZONE                  — Compute zone   (default: us-central1-a)
#   GCP_INSTANCE_NAME         — Instance hostname (default: cloudbooter-vm)
#   GCP_CREDENTIALS_FILE      — Path to SA key / WIF config JSON
#   GCP_IMPERSONATE_SA        — SA email to impersonate instead of using direct key
#   GCP_ALLOW_PAID_RESOURCES  — Skip free-tier guardrails (set to "true" to allow)
#   GCP_BOOT_DISK_GB          — Boot disk size in GB (max 30, default 20)
#   GCP_SSH_KEY_FILE          — Path to existing SSH public key (generates if missing)
#   GCP_EXTRA_PACKAGES        — Space-separated list of extra apt packages in cloud-init
#   GCP_MODE                  — "gcloud" (default) | "python" (gcloud-free SDK mode)
#   NON_INTERACTIVE           — "true" to suppress all prompts
#   AUTO_DEPLOY               — "true" to run terraform apply without prompting
#   AUTO_USE_EXISTING         — "true" to automatically reuse discovered resources
#   SKIP_CONFIG               — "true" to skip all configuration prompts
#   FORCE_REAUTH              — "true" to force re-run of auth setup
#   DEBUG                     — "true" to enable set -x tracing
#   RETRY_MAX_ATTEMPTS        — Max terraform apply retries (default 8)
#   RETRY_BASE_DELAY          — Base delay in seconds for backoff (default 15)
#   TF_BACKEND                — "local" (default) | "gcs"
#   TF_BACKEND_BUCKET         — GCS bucket for remote state (requires TF_BACKEND=gcs)
# =============================================================================
set -euo pipefail

# Debug mode
[[ "${DEBUG:-false}" == "true" ]] && set -x

# =============================================================================
# SECTION 1 — Free-Tier Constants (stay in sync with free_tier.py and Terraform check blocks)
# =============================================================================
readonly FREE_MACHINE_TYPE="e2-micro"
readonly FREE_COMPUTE_HOURS_PER_MONTH=744
readonly FREE_STANDARD_PD_GB=30
readonly FREE_STORAGE_GB=5
readonly FREE_SECRET_VERSIONS=6
readonly FREE_SECRET_OPS_PER_MONTH=10000
readonly FREE_ARTIFACT_REGISTRY_GB=0    # 0.5 but use integer floor
readonly FREE_CLOUD_BUILD_MINS=2500
readonly FREE_LOGGING_GIB=50

# Allowed regions (associative set emulated as space-delimited string)
readonly FREE_COMPUTE_REGIONS="us-central1 us-west1 us-east1"
readonly FREE_STORAGE_REGIONS="us-east1 us-west1 us-central1"

# Default configuration values
readonly DEFAULT_REGION="us-central1"
readonly DEFAULT_ZONE="us-central1-a"
readonly DEFAULT_INSTANCE_NAME="cloudbooter-vm"
readonly DEFAULT_BOOT_DISK_GB=20
readonly DEFAULT_SSH_KEY_FILE="${HOME}/.ssh/cloudbooter_gcp"

# Retry configuration
RETRY_MAX_ATTEMPTS="${RETRY_MAX_ATTEMPTS:-8}"
RETRY_BASE_DELAY="${RETRY_BASE_DELAY:-15}"

# GCP quota / capacity error patterns to catch for retry
readonly -a GCP_RETRY_PATTERNS=(
    "RESOURCE_EXHAUSTED"
    "rateLimitExceeded"
    "quotaExceeded"
    "ZONE_RESOURCE_POOL_EXHAUSTED"
    "Error 429"
    "Error 503"
    "Backend Error"
    "quota exceeded"
    "QUOTA_EXCEEDED"
)

# =============================================================================
# SECTION 2 — Script-level State Variables
# =============================================================================
declare -g project_id=""
declare -g region="${GCP_REGION:-${DEFAULT_REGION}}"
declare -g zone="${GCP_ZONE:-${DEFAULT_ZONE}}"
declare -g instance_name="${GCP_INSTANCE_NAME:-${DEFAULT_INSTANCE_NAME}}"
declare -g boot_disk_gb="${GCP_BOOT_DISK_GB:-${DEFAULT_BOOT_DISK_GB}}"
declare -g credentials_file="${GCP_CREDENTIALS_FILE:-}"
declare -g impersonate_sa="${GCP_IMPERSONATE_SA:-}"
declare -g ssh_public_key=""
declare -g ssh_key_file="${GCP_SSH_KEY_FILE:-${DEFAULT_SSH_KEY_FILE}}"
declare -g gcp_mode="${GCP_MODE:-gcloud}"
declare -g extra_packages="${GCP_EXTRA_PACKAGES:-}"

# Resource inventory maps
declare -gA EXISTING_VPCS=()           # name → self_link
declare -gA EXISTING_SUBNETS=()        # name → self_link
declare -gA EXISTING_FIREWALLS=()      # name → network
declare -gA EXISTING_INSTANCES=()      # name → status
declare -gA EXISTING_DISKS=()          # name → size_gb
declare -gA EXISTING_STATIC_IPS=()     # name → address (WARN: these cost money)
declare -gA EXISTING_BUCKETS=()        # name → location

# Flags
declare -g auth_configured=false
declare -g terraform_output_dir=""

# =============================================================================
# SECTION 3 — Logging Helpers
# =============================================================================
readonly RESET="\033[0m"
readonly BOLD="\033[1m"
readonly RED="\033[31m"
readonly GREEN="\033[32m"
readonly YELLOW="\033[33m"
readonly BLUE="\033[34m"
readonly CYAN="\033[36m"
readonly WHITE="\033[37m"

print_status()  { echo -e "${BLUE}[INFO]${RESET}  $*"; }
print_success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
print_warning() { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
print_error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
print_debug()   { [[ "${DEBUG:-false}" == "true" ]] && echo -e "${CYAN}[DEBUG]${RESET} $*" || true; }
print_header()  { echo -e "\n${BOLD}${WHITE}=== $* ===${RESET}\n"; }

# =============================================================================
# SECTION 4 — Utility Functions
# =============================================================================

command_exists() { command -v "$1" &>/dev/null; }

is_wsl() {
    [[ -f /proc/version ]] && grep -qi "microsoft" /proc/version 2>/dev/null
}

is_macos() { [[ "$(uname -s)" == "Darwin" ]]; }
is_linux() { [[ "$(uname -s)" == "Linux" ]]; }

# Strip carriage returns (handles CR/LF copy-paste artefacts)
strip_cr() { tr -d '\r'; }

prompt_with_default() {
    local prompt="$1"
    local default="$2"
    local result
    if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
        echo "${default}"
        return
    fi
    read -r -p "${prompt} [${default}]: " result < /dev/tty
    result="$(echo "${result}" | strip_cr)"
    echo "${result:-${default}}"
}

prompt_int_range() {
    local prompt="$1"
    local min="$2"
    local max="$3"
    local default="$4"
    local result
    while true; do
        result="$(prompt_with_default "${prompt} (${min}-${max})" "${default}")"
        if [[ "${result}" =~ ^[0-9]+$ ]] && (( result >= min && result <= max )); then
            echo "${result}"
            return
        fi
        print_warning "Please enter an integer between ${min} and ${max}."
    done
}

confirm_action() {
    local prompt="$1"
    local default="${2:-y}"
    if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
        [[ "${default}" == "y" ]] && return 0 || return 1
    fi
    local answer
    read -r -p "${prompt} [y/N]: " answer < /dev/tty
    answer="$(echo "${answer}" | strip_cr | tr '[:upper:]' '[:lower:]')"
    [[ "${answer}" == "y" || "${answer}" == "yes" ]]
}

# safe JSON extraction — returns empty string on failure
safe_jq() {
    local query="$1"
    local json="$2"
    echo "${json}" | jq -r "${query}" 2>/dev/null || echo ""
}

# =============================================================================
# SECTION 5 — gcloud Command Wrapper
# =============================================================================

# Execute a gcloud command with standard flags and JSON output.
# In GCP_MODE=python, delegates to the Python CLI.
gcloud_cmd() {
    local -a args=("$@")
    if [[ "${gcp_mode}" == "python" ]]; then
        python_gcp_cmd "${args[@]}"
        return
    fi
    local -a gcloud_args=(
        gcloud "${args[@]}"
        --format=json
        --quiet
    )
    [[ -n "${project_id}" ]] && gcloud_args+=(--project "${project_id}")
    [[ -n "${credentials_file}" ]] && \
        GOOGLE_APPLICATION_CREDENTIALS="${credentials_file}" \
        gcloud_args=("${gcloud_args[@]}")

    print_debug "gcloud ${args[*]}"
    "${gcloud_args[@]}" 2>/dev/null
}

# Tolerant JSON parser: returns {} on failure
safe_gcloud_json() {
    local output
    output=$(gcloud_cmd "$@" 2>/dev/null) || output="[]"
    if ! echo "${output}" | jq . &>/dev/null; then
        echo "[]"
    else
        echo "${output}"
    fi
}

# Python SDK fallback (used in GCP_MODE=python)
python_gcp_cmd() {
    if ! command_exists python3; then
        print_error "python3 not found — cannot use GCP_MODE=python"
        return 1
    fi
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PYTHONPATH="${script_dir}/src:${PYTHONPATH:-}" python3 -m cloudbooter "$@"
}

# =============================================================================
# SECTION 6 — Prerequisites & Installation
# =============================================================================

install_gcloud_sdk() {
    print_header "Installing Google Cloud SDK"

    if command_exists gcloud; then
        local ver
        ver=$(gcloud version --format="value(Google Cloud SDK)" 2>/dev/null || echo "?")
        print_success "gcloud already installed (${ver})"
        return 0
    fi

    print_status "Attempting Tier 1 install (package manager)..."

    if is_macos && command_exists brew; then
        brew install --cask google-cloud-sdk && return 0
    fi

    if is_linux; then
        if command_exists snap; then
            sudo snap install google-cloud-sdk --classic && return 0
        fi
        if command_exists apt-get; then
            # Add HashiCorp-style Google Cloud SDK apt repo
            curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
                | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg 2>/dev/null
            echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] \
https://packages.cloud.google.com/apt cloud-sdk main" \
                | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list > /dev/null
            sudo apt-get update -qq && sudo apt-get install -y google-cloud-cli && return 0
        fi
    fi

    print_status "Attempting Tier 2 install (interactive installer)..."
    local install_script="/tmp/gcloud_install_$$.sh"
    if curl -fsSL https://sdk.cloud.google.com -o "${install_script}"; then
        bash "${install_script}" --disable-prompts --install-dir="${HOME}/.local" && \
            export PATH="${HOME}/.local/google-cloud-sdk/bin:${PATH}" && \
            return 0
    fi

    # Tier 3 — python SDK only
    print_warning "gcloud SDK could not be installed. Switching to GCP_MODE=python."
    gcp_mode="python"
    return 0
}

install_terraform() {
    print_header "Installing Terraform"

    if command_exists terraform; then
        local ver
        ver=$(terraform version -json 2>/dev/null | jq -r '.terraform_version' 2>/dev/null || echo "?")
        print_success "terraform already installed (v${ver})"
        return 0
    fi

    if is_macos && command_exists brew; then
        brew tap hashicorp/tap && brew install hashicorp/tap/terraform && return 0
    fi

    if is_linux && command_exists apt-get; then
        wget -qO- https://apt.releases.hashicorp.com/gpg \
            | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg 2>/dev/null
        echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs 2>/dev/null || echo jammy) main" \
            | sudo tee /etc/apt/sources.list.d/hashicorp.list > /dev/null
        sudo apt-get update -qq && sudo apt-get install -y terraform && return 0
    fi

    # Direct zip download fallback
    local tf_version
    tf_version=$(curl -fsSL https://checkpoint-api.hashicorp.com/v1/check/terraform \
        | jq -r '.current_version' 2>/dev/null || echo "1.9.8")
    local arch="amd64"
    [[ "$(uname -m)" == "arm64" ]] && arch="arm64"
    local os_slug="linux"
    is_macos && os_slug="darwin"
    local url="https://releases.hashicorp.com/terraform/${tf_version}/terraform_${tf_version}_${os_slug}_${arch}.zip"
    curl -fsSL "${url}" -o /tmp/terraform_$$.zip && \
        unzip -qq /tmp/terraform_$$.zip -d "${HOME}/.local/bin" && \
        chmod +x "${HOME}/.local/bin/terraform" && \
        export PATH="${HOME}/.local/bin:${PATH}" && \
        print_success "Terraform ${tf_version} installed to ~/.local/bin" && return 0

    print_error "Could not install Terraform automatically."
    return 1
}

ensure_python_deps() {
    print_status "Ensuring Python dependencies are installed..."
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local req="${script_dir}/requirements.txt"

    if command_exists pip3 && [[ -f "${req}" ]]; then
        pip3 install -q -r "${req}" && print_success "Python deps installed." && return 0
    fi
    print_warning "pip3 not found or requirements.txt missing. Skipping Python deps."
}

# =============================================================================
# SECTION 7 — Authentication
# =============================================================================

setup_gcp_auth() {
    print_header "GCP Authentication"

    if [[ "${auth_configured}" == "true" && "${FORCE_REAUTH:-false}" != "true" ]]; then
        print_success "Authentication already configured."
        return 0
    fi

    # Detect pattern
    local cred_type=""
    if [[ -n "${credentials_file}" && -f "${credentials_file}" ]]; then
        cred_type=$(jq -r '.type // "unknown"' "${credentials_file}" 2>/dev/null || echo "unknown")
    fi

    case "${cred_type}" in
        service_account)
            print_status "Using Service Account key: ${credentials_file}"
            if [[ "${gcp_mode}" == "gcloud" ]]; then
                gcloud auth activate-service-account \
                    --key-file="${credentials_file}" --quiet 2>/dev/null \
                    && print_success "SA key activated." || \
                    print_warning "gcloud activate-service-account failed; relying on GOOGLE_APPLICATION_CREDENTIALS"
                export GOOGLE_APPLICATION_CREDENTIALS="${credentials_file}"
            fi
            ;;
        external_account)
            print_status "Using Workload Identity Federation config: ${credentials_file}"
            export GOOGLE_APPLICATION_CREDENTIALS="${credentials_file}"
            ;;
        "")
            if [[ -n "${impersonate_sa}" ]]; then
                print_status "Using service account impersonation: ${impersonate_sa}"
            else
                print_status "No credentials file set — using Application Default Credentials (ADC)"
                if [[ "${gcp_mode}" == "gcloud" ]] && ! gcloud auth application-default print-access-token &>/dev/null; then
                    if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
                        print_error "ADC not configured and cannot prompt. Set GCP_CREDENTIALS_FILE."
                        return 1
                    fi
                    print_status "Running: gcloud auth application-default login"
                    gcloud auth application-default login
                fi
            fi
            ;;
        *)
            print_warning "Unknown credential type '${cred_type}'; using as-is."
            export GOOGLE_APPLICATION_CREDENTIALS="${credentials_file}"
            ;;
    esac

    # Validate
    if [[ "${gcp_mode}" == "gcloud" ]]; then
        local active_account
        active_account=$(gcloud auth list --filter="status:ACTIVE" --format="value(account)" 2>/dev/null | head -n1)
        if [[ -z "${active_account}" ]]; then
            print_error "No active gcloud account found."
            return 1
        fi
        print_success "Active account: ${active_account}"
    else
        print_status "GCP_MODE=python — credential verification deferred to Python SDK."
    fi

    auth_configured=true
}

# =============================================================================
# SECTION 8 — Resource Inventory
# =============================================================================

inventory_vpcs() {
    print_status "Inventorying VPCs..."
    local json
    json=$(safe_gcloud_json compute networks list 2>/dev/null)
    while IFS=$'\t' read -r name self_link; do
        [[ -n "${name}" ]] && EXISTING_VPCS["${name}"]="${self_link}"
    done < <(echo "${json}" | jq -r '.[] | [.name, .selfLink] | @tsv' 2>/dev/null)
    print_debug "VPCs found: ${#EXISTING_VPCS[@]}"
}

inventory_subnets() {
    print_status "Inventorying subnets in region ${region}..."
    local json
    json=$(safe_gcloud_json compute networks subnets list --filter="region:${region}")
    while IFS=$'\t' read -r name self_link; do
        [[ -n "${name}" ]] && EXISTING_SUBNETS["${name}"]="${self_link}"
    done < <(echo "${json}" | jq -r '.[] | [.name, .selfLink] | @tsv' 2>/dev/null)
    print_debug "Subnets found: ${#EXISTING_SUBNETS[@]}"
}

inventory_firewalls() {
    print_status "Inventorying firewall rules..."
    local json
    json=$(safe_gcloud_cmd_or_empty compute firewall-rules list)
    while IFS=$'\t' read -r name network; do
        [[ -n "${name}" ]] && EXISTING_FIREWALLS["${name}"]="${network}"
    done < <(echo "${json}" | jq -r '.[] | [.name, .network] | @tsv' 2>/dev/null)
    print_debug "Firewalls found: ${#EXISTING_FIREWALLS[@]}"
}

inventory_instances() {
    print_status "Inventorying compute instances in zone ${zone}..."
    local json
    json=$(safe_gcloud_json compute instances list --filter="zone:(${zone})")
    while IFS=$'\t' read -r name status; do
        [[ -n "${name}" ]] && EXISTING_INSTANCES["${name}"]="${status}"
    done < <(echo "${json}" | jq -r '.[] | [.name, .status] | @tsv' 2>/dev/null)
    print_debug "Instances found: ${#EXISTING_INSTANCES[@]}"
}

inventory_disks() {
    print_status "Inventorying disks in zone ${zone}..."
    local json
    json=$(safe_gcloud_json compute disks list --filter="zone:(${zone})")
    while IFS=$'\t' read -r name size; do
        [[ -n "${name}" ]] && EXISTING_DISKS["${name}"]="${size}"
    done < <(echo "${json}" | jq -r '.[] | [.name, .sizeGb] | @tsv' 2>/dev/null)
    print_debug "Disks found: ${#EXISTING_DISKS[@]}"
}

inventory_static_ips() {
    print_status "Inventorying static IPs (BILLING TRAP — unattached IPs cost money)..."
    local json
    json=$(safe_gcloud_json compute addresses list --filter="region:(${region})")
    while IFS=$'\t' read -r name address status; do
        [[ -n "${name}" ]] && EXISTING_STATIC_IPS["${name}"]="${address}|${status}"
        if [[ "${status}" == "RESERVED" ]]; then
            print_warning "  BILLING TRAP: Static IP '${name}' (${address}) is RESERVED but not attached — you are being charged."
        fi
    done < <(echo "${json}" | jq -r '.[] | [.name, .address, .status] | @tsv' 2>/dev/null)
    print_debug "Static IPs found: ${#EXISTING_STATIC_IPS[@]}"
}

inventory_buckets() {
    print_status "Inventorying GCS buckets..."
    local json
    json=$(safe_gcloud_json storage buckets list 2>/dev/null || echo "[]")
    while IFS=$'\t' read -r name location; do
        [[ -n "${name}" ]] && EXISTING_BUCKETS["${name}"]="${location}"
    done < <(echo "${json}" | jq -r '.[] | [.name, .location] | @tsv' 2>/dev/null)
    print_debug "Buckets found: ${#EXISTING_BUCKETS[@]}"
}

run_full_inventory() {
    print_header "Resource Inventory"
    inventory_vpcs
    inventory_subnets
    inventory_firewalls
    inventory_instances
    inventory_disks
    inventory_static_ips
    inventory_buckets
}

display_inventory_summary() {
    echo ""
    print_header "Inventory Summary"
    echo "  VPCs:         ${#EXISTING_VPCS[@]}"
    echo "  Subnets:      ${#EXISTING_SUBNETS[@]}"
    echo "  Firewalls:    ${#EXISTING_FIREWALLS[@]}"
    echo "  Instances:    ${#EXISTING_INSTANCES[@]}"
    echo "  Disks:        ${#EXISTING_DISKS[@]}"
    echo "  Static IPs:   ${#EXISTING_STATIC_IPS[@]}"
    echo "  GCS Buckets:  ${#EXISTING_BUCKETS[@]}"

    if [[ ${#EXISTING_INSTANCES[@]} -gt 0 ]]; then
        echo ""
        print_status "Existing instances:"
        for name in "${!EXISTING_INSTANCES[@]}"; do
            echo "    - ${name}: ${EXISTING_INSTANCES[$name]}"
        done
    fi
}

# Helper to avoid failing when gcloud not available
safe_gcloud_cmd_or_empty() {
    if [[ "${gcp_mode}" != "gcloud" ]] || ! command_exists gcloud; then
        echo "[]"
        return
    fi
    safe_gcloud_json "$@"
}

# =============================================================================
# SECTION 9 — Free Tier Validation
# =============================================================================

validate_proposed_config() {
    local check_machine="${1:-${FREE_MACHINE_TYPE}}"
    local check_region="${2:-${region}}"
    local check_disk="${3:-${boot_disk_gb}}"
    local errors=0

    print_header "Free-Tier Validation"

    # Machine type
    if [[ "${check_machine}" != "${FREE_MACHINE_TYPE}" ]]; then
        print_error "Machine type '${check_machine}' is NOT free tier. Only '${FREE_MACHINE_TYPE}' qualifies."
        (( errors++ )) || true
    else
        print_success "Machine type: ${check_machine} ✓"
    fi

    # Region
    if ! echo "${FREE_COMPUTE_REGIONS}" | grep -qw "${check_region}"; then
        print_error "Region '${check_region}' not in free tier list: ${FREE_COMPUTE_REGIONS}"
        (( errors++ )) || true
    else
        print_success "Region: ${check_region} ✓"
    fi

    # Disk
    if (( check_disk > FREE_STANDARD_PD_GB )); then
        print_error "Boot disk ${check_disk} GB exceeds free tier cap of ${FREE_STANDARD_PD_GB} GB."
        (( errors++ )) || true
    else
        print_success "Boot disk: ${check_disk} GB ✓"
    fi

    if [[ "${GCP_ALLOW_PAID_RESOURCES:-false}" == "true" ]]; then
        print_warning "GCP_ALLOW_PAID_RESOURCES=true — free-tier violations allowed."
        return 0
    fi

    return "${errors}"
}

# =============================================================================
# SECTION 10 — SSH Key Management
# =============================================================================

setup_ssh_keys() {
    print_header "SSH Keys"

    if [[ -f "${ssh_key_file}.pub" ]]; then
        ssh_public_key="$(cat "${ssh_key_file}.pub")"
        print_success "Using existing public key: ${ssh_key_file}.pub"
        return 0
    fi

    if [[ "${NON_INTERACTIVE:-false}" != "true" ]]; then
        if confirm_action "Generate new SSH key pair at ${ssh_key_file}?"; then
            mkdir -p "$(dirname "${ssh_key_file}")"
            ssh-keygen -t ed25519 -f "${ssh_key_file}" -C "cloudbooter-gcp" -N "" -q
            print_success "SSH key generated: ${ssh_key_file}"
        fi
    else
        mkdir -p "$(dirname "${ssh_key_file}")"
        ssh-keygen -t ed25519 -f "${ssh_key_file}" -C "cloudbooter-gcp" -N "" -q
        print_success "SSH key generated (non-interactive): ${ssh_key_file}"
    fi

    ssh_public_key="$(cat "${ssh_key_file}.pub")"
}

# =============================================================================
# SECTION 11 — User Configuration
# =============================================================================

prompt_configuration() {
    print_header "Configuration"

    if [[ "${SKIP_CONFIG:-false}" == "true" ]]; then
        print_status "SKIP_CONFIG=true — using env/defaults."
        return 0
    fi

    # Project ID
    if [[ -z "${project_id}" ]]; then
        local default_project
        default_project=$(gcloud config get project 2>/dev/null | strip_cr || echo "")
        project_id="$(prompt_with_default "GCP Project ID" "${default_project}")"
    fi
    [[ -z "${project_id}" ]] && { print_error "Project ID is required."; exit 1; }

    # Region
    region="$(prompt_with_default "Compute region" "${region}")"

    # Auto-select zone if not set
    if [[ "${zone}" == "${DEFAULT_ZONE}" && "${region}" != "${DEFAULT_REGION}" ]]; then
        zone="${region}-a"
    fi
    zone="$(prompt_with_default "Compute zone" "${zone}")"

    # Instance name
    if [[ ${#EXISTING_INSTANCES[@]} -gt 0 ]] && [[ "${AUTO_USE_EXISTING:-false}" != "true" ]]; then
        echo ""
        print_warning "Found existing instances:"
        for name in "${!EXISTING_INSTANCES[@]}"; do
            echo "  - ${name}: ${EXISTING_INSTANCES[$name]}"
        done
        if confirm_action "Use an existing instance instead of creating a new one?"; then
            instance_name="$(prompt_with_default "Existing instance name" "$(echo "${!EXISTING_INSTANCES[@]}" | awk '{print $1}')")"
            print_success "Will target existing instance: ${instance_name}"
            return 0
        fi
    fi

    instance_name="$(prompt_with_default "Instance name" "${instance_name}")"

    # Boot disk
    boot_disk_gb="$(prompt_int_range "Boot disk size GB" 10 "${FREE_STANDARD_PD_GB}" "${boot_disk_gb}")"

    # Extra packages
    if [[ "${NON_INTERACTIVE:-false}" != "true" ]]; then
        local extra
        extra="$(prompt_with_default "Extra apt packages (space-separated, or blank)" "")"
        extra_packages="${extra}"
    fi
}

# =============================================================================
# SECTION 12 — Terraform File Generation
# =============================================================================

generate_provider_tf() {
    local cred_arg=""
    local impersonate_arg=""
    [[ -n "${credentials_file}" ]] && cred_arg='  credentials = file(var.credentials_file)'
    [[ -n "${impersonate_sa}" ]] && \
        impersonate_arg="  impersonate_service_account = var.impersonate_service_account"

    cat > "${terraform_output_dir}/provider.tf" << PROVIDERF
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

$(generate_backend_block)
}

provider "google" {
  project = var.project_id
  region  = var.region
${cred_arg}
${impersonate_arg}
}
PROVIDERF
    print_success "Generated provider.tf"
}

generate_backend_block() {
    if [[ "${TF_BACKEND:-local}" == "gcs" ]]; then
        cat << BACKENDBLOCK
  backend "gcs" {
    bucket = "${TF_BACKEND_BUCKET:?TF_BACKEND_BUCKET must be set for GCS backend}"
    prefix = "cloudbooter/${project_id}/${instance_name}"
  }
BACKENDBLOCK
    else
        cat << BACKENDBLOCK
  backend "local" {}
BACKENDBLOCK
    fi
}

generate_variables_tf() {
    local cred_variable=""
    [[ -n "${credentials_file}" ]] && cred_variable='
variable "credentials_file" {
  description = "Path to GCP service account key file"
  type        = string
}'

    local impersonation_variable=""
    [[ -n "${impersonate_sa}" ]] && impersonation_variable='
variable "impersonate_service_account" {
  description = "Service account email to impersonate"
  type        = string
  default     = ""
}'

    cat > "${terraform_output_dir}/variables.tf" << VARIABLESF
variable "project_id" {
  description = "GCP project ID"
  type        = string
  default     = "${project_id}"
}

variable "region" {
  description = "GCP compute region"
  type        = string
  default     = "${region}"

  validation {
    condition     = contains(["us-central1", "us-west1", "us-east1"], var.region)
    error_message = "For the GCP Always Free tier, region must be one of: us-central1, us-west1, us-east1."
  }
}

variable "zone" {
  description = "GCP compute zone"
  type        = string
  default     = "${zone}"
}

variable "machine_type" {
  description = "GCE machine type"
  type        = string
  default     = "${FREE_MACHINE_TYPE}"
}

variable "boot_disk_size_gb" {
  description = "Boot disk size in GB (free tier max: ${FREE_STANDARD_PD_GB})"
  type        = number
  default     = ${boot_disk_gb}
}

variable "instance_name" {
  description = "Compute instance name"
  type        = string
  default     = "${instance_name}"
}

variable "ssh_public_key" {
  description = "SSH public key content for instance-level metadata"
  type        = string
  default     = "${ssh_public_key}"
  sensitive   = true
}
${cred_variable}
${impersonation_variable}

# --- Free-tier check blocks ---

check "e2_micro_machine_type" {
  assert {
    condition     = var.machine_type == "${FREE_MACHINE_TYPE}"
    error_message = "Machine type must be ${FREE_MACHINE_TYPE} for the GCP Always Free tier."
  }
}

check "compute_region_free_tier" {
  assert {
    condition     = contains(["us-central1", "us-west1", "us-east1"], var.region)
    error_message = "Region must be us-central1, us-west1, or us-east1 for free compute."
  }
}

check "standard_pd_limit" {
  assert {
    condition     = var.boot_disk_size_gb <= ${FREE_STANDARD_PD_GB}
    error_message = "Boot disk must be <= ${FREE_STANDARD_PD_GB} GB for the GCP Always Free tier."
  }
}
VARIABLESF
    print_success "Generated variables.tf"
}

generate_data_sources_tf() {
    cat > "${terraform_output_dir}/data_sources.tf" << DATAF
data "google_project" "current" {}

data "google_compute_image" "ubuntu" {
  family  = "ubuntu-2404-lts-amd64"
  project = "ubuntu-os-cloud"
}

data "google_compute_zones" "available" {
  region = var.region
  status = "UP"
}
DATAF
    print_success "Generated data_sources.tf"
}

generate_main_tf() {
    cat > "${terraform_output_dir}/main.tf" << MAINF
resource "google_compute_network" "vpc" {
  name                    = "\${var.instance_name}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name          = "\${var.instance_name}-subnet"
  ip_cidr_range = "10.0.0.0/24"
  region        = var.region
  network       = google_compute_network.vpc.id
}

resource "google_compute_firewall" "allow_ssh" {
  name    = "\${var.instance_name}-allow-ssh"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["\${var.instance_name}-ssh"]
}

resource "google_compute_firewall" "allow_icmp" {
  name    = "\${var.instance_name}-allow-icmp"
  network = google_compute_network.vpc.name

  allow {
    protocol = "icmp"
  }

  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_disk" "boot" {
  name  = "\${var.instance_name}-boot"
  type  = "pd-standard"
  zone  = var.zone
  size  = var.boot_disk_size_gb
  image = data.google_compute_image.ubuntu.self_link

  lifecycle {
    prevent_destroy = false
  }
}

resource "google_compute_instance" "vm" {
  name         = var.instance_name
  machine_type = var.machine_type
  zone         = var.zone

  boot_disk {
    source = google_compute_disk.boot.self_link
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id

    access_config {}
  }

  metadata = {
    "ssh-keys" = "ubuntu:\${var.ssh_public_key}"
    user-data  = file("\${path.module}/cloud-init.yaml")
  }

  tags = ["\${var.instance_name}-ssh"]

  scheduling {
    preemptible        = false
    automatic_restart  = true
    on_host_maintenance = "MIGRATE"
  }

  lifecycle {
    ignore_changes = [metadata["ssh-keys"]]
  }
}

output "instance_external_ip" {
  description = "External IP of the compute instance"
  value       = google_compute_instance.vm.network_interface[0].access_config[0].nat_ip
}

output "ssh_command" {
  description = "SSH command to connect to the instance"
  value       = "ssh -i ${ssh_key_file} ubuntu@\${google_compute_instance.vm.network_interface[0].access_config[0].nat_ip}"
}

output "console_url" {
  description = "GCP Console URL for the instance"
  value       = "https://console.cloud.google.com/compute/instancesDetail/zones/\${var.zone}/instances/\${var.instance_name}?project=\${var.project_id}"
}
MAINF
    print_success "Generated main.tf"
}

generate_cloud_init_yaml() {
    local packages=""
    if [[ -n "${extra_packages}" ]]; then
        for pkg in ${extra_packages}; do
            packages+="  - ${pkg}"$'\n'
        done
    fi

    cat > "${terraform_output_dir}/cloud-init.yaml" << CLOUDINIT
#cloud-config
hostname: ${instance_name}
manage_etc_hosts: true

package_update: true
package_upgrade: true
packages:
  - curl
  - wget
  - git
  - vim
  - unzip
  - jq
  - unattended-upgrades
${packages}
runcmd:
  - dpkg-reconfigure --priority=low unattended-upgrades
  - echo "CloudBooter provisioned on \$(date)" >> /var/log/cloudbooter.log
CLOUDINIT
    print_success "Generated cloud-init.yaml"
}

generate_all_terraform_files() {
    print_header "Generating Terraform Files"

    terraform_output_dir="${1:-${PWD}}"
    mkdir -p "${terraform_output_dir}"

    generate_provider_tf
    generate_variables_tf
    generate_data_sources_tf
    generate_main_tf
    generate_cloud_init_yaml

    print_success "All Terraform files written to: ${terraform_output_dir}"
}

# =============================================================================
# SECTION 13 — Terraform Execution with Retry
# =============================================================================

is_quota_error() {
    local output="$1"
    for pattern in "${GCP_RETRY_PATTERNS[@]}"; do
        if echo "${output}" | grep -qi "${pattern}"; then
            return 0
        fi
    done
    return 1
}

run_terraform_init() {
    print_status "Running: terraform init"
    terraform -chdir="${terraform_output_dir}" init -input=false -upgrade
}

run_terraform_plan() {
    print_status "Running: terraform plan"
    terraform -chdir="${terraform_output_dir}" plan \
        -var="project_id=${project_id}" \
        -var="region=${region}" \
        -var="zone=${zone}" \
        -var="instance_name=${instance_name}" \
        -var="boot_disk_size_gb=${boot_disk_gb}" \
        -out="${terraform_output_dir}/tfplan"
}

out_of_quota_auto_apply() {
    local attempt=0
    local delay="${RETRY_BASE_DELAY}"

    print_header "Terraform Apply (with Quota-Error Retry)"

    while (( attempt < RETRY_MAX_ATTEMPTS )); do
        (( attempt++ )) || true
        print_status "Apply attempt ${attempt}/${RETRY_MAX_ATTEMPTS}..."

        local output
        output=$(terraform -chdir="${terraform_output_dir}" apply \
            -auto-approve \
            "${terraform_output_dir}/tfplan" 2>&1) && {
            echo "${output}"
            print_success "Terraform apply succeeded on attempt ${attempt}."
            return 0
        }

        echo "${output}"

        if is_quota_error "${output}"; then
            print_warning "Quota/capacity error detected. Waiting ${delay}s before retry..."
            sleep "${delay}"
            delay=$(( delay * 2 ))  # Exponential backoff
            # Refresh plan before retry
            run_terraform_plan || true
        else
            print_error "Terraform apply failed with a non-retryable error."
            return 1
        fi
    done

    print_error "Terraform apply failed after ${RETRY_MAX_ATTEMPTS} attempts."
    return 1
}

run_cmd_with_retries() {
    local max="${1}"; shift
    local base_delay="${1}"; shift
    local attempt=0
    local delay="${base_delay}"

    while (( attempt < max )); do
        (( attempt++ )) || true
        "$@" && return 0
        print_warning "Command failed (attempt ${attempt}/${max}). Retrying in ${delay}s..."
        sleep "${delay}"
        delay=$(( delay * 2 ))
    done
    return 1
}

# =============================================================================
# SECTION 14 — Main Orchestration
# =============================================================================

print_banner() {
    cat << 'BANNER'

  _____ _                 _ ____              _
 / ____| |               | |  _ \            | |
| |    | | ___  _   _  __| | |_) | ___   ___ | |_ ___ _ __
| |    | |/ _ \| | | |/ _` |  _ < / _ \ / _ \| __/ _ \ '__|
| |____| | (_) | |_| | (_| | |_) | (_) | (_) | ||  __/ |
 \_____|_|\___/ \__,_|\__,_|____/ \___/ \___/ \__\___|_|
                          GCP Edition — Always Free Tier
BANNER
    echo ""
    print_status "CloudBooter GCP Provisioner"
    print_status "Provisions e2-micro instances within GCP Always Free Tier limits"
    echo ""
}

main() {
    print_banner

    # --- 1. Prerequisites ---
    print_header "Prerequisites"
    install_gcloud_sdk
    install_terraform
    ensure_python_deps

    # --- 2. Project ID ---
    project_id="${GCP_PROJECT_ID:-}"
    if [[ -z "${project_id}" ]] && [[ "${NON_INTERACTIVE:-false}" != "true" ]]; then
        local default_proj
        default_proj=$(gcloud config get project 2>/dev/null | strip_cr || echo "")
        project_id="$(prompt_with_default "GCP Project ID" "${default_proj}")"
    fi
    [[ -z "${project_id}" ]] && { print_error "GCP_PROJECT_ID is required."; exit 1; }
    print_success "Project: ${project_id}"

    # --- 3. Auth ---
    setup_gcp_auth

    # --- 4. Inventory ---
    if [[ "${SKIP_INVENTORY:-false}" != "true" ]]; then
        run_full_inventory
        display_inventory_summary
    fi

    # --- 5. Configuration ---
    prompt_configuration

    # --- 6. Validation ---
    validate_proposed_config "${FREE_MACHINE_TYPE}" "${region}" "${boot_disk_gb}"

    # --- 7. SSH Keys ---
    setup_ssh_keys

    # --- 8. Terraform Generation ---
    terraform_output_dir="${TF_OUTPUT_DIR:-${PWD}}"
    generate_all_terraform_files "${terraform_output_dir}"

    # --- 9. Deploy ---
    if [[ "${AUTO_DEPLOY:-false}" == "true" ]] || \
       confirm_action "Run Terraform (init + plan + apply)?"; then

        run_terraform_init
        run_terraform_plan

        if [[ "${AUTO_DEPLOY:-false}" == "true" ]]; then
            out_of_quota_auto_apply
        elif confirm_action "Apply the plan?"; then
            out_of_quota_auto_apply
        else
            print_warning "Apply skipped. Run 'terraform apply ${terraform_output_dir}/tfplan' when ready."
        fi
    else
        print_status "Terraform generation complete. Files in: ${terraform_output_dir}"
        print_status "Run: terraform -chdir=${terraform_output_dir} init && terraform -chdir=${terraform_output_dir} apply"
    fi

    echo ""
    print_success "CloudBooter GCP run complete."
    if [[ -n "${ssh_key_file}" && -f "${ssh_key_file}.pub" ]]; then
        print_status "SSH private key: ${ssh_key_file}"
    fi
}

# --- Entrypoint ---
main "$@"

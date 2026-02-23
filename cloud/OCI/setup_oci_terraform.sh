#!/bin/bash

# Oracle Cloud Infrastructure (OCI) Terraform Setup Script
# Idempotent, comprehensive implementation for Always Free Tier management
#
# Usage:
#   Interactive mode:        ./setup_oci_terraform.sh
#   Non-interactive mode:    NON_INTERACTIVE=true AUTO_USE_EXISTING=true AUTO_DEPLOY=true ./setup_oci_terraform.sh
#   Use existing config:     AUTO_USE_EXISTING=true ./setup_oci_terraform.sh
#   Auto deploy only:        AUTO_DEPLOY=true ./setup_oci_terraform.sh
#   Skip to deploy:          SKIP_CONFIG=true ./setup_oci_terraform.sh
#
# Key features:
#   - Completely idempotent: safe to run multiple times
#   - Comprehensive resource detection before any deployment
#   - Strict Free Tier limit validation
#   - Robust existing resource import

set -euo pipefail
#set -x

# ============================================================================
# CONFIGURATION AND CONSTANTS
# ============================================================================

# Non-interactive mode support
NON_INTERACTIVE=${NON_INTERACTIVE:-false}
AUTO_USE_EXISTING=${AUTO_USE_EXISTING:-false}
AUTO_DEPLOY=${AUTO_DEPLOY:-false}
SKIP_CONFIG=${SKIP_CONFIG:-false}
DEBUG=${DEBUG:-false}
FORCE_REAUTH=${FORCE_REAUTH:-false}

# Optional Terraform remote backend (set to 'oci' to use OCI Object Storage S3-compatible backend)
TF_BACKEND=${TF_BACKEND:-local}                # values: local | oci
TF_BACKEND_BUCKET=${TF_BACKEND_BUCKET:-""}   # Bucket name for terraform state
TF_BACKEND_CREATE_BUCKET=${TF_BACKEND_CREATE_BUCKET:-false}
TF_BACKEND_REGION=${TF_BACKEND_REGION:-""}
TF_BACKEND_ENDPOINT=${TF_BACKEND_ENDPOINT:-""}
TF_BACKEND_STATE_KEY=${TF_BACKEND_STATE_KEY:-"terraform.tfstate"}
TF_BACKEND_ACCESS_KEY=${TF_BACKEND_ACCESS_KEY:-""}   # (optional) S3 access key
TF_BACKEND_SECRET_KEY=${TF_BACKEND_SECRET_KEY:-""}   # (optional) S3 secret key

# Retry/backoff settings for transient errors like 'Out of Capacity'
RETRY_MAX_ATTEMPTS=${RETRY_MAX_ATTEMPTS:-8}
RETRY_BASE_DELAY=${RETRY_BASE_DELAY:-15}  # seconds

# Timeout for OCI CLI calls (seconds). Set lower if your environment can be slow.
OCI_CMD_TIMEOUT=${OCI_CMD_TIMEOUT:-20}
# If no coreutils timeout is available, the script attempts to still run but may block on slow OCI CLI calls.

# OCI CLI configuration
OCI_CONFIG_FILE=${OCI_CONFIG_FILE:-"$HOME/.oci/config"}
OCI_PROFILE=${OCI_PROFILE:-"DEFAULT"}
OCI_AUTH_REGION=${OCI_AUTH_REGION:-""}
OCI_CLI_CONNECTION_TIMEOUT=${OCI_CLI_CONNECTION_TIMEOUT:-10}
OCI_CLI_READ_TIMEOUT=${OCI_CLI_READ_TIMEOUT:-60}
OCI_CLI_MAX_RETRIES=${OCI_CLI_MAX_RETRIES:-3}



# Oracle Free Tier Limits (as of 2025)
readonly FREE_TIER_MAX_AMD_INSTANCES=2
readonly FREE_TIER_AMD_SHAPE="VM.Standard.E2.1.Micro"
readonly FREE_TIER_MAX_ARM_OCPUS=4
readonly FREE_TIER_MAX_ARM_MEMORY_GB=24
readonly FREE_TIER_ARM_SHAPE="VM.Standard.A1.Flex"
readonly FREE_TIER_MAX_STORAGE_GB=200
readonly FREE_TIER_MIN_BOOT_VOLUME_GB=47
readonly FREE_TIER_MAX_ARM_INSTANCES=4
readonly FREE_TIER_MAX_VCNS=2

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color

# Global state tracking
declare -g tenancy_ocid=""
declare -g user_ocid=""
declare -g region=""
declare -g fingerprint=""
declare -g availability_domain=""
declare -g ubuntu_image_ocid=""
declare -g ubuntu_arm_flex_image_ocid=""
declare -g ssh_public_key=""
declare -g auth_method="security_token"

# Existing resource tracking (populated by inventory functions)
declare -gA EXISTING_VCNS=()
declare -gA EXISTING_SUBNETS=()
declare -gA EXISTING_INTERNET_GATEWAYS=()
declare -gA EXISTING_ROUTE_TABLES=()
declare -gA EXISTING_SECURITY_LISTS=()
declare -gA EXISTING_AMD_INSTANCES=()
declare -gA EXISTING_ARM_INSTANCES=()
declare -gA EXISTING_BOOT_VOLUMES=()
declare -gA EXISTING_BLOCK_VOLUMES=()

# Instance configuration
declare -g amd_micro_instance_count=0
declare -g amd_micro_boot_volume_size_gb=50
declare -g arm_flex_instance_count=0
declare -g arm_flex_ocpus_per_instance=""
declare -g arm_flex_memory_per_instance=""
declare -g arm_flex_boot_volume_size_gb=""
declare -ga arm_flex_block_volumes=()
declare -ga amd_micro_hostnames=()
declare -ga arm_flex_hostnames=()

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_debug() {
    if [ "$DEBUG" = "true" ]; then
        echo -e "${CYAN}[DEBUG]${NC} $1"
    fi
}

prompt_with_default() {
    local prompt="$1"
    local default_value="$2"
    local input

    # Print prompt to stderr so command substitutions capture only the answer
    printf "%s%s [%s]: %s" "${BLUE}" "${prompt}" "${default_value}" "${NC}" 1>&2
    read -r input
    # Normalize input: remove CR (Windows line endings) and trim whitespace
    input=$(echo "$input" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -z "$input" ]; then
        echo "$default_value"
    else
        echo "$input"
    fi
} 

prompt_int_range() {
    local prompt="$1"
    local default_value="$2"
    local min_value="$3"
    local max_value="$4"
    local value

    while true; do
        value=$(prompt_with_default "$prompt" "$default_value")
        # Normalize input in case of CR or surrounding whitespace
        value=$(echo "$value" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge "$min_value" ] && [ "$value" -le "$max_value" ]; then
            echo "$value"
            return 0
        fi
        print_error "Please enter a number between $min_value and $max_value (received: '$value')"
    done
} 

print_header() {
    echo ""
    echo -e "${BOLD}${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${MAGENTA}  $1${NC}"
    echo -e "${BOLD}${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_subheader() {
    echo ""
    echo -e "${BOLD}${CYAN}── $1 ──${NC}"
    echo ""
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

is_wsl() {
    grep -qiE "microsoft|wsl" /proc/version 2>/dev/null
}

default_region_for_host() {
    # Best-effort heuristic when the user doesn't specify a region.
    # Prefers "nearby" regions based on system timezone.
    local tz
    tz=$(cat /etc/timezone 2>/dev/null || true)
    tz=${tz:-""}

    case "$tz" in
        *Chicago*|*Central*|*Winnipeg*|*Mexico_City*) echo "us-chicago-1" ;;
        *New_York*|*Toronto*|*Montreal*|*Eastern*) echo "us-ashburn-1" ;;
        *Los_Angeles*|*Vancouver*|*Pacific*) echo "us-sanjose-1" ;;
        *Phoenix*|*Denver*|*Mountain*) echo "us-phoenix-1" ;;
        *London*|*Dublin*) echo "uk-london-1" ;;
        *Paris*|*Berlin*|*Rome*|*Madrid*|*Amsterdam*|*Stockholm*|*Zurich*|*Europe*) echo "eu-frankfurt-1" ;;
        *Tokyo*) echo "ap-tokyo-1" ;;
        *Seoul*) echo "ap-seoul-1" ;;
        *Singapore*) echo "ap-singapore-1" ;;
        *Sydney*|*Melbourne*) echo "ap-sydney-1" ;;
        *) echo "us-chicago-1" ;;
    esac
}

open_url_best_effort() {
    local url="$1"
    if [ -z "$url" ]; then
        return 1
    fi

    if is_wsl && command_exists powershell.exe; then
        # Open in Windows default browser with correct quoting (avoid cmd.exe splitting on '&')
        powershell.exe -NoProfile -Command "Start-Process '$url'" >/dev/null 2>&1 || true
        return 0
    fi

    if command_exists xdg-open; then
        xdg-open "$url" >/dev/null 2>&1 || true
        return 0
    fi

    if command_exists open; then
        open "$url" >/dev/null 2>&1 || true
        return 0
    fi

    return 1
}

read_oci_config_value() {
    local key="$1"
    local file="${2:-$OCI_CONFIG_FILE}"
    local profile="${3:-$OCI_PROFILE}"

    if [ ! -f "$file" ]; then
        return 1
    fi

    awk -v key="$key" -v profile="$profile" '
        BEGIN { section = "" }
        /^[[:space:]]*\[/ { section = $0; next }
        section == "["profile"]" {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (line ~ "^"key"[[:space:]]*=") {
                sub("^"key"[[:space:]]*=", "", line)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
                print line
                exit
            }
        }
    ' "$file"
}

is_instance_principal_available() {
    if ! command_exists curl; then
        return 1
    fi
    # Quick reachability check to OCI metadata service (non-blocking)
    curl -s --connect-timeout 1 --max-time 2 http://169.254.169.254/opc/v2/ >/dev/null 2>&1
}

validate_existing_oci_config() {
    if [ ! -f "$OCI_CONFIG_FILE" ]; then
        print_warning "OCI config not found at $OCI_CONFIG_FILE"
        return 1
    fi

    local cfg_auth
    local key_file
    local token_file
    local pass_phrase

    cfg_auth=$(read_oci_config_value "auth")
    key_file=$(read_oci_config_value "key_file")
    token_file=$(read_oci_config_value "security_token_file")
    pass_phrase=$(read_oci_config_value "pass_phrase")

    if [ -n "$cfg_auth" ]; then
        auth_method="$cfg_auth"
    elif [ -n "$token_file" ]; then
        auth_method="security_token"
    elif [ -n "$key_file" ]; then
        auth_method="api_key"
    fi

    case "$auth_method" in
        security_token)
            if [ -z "$token_file" ] || [ ! -f "$token_file" ]; then
                print_warning "security_token auth selected but security_token_file is missing"
                return 1
            fi
            ;;
        api_key)
            if [ -z "$key_file" ] || [ ! -f "$key_file" ]; then
                print_warning "api_key auth selected but key_file is missing"
                return 1
            fi
            if grep -q "ENCRYPTED" "$key_file" 2>/dev/null; then
                if [ -z "${OCI_CLI_PASSPHRASE:-$pass_phrase}" ]; then
                    print_warning "Private key is encrypted but no passphrase provided (set OCI_CLI_PASSPHRASE or pass_phrase in config)"
                    return 1
                fi
            fi
            ;;
        instance_principal|resource_principal|oke_workload_identity|instance_obo_user)
            if ! is_instance_principal_available; then
                print_warning "Instance principal auth selected but OCI metadata service is unreachable"
                return 1
            fi
            ;;
        "")
            print_warning "Unable to determine auth method from config"
            return 1
            ;;
        *)
            print_warning "Unsupported auth method '$auth_method' in config"
            return 1
            ;;
    esac

    return 0
}

# Run OCI command with proper authentication handling
oci_cmd() {
    local cmd="$*"
    local result=""
    local exit_code=0
    local base_args

    base_args="--config-file \"$OCI_CONFIG_FILE\" --profile \"$OCI_PROFILE\" --connection-timeout $OCI_CLI_CONNECTION_TIMEOUT --read-timeout $OCI_CLI_READ_TIMEOUT --max-retries $OCI_CLI_MAX_RETRIES"
    if [ -n "${OCI_CLI_AUTH:-}" ]; then
        base_args="$base_args --auth $OCI_CLI_AUTH"
    elif [ -n "$auth_method" ]; then
        base_args="$base_args --auth $auth_method"
    fi

    # Internal helper to run with timeout when available
    _run_oci_with_timeout() {
        local full_cmd="oci $base_args $cmd $*"
        if command_exists timeout; then
            # Use coreutils timeout for safety
            result=$(timeout "${OCI_CMD_TIMEOUT}s" bash -c "$full_cmd" </dev/null 2>&1) && exit_code=0 || exit_code=$?
        else
            # Fallback: run normally (may block if OCI CLI hangs)
            result=$(eval "$full_cmd" </dev/null 2>&1) && exit_code=0 || exit_code=$?
        fi
    }

    _run_oci_with_timeout ""
    if [ $exit_code -eq 0 ]; then
        echo "$result"
        return 0
    fi
    if [ $exit_code -eq 124 ]; then
        print_warning "OCI CLI call timed out after ${OCI_CMD_TIMEOUT}s"
    fi

    return 1
}

# Safe JSON parsing with jq
safe_jq() {
    local json="$1"
    local query="$2"
    local default="${3:-}"
    
    if [ -z "$json" ] || [ "$json" = "null" ]; then
        echo "$default"
        return
    fi
    
    local result
    result=$(echo "$json" | jq -r "$query" 2>/dev/null) || result="$default"
    
    if [ "$result" = "null" ] || [ -z "$result" ]; then
        echo "$default"
    else
        echo "$result"
    fi
}

# Run a command with retry/backoff, detect Out-of-Capacity signals
retry_with_backoff() {
    local cmd="$*"
    local attempt=1
    local rc=1
    local out

    while [ "$attempt" -le "$RETRY_MAX_ATTEMPTS" ]; do
        print_status "Attempt $attempt/$RETRY_MAX_ATTEMPTS: $cmd"
        out=$(eval "$cmd" 2>&1) && rc=0 || rc=$?

        if [ $rc -eq 0 ]; then
            echo "$out"
            return 0
        fi

        # Detect Out-of-Capacity patterns
        if echo "$out" | grep -i -E "out of capacity|out of host capacity|OutOfCapacity|OutOfHostCapacity" >/dev/null 2>&1; then
            print_warning "Detected 'Out of Capacity' condition (attempt $attempt)."
            # If we've exhausted attempts, bail
        else
            print_warning "Command failed (exit $rc)."
        fi

        local sleep_time=$(( RETRY_BASE_DELAY * (2 ** (attempt - 1)) ))
        print_status "Retrying in ${sleep_time}s..."
        sleep $sleep_time
        attempt=$((attempt + 1))
    done

    print_error "Command failed after $RETRY_MAX_ATTEMPTS attempts"
    echo "$out"
    return $rc
}

# A simpler wrapper that returns true/false and sets OUT_OF_CAPACITY_DETECTED=1 when detected
run_cmd_with_retries_and_check() {
    local cmd="$*"
    local out
    # shellcheck disable=SC2034  # OUT_OF_CAPACITY_DETECTED is set for callers to inspect
    OUT_OF_CAPACITY_DETECTED=0

    out=$(retry_with_backoff "$cmd") || true
    if echo "$out" | grep -i -E "out of capacity|out of host capacity|OutOfCapacity|OutOfHostCapacity" >/dev/null 2>&1; then
        # shellcheck disable=SC2034  # exported flag for callers/tests
        OUT_OF_CAPACITY_DETECTED=1
    fi

    # Return success if last command succeeded
    grep -q "^\{" <<< "$out" 2>/dev/null || true
    # We cannot rely on JSON only; instead rely on previous command exit status from retry_with_backoff
    return $?
}

# Automatically re-run terraform apply until success on 'Out of Capacity', with backoff
out_of_capacity_auto_apply() {
    print_status "Auto-retrying terraform apply until success or max attempts (${RETRY_MAX_ATTEMPTS})..."
    local attempt=1
    local rc=1
    local out

    while [ "$attempt" -le "$RETRY_MAX_ATTEMPTS" ]; do
        print_status "Apply attempt $attempt/$RETRY_MAX_ATTEMPTS"
        out=$(terraform apply -input=false tfplan 2>&1) && rc=0 || rc=$?

        if [ $rc -eq 0 ]; then
            print_success "terraform apply succeeded"
            return 0
        fi

        if echo "$out" | grep -i -E "out of capacity|out of host capacity|OutOfCapacity|OutOfHostCapacity" >/dev/null 2>&1; then
            print_warning "Apply failed with 'Out of Capacity' - will retry"
        else
            print_error "terraform apply failed with non-retryable error"
            echo "$out"
            return $rc
        fi

        local sleep_time=$(( RETRY_BASE_DELAY * (2 ** (attempt - 1)) ))
        print_status "Waiting ${sleep_time}s before retrying..."
        sleep $sleep_time
        attempt=$((attempt + 1))
    done

    print_error "terraform apply did not succeed after $RETRY_MAX_ATTEMPTS attempts"
    echo "$out"
    return 1
}

# Create an OCI Object Storage bucket (S3-compatible) for remote TF state if requested
create_s3_backend_bucket() {
    local bucket_name="$1"
    if [ -z "$bucket_name" ]; then
        print_error "Bucket name is empty"
        return 1
    fi

    print_status "Creating/checking OCI Object Storage bucket: $bucket_name"

    local ns
    ns=$(oci_cmd "os ns get --query 'data' --raw-output" 2>/dev/null) || ns=""
    if [ -z "$ns" ]; then
        print_error "Failed to determine Object Storage namespace"
        return 1
    fi

    # Check if bucket exists
    if oci_cmd "os bucket get --namespace-name $ns --bucket-name $bucket_name" >/dev/null 2>&1; then
        print_status "Bucket $bucket_name already exists in namespace $ns"
        return 0
    fi

    if oci_cmd "os bucket create --namespace-name $ns --compartment-id $tenancy_ocid --name $bucket_name --is-versioning-enabled true" >/dev/null 2>&1; then
        print_success "Created bucket $bucket_name in namespace $ns"
        return 0
    fi

    print_error "Failed to create bucket $bucket_name"
    return 1
}

# Configure terraform backend if TF_BACKEND=oci
configure_terraform_backend() {
    if [ "$TF_BACKEND" != "oci" ]; then
        return 0
    fi

    if [ -z "$TF_BACKEND_BUCKET" ]; then
        print_error "TF_BACKEND is 'oci' but TF_BACKEND_BUCKET is not set"
        return 1
    fi

    TF_BACKEND_REGION=${TF_BACKEND_REGION:-$region}
    TF_BACKEND_ENDPOINT=${TF_BACKEND_ENDPOINT:-"https://objectstorage.${TF_BACKEND_REGION}.oraclecloud.com"}

    if [ "$TF_BACKEND_CREATE_BUCKET" = "true" ]; then
        create_s3_backend_bucket "$TF_BACKEND_BUCKET" || return 1
    fi

    # Write backend override (sensitive; keep out of VCS)
    print_status "Writing backend.tf (do not commit -- contains sensitive values)"
    cat > backend.tf <<EOF
terraform {
  backend "s3" {
    bucket     = "$TF_BACKEND_BUCKET"
    key        = "$TF_BACKEND_STATE_KEY"
    region     = "$TF_BACKEND_REGION"
    endpoint   = "$TF_BACKEND_ENDPOINT"
    access_key = "$TF_BACKEND_ACCESS_KEY"
    secret_key = "$TF_BACKEND_SECRET_KEY"
    skip_credentials_validation = true
    skip_region_validation = true
    skip_metadata_api_check = true
    force_path_style = true
  }
}
EOF
    print_warning "backend.tf written - ensure this file is in .gitignore (contains credentials if provided)"
}

# Confirm action with user
confirm_action() {
    local prompt="$1"
    local default="${2:-N}"
    
    if [ "$NON_INTERACTIVE" = "true" ]; then
        [ "$default" = "Y" ] && return 0 || return 1
    fi
    
    local yn_prompt
    if [ "$default" = "Y" ]; then
        yn_prompt="[Y/n]"
    else
        yn_prompt="[y/N]"
    fi
    
    echo -n -e "${BLUE}$prompt $yn_prompt: ${NC}"
    read -r response
    response=${response:-$default}
    
    [[ "$response" =~ ^[Yy]$ ]]
}

# ============================================================================
# INSTALLATION FUNCTIONS
# ============================================================================

install_prerequisites() {
    print_subheader "Installing Prerequisites"
    
    local packages_to_install=()
    
    # Check for required commands
    if ! command_exists jq; then
        packages_to_install+=("jq")
    fi
    if ! command_exists curl; then
        packages_to_install+=("curl")
    fi
    if ! command_exists unzip; then
        packages_to_install+=("unzip")
    fi
    
    if [ ${#packages_to_install[@]} -gt 0 ]; then
        print_status "Installing required packages: ${packages_to_install[*]}"
        if command_exists apt-get; then
            sudo apt-get update -qq
            sudo apt-get install -y -qq "${packages_to_install[@]}"
        elif command_exists yum; then
            sudo yum install -y -q "${packages_to_install[@]}"
        elif command_exists dnf; then
            sudo dnf install -y -q "${packages_to_install[@]}"
        else
            print_error "Cannot install packages: no supported package manager found"
            return 1
        fi
    fi
    
    # Verify all required commands exist
    local required_commands=("jq" "openssl" "ssh-keygen" "curl")
    for cmd in "${required_commands[@]}"; do
        if ! command_exists "$cmd"; then
            print_error "Required command '$cmd' is not available"
            return 1
        fi
    done
    
    print_success "All prerequisites installed"
}

install_oci_cli() {
    print_subheader "OCI CLI Setup"
    
    # Check if OCI CLI is already installed and working
    if command_exists oci; then
        local version
        version=$(oci --version 2>/dev/null | head -1) || version="unknown"
        print_status "OCI CLI already installed: $version"
        return 0
    fi
    
    print_status "Installing OCI CLI..."
    
    # Check if Python is installed
    if ! command_exists python3; then
        print_status "Installing Python 3..."
        if command_exists apt-get; then
            sudo apt-get update -qq
            sudo apt-get install -y -qq python3 python3-venv python3-pip
        elif command_exists yum; then
            sudo yum install -y -q python3 python3-pip
        fi
    fi
    
    # Create virtual environment for OCI CLI
    local venv_dir="$PWD/.venv"
    if [ ! -d "$venv_dir" ]; then
        print_status "Creating Python virtual environment..."
        python3 -m venv "$venv_dir"
    fi
    
    # Activate and install OCI CLI
    # shellcheck source=/dev/null
    # shellcheck disable=SC1091
    source "$venv_dir/bin/activate"
    
    print_status "Installing OCI CLI in virtual environment..."
    pip install --upgrade pip --quiet
    pip install oci-cli --quiet
    
    # Add activation to bashrc if not already present
    local activation_line="source $venv_dir/bin/activate"
    if ! grep -qF "$activation_line" ~/.bashrc 2>/dev/null; then
        { echo ""; echo "# OCI CLI virtual environment"; echo "$activation_line"; } >> ~/.bashrc
    fi
    
    print_success "OCI CLI installed successfully"
}

install_terraform() {
    print_subheader "Terraform Setup"
    
    if command_exists terraform; then
        local version
        version=$(terraform version -json 2>/dev/null | jq -r '.terraform_version' 2>/dev/null) || \
        version=$(terraform version | head -1 | awk '{print $2}' | sed 's/v//')
        print_status "Terraform already installed: version $version"
        return 0
    fi
    
    print_status "Installing Terraform..."
    
    # Try snap first on Ubuntu/Debian
    if command_exists snap; then
        if sudo snap install terraform --classic; then
            print_success "Terraform installed via snap"
            return 0
        fi
    fi
    
    # Manual installation
    local latest_version
    latest_version=$(curl -s https://api.github.com/repos/hashicorp/terraform/releases/latest | jq -r '.tag_name' | sed 's/v//')
    
    if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
        latest_version="1.7.0"
        print_warning "Could not fetch latest version, using fallback: $latest_version"
    fi
    
    local arch="amd64"
    if [ "$(uname -m)" = "aarch64" ]; then
        arch="arm64"
    fi
    
    local os="linux"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        os="darwin"
    fi
    
    local tf_url="https://releases.hashicorp.com/terraform/${latest_version}/terraform_${latest_version}_${os}_${arch}.zip"
    local temp_dir
    temp_dir=$(mktemp -d)
    
    print_status "Downloading Terraform $latest_version for ${os}_${arch}..."
    
    if curl -sLo "$temp_dir/terraform.zip" "$tf_url"; then
        unzip -q "$temp_dir/terraform.zip" -d "$temp_dir"
        sudo mv "$temp_dir/terraform" /usr/local/bin/
        sudo chmod +x /usr/local/bin/terraform
        rm -rf "$temp_dir"
        
        if command_exists terraform; then
            print_success "Terraform installed successfully"
            return 0
        fi
    fi
    
    rm -rf "$temp_dir"
    print_error "Failed to install Terraform"
    return 1
}

# ============================================================================
# OCI AUTHENTICATION FUNCTIONS
# ============================================================================

detect_auth_method() {
    if [ -f "$OCI_CONFIG_FILE" ]; then
        local cfg_auth
        local token_file
        local key_file

        cfg_auth=$(read_oci_config_value "auth")
        token_file=$(read_oci_config_value "security_token_file")
        key_file=$(read_oci_config_value "key_file")

        if [ -n "$cfg_auth" ]; then
            auth_method="$cfg_auth"
        elif [ -n "$token_file" ]; then
            auth_method="security_token"
        elif [ -n "$key_file" ]; then
            auth_method="api_key"
        fi
    fi
    print_debug "Detected auth method: $auth_method (profile: $OCI_PROFILE, config: $OCI_CONFIG_FILE)"
}

setup_oci_config() {
    print_subheader "OCI Authentication"
    
    mkdir -p ~/.oci
    
    local existing_config_invalid=0
    if [ -f "$OCI_CONFIG_FILE" ]; then
        print_status "Existing OCI configuration found"
        detect_auth_method

        print_status "Validating existing OCI configuration..."

        if ! validate_existing_oci_config; then
            existing_config_invalid=1
            print_warning "Existing OCI configuration is incomplete or requires interactive input"
        else
            # Test existing configuration
            print_status "Testing existing OCI configuration connectivity..."
            if test_oci_connectivity; then
                print_success "Existing OCI configuration is valid"
                return 0
            fi
        fi

        print_warning "Existing configuration failed connectivity test (will retry with refresh)"
        
        # Check if session token expired
        if [ "$auth_method" = "security_token" ]; then
            print_status "Attempting to refresh session token (timeout ${OCI_CMD_TIMEOUT}s)..."
            if oci_cmd "session refresh" >/dev/null 2>&1; then
                if test_oci_connectivity; then
                    print_success "Session token refreshed successfully"
                    return 0
                fi
            else
                print_warning "Session refresh failed or timed out"
            fi
            
            print_status "Session refresh did not restore connectivity, initiating interactive authentication as a fallback..."
        fi
    fi
    
    # Setup new authentication
    print_status "Setting up browser-based authentication..."
    print_status "This will open a browser window for you to log in to Oracle Cloud."

    if [ "$NON_INTERACTIVE" = "true" ]; then
        print_error "Cannot perform interactive authentication in non-interactive mode. Aborting."
        return 1
    fi

    # Determine region to use for browser login.
    # If we have an existing config, prefer its region (avoids the region selection prompt).
    local auth_region
    auth_region=$(read_oci_config_value "region" "$OCI_CONFIG_FILE" "$OCI_PROFILE" 2>/dev/null || true)
    auth_region=${auth_region:-$OCI_AUTH_REGION}
    auth_region=${auth_region:-$(default_region_for_host)}

    # Keep this interactive (per UX request): prompt with a sane default so Enter works.
    if [ "$NON_INTERACTIVE" != "true" ]; then
        auth_region=$(prompt_with_default "Region for authentication" "$auth_region")
    fi

    # Allow forcing re-auth / new profile
    if [ "$FORCE_REAUTH" = "true" ]; then
        new_profile=$(prompt_with_default "Enter new profile name to create/use" "NEW_PROFILE")
        print_status "Starting interactive session authenticate for profile '$new_profile'..."

        print_status "Using region '$auth_region' for authentication"
        local auth_out
        if is_wsl; then
            auth_out=$(oci session authenticate --no-browser --profile-name "$new_profile" --region "$auth_region" --session-expiration-in-minutes 60 2>&1) || {
                echo "$auth_out" >&2
                if echo "$auth_out" | grep -i -E "config file.*is invalid|Config Errors|user .*missing" >/dev/null 2>&1; then
                    print_warning "OCI CLI reports the config file is invalid or missing required fields. Offering repair options..."
                    existing_config_invalid=1
                else
                    print_error "Authentication failed"
                    return 1
                fi
            }
            if [ "$existing_config_invalid" -ne 1 ]; then
                echo "$auth_out"
                local url
                url=$(echo "$auth_out" | grep -Eo 'https://[^ ]+' | head -1 || true)
                if [ -n "$url" ]; then
                    print_status "Opening browser for login URL (WSL)..."
                    open_url_best_effort "$url" || true
                fi
            fi
        else
            if ! oci session authenticate --profile-name "$new_profile" --region "$auth_region" --session-expiration-in-minutes 60; then
                print_error "Browser authentication failed or was cancelled"
                return 1
            fi
        fi

        print_status "Authentication for profile '$new_profile' completed. Updating OCI_PROFILE to use it."
        OCI_PROFILE="$new_profile"
        auth_method="security_token"

        if [ "$existing_config_invalid" -eq 1 ]; then
            # Run the same automatic delete and recreate flow
            print_warning "Detected invalid or incomplete OCI config file during forced re-auth - AUTOMATICALLY DELETING AND FORCING FRESH AUTHENTICATION"

            # IMMEDIATE DELETE: Remove corrupted config without prompting
            if [ -f "$OCI_CONFIG_FILE" ]; then
                print_status "Backing up corrupted config to $OCI_CONFIG_FILE.corrupted.$(date +%Y%m%d_%H%M%S)"
                cp "$OCI_CONFIG_FILE" "$OCI_CONFIG_FILE.corrupted.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
                print_status "Forcibly deleting corrupted config file: $OCI_CONFIG_FILE"
                rm -f "$OCI_CONFIG_FILE"
            fi
            
            # Delete any temp config files to start completely fresh
            rm -f "$HOME/.oci/config.session_auth" 2>/dev/null || true
            
            # Create completely new profile with session auth
            new_profile="DEFAULT"
            print_status "Creating fresh OCI configuration with browser-based authentication for profile '$new_profile'..."
            print_status "This will open your browser to log into Oracle Cloud."
            print_status ""
            print_status "Using region '$auth_region' for authentication"
            print_status ""
            
            # Use the default config location (let OCI CLI create it fresh)
            OCI_CONFIG_FILE="$HOME/.oci/config"
            OCI_PROFILE="$new_profile"
            unset OCI_CLI_CONFIG_FILE
            
            if is_wsl; then
                if auth_out=$(oci session authenticate --no-browser --profile-name "$new_profile" --region "$auth_region" --session-expiration-in-minutes 60 2>&1); then
                    echo "$auth_out"
                    local url
                    url=$(echo "$auth_out" | grep -Eo 'https://[^ ]+' | head -1 || true)
                    if [ -n "$url" ]; then
                        print_status "Opening browser for login URL (WSL)..."
                        open_url_best_effort "$url" || true
                        print_status ""
                        print_status "After completing browser authentication, press Enter to continue..."
                        read -r
                    fi
                    OCI_PROFILE="$new_profile"
                    auth_method="security_token"
                    if test_oci_connectivity; then
                        print_success "Fresh session authentication succeeded for profile '$new_profile'"
                        return 0
                    else
                        print_warning "Session auth completed but connectivity test failed"
                    fi
                else
                    echo "$auth_out" >&2
                    print_error "Browser-based authentication failed. Please verify your Oracle Cloud credentials and try again."
                    return 1
                fi
            else
                if oci session authenticate --profile-name "$new_profile" --region "$auth_region" --session-expiration-in-minutes 60; then
                    OCI_PROFILE="$new_profile"
                    auth_method="security_token"
                    if test_oci_connectivity; then
                        print_success "Fresh session authentication succeeded for profile '$new_profile'"
                        return 0
                    else
                        print_warning "Session auth completed but connectivity test failed"
                    fi
                else
                    print_error "Browser-based authentication failed. Please verify your Oracle Cloud credentials and try again."
                    return 1
                fi
            fi
        fi

        if test_oci_connectivity; then
            print_success "OCI authentication configured successfully for profile '$new_profile'"
            return 0
        else
            print_warning "Authentication succeeded but connectivity test failed for profile '$new_profile'"
        fi
    else
        # If existing config was invalid, automatically fix it
        if [ "$existing_config_invalid" -eq 1 ]; then
            print_warning "Detected invalid or incomplete OCI config file - AUTOMATICALLY DELETING AND FORCING FRESH AUTHENTICATION"
            
            # IMMEDIATE DELETE: Remove corrupted config without prompting
            if [ -f "$OCI_CONFIG_FILE" ]; then
                print_status "Backing up corrupted config to $OCI_CONFIG_FILE.corrupted.$(date +%Y%m%d_%H%M%S)"
                cp "$OCI_CONFIG_FILE" "$OCI_CONFIG_FILE.corrupted.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
                print_status "Forcibly deleting corrupted config file: $OCI_CONFIG_FILE"
                rm -f "$OCI_CONFIG_FILE"
            fi
            
            # Delete any temp config files to start completely fresh
            rm -f "$HOME/.oci/config.session_auth" 2>/dev/null || true
            
            # Create completely new profile with session auth
            new_profile="DEFAULT"
            print_status "Creating fresh OCI configuration with browser-based authentication for profile '$new_profile'..."
            print_status "This will open your browser to log into Oracle Cloud."
            print_status ""
            print_status "Using region '$auth_region' for authentication"
            print_status ""
            
            # Use the default config location (let OCI CLI create it fresh)
            OCI_CONFIG_FILE="$HOME/.oci/config"
            OCI_PROFILE="$new_profile"
            unset OCI_CLI_CONFIG_FILE
            
            if is_wsl; then
                if auth_out=$(oci session authenticate --no-browser --profile-name "$new_profile" --region "$auth_region" --session-expiration-in-minutes 60 2>&1); then
                    echo "$auth_out"
                    local url
                    url=$(echo "$auth_out" | grep -Eo 'https://[^ ]+' | head -1 || true)
                    if [ -n "$url" ]; then
                        print_status "Opening browser for login URL (WSL)..."
                        open_url_best_effort "$url" || true
                        print_status ""
                        print_status "After completing browser authentication, press Enter to continue..."
                        read -r
                    fi
                    auth_method="security_token"
                    if test_oci_connectivity; then
                        print_success "Fresh session authentication succeeded for profile '$new_profile'"
                        return 0
                    else
                        print_warning "Session auth completed but connectivity test failed"
                    fi
                else
                    echo "$auth_out" >&2
                    print_error "Browser-based authentication failed. Please verify your Oracle Cloud credentials and try again."
                    return 1
                fi
            else
                if oci session authenticate --profile-name "$new_profile" --region "$auth_region" --session-expiration-in-minutes 60; then
                    auth_method="security_token"
                    if test_oci_connectivity; then
                        print_success "Fresh session authentication succeeded for profile '$new_profile'"
                        return 0
                    else
                        print_warning "Session auth completed but connectivity test failed"
                    fi
                else
                    print_error "Browser-based authentication failed. Please verify your Oracle Cloud credentials and try again."
                    return 1
                fi
            fi
        fi
        # Interactive authenticate (may open browser)
        print_status "Using profile '$OCI_PROFILE' for interactive session authenticate..."

        print_status "Using region '$auth_region' for authentication"
        if is_wsl; then
            local auth_out
            auth_out=$(oci session authenticate --no-browser --profile-name "$OCI_PROFILE" --region "$auth_region" --session-expiration-in-minutes 60 2>&1) || {
                echo "$auth_out" >&2
                if echo "$auth_out" | grep -i -E "config file.*is invalid|Config Errors|user .*missing" >/dev/null 2>&1; then
                    print_warning "OCI CLI reports the config file is invalid or missing required fields. Offering repair options..."
                    existing_config_invalid=1
                else
                    print_error "Authentication failed"
                    return 1
                fi
            }
            if [ "$existing_config_invalid" -ne 1 ]; then
                echo "$auth_out"
                local url
                url=$(echo "$auth_out" | grep -Eo 'https://[^ ]+' | head -1 || true)
                if [ -n "$url" ]; then
                    print_status "Opening browser for login URL (WSL)..."
                    open_url_best_effort "$url" || true
                fi
            fi
        else
            # Capture output so we can detect invalid-config errors and offer remediation
            auth_out=$(oci session authenticate --profile-name "$OCI_PROFILE" --region "$auth_region" --session-expiration-in-minutes 60 2>&1) || {
                echo "$auth_out" >&2
                if echo "$auth_out" | grep -i -E "config file.*is invalid|Config Errors|user .*missing" >/dev/null 2>&1; then
                    print_warning "OCI CLI reports the config file is invalid or missing required fields. Offering repair options..."
                    existing_config_invalid=1
                else
                    print_error "Browser authentication failed or was cancelled"
                    return 1
                fi
            }
        fi

        # SHARED REPAIR FLOW: runs for both WSL and non-WSL when existing_config_invalid is set
        if [ "$existing_config_invalid" -eq 1 ]; then
            print_warning "Detected invalid or incomplete OCI config file - AUTOMATICALLY DELETING AND FORCING FRESH AUTHENTICATION"
            
            # IMMEDIATE DELETE: Remove corrupted config without prompting
            if [ -f "$OCI_CONFIG_FILE" ]; then
                print_status "Backing up corrupted config to $OCI_CONFIG_FILE.corrupted.$(date +%Y%m%d_%H%M%S)"
                cp "$OCI_CONFIG_FILE" "$OCI_CONFIG_FILE.corrupted.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
                print_status "Forcibly deleting corrupted config file: $OCI_CONFIG_FILE"
                rm -f "$OCI_CONFIG_FILE"
            fi
            
            # Delete any temp config files to start completely fresh
            rm -f "$HOME/.oci/config.session_auth" 2>/dev/null || true
            
            # Create completely new profile with session auth
            new_profile="DEFAULT"
            print_status "Creating fresh OCI configuration with browser-based authentication for profile '$new_profile'..."
            print_status "This will open your browser to log into Oracle Cloud."
            print_status ""
            print_status "Using region '$auth_region' for authentication"
            print_status ""
            
            # Use the default config location (let OCI CLI create it fresh)
            OCI_CONFIG_FILE="$HOME/.oci/config"
            OCI_PROFILE="$new_profile"
            unset OCI_CLI_CONFIG_FILE
            
            if is_wsl; then
                if auth_out=$(oci session authenticate --no-browser --profile-name "$new_profile" --region "$auth_region" --session-expiration-in-minutes 60 2>&1); then
                    echo "$auth_out"
                    local url
                    url=$(echo "$auth_out" | grep -Eo 'https://[^ ]+' | head -1 || true)
                    if [ -n "$url" ]; then
                        print_status "Opening browser for login URL (WSL)..."
                        open_url_best_effort "$url" || true
                        print_status ""
                        print_status "After completing browser authentication, press Enter to continue..."
                        read -r
                    fi
                    auth_method="security_token"
                    if test_oci_connectivity; then
                        print_success "Fresh session authentication succeeded for profile '$new_profile'"
                        return 0
                    else
                        print_warning "Session auth completed but connectivity test failed"
                    fi
                else
                    echo "$auth_out" >&2
                    print_error "Browser-based authentication failed. Please verify your Oracle Cloud credentials and try again."
                    return 1
                fi
            else
                if oci session authenticate --profile-name "$new_profile" --region "$auth_region" --session-expiration-in-minutes 60; then
                    auth_method="security_token"
                    if test_oci_connectivity; then
                        print_success "Fresh session authentication succeeded for profile '$new_profile'"
                        return 0
                    else
                        print_warning "Session auth completed but connectivity test failed"
                    fi
                else
                    print_error "Browser-based authentication failed. Please verify your Oracle Cloud credentials and try again."
                    return 1
                fi
            fi
        fi


        # If we got here without returning, then authentication succeeded but connectivity might have issues
        # Let's continue anyway since the auth was successful
        auth_method="security_token"

        # Verify the new configuration
        if test_oci_connectivity; then
            print_success "OCI authentication configured successfully"
            return 0
        fi
    fi

    print_error "OCI configuration verification failed"
    return 1
}

test_oci_connectivity() {
    print_status "Testing OCI API connectivity..."
    
    # Method 1: List regions (simplest test)
    print_status "Checking IAM region list (timeout ${OCI_CMD_TIMEOUT}s)..."
    if oci_cmd "iam region list" >/dev/null 2>&1; then
        print_debug "Connectivity test passed (region list)"
        return 0
    else
        print_warning "Region list query failed or timed out"
    fi
    
    # Method 2: Get tenancy info if we have it
    local test_tenancy
    test_tenancy=$(grep -oP '(?<=tenancy=).*' "$OCI_CONFIG_FILE" 2>/dev/null | head -1)
    
    if [ -n "$test_tenancy" ]; then
        print_status "Checking IAM tenancy get (timeout ${OCI_CMD_TIMEOUT}s)..."
        if oci_cmd "iam tenancy get --tenancy-id $test_tenancy" >/dev/null 2>&1; then
            print_debug "Connectivity test passed (tenancy get)"
            return 0
        else
            print_warning "Tenancy get failed or timed out"
        fi
    fi
    
    print_debug "All connectivity tests failed"
    return 1
}

# ============================================================================
# OCI RESOURCE DISCOVERY FUNCTIONS
# ============================================================================

fetch_oci_config_values() {
    print_subheader "Fetching OCI Configuration"
    
    # Tenancy OCID
    tenancy_ocid=$(grep -oP '(?<=tenancy=).*' ~/.oci/config | head -1)
    if [ -z "$tenancy_ocid" ]; then
        print_error "Failed to fetch tenancy OCID from config"
        return 1
    fi
    print_status "Tenancy OCID: $tenancy_ocid"
    
    # User OCID
    user_ocid=$(grep -P '^\s*user\s*=' ~/.oci/config | sed -E 's/^\s*user\s*=\s*//' | head -1)
    if [ -z "$user_ocid" ]; then
        # Try to get from API for session token auth
        local user_info
        user_info=$(oci_cmd "iam user list --compartment-id $tenancy_ocid --limit 1")
        user_ocid=$(safe_jq "$user_info" '.data[0].id')
    fi
    print_status "User OCID: ${user_ocid:-N/A (session token auth)}"
    
    # Region
    region=$(grep -oP '(?<=region=).*' ~/.oci/config | head -1)
    if [ -z "$region" ]; then
        print_error "Failed to fetch region from config"
        return 1
    fi
    print_status "Region: $region"
    
    # Fingerprint (only for API key auth)
    if [ "$auth_method" = "security_token" ]; then
        fingerprint="session_token_auth"
    else
        fingerprint=$(grep -oP '(?<=fingerprint=).*' ~/.oci/config | head -1)
    fi
    print_debug "Auth fingerprint: $fingerprint"
    
    print_success "OCI configuration values fetched"
}

fetch_availability_domains() {
    print_status "Fetching availability domains..."
    
    local ad_list
    ad_list=$(oci_cmd "iam availability-domain list --compartment-id $tenancy_ocid --query 'data[].name' --raw-output")
    
    if [ -z "$ad_list" ] || [ "$ad_list" = "null" ]; then
        print_error "Failed to fetch availability domains"
        return 1
    fi
    
    # Parse first AD
    availability_domain=$(echo "$ad_list" | jq -r '.[0]' 2>/dev/null)
    
    if [ -z "$availability_domain" ] || [ "$availability_domain" = "null" ]; then
        print_error "Failed to parse availability domain"
        return 1
    fi
    
    print_success "Availability domain: $availability_domain"
}

fetch_ubuntu_images() {
    print_status "Fetching Ubuntu images for region $region..."
    
    # Fetch x86 (AMD64) Ubuntu image
    print_status "  Looking for x86 Ubuntu image..."
    local x86_images
    x86_images=$(oci_cmd "compute image list \
        --compartment-id $tenancy_ocid \
        --operating-system 'Canonical Ubuntu' \
        --shape '$FREE_TIER_AMD_SHAPE' \
        --sort-by TIMECREATED \
        --sort-order DESC \
        --query 'data[].{id:id,name:\"display-name\"}' \
        --all")
    
    ubuntu_image_ocid=$(safe_jq "$x86_images" '.[0].id')
    local x86_name
    x86_name=$(safe_jq "$x86_images" '.[0].name')
    
    if [ -n "$ubuntu_image_ocid" ] && [ "$ubuntu_image_ocid" != "null" ]; then
        print_success "  x86 image: $x86_name"
        print_debug "  x86 OCID: $ubuntu_image_ocid"
    else
        print_warning "  No x86 Ubuntu image found - AMD instances disabled"
        ubuntu_image_ocid=""
    fi
    
    # Fetch ARM Ubuntu image
    print_status "  Looking for ARM Ubuntu image..."
    local arm_images
    arm_images=$(oci_cmd "compute image list \
        --compartment-id $tenancy_ocid \
        --operating-system 'Canonical Ubuntu' \
        --shape '$FREE_TIER_ARM_SHAPE' \
        --sort-by TIMECREATED \
        --sort-order DESC \
        --query 'data[].{id:id,name:\"display-name\"}' \
        --all")
    
    ubuntu_arm_flex_image_ocid=$(safe_jq "$arm_images" '.[0].id')
    local arm_name
    arm_name=$(safe_jq "$arm_images" '.[0].name')
    
    if [ -n "$ubuntu_arm_flex_image_ocid" ] && [ "$ubuntu_arm_flex_image_ocid" != "null" ]; then
        print_success "  ARM image: $arm_name"
        print_debug "  ARM OCID: $ubuntu_arm_flex_image_ocid"
    else
        print_warning "  No ARM Ubuntu image found - ARM instances disabled"
        ubuntu_arm_flex_image_ocid=""
    fi
}

generate_ssh_keys() {
    print_status "Setting up SSH keys..."
    
    local ssh_dir="$PWD/ssh_keys"
    mkdir -p "$ssh_dir"
    
    if [ ! -f "$ssh_dir/id_rsa" ]; then
        print_status "Generating new SSH key pair..."
        ssh-keygen -t rsa -b 4096 -f "$ssh_dir/id_rsa" -N "" -q
        chmod 600 "$ssh_dir/id_rsa"
        chmod 644 "$ssh_dir/id_rsa.pub"
        print_success "SSH key pair generated at $ssh_dir/"
    else
        print_status "Using existing SSH key pair at $ssh_dir/"
    fi
    
    # shellcheck disable=SC2034  # exported for Terraform/template consumption
    ssh_public_key=$(cat "$ssh_dir/id_rsa.pub")
}

# ============================================================================
# COMPREHENSIVE RESOURCE INVENTORY
# ============================================================================

inventory_all_resources() {
    print_header "COMPREHENSIVE RESOURCE INVENTORY"
    print_status "Scanning all existing OCI resources in tenancy..."
    print_status "This ensures we never create duplicate resources."
    echo ""
    
    inventory_compute_instances
    inventory_networking_resources
    inventory_storage_resources
    
    display_resource_inventory
}

inventory_compute_instances() {
    print_status "Inventorying compute instances..."
    
    # Get ALL instances (including terminated for awareness)
    local all_instances
    all_instances=$(oci_cmd "compute instance list \
        --compartment-id $tenancy_ocid \
        --query 'data[?\"lifecycle-state\"!=\`TERMINATED\`].{id:id,name:\"display-name\",state:\"lifecycle-state\",shape:shape,ad:\"availability-domain\",created:\"time-created\"}' \
        --all" 2>/dev/null) || all_instances="[]"
    
    if [ -z "$all_instances" ] || [ "$all_instances" = "null" ]; then
        all_instances="[]"
    fi
    
    # Clear existing tracking
    EXISTING_AMD_INSTANCES=()
    EXISTING_ARM_INSTANCES=()
    
    local instance_count
    instance_count=$(echo "$all_instances" | jq 'length' 2>/dev/null) || instance_count=0
    
    if [ "$instance_count" -eq 0 ]; then
        print_status "  No existing compute instances found"
        return 0
    fi
    
    # Parse each instance
    while IFS= read -r instance; do
        local id name state shape
        id=$(safe_jq "$instance" '.id')
        name=$(safe_jq "$instance" '.name')
        state=$(safe_jq "$instance" '.state')
        shape=$(safe_jq "$instance" '.shape')
        
        if [ -z "$id" ] || [ "$id" = "null" ]; then
            continue
        fi
        
        # Get VNIC information for IP addresses
        local vnic_attachments public_ip private_ip
        vnic_attachments=$(oci_cmd "compute vnic-attachment list \
            --compartment-id $tenancy_ocid \
            --instance-id $id \
            --query 'data[?\"lifecycle-state\"==\`ATTACHED\`]'" 2>/dev/null) || vnic_attachments="[]"
        
        if [ -n "$vnic_attachments" ] && [ "$vnic_attachments" != "[]" ] && [ "$vnic_attachments" != "null" ]; then
            local vnic_id
            vnic_id=$(safe_jq "$vnic_attachments" '.[0]."vnic-id"')
            
            if [ -n "$vnic_id" ] && [ "$vnic_id" != "null" ]; then
                local vnic_details
                vnic_details=$(oci_cmd "network vnic get --vnic-id $vnic_id" 2>/dev/null)
                public_ip=$(safe_jq "$vnic_details" '.data."public-ip"' "none")
                private_ip=$(safe_jq "$vnic_details" '.data."private-ip"' "none")
            fi
        fi
        
        # Categorize by shape
        if [ "$shape" = "$FREE_TIER_AMD_SHAPE" ]; then
            EXISTING_AMD_INSTANCES["$id"]="$name|$state|$shape|${public_ip:-none}|${private_ip:-none}"
            print_status "  Found AMD instance: $name ($state) - IP: ${public_ip:-none}"
        elif [ "$shape" = "$FREE_TIER_ARM_SHAPE" ]; then
            # Get shape config for ARM instances
            local instance_details ocpus memory
            instance_details=$(oci_cmd "compute instance get --instance-id $id" 2>/dev/null)
            ocpus=$(safe_jq "$instance_details" '.data."shape-config".ocpus' "0")
            memory=$(safe_jq "$instance_details" '.data."shape-config"."memory-in-gbs"' "0")
            
            EXISTING_ARM_INSTANCES["$id"]="$name|$state|$shape|${public_ip:-none}|${private_ip:-none}|$ocpus|$memory"
            print_status "  Found ARM instance: $name ($state, ${ocpus}OCPUs, ${memory}GB) - IP: ${public_ip:-none}"
        else
            print_debug "  Found non-free-tier instance: $name ($shape)"
        fi
    done <<< "$(echo "$all_instances" | jq -c '.[]' 2>/dev/null)"
    
    print_status "  AMD instances: ${#EXISTING_AMD_INSTANCES[@]}/${FREE_TIER_MAX_AMD_INSTANCES}"
    print_status "  ARM instances: ${#EXISTING_ARM_INSTANCES[@]}/${FREE_TIER_MAX_ARM_INSTANCES}"
}

inventory_networking_resources() {
    print_status "Inventorying networking resources..."
    
    # Clear existing tracking
    EXISTING_VCNS=()
    EXISTING_SUBNETS=()
    EXISTING_INTERNET_GATEWAYS=()
    EXISTING_ROUTE_TABLES=()
    EXISTING_SECURITY_LISTS=()
    
    # Get VCNs
    local vcn_list
    vcn_list=$(oci_cmd "network vcn list \
        --compartment-id $tenancy_ocid \
        --query 'data[?\"lifecycle-state\"==\`AVAILABLE\`].{id:id,name:\"display-name\",cidr:\"cidr-block\"}' \
        --all" 2>/dev/null) || vcn_list="[]"
    
    if [ -z "$vcn_list" ] || [ "$vcn_list" = "null" ]; then
        vcn_list="[]"
    fi
    
    while IFS= read -r vcn; do
        local vcn_id vcn_name vcn_cidr
        vcn_id=$(safe_jq "$vcn" '.id')
        vcn_name=$(safe_jq "$vcn" '.name')
        vcn_cidr=$(safe_jq "$vcn" '.cidr')
        
        if [ -z "$vcn_id" ] || [ "$vcn_id" = "null" ]; then
            continue
        fi
        
        EXISTING_VCNS["$vcn_id"]="$vcn_name|$vcn_cidr"
        print_status "  Found VCN: $vcn_name ($vcn_cidr)"
        
        # Get subnets for this VCN
        local subnet_list
        subnet_list=$(oci_cmd "network subnet list \
            --compartment-id $tenancy_ocid \
            --vcn-id $vcn_id \
            --query 'data[?\"lifecycle-state\"==\`AVAILABLE\`].{id:id,name:\"display-name\",cidr:\"cidr-block\"}'" 2>/dev/null) || subnet_list="[]"
        
        while IFS= read -r subnet; do
            local subnet_id subnet_name subnet_cidr
            subnet_id=$(safe_jq "$subnet" '.id')
            subnet_name=$(safe_jq "$subnet" '.name')
            subnet_cidr=$(safe_jq "$subnet" '.cidr')
            
            if [ -n "$subnet_id" ] && [ "$subnet_id" != "null" ]; then
                EXISTING_SUBNETS["$subnet_id"]="$subnet_name|$subnet_cidr|$vcn_id"
                print_debug "    Subnet: $subnet_name ($subnet_cidr)"
            fi
        done <<< "$(echo "$subnet_list" | jq -c '.[]' 2>/dev/null)"
        
        # Get internet gateways
        local ig_list
        ig_list=$(oci_cmd "network internet-gateway list \
            --compartment-id $tenancy_ocid \
            --vcn-id $vcn_id \
            --query 'data[?\"lifecycle-state\"==\`AVAILABLE\`].{id:id,name:\"display-name\"}'" 2>/dev/null) || ig_list="[]"
        
        while IFS= read -r ig; do
            local ig_id ig_name
            ig_id=$(safe_jq "$ig" '.id')
            ig_name=$(safe_jq "$ig" '.name')
            
            if [ -n "$ig_id" ] && [ "$ig_id" != "null" ]; then
                EXISTING_INTERNET_GATEWAYS["$ig_id"]="$ig_name|$vcn_id"
            fi
        done <<< "$(echo "$ig_list" | jq -c '.[]' 2>/dev/null)"
        
        # Get route tables
        local rt_list
        rt_list=$(oci_cmd "network route-table list \
            --compartment-id $tenancy_ocid \
            --vcn-id $vcn_id \
            --query 'data[].{id:id,name:\"display-name\"}'" 2>/dev/null) || rt_list="[]"
        
        while IFS= read -r rt; do
            local rt_id rt_name
            rt_id=$(safe_jq "$rt" '.id')
            rt_name=$(safe_jq "$rt" '.name')
            
            if [ -n "$rt_id" ] && [ "$rt_id" != "null" ]; then
                EXISTING_ROUTE_TABLES["$rt_id"]="$rt_name|$vcn_id"
            fi
        done <<< "$(echo "$rt_list" | jq -c '.[]' 2>/dev/null)"
        
        # Get security lists
        local sl_list
        sl_list=$(oci_cmd "network security-list list \
            --compartment-id $tenancy_ocid \
            --vcn-id $vcn_id \
            --query 'data[].{id:id,name:\"display-name\"}'" 2>/dev/null) || sl_list="[]"
        
        while IFS= read -r sl; do
            local sl_id sl_name
            sl_id=$(safe_jq "$sl" '.id')
            sl_name=$(safe_jq "$sl" '.name')
            
            if [ -n "$sl_id" ] && [ "$sl_id" != "null" ]; then
                EXISTING_SECURITY_LISTS["$sl_id"]="$sl_name|$vcn_id"
            fi
        done <<< "$(echo "$sl_list" | jq -c '.[]' 2>/dev/null)"
        
    done <<< "$(echo "$vcn_list" | jq -c '.[]' 2>/dev/null)"
    
    print_status "  VCNs: ${#EXISTING_VCNS[@]}/${FREE_TIER_MAX_VCNS}"
    print_status "  Subnets: ${#EXISTING_SUBNETS[@]}"
    print_status "  Internet Gateways: ${#EXISTING_INTERNET_GATEWAYS[@]}"
}

inventory_storage_resources() {
    print_status "Inventorying storage resources..."
    
    EXISTING_BOOT_VOLUMES=()
    EXISTING_BLOCK_VOLUMES=()
    
    # Get boot volumes
    local boot_list
    boot_list=$(oci_cmd "bv boot-volume list \
        --compartment-id $tenancy_ocid \
        --availability-domain $availability_domain \
        --query 'data[?\"lifecycle-state\"==\`AVAILABLE\`].{id:id,name:\"display-name\",size:\"size-in-gbs\"}' \
        --all" 2>/dev/null) || boot_list="[]"
    
    local total_boot_gb=0
    
    while IFS= read -r boot; do
        local boot_id boot_name boot_size
        boot_id=$(safe_jq "$boot" '.id')
        boot_name=$(safe_jq "$boot" '.name')
        boot_size=$(safe_jq "$boot" '.size' "0")
        
        if [ -n "$boot_id" ] && [ "$boot_id" != "null" ]; then
            EXISTING_BOOT_VOLUMES["$boot_id"]="$boot_name|$boot_size"
            total_boot_gb=$((total_boot_gb + boot_size))
        fi
    done <<< "$(echo "$boot_list" | jq -c '.[]' 2>/dev/null)"
    
    # Get block volumes
    local block_list
    block_list=$(oci_cmd "bv volume list \
        --compartment-id $tenancy_ocid \
        --availability-domain $availability_domain \
        --query 'data[?\"lifecycle-state\"==\`AVAILABLE\`].{id:id,name:\"display-name\",size:\"size-in-gbs\"}' \
        --all" 2>/dev/null) || block_list="[]"
    
    local total_block_gb=0
    
    while IFS= read -r block; do
        local block_id block_name block_size
        block_id=$(safe_jq "$block" '.id')
        block_name=$(safe_jq "$block" '.name')
        block_size=$(safe_jq "$block" '.size' "0")
        
        if [ -n "$block_id" ] && [ "$block_id" != "null" ]; then
            EXISTING_BLOCK_VOLUMES["$block_id"]="$block_name|$block_size"
            total_block_gb=$((total_block_gb + block_size))
        fi
    done <<< "$(echo "$block_list" | jq -c '.[]' 2>/dev/null)"
    
    local total_storage=$((total_boot_gb + total_block_gb))
    
    print_status "  Boot volumes: ${#EXISTING_BOOT_VOLUMES[@]} (${total_boot_gb}GB)"
    print_status "  Block volumes: ${#EXISTING_BLOCK_VOLUMES[@]} (${total_block_gb}GB)"
    print_status "  Total storage: ${total_storage}GB/${FREE_TIER_MAX_STORAGE_GB}GB"
}

display_resource_inventory() {
    echo ""
    print_header "RESOURCE INVENTORY SUMMARY"
    
    # Calculate totals
    local total_amd=${#EXISTING_AMD_INSTANCES[@]}
    local total_arm=${#EXISTING_ARM_INSTANCES[@]}
    local total_arm_ocpus=0
    local total_arm_memory=0
    
    for instance_data in "${EXISTING_ARM_INSTANCES[@]}"; do
        local ocpus memory
        ocpus=$(echo "$instance_data" | cut -d'|' -f6)
        memory=$(echo "$instance_data" | cut -d'|' -f7)
        total_arm_ocpus=$((total_arm_ocpus + ocpus))
        total_arm_memory=$((total_arm_memory + memory))
    done
    
    local total_boot_gb=0
    for boot_data in "${EXISTING_BOOT_VOLUMES[@]}"; do
        local size
        size=$(echo "$boot_data" | cut -d'|' -f2)
        total_boot_gb=$((total_boot_gb + size))
    done
    
    local total_block_gb=0
    for block_data in "${EXISTING_BLOCK_VOLUMES[@]}"; do
        local size
        size=$(echo "$block_data" | cut -d'|' -f2)
        total_block_gb=$((total_block_gb + size))
    done
    
    local total_storage=$((total_boot_gb + total_block_gb))
    
    echo -e "${BOLD}Compute Resources:${NC}"
    echo "  ┌─────────────────────────────────────────────────────────────┐"
    echo "  │ AMD Micro Instances:  $total_amd / $FREE_TIER_MAX_AMD_INSTANCES (Free Tier limit)          │"
    echo "  │ ARM A1 Instances:     $total_arm / $FREE_TIER_MAX_ARM_INSTANCES (up to)                    │"
    echo "  │ ARM OCPUs Used:       $total_arm_ocpus / $FREE_TIER_MAX_ARM_OCPUS                           │"
    echo "  │ ARM Memory Used:      ${total_arm_memory}GB / ${FREE_TIER_MAX_ARM_MEMORY_GB}GB                         │"
    echo "  └─────────────────────────────────────────────────────────────┘"
    echo ""
    echo -e "${BOLD}Storage Resources:${NC}"
    echo "  ┌─────────────────────────────────────────────────────────────┐"
    echo "  │ Boot Volumes:         ${total_boot_gb}GB                                    │"
    echo "  │ Block Volumes:        ${total_block_gb}GB                                    │"
    printf "  │ Total Storage:        %3dGB / %3dGB Free Tier limit          │\n" "$total_storage" "$FREE_TIER_MAX_STORAGE_GB"
    echo "  └─────────────────────────────────────────────────────────────┘"
    echo ""
    echo -e "${BOLD}Networking Resources:${NC}"
    echo "  ┌─────────────────────────────────────────────────────────────┐"
    echo "  │ VCNs:                 ${#EXISTING_VCNS[@]} / $FREE_TIER_MAX_VCNS (Free Tier limit)             │"
    echo "  │ Subnets:              ${#EXISTING_SUBNETS[@]}                                       │"
    echo "  │ Internet Gateways:    ${#EXISTING_INTERNET_GATEWAYS[@]}                                       │"
    echo "  └─────────────────────────────────────────────────────────────┘"
    echo ""
    
    # Warnings for near-limit resources
    if [ "$total_amd" -ge "$FREE_TIER_MAX_AMD_INSTANCES" ]; then
        print_warning "AMD instance limit reached - cannot create more AMD instances"
    fi
    if [ "$total_arm_ocpus" -ge "$FREE_TIER_MAX_ARM_OCPUS" ]; then
        print_warning "ARM OCPU limit reached - cannot allocate more ARM OCPUs"
    fi
    if [ "$total_arm_memory" -ge "$FREE_TIER_MAX_ARM_MEMORY_GB" ]; then
        print_warning "ARM memory limit reached - cannot allocate more ARM memory"
    fi
    if [ "$total_storage" -ge "$FREE_TIER_MAX_STORAGE_GB" ]; then
        print_warning "Storage limit reached - cannot create more volumes"
    fi
    if [ "${#EXISTING_VCNS[@]}" -ge "$FREE_TIER_MAX_VCNS" ]; then
        print_warning "VCN limit reached - cannot create more VCNs"
    fi
}

# ============================================================================
# FREE TIER LIMIT VALIDATION
# ============================================================================

calculate_available_resources() {
    # Calculate what's still available within Free Tier limits
    local used_amd=${#EXISTING_AMD_INSTANCES[@]}
    local used_arm_ocpus=0
    local used_arm_memory=0
    local used_storage=0
    
    for instance_data in "${EXISTING_ARM_INSTANCES[@]}"; do
        local ocpus memory
        ocpus=$(echo "$instance_data" | cut -d'|' -f6)
        memory=$(echo "$instance_data" | cut -d'|' -f7)
        used_arm_ocpus=$((used_arm_ocpus + ocpus))
        used_arm_memory=$((used_arm_memory + memory))
    done
    
    for boot_data in "${EXISTING_BOOT_VOLUMES[@]}"; do
        local size
        size=$(echo "$boot_data" | cut -d'|' -f2)
        used_storage=$((used_storage + size))
    done
    
    for block_data in "${EXISTING_BLOCK_VOLUMES[@]}"; do
        local size
        size=$(echo "$block_data" | cut -d'|' -f2)
        used_storage=$((used_storage + size))
    done
    
    # Export available resources
    export AVAILABLE_AMD_INSTANCES=$((FREE_TIER_MAX_AMD_INSTANCES - used_amd))
    export AVAILABLE_ARM_OCPUS=$((FREE_TIER_MAX_ARM_OCPUS - used_arm_ocpus))
    export AVAILABLE_ARM_MEMORY=$((FREE_TIER_MAX_ARM_MEMORY_GB - used_arm_memory))
    export AVAILABLE_STORAGE=$((FREE_TIER_MAX_STORAGE_GB - used_storage))
    export USED_ARM_INSTANCES=${#EXISTING_ARM_INSTANCES[@]}
    
    print_debug "Available: AMD=$AVAILABLE_AMD_INSTANCES, ARM_OCPU=$AVAILABLE_ARM_OCPUS, ARM_MEM=$AVAILABLE_ARM_MEMORY, Storage=$AVAILABLE_STORAGE"
}

validate_proposed_config() {
    local proposed_amd=$1
    # shellcheck disable=SC2034  # keep argument for future checks
    local proposed_arm=$2
    local proposed_arm_ocpus=$3
    local proposed_arm_memory=$4
    local proposed_storage=$5
    
    local errors=0
    
    if [ "$proposed_amd" -gt "$AVAILABLE_AMD_INSTANCES" ]; then
        print_error "Cannot create $proposed_amd AMD instances - only $AVAILABLE_AMD_INSTANCES available"
        errors=$((errors + 1))
    fi
    
    if [ "$proposed_arm_ocpus" -gt "$AVAILABLE_ARM_OCPUS" ]; then
        print_error "Cannot allocate $proposed_arm_ocpus ARM OCPUs - only $AVAILABLE_ARM_OCPUS available"
        errors=$((errors + 1))
    fi
    
    if [ "$proposed_arm_memory" -gt "$AVAILABLE_ARM_MEMORY" ]; then
        print_error "Cannot allocate ${proposed_arm_memory}GB ARM memory - only ${AVAILABLE_ARM_MEMORY}GB available"
        errors=$((errors + 1))
    fi
    
    if [ "$proposed_storage" -gt "$AVAILABLE_STORAGE" ]; then
        print_error "Cannot use ${proposed_storage}GB storage - only ${AVAILABLE_STORAGE}GB available"
        errors=$((errors + 1))
    fi
    
    return $errors
}

# ============================================================================
# CONFIGURATION FUNCTIONS
# ============================================================================

load_existing_config() {
    if [ ! -f "variables.tf" ]; then
        return 1
    fi
    
    print_status "Loading existing configuration from variables.tf..."
    
    # Load basic counts
    amd_micro_instance_count=$(grep -oP 'amd_micro_instance_count\s*=\s*\K[0-9]+' variables.tf 2>/dev/null | head -1) || amd_micro_instance_count=0
    amd_micro_boot_volume_size_gb=$(grep -oP 'amd_micro_boot_volume_size_gb\s*=\s*\K[0-9]+' variables.tf 2>/dev/null | head -1) || amd_micro_boot_volume_size_gb=50
    arm_flex_instance_count=$(grep -oP 'arm_flex_instance_count\s*=\s*\K[0-9]+' variables.tf 2>/dev/null | head -1) || arm_flex_instance_count=0
    
    # Load ARM arrays
    local ocpus_str memory_str boot_str
    ocpus_str=$(grep -oP 'arm_flex_ocpus_per_instance\s*=\s*\[\K[^\]]+' variables.tf 2>/dev/null | head -1) || ocpus_str=""
    memory_str=$(grep -oP 'arm_flex_memory_per_instance\s*=\s*\[\K[^\]]+' variables.tf 2>/dev/null | head -1) || memory_str=""
    boot_str=$(grep -oP 'arm_flex_boot_volume_size_gb\s*=\s*\[\K[^\]]+' variables.tf 2>/dev/null | head -1) || boot_str=""
    
    arm_flex_ocpus_per_instance=$(echo "$ocpus_str" | tr ',' ' ' | tr -s ' ')
    arm_flex_memory_per_instance=$(echo "$memory_str" | tr ',' ' ' | tr -s ' ')
    arm_flex_boot_volume_size_gb=$(echo "$boot_str" | tr ',' ' ' | tr -s ' ')
    
    # Load hostnames
    local amd_hostnames_str arm_hostnames_str
    amd_hostnames_str=$(grep -oP 'amd_micro_hostnames\s*=\s*\[\K[^\]]+' variables.tf 2>/dev/null | head -1) || amd_hostnames_str=""
    arm_hostnames_str=$(grep -oP 'arm_flex_hostnames\s*=\s*\[\K[^\]]+' variables.tf 2>/dev/null | head -1) || arm_hostnames_str=""
    
    amd_micro_hostnames=()
    arm_flex_hostnames=()
    
    if [ -n "$amd_hostnames_str" ]; then
        while IFS= read -r hostname; do
            hostname=$(echo "$hostname" | tr -d '"' | tr -d ' ')
            [ -n "$hostname" ] && amd_micro_hostnames+=("$hostname")
        done <<< "$(echo "$amd_hostnames_str" | tr ',' '\n')"
    fi
    
    if [ -n "$arm_hostnames_str" ]; then
        while IFS= read -r hostname; do
            hostname=$(echo "$hostname" | tr -d '"' | tr -d ' ')
            [ -n "$hostname" ] && arm_flex_hostnames+=("$hostname")
        done <<< "$(echo "$arm_hostnames_str" | tr ',' '\n')"
    fi
    
    print_success "Loaded configuration: ${amd_micro_instance_count}x AMD, ${arm_flex_instance_count}x ARM"
    return 0
}

prompt_configuration() {
    print_header "INSTANCE CONFIGURATION"
    
    calculate_available_resources
    
    echo -e "${BOLD}Available Free Tier Resources:${NC}"
    echo "  • AMD instances:  $AVAILABLE_AMD_INSTANCES available (max $FREE_TIER_MAX_AMD_INSTANCES)"
    echo "  • ARM OCPUs:      $AVAILABLE_ARM_OCPUS available (max $FREE_TIER_MAX_ARM_OCPUS)"
    echo "  • ARM Memory:     ${AVAILABLE_ARM_MEMORY}GB available (max ${FREE_TIER_MAX_ARM_MEMORY_GB}GB)"
    echo "  • Storage:        ${AVAILABLE_STORAGE}GB available (max ${FREE_TIER_MAX_STORAGE_GB}GB)"
    echo ""
    
    # Check if we have existing config
    local has_existing_config=false
    if load_existing_config; then
        has_existing_config=true
    fi
    
    print_status "Configuration options:"
    echo "  1) Use existing instances (manage what's already deployed)"
    if [ "$has_existing_config" = "true" ]; then
        echo "  2) Use saved configuration from variables.tf"
    else
        echo "  2) Use saved configuration from variables.tf (not available)"
    fi
    echo "  3) Configure new instances (respecting Free Tier limits)"
    echo "  4) Maximum Free Tier configuration (use all available resources)"
    echo ""
    
    local choice
    while true; do
        if [ "$AUTO_USE_EXISTING" = "true" ]; then
            choice=1
            print_status "Auto mode: Using existing instances"
        elif [ "$NON_INTERACTIVE" = "true" ]; then
            choice=1
            print_status "Non-interactive mode: Using existing instances"
        else
            # Use prompt_with_default so the user sees the default inline (e.g. "[1]") as requested
            raw_choice=$(prompt_with_default "Choose configuration (1-4)" "1")
            # Normalize input (remove CR and trim whitespace)
            raw_choice=$(echo "$raw_choice" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            # Validate numeric range
            if [[ "$raw_choice" =~ ^[0-9]+$ ]] && [ "$raw_choice" -ge 1 ] && [ "$raw_choice" -le 4 ]; then
                choice=$raw_choice
            else
                print_error "Please enter a number between 1 and 4 (received: '$raw_choice')"
                continue
            fi
        fi
        
        case $choice in
            1)
                configure_from_existing_instances
                break
                ;;
            2)
                if [ "$has_existing_config" = "true" ]; then
                    print_success "Using saved configuration"
                    break
                else
                    print_error "No saved configuration available"
                    continue
                fi
                ;;
            3)
                configure_custom_instances
                break
                ;;
            4)
                configure_maximum_free_tier
                break
                ;;
            *)
                print_error "Invalid choice"
                continue
                ;;
        esac
    done
}

configure_from_existing_instances() {
    print_status "Configuring based on existing instances..."
    
    # Use existing AMD instances
    amd_micro_instance_count=${#EXISTING_AMD_INSTANCES[@]}
    amd_micro_hostnames=()
    
    for instance_data in "${EXISTING_AMD_INSTANCES[@]}"; do
        local name
        name=$(echo "$instance_data" | cut -d'|' -f1)
        amd_micro_hostnames+=("$name")
    done
    
    # Use existing ARM instances
    arm_flex_instance_count=${#EXISTING_ARM_INSTANCES[@]}
    arm_flex_hostnames=()
    arm_flex_ocpus_per_instance=""
    arm_flex_memory_per_instance=""
    arm_flex_boot_volume_size_gb=""
    arm_flex_block_volumes=()
    
    for instance_data in "${EXISTING_ARM_INSTANCES[@]}"; do
        local name ocpus memory
        name=$(echo "$instance_data" | cut -d'|' -f1)
        ocpus=$(echo "$instance_data" | cut -d'|' -f6)
        memory=$(echo "$instance_data" | cut -d'|' -f7)
        
        arm_flex_hostnames+=("$name")
        arm_flex_ocpus_per_instance+="$ocpus "
        arm_flex_memory_per_instance+="$memory "
        arm_flex_boot_volume_size_gb+="50 "  # Default, will be updated from state
        arm_flex_block_volumes+=(0)
    done
    
    # Trim trailing spaces
    arm_flex_ocpus_per_instance=$(echo "$arm_flex_ocpus_per_instance" | xargs)
    arm_flex_memory_per_instance=$(echo "$arm_flex_memory_per_instance" | xargs)
    arm_flex_boot_volume_size_gb=$(echo "$arm_flex_boot_volume_size_gb" | xargs)
    
    # Set defaults if no instances exist
    if [ "$amd_micro_instance_count" -eq 0 ] && [ "$arm_flex_instance_count" -eq 0 ]; then
        print_status "No existing instances found, using default configuration"
        amd_micro_instance_count=0
        arm_flex_instance_count=1
        arm_flex_ocpus_per_instance="4"
        arm_flex_memory_per_instance="24"
        arm_flex_boot_volume_size_gb="200"
        arm_flex_hostnames=("arm-instance-1")
        arm_flex_block_volumes=(0)
    fi
    
    amd_micro_boot_volume_size_gb=50
    
    print_success "Configuration: ${amd_micro_instance_count}x AMD, ${arm_flex_instance_count}x ARM"
}

configure_custom_instances() {
    print_status "Custom instance configuration..."
    
    # AMD instances
    amd_micro_instance_count=$(prompt_int_range "Number of AMD instances (0-$AVAILABLE_AMD_INSTANCES)" "0" "0" "$AVAILABLE_AMD_INSTANCES")
    
    amd_micro_hostnames=()
    if [ "$amd_micro_instance_count" -gt 0 ]; then
        amd_micro_boot_volume_size_gb=$(prompt_int_range "AMD boot volume size GB (50-100)" "50" "50" "100")
        
        for ((i=1; i<=amd_micro_instance_count; i++)); do
            echo -n -e "${BLUE}Hostname for AMD instance $i [amd-instance-$i]: ${NC}"
            read -r hostname
            hostname=${hostname:-"amd-instance-$i"}
            amd_micro_hostnames+=("$hostname")
        done
    else
        amd_micro_boot_volume_size_gb=50
    fi
    
    # ARM instances
    if [ -n "$ubuntu_arm_flex_image_ocid" ] && [ "$AVAILABLE_ARM_OCPUS" -gt 0 ]; then
        arm_flex_instance_count=$(prompt_int_range "Number of ARM instances (0-4)" "1" "0" "4")
        
        arm_flex_hostnames=()
        arm_flex_ocpus_per_instance=""
        arm_flex_memory_per_instance=""
        arm_flex_boot_volume_size_gb=""
        arm_flex_block_volumes=()
        
        local remaining_ocpus=$AVAILABLE_ARM_OCPUS
        local remaining_memory=$AVAILABLE_ARM_MEMORY
        
        for ((i=1; i<=arm_flex_instance_count; i++)); do
            echo ""
            print_status "ARM instance $i configuration (remaining: ${remaining_ocpus} OCPUs, ${remaining_memory}GB RAM):"
            
            echo -n -e "${BLUE}  Hostname [arm-instance-$i]: ${NC}"
            read -r hostname
            hostname=${hostname:-"arm-instance-$i"}
            arm_flex_hostnames+=("$hostname")

            ocpus=$(prompt_int_range "  OCPUs (1-$remaining_ocpus)" "$remaining_ocpus" "1" "$remaining_ocpus")
            arm_flex_ocpus_per_instance+="$ocpus "
            remaining_ocpus=$((remaining_ocpus - ocpus))
            
            local max_memory=$((ocpus * 6))  # 6GB per OCPU max
            [ $max_memory -gt $remaining_memory ] && max_memory=$remaining_memory

            memory=$(prompt_int_range "  Memory GB (1-$max_memory)" "$max_memory" "1" "$max_memory")
            arm_flex_memory_per_instance+="$memory "
            remaining_memory=$((remaining_memory - memory))

            boot=$(prompt_int_range "  Boot volume GB (50-200)" "50" "50" "200")
            arm_flex_boot_volume_size_gb+="$boot "
            
            arm_flex_block_volumes+=(0)
        done
        
        arm_flex_ocpus_per_instance=$(echo "$arm_flex_ocpus_per_instance" | xargs)
        arm_flex_memory_per_instance=$(echo "$arm_flex_memory_per_instance" | xargs)
        arm_flex_boot_volume_size_gb=$(echo "$arm_flex_boot_volume_size_gb" | xargs)
    else
        arm_flex_instance_count=0
        arm_flex_ocpus_per_instance=""
        arm_flex_memory_per_instance=""
        arm_flex_boot_volume_size_gb=""
        arm_flex_block_volumes=()
        arm_flex_hostnames=()
    fi
}

configure_maximum_free_tier() {
    print_status "Configuring maximum Free Tier utilization..."
    
    # Use all available AMD instances
    amd_micro_instance_count=$AVAILABLE_AMD_INSTANCES
    amd_micro_boot_volume_size_gb=50
    amd_micro_hostnames=()
    for ((i=1; i<=amd_micro_instance_count; i++)); do
        amd_micro_hostnames+=("amd-instance-$i")
    done
    
    # Use all available ARM resources
    if [ -n "$ubuntu_arm_flex_image_ocid" ] && [ "$AVAILABLE_ARM_OCPUS" -gt 0 ]; then
        arm_flex_instance_count=1
        arm_flex_ocpus_per_instance="$AVAILABLE_ARM_OCPUS"
        arm_flex_memory_per_instance="$AVAILABLE_ARM_MEMORY"
        
        # Calculate boot volume size to use remaining storage
        local used_by_amd=$((amd_micro_instance_count * amd_micro_boot_volume_size_gb))
        local remaining_storage=$((AVAILABLE_STORAGE - used_by_amd))
        [ $remaining_storage -lt $FREE_TIER_MIN_BOOT_VOLUME_GB ] && remaining_storage=$FREE_TIER_MIN_BOOT_VOLUME_GB
        
        arm_flex_boot_volume_size_gb="$remaining_storage"
        arm_flex_hostnames=("arm-instance-1")
        arm_flex_block_volumes=(0)
    else
        arm_flex_instance_count=0
        arm_flex_ocpus_per_instance=""
        arm_flex_memory_per_instance=""
        arm_flex_boot_volume_size_gb=""
        arm_flex_hostnames=()
        arm_flex_block_volumes=()
    fi
    
    print_success "Maximum config: ${amd_micro_instance_count}x AMD, ${arm_flex_instance_count}x ARM ($AVAILABLE_ARM_OCPUS OCPUs, ${AVAILABLE_ARM_MEMORY}GB)"
}

# ============================================================================
# TERRAFORM FILE GENERATION
# ============================================================================

create_terraform_files() {
    print_header "GENERATING TERRAFORM FILES"
    
    create_terraform_provider
    create_terraform_variables
    create_terraform_datasources
    create_terraform_main
    create_terraform_block_volumes
    create_cloud_init
    
    print_success "All Terraform files generated successfully"
}

create_terraform_provider() {
    print_status "Creating provider.tf..."

    # Configure terraform backend if requested (may create backend.tf)
    configure_terraform_backend || true
    
    [ -f "provider.tf" ] && cp provider.tf "provider.tf.bak.$(date +%Y%m%d_%H%M%S)"
    
    cat > provider.tf << EOF
# Terraform Provider Configuration for Oracle Cloud Infrastructure
# Generated: $(date)
# Region: $region

terraform {
  required_version = ">= 1.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
    }
  }
}

# OCI Provider with session token authentication
provider "oci" {
  auth                = "SecurityToken"
  config_file_profile = "DEFAULT"
  region              = "$region"
}
EOF
    
    print_success "provider.tf created"
}

create_terraform_variables() {
    print_status "Creating variables.tf..."
    
    [ -f "variables.tf" ] && cp variables.tf "variables.tf.bak.$(date +%Y%m%d_%H%M%S)"
    
    # Build array strings for Terraform
    local amd_hostnames_tf="["
    for ((i=0; i<${#amd_micro_hostnames[@]}; i++)); do
        [ $i -gt 0 ] && amd_hostnames_tf+=", "
        amd_hostnames_tf+="\"${amd_micro_hostnames[$i]}\""
    done
    amd_hostnames_tf+="]"
    
    local arm_hostnames_tf="["
    for ((i=0; i<${#arm_flex_hostnames[@]}; i++)); do
        [ $i -gt 0 ] && arm_hostnames_tf+=", "
        arm_hostnames_tf+="\"${arm_flex_hostnames[$i]}\""
    done
    arm_hostnames_tf+="]"
    
    local arm_ocpus_tf="["
    local arm_memory_tf="["
    local arm_boot_tf="["
    local arm_block_tf="["
    
    if [ "$arm_flex_instance_count" -gt 0 ]; then
        # Split space-separated strings safely into arrays
        IFS=' ' read -r -a ocpu_arr <<< "$arm_flex_ocpus_per_instance"
        IFS=' ' read -r -a memory_arr <<< "$arm_flex_memory_per_instance"
        IFS=' ' read -r -a boot_arr <<< "$arm_flex_boot_volume_size_gb"
        
        for ((i=0; i<${#ocpu_arr[@]}; i++)); do
            [ $i -gt 0 ] && arm_ocpus_tf+=", " && arm_memory_tf+=", " && arm_boot_tf+=", " && arm_block_tf+=", "
            arm_ocpus_tf+="${ocpu_arr[$i]}"
            arm_memory_tf+="${memory_arr[$i]}"
            arm_boot_tf+="${boot_arr[$i]}"
            arm_block_tf+="${arm_flex_block_volumes[$i]:-0}"
        done
    fi
    
    arm_ocpus_tf+="]"
    arm_memory_tf+="]"
    arm_boot_tf+="]"
    arm_block_tf+="]"
    
    cat > variables.tf << EOF
# Oracle Cloud Infrastructure Terraform Variables
# Generated: $(date)
# Configuration: ${amd_micro_instance_count}x AMD + ${arm_flex_instance_count}x ARM instances

locals {
  # Core identifiers
  tenancy_ocid    = "$tenancy_ocid"
  compartment_id  = "$tenancy_ocid"
  user_ocid       = "$user_ocid"
  region          = "$region"
  
  # Ubuntu Images (region-specific)
  ubuntu_x86_image_ocid = "$ubuntu_image_ocid"
  ubuntu_arm_image_ocid = "$ubuntu_arm_flex_image_ocid"
  
  # SSH Configuration
  ssh_pubkey_path      = pathexpand("./ssh_keys/id_rsa.pub")
  ssh_pubkey_data      = file(pathexpand("./ssh_keys/id_rsa.pub"))
  ssh_private_key_path = pathexpand("./ssh_keys/id_rsa")
  
  # AMD x86 Micro Instances Configuration
  amd_micro_instance_count      = $amd_micro_instance_count
  amd_micro_boot_volume_size_gb = $amd_micro_boot_volume_size_gb
  amd_micro_hostnames           = $amd_hostnames_tf
  amd_block_volume_size_gb      = 0
  
  # ARM A1 Flex Instances Configuration
  arm_flex_instance_count       = $arm_flex_instance_count
  arm_flex_ocpus_per_instance   = $arm_ocpus_tf
  arm_flex_memory_per_instance  = $arm_memory_tf
  arm_flex_boot_volume_size_gb  = $arm_boot_tf
  arm_flex_hostnames            = $arm_hostnames_tf
  arm_block_volume_sizes        = $arm_block_tf
  
  # Storage calculations
  total_amd_storage = local.amd_micro_instance_count * local.amd_micro_boot_volume_size_gb
  total_arm_storage = local.arm_flex_instance_count > 0 ? sum(local.arm_flex_boot_volume_size_gb) : 0
  total_block_storage = (local.amd_micro_instance_count * local.amd_block_volume_size_gb) + (local.arm_flex_instance_count > 0 ? sum(local.arm_block_volume_sizes) : 0)
  total_storage = local.total_amd_storage + local.total_arm_storage + local.total_block_storage
}

# Free Tier Limits
variable "free_tier_max_storage_gb" {
  description = "Maximum storage for Oracle Free Tier"
  type        = number
  default     = $FREE_TIER_MAX_STORAGE_GB
}

variable "free_tier_max_arm_ocpus" {
  description = "Maximum ARM OCPUs for Oracle Free Tier"
  type        = number
  default     = $FREE_TIER_MAX_ARM_OCPUS
}

variable "free_tier_max_arm_memory_gb" {
  description = "Maximum ARM memory for Oracle Free Tier"
  type        = number
  default     = $FREE_TIER_MAX_ARM_MEMORY_GB
}

# Validation checks
check "storage_limit" {
  assert {
    condition     = local.total_storage <= var.free_tier_max_storage_gb
    error_message = "Total storage (\${local.total_storage}GB) exceeds Free Tier limit (\${var.free_tier_max_storage_gb}GB)"
  }
}

check "arm_ocpu_limit" {
  assert {
    condition     = local.arm_flex_instance_count == 0 || sum(local.arm_flex_ocpus_per_instance) <= var.free_tier_max_arm_ocpus
    error_message = "Total ARM OCPUs exceed Free Tier limit (\${var.free_tier_max_arm_ocpus})"
  }
}

check "arm_memory_limit" {
  assert {
    condition     = local.arm_flex_instance_count == 0 || sum(local.arm_flex_memory_per_instance) <= var.free_tier_max_arm_memory_gb
    error_message = "Total ARM memory exceeds Free Tier limit (\${var.free_tier_max_arm_memory_gb}GB)"
  }
}
EOF
    
    print_success "variables.tf created"
}

create_terraform_datasources() {
    print_status "Creating data_sources.tf..."
    
    [ -f "data_sources.tf" ] && cp data_sources.tf "data_sources.tf.bak.$(date +%Y%m%d_%H%M%S)"
    
    cat > data_sources.tf << 'EOF'
# OCI Data Sources
# Fetches dynamic information from Oracle Cloud

# Availability Domains
data "oci_identity_availability_domains" "ads" {
  compartment_id = local.tenancy_ocid
}

# Tenancy Information
data "oci_identity_tenancy" "tenancy" {
  tenancy_id = local.tenancy_ocid
}

# Available Regions
data "oci_identity_regions" "regions" {}

# Region Subscriptions
data "oci_identity_region_subscriptions" "subscriptions" {
  tenancy_id = local.tenancy_ocid
}
EOF
    
    print_success "data_sources.tf created"
}

create_terraform_main() {
    print_status "Creating main.tf..."
    
    [ -f "main.tf" ] && cp main.tf "main.tf.bak.$(date +%Y%m%d_%H%M%S)"
    
    cat > main.tf << 'EOFMAIN'
# Oracle Cloud Infrastructure - Main Configuration
# Always Free Tier Optimized

# ============================================================================
# NETWORKING
# ============================================================================

resource "oci_core_vcn" "main" {
  compartment_id = local.compartment_id
  cidr_blocks    = ["10.0.0.0/16"]
  display_name   = "main-vcn"
  dns_label      = "mainvcn"
  is_ipv6enabled = true
  
  freeform_tags = {
    "Purpose" = "AlwaysFreeTier"
    "Managed" = "Terraform"
  }
}

resource "oci_core_internet_gateway" "main" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "main-igw"
  enabled        = true
}

resource "oci_core_default_route_table" "main" {
  manage_default_resource_id = oci_core_vcn.main.default_route_table_id
  display_name               = "main-rt"
  
  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.main.id
  }
  
  route_rules {
    destination       = "::/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.main.id
  }
}

resource "oci_core_default_security_list" "main" {
  manage_default_resource_id = oci_core_vcn.main.default_security_list_id
  display_name               = "main-sl"
  
  # Allow all egress
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }
  
  egress_security_rules {
    destination = "::/0"
    protocol    = "all"
  }
  
  # Allow ALL ingress traffic on ALL ports and ALL protocols (IPv4)
  # OCI Security List: protocol "all" with no tcp/udp options = every port, every protocol
  # Eliminates the need to manually open ports in the OCI console after deployment.
  ingress_security_rules {
    protocol = "all"
    source   = "0.0.0.0/0"
  }
  # Allow ALL ingress traffic on ALL ports and ALL protocols (IPv6)
  ingress_security_rules {
    protocol = "all"
    source   = "::/0"
  }
}

resource "oci_core_subnet" "main" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.main.id
  cidr_block     = "10.0.1.0/24"
  display_name   = "main-subnet"
  dns_label      = "mainsubnet"
  
  route_table_id    = oci_core_default_route_table.main.id
  security_list_ids = [oci_core_default_security_list.main.id]
  
  # IPv6 - use first /64 block from VCN's /56
  ipv6cidr_blocks = [cidrsubnet(oci_core_vcn.main.ipv6cidr_blocks[0], 8, 0)]
}

# ============================================================================
# COMPUTE INSTANCES
# ============================================================================

# AMD x86 Micro Instances
resource "oci_core_instance" "amd" {
  count = local.amd_micro_instance_count
  
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = local.compartment_id
  display_name        = local.amd_micro_hostnames[count.index]
  shape               = "VM.Standard.E2.1.Micro"
  
  create_vnic_details {
    subnet_id        = oci_core_subnet.main.id
    display_name     = "${local.amd_micro_hostnames[count.index]}-vnic"
    assign_public_ip = true
    assign_ipv6ip    = true
    hostname_label   = local.amd_micro_hostnames[count.index]
  }
  
  source_details {
    source_type             = "image"
    source_id               = local.ubuntu_x86_image_ocid
    boot_volume_size_in_gbs = local.amd_micro_boot_volume_size_gb
  }
  
  metadata = {
    ssh_authorized_keys = local.ssh_pubkey_data
    user_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
      hostname = local.amd_micro_hostnames[count.index]
    }))
  }
  
  freeform_tags = {
    "Purpose"      = "AlwaysFreeTier"
    "InstanceType" = "AMD-Micro"
    "Managed"      = "Terraform"
  }
  
  lifecycle {
    ignore_changes = [
      source_details[0].source_id,  # Ignore image updates
      defined_tags,
    ]
  }
}

# ARM A1 Flex Instances
resource "oci_core_instance" "arm" {
  count = local.arm_flex_instance_count
  
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = local.compartment_id
  display_name        = local.arm_flex_hostnames[count.index]
  shape               = "VM.Standard.A1.Flex"
  
  shape_config {
    ocpus         = local.arm_flex_ocpus_per_instance[count.index]
    memory_in_gbs = local.arm_flex_memory_per_instance[count.index]
  }
  
  create_vnic_details {
    subnet_id        = oci_core_subnet.main.id
    display_name     = "${local.arm_flex_hostnames[count.index]}-vnic"
    assign_public_ip = true
    assign_ipv6ip    = true
    hostname_label   = local.arm_flex_hostnames[count.index]
  }
  
  source_details {
    source_type             = "image"
    source_id               = local.ubuntu_arm_image_ocid
    boot_volume_size_in_gbs = local.arm_flex_boot_volume_size_gb[count.index]
  }
  
  metadata = {
    ssh_authorized_keys = local.ssh_pubkey_data
    user_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
      hostname = local.arm_flex_hostnames[count.index]
    }))
  }
  
  freeform_tags = {
    "Purpose"      = "AlwaysFreeTier"
    "InstanceType" = "ARM-A1-Flex"
    "Managed"      = "Terraform"
  }
  
  lifecycle {
    ignore_changes = [
      source_details[0].source_id,
      defined_tags,
    ]
  }
}

# ============================================================================
# PER-INSTANCE IPv6: Reserve an IPv6 for each instance VNIC
# Docs: "Creates an IPv6 for the specified VNIC." and "lifetime: Ephemeral | Reserved" (OCI Terraform provider)
# ============================================================================

data "oci_core_vnic_attachments" "amd_vnics" {
  count = local.amd_micro_instance_count
  compartment_id = local.compartment_id
  instance_id    = oci_core_instance.amd[count.index].id
}

resource "oci_core_ipv6" "amd_ipv6" {
  count = local.amd_micro_instance_count
  vnic_id = data.oci_core_vnic_attachments.amd_vnics[count.index].vnic_attachments[0].vnic_id
  lifetime = "RESERVED"
  subnet_id = oci_core_subnet.main.id
  route_table_id = oci_core_default_route_table.main.id
  display_name = "amd-${local.amd_micro_hostnames[count.index]}-ipv6"
  freeform_tags = {
    "Purpose" = "AlwaysFreeTier"
    "Managed" = "Terraform"
  }
}

data "oci_core_vnic_attachments" "arm_vnics" {
  count = local.arm_flex_instance_count
  compartment_id = local.compartment_id
  instance_id    = oci_core_instance.arm[count.index].id
}

resource "oci_core_ipv6" "arm_ipv6" {
  count = local.arm_flex_instance_count
  vnic_id = data.oci_core_vnic_attachments.arm_vnics[count.index].vnic_attachments[0].vnic_id
  lifetime = "RESERVED"
  subnet_id = oci_core_subnet.main.id
  route_table_id = oci_core_default_route_table.main.id
  display_name = "arm-${local.arm_flex_hostnames[count.index]}-ipv6"
  freeform_tags = {
    "Purpose" = "AlwaysFreeTier"
    "Managed" = "Terraform"
  }
}

# ============================================================================
# OUTPUTS
# ============================================================================

output "amd_instances" {
  description = "AMD instance information"
  value = local.amd_micro_instance_count > 0 ? {
    for i in range(local.amd_micro_instance_count) : local.amd_micro_hostnames[i] => {
      id         = oci_core_instance.amd[i].id
      public_ip  = oci_core_instance.amd[i].public_ip
      private_ip = oci_core_instance.amd[i].private_ip
      ipv6       = oci_core_ipv6.amd_ipv6[i].ip_address
      state      = oci_core_instance.amd[i].state
      ssh        = "ssh -i ./ssh_keys/id_rsa ubuntu@${oci_core_instance.amd[i].public_ip}"
    }
  } : {}
}

output "arm_instances" {
  description = "ARM instance information"
  value = local.arm_flex_instance_count > 0 ? {
    for i in range(local.arm_flex_instance_count) : local.arm_flex_hostnames[i] => {
      id         = oci_core_instance.arm[i].id
      public_ip  = oci_core_instance.arm[i].public_ip
      private_ip = oci_core_instance.arm[i].private_ip
      ipv6       = oci_core_ipv6.arm_ipv6[i].ip_address
      state      = oci_core_instance.arm[i].state
      ocpus      = local.arm_flex_ocpus_per_instance[i]
      memory_gb  = local.arm_flex_memory_per_instance[i]
      ssh        = "ssh -i ./ssh_keys/id_rsa ubuntu@${oci_core_instance.arm[i].public_ip}"
    }
  } : {}
}

output "network" {
  description = "Network information"
  value = {
    vcn_id     = oci_core_vcn.main.id
    vcn_cidr   = oci_core_vcn.main.cidr_blocks[0]
    subnet_id  = oci_core_subnet.main.id
    subnet_cidr = oci_core_subnet.main.cidr_block
  }
}

output "summary" {
  description = "Infrastructure summary"
  value = {
    region          = local.region
    total_amd       = local.amd_micro_instance_count
    total_arm       = local.arm_flex_instance_count
    total_storage   = local.total_storage
    free_tier_limit = 200
  }
}
EOFMAIN
    
    print_success "main.tf created"
}

create_terraform_block_volumes() {
    print_status "Creating block_volumes.tf..."
    
    [ -f "block_volumes.tf" ] && cp block_volumes.tf "block_volumes.tf.bak.$(date +%Y%m%d_%H%M%S)"
    
    cat > block_volumes.tf << 'EOF'
# Block Volume Resources (Optional)
# Block volumes provide additional storage beyond boot volumes

# AMD Block Volumes
resource "oci_core_volume" "amd_block" {
  count = local.amd_block_volume_size_gb > 0 ? local.amd_micro_instance_count : 0
  
  compartment_id      = local.compartment_id
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  display_name        = "${local.amd_micro_hostnames[count.index]}-block"
  size_in_gbs         = local.amd_block_volume_size_gb
  
  freeform_tags = {
    "Purpose" = "AlwaysFreeTier"
    "Type"    = "BlockVolume"
    "Managed" = "Terraform"
  }
}

resource "oci_core_volume_attachment" "amd_block" {
  count = local.amd_block_volume_size_gb > 0 ? local.amd_micro_instance_count : 0
  
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.amd[count.index].id
  volume_id       = oci_core_volume.amd_block[count.index].id
}

# ARM Block Volumes
resource "oci_core_volume" "arm_block" {
  count = local.arm_flex_instance_count > 0 ? length([for s in local.arm_block_volume_sizes : s if s > 0]) : 0
  
  compartment_id      = local.compartment_id
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  display_name        = "${local.arm_flex_hostnames[count.index]}-block"
  size_in_gbs         = [for s in local.arm_block_volume_sizes : s if s > 0][count.index]
  
  freeform_tags = {
    "Purpose" = "AlwaysFreeTier"
    "Type"    = "BlockVolume"
    "Managed" = "Terraform"
  }
}

resource "oci_core_volume_attachment" "arm_block" {
  count = local.arm_flex_instance_count > 0 ? length([for s in local.arm_block_volume_sizes : s if s > 0]) : 0
  
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.arm[count.index].id
  volume_id       = oci_core_volume.arm_block[count.index].id
}
EOF
    
    print_success "block_volumes.tf created"
}

create_cloud_init() {
    print_status "Creating cloud-init.yaml..."
    
    [ -f "cloud-init.yaml" ] && cp cloud-init.yaml "cloud-init.yaml.bak.$(date +%Y%m%d_%H%M%S)"
    
    cat > cloud-init.yaml << 'EOF'
#cloud-config
hostname: ${hostname}
fqdn: ${hostname}.local
manage_etc_hosts: true

package_update: true
package_upgrade: true

packages:
  - curl
  - wget
  - git
  - htop
  - vim
  - unzip
  - jq
  - tmux
  - net-tools
  - iotop
  - ncdu

runcmd:
  - echo "Instance ${hostname} initialized at $(date)" >> /var/log/cloud-init-complete.log
  - systemctl enable --now fail2ban || true

# Basic security hardening
write_files:
  - path: /etc/ssh/sshd_config.d/hardening.conf
    content: |
      PermitRootLogin no
      PasswordAuthentication no
      MaxAuthTries 3
      ClientAliveInterval 300
      ClientAliveCountMax 2

timezone: UTC
ssh_pwauth: false

final_message: "Instance ${hostname} ready after $UPTIME seconds"
EOF
    
    print_success "cloud-init.yaml created"
}

# ============================================================================
# TERRAFORM IMPORT AND STATE MANAGEMENT
# ============================================================================

import_existing_resources() {
    print_header "IMPORTING EXISTING RESOURCES"
    
    if [ ${#EXISTING_VCNS[@]} -eq 0 ] && [ ${#EXISTING_AMD_INSTANCES[@]} -eq 0 ] && [ ${#EXISTING_ARM_INSTANCES[@]} -eq 0 ]; then
        print_status "No existing resources to import"
        return 0
    fi
    
    # Initialize Terraform first
    print_status "Initializing Terraform..."
    if ! retry_with_backoff "terraform init -input=false" >/dev/null 2>&1; then
        print_error "Terraform init failed after retries"
        return 1
    fi
    
    local imported=0
    local failed=0
    
    # Import VCN
    if [ ${#EXISTING_VCNS[@]} -gt 0 ]; then
        local first_vcn_id
        first_vcn_id=$(echo "${!EXISTING_VCNS[@]}" | tr ' ' '\n' | head -1)
        
        if [ -n "$first_vcn_id" ]; then
            local vcn_name
            vcn_name=$(echo "${EXISTING_VCNS[$first_vcn_id]}" | cut -d'|' -f1)
            print_status "Importing VCN: $vcn_name"
            
            if terraform state show oci_core_vcn.main >/dev/null 2>&1; then
                print_status "  Already in state"
            elif run_cmd_with_retries_and_check "terraform import oci_core_vcn.main \"$first_vcn_id\"" >/dev/null 2>&1; then
                print_success "  Imported successfully"
                imported=$((imported + 1))
                
                # Import related networking resources
                import_vcn_components "$first_vcn_id"
            else
                print_warning "  Failed to import (see logs above)"
                failed=$((failed + 1))
            fi
        fi
    fi
    
    # Import AMD instances
    local amd_index=0
    for instance_id in "${!EXISTING_AMD_INSTANCES[@]}"; do
        local instance_name
        instance_name=$(echo "${EXISTING_AMD_INSTANCES[$instance_id]}" | cut -d'|' -f1)
        print_status "Importing AMD instance: $instance_name"
        
        if terraform state show "oci_core_instance.amd[$amd_index]" >/dev/null 2>&1; then
            print_status "  Already in state"
        elif run_cmd_with_retries_and_check "terraform import \"oci_core_instance.amd[$amd_index]\" \"$instance_id\"" >/dev/null 2>&1; then
            print_success "  Imported successfully"
            imported=$((imported + 1))
        else
            print_warning "  Failed to import (see logs above)"
            failed=$((failed + 1))
        fi
        
        amd_index=$((amd_index + 1))
        [ "$amd_index" -ge "$amd_micro_instance_count" ] && break
    done
    
    # Import ARM instances
    local arm_index=0
    for instance_id in "${!EXISTING_ARM_INSTANCES[@]}"; do
        local instance_name
        instance_name=$(echo "${EXISTING_ARM_INSTANCES[$instance_id]}" | cut -d'|' -f1)
        print_status "Importing ARM instance: $instance_name"
        
        if terraform state show "oci_core_instance.arm[$arm_index]" >/dev/null 2>&1; then
            print_status "  Already in state"
        elif run_cmd_with_retries_and_check "terraform import \"oci_core_instance.arm[$arm_index]\" \"$instance_id\"" >/dev/null 2>&1; then
            print_success "  Imported successfully"
            imported=$((imported + 1))
        else
            print_warning "  Failed to import (see logs above)"
            failed=$((failed + 1))
        fi
        
        arm_index=$((arm_index + 1))
        [ "$arm_index" -ge "$arm_flex_instance_count" ] && break
    done
    
    print_status ""
    print_success "Import complete: $imported imported, $failed failed"
}

import_vcn_components() {
    local vcn_id="$1"
    
    # Import Internet Gateway
    for ig_id in "${!EXISTING_INTERNET_GATEWAYS[@]}"; do
        local ig_vcn
        ig_vcn=$(echo "${EXISTING_INTERNET_GATEWAYS[$ig_id]}" | cut -d'|' -f2)
        if [ "$ig_vcn" = "$vcn_id" ]; then
            if ! terraform state show oci_core_internet_gateway.main >/dev/null 2>&1; then
                terraform import oci_core_internet_gateway.main "$ig_id" 2>/dev/null && \
                    print_status "    Imported Internet Gateway" || true
            fi
            break
        fi
    done
    
    # Import Subnet
    for subnet_id in "${!EXISTING_SUBNETS[@]}"; do
        local subnet_vcn
        subnet_vcn=$(echo "${EXISTING_SUBNETS[$subnet_id]}" | cut -d'|' -f3)
        if [ "$subnet_vcn" = "$vcn_id" ]; then
            if ! terraform state show oci_core_subnet.main >/dev/null 2>&1; then
                terraform import oci_core_subnet.main "$subnet_id" 2>/dev/null && \
                    print_status "    Imported Subnet" || true
            fi
            break
        fi
    done
    
    # Import Route Table (default)
    for rt_id in "${!EXISTING_ROUTE_TABLES[@]}"; do
        local rt_vcn rt_name
        rt_vcn=$(echo "${EXISTING_ROUTE_TABLES[$rt_id]}" | cut -d'|' -f2)
        rt_name=$(echo "${EXISTING_ROUTE_TABLES[$rt_id]}" | cut -d'|' -f1)
        if [ "$rt_vcn" = "$vcn_id" ] && [[ "$rt_name" == *"Default"* || "$rt_name" == *"default"* ]]; then
            if ! terraform state show oci_core_default_route_table.main >/dev/null 2>&1; then
                terraform import oci_core_default_route_table.main "$rt_id" 2>/dev/null && \
                    print_status "    Imported Route Table" || true
            fi
            break
        fi
    done
    
    # Import Security List (default)
    for sl_id in "${!EXISTING_SECURITY_LISTS[@]}"; do
        local sl_vcn sl_name
        sl_vcn=$(echo "${EXISTING_SECURITY_LISTS[$sl_id]}" | cut -d'|' -f2)
        sl_name=$(echo "${EXISTING_SECURITY_LISTS[$sl_id]}" | cut -d'|' -f1)
        if [ "$sl_vcn" = "$vcn_id" ] && [[ "$sl_name" == *"Default"* || "$sl_name" == *"default"* ]]; then
            if ! terraform state show oci_core_default_security_list.main >/dev/null 2>&1; then
                terraform import oci_core_default_security_list.main "$sl_id" 2>/dev/null && \
                    print_status "    Imported Security List" || true
            fi
            break
        fi
    done
}

# ============================================================================
# TERRAFORM WORKFLOW
# ============================================================================

run_terraform_workflow() {
    print_header "TERRAFORM WORKFLOW"
    
    # Step 1: Initialize
    print_status "Step 1: Initializing Terraform..."
    if ! retry_with_backoff "terraform init -input=false -upgrade" >/dev/null 2>&1; then
        print_error "Terraform init failed after retries"
        return 1
    fi
    print_success "Terraform initialized"
    
    # Step 2: Import existing resources
    if [ ${#EXISTING_VCNS[@]} -gt 0 ] || [ ${#EXISTING_AMD_INSTANCES[@]} -gt 0 ] || [ ${#EXISTING_ARM_INSTANCES[@]} -gt 0 ]; then
        print_status "Step 2: Importing existing resources..."
        import_existing_resources
    else
        print_status "Step 2: No existing resources to import"
    fi
    
    # Step 3: Validate
    print_status "Step 3: Validating configuration..."
    if ! terraform validate; then
        print_error "Terraform validation failed"
        return 1
    fi
    print_success "Configuration valid"
    
    # Step 4: Plan
    print_status "Step 4: Creating execution plan..."
    if ! terraform plan -out=tfplan -input=false; then
        print_error "Terraform plan failed"
        return 1
    fi
    print_success "Plan created successfully"
    
    # Show plan summary
    echo ""
    print_status "Plan summary:"
    terraform show -no-color tfplan | grep -E "^(Plan:|  #|will be)" | head -20 || true
    echo ""
    
    # Step 5: Apply (with confirmation)
    if [ "$AUTO_DEPLOY" = "true" ] || [ "$NON_INTERACTIVE" = "true" ]; then
        print_status "Step 5: Auto-applying plan..."
        apply_choice="Y"
    else
        echo -n -e "${BLUE}Apply this plan? [y/N]: ${NC}"
        read -r apply_choice
        apply_choice=${apply_choice:-N}
    fi
    
    if [[ "$apply_choice" =~ ^[Yy]$ ]]; then
        print_status "Applying Terraform plan..."
        if out_of_capacity_auto_apply; then
            print_success "Infrastructure deployed successfully!"
            rm -f tfplan
            
            # Show outputs
            echo ""
            print_header "DEPLOYMENT COMPLETE"
            terraform output -json 2>/dev/null | jq '.' || terraform output
        else
            print_error "Terraform apply failed"
            return 1
        fi
    else
        print_status "Plan saved as 'tfplan' - apply later with: terraform apply tfplan"
    fi
    
    return 0
}

terraform_menu() {
    while true; do
        echo ""
        print_header "TERRAFORM MANAGEMENT"
        echo "  1) Full workflow (init → import → plan → apply)"
        echo "  2) Plan only"
        echo "  3) Apply existing plan"
        echo "  4) Import existing resources"
        echo "  5) Show current state"
        echo "  6) Destroy infrastructure"
        echo "  7) Reconfigure"
        echo "  8) Exit"
        echo ""
        
        if [ "$AUTO_DEPLOY" = "true" ] || [ "$NON_INTERACTIVE" = "true" ]; then
            choice=1
            print_status "Auto mode: Running full workflow"
        else
            echo -n -e "${BLUE}Choose option [1]: ${NC}"
            read -r choice
            choice=${choice:-1}
        fi
        
        case $choice in
            1)
                run_terraform_workflow
                [ "$AUTO_DEPLOY" = "true" ] && return 0
                ;;
            2)
                terraform init -input=false && terraform plan
                ;;
            3)
                if [ -f "tfplan" ]; then
                    terraform apply tfplan
                else
                    print_error "No plan file found"
                fi
                ;;
            4)
                import_existing_resources
                ;;
            5)
                if terraform state list 2>/dev/null && terraform output 2>/dev/null; then
                    :
                else
                    print_status "No state found"
                fi
                ;;
            6)
                if confirm_action "DESTROY all infrastructure?" "N"; then
                    terraform destroy
                fi
                ;;
            7)
                return 1  # Signal to reconfigure
                ;;
            8)
                return 0
                ;;
            *)
                print_error "Invalid choice"
                ;;
        esac
        
        if [ "$NON_INTERACTIVE" = "true" ]; then
            return 0
        fi
        
        echo ""
        echo -n -e "${BLUE}Press Enter to continue...${NC}"
        read -r
    done
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    print_header "OCI TERRAFORM SETUP - IDEMPOTENT EDITION"
    print_status "This script safely manages Oracle Cloud Free Tier resources"
    print_status "Safe to run multiple times - will detect and reuse existing resources"
    echo ""
    
    # Phase 1: Prerequisites
    install_prerequisites
    install_terraform
    install_oci_cli
    
    # Activate virtual environment if it exists
    # shellcheck disable=SC1091
    [ -f ".venv/bin/activate" ] && source .venv/bin/activate
    
    # Phase 2: Authentication
    setup_oci_config
    
    # Phase 3: Fetch OCI information
    fetch_oci_config_values
    fetch_availability_domains
    fetch_ubuntu_images
    generate_ssh_keys
    
    # Phase 4: Resource inventory (CRITICAL for idempotency)
    inventory_all_resources
    
    # Phase 5: Configuration
    if [ "$SKIP_CONFIG" != "true" ]; then
        prompt_configuration
    else
        load_existing_config || configure_from_existing_instances
    fi
    
    # Phase 6: Generate Terraform files
    create_terraform_files
    
    # Phase 7: Terraform management
    while true; do
        if terraform_menu; then
            break
        fi

        # Reconfigure requested
        prompt_configuration
        create_terraform_files
    done
    
    print_header "SETUP COMPLETE"
    print_success "Oracle Cloud Free Tier infrastructure managed successfully"
    echo ""
    print_status "Files created/updated:"
    print_status "  • provider.tf - OCI provider configuration"
    print_status "  • variables.tf - Instance configuration"
    print_status "  • main.tf - Infrastructure resources"
    print_status "  • data_sources.tf - OCI data sources"
    print_status "  • block_volumes.tf - Storage volumes"
    print_status "  • cloud-init.yaml - Instance initialization"
    echo ""
    print_status "To manage your infrastructure:"
    print_status "  terraform plan    - Preview changes"
    print_status "  terraform apply   - Apply changes"
    print_status "  terraform destroy - Remove all resources"
}

# Execute
main "$@"

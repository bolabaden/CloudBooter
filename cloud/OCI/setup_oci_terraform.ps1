# Oracle Cloud Infrastructure (OCI) Terraform Setup Script
# Idempotent, comprehensive implementation for Always Free Tier management
#
# Usage:
#   Interactive mode:        .\setup_oci_terraform.ps1
#   Non-interactive mode:    $env:NON_INTERACTIVE='true'; $env:AUTO_USE_EXISTING='true'; $env:AUTO_DEPLOY='true'; .\setup_oci_terraform.ps1
#   Use existing config:     $env:AUTO_USE_EXISTING='true'; .\setup_oci_terraform.ps1
#   Auto deploy only:        $env:AUTO_DEPLOY='true'; .\setup_oci_terraform.ps1
#   Skip to deploy:          $env:SKIP_CONFIG='true'; .\setup_oci_terraform.ps1
#
# Key features:
#   - Completely idempotent: safe to run multiple times
#   - Comprehensive resource detection before any deployment
#   - Strict Free Tier limit validation
#   - Robust existing resource import

$ErrorActionPreference = 'Stop'

# ============================================================================
# CONFIGURATION AND CONSTANTS
# ============================================================================

# Non-interactive mode support
$NON_INTERACTIVE = if ($env:NON_INTERACTIVE) { $env:NON_INTERACTIVE } else { 'false' }
$AUTO_USE_EXISTING = if ($env:AUTO_USE_EXISTING) { $env:AUTO_USE_EXISTING } else { 'false' }
$AUTO_DEPLOY = if ($env:AUTO_DEPLOY) { $env:AUTO_DEPLOY } else { 'false' }
$SKIP_CONFIG = if ($env:SKIP_CONFIG) { $env:SKIP_CONFIG } else { 'false' }
$DEBUG = if ($env:DEBUG) { $env:DEBUG } else { 'false' }
$FORCE_REAUTH = if ($env:FORCE_REAUTH) { $env:FORCE_REAUTH } else { 'false' }

# Optional Terraform remote backend (set to 'oci' to use OCI Object Storage S3-compatible backend)
$TF_BACKEND = if ($env:TF_BACKEND) { $env:TF_BACKEND } else { 'local' }                # values: local | oci
$TF_BACKEND_BUCKET = if ($env:TF_BACKEND_BUCKET) { $env:TF_BACKEND_BUCKET } else { '' }   # Bucket name for terraform state
$TF_BACKEND_CREATE_BUCKET = if ($env:TF_BACKEND_CREATE_BUCKET) { $env:TF_BACKEND_CREATE_BUCKET } else { 'false' }
$TF_BACKEND_REGION = if ($env:TF_BACKEND_REGION) { $env:TF_BACKEND_REGION } else { '' }
$TF_BACKEND_ENDPOINT = if ($env:TF_BACKEND_ENDPOINT) { $env:TF_BACKEND_ENDPOINT } else { '' }
$TF_BACKEND_STATE_KEY = if ($env:TF_BACKEND_STATE_KEY) { $env:TF_BACKEND_STATE_KEY } else { 'terraform.tfstate' }
$TF_BACKEND_ACCESS_KEY = if ($env:TF_BACKEND_ACCESS_KEY) { $env:TF_BACKEND_ACCESS_KEY } else { '' }   # (optional) S3 access key
$TF_BACKEND_SECRET_KEY = if ($env:TF_BACKEND_SECRET_KEY) { $env:TF_BACKEND_SECRET_KEY } else { '' }   # (optional) S3 secret key

# Retry/backoff settings for transient errors like 'Out of Capacity'
$RETRY_MAX_ATTEMPTS = if ($env:RETRY_MAX_ATTEMPTS) { [int]$env:RETRY_MAX_ATTEMPTS } else { 8 }
$RETRY_BASE_DELAY = if ($env:RETRY_BASE_DELAY) { [int]$env:RETRY_BASE_DELAY } else { 15 }  # seconds

# Timeout for OCI CLI calls (seconds). Set lower if your environment can be slow.
$OCI_CMD_TIMEOUT = if ($env:OCI_CMD_TIMEOUT) { [int]$env:OCI_CMD_TIMEOUT } else { 20 }
# If no coreutils timeout is available, the script attempts to still run but may block on slow OCI CLI calls.

# OCI CLI configuration
$OCI_CONFIG_FILE = if ($env:OCI_CONFIG_FILE) { $env:OCI_CONFIG_FILE } else { "$env:USERPROFILE\.oci\config" }
$OCI_PROFILE = if ($env:OCI_PROFILE) { $env:OCI_PROFILE } else { 'DEFAULT' }
$OCI_AUTH_REGION = if ($env:OCI_AUTH_REGION) { $env:OCI_AUTH_REGION } else { '' }
$OCI_CLI_CONNECTION_TIMEOUT = if ($env:OCI_CLI_CONNECTION_TIMEOUT) { [int]$env:OCI_CLI_CONNECTION_TIMEOUT } else { 10 }
$OCI_CLI_READ_TIMEOUT = if ($env:OCI_CLI_READ_TIMEOUT) { [int]$env:OCI_CLI_READ_TIMEOUT } else { 60 }
$OCI_CLI_MAX_RETRIES = if ($env:OCI_CLI_MAX_RETRIES) { [int]$env:OCI_CLI_MAX_RETRIES } else { 3 }

# Oracle Free Tier Limits (as of 2025)
$FREE_TIER_MAX_AMD_INSTANCES = 2
$FREE_TIER_AMD_SHAPE = 'VM.Standard.E2.1.Micro'
$FREE_TIER_MAX_ARM_OCPUS = 4
$FREE_TIER_MAX_ARM_MEMORY_GB = 24
$FREE_TIER_ARM_SHAPE = 'VM.Standard.A1.Flex'
$FREE_TIER_MAX_STORAGE_GB = 200
$FREE_TIER_MIN_BOOT_VOLUME_GB = 47
$FREE_TIER_MAX_ARM_INSTANCES = 4
$FREE_TIER_MAX_VCNS = 2

# Colors for output
$RED = [char]27 + '[0;31m'
$GREEN = [char]27 + '[0;32m'
$YELLOW = [char]27 + '[1;33m'
$BLUE = [char]27 + '[0;34m'
$CYAN = [char]27 + '[0;36m'
$MAGENTA = [char]27 + '[0;35m'
$BOLD = [char]27 + '[1m'
$NC = [char]27 + '[0m' # No Color

# Global state tracking
$tenancy_ocid = ''
$user_ocid = ''
$region = ''
$fingerprint = ''
$availability_domain = ''
$ubuntu_image_ocid = ''
$ubuntu_arm_flex_image_ocid = ''
$ssh_public_key = ''
$auth_method = 'security_token'

# Existing resource tracking (populated by inventory functions)
$EXISTING_VCNS = @{}
$EXISTING_SUBNETS = @{}
$EXISTING_INTERNET_GATEWAYS = @{}
$EXISTING_ROUTE_TABLES = @{}
$EXISTING_SECURITY_LISTS = @{}
$EXISTING_AMD_INSTANCES = @{}
$EXISTING_ARM_INSTANCES = @{}
$EXISTING_BOOT_VOLUMES = @{}
$EXISTING_BLOCK_VOLUMES = @{}

# Instance configuration
$amd_micro_instance_count = 0
$amd_micro_boot_volume_size_gb = 50
$arm_flex_instance_count = 0
$arm_flex_ocpus_per_instance = ''
$arm_flex_memory_per_instance = ''
$arm_flex_boot_volume_size_gb = ''
$arm_flex_block_volumes = @()
$amd_micro_hostnames = @()
$arm_flex_hostnames = @()

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

function print_status {
    param([string]$message)
    Write-Host "$($BLUE)[INFO]$($NC) $message"
}

function print_success {
    param([string]$message)
    Write-Host "$($GREEN)[SUCCESS]$($NC) $message"
}

function print_warning {
    param([string]$message)
    Write-Host "$($YELLOW)[WARNING]$($NC) $message"
}

function print_error {
    param([string]$message)
    Write-Host "$($RED)[ERROR]$($NC) $message"
}

function print_debug {
    param([string]$message)
    if ($DEBUG -eq 'true') {
        Write-Host "$($CYAN)[DEBUG]$($NC) $message"
    }
}

function prompt_with_default {
    param([string]$prompt, [string]$default_value)
    $userInput = Read-Host "$($BLUE)$prompt [$default_value]: $($NC)"
    if ([string]::IsNullOrEmpty($userInput)) {
        $default_value
    } else {
        $userInput
    }
}

function prompt_int_range {
    param([string]$prompt, [string]$default_value, [int]$min_value, [int]$max_value)
    while ($true) {
        $value = prompt_with_default $prompt $default_value
        $value = $value -replace '\r', '' -replace '^\s+', '' -replace '\s+$', ''
        if ($value -match '^\d+$' -and [int]$value -ge $min_value -and [int]$value -le $max_value) {
            return [int]$value
        }
        print_error "Please enter a number between $min_value and $max_value (received: '$value')"
        continue
    }
}

function print_header {
    param([string]$title)
    Write-Host ""
    Write-Host "$($BOLD)$($MAGENTA)════════════════════════════════════════════════════════════════$($NC)"
    Write-Host "$($BOLD)$($MAGENTA)  $title$($NC)"
    Write-Host "$($BOLD)$($MAGENTA)════════════════════════════════════════════════════════════════$($NC)"
    Write-Host ""
}

function print_subheader {
    param([string]$title)
    Write-Host ""
    Write-Host "$($BOLD)$($CYAN)── $title ──$($NC)"
    Write-Host ""
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

function command_exists {
    param([string]$cmd)
    try {
        Get-Command $cmd -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function is_wsl {
    if ($env:WSL_DISTRO_NAME) {
        return $true
    }
    return $false
}

function default_region_for_host {
    $tz = try { Get-TimeZone | Select-Object -ExpandProperty Id } catch { '' }
    switch -Regex ($tz) {
        '.*Chicago.*|.*Central.*|.*Winnipeg.*|.*Mexico_City.*' { 'us-chicago-1' }
        '.*New_York.*|.*Toronto.*|.*Montreal.*|.*Eastern.*' { 'us-ashburn-1' }
        '.*Los_Angeles.*|.*Vancouver.*|.*Pacific.*' { 'us-sanjose-1' }
        '.*Phoenix.*|.*Denver.*|.*Mountain.*' { 'us-phoenix-1' }
        '.*London.*|.*Dublin.*' { 'uk-london-1' }
        '.*Paris.*|.*Berlin.*|.*Rome.*|.*Madrid.*|.*Amsterdam.*|.*Stockholm.*|.*Zurich.*|.*Europe.*' { 'eu-frankfurt-1' }
        '.*Tokyo.*' { 'ap-tokyo-1' }
        '.*Seoul.*' { 'ap-seoul-1' }
        '.*Singapore.*' { 'ap-singapore-1' }
        '.*Sydney.*|.*Melbourne.*' { 'ap-sydney-1' }
        default { 'us-chicago-1' }
    }
}

function open_url_best_effort {
    param([string]$url)
    if ([string]::IsNullOrEmpty($url)) {
        return $false
    }

    if (is_wsl -and (command_exists 'powershell.exe')) {
        try {
            & powershell.exe -NoProfile -Command "Start-Process '$url'" 2>$null
            return $true
        }
        catch {
            return $false
        }
    }

    try {
        Start-Process $url
        return $true
    }
    catch {
        return $false
    }
}

function read_oci_config_value {
    param([string]$key, [string]$file = $OCI_CONFIG_FILE, [string]$prof = $OCI_PROFILE)
    if (!(Test-Path $file)) {
        return $null
    }
    $content = Get-Content $file -Raw
    $section = ""
    foreach ($line in ($content -split "`n")) {
        if ($line -match '^\s*\[') {
            $section = $line
        }
        elseif ($section -eq "[$prof]") {
            $line = $line -replace '^\s+', ''
            if ($line -match "^$key\s*=") {
                $line = $line -replace "^$key\s*=", ''
                $line = $line -replace '^\s+', '' -replace '\s+$', ''
                return $line
            }
        }
    }
    return $null
}

function is_instance_principal_available {
    if (!(command_exists 'curl')) {
        return $false
    }
    try {
        $result = Invoke-WebRequest -Uri 'http://169.254.169.254/opc/v2/' -TimeoutSec 1 -Method Head
        return $true
    }
    catch {
        return $false
    }
}

function validate_existing_oci_config {
    if (!(Test-Path $OCI_CONFIG_FILE)) {
        print_warning "OCI config not found at $OCI_CONFIG_FILE"
        return $false
    }

    $cfg_auth = read_oci_config_value 'auth'
    $key_file = read_oci_config_value 'key_file'
    $token_file = read_oci_config_value 'security_token_file'
    $pass_phrase = read_oci_config_value 'pass_phrase'

    if ($cfg_auth) {
        $script:auth_method = $cfg_auth
    }
    elseif ($token_file) {
        $script:auth_method = 'security_token'
    }
    elseif ($key_file) {
        $script:auth_method = 'api_key'
    }

    switch ($script:auth_method) {
        'security_token' {
            if (!$token_file -or !(Test-Path $token_file)) {
                print_warning "security_token auth selected but security_token_file is missing"
                return $false
            }
        }
        'api_key' {
            if (!$key_file -or !(Test-Path $key_file)) {
                print_warning "api_key auth selected but key_file is missing"
                return $false
            }
            $content = Get-Content $key_file -Raw
            if ($content -match 'ENCRYPTED') {
                if (!$env:OCI_CLI_PASSPHRASE -and !$pass_phrase) {
                    print_warning "Private key is encrypted but no passphrase provided (set OCI_CLI_PASSPHRASE or pass_phrase in config)"
                    return $false
                }
            }
        }
        { $_ -in @('instance_principal', 'resource_principal', 'oke_workload_identity', 'instance_obo_user') } {
            if (!(is_instance_principal_available)) {
                print_warning "Instance principal auth selected but OCI metadata service is unreachable"
                return $false
            }
        }
        '' {
            print_warning "Unable to determine auth method from config"
            return $false
        }
        default {
            print_warning "Unsupported auth method '$script:auth_method' in config"
            return $false
        }
    }

    return $true
}

# Run OCI command with proper authentication handling
function oci_cmd {
    $cmd = $args -join ' '
    $result = ''
    $exit_code = 0
    $base_args = "--config-file `"$OCI_CONFIG_FILE`" --profile `"$OCI_PROFILE`" --connection-timeout $OCI_CLI_CONNECTION_TIMEOUT --read-timeout $OCI_CLI_READ_TIMEOUT --max-retries $OCI_CLI_MAX_RETRIES"
    if ($env:OCI_CLI_AUTH) {
        $base_args += " --auth $env:OCI_CLI_AUTH"
    }
    elseif ($script:auth_method) {
        $base_args += " --auth $script:auth_method"
    }

    # Run command with proper error handling
    try {
        $full_cmd = "oci $base_args $cmd"
        $result = & cmd /c $full_cmd 2>&1
        $exit_code = $LASTEXITCODE
        if ($null -eq $exit_code) { $exit_code = 0 }
    }
    catch {
        $result = $_.Exception.Message
        $exit_code = 1
    }

    if ($exit_code -eq 0) {
        return $result
    }
    if ($exit_code -eq 124 -or $exit_code -eq -1) {
        print_warning "OCI CLI call timed out after ${OCI_CMD_TIMEOUT}s"
    }

    throw "OCI command failed: $result"
}

# Safe JSON parsing with jq
function safe_jq {
    param([string]$json, [string]$query, [string]$default = '')
    if ([string]::IsNullOrEmpty($json) -or $json -eq 'null') {
        return $default
    }
    try {
        $result = $json | jq -r $query 2>$null
        if ($result -eq 'null' -or [string]::IsNullOrEmpty($result)) {
            return $default
        }
        return $result
    }
    catch {
        return $default
    }
}

# Run a command with retry/backoff, detect Out-of-Capacity signals
function retry_with_backoff {
    $cmd = $args
    $attempt = 1
    $rc = 1
    $out = ''

    while ($attempt -le $RETRY_MAX_ATTEMPTS) {
        print_status "Attempt $attempt/${RETRY_MAX_ATTEMPTS}: $cmd"
        try {
            $out = & cmd /c $cmd 2>&1
            $rc = $LASTEXITCODE
            if ($null -eq $rc) { $rc = 0 }
        }
        catch {
            $out = $_.Exception.Message
            $rc = 1
        }

        if ($rc -eq 0) {
            Write-Host $out
            return 0
        }

        # Detect Out-of-Capacity patterns
        if ($out -match '(?i)out of capacity|out of host capacity|OutOfCapacity|OutOfHostCapacity') {
            print_warning "Detected 'Out of Capacity' condition (attempt $attempt)."
        }
        else {
            print_warning "Command failed (exit $rc)."
        }

        $sleep_time = [int]($RETRY_BASE_DELAY * [math]::Pow(2, ($attempt - 1)))
        print_status "Retrying in ${sleep_time}s..."
        Start-Sleep -Seconds $sleep_time
        $attempt++
    }

    print_error "Command failed after $RETRY_MAX_ATTEMPTS attempts"
    Write-Host $out
    return $rc
}

# A simpler wrapper that returns true/false and sets OUT_OF_CAPACITY_DETECTED=1 when detected
function run_cmd_with_retries_and_check {
    $cmd = $args
    $script:OUT_OF_CAPACITY_DETECTED = 0

    try {
        $out = retry_with_backoff $cmd
        if ($out -match '(?i)out of capacity|out of host capacity|OutOfCapacity|OutOfHostCapacity') {
            $script:OUT_OF_CAPACITY_DETECTED = 1
        }
        return $true
    }
    catch {
        return $false
    }
}

# Automatically re-run terraform apply until success on 'Out of Capacity', with backoff
function out_of_capacity_auto_apply {
    print_status "Auto-retrying terraform apply until success or max attempts ($RETRY_MAX_ATTEMPTS)..."
    $attempt = 1
    $rc = 1
    $out = ''

    while ($attempt -le $RETRY_MAX_ATTEMPTS) {
        print_status "Apply attempt $attempt/$RETRY_MAX_ATTEMPTS"
        try {
            & terraform apply -input=false tfplan 2>&1 | Tee-Object -Variable out | Out-Null
            $rc = $LASTEXITCODE
            if ($null -eq $rc) { $rc = 0 }
        }
        catch {
            $out = $_.Exception.Message
            $rc = 1
        }

        if ($rc -eq 0) {
            print_success "terraform apply succeeded"
            return $true
        }

        if ($out -match '(?i)out of capacity|out of host capacity|OutOfCapacity|OutOfHostCapacity') {
            print_warning "Apply failed with 'Out of Capacity' - will retry"
        }
        else {
            print_error "terraform apply failed with non-retryable error"
            Write-Host $out
            return $false
        }

        $sleep_time = [int]($RETRY_BASE_DELAY * [math]::Pow(2, ($attempt - 1)))
        print_status "Waiting ${sleep_time}s before retrying..."
        Start-Sleep -Seconds $sleep_time
        $attempt++
    }

    print_error "terraform apply did not succeed after $RETRY_MAX_ATTEMPTS attempts"
    Write-Host $out
    return $false
}

# Create an OCI Object Storage bucket (S3-compatible) for remote TF state if requested
function create_s3_backend_bucket {
    param([string]$bucket_name)
    if ([string]::IsNullOrEmpty($bucket_name)) {
        print_error "Bucket name is empty"
        throw "Bucket name empty"
    }

    print_status "Creating/checking OCI Object Storage bucket: $bucket_name"

    try {
        $ns = oci_cmd "os ns get --query 'data' --raw-output"
    }
    catch {
        print_error "Failed to determine Object Storage namespace"
        throw "Failed to get namespace"
    }
    if ([string]::IsNullOrEmpty($ns)) {
        print_error "Failed to determine Object Storage namespace"
        throw "Failed to get namespace"
    }

    # Check if bucket exists
    try {
        oci_cmd "os bucket get --namespace-name $ns --bucket-name $bucket_name" | Out-Null
        print_status "Bucket $bucket_name already exists in namespace $ns"
        return
    }
    catch {
        # Bucket doesn't exist, create it
    }

    try {
        oci_cmd "os bucket create --namespace-name $ns --compartment-id $script:tenancy_ocid --name $bucket_name --is-versioning-enabled true" | Out-Null
        print_success "Created bucket $bucket_name in namespace $ns"
    }
    catch {
        print_error "Failed to create bucket $bucket_name"
        throw "Failed to create bucket"
    }
}

# Configure terraform backend if TF_BACKEND=oci
function configure_terraform_backend {
    if ($TF_BACKEND -ne 'oci') {
        return
    }

    if ([string]::IsNullOrEmpty($TF_BACKEND_BUCKET)) {
        print_error "TF_BACKEND is 'oci' but TF_BACKEND_BUCKET is not set"
        throw "TF_BACKEND_BUCKET not set"
    }

    $TF_BACKEND_REGION = if ($TF_BACKEND_REGION) { $TF_BACKEND_REGION } else { $script:region }
    $TF_BACKEND_ENDPOINT = if ($TF_BACKEND_ENDPOINT) { $TF_BACKEND_ENDPOINT } else { "https://objectstorage.${TF_BACKEND_REGION}.oraclecloud.com" }

    if ($TF_BACKEND_CREATE_BUCKET -eq 'true') {
        create_s3_backend_bucket $TF_BACKEND_BUCKET
    }

    # Write backend override (sensitive; keep out of VCS)
    print_status "Writing backend.tf (do not commit -- contains sensitive values)"
    $backendContent = @"
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
"@
    if (Test-Path 'backend.tf') {
        Copy-Item 'backend.tf' "backend.tf.bak.$((Get-Date).ToString('yyyyMMdd_HHmmss'))"
    }
    Set-Content -Path 'backend.tf' -Value $backendContent
    print_warning "backend.tf written - ensure this file is in .gitignore (contains credentials if provided)"
}

# Confirm action with user
function confirm_action {
    param([string]$prompt, [string]$default = 'N')
    if ($NON_INTERACTIVE -eq 'true') {
        return ($default -eq 'Y')
    }
    $yn_prompt = if ($default -eq 'Y') { '[Y/n]' } else { '[y/N]' }
    $response = Read-Host "$($BLUE)$prompt $yn_prompt`: $($NC)"
    $response = if ([string]::IsNullOrEmpty($response)) { $default } else { $response }
    return ($response -match '^[Yy]$')
}

# ============================================================================
# INSTALLATION FUNCTIONS
# ============================================================================

function install_prerequisites {
    print_subheader "Installing Prerequisites"
    
    $packages_to_install = @()
    
    # Check for required commands
    if (!(command_exists 'jq')) {
        $packages_to_install += 'jq'
    }
    if (!(command_exists 'curl')) {
        $packages_to_install += 'curl'
    }
    if (!(command_exists 'unzip')) {
        $packages_to_install += 'unzip'
    }
    
    if ($packages_to_install.Count -gt 0) {
        print_status "Installing required packages: $($packages_to_install -join ', ')"
        # Assuming Chocolatey or similar, but for simplicity, assume they are installed or skip
        print_warning "Please install the following packages manually: $($packages_to_install -join ', ')"
    }
    
    # Verify all required commands exist
    $required_commands = @('jq', 'openssl', 'ssh-keygen', 'curl')
    foreach ($cmd in $required_commands) {
        if (!(command_exists $cmd)) {
            print_error "Required command '$cmd' is not available"
            throw "Missing command $cmd"
        }
    }
    
    print_success "All prerequisites installed"
}

function install_oci_cli {
    print_subheader "OCI CLI Setup"
    
    # Check if OCI CLI is already installed and working
    if (command_exists 'oci') {
        $version = try { & oci --version 2>$null | Select-Object -First 1 } catch { 'unknown' }
        print_status "OCI CLI already installed: $version"
        return
    }
    
    print_status "Installing OCI CLI..."
    
    # Check if Python is installed
    if (!(command_exists 'python3')) {
        print_status "Installing Python 3..."
        # Assume Python is installed, or use winget/choco
        print_warning "Please install Python 3 manually"
    }
    
    # Create virtual environment for OCI CLI
    $venv_dir = '.venv'
    if (!(Test-Path $venv_dir)) {
        print_status "Creating Python virtual environment..."
        & python3 -m venv $venv_dir
    }
    
    # Activate and install OCI CLI
    # In PowerShell, activate venv
    & "$venv_dir\Scripts\Activate.ps1"
    
    print_status "Installing OCI CLI in virtual environment..."
    & pip install --upgrade pip --quiet
    & pip install oci-cli --quiet
    
    # Add activation to profile if not already present
    $activation_line = "& '$PWD\$venv_dir\Scripts\Activate.ps1'"
    $profileContent = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
    if ($profileContent -notmatch [regex]::Escape($activation_line)) {
        Add-Content $PROFILE "`n# OCI CLI virtual environment`n$activation_line"
    }
    
    print_success "OCI CLI installed successfully"
}

function install_terraform {
    print_subheader "Terraform Setup"
    
    if (command_exists 'terraform') {
        $version = try { & terraform version -json 2>$null | ConvertFrom-Json | Select-Object -ExpandProperty terraform_version } catch { & terraform version | Select-Object -First 1 | ForEach-Object { ($_ -split ' ')[1] -replace '^v' } }
        print_status "Terraform already installed: version $version"
        return
    }
    
    print_status "Installing Terraform..."
    
    # Try choco first
    if (command_exists 'choco') {
        try {
            & choco install terraform --yes
            print_success "Terraform installed via choco"
            return
        }
        catch {
        }
    }
    
    # Manual installation
    $latest_version = try { Invoke-WebRequest -Uri 'https://api.github.com/repos/hashicorp/terraform/releases/latest' -UseBasicParsing | ConvertFrom-Json | Select-Object -ExpandProperty tag_name | ForEach-Object { $_ -replace '^v' } } catch { '1.7.0' }
    
    if ([string]::IsNullOrEmpty($latest_version) -or $latest_version -eq 'null') {
        $latest_version = '1.7.0'
        print_warning "Could not fetch latest version, using fallback: $latest_version"
    }
    
    $arch = if ([Environment]::Is64BitOperatingSystem) { 'amd64' } else { '386' }
    $os = 'windows'
    
    $tf_url = "https://releases.hashicorp.com/terraform/${latest_version}/terraform_${latest_version}_${os}_${arch}.zip"
    $temp_dir = [System.IO.Path]::GetTempPath() + [System.IO.Path]::GetRandomFileName()
    New-Item -ItemType Directory -Path $temp_dir | Out-Null
    
    print_status "Downloading Terraform $latest_version for ${os}_${arch}..."
    
    try {
        Invoke-WebRequest -Uri $tf_url -OutFile "$temp_dir\terraform.zip"
        Expand-Archive -Path "$temp_dir\terraform.zip" -DestinationPath $temp_dir
        Move-Item "$temp_dir\terraform.exe" "$env:ProgramFiles\Terraform\terraform.exe" -Force
        $env:Path += ";$env:ProgramFiles\Terraform"
        if (command_exists 'terraform') {
            print_success "Terraform installed successfully"
        }
        else {
            throw "Terraform not found after installation"
        }
    }
    catch {
        print_error "Failed to install Terraform"
        throw "Terraform installation failed"
    }
    finally {
        Remove-Item $temp_dir -Recurse -Force
    }
}

# ============================================================================
# OCI AUTHENTICATION FUNCTIONS
# ============================================================================

function detect_auth_method {
    if (Test-Path $OCI_CONFIG_FILE) {
        $cfg_auth = read_oci_config_value 'auth'
        $token_file = read_oci_config_value 'security_token_file'
        $key_file = read_oci_config_value 'key_file'

        if ($cfg_auth) {
            $script:auth_method = $cfg_auth
        }
        elseif ($token_file) {
            $script:auth_method = 'security_token'
        }
        elseif ($key_file) {
            $script:auth_method = 'api_key'
        }
    }
    print_debug "Detected auth method: $script:auth_method (profile: $OCI_PROFILE, config: $OCI_CONFIG_FILE)"
}

function setup_oci_config {
    print_subheader "OCI Authentication"
    
    New-Item -ItemType Directory -Path "$env:USERPROFILE\.oci" -Force | Out-Null
    
    $existing_config_invalid = $false
    if (Test-Path $OCI_CONFIG_FILE) {
        print_status "Existing OCI configuration found"
        detect_auth_method

        print_status "Validating existing OCI configuration..."

        if (!(validate_existing_oci_config)) {
            $existing_config_invalid = $true
            print_warning "Existing OCI configuration is incomplete or requires interactive input"
        }
        else {
            # Test existing configuration
            print_status "Testing existing OCI configuration connectivity..."
            if (test_oci_connectivity) {
                print_success "Existing OCI configuration is valid"
                return
            }
        }
    }
    
    # Setup new authentication
    print_status "Setting up browser-based authentication..."
    print_status "This will open a browser window for you to log in to Oracle Cloud."

    if ($NON_INTERACTIVE -eq 'true') {
        print_error "Cannot perform interactive authentication in non-interactive mode. Aborting."
        throw "Non-interactive auth not possible"
    }

    # Determine region to use for browser login.
    # If we have an existing config, prefer its region (avoids the region selection prompt).
    $auth_region = read_oci_config_value 'region' $OCI_CONFIG_FILE $OCI_PROFILE
    $auth_region = if ($auth_region) { $auth_region } else { $OCI_AUTH_REGION }
    $auth_region = if ($auth_region) { $auth_region } else { default_region_for_host }

    # Keep this interactive (per UX request): prompt with a sane default so Enter works.
    if ($NON_INTERACTIVE -ne 'true') {
        $auth_region = prompt_with_default "Region for authentication" $auth_region
    }

    # Allow forcing re-auth / new profile
    if ($FORCE_REAUTH -eq 'true') {
        $new_profile = prompt_with_default "Enter new profile name to create/use" "NEW_PROFILE"
        print_status "Starting interactive session authenticate for profile '$new_profile'..."

        print_status "Using region '$auth_region' for authentication"
        try {
            if (is_wsl) {
                $auth_out = & oci session authenticate --no-browser --profile-name $new_profile --region $auth_region --session-expiration-in-minutes 60 2>&1
                Write-Host $auth_out
                $url = $auth_out | Select-String -Pattern 'https://[^ ]+' | ForEach-Object { $_.Matches.Value } | Select-Object -First 1
                if ($url) {
                    print_status "Opening browser for login URL (WSL)..."
                    open_url_best_effort $url | Out-Null
                }
            }
            else {
                & oci session authenticate --profile-name $new_profile --region $auth_region --session-expiration-in-minutes 60
            }
        }
        catch {
            print_error "Authentication failed"
            throw "Authentication failed"
        }

        print_status "Authentication for profile '$new_profile' completed. Updating OCI_PROFILE to use it."
        $script:OCI_PROFILE = $new_profile
        $script:auth_method = 'security_token'

        if ($existing_config_invalid) {
            # Run the same automatic delete and recreate flow
            print_warning "Detected invalid or incomplete OCI config file during forced re-auth - AUTOMATICALLY DELETING AND FORCING FRESH AUTHENTICATION"

            # IMMEDIATE DELETE: Remove corrupted config without prompting
            if (Test-Path $OCI_CONFIG_FILE) {
                print_status "Backing up corrupted config to $OCI_CONFIG_FILE.corrupted.$((Get-Date).ToString('yyyyMMdd_HHmmss'))"
                Copy-Item $OCI_CONFIG_FILE "$OCI_CONFIG_FILE.corrupted.$((Get-Date).ToString('yyyyMMdd_HHmmss'))" -ErrorAction SilentlyContinue
                print_status "Forcibly deleting corrupted config file: $OCI_CONFIG_FILE"
                Remove-Item $OCI_CONFIG_FILE -Force
            }
            
            # Delete any temp config files to start completely fresh
            Remove-Item "$env:USERPROFILE\.oci\config.session_auth" -ErrorAction SilentlyContinue
            
            # Create completely new profile with session auth
            $new_profile = 'DEFAULT'
            print_status "Creating fresh OCI configuration with browser-based authentication for profile '$new_profile'..."
            print_status "This will open your browser to log into Oracle Cloud."
            Write-Host ""
            print_status "Using region '$auth_region' for authentication"
            Write-Host ""
            
            # Use the default config location (let OCI CLI create it fresh)
            $script:OCI_CONFIG_FILE = "$env:USERPROFILE\.oci\config"
            $script:OCI_PROFILE = $new_profile
            $env:OCI_CLI_CONFIG_FILE = $null
            
            if (is_wsl) {
                try {
                    $auth_out = & oci session authenticate --no-browser --profile-name $new_profile --region $auth_region --session-expiration-in-minutes 60 2>&1
                    Write-Host $auth_out
                    $url = $auth_out | Select-String -Pattern 'https://[^ ]+' | ForEach-Object { $_.Matches.Value } | Select-Object -First 1
                    if ($url) {
                        print_status "Opening browser for login URL (WSL)..."
                        open_url_best_effort $url | Out-Null
                        Write-Host ""
                        print_status "After completing browser authentication, press Enter to continue..."
                        Read-Host
                    }
                    $script:auth_method = 'security_token'
                    if (test_oci_connectivity) {
                        print_success "Fresh session authentication succeeded for profile '$new_profile'"
                        return
                    }
                    else {
                        print_warning "Session auth completed but connectivity test failed"
                    }
                }
                catch {
                    Write-Host $_.Exception.Message
                    print_error "Browser-based authentication failed. Please verify your Oracle Cloud credentials and try again."
                    throw "Authentication failed"
                }
            }
            else {
                try {
                    & oci session authenticate --profile-name $new_profile --region $auth_region --session-expiration-in-minutes 60
                    $script:auth_method = 'security_token'
                    if (test_oci_connectivity) {
                        print_success "Fresh session authentication succeeded for profile '$new_profile'"
                        return
                    }
                    else {
                        print_warning "Session auth completed but connectivity test failed"
                    }
                }
                catch {
                    print_error "Browser-based authentication failed. Please verify your Oracle Cloud credentials and try again."
                    throw "Authentication failed"
                }
            }
        }

        if (test_oci_connectivity) {
            print_success "OCI authentication configured successfully for profile '$new_profile'"
            return
        }
        else {
            print_warning "Authentication succeeded but connectivity test failed for profile '$new_profile'"
        }
    }
    else {
        # If existing config was invalid, automatically fix it
        if ($existing_config_invalid) {
            print_warning "Detected invalid or incomplete OCI config file - AUTOMATICALLY DELETING AND FORCING FRESH AUTHENTICATION"
            
            # IMMEDIATE DELETE: Remove corrupted config without prompting
            if (Test-Path $OCI_CONFIG_FILE) {
                print_status "Backing up corrupted config to $OCI_CONFIG_FILE.corrupted.$((Get-Date).ToString('yyyyMMdd_HHmmss'))"
                Copy-Item $OCI_CONFIG_FILE "$OCI_CONFIG_FILE.corrupted.$((Get-Date).ToString('yyyyMMdd_HHmmss'))" -ErrorAction SilentlyContinue
                print_status "Forcibly deleting corrupted config file: $OCI_CONFIG_FILE"
                Remove-Item $OCI_CONFIG_FILE -Force
            }
            
            # Delete any temp config files to start completely fresh
            Remove-Item "$env:USERPROFILE\.oci\config.session_auth" -ErrorAction SilentlyContinue
            
            # Create completely new profile with session auth
            $new_profile = 'DEFAULT'
            print_status "Creating fresh OCI configuration with browser-based authentication for profile '$new_profile'..."
            print_status "This will open your browser to log into Oracle Cloud."
            Write-Host ""
            print_status "Using region '$auth_region' for authentication"
            Write-Host ""
            
            # Use the default config location (let OCI CLI create it fresh)
            $script:OCI_CONFIG_FILE = "$env:USERPROFILE\.oci\config"
            $script:OCI_PROFILE = $new_profile
            $env:OCI_CLI_CONFIG_FILE = $null
            
            if (is_wsl) {
                try {
                    $auth_out = & oci session authenticate --no-browser --profile-name $new_profile --region $auth_region --session-expiration-in-minutes 60 2>&1
                    Write-Host $auth_out
                    $url = $auth_out | Select-String -Pattern 'https://[^ ]+' | ForEach-Object { $_.Matches.Value } | Select-Object -First 1
                    if ($url) {
                        print_status "Opening browser for login URL (WSL)..."
                        open_url_best_effort $url | Out-Null
                        Write-Host ""
                        print_status "After completing browser authentication, press Enter to continue..."
                        Read-Host
                    }
                    $script:auth_method = 'security_token'
                    if (test_oci_connectivity) {
                        print_success "Fresh session authentication succeeded for profile '$new_profile'"
                        return
                    }
                    else {
                        print_warning "Session auth completed but connectivity test failed"
                    }
                }
                catch {
                    Write-Host $_.Exception.Message
                    print_error "Browser-based authentication failed. Please verify your Oracle Cloud credentials and try again."
                    throw "Authentication failed"
                }
            }
            else {
                try {
                    & oci session authenticate --profile-name $new_profile --region $auth_region --session-expiration-in-minutes 60
                    $script:auth_method = 'security_token'
                    if (test_oci_connectivity) {
                        print_success "Fresh session authentication succeeded for profile '$new_profile'"
                        return
                    }
                    else {
                        print_warning "Session auth completed but connectivity test failed"
                    }
                }
                catch {
                    print_error "Browser-based authentication failed. Please verify your Oracle Cloud credentials and try again."
                    throw "Authentication failed"
                }
            }
        }
        # Interactive authenticate (may open browser)
        print_status "Using profile '$script:OCI_PROFILE' for interactive session authenticate..."

        print_status "Using region '$auth_region' for authentication"
        if (is_wsl) {
            try {
                $auth_out = & oci session authenticate --no-browser --profile-name $script:OCI_PROFILE --region $auth_region --session-expiration-in-minutes 60 2>&1
                Write-Host $auth_out
                $url = $auth_out | Select-String -Pattern 'https://[^ ]+' | ForEach-Object { $_.Matches.Value } | Select-Object -First 1
                if ($url) {
                    print_status "Opening browser for login URL (WSL)..."
                    open_url_best_effort $url | Out-Null
                }
            }
            catch {
                Write-Host $_.Exception.Message
                if ($auth_out -match '(?i)config file.*is invalid|Config Errors|user .*missing') {
                    print_warning "OCI CLI reports the config file is invalid or missing required fields. Offering repair options..."
                    $existing_config_invalid = $true
                }
                else {
                    print_error "Authentication failed"
                    throw "Authentication failed"
                }
            }
        }
        else {
            # Capture output so we can detect invalid-config errors and offer remediation
            try {
                & oci session authenticate --profile-name $script:OCI_PROFILE --region $auth_region --session-expiration-in-minutes 60
            }
            catch {
                $auth_out = $_.Exception.Message
                if ($auth_out -match '(?i)config file.*is invalid|Config Errors|user .*missing') {
                    print_warning "OCI CLI reports the config file is invalid or missing required fields. Offering repair options..."
                    $existing_config_invalid = $true
                }
                else {
                    print_error "Browser authentication failed or was cancelled"
                    throw "Authentication failed"
                }
            }
        }

        # SHARED REPAIR FLOW: runs for both WSL and non-WSL when existing_config_invalid is set
        if ($existing_config_invalid) {
            print_warning "Detected invalid or incomplete OCI config file - AUTOMATICALLY DELETING AND FORCING FRESH AUTHENTICATION"
            
            # IMMEDIATE DELETE: Remove corrupted config without prompting
            if (Test-Path $OCI_CONFIG_FILE) {
                print_status "Backing up corrupted config to $OCI_CONFIG_FILE.corrupted.$((Get-Date).ToString('yyyyMMdd_HHmmss'))"
                Copy-Item $OCI_CONFIG_FILE "$OCI_CONFIG_FILE.corrupted.$((Get-Date).ToString('yyyyMMdd_HHmmss'))" -ErrorAction SilentlyContinue
                print_status "Forcibly deleting corrupted config file: $OCI_CONFIG_FILE"
                Remove-Item $OCI_CONFIG_FILE -Force
            }
            
            # Delete any temp config files to start completely fresh
            Remove-Item "$env:USERPROFILE\.oci\config.session_auth" -ErrorAction SilentlyContinue
            
            # Create completely new profile with session auth
            $new_profile = 'DEFAULT'
            print_status "Creating fresh OCI configuration with browser-based authentication for profile '$new_profile'..."
            print_status "This will open your browser to log into Oracle Cloud."
            Write-Host ""
            print_status "Using region '$auth_region' for authentication"
            Write-Host ""
            
            # Use the default config location (let OCI CLI create it fresh)
            $script:OCI_CONFIG_FILE = "$env:USERPROFILE\.oci\config"
            $script:OCI_PROFILE = $new_profile
            $env:OCI_CLI_CONFIG_FILE = $null
            
            if (is_wsl) {
                try {
                    $auth_out = & oci session authenticate --no-browser --profile-name $new_profile --region $auth_region --session-expiration-in-minutes 60 2>&1
                    Write-Host $auth_out
                    $url = $auth_out | Select-String -Pattern 'https://[^ ]+' | ForEach-Object { $_.Matches.Value } | Select-Object -First 1
                    if ($url) {
                        print_status "Opening browser for login URL (WSL)..."
                        open_url_best_effort $url | Out-Null
                        Write-Host ""
                        print_status "After completing browser authentication, press Enter to continue..."
                        Read-Host
                    }
                    $script:auth_method = 'security_token'
                    if (test_oci_connectivity) {
                        print_success "Fresh session authentication succeeded for profile '$new_profile'"
                        return
                    }
                    else {
                        print_warning "Session auth completed but connectivity test failed"
                    }
                }
                catch {
                    Write-Host $_.Exception.Message
                    print_error "Browser-based authentication failed. Please verify your Oracle Cloud credentials and try again."
                    throw "Authentication failed"
                }
            }
            else {
                try {
                    & oci session authenticate --profile-name $new_profile --region $auth_region --session-expiration-in-minutes 60
                    $script:auth_method = 'security_token'
                    if (test_oci_connectivity) {
                        print_success "Fresh session authentication succeeded for profile '$new_profile'"
                        return
                    }
                    else {
                        print_warning "Session auth completed but connectivity test failed"
                    }
                }
                catch {
                    print_error "Browser-based authentication failed. Please verify your Oracle Cloud credentials and try again."
                    throw "Authentication failed"
                }
            }
        }


        # If we got here without returning, then authentication succeeded but connectivity might have issues
        # Let's continue anyway since the auth was successful
        $script:auth_method = 'security_token'

        # Verify the new configuration
        if (test_oci_connectivity) {
            print_success "OCI authentication configured successfully"
            return
        }
    }

    print_error "OCI configuration verification failed"
    throw "OCI configuration failed"
}

function test_oci_connectivity {
    print_status "Testing OCI API connectivity..."
    
    # Method 1: List regions (simplest test)
    print_status "Checking IAM region list (timeout ${OCI_CMD_TIMEOUT}s)..."
    try {
        $result = oci_cmd "iam region list"
        print_debug "Connectivity test passed (region list)"
        return $true
    }
    catch {
        print_warning "Region list query failed or timed out"
    }
    
    # Method 2: Get tenancy info if we have it
    $test_tenancy = $null
    try {
        $content = Get-Content $OCI_CONFIG_FILE -Raw
        if ($content -match '(?<=tenancy=).*') {
            $test_tenancy = $matches[0]
        }
    }
    catch { }
    
    if ($test_tenancy) {
        print_status "Checking IAM tenancy get (timeout ${OCI_CMD_TIMEOUT}s)..."
        try {
            $result = oci_cmd "iam tenancy get --tenancy-id $test_tenancy"
            print_debug "Connectivity test passed (tenancy get)"
            return $true
        }
        catch {
            print_warning "Tenancy get failed or timed out"
        }
    }
    
    print_debug "All connectivity tests failed"
    return $false
}

# ============================================================================
# OCI RESOURCE DISCOVERY FUNCTIONS
# ============================================================================

function fetch_oci_config_values {
    print_subheader "Fetching OCI Configuration"
    
    # Tenancy OCID
    $content = Get-Content $OCI_CONFIG_FILE -Raw
    if ($content -match 'tenancy=(.*)$') {
        $script:tenancy_ocid = $matches[1]
    }
    if ([string]::IsNullOrEmpty($script:tenancy_ocid)) {
        print_error "Failed to fetch tenancy OCID from config"
        throw "Failed to fetch tenancy OCID"
    }
    print_status "Tenancy OCID: $script:tenancy_ocid"
    
    # User OCID
    if ($content -match '^\s*user\s*=\s*(.*)$') {
        $script:user_ocid = ($matches[1] -replace '^\s+', '' -replace '\s+$', '')
    }
    if ([string]::IsNullOrEmpty($script:user_ocid)) {
        # Try to get from API for session token auth
        try {
            $user_info = oci_cmd "iam user list --compartment-id $script:tenancy_ocid --limit 1"
            $script:user_ocid = safe_jq $user_info '.data[0].id'
        }
        catch {
        }
    }
    print_status "User OCID: $(if ($script:user_ocid) { $script:user_ocid } else { 'N/A (session token auth)' })"
    
    # Region
    if ($content -match 'region=(.*)$') {
        $script:region = $matches[1]
    }
    if ([string]::IsNullOrEmpty($script:region)) {
        print_error "Failed to fetch region from config"
        throw "Failed to fetch region"
    }
    print_status "Region: $script:region"
    
    # Fingerprint (only for API key auth)
    if ($script:auth_method -eq 'security_token') {
        $script:fingerprint = 'session_token_auth'
    }
    else {
        if ($content -match 'fingerprint=(.*)$') {
            $script:fingerprint = $matches[1]
        }
    }
    print_debug "Auth fingerprint: $script:fingerprint"
    
    print_success "OCI configuration values fetched"
}

function fetch_availability_domains {
    print_status "Fetching availability domains..."
    
    try {
        $ad_list = oci_cmd "iam availability-domain list --compartment-id $script:tenancy_ocid --query 'data[].name' --raw-output"
    }
    catch {
        print_error "Failed to fetch availability domains"
        throw "Failed to fetch ADs"
    }
    
    if ([string]::IsNullOrEmpty($ad_list) -or $ad_list -eq 'null') {
        print_error "Failed to fetch availability domains"
        throw "Failed to fetch ADs"
    }
    
    # Parse first AD (should come as raw output with newlines)
    try {
        $ad_array = $ad_list -split '\r?\n' | Where-Object { ![string]::IsNullOrWhiteSpace($_) }
        $script:availability_domain = $ad_array[0]
    }
    catch {
        $script:availability_domain = $ad_list
    }
    
    if ([string]::IsNullOrEmpty($script:availability_domain) -or $script:availability_domain -eq 'null') {
        print_error "Failed to parse availability domain"
        throw "Failed to parse AD"
    }
    
    print_success "Availability domain: $script:availability_domain"
}

function fetch_ubuntu_images {
    print_status "Fetching Ubuntu images for region $script:region..."
    
    # Fetch x86 (AMD64) Ubuntu image
    print_status "  Looking for x86 Ubuntu image..."
    try {
        $x86_images = oci_cmd "compute image list --compartment-id $script:tenancy_ocid --operating-system 'Canonical Ubuntu' --shape '$FREE_TIER_AMD_SHAPE' --sort-by TIMECREATED --sort-order DESC --query 'data[].{id:id,name:\"display-name\"}' --all"
    }
    catch {
        $x86_images = '[]'
    }
    
    $script:ubuntu_image_ocid = safe_jq $x86_images '.[0].id' ''
    $x86_name = safe_jq $x86_images '.[0].name' ''
    
    if ($script:ubuntu_image_ocid -and $script:ubuntu_image_ocid -ne 'null') {
        print_success "  x86 image: $x86_name"
        print_debug "  x86 OCID: $script:ubuntu_image_ocid"
    }
    else {
        print_warning "  No x86 Ubuntu image found - AMD instances disabled"
        $script:ubuntu_image_ocid = ''
    }
    
    # Fetch ARM Ubuntu image
    print_status "  Looking for ARM Ubuntu image..."
    try {
        $arm_images = oci_cmd "compute image list --compartment-id $script:tenancy_ocid --operating-system 'Canonical Ubuntu' --shape '$FREE_TIER_ARM_SHAPE' --sort-by TIMECREATED --sort-order DESC --query 'data[].{id:id,name:\"display-name\"}' --all"
    }
    catch {
        $arm_images = '[]'
    }
    
    $script:ubuntu_arm_flex_image_ocid = safe_jq $arm_images '.[0].id' ''
    $arm_name = safe_jq $arm_images '.[0].name' ''
    
    if ($script:ubuntu_arm_flex_image_ocid -and $script:ubuntu_arm_flex_image_ocid -ne 'null') {
        print_success "  ARM image: $arm_name"
        print_debug "  ARM OCID: $script:ubuntu_arm_flex_image_ocid"
    }
    else {
        print_warning "  No ARM Ubuntu image found - ARM instances disabled"
        $script:ubuntu_arm_flex_image_ocid = ''
    }
}

function generate_ssh_keys {
    print_status "Setting up SSH keys..."
    
    $ssh_dir = 'ssh_keys'
    New-Item -ItemType Directory -Path $ssh_dir -Force | Out-Null
    
    if (!(Test-Path "$ssh_dir\id_rsa")) {
        print_status "Generating new SSH key pair..."
        & ssh-keygen -t rsa -b 4096 -f "$ssh_dir\id_rsa" -N '' -q
        # Set permissions
        # In Windows, permissions are different
        print_success "SSH key pair generated at $ssh_dir/"
    }
    else {
        print_status "Using existing SSH key pair at $ssh_dir/"
    }
    
    # exported for Terraform/template consumption
    $script:ssh_public_key = Get-Content "$ssh_dir\id_rsa.pub" -Raw
}

# ============================================================================
# COMPREHENSIVE RESOURCE INVENTORY
# ============================================================================

function inventory_all_resources {
    print_header "COMPREHENSIVE RESOURCE INVENTORY"
    print_status "Scanning all existing OCI resources in tenancy..."
    print_status "This ensures we never create duplicate resources."
    Write-Host ""
    
    inventory_compute_instances
    inventory_networking_resources
    inventory_storage_resources
    
    display_resource_inventory
}

function inventory_compute_instances {
    print_status "Inventorying compute instances..."
    
    # Get ALL instances (including terminated for awareness)
    try {
        $all_instances = oci_cmd "compute instance list --compartment-id $script:tenancy_ocid --query 'data[?\"lifecycle-state\"!=\"TERMINATED\"].{id:id,name:\"display-name\",state:\"lifecycle-state\",shape:shape,ad:\"availability-domain\",created:\"time-created\"}' --all"
    }
    catch {
        $all_instances = '[]'
    }
    
    if ([string]::IsNullOrEmpty($all_instances) -or $all_instances -eq 'null') {
        $all_instances = '[]'
    }
    
    # Clear existing tracking
    $script:EXISTING_AMD_INSTANCES = @{}
    $script:EXISTING_ARM_INSTANCES = @{}
    
    try {
        $instances_array = $all_instances | ConvertFrom-Json
    }
    catch {
        $instances_array = @()
    }
    
    $instance_count = if ($instances_array -is [array]) { $instances_array.Count } else { if ($null -eq $instances_array) { 0 } else { 1 } }
    
    if ($instance_count -eq 0) {
        print_status "  No existing compute instances found"
        return
    }
    
    # Parse each instance
    $instances = if ($instances_array -is [array]) { $instances_array } else { @($instances_array) }
    foreach ($instance in $instances) {
        $id = $instance.id
        $name = $instance.name
        $state = $instance.state
        $shape = $instance.shape
        
        if ([string]::IsNullOrEmpty($id)) {
            continue
        }
        
        # Get VNIC information for IP addresses
        try {
            $vnic_attachments = oci_cmd "compute vnic-attachment list --compartment-id $script:tenancy_ocid --instance-id $id --query 'data[?\"lifecycle-state\"==\"ATTACHED\"]'"
        }
        catch {
            $vnic_attachments = '[]'
        }
        
        $public_ip = 'none'
        $private_ip = 'none'
        if ($vnic_attachments -and $vnic_attachments -ne '[]' -and $vnic_attachments -ne 'null') {
            try {
                $vnic_id = safe_jq $vnic_attachments '.[0]."vnic-id"' ''
                
                if ($vnic_id -and $vnic_id -ne 'null') {
                    try {
                        $vnic_details = oci_cmd "network vnic get --vnic-id $vnic_id"
                        $public_ip = safe_jq $vnic_details '.data."public-ip"' 'none'
                        $private_ip = safe_jq $vnic_details '.data."private-ip"' 'none'
                    }
                    catch {
                    }
                }
            }
            catch {
            }
        }
        
        # Categorize by shape
        if ($shape -eq $FREE_TIER_AMD_SHAPE) {
            $script:EXISTING_AMD_INSTANCES[$id] = "$name|$state|$shape|$public_ip|$private_ip"
            print_status "  Found AMD instance: $name ($state) - IP: $public_ip"
        }
        elseif ($shape -eq $FREE_TIER_ARM_SHAPE) {
            # Get shape config for ARM instances
            try {
                $instance_details = oci_cmd "compute instance get --instance-id $id"
                $ocpus = safe_jq $instance_details '.data."shape-config".ocpus' '0'
                $memory = safe_jq $instance_details '.data."shape-config"."memory-in-gbs"' '0'
            }
            catch {
                $ocpus = '0'
                $memory = '0'
            }
            
            $script:EXISTING_ARM_INSTANCES[$id] = "$name|$state|$shape|$public_ip|$private_ip|$ocpus|$memory"
            print_status "  Found ARM instance: $name ($state, ${ocpus}OCPUs, ${memory}GB) - IP: $public_ip"
        }
        else {
            print_debug "  Found non-free-tier instance: $name ($shape)"
        }
    }
    
    print_status "  AMD instances: $($script:EXISTING_AMD_INSTANCES.Count)/$FREE_TIER_MAX_AMD_INSTANCES"
    print_status "  ARM instances: $($script:EXISTING_ARM_INSTANCES.Count)/$FREE_TIER_MAX_ARM_INSTANCES"
}

function inventory_networking_resources {
    print_status "Inventorying networking resources..."
    
    # Clear existing tracking
    $script:EXISTING_VCNS = @{}
    $script:EXISTING_SUBNETS = @{}
    $script:EXISTING_INTERNET_GATEWAYS = @{}
    $script:EXISTING_ROUTE_TABLES = @{}
    $script:EXISTING_SECURITY_LISTS = @{}
    
    # Get VCNs
    try {
        $vcn_list = oci_cmd "network vcn list --compartment-id $script:tenancy_ocid --query 'data[?\"lifecycle-state\"==\"AVAILABLE\"].{id:id,name:\"display-name\",cidr:\"cidr-block\"}' --all"
    }
    catch {
        $vcn_list = '[]'
    }
    
    if ([string]::IsNullOrEmpty($vcn_list) -or $vcn_list -eq 'null') {
        $vcn_list = '[]'
    }
    
    try {
        $vcns = $vcn_list | ConvertFrom-Json
    }
    catch {
        $vcns = @()
    }
    
    foreach ($vcn in @($vcns)) {
        $vcn_id = $vcn.id
        $vcn_name = $vcn.name
        $vcn_cidr = $vcn.cidr
        
        if ([string]::IsNullOrEmpty($vcn_id)) {
            continue
        }
        
        $script:EXISTING_VCNS[$vcn_id] = "$vcn_name|$vcn_cidr"
        print_status "  Found VCN: $vcn_name ($vcn_cidr)"
        
        # Get subnets for this VCN
        try {
            $subnet_list = oci_cmd "network subnet list --compartment-id $script:tenancy_ocid --vcn-id $vcn_id --query 'data[?\"lifecycle-state\"==\"AVAILABLE\"].{id:id,name:\"display-name\",cidr:\"cidr-block\"}'"
        }
        catch {
            $subnet_list = '[]'
        }
        
        try {
            $subnets = $subnet_list | ConvertFrom-Json
        }
        catch {
            $subnets = @()
        }
        
        foreach ($subnet in @($subnets)) {
            $subnet_id = $subnet.id
            $subnet_name = $subnet.name
            $subnet_cidr = $subnet.cidr
            
            if ($subnet_id) {
                $script:EXISTING_SUBNETS[$subnet_id] = "$subnet_name|$subnet_cidr|$vcn_id"
                print_debug "    Subnet: $subnet_name ($subnet_cidr)"
            }
        }
        
        # Get internet gateways
        try {
            $ig_list = oci_cmd "network internet-gateway list --compartment-id $script:tenancy_ocid --vcn-id $vcn_id --query 'data[?\"lifecycle-state\"==\"AVAILABLE\"].{id:id,name:\"display-name\"}'"
        }
        catch {
            $ig_list = '[]'
        }
        
        try {
            $igs = $ig_list | ConvertFrom-Json
        }
        catch {
            $igs = @()
        }
        
        foreach ($ig in @($igs)) {
            $ig_id = $ig.id
            $ig_name = $ig.name
            
            if ($ig_id) {
                $script:EXISTING_INTERNET_GATEWAYS[$ig_id] = "$ig_name|$vcn_id"
            }
        }
        
        # Get route tables
        try {
            $rt_list = oci_cmd "network route-table list --compartment-id $script:tenancy_ocid --vcn-id $vcn_id --query 'data[].{id:id,name:\"display-name\"}'"
        }
        catch {
            $rt_list = '[]'
        }
        
        try {
            $rts = $rt_list | ConvertFrom-Json
        }
        catch {
            $rts = @()
        }
        
        foreach ($rt in @($rts)) {
            $rt_id = $rt.id
            $rt_name = $rt.name
            
            if ($rt_id) {
                $script:EXISTING_ROUTE_TABLES[$rt_id] = "$rt_name|$vcn_id"
            }
        }
        
        # Get security lists
        try {
            $sl_list = oci_cmd "network security-list list --compartment-id $script:tenancy_ocid --vcn-id $vcn_id --query 'data[].{id:id,name:\"display-name\"}'"
        }
        catch {
            $sl_list = '[]'
        }
        
        try {
            $sls = $sl_list | ConvertFrom-Json
        }
        catch {
            $sls = @()
        }
        
        foreach ($sl in @($sls)) {
            $sl_id = $sl.id
            $sl_name = $sl.name
            
            if ($sl_id) {
                $script:EXISTING_SECURITY_LISTS[$sl_id] = "$sl_name|$vcn_id"
            }
        }
    }
    
    print_status "  VCNs: $($script:EXISTING_VCNS.Count)/$FREE_TIER_MAX_VCNS"
    print_status "  Subnets: $($script:EXISTING_SUBNETS.Count)"
    print_status "  Internet Gateways: $($script:EXISTING_INTERNET_GATEWAYS.Count)"
}

function inventory_storage_resources {
    print_status "Inventorying storage resources..."
    
    $script:EXISTING_BOOT_VOLUMES = @{}
    $script:EXISTING_BLOCK_VOLUMES = @{}
    
    # Get boot volumes
    try {
        $boot_list = oci_cmd "bv boot-volume list --compartment-id $script:tenancy_ocid --availability-domain $script:availability_domain --query 'data[?\"lifecycle-state\"==\"AVAILABLE\"].{id:id,name:\"display-name\",size:\"size-in-gbs\"}' --all"
    }
    catch {
        $boot_list = '[]'
    }
    
    $total_boot_gb = 0
    
    try {
        $boots = $boot_list | ConvertFrom-Json
    }
    catch {
        $boots = @()
    }
    
    foreach ($boot in @($boots)) {
        $boot_id = $boot.id
        $boot_name = $boot.name
        $boot_size = [int]$boot.size
        
        if ($boot_id) {
            $script:EXISTING_BOOT_VOLUMES[$boot_id] = "$boot_name|$boot_size"
            $total_boot_gb += $boot_size
        }
    }
    
    # Get block volumes
    try {
        $block_list = oci_cmd "bv volume list --compartment-id $script:tenancy_ocid --availability-domain $script:availability_domain --query 'data[?\"lifecycle-state\"==\"AVAILABLE\"].{id:id,name:\"display-name\",size:\"size-in-gbs\"}' --all"
    }
    catch {
        $block_list = '[]'
    }
    
    $total_block_gb = 0
    
    try {
        $blocks = $block_list | ConvertFrom-Json
    }
    catch {
        $blocks = @()
    }
    
    foreach ($block in @($blocks)) {
        $block_id = $block.id
        $block_name = $block.name
        $block_size = [int]$block.size
        
        if ($block_id) {
            $script:EXISTING_BLOCK_VOLUMES[$block_id] = "$block_name|$block_size"
            $total_block_gb += $block_size
        }
    }
    
    $total_storage = $total_boot_gb + $total_block_gb
    
    print_status "  Boot volumes: $($script:EXISTING_BOOT_VOLUMES.Count) (${total_boot_gb}GB)"
    print_status "  Block volumes: $($script:EXISTING_BLOCK_VOLUMES.Count) (${total_block_gb}GB)"
    print_status "  Total storage: ${total_storage}GB/${FREE_TIER_MAX_STORAGE_GB}GB"
}

function display_resource_inventory {
    Write-Host ""
    print_header "RESOURCE INVENTORY SUMMARY"
    
    # Calculate totals
    $total_amd = $script:EXISTING_AMD_INSTANCES.Count
    $total_arm = $script:EXISTING_ARM_INSTANCES.Count
    $total_arm_ocpus = 0
    $total_arm_memory = 0
    
    foreach ($instance_data in $script:EXISTING_ARM_INSTANCES.Values) {
        $parts = $instance_data -split '\|'
        $ocpus = [int]$parts[5]
        $memory = [int]$parts[6]
        $total_arm_ocpus += $ocpus
        $total_arm_memory += $memory
    }
    
    $total_boot_gb = 0
    foreach ($boot_data in $script:EXISTING_BOOT_VOLUMES.Values) {
        $size = [int]($boot_data -split '\|')[1]
        $total_boot_gb += $size
    }
    
    $total_block_gb = 0
    foreach ($block_data in $script:EXISTING_BLOCK_VOLUMES.Values) {
        $size = [int]($block_data -split '\|')[1]
        $total_block_gb += $size
    }
    
    $total_storage = $total_boot_gb + $total_block_gb
    
    Write-Host -ForegroundColor $BOLD "Compute Resources:$($NC)"
    Write-Host "  ┌─────────────────────────────────────────────────────────────┐"
    Write-Host "  │ AMD Micro Instances:  $total_amd / $FREE_TIER_MAX_AMD_INSTANCES (Free Tier limit)          │"
    Write-Host "  │ ARM A1 Instances:     $total_arm / $FREE_TIER_MAX_ARM_INSTANCES (up to)                    │"
    Write-Host "  │ ARM OCPUs Used:       $total_arm_ocpus / $FREE_TIER_MAX_ARM_OCPUS                           │"
    Write-Host "  │ ARM Memory Used:      ${total_arm_memory}GB / ${FREE_TIER_MAX_ARM_MEMORY_GB}GB                         │"
    Write-Host "  └─────────────────────────────────────────────────────────────┘"
    Write-Host ""
    Write-Host -ForegroundColor $BOLD "Storage Resources:$($NC)"
    Write-Host "  ┌─────────────────────────────────────────────────────────────┐"
    Write-Host "  │ Boot Volumes:         ${total_boot_gb}GB                                    │"
    Write-Host "  │ Block Volumes:        ${total_block_gb}GB                                    │"
    Write-Host ("  │ Total Storage:        {0,3}GB / {1,3}GB Free Tier limit          │" -f $total_storage, $FREE_TIER_MAX_STORAGE_GB)
    Write-Host "  └─────────────────────────────────────────────────────────────┘"
    Write-Host ""
    Write-Host -ForegroundColor $BOLD "Networking Resources:$($NC)"
    Write-Host "  ┌─────────────────────────────────────────────────────────────┐"
    Write-Host "  │ VCNs:                 $($script:EXISTING_VCNS.Count) / $FREE_TIER_MAX_VCNS (Free Tier limit)             │"
    Write-Host "  │ Subnets:              $($script:EXISTING_SUBNETS.Count)                                       │"
    Write-Host "  │ Internet Gateways:    $($script:EXISTING_INTERNET_GATEWAYS.Count)                                       │"
    Write-Host "  └─────────────────────────────────────────────────────────────┘"
    Write-Host ""
    
    # Warnings for near-limit resources
    if ($total_amd -ge $FREE_TIER_MAX_AMD_INSTANCES) {
        print_warning "AMD instance limit reached - cannot create more AMD instances"
    }
    if ($total_arm_ocpus -ge $FREE_TIER_MAX_ARM_OCPUS) {
        print_warning "ARM OCPU limit reached - cannot allocate more ARM OCPUs"
    }
    if ($total_arm_memory -ge $FREE_TIER_MAX_ARM_MEMORY_GB) {
        print_warning "ARM memory limit reached - cannot allocate more ARM memory"
    }
    if ($total_storage -ge $FREE_TIER_MAX_STORAGE_GB) {
        print_warning "Storage limit reached - cannot create more volumes"
    }
    if ($script:EXISTING_VCNS.Count -ge $FREE_TIER_MAX_VCNS) {
        print_warning "VCN limit reached - cannot create more VCNs"
    }
}

# ============================================================================
# FREE TIER LIMIT VALIDATION
# ============================================================================

function calculate_available_resources {
    # Calculate what's still available within Free Tier limits
    $used_amd = $script:EXISTING_AMD_INSTANCES.Count
    $used_arm_ocpus = 0
    $used_arm_memory = 0
    $used_storage = 0
    
    foreach ($instance_data in $script:EXISTING_ARM_INSTANCES.Values) {
        $parts = $instance_data -split '\|'
        $ocpus = [int]$parts[5]
        $memory = [int]$parts[6]
        $used_arm_ocpus += $ocpus
        $used_arm_memory += $memory
    }
    
    foreach ($boot_data in $script:EXISTING_BOOT_VOLUMES.Values) {
        $size = [int]($boot_data -split '\|')[1]
        $used_storage += $size
    }
    
    foreach ($block_data in $script:EXISTING_BLOCK_VOLUMES.Values) {
        $size = [int]($block_data -split '\|')[1]
        $used_storage += $size
    }
    
    # Export available resources
    $script:AVAILABLE_AMD_INSTANCES = $FREE_TIER_MAX_AMD_INSTANCES - $used_amd
    $script:AVAILABLE_ARM_OCPUS = $FREE_TIER_MAX_ARM_OCPUS - $used_arm_ocpus
    $script:AVAILABLE_ARM_MEMORY = $FREE_TIER_MAX_ARM_MEMORY_GB - $used_arm_memory
    $script:AVAILABLE_STORAGE = $FREE_TIER_MAX_STORAGE_GB - $used_storage
    $script:USED_ARM_INSTANCES = $script:EXISTING_ARM_INSTANCES.Count
    
    print_debug "Available: AMD=$script:AVAILABLE_AMD_INSTANCES, ARM_OCPU=$script:AVAILABLE_ARM_OCPUS, ARM_MEM=$script:AVAILABLE_ARM_MEMORY, Storage=$script:AVAILABLE_STORAGE"
}

function validate_proposed_config {
    param([int]$proposed_amd, [int]$proposed_arm, [int]$proposed_arm_ocpus, [int]$proposed_arm_memory, [int]$proposed_storage)
    
    $errors = 0
    
    if ($proposed_amd -gt $script:AVAILABLE_AMD_INSTANCES) {
        print_error "Cannot create $proposed_amd AMD instances - only $script:AVAILABLE_AMD_INSTANCES available"
        $errors++
    }
    
    if ($proposed_arm_ocpus -gt $script:AVAILABLE_ARM_OCPUS) {
        print_error "Cannot allocate $proposed_arm_ocpus ARM OCPUs - only $script:AVAILABLE_ARM_OCPUS available"
        $errors++
    }
    
    if ($proposed_arm_memory -gt $script:AVAILABLE_ARM_MEMORY) {
        print_error "Cannot allocate ${proposed_arm_memory}GB ARM memory - only ${script:AVAILABLE_ARM_MEMORY}GB available"
        $errors++
    }
    
    if ($proposed_storage -gt $script:AVAILABLE_STORAGE) {
        print_error "Cannot use ${proposed_storage}GB storage - only ${script:AVAILABLE_STORAGE}GB available"
        $errors++
    }
    
    return ($errors -eq 0)
}

# ============================================================================
# CONFIGURATION FUNCTIONS
# ============================================================================

function load_existing_config {
    if (!(Test-Path 'variables.tf')) {
        return $false
    }
    
    print_status "Loading existing configuration from variables.tf..."
    
    # Load basic counts
    $content = Get-Content 'variables.tf' -Raw
    
    if ($content -match 'amd_micro_instance_count\s*=\s*(\d+)') {
        $script:amd_micro_instance_count = [int]$matches[1]
    }
    else {
        $script:amd_micro_instance_count = 0
    }
    
    if ($content -match 'amd_micro_boot_volume_size_gb\s*=\s*(\d+)') {
        $script:amd_micro_boot_volume_size_gb = [int]$matches[1]
    }
    else {
        $script:amd_micro_boot_volume_size_gb = 50
    }
    
    if ($content -match 'arm_flex_instance_count\s*=\s*(\d+)') {
        $script:arm_flex_instance_count = [int]$matches[1]
    }
    else {
        $script:arm_flex_instance_count = 0
    }
    
    # Load ARM arrays
    $ocpus_str = $null
    if ($content -match 'arm_flex_ocpus_per_instance\s*=\s*\[([^\]]+)') {
        $ocpus_str = $matches[1]
    }
    
    $memory_str = $null
    if ($content -match 'arm_flex_memory_per_instance\s*=\s*\[([^\]]+)') {
        $memory_str = $matches[1]
    }
    
    $boot_str = $null
    if ($content -match 'arm_flex_boot_volume_size_gb\s*=\s*\[([^\]]+)') {
        $boot_str = $matches[1]
    }
    
    $script:arm_flex_ocpus_per_instance = (($ocpus_str ?? '') -replace ',', ' ' -replace '\s+', ' ').Trim()
    $script:arm_flex_memory_per_instance = (($memory_str ?? '') -replace ',', ' ' -replace '\s+', ' ').Trim()
    $script:arm_flex_boot_volume_size_gb = (($boot_str ?? '') -replace ',', ' ' -replace '\s+', ' ').Trim()
    
    # Load hostnames
    $amd_hostnames_str = $null
    if ($content -match 'amd_micro_hostnames\s*=\s*\[([^\]]+)') {
        $amd_hostnames_str = $matches[1]
    }
    
    $arm_hostnames_str = $null
    if ($content -match 'arm_flex_hostnames\s*=\s*\[([^\]]+)') {
        $arm_hostnames_str = $matches[1]
    }
    
    $script:amd_micro_hostnames = @()
    $script:arm_flex_hostnames = @()
    
    if ($amd_hostnames_str) {
        $script:amd_micro_hostnames = @($amd_hostnames_str -split ',' | ForEach-Object { $_.Trim() -replace '"', '' } | Where-Object { ![string]::IsNullOrEmpty($_) })
    }
    
    if ($arm_hostnames_str) {
        $script:arm_flex_hostnames = @($arm_hostnames_str -split ',' | ForEach-Object { $_.Trim() -replace '"', '' } | Where-Object { ![string]::IsNullOrEmpty($_) })
    }
    
    print_success "Loaded configuration: $($script:amd_micro_instance_count)x AMD, $($script:arm_flex_instance_count)x ARM"
    return $true
}

function prompt_configuration {
    print_header "INSTANCE CONFIGURATION"
    
    calculate_available_resources
    
    Write-Host -ForegroundColor $BOLD "Available Free Tier Resources:$($NC)"
    Write-Host "  • AMD instances:  $script:AVAILABLE_AMD_INSTANCES available (max $FREE_TIER_MAX_AMD_INSTANCES)"
    Write-Host "  • ARM OCPUs:      $script:AVAILABLE_ARM_OCPUS available (max $FREE_TIER_MAX_ARM_OCPUS)"
    Write-Host "  • ARM Memory:     $($script:AVAILABLE_ARM_MEMORY)GB available (max $($FREE_TIER_MAX_ARM_MEMORY_GB)GB)"
    Write-Host "  • Storage:        $($script:AVAILABLE_STORAGE)GB available (max $($FREE_TIER_MAX_STORAGE_GB)GB)"
    Write-Host ""
    
    # Check if we have existing config
    $has_existing_config = load_existing_config
    
    print_status "Configuration options:"
    Write-Host "  1) Use existing instances (manage what's already deployed)"
    if ($has_existing_config) {
        Write-Host "  2) Use saved configuration from variables.tf"
    }
    else {
        Write-Host "  2) Use saved configuration from variables.tf (not available)"
    }
    Write-Host "  3) Configure new instances (respecting Free Tier limits)"
    Write-Host "  4) Maximum Free Tier configuration (use all available resources)"
    Write-Host ""
    
    $choice = 0
    while ($true) {
        if ($AUTO_USE_EXISTING -eq 'true') {
            $choice = 1
            print_status "Auto mode: Using existing instances"
        }
        elseif ($NON_INTERACTIVE -eq 'true') {
            $choice = 1
            print_status "Non-interactive mode: Using existing instances"
        }
        else {
            $raw_choice = prompt_with_default "Choose configuration (1-4)" "1"
            $raw_choice = $raw_choice -replace '\r', '' -replace '^\s+', '' -replace '\s+$', ''
            if ($raw_choice -match '^[0-9]+$' -and [int]$raw_choice -ge 1 -and [int]$raw_choice -le 4) {
                $choice = [int]$raw_choice
            }
            else {
                print_error "Please enter a number between 1 and 4 (received: '$raw_choice')"
                continue
            }
        }
        
        switch ($choice) {
            1 {
                configure_from_existing_instances
                break
            }
            2 {
                if ($has_existing_config) {
                    print_success "Using saved configuration"
                    break
                }
                else {
                    print_error "No saved configuration available"
                    continue
                }
            }
            3 {
                configure_custom_instances
                break
            }
            4 {
                configure_maximum_free_tier
                break
            }
            default {
                print_error "Invalid choice"
                continue
            }
        }
    }
}

function configure_from_existing_instances {
    print_status "Configuring based on existing instances..."
    
    # Use existing AMD instances
    $script:amd_micro_instance_count = $script:EXISTING_AMD_INSTANCES.Count
    $script:amd_micro_hostnames = @()
    
    foreach ($instance_data in $script:EXISTING_AMD_INSTANCES.Values) {
        $name = ($instance_data -split '\|')[0]
        $script:amd_micro_hostnames += $name
    }
    
    # Use existing ARM instances
    $script:arm_flex_instance_count = $script:EXISTING_ARM_INSTANCES.Count
    $script:arm_flex_hostnames = @()
    $script:arm_flex_ocpus_per_instance = ''
    $script:arm_flex_memory_per_instance = ''
    $script:arm_flex_boot_volume_size_gb = ''
    $script:arm_flex_block_volumes = @()
    
    foreach ($instance_data in $script:EXISTING_ARM_INSTANCES.Values) {
        $parts = $instance_data -split '\|'
        $name = $parts[0]
        $ocpus = $parts[5]
        $memory = $parts[6]
        
        $script:arm_flex_hostnames += $name
        $script:arm_flex_ocpus_per_instance += "$ocpus "
        $script:arm_flex_memory_per_instance += "$memory "
        $script:arm_flex_boot_volume_size_gb += "50 "  # Default, will be updated from state
        $script:arm_flex_block_volumes += 0
    }
    
    # Trim trailing spaces
    $script:arm_flex_ocpus_per_instance = $script:arm_flex_ocpus_per_instance.Trim()
    $script:arm_flex_memory_per_instance = $script:arm_flex_memory_per_instance.Trim()
    $script:arm_flex_boot_volume_size_gb = $script:arm_flex_boot_volume_size_gb.Trim()
    
    # Set defaults if no instances exist
    if ($script:amd_micro_instance_count -eq 0 -and $script:arm_flex_instance_count -eq 0) {
        print_status "No existing instances found, using default configuration"
        $script:amd_micro_instance_count = 0
        $script:arm_flex_instance_count = 1
        $script:arm_flex_ocpus_per_instance = '4'
        $script:arm_flex_memory_per_instance = '24'
        $script:arm_flex_boot_volume_size_gb = '200'
        $script:arm_flex_hostnames = @('arm-instance-1')
        $script:arm_flex_block_volumes = @(0)
    }
    
    $script:amd_micro_boot_volume_size_gb = 50
    
    print_success "Configuration: $($script:amd_micro_instance_count)x AMD, $($script:arm_flex_instance_count)x ARM"
}

function configure_custom_instances {
    print_status "Custom instance configuration..."
    
    # AMD instances
    $script:amd_micro_instance_count = prompt_int_range "Number of AMD instances (0-$script:AVAILABLE_AMD_INSTANCES)" "0" 0 $script:AVAILABLE_AMD_INSTANCES
    
    $script:amd_micro_hostnames = @()
    if ($script:amd_micro_instance_count -gt 0) {
        $script:amd_micro_boot_volume_size_gb = prompt_int_range "AMD boot volume size GB (50-100)" "50" 50 100
        
        for ($i = 1; $i -le $script:amd_micro_instance_count; $i++) {
            $hostname = Read-Host "$($BLUE)Hostname for AMD instance $i [amd-instance-$i]: $($NC)"
            if ([string]::IsNullOrEmpty($hostname)) {
                $hostname = "amd-instance-$i"
            }
            $script:amd_micro_hostnames += $hostname
        }
    }
    else {
        $script:amd_micro_boot_volume_size_gb = 50
    }
    
    # ARM instances
    if ($script:ubuntu_arm_flex_image_ocid -and $script:AVAILABLE_ARM_OCPUS -gt 0) {
        $script:arm_flex_instance_count = prompt_int_range "Number of ARM instances (0-4)" "1" 0 4
        
        $script:arm_flex_hostnames = @()
        $script:arm_flex_ocpus_per_instance = ''
        $script:arm_flex_memory_per_instance = ''
        $script:arm_flex_boot_volume_size_gb = ''
        $script:arm_flex_block_volumes = @()
        
        $remaining_ocpus = $script:AVAILABLE_ARM_OCPUS
        $remaining_memory = $script:AVAILABLE_ARM_MEMORY
        
        for ($i = 1; $i -le $script:arm_flex_instance_count; $i++) {
            Write-Host ""
            print_status "ARM instance $i configuration (remaining: ${remaining_ocpus} OCPUs, ${remaining_memory}GB RAM):"
            
            $hostname = Read-Host "$($BLUE)  Hostname [arm-instance-$i]: $($NC)"
            if ([string]::IsNullOrEmpty($hostname)) {
                $hostname = "arm-instance-$i"
            }
            $script:arm_flex_hostnames += $hostname

            $ocpus = prompt_int_range "  OCPUs (1-$remaining_ocpus)" "$remaining_ocpus" 1 $remaining_ocpus
            $script:arm_flex_ocpus_per_instance += "$ocpus "
            $remaining_ocpus -= $ocpus
            
            $max_memory = $ocpus * 6  # 6GB per OCPU max
            if ($max_memory -gt $remaining_memory) { $max_memory = $remaining_memory }

            $memory = prompt_int_range "  Memory GB (1-$max_memory)" "$max_memory" 1 $max_memory
            $script:arm_flex_memory_per_instance += "$memory "
            $remaining_memory -= $memory

            $boot = prompt_int_range "  Boot volume GB (50-200)" "50" 50 200
            $script:arm_flex_boot_volume_size_gb += "$boot "
            
            $script:arm_flex_block_volumes += 0
        }
        
        $script:arm_flex_ocpus_per_instance = $script:arm_flex_ocpus_per_instance.Trim()
        $script:arm_flex_memory_per_instance = $script:arm_flex_memory_per_instance.Trim()
        $script:arm_flex_boot_volume_size_gb = $script:arm_flex_boot_volume_size_gb.Trim()
    }
    else {
        $script:arm_flex_instance_count = 0
        $script:arm_flex_ocpus_per_instance = ''
        $script:arm_flex_memory_per_instance = ''
        $script:arm_flex_boot_volume_size_gb = ''
        $script:arm_flex_block_volumes = @()
        $script:arm_flex_hostnames = @()
    }
}

function configure_maximum_free_tier {
    print_status "Configuring maximum Free Tier utilization..."
    
    # Use all available AMD instances
    $script:amd_micro_instance_count = $script:AVAILABLE_AMD_INSTANCES
    $script:amd_micro_boot_volume_size_gb = 50
    $script:amd_micro_hostnames = @()
    for ($i = 1; $i -le $script:amd_micro_instance_count; $i++) {
        $script:amd_micro_hostnames += "amd-instance-$i"
    }
    
    # Use all available ARM resources
    if ($script:ubuntu_arm_flex_image_ocid -and $script:AVAILABLE_ARM_OCPUS -gt 0) {
        $script:arm_flex_instance_count = 1
        $script:arm_flex_ocpus_per_instance = "$script:AVAILABLE_ARM_OCPUS"
        $script:arm_flex_memory_per_instance = "$script:AVAILABLE_ARM_MEMORY"
        
        # Calculate boot volume size to use remaining storage
        $used_by_amd = $script:amd_micro_instance_count * $script:amd_micro_boot_volume_size_gb
        $remaining_storage = $script:AVAILABLE_STORAGE - $used_by_amd
        if ($remaining_storage -lt $FREE_TIER_MIN_BOOT_VOLUME_GB) { $remaining_storage = $FREE_TIER_MIN_BOOT_VOLUME_GB }
        
        $script:arm_flex_boot_volume_size_gb = "$remaining_storage"
        $script:arm_flex_hostnames = @('arm-instance-1')
        $script:arm_flex_block_volumes = @(0)
    }
    else {
        $script:arm_flex_instance_count = 0
        $script:arm_flex_ocpus_per_instance = ''
        $script:arm_flex_memory_per_instance = ''
        $script:arm_flex_boot_volume_size_gb = ''
        $script:arm_flex_hostnames = @()
        $script:arm_flex_block_volumes = @()
    }
    
    print_success "Maximum config: $($script:amd_micro_instance_count)x AMD, $($script:arm_flex_instance_count)x ARM ($script:AVAILABLE_ARM_OCPUS OCPUs, $($script:AVAILABLE_ARM_MEMORY)GB)"
}

# ============================================================================
# TERRAFORM FILE GENERATION
# ============================================================================

function create_terraform_files {
    print_header "GENERATING TERRAFORM FILES"
    
    create_terraform_provider
    create_terraform_variables
    create_terraform_datasources
    create_terraform_main
    create_terraform_block_volumes
    create_cloud_init
    
    print_success "All Terraform files generated successfully"
}

function create_terraform_provider {
    print_status "Creating provider.tf..."

    # Configure terraform backend if requested (may create backend.tf)
    configure_terraform_backend
    
    if (Test-Path 'provider.tf') {
        Copy-Item 'provider.tf' "provider.tf.bak.$((Get-Date).ToString('yyyyMMdd_HHmmss'))"
    }
    
    $providerContent = @"
# Terraform Provider Configuration for Oracle Cloud Infrastructure
# Generated: $(Get-Date)
# Region: $script:region

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
  region              = "$script:region"
}
"@
    Set-Content -Path 'provider.tf' -Value $providerContent
    
    print_success "provider.tf created"
}

function create_terraform_variables {
    print_status "Creating variables.tf..."
    
    if (Test-Path 'variables.tf') {
        Copy-Item 'variables.tf' "variables.tf.bak.$((Get-Date).ToString('yyyyMMdd_HHmmss'))"
    }
    
    # Build array strings for Terraform
    $amd_hostnames_tf = '['
    for ($i = 0; $i -lt $script:amd_micro_hostnames.Count; $i++) {
        if ($i -gt 0) { $amd_hostnames_tf += ', ' }
        $amd_hostnames_tf += "`"$($script:amd_micro_hostnames[$i])`""
    }
    $amd_hostnames_tf += ']'
    
    $arm_hostnames_tf = '['
    for ($i = 0; $i -lt $script:arm_flex_hostnames.Count; $i++) {
        if ($i -gt 0) { $arm_hostnames_tf += ', ' }
        $arm_hostnames_tf += "`"$($script:arm_flex_hostnames[$i])`""
    }
    $arm_hostnames_tf += ']'
    
    $arm_ocpus_tf = '['
    $arm_memory_tf = '['
    $arm_boot_tf = '['
    $arm_block_tf = '['
    
    if ($script:arm_flex_instance_count -gt 0) {
        # Split space-separated strings safely into arrays
        $ocpu_arr = $script:arm_flex_ocpus_per_instance -split '\s+'
        $memory_arr = $script:arm_flex_memory_per_instance -split '\s+'
        $boot_arr = $script:arm_flex_boot_volume_size_gb -split '\s+'
        
        for ($i = 0; $i -lt $ocpu_arr.Count; $i++) {
            if ($i -gt 0) { 
                $arm_ocpus_tf += ', '
                $arm_memory_tf += ', '
                $arm_boot_tf += ', '
                $arm_block_tf += ', '
            }
            $arm_ocpus_tf += $ocpu_arr[$i]
            $arm_memory_tf += $memory_arr[$i]
            $arm_boot_tf += $boot_arr[$i]
            $arm_block_tf += $script:arm_flex_block_volumes[$i]
        }
    }
    
    $arm_ocpus_tf += ']'
    $arm_memory_tf += ']'
    $arm_boot_tf += ']'
    $arm_block_tf += ']'
    
    $variablesTemplate = @'
# Oracle Cloud Infrastructure Terraform Variables
# Generated: __GENERATED_AT__
# Configuration: __AMD_COUNT__x AMD + __ARM_COUNT__x ARM instances

locals {
    # Core identifiers
    tenancy_ocid    = "__TENANCY_OCID__"
    compartment_id  = "__TENANCY_OCID__"
    user_ocid       = "__USER_OCID__"
    region          = "__REGION__"
  
    # Ubuntu Images (region-specific)
    ubuntu_x86_image_ocid = "__UBUNTU_X86_IMAGE_OCID__"
    ubuntu_arm_image_ocid = "__UBUNTU_ARM_IMAGE_OCID__"
  
    # SSH Configuration
    ssh_pubkey_path      = pathexpand("./ssh_keys/id_rsa.pub")
    ssh_pubkey_data      = file(pathexpand("./ssh_keys/id_rsa.pub"))
    ssh_private_key_path = pathexpand("./ssh_keys/id_rsa")
  
    # AMD x86 Micro Instances Configuration
    amd_micro_instance_count      = __AMD_COUNT__
    amd_micro_boot_volume_size_gb = __AMD_BOOT_GB__
    amd_micro_hostnames           = __AMD_HOSTNAMES__
    amd_block_volume_size_gb      = 0
  
    # ARM A1 Flex Instances Configuration
    arm_flex_instance_count       = __ARM_COUNT__
    arm_flex_ocpus_per_instance   = __ARM_OCPUS__
    arm_flex_memory_per_instance  = __ARM_MEMORY__
    arm_flex_boot_volume_size_gb  = __ARM_BOOT__
    arm_flex_hostnames            = __ARM_HOSTNAMES__
    arm_block_volume_sizes        = __ARM_BLOCK__
  
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
    default     = __MAX_STORAGE__
}

variable "free_tier_max_arm_ocpus" {
    description = "Maximum ARM OCPUs for Oracle Free Tier"
    type        = number
    default     = __MAX_ARM_OCPUS__
}

variable "free_tier_max_arm_memory_gb" {
    description = "Maximum ARM memory for Oracle Free Tier"
    type        = number
    default     = __MAX_ARM_MEMORY__
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
'@
    $variablesContent = $variablesTemplate
    $variablesContent = $variablesContent.Replace('__GENERATED_AT__', (Get-Date).ToString())
    $variablesContent = $variablesContent.Replace('__TENANCY_OCID__', $script:tenancy_ocid)
    $variablesContent = $variablesContent.Replace('__USER_OCID__', $script:user_ocid)
    $variablesContent = $variablesContent.Replace('__REGION__', $script:region)
    $variablesContent = $variablesContent.Replace('__UBUNTU_X86_IMAGE_OCID__', $script:ubuntu_image_ocid)
    $variablesContent = $variablesContent.Replace('__UBUNTU_ARM_IMAGE_OCID__', $script:ubuntu_arm_flex_image_ocid)
    $variablesContent = $variablesContent.Replace('__AMD_COUNT__', $script:amd_micro_instance_count)
    $variablesContent = $variablesContent.Replace('__AMD_BOOT_GB__', $script:amd_micro_boot_volume_size_gb)
    $variablesContent = $variablesContent.Replace('__AMD_HOSTNAMES__', $amd_hostnames_tf)
    $variablesContent = $variablesContent.Replace('__ARM_COUNT__', $script:arm_flex_instance_count)
    $variablesContent = $variablesContent.Replace('__ARM_OCPUS__', $arm_ocpus_tf)
    $variablesContent = $variablesContent.Replace('__ARM_MEMORY__', $arm_memory_tf)
    $variablesContent = $variablesContent.Replace('__ARM_BOOT__', $arm_boot_tf)
    $variablesContent = $variablesContent.Replace('__ARM_HOSTNAMES__', $arm_hostnames_tf)
    $variablesContent = $variablesContent.Replace('__ARM_BLOCK__', $arm_block_tf)
    $variablesContent = $variablesContent.Replace('__MAX_STORAGE__', $FREE_TIER_MAX_STORAGE_GB)
    $variablesContent = $variablesContent.Replace('__MAX_ARM_OCPUS__', $FREE_TIER_MAX_ARM_OCPUS)
    $variablesContent = $variablesContent.Replace('__MAX_ARM_MEMORY__', $FREE_TIER_MAX_ARM_MEMORY_GB)
    Set-Content -Path 'variables.tf' -Value $variablesContent
    
    print_success "variables.tf created"
}

function create_terraform_datasources {
    print_status "Creating data_sources.tf..."
    
    if (Test-Path 'data_sources.tf') {
        Copy-Item 'data_sources.tf' "data_sources.tf.bak.$((Get-Date).ToString('yyyyMMdd_HHmmss'))"
    }
    
    $dataSourcesContent = @'
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
'@
    Set-Content -Path 'data_sources.tf' -Value $dataSourcesContent
    
    print_success "data_sources.tf created"
}

function create_terraform_main {
    print_status "Creating main.tf..."
    
    if (Test-Path 'main.tf') {
        Copy-Item 'main.tf' "main.tf.bak.$((Get-Date).ToString('yyyyMMdd_HHmmss'))"
    }
    
    $mainContent = @'
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
  
  # SSH (IPv4)
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 22
      max = 22
    }
  }
  # SSH (IPv6)
  ingress_security_rules {
    protocol = "6"
    source   = "::/0"
    tcp_options {
      min = 22
      max = 22
    }
  }
  
  # HTTP (IPv4)
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 80
      max = 80
    }
  }
  # HTTP (IPv6)
  ingress_security_rules {
    protocol = "6"
    source   = "::/0"
    tcp_options {
      min = 80
      max = 80
    }
  }
  
  # HTTPS (IPv4)
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 443
      max = 443
    }
  }
  # HTTPS (IPv6)
  ingress_security_rules {
    protocol = "6"
    source   = "::/0"
    tcp_options {
      min = 443
      max = 443
    }
  }
  
  # ICMP (IPv4)
  ingress_security_rules {
    protocol = "1"
    source   = "0.0.0.0/0"
  }
  # ICMP (IPv6)
  ingress_security_rules {
    protocol = "1"
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
'@
    Set-Content -Path 'main.tf' -Value $mainContent
    
    print_success "main.tf created"
}

function create_terraform_block_volumes {
    print_status "Creating block_volumes.tf..."
    
    if (Test-Path 'block_volumes.tf') {
        Copy-Item 'block_volumes.tf' "block_volumes.tf.bak.$((Get-Date).ToString('yyyyMMdd_HHmmss'))"
    }
    
    $blockVolumesContent = @'
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
'@
    Set-Content -Path 'block_volumes.tf' -Value $blockVolumesContent
    
    print_success "block_volumes.tf created"
}

function create_cloud_init {
    print_status "Creating cloud-init.yaml..."
    
    if (Test-Path 'cloud-init.yaml') {
        Copy-Item 'cloud-init.yaml' "cloud-init.yaml.bak.$((Get-Date).ToString('yyyyMMdd_HHmmss'))"
    }
    
    $cloudInitContent = @'
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
'@
    Set-Content -Path 'cloud-init.yaml' -Value $cloudInitContent
    
    print_success "cloud-init.yaml created"
}

# ============================================================================
# TERRAFORM IMPORT AND STATE MANAGEMENT
# ============================================================================

function import_existing_resources {
    print_header "IMPORTING EXISTING RESOURCES"
    
    if ($script:EXISTING_VCNS.Count -eq 0 -and $script:EXISTING_AMD_INSTANCES.Count -eq 0 -and $script:EXISTING_ARM_INSTANCES.Count -eq 0) {
        print_status "No existing resources to import"
        return
    }
    
    # Initialize Terraform first
    print_status "Initializing Terraform..."
    & terraform init -input=false 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        print_error "Terraform init failed after retries"
        throw "Terraform init failed"
    }
    
    $imported = 0
    $failed = 0
    
    # Import VCN
    if ($script:EXISTING_VCNS.Count -gt 0) {
        $first_vcn_id = $script:EXISTING_VCNS.Keys | Select-Object -First 1
        
        if ($first_vcn_id) {
            $vcn_name = ($script:EXISTING_VCNS[$first_vcn_id] -split '\|')[0]
            print_status "Importing VCN: $vcn_name"
            
            & terraform state show oci_core_vcn.main 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                print_status "  Already in state"
            }
            else {
                & terraform import oci_core_vcn.main "$first_vcn_id" 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                print_success "  Imported successfully"
                $imported++
                
                # Import related networking resources
                import_vcn_components $first_vcn_id
            }
            else {
                print_warning "  Failed to import (see logs above)"
                $failed++
            }
            }
        }
    }
    
    # Import AMD instances
    $amd_index = 0
    foreach ($instance_id in $script:EXISTING_AMD_INSTANCES.Keys) {
        $instance_name = ($script:EXISTING_AMD_INSTANCES[$instance_id] -split '\|')[0]
        print_status "Importing AMD instance: $instance_name"
        
        & terraform state show "oci_core_instance.amd[$amd_index]" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            print_status "  Already in state"
        }
        else {
            & terraform import "oci_core_instance.amd[$amd_index]" "$instance_id" 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
            print_success "  Imported successfully"
            $imported++
        }
        else {
            print_warning "  Failed to import (see logs above)"
            $failed++
        }
        }
        
        $amd_index++
        if ($amd_index -ge $script:amd_micro_instance_count) { break }
    }
    
    # Import ARM instances
    $arm_index = 0
    foreach ($instance_id in $script:EXISTING_ARM_INSTANCES.Keys) {
        $instance_name = ($script:EXISTING_ARM_INSTANCES[$instance_id] -split '\|')[0]
        print_status "Importing ARM instance: $instance_name"

        & terraform state show "oci_core_instance.arm[$arm_index]" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            print_status "  Already in state"
        }
        else {
            & terraform import "oci_core_instance.arm[$arm_index]" "$instance_id" 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
            print_success "  Imported successfully"
            $imported++
        }
        else {
            print_warning "  Failed to import (see logs above)"
            $failed++
        }
        }
        
        $arm_index++
        if ($arm_index -ge $script:arm_flex_instance_count) { break }
    }
    
    Write-Host ""
    print_success "Import complete: $imported imported, $failed failed"
}

function import_vcn_components {
    param([string]$vcn_id)
    
    # Import Internet Gateway
    foreach ($ig_id in $script:EXISTING_INTERNET_GATEWAYS.Keys) {
        $ig_vcn = ($script:EXISTING_INTERNET_GATEWAYS[$ig_id] -split '\|')[1]
        if ($ig_vcn -eq $vcn_id) {
            & terraform state show oci_core_internet_gateway.main 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                & terraform import oci_core_internet_gateway.main "$ig_id" 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { print_status "    Imported Internet Gateway" }
            }
            break
        }
    }
    
    # Import Subnet
    foreach ($subnet_id in $script:EXISTING_SUBNETS.Keys) {
        $subnet_vcn = ($script:EXISTING_SUBNETS[$subnet_id] -split '\|')[2]
        if ($subnet_vcn -eq $vcn_id) {
            & terraform state show oci_core_subnet.main 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                & terraform import oci_core_subnet.main "$subnet_id" 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { print_status "    Imported Subnet" }
            }
            break
        }
    }
    
    # Import Route Table (default)
    foreach ($rt_id in $script:EXISTING_ROUTE_TABLES.Keys) {
        $rt_vcn = ($script:EXISTING_ROUTE_TABLES[$rt_id] -split '\|')[1]
        $rt_name = ($script:EXISTING_ROUTE_TABLES[$rt_id] -split '\|')[0]
        if ($rt_vcn -eq $vcn_id -and ($rt_name -match 'Default' -or $rt_name -match 'default')) {
            & terraform state show oci_core_default_route_table.main 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                & terraform import oci_core_default_route_table.main "$rt_id" 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { print_status "    Imported Route Table" }
            }
            break
        }
    }
    
    # Import Security List (default)
    foreach ($sl_id in $script:EXISTING_SECURITY_LISTS.Keys) {
        $sl_vcn = ($script:EXISTING_SECURITY_LISTS[$sl_id] -split '\|')[1]
        $sl_name = ($script:EXISTING_SECURITY_LISTS[$sl_id] -split '\|')[0]
        if ($sl_vcn -eq $vcn_id -and ($sl_name -match 'Default' -or $sl_name -match 'default')) {
            & terraform state show oci_core_default_security_list.main 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                & terraform import oci_core_default_security_list.main "$sl_id" 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { print_status "    Imported Security List" }
            }
            break
        }
    }
}

# ============================================================================
# TERRAFORM WORKFLOW
# ============================================================================

function run_terraform_workflow {
    print_header "TERRAFORM WORKFLOW"
    
    # Step 1: Initialize
    print_status "Step 1: Initializing Terraform..."
    try {
        & terraform init -input=false -upgrade 2>&1 | Out-Null
    }
    catch {
        print_error "Terraform init failed after retries"
        throw "Terraform init failed"
    }
    print_success "Terraform initialized"
    
    # Step 2: Import existing resources
    if ($script:EXISTING_VCNS.Count -gt 0 -or $script:EXISTING_AMD_INSTANCES.Count -gt 0 -or $script:EXISTING_ARM_INSTANCES.Count -gt 0) {
        print_status "Step 2: Importing existing resources..."
        import_existing_resources
    }
    else {
        print_status "Step 2: No existing resources to import"
    }
    
    # Step 3: Validate
    print_status "Step 3: Validating configuration..."
    try {
        & terraform validate 2>&1 | Out-Null
    }
    catch {
        print_error "Terraform validation failed"
        throw "Terraform validation failed"
    }
    print_success "Configuration valid"
    
    # Step 4: Plan
    print_status "Step 4: Creating execution plan..."
    try {
        & terraform plan -out=tfplan -input=false 2>&1 | Out-Null
    }
    catch {
        print_error "Terraform plan failed"
        throw "Terraform plan failed"
    }
    print_success "Plan created successfully"
    
    # Show plan summary
    Write-Host ""
    print_status "Plan summary:"
    try {
        & terraform show -no-color tfplan 2>&1 | Select-String -Pattern '^(Plan:|  #|will be)' | Select-Object -First 20
    }
    catch { }
    Write-Host ""
    
    # Step 5: Apply (with confirmation)
    if ($AUTO_DEPLOY -eq 'true' -or $NON_INTERACTIVE -eq 'true') {
        print_status "Step 5: Auto-applying plan..."
        $apply_choice = 'Y'
    }
    else {
        $apply_choice = Read-Host "$($BLUE)Apply this plan? [y/N]: $($NC)"
        $apply_choice = if ([string]::IsNullOrEmpty($apply_choice)) { 'N' } else { $apply_choice }
    }
    
    if ($apply_choice -match '^[Yy]$') {
        print_status "Applying Terraform plan..."
        if (out_of_capacity_auto_apply) {
            print_success "Infrastructure deployed successfully!"
            Remove-Item tfplan -ErrorAction SilentlyContinue
            
            # Show outputs
            Write-Host ""
            print_header "DEPLOYMENT COMPLETE"
            try {
                & terraform output -json | ConvertFrom-Json | ConvertTo-Json
            }
            catch {
                & terraform output
            }
        }
        else {
            print_error "Terraform apply failed"
            throw "Terraform apply failed"
        }
    }
    else {
        print_status "Plan saved as 'tfplan' - apply later with: terraform apply tfplan"
    }
    
    return $true
}

function terraform_menu {
    while ($true) {
        Write-Host ""
        print_header "TERRAFORM MANAGEMENT"
        Write-Host "  1) Full workflow (init → import → plan → apply)"
        Write-Host "  2) Plan only"
        Write-Host "  3) Apply existing plan"
        Write-Host "  4) Import existing resources"
        Write-Host "  5) Show current state"
        Write-Host "  6) Destroy infrastructure"
        Write-Host "  7) Reconfigure"
        Write-Host "  8) Exit"
        Write-Host ""
        
        if ($AUTO_DEPLOY -eq 'true' -or $NON_INTERACTIVE -eq 'true') {
            $choice = 1
            print_status "Auto mode: Running full workflow"
        }
        else {
            $raw_choice = Read-Host "$($BLUE)Choose option [1]: $($NC)"
            $choice = if ([string]::IsNullOrEmpty($raw_choice)) { 1 } else { [int]$raw_choice }
        }
        
        switch ($choice) {
            1 {
                run_terraform_workflow
                if ($AUTO_DEPLOY -eq 'true') { return $true }
            }
            2 {
                try {
                    & terraform init -input=false
                    & terraform plan
                }
                catch {
                    print_error "Terraform plan failed"
                }
            }
            3 {
                if (Test-Path 'tfplan') {
                    & terraform apply tfplan 2>&1 | Out-Null
                }
                else {
                    print_error "No plan file found"
                }
            }
            4 {
                import_existing_resources
            }
            5 {
                & terraform state list 2>&1 | Out-Null
                $state_ok = ($LASTEXITCODE -eq 0)
                & terraform output 2>&1 | Out-Null
                $output_ok = ($LASTEXITCODE -eq 0)
                if ($state_ok -and $output_ok) {
                    $null
                }
                else {
                    print_status "No state found"
                }
            }
            6 {
                if (confirm_action "DESTROY all infrastructure?" 'N') {
                    & terraform destroy 2>&1 | Out-Null
                }
            }
            7 {
                return $false  # Signal to reconfigure
            }
            8 {
                return $true
            }
            default {
                print_error "Invalid choice"
            }
        }
        
        if ($NON_INTERACTIVE -eq 'true') {
            return $true
        }
        
        Write-Host ""
        Read-Host "$($BLUE)Press Enter to continue...$($NC)"
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

function main {
    print_header "OCI TERRAFORM SETUP - IDEMPOTENT EDITION"
    print_status "This script safely manages Oracle Cloud Free Tier resources"
    print_status "Safe to run multiple times - will detect and reuse existing resources"
    Write-Host ""
    
    # Phase 1: Prerequisites
    install_prerequisites
    install_terraform
    install_oci_cli
    
    # Activate virtual environment if it exists
    if (Test-Path '.venv\Scripts\Activate.ps1') {
        & .venv\Scripts\Activate.ps1
    }
    
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
    if ($SKIP_CONFIG -ne 'true') {
        prompt_configuration
    }
    else {
        if (!(load_existing_config)) {
            configure_from_existing_instances
        }
    }
    
    # Phase 6: Generate Terraform files
    create_terraform_files
    
    # Phase 7: Terraform management
    while ($true) {
        if (terraform_menu) {
            break
        }

        # Reconfigure requested
        prompt_configuration
        create_terraform_files
    }
    
    print_header "SETUP COMPLETE"
    print_success "Oracle Cloud Free Tier infrastructure managed successfully"
    Write-Host ""
    print_status "Files created/updated:"
    print_status "  • provider.tf - OCI provider configuration"
    print_status "  • variables.tf - Instance configuration"
    print_status "  • main.tf - Infrastructure resources"
    print_status "  • data_sources.tf - OCI data sources"
    print_status "  • block_volumes.tf - Storage volumes"
    print_status "  • cloud-init.yaml - Instance initialization"
    Write-Host ""
    print_status "To manage your infrastructure:"
    print_status "  terraform plan    - Preview changes"
    print_status "  terraform apply   - Apply changes"
    print_status "  terraform destroy - Remove all resources"
}

# Execute
main

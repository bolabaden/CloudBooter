# Oracle Cloud Infrastructure (OCI) Terraform Setup Script
#
# Usage:
#   TUI mode (recommended):  .\setup_oci_terraform.ps1
#

$ErrorActionPreference = 'Stop'

# ============================================================================
# CONFIGURATION AND CONSTANTS
# ============================================================================

# TUI-first execution model
$DEBUG = if ($env:DEBUG) { $env:DEBUG } else { 'false' }
$FORCE_REAUTH = if ($env:FORCE_REAUTH) { $env:FORCE_REAUTH } else { 'false' }
$LOG_LEVEL = if ($env:LOG_LEVEL) { $env:LOG_LEVEL.ToUpperInvariant() } else { 'INFO' }
$LOG_TIMESTAMPS = if ($env:LOG_TIMESTAMPS) { $env:LOG_TIMESTAMPS } else { 'true' }
$LOG_CATALOG_SIZE = if ($env:LOG_CATALOG_SIZE) { [int]$env:LOG_CATALOG_SIZE } else { 900 }

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
$_ociHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
$OCI_CONFIG_FILE = if ($env:OCI_CONFIG_FILE) { $env:OCI_CONFIG_FILE } else { Join-Path $_ociHome '.oci' 'config' }
$OCI_PROFILE = if ($env:OCI_PROFILE) { $env:OCI_PROFILE } else { 'DEFAULT' }
$OCI_AUTH_REGION = if ($env:OCI_AUTH_REGION) { $env:OCI_AUTH_REGION } else { '' }
$OCI_CLI_CONNECTION_TIMEOUT = if ($env:OCI_CLI_CONNECTION_TIMEOUT) { [int]$env:OCI_CLI_CONNECTION_TIMEOUT } else { 10 }
$OCI_CLI_READ_TIMEOUT = if ($env:OCI_CLI_READ_TIMEOUT) { [int]$env:OCI_CLI_READ_TIMEOUT } else { 60 }
$OCI_CLI_MAX_RETRIES = if ($env:OCI_CLI_MAX_RETRIES) { [int]$env:OCI_CLI_MAX_RETRIES } else { 3 }

if (-not $env:OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING) {
    $env:OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING = 'True'
}
if (-not $env:OCI_CLI_SUPPRESS_FILE_PERMISSIONS_CHECK) {
    $env:OCI_CLI_SUPPRESS_FILE_PERMISSIONS_CHECK = 'True'
}

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

# Accessibility: disable ANSI colors when NO_COLOR is enabled
if ($env:NO_COLOR -eq '1' -or $env:NO_COLOR -eq 'true') {
    $RED = ''
    $GREEN = ''
    $YELLOW = ''
    $BLUE = ''
    $CYAN = ''
    $MAGENTA = ''
    $BOLD = ''
    $NC = ''
}

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

# TUI workflow state
$TUI_BOOTSTRAPPED = $false
$TUI_DISCOVERED = $false
$TUI_CONFIGURED = $false
$TUI_TERRAFORM_FILES_READY = $false
$TUI_CLEAR_SCREEN = if ($env:TUI_CLEAR_SCREEN) { $env:TUI_CLEAR_SCREEN } else { 'true' }
$TUI_ASCII_ONLY = if ($env:TUI_ASCII_ONLY) { $env:TUI_ASCII_ONLY } else { 'false' }
$TUI_SHOW_HINTS = if ($env:TUI_SHOW_HINTS) { $env:TUI_SHOW_HINTS } else { 'true' }
$TUI_CONCISE_LOGS = if ($env:TUI_CONCISE_LOGS) { $env:TUI_CONCISE_LOGS } else { 'true' }
$TUI_LAST_ACTION = ''
$LAST_GENERATED_CONFIG_SIGNATURE = ''

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

$LOG_LEVEL_PRIORITIES = @{
    'VERBOSE' = 10
    'DEBUG'   = 20
    'INFO'    = 30
    'SUCCESS' = 35
    'WARNING' = 40
    'ERROR'   = 50
}

$LOG_MESSAGE_CATALOG = @{}

function should_log {
    param([string]$level)

    $normalizedLevel = if ($level) { $level.ToUpperInvariant() } else { 'INFO' }
    $currentLevel = if ($LOG_LEVEL) { $LOG_LEVEL.ToUpperInvariant() } else { 'INFO' }

    if (-not $LOG_LEVEL_PRIORITIES.ContainsKey($normalizedLevel)) {
        $normalizedLevel = 'INFO'
    }
    if (-not $LOG_LEVEL_PRIORITIES.ContainsKey($currentLevel)) {
        $currentLevel = 'INFO'
    }

    return ($LOG_LEVEL_PRIORITIES[$normalizedLevel] -ge $LOG_LEVEL_PRIORITIES[$currentLevel])
}

function write_log {
    param([string]$level, [string]$message)

    $normalizedLevel = if ($level) { $level.ToUpperInvariant() } else { 'INFO' }
    if (-not (should_log $normalizedLevel)) {
        return
    }

    $labelColor = switch ($normalizedLevel) {
        'VERBOSE' { $MAGENTA }
        'DEBUG'   { $CYAN }
        'INFO'    { $BLUE }
        'SUCCESS' { $GREEN }
        'WARNING' { $YELLOW }
        'ERROR'   { $RED }
        default   { $BLUE }
    }

    $prefix = if ($LOG_TIMESTAMPS -eq 'true') {
        "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))][$normalizedLevel]"
    }
    else {
        "[$normalizedLevel]"
    }

    Write-Host "$labelColor$prefix$NC $message"
}

function initialize_log_catalog {
    if ($LOG_MESSAGE_CATALOG.Count -gt 0) {
        return
    }

    for ($i = 1; $i -le $LOG_CATALOG_SIZE; $i++) {
        $catalogLevel = switch ($i % 5) {
            0 { 'ERROR' }
            1 { 'VERBOSE' }
            2 { 'DEBUG' }
            3 { 'INFO' }
            default { 'WARNING' }
        }
        $key = ('CB-{0:D4}' -f $i)
        $LOG_MESSAGE_CATALOG[$key] = "[$catalogLevel] CloudBooter telemetry template message $i"
    }

    write_log 'DEBUG' "Initialized logging catalog with $($LOG_MESSAGE_CATALOG.Count) templates"
}

function print_verbose {
    param([string]$message)
    write_log 'VERBOSE' $message
}

function print_status {
    param([string]$message)
    write_log 'INFO' $message
}

function print_success {
    param([string]$message)
    write_log 'SUCCESS' $message
}

function print_warning {
    param([string]$message)
    write_log 'WARNING' $message
}

function print_error {
    param([string]$message)
    write_log 'ERROR' $message
}

function print_debug {
    param([string]$message)
    if ($DEBUG -eq 'true' -or $LOG_LEVEL -eq 'DEBUG' -or $LOG_LEVEL -eq 'VERBOSE') {
        write_log 'DEBUG' $message
    }
}

function prompt_with_default {
    param([string]$prompt, [string]$default_value)
    $userInput = Read-Host "$($BLUE)$prompt [$default_value]: $($NC)"
    $userInput = if ($null -eq $userInput) { '' } else { $userInput.Trim() }
    if ([string]::IsNullOrEmpty($userInput) -or $userInput -eq ':') {
        $default_value
    } else {
        $userInput
    }
}

function normalize_bool_input {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    return $Value.Trim().ToLowerInvariant()
}

function get_tui_rule {
    param([int]$Length = 64, [string]$Char = '=')
    return ($Char * $Length)
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
    $lineChar = if ($TUI_ASCII_ONLY -eq 'true') { '=' } else { '═' }
    $line = get_tui_rule 64 $lineChar
    Write-Host ""
    Write-Host "$($BOLD)$($MAGENTA)$line$($NC)"
    Write-Host "$($BOLD)$($MAGENTA)  $title$($NC)"
    Write-Host "$($BOLD)$($MAGENTA)$line$($NC)"
    Write-Host ""
}

function print_subheader {
    param([string]$title)
    $lineChar = if ($TUI_ASCII_ONLY -eq 'true') { '-' } else { '─' }
    $line = get_tui_rule 40 $lineChar
    Write-Host ""
    Write-Host "$($BOLD)$($CYAN)$line$($NC)"
    Write-Host "$($BOLD)$($CYAN)$title$($NC)"
    Write-Host "$($BOLD)$($CYAN)$line$($NC)"
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

function is_headless_environment {
    # Detect if we're in a headless (no GUI / no browser) environment.
    # PowerShell runs on Windows, macOS, and Linux — detect each.
    if ($IsLinux) {
        # Check for DISPLAY (X11) or WAYLAND_DISPLAY or SSH_CONNECTION
        if (-not $env:DISPLAY -and -not $env:WAYLAND_DISPLAY) {
            return $true
        }
        if ($env:SSH_CONNECTION -or $env:SSH_TTY) {
            return $true
        }
    }
    # On Windows and macOS, assume GUI is available
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

    try {
        if ($IsWindows -or (-not $IsLinux -and -not $IsMacOS)) {
            # Windows (including Windows PowerShell 5.x where $IsWindows may not exist)
            Start-Process $url
        }
        elseif ($IsMacOS) {
            & open $url 2>$null
        }
        else {
            # Linux — try xdg-open
            if (command_exists 'xdg-open') {
                & xdg-open $url 2>$null
            }
            else {
                return $false
            }
        }
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
    $targetSection = "[$prof]"
    $section = ''
    foreach ($rawLine in ($content -split "`n")) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrEmpty($line) -or $line.StartsWith('#') -or $line.StartsWith(';')) {
            continue
        }

        if ($line -match '^\[(.+)\]$') {
            $section = "[$($Matches[1].Trim())]"
            continue
        }

        if ($section -eq $targetSection -and $line -match "^$([regex]::Escape($key))\s*=") {
            $value = $line -replace "^$([regex]::Escape($key))\s*=", ''
            return $value.Trim()
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

    $script:auth_method = ''

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

# Resolve the full path to the oci executable, preferring the venv copy.
# Caches in $script:oci_exe so subsequent calls are fast.
function resolve_oci_exe {
    if ($script:oci_exe -and (Test-Path $script:oci_exe -ErrorAction SilentlyContinue)) {
        return $script:oci_exe
    }
    # Try Get-Command first (works when venv is activated)
    $found = Get-Command oci -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) {
        $script:oci_exe = $found.Source
        return $script:oci_exe
    }
    # Fallback: check venv Scripts/bin directly
    $venvBin = if ($IsWindows -or (-not $IsLinux -and -not $IsMacOS)) { 'Scripts' } else { 'bin' }
    $venvOci = Join-Path $PWD ".venv" $venvBin "oci"
    if ($IsWindows -or (-not $IsLinux -and -not $IsMacOS)) {
        $venvOci = Join-Path $PWD ".venv" $venvBin "oci.exe"
    }
    if (Test-Path $venvOci) {
        $script:oci_exe = $venvOci
        return $script:oci_exe
    }
    throw "Cannot find 'oci' executable. Ensure OCI CLI is installed."
}

# Tokenize a command string respecting single and double quotes.
# E.g. "--operating-system 'Canonical Ubuntu'" → @('--operating-system', 'Canonical Ubuntu')
function tokenize_cmd_string([string]$cmd) {
    $tokens = [System.Collections.Generic.List[string]]::new()
    $current = [System.Text.StringBuilder]::new()
    $inSingle = $false
    $inDouble = $false

    for ($i = 0; $i -lt $cmd.Length; $i++) {
        $c = $cmd[$i]

        if ($c -eq "'" -and -not $inDouble) {
            $inSingle = -not $inSingle
            continue          # strip the quote character itself
        }
        if ($c -eq '"' -and -not $inSingle) {
            $inDouble = -not $inDouble
            continue
        }
        if ([char]::IsWhiteSpace($c) -and -not $inSingle -and -not $inDouble) {
            if ($current.Length -gt 0) {
                $tokens.Add($current.ToString())
                $current.Clear() | Out-Null
            }
            continue
        }
        $current.Append($c) | Out-Null
    }
    if ($current.Length -gt 0) {
        $tokens.Add($current.ToString())
    }
    return [string[]]$tokens
}

# Run OCI command with proper authentication handling
function oci_cmd {
    $cmd = $args -join ' '
    $ociExe = resolve_oci_exe

    # Build argument list as a proper array so we don't need cmd /c
    $argList = @(
        '--config-file', $OCI_CONFIG_FILE,
        '--profile', $OCI_PROFILE,
        '--connection-timeout', $OCI_CLI_CONNECTION_TIMEOUT,
        '--read-timeout', $OCI_CLI_READ_TIMEOUT,
        '--max-retries', $OCI_CLI_MAX_RETRIES
    )
    if ($env:OCI_CLI_AUTH) {
        $argList += '--auth'
        $argList += $env:OCI_CLI_AUTH
    }
    elseif ($script:auth_method) {
        $argList += '--auth'
        $argList += $script:auth_method
    }
    # Append the user-supplied sub-command tokens, respecting quoted arguments
    $argList += (tokenize_cmd_string $cmd)

    # Invoke oci directly, merging stderr into stdout to avoid ErrorActionPreference='Stop'
    # from turning informational stderr lines into terminating errors.
    $allOutput = & $ociExe @argList 2>&1
    $exit_code = $LASTEXITCODE
    if ($null -eq $exit_code) { $exit_code = 0 }

    # Separate stdout (strings) from stderr (ErrorRecord objects)
    $stdout = ($allOutput | Where-Object { $_ -is [string] }) -join "`n"
    $stderr = ($allOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join "`n"

    if ($exit_code -eq 0) {
        return $stdout
    }
    if ($exit_code -eq 124 -or $exit_code -eq -1) {
        print_warning "OCI CLI call timed out after ${OCI_CMD_TIMEOUT}s"
    }

    throw "OCI command failed (exit $exit_code): $stderr $stdout"
}

# Safe JSON parsing using PowerShell native parsing (no jq required)
function safe_jq {
    param([string]$json, [string]$query, [string]$default = '')
    if ([string]::IsNullOrEmpty($json) -or $json -eq 'null') {
        return $default
    }
    try {
        # Parse JSON
        $obj = $json | ConvertFrom-Json -ErrorAction Stop
        
        # Parse jq-like query and navigate the object
        # Supports: .property, ."property-with-dashes", [index], nested paths
        $result = $obj
        
        # Remove leading dot if present
        $query = $query.TrimStart('.')
        
        # Split by dots, but respect quoted strings and brackets
        $tokens = @()
        $current = ''
        $inQuotes = $false
        $inBrackets = $false
        
        for ($i = 0; $i -lt $query.Length; $i++) {
            $char = $query[$i]
            
            if ($char -eq '"') {
                $inQuotes = -not $inQuotes
                continue
            }
            
            if ($char -eq '[' -and -not $inQuotes) {
                if ($current) {
                    $tokens += $current
                    $current = ''
                }
                $inBrackets = $true
                $current = '['
                continue
            }
            
            if ($char -eq ']' -and -not $inQuotes) {
                $current += ']'
                $tokens += $current
                $current = ''
                $inBrackets = $false
                continue
            }
            
            if ($char -eq '.' -and -not $inQuotes -and -not $inBrackets) {
                if ($current) {
                    $tokens += $current
                    $current = ''
                }
                continue
            }
            
            $current += $char
        }
        
        if ($current) {
            $tokens += $current
        }
        
        # Navigate through tokens
        foreach ($token in $tokens) {
            if ([string]::IsNullOrEmpty($token)) { continue }
            
            # Handle array index like [0]
            if ($token -match '^\[(\d+)\]$') {
                $index = [int]$matches[1]
                if ($result -is [array] -and $index -lt $result.Count) {
                    $result = $result[$index]
                } else {
                    return $default
                }
            }
            # Handle property access
            else {
                $propName = $token
                # Handle properties with dashes or special characters
                if ($result.PSObject.Properties[$propName]) {
                    $result = $result.$propName
                } else {
                    return $default
                }
            }
        }
        
        # Convert result to string
        if ($null -eq $result -or $result -eq 'null') {
            return $default
        }
        
        return $result.ToString()
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
            # Use Invoke-Expression for cross-platform command execution
            $out = Invoke-Expression "$cmd 2>&1" -ErrorAction SilentlyContinue
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
            & terraform apply tfplan 2>&1 | Tee-Object -Variable out | Out-Null
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
    $yn_prompt = if ($default -eq 'Y') { '[Y/n]' } else { '[y/N]' }
    $response = Read-Host "$($BLUE)$prompt $yn_prompt`: $($NC)"
    $normalized = normalize_bool_input $(if ([string]::IsNullOrEmpty($response)) { $default } else { $response })
    return ($normalized -match '^(y|yes)$')
}

# ============================================================================
# INSTALLATION FUNCTIONS
# ============================================================================

function install_prerequisites {
    print_subheader "Installing Prerequisites"
    
    # Check for ssh-keygen (required for SSH key generation)
    if (!(command_exists 'ssh-keygen')) {
        print_status "ssh-keygen not found. Attempting to install OpenSSH..."
        
        # Try to enable OpenSSH client on Windows
        try {
            $sshClient = Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Client*'
            if ($sshClient.State -ne 'Installed') {
                print_status "Installing OpenSSH Client via Windows capabilities..."
                Add-WindowsCapability -Online -Name $sshClient.Name -ErrorAction Stop | Out-Null
                print_success "OpenSSH Client installed successfully"
            }
        }
        catch {
            print_warning "Could not install OpenSSH via Windows capabilities: $_"
            
            # Try chocolatey as fallback
            if (command_exists 'choco') {
                print_status "Attempting to install openssh via Chocolatey..."
                try {
                    & choco install openssh --yes --no-progress 2>&1 | Out-Null
                    print_success "OpenSSH installed via Chocolatey"
                }
                catch {
                    print_error "Failed to install OpenSSH. Please install manually:"
                    print_error "  Option 1: Run as Administrator: Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0"
                    print_error "  Option 2: Install via Chocolatey: choco install openssh"
                    print_error "  Option 3: Download from: https://github.com/PowerShell/Win32-OpenSSH/releases"
                    throw "Missing required command: ssh-keygen"
                }
            }
            else {
                print_error "ssh-keygen is required but not found. Please install OpenSSH:"
                print_error "  Option 1: Run as Administrator: Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0"
                print_error "  Option 2: Install via Chocolatey: choco install openssh"
                print_error "  Option 3: Download from: https://github.com/PowerShell/Win32-OpenSSH/releases"
                throw "Missing required command: ssh-keygen"
            }
        }
        
        # Verify installation
        if (!(command_exists 'ssh-keygen')) {
            print_error "ssh-keygen still not available after installation attempt"
            throw "Missing required command: ssh-keygen"
        }
    }
    else {
        print_status "ssh-keygen is available"
    }
    
    # Check for unzip (used by Terraform installation)
    if (!(command_exists 'unzip')) {
        print_status "unzip not found, but PowerShell Expand-Archive can be used as fallback"
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
    
    # Also check inside the venv directly (venv might not be activated yet)
    $venvBin = if ($IsWindows -or (-not $IsLinux -and -not $IsMacOS)) { 'Scripts' } else { 'bin' }
    $venvOciExe = Join-Path $PWD '.venv' $venvBin 'oci'
    if ($IsWindows -or (-not $IsLinux -and -not $IsMacOS)) {
        $venvOciExe = Join-Path $PWD '.venv' $venvBin 'oci.exe'
    }
    if (Test-Path $venvOciExe) {
        $version = try { & $venvOciExe --version 2>$null | Select-Object -First 1 } catch { 'unknown' }
        print_status "OCI CLI found in venv: $version"
        return
    }
    
    print_status "Installing OCI CLI..."
    
    # Determine Python command: prefer 'python' on Windows, 'python3' on Unix
    $pythonCmd = $null
    if ($IsWindows -or (-not $IsLinux -and -not $IsMacOS)) {
        # On Windows, 'python3' is often a MS Store stub — prefer 'python'
        foreach ($candidate in @('python', 'python3')) {
            $found = Get-Command $candidate -ErrorAction SilentlyContinue
            if ($found -and $found.Source -notmatch 'WindowsApps') {
                $pythonCmd = $candidate
                break
            }
        }
    }
    else {
        foreach ($candidate in @('python3', 'python')) {
            if (command_exists $candidate) {
                $pythonCmd = $candidate
                break
            }
        }
    }
    if (-not $pythonCmd) {
        print_error "Python is required but not found. Please install Python 3."
        throw "Python not found"
    }
    
    # Create virtual environment for OCI CLI
    $venv_dir = '.venv'
    if (!(Test-Path $venv_dir)) {
        print_status "Creating Python virtual environment..."
        & $pythonCmd -m venv $venv_dir
    }
    elseif (!(Test-Path (Join-Path $venv_dir 'pyvenv.cfg'))) {
        # Venv directory exists but is corrupted (missing pyvenv.cfg), recreate it
        print_warning "Virtual environment appears corrupted (missing pyvenv.cfg). Recreating..."
        Remove-Item $venv_dir -Recurse -Force
        & $pythonCmd -m venv $venv_dir
    }
    
    # Activate virtual environment (cross-platform)
    $activateScript = Join-Path $PWD $venv_dir $venvBin 'Activate.ps1'
    if (Test-Path $activateScript) {
        & $activateScript
    }
    else {
        print_error "Could not find activation script at $activateScript"
        throw "Venv activation failed"
    }
    
    # After activation, use the venv's own python to ensure correct pip context
    $venvPython = Join-Path $PWD $venv_dir $venvBin 'python'
    if ($IsWindows -or (-not $IsLinux -and -not $IsMacOS)) {
        $venvPython = Join-Path $PWD $venv_dir $venvBin 'python.exe'
    }
    
    print_status "Installing OCI CLI in virtual environment..."
    & $venvPython -m pip install --upgrade pip --quiet 2>&1 | Out-Null
    & $venvPython -m pip install oci-cli --quiet
    
    # Verify installation
    if (Test-Path $venvOciExe) {
        print_success "OCI CLI installed successfully"
    }
    elseif (command_exists 'oci') {
        print_success "OCI CLI installed successfully"
    }
    else {
        print_error "OCI CLI installation completed but 'oci' executable not found"
        throw "OCI CLI installation failed"
    }
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

function ensure_oci_config_bootstrap {
    param(
        [string]$ConfigPath,
        [string]$ProfileName,
        [string]$RegionHint
    )

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        throw "OCI config path is empty"
    }

    $effectiveProfile = if ([string]::IsNullOrWhiteSpace($ProfileName)) { 'DEFAULT' } else { $ProfileName }
    $effectiveRegion = if ([string]::IsNullOrWhiteSpace($RegionHint)) { default_region_for_host } else { $RegionHint }
    $configDir = Split-Path -Parent $ConfigPath

    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }

    if (-not (Test-Path $ConfigPath)) {
        print_warning "OCI config file missing at $ConfigPath. Creating bootstrap profile [$effectiveProfile]."
        $bootstrapContent = @"
[$effectiveProfile]
region=$effectiveRegion
"@
        Set-Content -Path $ConfigPath -Value $bootstrapContent
        print_debug "Bootstrapped OCI config at $ConfigPath"
        return
    }

    $content = Get-Content $ConfigPath -Raw
    if ($content -notmatch "(?m)^\[$([regex]::Escape($effectiveProfile))\]\s*$") {
        print_warning "OCI profile [$effectiveProfile] not present in $ConfigPath. Appending bootstrap profile section."
        Add-Content -Path $ConfigPath -Value "`n[$effectiveProfile]`nregion=$effectiveRegion`n"
    }
}

function normalize_auth_region {
    param([string]$regionInput)

    $candidate = if ($null -eq $regionInput) { '' } else { $regionInput.Trim() }
    if ($candidate -eq ':' -or [string]::IsNullOrWhiteSpace($candidate)) {
        return (default_region_for_host)
    }

    if ($candidate -match '^[a-z]{2}-[a-z0-9-]+-\d+$') {
        return $candidate
    }

    print_warning "Invalid region input '$candidate'. Falling back to default region."
    return (default_region_for_host)
}

# ── Cross-platform OCI session authenticate helper ──
# Uses --no-browser universally so stderr informational output never triggers
# PowerShell's ErrorActionPreference='Stop' terminating-error behavior.
# Extracts the login URL from the CLI output, opens the browser ourselves,
# then waits for the user to complete login (the CLI blocks until done).
#
# Parameters:
#   -ProfileName  : OCI profile name
#   -Region       : OCI region string
#   -ReturnOutput : (switch) If set, returns a hashtable {Stdout, Stderr, ExitCode}
#                   instead of throwing on failure. Useful for callers that need to
#                   inspect the output for config-error detection.
function invoke_oci_session_authenticate {
    param(
        [string]$ProfileName,
        [string]$Region,
        [switch]$ReturnOutput
    )

    $ociExe = resolve_oci_exe

    # Build argument list
    $argList = @(
        '--config-file', $script:OCI_CONFIG_FILE,
        'session', 'authenticate',
        '--no-browser',
        '--profile-name', $ProfileName,
        '--region', $Region,
        '--session-expiration-in-minutes', '60'
    )

    print_status "Launching OCI session authentication (--no-browser mode)..."
    print_status "The CLI will print a URL. Please open it in your browser to log in."
    Write-Host ""

    # Strategy: launch the process with redirected stdout/stderr, then poll both
    # streams from the MAIN thread using ReadLineAsync(). This avoids the broken
    # Register-ObjectEvent approach where event-handler scriptblocks run in a
    # separate runspace and cannot call Write-Host / Start-Process reliably.

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $ociExe
    # Use ArgumentList (collection) for proper quoting on all platforms (.NET 5+)
    foreach ($a in $argList) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi

    $stdoutLines = [System.Collections.Generic.List[string]]::new()
    $stderrLines = [System.Collections.Generic.List[string]]::new()
    $browserOpened = $false

    try {
        $proc.Start() | Out-Null

        $stdoutReader = $proc.StandardOutput
        $stderrReader = $proc.StandardError

        # Kick off the first async reads
        $stdoutTask = $stdoutReader.ReadLineAsync()
        $stderrTask = $stderrReader.ReadLineAsync()
        $stdoutDone = $false
        $stderrDone = $false

        # Poll both streams from the main thread
        while (-not ($stdoutDone -and $stderrDone)) {
            # --- stdout ---
            if (-not $stdoutDone -and $stdoutTask.IsCompleted) {
                $line = $stdoutTask.Result
                if ($null -eq $line) {
                    $stdoutDone = $true
                }
                else {
                    $stdoutLines.Add($line)
                    Write-Host $line
                    if (-not $browserOpened -and $line -match '(https://[^\s]+)') {
                        open_url_best_effort $Matches[1]
                        $browserOpened = $true
                    }
                    $stdoutTask = $stdoutReader.ReadLineAsync()
                }
            }

            # --- stderr ---
            if (-not $stderrDone -and $stderrTask.IsCompleted) {
                $line = $stderrTask.Result
                if ($null -eq $line) {
                    $stderrDone = $true
                }
                else {
                    $stderrLines.Add($line)
                    Write-Host $line
                    if (-not $browserOpened -and $line -match '(https://[^\s]+)') {
                        open_url_best_effort $Matches[1]
                        $browserOpened = $true
                    }
                    $stderrTask = $stderrReader.ReadLineAsync()
                }
            }

            if (-not ($stdoutDone -and $stderrDone)) {
                Start-Sleep -Milliseconds 150
            }
        }

        $proc.WaitForExit()
        $exitCode = $proc.ExitCode
    }
    finally {
        $proc.Dispose()
    }

    $stdoutStr = $stdoutLines -join "`n"
    $stderrStr = $stderrLines -join "`n"

    if ($ReturnOutput) {
        return @{
            Stdout   = $stdoutStr
            Stderr   = $stderrStr
            ExitCode = $exitCode
        }
    }

    if ($exitCode -ne 0) {
        print_error "Browser-based authentication failed. Please verify your Oracle Cloud credentials and try again."
        print_error "Exit code: $exitCode"
        if ($stderrStr) { print_error "Details: $stderrStr" }
        throw "Authentication failed"
    }

    print_success "Browser authentication completed successfully"
}

function invoke_oci_setup_bootstrap {
    param(
        [string]$ProfileName,
        [string]$ConfigPath,
        [string]$Region,
        [switch]$ReturnOutput
    )

    $ociExe = resolve_oci_exe
    if ([string]::IsNullOrWhiteSpace($Region)) {
        $Region = default_region_for_host
    }

    $argList = @(
        '--region', $Region,
        'setup', 'bootstrap',
        '--profile-name', $ProfileName,
        '--config-location', $ConfigPath
    )

    print_status "Launching OCI setup bootstrap (automated, browser-login only)..."
    print_status "Region: $Region"
    print_status "Private key passphrase: none (auto-set N/A)"
    print_status "A browser window will open for Oracle Cloud login."
    Write-Host ""

    $stdoutStr = ''
    $stderrStr = ''
    $exitCode = 1
    $proc = $null

    try {
        # Redirect ONLY stdin so we can pre-fill region + passphrase answers.
        # stdout/stderr go directly to the console so the user sees progress
        # and the OCI CLI can open the browser itself.
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $ociExe
        foreach ($a in $argList) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $false
        $psi.RedirectStandardError  = $false

        $proc = [System.Diagnostics.Process]::new()
        $proc.StartInfo = $psi
        $proc.Start() | Out-Null

        # Pre-fill expected interactive prompts via stdin so no manual typing
        # is needed (except browser authentication itself). We include many
        # passphrase entries because OCI may re-prompt for confirmation.
        $proc.StandardInput.WriteLine('N/A')
        $proc.StandardInput.WriteLine('N/A')
        $proc.StandardInput.WriteLine('N/A')
        $proc.StandardInput.WriteLine('N/A')
        $proc.StandardInput.WriteLine('N/A')
        $proc.StandardInput.WriteLine('N/A')
        $proc.StandardInput.WriteLine('N/A')
        $proc.StandardInput.WriteLine('N/A')
        $proc.StandardInput.Close()

        $proc.WaitForExit()
        $exitCode = $proc.ExitCode
        if ($null -eq $exitCode) { $exitCode = 0 }
    }
    catch {
        $stderrStr = $_.Exception.Message
        $exitCode = 1
    }
    finally {
        if ($proc) { $proc.Dispose() }
    }

    if ($ReturnOutput) {
        return @{
            Stdout   = $stdoutStr
            Stderr   = $stderrStr
            ExitCode = $exitCode
        }
    }

    if ($exitCode -ne 0) {
        print_error "OCI setup bootstrap failed"
        print_error "Exit code: $exitCode"
        if ($stderrStr) { print_error "Details: $stderrStr" }
        throw "Bootstrap authentication failed"
    }

    print_success "OCI setup bootstrap completed successfully"
}

function setup_oci_config {
    print_subheader "OCI Authentication"
    
    # Cross-platform home directory for .oci config
    $ociDir = if ($env:USERPROFILE) { "$env:USERPROFILE\.oci" } else { "$env:HOME/.oci" }
    New-Item -ItemType Directory -Path $ociDir -Force | Out-Null
    
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
            if (wait_for_oci_connectivity) {
                print_success "Existing OCI configuration is valid"
                return
            }
        }
    }
    
    # Setup new authentication
    print_status "Setting up browser-based authentication..."
    print_status "This will open a browser window for you to log in to Oracle Cloud."

    # Determine region to use for browser login (auto-detected, no prompt).
    $auth_region = read_oci_config_value 'region' $OCI_CONFIG_FILE $OCI_PROFILE
    $auth_region = if ($auth_region) { $auth_region } else { $OCI_AUTH_REGION }
    $auth_region = if ($auth_region) { $auth_region } else { default_region_for_host }
    $auth_region = normalize_auth_region $auth_region
    print_status "Using region: $auth_region"

    $env:OCI_CLI_CONFIG_FILE = $OCI_CONFIG_FILE

    # --- Helper: delete corrupted config and prepare for fresh auth ---
    $delete_and_prepare_fresh_config = {
        param([string]$reason)
        print_warning "$reason - AUTOMATICALLY DELETING AND FORCING FRESH AUTHENTICATION"
        if (Test-Path $OCI_CONFIG_FILE) {
            print_status "Backing up corrupted config to $OCI_CONFIG_FILE.corrupted.$((Get-Date).ToString('yyyyMMdd_HHmmss'))"
            Copy-Item $OCI_CONFIG_FILE "$OCI_CONFIG_FILE.corrupted.$((Get-Date).ToString('yyyyMMdd_HHmmss'))" -ErrorAction SilentlyContinue
            print_status "Forcibly deleting corrupted config file: $OCI_CONFIG_FILE"
            Remove-Item $OCI_CONFIG_FILE -Force
        }
        $sessionAuthFile = Join-Path $ociDir 'config.session_auth'
        Remove-Item $sessionAuthFile -ErrorAction SilentlyContinue
        $script:OCI_CONFIG_FILE = Join-Path $ociDir 'config'
        $script:OCI_PROFILE = 'DEFAULT'
        $env:OCI_CLI_CONFIG_FILE = $null
    }

    # Allow forcing re-auth / new profile
    if ($FORCE_REAUTH -eq 'true') {
        $new_profile = 'DEFAULT'
        print_status "Starting authentication setup for profile '$new_profile'..."
        print_status "Using region '$auth_region' for authentication"

        invoke_oci_setup_bootstrap -ProfileName $new_profile -ConfigPath $OCI_CONFIG_FILE -Region $auth_region
        detect_auth_method

        print_status "Authentication for profile '$new_profile' completed. Updating OCI_PROFILE to use it."
        $script:OCI_PROFILE = $new_profile

        if ($existing_config_invalid) {
            & $delete_and_prepare_fresh_config "Detected invalid or incomplete OCI config file during forced re-auth"
            $new_profile = 'DEFAULT'
            print_status "Creating fresh OCI configuration with browser-based authentication for profile '$new_profile'..."
            Write-Host ""
            print_status "Using region '$auth_region' for authentication"
            Write-Host ""

            invoke_oci_setup_bootstrap -ProfileName $new_profile -ConfigPath $script:OCI_CONFIG_FILE -Region $auth_region
            detect_auth_method
            if (wait_for_oci_connectivity) {
                print_success "Fresh session authentication succeeded for profile '$new_profile'"
                return
            }
            else {
                print_warning "Session auth completed but connectivity test failed"
            }
        }

        if (wait_for_oci_connectivity) {
            print_success "OCI authentication configured successfully for profile '$new_profile'"
            return
        }
        else {
            print_warning "Authentication succeeded but connectivity test failed for profile '$new_profile'"
        }
    }
    else {
        # If existing config is missing/invalid, go straight to bootstrap.
        if ($existing_config_invalid -or -not (Test-Path $OCI_CONFIG_FILE)) {
            if ($existing_config_invalid) {
                & $delete_and_prepare_fresh_config "Detected invalid or incomplete OCI config file"
            }
            $new_profile = 'DEFAULT'
            print_status "Creating fresh OCI configuration with browser-based authentication for profile '$new_profile'..."
            print_status "This will open your browser to log into Oracle Cloud."
            Write-Host ""
            invoke_oci_setup_bootstrap -ProfileName $new_profile -ConfigPath $script:OCI_CONFIG_FILE -Region $auth_region
            detect_auth_method
            if (wait_for_oci_connectivity) {
                print_success "Fresh authentication succeeded for profile '$new_profile'"
                return
            }
            print_warning "Authentication completed but connectivity test failed"
            throw "Authentication failed"
        }

        # Interactive authenticate (may open browser)
        print_status "Using profile '$script:OCI_PROFILE' for interactive session authenticate..."
        print_status "Using region '$auth_region' for authentication"
        ensure_oci_config_bootstrap -ConfigPath $OCI_CONFIG_FILE -ProfileName $script:OCI_PROFILE -RegionHint $auth_region

        $authResult = invoke_oci_session_authenticate -ProfileName $script:OCI_PROFILE -Region $auth_region -ReturnOutput

        # Check if the auth output indicates an invalid config (so we can offer repair)
        if ($authResult.ExitCode -ne 0) {
            $combinedOut = "$($authResult.Stdout)`n$($authResult.Stderr)"
            if ($combinedOut -match '(?i)config file.*is invalid|Config Errors|user .*missing') {
                print_warning "OCI CLI reports the profile requires full API-key fields. Falling back to setup bootstrap flow..."
                & $delete_and_prepare_fresh_config "Detected invalid or incomplete OCI config file"
                $bootstrapResult = invoke_oci_setup_bootstrap -ProfileName $script:OCI_PROFILE -ConfigPath $OCI_CONFIG_FILE -Region $auth_region -ReturnOutput
                if ($bootstrapResult.ExitCode -ne 0) {
                    print_error "Bootstrap fallback failed"
                    throw "Authentication failed"
                }

                detect_auth_method
                if (wait_for_oci_connectivity) {
                    print_success "OCI authentication configured successfully via bootstrap"
                    return
                }
                else {
                    print_warning "Bootstrap completed but connectivity test failed"
                    throw "Authentication failed"
                }
            }
            else {
                print_error "Browser authentication failed or was cancelled"
                throw "Authentication failed"
            }
        }

        # If we got here without returning, then authentication succeeded but connectivity might have issues
        $script:auth_method = 'security_token'

        if (wait_for_oci_connectivity) {
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

function wait_for_oci_connectivity {
    param(
        [int]$MaxAttempts = 12,
        [int]$DelaySeconds = 10
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        print_status "Connectivity verification attempt $attempt/$MaxAttempts..."
        if (test_oci_connectivity) {
            return $true
        }

        if ($attempt -lt $MaxAttempts) {
            print_warning "OCI credentials not active yet; retrying in ${DelaySeconds}s..."
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    return $false
}

# ============================================================================
# OCI RESOURCE DISCOVERY FUNCTIONS
# ============================================================================

function fetch_oci_config_values {
    print_subheader "Fetching OCI Configuration"

    # Read values from active profile using robust parser
    $script:tenancy_ocid = read_oci_config_value 'tenancy' $OCI_CONFIG_FILE $OCI_PROFILE
    if ([string]::IsNullOrEmpty($script:tenancy_ocid)) {
        print_error "Failed to fetch tenancy OCID from config"
        throw "Failed to fetch tenancy OCID"
    }
    print_status "Tenancy OCID: $script:tenancy_ocid"

    # User OCID
    $script:user_ocid = read_oci_config_value 'user' $OCI_CONFIG_FILE $OCI_PROFILE
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
    $script:region = read_oci_config_value 'region' $OCI_CONFIG_FILE $OCI_PROFILE
    if ([string]::IsNullOrEmpty($script:region)) {
        $script:region = default_region_for_host
        print_warning "Region not found in profile. Falling back to '$script:region'."
    }
    $script:region = normalize_auth_region $script:region
    print_status "Region: $script:region"

    # Fingerprint (only for API key auth)
    if ($script:auth_method -eq 'security_token') {
        $script:fingerprint = 'session_token_auth'
    }
    else {
        $script:fingerprint = read_oci_config_value 'fingerprint' $OCI_CONFIG_FILE $OCI_PROFILE
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
    
    # Parse first AD from either JSON array output or raw newline output.
    try {
        $trimmedAdList = $ad_list.Trim()
        if ($trimmedAdList.StartsWith('[')) {
            $parsedAds = $trimmedAdList | ConvertFrom-Json -ErrorAction Stop
            if ($parsedAds -is [array] -and $parsedAds.Count -gt 0) {
                $script:availability_domain = "$($parsedAds[0])".Trim()
            }
        }

        if ([string]::IsNullOrWhiteSpace($script:availability_domain)) {
            $ad_array = $ad_list -split '\r?\n' | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { ![string]::IsNullOrWhiteSpace($_) -and $_ -notin @('[', ']') }
            if ($ad_array.Count -gt 0) {
                $script:availability_domain = $ad_array[0]
            }
        }
    }
    catch {
        $script:availability_domain = $ad_list.Trim()
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
        $x86_images = oci_cmd "compute image list --compartment-id $script:tenancy_ocid --operating-system 'Canonical Ubuntu' --shape '$FREE_TIER_AMD_SHAPE' --sort-by TIMECREATED --sort-order DESC --all"
    }
    catch {
        $x86_images = '{"data":[]}'
    }
    
    $script:ubuntu_image_ocid = safe_jq $x86_images '.data.[0].id' ''
    $x86_name = safe_jq $x86_images '.data.[0].display-name' ''
    
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
        $arm_images = oci_cmd "compute image list --compartment-id $script:tenancy_ocid --operating-system 'Canonical Ubuntu' --shape '$FREE_TIER_ARM_SHAPE' --sort-by TIMECREATED --sort-order DESC --all"
    }
    catch {
        $arm_images = '{"data":[]}'
    }
    
    $script:ubuntu_arm_flex_image_ocid = safe_jq $arm_images '.data.[0].id' ''
    $arm_name = safe_jq $arm_images '.data.[0].display-name' ''
    
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
    
    $keyPath = Join-Path $ssh_dir 'id_rsa'
    $pubPath = Join-Path $ssh_dir 'id_rsa.pub'
    
    if (!(Test-Path $keyPath)) {
        print_status "Generating new SSH key pair..."
        & ssh-keygen -t rsa -b 4096 -f $keyPath -N '' -q
        print_success "SSH key pair generated at $ssh_dir/"
    }
    else {
        print_status "Using existing SSH key pair at $ssh_dir/"
    }
    
    # exported for Terraform/template consumption
    $script:ssh_public_key = Get-Content $pubPath -Raw
}

# ============================================================================
# RESOURCE INVENTORY
# ============================================================================

function inventory_all_resources {
    print_header "RESOURCE INVENTORY"
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
    
    Write-Host "$($BOLD)Compute Resources:$($NC)"
    Write-Host "  ┌─────────────────────────────────────────────────────────────┐"
    Write-Host "  │ AMD Micro Instances:  $total_amd / $FREE_TIER_MAX_AMD_INSTANCES (Free Tier limit)          │"
    Write-Host "  │ ARM A1 Instances:     $total_arm / $FREE_TIER_MAX_ARM_INSTANCES (up to)                    │"
    Write-Host "  │ ARM OCPUs Used:       $total_arm_ocpus / $FREE_TIER_MAX_ARM_OCPUS                           │"
    Write-Host "  │ ARM Memory Used:      ${total_arm_memory}GB / ${FREE_TIER_MAX_ARM_MEMORY_GB}GB                         │"
    Write-Host "  └─────────────────────────────────────────────────────────────┘"
    Write-Host ""
    Write-Host "$($BOLD)Storage Resources:$($NC)"
    Write-Host "  ┌─────────────────────────────────────────────────────────────┐"
    Write-Host "  │ Boot Volumes:         ${total_boot_gb}GB                                    │"
    Write-Host "  │ Block Volumes:        ${total_block_gb}GB                                    │"
    Write-Host ("  │ Total Storage:        {0,3}GB / {1,3}GB Free Tier limit          │" -f $total_storage, $FREE_TIER_MAX_STORAGE_GB)
    Write-Host "  └─────────────────────────────────────────────────────────────┘"
    Write-Host ""
    Write-Host "$($BOLD)Networking Resources:$($NC)"
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

function sum_numeric_tokens {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return 0
    }

    $sum = 0
    foreach ($token in ($Value -split '\s+')) {
        if ($token -match '^\d+$') {
            $sum += [int]$token
        }
    }

    return $sum
}

function get_deployed_state_summary {
    $total_arm_ocpus = 0
    $total_arm_memory = 0
    foreach ($instance_data in $script:EXISTING_ARM_INSTANCES.Values) {
        $parts = $instance_data -split '\|'
        if ($parts.Count -ge 7) {
            $ocpus = 0
            $memory = 0
            [void][int]::TryParse($parts[5], [ref]$ocpus)
            [void][int]::TryParse($parts[6], [ref]$memory)
            $total_arm_ocpus += $ocpus
            $total_arm_memory += $memory
        }
    }

    $total_boot_gb = 0
    foreach ($boot_data in $script:EXISTING_BOOT_VOLUMES.Values) {
        $parts = $boot_data -split '\|'
        if ($parts.Count -ge 2) {
            $size = 0
            [void][int]::TryParse($parts[1], [ref]$size)
            $total_boot_gb += $size
        }
    }

    $total_block_gb = 0
    foreach ($block_data in $script:EXISTING_BLOCK_VOLUMES.Values) {
        $parts = $block_data -split '\|'
        if ($parts.Count -ge 2) {
            $size = 0
            [void][int]::TryParse($parts[1], [ref]$size)
            $total_block_gb += $size
        }
    }

    return @{
        AmdCount    = [int]$script:EXISTING_AMD_INSTANCES.Count
        ArmCount    = [int]$script:EXISTING_ARM_INSTANCES.Count
        ArmOcpus    = $total_arm_ocpus
        ArmMemoryGb = $total_arm_memory
        StorageGb   = ($total_boot_gb + $total_block_gb)
        Vcns        = [int]$script:EXISTING_VCNS.Count
    }
}

function get_desired_config_summary {
    $arm_boot_total = sum_numeric_tokens $script:arm_flex_boot_volume_size_gb
    $amd_boot_total = [int]$script:amd_micro_instance_count * [int]$script:amd_micro_boot_volume_size_gb

    $amd = [int]$script:amd_micro_instance_count
    $arm = [int]$script:arm_flex_instance_count
    $armOcpus = sum_numeric_tokens $script:arm_flex_ocpus_per_instance
    $armMemory = sum_numeric_tokens $script:arm_flex_memory_per_instance
    $storage = $amd_boot_total + $arm_boot_total

    return @{
        AmdCount    = $amd
        ArmCount    = $arm
        ArmOcpus    = $armOcpus
        ArmMemoryGb = $armMemory
        StorageGb   = $storage
        IsEmpty     = ($amd -eq 0 -and $arm -eq 0 -and $armOcpus -eq 0 -and $armMemory -eq 0)
    }
}

function get_config_drift_summary {
    param(
        [hashtable]$Deployed,
        [hashtable]$Desired
    )

    if ($Desired.IsEmpty) {
        return "Desired config not set yet"
    }

    $diff = @()
    if ($Desired.AmdCount -ne $Deployed.AmdCount) { $diff += "AMD count" }
    if ($Desired.ArmCount -ne $Deployed.ArmCount) { $diff += "ARM count" }
    if ($Desired.ArmOcpus -ne $Deployed.ArmOcpus) { $diff += "ARM OCPUs" }
    if ($Desired.ArmMemoryGb -ne $Deployed.ArmMemoryGb) { $diff += "ARM memory" }

    if ($diff.Count -eq 0) {
        return "Desired config matches deployed compute shape"
    }

    return "Differences detected: " + ($diff -join ', ')
}

function get_desired_config_signature {
    return "amd=$($script:amd_micro_instance_count)|amdBoot=$($script:amd_micro_boot_volume_size_gb)|arm=$($script:arm_flex_instance_count)|armOcpus=$($script:arm_flex_ocpus_per_instance)|armMem=$($script:arm_flex_memory_per_instance)|armBoot=$($script:arm_flex_boot_volume_size_gb)|amdHosts=$($script:amd_micro_hostnames -join ',')|armHosts=$($script:arm_flex_hostnames -join ',')"
}

# ── Compact status display helpers ──

function has_terraform_files {
    return (Test-Path 'provider.tf') -and (Test-Path 'variables.tf') -and (Test-Path 'main.tf')
}

function get_config_one_liner {
    if (-not $script:TUI_CONFIGURED) {
        if (Test-Path 'variables.tf') { return '(variables.tf exists, not loaded yet)' }
        return 'Not configured (defaults apply on first deploy)'
    }

    $parts = @()
    if ([int]$script:arm_flex_instance_count -gt 0) {
        $ocpus = $script:arm_flex_ocpus_per_instance
        $mem = $script:arm_flex_memory_per_instance
        $boot = $script:arm_flex_boot_volume_size_gb
        $parts += "$($script:arm_flex_instance_count)x ARM ($ocpus OCPU, ${mem}GB RAM, ${boot}GB boot)"
    }
    if ([int]$script:amd_micro_instance_count -gt 0) {
        $parts += "$($script:amd_micro_instance_count)x AMD (${script:amd_micro_boot_volume_size_gb}GB boot)"
    }
    if ($parts.Count -eq 0) { return 'Empty (no instances configured)' }
    return $parts -join ' | '
}

function get_deployed_one_liner {
    $d = get_deployed_state_summary
    $parts = @()
    if ($d.ArmCount -gt 0) { $parts += "$($d.ArmCount)x ARM ($($d.ArmOcpus) OCPU, $($d.ArmMemoryGb)GB)" }
    if ($d.AmdCount -gt 0) { $parts += "$($d.AmdCount)x AMD" }
    $instances = if ($parts.Count -gt 0) { $parts -join ', ' } else { 'No instances' }
    return "$instances | $($d.StorageGb)GB/$($FREE_TIER_MAX_STORAGE_GB)GB storage | $($d.Vcns)/$($FREE_TIER_MAX_VCNS) VCNs"
}

function get_files_one_liner {
    $files = @('provider.tf', 'variables.tf', 'main.tf', 'data_sources.tf')
    $existing = @($files | Where-Object { Test-Path $_ })
    if ($existing.Count -eq 0) { return 'No .tf files (generated on first deploy)' }
    $stale = if ($script:TUI_CONFIGURED -and -not $script:TUI_TERRAFORM_FILES_READY) { ' [config changed - regenerate needed]' } else { '' }
    return "$($existing -join ', ')$stale"
}

function show_compact_status {
    $profileText = if ([string]::IsNullOrWhiteSpace($OCI_PROFILE)) { 'DEFAULT' } else { $OCI_PROFILE }
    $regionText = if ([string]::IsNullOrWhiteSpace($script:region)) { 'not set' } else { $script:region }
    $authText = if ($script:TUI_BOOTSTRAPPED) { "${GREEN}Authenticated${NC}" } else { "${YELLOW}Not authenticated${NC}" }

    Write-Host "  $($BOLD)Session:$($NC)  $profileText @ $regionText | $authText"
    Write-Host "  $($BOLD)Config:$($NC)   $(get_config_one_liner)"
    Write-Host "  $($BOLD)Live:$($NC)     $(get_deployed_one_liner)"
    Write-Host "  $($BOLD)Files:$($NC)    $(get_files_one_liner)"
    Write-Host ""
}

# ── Auto-configuration: loads config without prompts ──

function apply_default_config {
    $script:amd_micro_instance_count = 0
    $script:amd_micro_boot_volume_size_gb = 50
    $script:amd_micro_hostnames = @()
    $script:arm_flex_instance_count = 1
    $script:arm_flex_ocpus_per_instance = '4'
    $script:arm_flex_memory_per_instance = '24'
    $script:arm_flex_boot_volume_size_gb = '200'
    $script:arm_flex_hostnames = @('arm-instance-1')
    $script:arm_flex_block_volumes = @(0)
    $script:TUI_CONFIGURED = $true
    $script:TUI_TERRAFORM_FILES_READY = $false
    print_status "Default config: 1x ARM (4 OCPU, 24GB RAM, 200GB boot)"
}

function auto_configure_if_needed {
    if ($script:TUI_CONFIGURED) { return }

    # Priority 1: load from existing variables.tf
    if (Test-Path 'variables.tf') {
        try {
            if (load_existing_config) {
                $script:TUI_CONFIGURED = $true
                $script:TUI_TERRAFORM_FILES_READY = (has_terraform_files)
                print_status "Config loaded from variables.tf"
                return
            }
        } catch { }
    }

    # Priority 2: sync from deployed instances
    if ($script:TUI_DISCOVERED -and ($script:EXISTING_AMD_INSTANCES.Count -gt 0 -or $script:EXISTING_ARM_INSTANCES.Count -gt 0)) {
        configure_from_existing_instances
        $script:TUI_CONFIGURED = $true
        $script:TUI_TERRAFORM_FILES_READY = $false
        print_status "Config synced from deployed instances"
        return
    }

    # Priority 3: apply defaults
    apply_default_config
}

# ── Deploy readiness: ensures .tf files exist for terraform ops ──

function ensure_deploy_ready {
    # If .tf files already exist and no config changes pending, use them as-is
    if ((has_terraform_files) -and (-not $script:TUI_CONFIGURED -or $script:TUI_TERRAFORM_FILES_READY)) {
        # Load config from variables.tf so status display is accurate
        if (-not $script:TUI_CONFIGURED -and (Test-Path 'variables.tf')) {
            try { load_existing_config | Out-Null; $script:TUI_CONFIGURED = $true } catch { }
        }
        $script:TUI_TERRAFORM_FILES_READY = $true
        return
    }

    # Need to discover + configure + generate
    if (-not $script:TUI_DISCOVERED) { refresh_discovery_context }
    auto_configure_if_needed
    if (-not $script:TUI_TERRAFORM_FILES_READY) {
        create_terraform_files
        $script:TUI_TERRAFORM_FILES_READY = $true
    }
}

# ── Plan-only workflow (no apply) ──

function terraform_init_and_plan {
    print_subheader "Terraform Plan"

    print_status "Initializing..."
    & terraform init -upgrade 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'terraform init failed' }
    print_success "Initialized"

    # Import existing resources if discovered
    if ($script:TUI_DISCOVERED -and ($script:EXISTING_VCNS.Count -gt 0 -or $script:EXISTING_AMD_INSTANCES.Count -gt 0 -or $script:EXISTING_ARM_INSTANCES.Count -gt 0)) {
        print_status "Importing existing resources..."
        import_existing_resources
    }

    print_status "Validating..."
    & terraform validate 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'terraform validate failed' }
    print_success "Valid"

    print_status "Planning..."
    Remove-Item tfplan -ErrorAction SilentlyContinue
    & terraform plan -out=tfplan
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path 'tfplan')) { throw 'terraform plan failed' }
    Write-Host ""
    print_success "Plan saved to tfplan. Review above, then use Deploy to apply."
}

# ── Inline configuration editor ──

function edit_configuration {
    if (-not $script:TUI_DISCOVERED) {
        bootstrap_tui_runtime
        refresh_discovery_context
    }
    calculate_available_resources

    Write-Host ""
    Write-Host "  $($BOLD)Current config:$($NC) $(get_config_one_liner)"
    Write-Host "  $($BOLD)Free Tier available:$($NC) AMD=$script:AVAILABLE_AMD_INSTANCES, ARM OCPU=$script:AVAILABLE_ARM_OCPUS, Memory=$($script:AVAILABLE_ARM_MEMORY)GB, Storage=$($script:AVAILABLE_STORAGE)GB"
    Write-Host ""
    Write-Host "  1) Custom          interactive prompts for each instance"
    Write-Host "  2) Max Free Tier   use all available resources"
    Write-Host "  3) Sync deployed   match what is currently running"
    Write-Host "  4) Load saved      reload from variables.tf"
    Write-Host "  5) Reset defaults  1x ARM, 4 OCPU, 24GB RAM, 200GB boot"
    Write-Host "  0) Cancel"
    Write-Host ""

    $choice = read_menu_choice "Choose" 0 5 1 @{
        c = 1; custom = 1
        m = 2; max = 2
        s = 3; sync = 3
        l = 4; load = 4
        d = 5; defaults = 5; reset = 5
        b = 0; cancel = 0; q = 0
    }

    switch ($choice) {
        0 { return }
        1 { configure_custom_instances }
        2 { configure_maximum_free_tier }
        3 { configure_from_existing_instances }
        4 {
            if (-not (load_existing_config)) {
                print_error "Could not load variables.tf"
                pause_tui
                return
            }
            print_success "Config loaded from variables.tf"
        }
        5 { apply_default_config }
    }

    $script:TUI_CONFIGURED = $true
    $script:TUI_TERRAFORM_FILES_READY = $false

    Write-Host ""
    Write-Host "  $($BOLD)Updated config:$($NC) $(get_config_one_liner)"

    # Auto-regenerate or prompt
    if (has_terraform_files) {
        if (confirm_action "  Regenerate .tf files with new config?" 'Y') {
            create_terraform_files
            $script:TUI_TERRAFORM_FILES_READY = $true
            print_success "Terraform files regenerated"
        }
        else {
            print_status "Files not regenerated yet. Use Regenerate (4) when ready."
        }
    }
    else {
        create_terraform_files
        $script:TUI_TERRAFORM_FILES_READY = $true
        print_success "Terraform files generated"
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
        $script:arm_flex_boot_volume_size_gb += "200 "  # Default, will be updated from state
        $script:arm_flex_block_volumes += 0
    }
    
    # Trim trailing spaces
    $script:arm_flex_ocpus_per_instance = $script:arm_flex_ocpus_per_instance.Trim()
    $script:arm_flex_memory_per_instance = $script:arm_flex_memory_per_instance.Trim()
    $script:arm_flex_boot_volume_size_gb = $script:arm_flex_boot_volume_size_gb.Trim()
    
    # Set defaults if no instances exist
    if ($script:amd_micro_instance_count -eq 0 -and $script:arm_flex_instance_count -eq 0) {
        print_status "No existing instances found, using default configuration"

        $armImageAvailable = -not [string]::IsNullOrWhiteSpace($script:ubuntu_arm_flex_image_ocid)
        $amdImageAvailable = -not [string]::IsNullOrWhiteSpace($script:ubuntu_image_ocid)

        if ($armImageAvailable -and $script:AVAILABLE_ARM_OCPUS -gt 0) {
            $script:amd_micro_instance_count = 0
            $script:arm_flex_instance_count = 1
            $script:arm_flex_ocpus_per_instance = '4'
            $script:arm_flex_memory_per_instance = '24'
            $script:arm_flex_boot_volume_size_gb = '200'
            $script:arm_flex_hostnames = @('arm-instance-1')
            $script:arm_flex_block_volumes = @(0)
        }
        elseif ($amdImageAvailable -and $script:AVAILABLE_AMD_INSTANCES -gt 0) {
            $script:amd_micro_instance_count = 1
            $script:amd_micro_hostnames = @('amd-instance-1')
            $script:arm_flex_instance_count = 0
            $script:arm_flex_ocpus_per_instance = ''
            $script:arm_flex_memory_per_instance = ''
            $script:arm_flex_boot_volume_size_gb = ''
            $script:arm_flex_hostnames = @()
            $script:arm_flex_block_volumes = @()
        }
        else {
            print_warning "No eligible Ubuntu image found for AMD or ARM. Skipping compute instance creation."
            $script:amd_micro_instance_count = 0
            $script:amd_micro_hostnames = @()
            $script:arm_flex_instance_count = 0
            $script:arm_flex_ocpus_per_instance = ''
            $script:arm_flex_memory_per_instance = ''
            $script:arm_flex_boot_volume_size_gb = ''
            $script:arm_flex_hostnames = @()
            $script:arm_flex_block_volumes = @()
        }
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

            $boot = prompt_int_range "  Boot volume GB (50-200)" "200" 50 200
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

    $script:LAST_GENERATED_CONFIG_SIGNATURE = get_desired_config_signature
    $script:TUI_LAST_ACTION = 'Generated Terraform files'
    
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
        error_message = "Total storage (${local.total_storage}GB) exceeds Free Tier limit (${var.free_tier_max_storage_gb}GB)"
    }
}

check "arm_ocpu_limit" {
    assert {
        condition     = local.arm_flex_instance_count == 0 || sum(local.arm_flex_ocpus_per_instance) <= var.free_tier_max_arm_ocpus
        error_message = "Total ARM OCPUs exceed Free Tier limit (${var.free_tier_max_arm_ocpus})"
    }
}

check "arm_memory_limit" {
    assert {
        condition     = local.arm_flex_instance_count == 0 || sum(local.arm_flex_memory_per_instance) <= var.free_tier_max_arm_memory_gb
        error_message = "Total ARM memory exceeds Free Tier limit (${var.free_tier_max_arm_memory_gb}GB)"
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
    & terraform init 2>&1 | Out-Null
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

function pause_tui {
    Read-Host "$($BLUE)Press Enter to continue...$($NC)" | Out-Null
}

function clear_tui_screen {
    if ($TUI_CLEAR_SCREEN -eq 'true') {
        Clear-Host
    }
}

function confirm_destructive_action {
    param([string]$Label)

    print_warning "$Label"
    $value = Read-Host "$($YELLOW)Type DESTROY to confirm, or press Enter to cancel:$($NC)"
    $value = if ([string]::IsNullOrWhiteSpace($value)) { '' } else { $value.Trim().ToUpperInvariant() }
    return ($value -eq 'DESTROY')
}

function read_menu_choice {
    param(
        [string]$Prompt,
        [int]$Min,
        [int]$Max,
        [int]$Default = 1,
        [hashtable]$Aliases = $null
    )

    while ($true) {
        $raw = Read-Host "$($BLUE)$Prompt [$Default]: $($NC)"
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $Default
        }

        $normalized = $raw.Trim().ToLowerInvariant()
        if ($normalized -eq 'help' -or $normalized -eq 'h' -or $normalized -eq '?') {
            if ($Aliases -and $Aliases.Count -gt 0) {
                $aliasKeys = ($Aliases.Keys | Sort-Object) -join ', '
                print_status "Valid inputs: $Min-$Max, or: $aliasKeys"
            }
            else {
                print_status "Valid inputs: $Min-$Max"
            }
            continue
        }
        if ($Aliases -and $Aliases.ContainsKey($normalized)) {
            return [int]$Aliases[$normalized]
        }

        if ($normalized -match '^\d+$') {
            $value = [int]$normalized
            if ($value -ge $Min -and $value -le $Max) {
                return $value
            }
        }

        if ($Aliases -and $Aliases.Count -gt 0) {
            $aliasKeys = ($Aliases.Keys | Sort-Object) -join ', '
            print_error "Enter $Min-$Max or one of: $aliasKeys"
        }
        else {
            print_error "Please enter a number between $Min and $Max"
        }
    }
}

function show_tfplan_summary {
    if (-not (Test-Path 'tfplan')) {
        print_status "No saved plan found."
        return
    }

    print_subheader "Saved Plan Summary"
    try {
        & terraform show -no-color tfplan 2>&1 | Select-String -Pattern '^(Plan:|  #|will be)' | Select-Object -First 30
    }
    catch {
        print_warning "Could not render summary."
        & terraform show tfplan
    }
}

function show_terraform_state_and_outputs {
    print_subheader "Terraform State"
    & terraform state list
    if ($LASTEXITCODE -ne 0) {
        print_status "No Terraform state found (not initialized yet)"
        return
    }

    print_subheader "Terraform Outputs"
    try {
        & terraform output -json | ConvertFrom-Json | ConvertTo-Json
    }
    catch {
        & terraform output
    }

    if (Test-Path 'tfplan') {
        show_tfplan_summary
    }
}

function ensure_venv_activation {
    $venvBin = if ($IsWindows -or (-not $IsLinux -and -not $IsMacOS)) { 'Scripts' } else { 'bin' }
    $activatePs1 = Join-Path $PWD '.venv' $venvBin 'Activate.ps1'
    if (Test-Path $activatePs1) {
        & $activatePs1
    }
}

function invoke_tui_phase {
    param(
        [string]$Title,
        [scriptblock]$Action
    )

    print_status "$Title..."

    $originalLogLevel = $LOG_LEVEL
    $useConcise = ($TUI_CONCISE_LOGS -eq 'true')
    if ($useConcise) {
        $script:LOG_LEVEL = 'WARNING'
    }

    try {
        & $Action
        print_success "$Title completed"
    }
    catch {
        print_error "$Title failed: $_"
        throw
    }
    finally {
        if ($useConcise) {
            $script:LOG_LEVEL = $originalLogLevel
        }
    }
}

function bootstrap_tui_runtime {
    if ($script:TUI_BOOTSTRAPPED) {
        return
    }

    print_subheader "Bootstrap & Authentication"

    invoke_tui_phase "Preparing local toolchain" {
        install_prerequisites
        install_terraform
        install_oci_cli
    }

    invoke_tui_phase "Authenticating with OCI" {
        ensure_venv_activation
        setup_oci_config
    }

    if ([string]::IsNullOrWhiteSpace($script:region)) {
        $regionHint = read_oci_config_value 'region' $OCI_CONFIG_FILE $OCI_PROFILE
        if (-not [string]::IsNullOrWhiteSpace($regionHint)) {
            $script:region = normalize_auth_region $regionHint
        }
    }

    $script:TUI_BOOTSTRAPPED = $true
    print_success "Bootstrap ready (Profile=$OCI_PROFILE, Region=$(if ([string]::IsNullOrWhiteSpace($script:region)) { 'unknown' } else { $script:region }))"
}

function refresh_discovery_context {
    bootstrap_tui_runtime

    print_subheader "Discovery & Inventory"
    invoke_tui_phase "Refreshing OCI discovery context" {
        fetch_oci_config_values
        fetch_availability_domains
        fetch_ubuntu_images
        generate_ssh_keys
        inventory_all_resources
    }

    $script:TUI_DISCOVERED = $true
    $script:TUI_CONFIGURED = $false
    $script:TUI_TERRAFORM_FILES_READY = $false
    print_success "Discovery ready (Region=$script:region, AMD=$($script:EXISTING_AMD_INSTANCES.Count), ARM=$($script:EXISTING_ARM_INSTANCES.Count), VCNs=$($script:EXISTING_VCNS.Count))"
}

function run_terraform_workflow {
    print_subheader "Deploy"

    # Init
    print_status "Initializing Terraform..."
    & terraform init -upgrade 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'terraform init failed' }
    print_success "Initialized"

    # Import existing resources if we discovered any
    if ($script:TUI_DISCOVERED -and ($script:EXISTING_VCNS.Count -gt 0 -or $script:EXISTING_AMD_INSTANCES.Count -gt 0 -or $script:EXISTING_ARM_INSTANCES.Count -gt 0)) {
        print_status "Importing existing resources..."
        import_existing_resources
    }

    # Validate
    print_status "Validating..."
    & terraform validate 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'terraform validate failed' }
    print_success "Valid"

    # Plan
    print_status "Planning..."
    Remove-Item tfplan -ErrorAction SilentlyContinue
    & terraform plan -out=tfplan
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path 'tfplan')) { throw 'terraform plan failed' }
    print_success "Plan created"
    Write-Host ""

    # Apply (with confirmation)
    if (confirm_action "Apply this plan now?" 'Y') {
        print_status "Applying..."
        if (out_of_capacity_auto_apply) {
            print_success "Infrastructure deployed successfully!"
            Remove-Item tfplan -ErrorAction SilentlyContinue
            Write-Host ""
            try { & terraform output } catch { }
        }
        else {
            print_error "Terraform apply failed"
        }
    }
    else {
        print_status "Plan saved as 'tfplan'. Apply later with: terraform apply tfplan"
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

function main {
    initialize_log_catalog
    clear_tui_screen

    # ── Quick pre-flight: detect tools + auth + load config (no prompts) ──
    if ((command_exists 'oci') -and (command_exists 'terraform') -and (Test-Path $OCI_CONFIG_FILE)) {
        detect_auth_method
        if ($script:auth_method) {
            $regionHint = read_oci_config_value 'region' $OCI_CONFIG_FILE $OCI_PROFILE
            if (-not [string]::IsNullOrWhiteSpace($regionHint)) {
                $script:region = normalize_auth_region $regionHint
            }
            $script:TUI_BOOTSTRAPPED = $true
        }
    }

    # Auto-load config from variables.tf if it exists
    if (Test-Path 'variables.tf') {
        try {
            if (load_existing_config) {
                $script:TUI_CONFIGURED = $true
                $script:TUI_TERRAFORM_FILES_READY = (has_terraform_files)
            }
        } catch { }
    }

    # ── Main loop: single flat menu ──
    while ($true) {
        clear_tui_screen
        print_header "OCI TERRAFORM MANAGER"
        show_compact_status

        # Smart default: deploy if ready, else regenerate if config changed, else edit
        $defaultOpt = if ($script:TUI_CONFIGURED -and $script:TUI_TERRAFORM_FILES_READY) { 1 }
                      elseif ($script:TUI_CONFIGURED) { 4 }
                      else { 1 }

        Write-Host "  1) Deploy           plan + apply (auto-retries capacity errors)"
        Write-Host "  2) Plan only        preview changes without applying"
        Write-Host "  3) Edit config      change instance types, counts, sizes"
        Write-Host "  4) Regenerate       rebuild .tf files from current config"
        Write-Host "  5) Show state       terraform state, outputs, saved plan"
        Write-Host "  6) Import           import existing OCI resources to state"
        Write-Host "  7) Destroy          tear down all managed infrastructure"
        Write-Host "  8) Re-discover      re-scan OCI account for changes"
        Write-Host "  0) Exit"
        Write-Host ""
        if ($TUI_SHOW_HINTS -eq 'true') {
            Write-Host "  $($CYAN)Shortcuts: d=deploy, p=plan, e=edit, g=regen, s=state, i=import, r=refresh, q=exit, h=help$($NC)"
            Write-Host "  $($CYAN)Deploy/Plan auto-bootstraps and generates files if needed.$($NC)"
        }
        Write-Host ""

        $choice = read_menu_choice "Choose" 0 8 $defaultOpt @{
            d = 1; deploy = 1; apply = 1
            p = 2; plan = 2
            e = 3; edit = 3; config = 3; c = 3
            g = 4; regen = 4; regenerate = 4
            s = 5; state = 5; status = 5; show = 5
            i = 6; import = 6
            x = 7; destroy = 7
            r = 8; refresh = 8; discover = 8; scan = 8
            q = 0; quit = 0; exit = 0
        }

        switch ($choice) {
            1 {
                # Deploy: auto-chains bootstrap → discover → config → generate → plan → apply
                try {
                    bootstrap_tui_runtime
                    ensure_deploy_ready
                    run_terraform_workflow
                }
                catch {
                    print_error "Deploy failed: $_"
                }
            }
            2 {
                # Plan only: same auto-chain but stops after plan
                try {
                    bootstrap_tui_runtime
                    ensure_deploy_ready
                    terraform_init_and_plan
                }
                catch {
                    print_error "Plan failed: $_"
                }
            }
            3 {
                # Edit config: inline sub-menu, auto-regenerates after
                try {
                    edit_configuration
                }
                catch {
                    print_error "Edit failed: $_"
                }
            }
            4 {
                # Regenerate .tf files from config
                try {
                    bootstrap_tui_runtime
                    if (-not $script:TUI_DISCOVERED) { refresh_discovery_context }
                    auto_configure_if_needed
                    $doGenerate = $true
                    if (has_terraform_files) {
                        print_warning "This will overwrite existing .tf files."
                        if (-not (confirm_action "Continue?" 'Y')) {
                            print_status "Cancelled"
                            $doGenerate = $false
                        }
                    }
                    if ($doGenerate) {
                        create_terraform_files
                        $script:TUI_TERRAFORM_FILES_READY = $true
                        print_success "Terraform files regenerated"
                    }
                }
                catch {
                    print_error "Regeneration failed: $_"
                }
            }
            5 {
                # Show terraform state + outputs + saved plan
                try {
                    show_terraform_state_and_outputs
                }
                catch {
                    print_error "Could not read state: $_"
                }
            }
            6 {
                # Import existing OCI resources into terraform state
                try {
                    bootstrap_tui_runtime
                    if (-not $script:TUI_DISCOVERED) { refresh_discovery_context }
                    import_existing_resources
                }
                catch {
                    print_error "Import failed: $_"
                }
            }
            7 {
                # Destroy all managed infrastructure
                if (confirm_destructive_action "This will DESTROY all managed infrastructure.") {
                    try {
                        bootstrap_tui_runtime
                        & terraform destroy
                        if ($LASTEXITCODE -eq 0) {
                            print_success "Infrastructure destroyed"
                        }
                        else {
                            print_error "terraform destroy exited with code $LASTEXITCODE"
                        }
                    }
                    catch {
                        print_error "Destroy failed: $_"
                    }
                }
                else {
                    print_status "Cancelled"
                }
            }
            8 {
                # Re-discover: re-scan OCI account
                try {
                    refresh_discovery_context
                }
                catch {
                    print_error "Discovery failed: $_"
                }
            }
            0 {
                # Exit
                Write-Host ""
                print_status "Goodbye."
                return
            }
        }

        Write-Host ""
        pause_tui
    }
}

# Execute
main

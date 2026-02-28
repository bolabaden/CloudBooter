#Requires -Version 5.1
<#
.SYNOPSIS
  CloudBooter GCP Provisioner (PowerShell).

.DESCRIPTION
  Automated GCP Always-Free-Tier provisioning toolkit for Windows.
  Mirrors setup_gcp_terraform.sh — generates Terraform files and optionally deploys.

.PARAMETER ProjectId
  GCP project ID (required). Defaults to $env:GCP_PROJECT_ID.

.PARAMETER Region
  Compute region (default: us-central1). Must be a free-tier region.

.PARAMETER Zone
  Compute zone (default: us-central1-a).

.PARAMETER InstanceName
  Compute instance name (default: cloudbooter-vm).

.PARAMETER BootDiskGb
  Boot disk size in GB. Max 30 GB for free tier (default: 20).

.PARAMETER CredentialsFile
  Path to GCP SA key JSON or WIF config file.

.PARAMETER ImersonateSa
  Service account email to impersonate.

.PARAMETER AutoDeploy
  Skip confirmation prompts and run terraform apply automatically.

.PARAMETER NonInteractive
  Suppress all prompts; use defaults/env vars.

.PARAMETER Debug
  Enable verbose debug output.

.EXAMPLE
  .\setup_gcp_terraform.ps1 -ProjectId "my-proj" -AutoDeploy

.EXAMPLE
  $env:GCP_PROJECT_ID="my-proj"; $env:NON_INTERACTIVE="true"; .\setup_gcp_terraform.ps1
#>
[CmdletBinding()]
param(
    [string]$ProjectId        = $env:GCP_PROJECT_ID,
    [string]$Region           = $(if ($env:GCP_REGION) { $env:GCP_REGION } else { "us-central1" }),
    [string]$Zone             = $(if ($env:GCP_ZONE) { $env:GCP_ZONE } else { "us-central1-a" }),
    [string]$InstanceName     = $(if ($env:GCP_INSTANCE_NAME) { $env:GCP_INSTANCE_NAME } else { "cloudbooter-vm" }),
    [int]   $BootDiskGb       = $(if ($env:GCP_BOOT_DISK_GB) { [int]$env:GCP_BOOT_DISK_GB } else { 20 }),
    [string]$CredentialsFile  = $env:GCP_CREDENTIALS_FILE,
    [string]$ImpersonateSa    = $env:GCP_IMPERSONATE_SA,
    [string]$SshKeyFile       = $(if ($env:GCP_SSH_KEY_FILE) { $env:GCP_SSH_KEY_FILE } else { "$HOME\.ssh\cloudbooter_gcp" }),
    [string]$ExtraPackages    = $env:GCP_EXTRA_PACKAGES,
    [string]$TfBackend        = $(if ($env:TF_BACKEND) { $env:TF_BACKEND } else { "local" }),
    [string]$TfBackendBucket  = $env:TF_BACKEND_BUCKET,
    [string]$TfOutputDir      = $PSScriptRoot,
    [switch]$AutoDeploy,
    [switch]$NonInteractive,
    [switch]$ForceReauth,
    [switch]$SkipInventory,
    [switch]$AllowPaidResources
)

# Honour env-based flags
if ($env:AUTO_DEPLOY -eq "true")        { $AutoDeploy       = $true }
if ($env:NON_INTERACTIVE -eq "true")    { $NonInteractive   = $true }
if ($env:FORCE_REAUTH -eq "true")       { $ForceReauth      = $true }
if ($env:SKIP_INVENTORY -eq "true")     { $SkipInventory    = $true }

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Free-tier constants ───────────────────────────────────────────────────────
$FREE_MACHINE_TYPE          = "e2-micro"
$FREE_STANDARD_PD_GB        = 30
$FREE_COMPUTE_REGIONS       = @("us-central1","us-west1","us-east1")
$FREE_STORAGE_REGIONS       = @("us-east1","us-west1","us-central1")
$RETRY_MAX_ATTEMPTS         = if ($env:RETRY_MAX_ATTEMPTS) { [int]$env:RETRY_MAX_ATTEMPTS } else { 8 }
$RETRY_BASE_DELAY           = if ($env:RETRY_BASE_DELAY)   { [int]$env:RETRY_BASE_DELAY }   else { 15 }

$GCP_RETRY_PATTERNS = @(
    "RESOURCE_EXHAUSTED", "rateLimitExceeded", "quotaExceeded",
    "ZONE_RESOURCE_POOL_EXHAUSTED", "Error 429", "Error 503",
    "Backend Error", "quota exceeded", "QUOTA_EXCEEDED"
)

# ── Inventory hashtables ──────────────────────────────────────────────────────
$ExistingVpcs       = @{}
$ExistingSubnets    = @{}
$ExistingFirewalls  = @{}
$ExistingInstances  = @{}
$ExistingDisks      = @{}
$ExistingStaticIps  = @{}
$ExistingBuckets    = @{}

# ── Colour helpers ────────────────────────────────────────────────────────────
function Write-Info    { param($m) Write-Host "[INFO]  $m" -ForegroundColor Cyan }
function Write-OK      { param($m) Write-Host "[OK]    $m" -ForegroundColor Green }
function Write-Warn    { param($m) Write-Host "[WARN]  $m" -ForegroundColor Yellow }
function Write-Err     { param($m) Write-Host "[ERROR] $m" -ForegroundColor Red }
function Write-Hdr     { param($m) Write-Host "`n=== $m ===`n" -ForegroundColor White }
function Write-Dbg     { param($m) if ($DebugPreference -ne "SilentlyContinue" -or $env:DEBUG -eq "true") { Write-Host "[DEBUG] $m" -ForegroundColor DarkGray } }

function Prompt-WithDefault {
    param([string]$Prompt, [string]$Default)
    if ($NonInteractive) { return $Default }
    $v = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($v)) { $Default } else { $v }
}

function Confirm-Action {
    param([string]$Prompt, [bool]$DefaultYes = $false)
    if ($NonInteractive) { return $DefaultYes }
    $r = Read-Host "$Prompt [y/N]"
    return ($r -match "^[yY]")
}

# ── Command availability ──────────────────────────────────────────────────────
function Test-Command { param($c) return [bool](Get-Command $c -ErrorAction SilentlyContinue) }

# ── gcloud wrapper ────────────────────────────────────────────────────────────
function Invoke-Gcloud {
    param([string[]]$Args)
    $allArgs = $Args + @("--format=json","--quiet")
    if ($ProjectId) { $allArgs += @("--project",$ProjectId) }
    Write-Dbg "gcloud $($allArgs -join ' ')"
    try {
        $output = & gcloud @allArgs 2>$null
        return $output | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return @()
    }
}

# ── Prerequisites ─────────────────────────────────────────────────────────────
function Install-GcloudSdk {
    Write-Hdr "Installing Google Cloud SDK"
    if (Test-Command "gcloud") {
        $ver = (& gcloud version 2>$null | Select-String "Google Cloud SDK") -replace ".*SDK\s+",""
        Write-OK "gcloud already installed ($ver)"
        return
    }

    # winget (Windows)
    if (Test-Command "winget") {
        Write-Info "Attempting: winget install Google.CloudSDK"
        winget install -e --id Google.CloudSDK --silent --accept-package-agreements --accept-source-agreements
        if (Test-Command "gcloud") { Write-OK "gcloud installed via winget"; return }
    }

    # Interactive installer download
    Write-Info "Downloading interactive Google Cloud SDK installer..."
    $installer = "$env:TEMP\GoogleCloudSDKInstaller.exe"
    Invoke-WebRequest -Uri "https://dl.google.com/dl/cloudsdk/channels/rapid/GoogleCloudSDKInstaller.exe" `
        -OutFile $installer -UseBasicParsing
    Start-Process $installer "/S" -Wait
    if (Test-Command "gcloud") { Write-OK "gcloud installed via installer"; return }

    Write-Warn "gcloud SDK could not be installed. Python SDK mode will be used."
    $env:GCP_MODE = "python"
}

function Install-Terraform {
    Write-Hdr "Installing Terraform"
    if (Test-Command "terraform") {
        $ver = (& terraform version -json 2>$null | ConvertFrom-Json).terraform_version
        Write-OK "terraform already installed (v$ver)"
        return
    }

    if (Test-Command "winget") {
        winget install -e --id Hashicorp.Terraform --silent --accept-package-agreements --accept-source-agreements
        if (Test-Command "terraform") { Write-OK "terraform installed via winget"; return }
    }

    # Direct zip download
    $latest = (Invoke-WebRequest -Uri "https://checkpoint-api.hashicorp.com/v1/check/terraform" -UseBasicParsing | `
        ConvertFrom-Json).current_version
    $url = "https://releases.hashicorp.com/terraform/$latest/terraform_${latest}_windows_amd64.zip"
    $zip = "$env:TEMP\terraform_$latest.zip"
    Write-Info "Downloading Terraform $latest ..."
    Invoke-WebRequest $url -OutFile $zip -UseBasicParsing
    $dest = "$env:LOCALAPPDATA\Programs\terraform"
    Expand-Archive -Path $zip -DestinationPath $dest -Force
    $env:PATH += ";$dest"
    Write-OK "Terraform $latest installed to $dest"
}

# ── Auth ──────────────────────────────────────────────────────────────────────
function Setup-GcpAuth {
    Write-Hdr "GCP Authentication"

    if ($CredentialsFile -and (Test-Path $CredentialsFile)) {
        $cred = Get-Content $CredentialsFile | ConvertFrom-Json -ErrorAction SilentlyContinue
        $credType = $cred.type

        switch ($credType) {
            "service_account" {
                Write-Info "Activating SA key: $CredentialsFile"
                & gcloud auth activate-service-account --key-file=$CredentialsFile --quiet 2>$null
                $env:GOOGLE_APPLICATION_CREDENTIALS = $CredentialsFile
                Write-OK "SA key activated."
            }
            "external_account" {
                Write-Info "WIF config: $CredentialsFile"
                $env:GOOGLE_APPLICATION_CREDENTIALS = $CredentialsFile
                Write-OK "WIF credentials configured."
            }
            default {
                $env:GOOGLE_APPLICATION_CREDENTIALS = $CredentialsFile
                Write-Warn "Unknown credential type '$credType'. Set as GOOGLE_APPLICATION_CREDENTIALS."
            }
        }
    } elseif ($ImpersonateSa) {
        Write-Info "Using impersonation: $ImpersonateSa"
    } else {
        Write-Info "Using Application Default Credentials (ADC)."
        $adcToken = & gcloud auth application-default print-access-token 2>$null
        if (-not $adcToken) {
            if ($NonInteractive) {
                throw "ADC not configured. Set GCP_CREDENTIALS_FILE or run gcloud auth application-default login."
            }
            Write-Info "Running: gcloud auth application-default login"
            & gcloud auth application-default login
        }
    }

    $active = & gcloud auth list --filter="status:ACTIVE" --format="value(account)" 2>$null | Select-Object -First 1
    if ($active) { Write-OK "Active account: $active" }
}

# ── Inventory ─────────────────────────────────────────────────────────────────
function Get-Inventory {
    Write-Hdr "Resource Inventory"

    Write-Info "VPCs..."
    (Invoke-Gcloud @("compute","networks","list")) | ForEach-Object {
        $ExistingVpcs[$_.name] = $_.selfLink
    }

    Write-Info "Subnets in $Region..."
    (Invoke-Gcloud @("compute","networks","subnets","list","--filter=region:$Region")) | ForEach-Object {
        $ExistingSubnets[$_.name] = $_.selfLink
    }

    Write-Info "Firewall rules..."
    (Invoke-Gcloud @("compute","firewall-rules","list")) | ForEach-Object {
        $ExistingFirewalls[$_.name] = $_.network
    }

    Write-Info "Instances in $Zone..."
    (Invoke-Gcloud @("compute","instances","list","--filter=zone:($Zone)")) | ForEach-Object {
        $ExistingInstances[$_.name] = $_.status
    }

    Write-Info "Disks in $Zone..."
    (Invoke-Gcloud @("compute","disks","list","--filter=zone:($Zone)")) | ForEach-Object {
        $ExistingDisks[$_.name] = $_.sizeGb
    }

    Write-Info "Static IPs in $Region..."
    (Invoke-Gcloud @("compute","addresses","list","--filter=region:($Region)")) | ForEach-Object {
        $ExistingStaticIps[$_.name] = "$($_.address)|$($_.status)"
        if ($_.status -eq "RESERVED") {
            Write-Warn "BILLING TRAP: Static IP '$($_.name)' ($($_.address)) is RESERVED but unattached — you are being charged."
        }
    }

    # Summary
    Write-Hdr "Inventory Summary"
    Write-Host ("  VPCs:         {0}" -f $ExistingVpcs.Count)
    Write-Host ("  Subnets:      {0}" -f $ExistingSubnets.Count)
    Write-Host ("  Firewalls:    {0}" -f $ExistingFirewalls.Count)
    Write-Host ("  Instances:    {0}" -f $ExistingInstances.Count)
    Write-Host ("  Disks:        {0}" -f $ExistingDisks.Count)
    Write-Host ("  Static IPs:   {0}" -f $ExistingStaticIps.Count)
}

# ── Validation ────────────────────────────────────────────────────────────────
function Assert-FreeTier {
    Write-Hdr "Free-Tier Validation"
    $ok = $true

    if ($InstanceName -and $ExistingInstances.Keys -notcontains $InstanceName) {
        # Only validate machine type if creating new
        # (existing instances may have been changed by the user)
    }

    if (-not $FREE_COMPUTE_REGIONS.Contains($Region)) {
        Write-Err "Region '$Region' is not in the free tier list: $($FREE_COMPUTE_REGIONS -join ', ')"
        $ok = $false
    } else { Write-OK "Region: $Region" }

    if ($BootDiskGb -gt $FREE_STANDARD_PD_GB) {
        Write-Err "Boot disk $BootDiskGb GB exceeds free tier cap of $FREE_STANDARD_PD_GB GB."
        $ok = $false
    } else { Write-OK "Boot disk: ${BootDiskGb} GB" }

    if ($AllowPaidResources) {
        Write-Warn "AllowPaidResources=true — free-tier limits bypassed."
        return
    }

    if (-not $ok) { throw "Free-tier validation failed. Use -AllowPaidResources to override." }
}

# ── SSH Keys ──────────────────────────────────────────────────────────────────
$SshPublicKey = ""
function Setup-SshKeys {
    if (Test-Path "$SshKeyFile.pub") {
        $script:SshPublicKey = Get-Content "$SshKeyFile.pub" -Raw
        Write-OK "SSH public key: $SshKeyFile.pub"
        return
    }

    $keyDir = Split-Path $SshKeyFile
    if (-not (Test-Path $keyDir)) { New-Item -ItemType Directory -Path $keyDir -Force | Out-Null }

    if ($NonInteractive -or (Confirm-Action "Generate SSH key at $SshKeyFile?")) {
        if (Test-Command "ssh-keygen") {
            & ssh-keygen -t ed25519 -f $SshKeyFile -C "cloudbooter-gcp" -N '""' -q 2>$null
        } else {
            # Fallback to OpenSSH in System32
            & "$env:SystemRoot\System32\OpenSSH\ssh-keygen.exe" -t ed25519 -f $SshKeyFile -C "cloudbooter-gcp" -N '""' -q 2>$null
        }
        $script:SshPublicKey = Get-Content "$SshKeyFile.pub" -Raw
        Write-OK "SSH key generated: $SshKeyFile"
    }
}

# ── Terraform Generation ──────────────────────────────────────────────────────
function New-ProviderTf {
    $credBlock = if ($CredentialsFile) { "  credentials = file(var.credentials_file)" } else { "" }
    $impBlock  = if ($ImpersonateSa)   { "  impersonate_service_account = var.impersonate_service_account" } else { "" }
    $backendBlock = if ($TfBackend -eq "gcs") {
        "  backend `"gcs`" {`n    bucket = `"$TfBackendBucket`"`n    prefix = `"cloudbooter/$ProjectId/$InstanceName`"`n  }"
    } else {
        "  backend `"local`" {}"
    }

    @"
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

$backendBlock
}

provider "google" {
  project = var.project_id
  region  = var.region
$credBlock
$impBlock
}
"@ | Set-Content "$TfOutputDir\provider.tf" -Encoding UTF8
    Write-OK "Generated provider.tf"
}

function New-VariablesTf {
    $credVar = if ($CredentialsFile) {
"`nvariable `"credentials_file`" {`n  description = `"SA key file path`"`n  type        = string`n}`n"
    } else { "" }

    @"
variable "project_id" {
  description = "GCP project ID"
  type        = string
  default     = "$ProjectId"
}

variable "region" {
  description = "GCP compute region"
  type        = string
  default     = "$Region"

  validation {
    condition     = contains(["us-central1", "us-west1", "us-east1"], var.region)
    error_message = "Region must be us-central1, us-west1, or us-east1 for free compute."
  }
}

variable "zone" {
  description = "GCP compute zone"
  type        = string
  default     = "$Zone"
}

variable "machine_type" {
  description = "GCE machine type"
  type        = string
  default     = "$FREE_MACHINE_TYPE"
}

variable "boot_disk_size_gb" {
  description = "Boot disk size in GB"
  type        = number
  default     = $BootDiskGb
}

variable "instance_name" {
  description = "Compute instance name"
  type        = string
  default     = "$InstanceName"
}

variable "ssh_public_key" {
  description = "SSH public key for instance metadata"
  type        = string
  default     = "$($SshPublicKey.Trim())"
  sensitive   = true
}
$credVar
check "e2_micro_machine_type" {
  assert {
    condition     = var.machine_type == "$FREE_MACHINE_TYPE"
    error_message = "Machine type must be $FREE_MACHINE_TYPE for the GCP Always Free tier."
  }
}

check "compute_region_free_tier" {
  assert {
    condition     = contains(["us-central1", "us-west1", "us-east1"], var.region)
    error_message = "Region must be us-central1, us-west1, or us-east1."
  }
}

check "standard_pd_limit" {
  assert {
    condition     = var.boot_disk_size_gb <= $FREE_STANDARD_PD_GB
    error_message = "Boot disk must be <= $FREE_STANDARD_PD_GB GB for the GCP Always Free tier."
  }
}
"@ | Set-Content "$TfOutputDir\variables.tf" -Encoding UTF8
    Write-OK "Generated variables.tf"
}

function New-DataSourcesTf {
    @"
data "google_project" "current" {}

data "google_compute_image" "ubuntu" {
  family  = "ubuntu-2404-lts-amd64"
  project = "ubuntu-os-cloud"
}

data "google_compute_zones" "available" {
  region = var.region
  status = "UP"
}
"@ | Set-Content "$TfOutputDir\data_sources.tf" -Encoding UTF8
    Write-OK "Generated data_sources.tf"
}

function New-MainTf {
    @"
resource "google_compute_network" "vpc" {
  name                    = "`${var.instance_name}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name          = "`${var.instance_name}-subnet"
  ip_cidr_range = "10.0.0.0/24"
  region        = var.region
  network       = google_compute_network.vpc.id
}

resource "google_compute_firewall" "allow_ssh" {
  name    = "`${var.instance_name}-allow-ssh"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["`${var.instance_name}-ssh"]
}

resource "google_compute_firewall" "allow_icmp" {
  name    = "`${var.instance_name}-allow-icmp"
  network = google_compute_network.vpc.name

  allow {
    protocol = "icmp"
  }

  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_disk" "boot" {
  name  = "`${var.instance_name}-boot"
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
    "ssh-keys" = "ubuntu:`${var.ssh_public_key}"
    user-data  = file("`${path.module}/cloud-init.yaml")
  }

  tags = ["`${var.instance_name}-ssh"]

  scheduling {
    preemptible         = false
    automatic_restart   = true
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
  description = "SSH command to connect"
  value       = "ssh -i $SshKeyFile ubuntu:`${google_compute_instance.vm.network_interface[0].access_config[0].nat_ip}"
}

output "console_url" {
  description = "GCP Console URL"
  value       = "https://console.cloud.google.com/compute/instancesDetail/zones/`${var.zone}/instances/`${var.instance_name}?project=`${var.project_id}"
}
"@ | Set-Content "$TfOutputDir\main.tf" -Encoding UTF8
    Write-OK "Generated main.tf"
}

function New-CloudInitYaml {
    $extraPkgLines = ""
    if ($ExtraPackages) {
        $ExtraPackages -split '\s+' | ForEach-Object { $extraPkgLines += "  - $_`n" }
    }

    @"
#cloud-config
hostname: $InstanceName
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
$extraPkgLines
runcmd:
  - dpkg-reconfigure --priority=low unattended-upgrades
  - echo "CloudBooter provisioned on `$(date)" >> /var/log/cloudbooter.log
"@ | Set-Content "$TfOutputDir\cloud-init.yaml" -Encoding UTF8
    Write-OK "Generated cloud-init.yaml"
}

function New-AllTerraformFiles {
    Write-Hdr "Generating Terraform Files"
    if (-not (Test-Path $TfOutputDir)) { New-Item -ItemType Directory -Path $TfOutputDir -Force | Out-Null }
    New-ProviderTf
    New-VariablesTf
    New-DataSourcesTf
    New-MainTf
    New-CloudInitYaml
    Write-OK "All files written to: $TfOutputDir"
}

# ── Terraform Execution ────────────────────────────────────────────────────────
function Test-QuotaError { param($text) $GCP_RETRY_PATTERNS | Where-Object { $text -match $_ } | Select-Object -First 1 }

function Invoke-TerraformApplyWithRetry {
    Write-Hdr "Terraform Apply (with Quota-Error Retry)"
    $attempt = 0
    $delay   = $RETRY_BASE_DELAY

    while ($attempt -lt $RETRY_MAX_ATTEMPTS) {
        $attempt++
        Write-Info "Apply attempt $attempt/$RETRY_MAX_ATTEMPTS..."

        $result = & terraform -chdir=$TfOutputDir apply -auto-approve "$TfOutputDir\tfplan" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-OK "Apply succeeded on attempt $attempt."
            return
        }

        $resultText = $result -join "`n"
        if (Test-QuotaError $resultText) {
            Write-Warn "Quota/capacity error. Waiting ${delay}s before retry..."
            Start-Sleep -Seconds $delay
            $delay *= 2
            & terraform -chdir=$TfOutputDir plan `
                -var="project_id=$ProjectId" -var="region=$Region" -var="zone=$Zone" `
                -var="instance_name=$InstanceName" -var="boot_disk_size_gb=$BootDiskGb" `
                -out="$TfOutputDir\tfplan" | Out-Null
        } else {
            Write-Err "Non-retryable Terraform error:`n$resultText"
            throw "Terraform apply failed."
        }
    }
    throw "Terraform apply failed after $RETRY_MAX_ATTEMPTS attempts."
}

# ── Main ──────────────────────────────────────────────────────────────────────
function Invoke-Main {
    Write-Host "`n  CloudBooter GCP Provisioner — Always Free Tier`n" -ForegroundColor White

    # Prerequisites
    Install-GcloudSdk
    Install-Terraform

    # Project ID
    if (-not $ProjectId) {
        $ProjectId = Prompt-WithDefault "GCP Project ID" ""
        if (-not $ProjectId) { throw "GCP_PROJECT_ID is required." }
    }
    Write-OK "Project: $ProjectId"

    # Auth
    Setup-GcpAuth

    # Inventory
    if (-not $SkipInventory) { Get-Inventory }

    # Validate
    Assert-FreeTier

    # SSH Keys
    Setup-SshKeys

    # Generate
    New-AllTerraformFiles

    # Deploy
    $shouldDeploy = $AutoDeploy -or (Confirm-Action "Run terraform init + plan + apply?")
    if ($shouldDeploy) {
        Write-Info "Running: terraform init"
        & terraform -chdir=$TfOutputDir init -input=false -upgrade
        if ($LASTEXITCODE -ne 0) { throw "terraform init failed." }

        Write-Info "Running: terraform plan"
        & terraform -chdir=$TfOutputDir plan `
            -var="project_id=$ProjectId" -var="region=$Region" -var="zone=$Zone" `
            -var="instance_name=$InstanceName" -var="boot_disk_size_gb=$BootDiskGb" `
            -out="$TfOutputDir\tfplan"
        if ($LASTEXITCODE -ne 0) { throw "terraform plan failed." }

        if ($AutoDeploy -or (Confirm-Action "Apply the plan?")) {
            Invoke-TerraformApplyWithRetry
        } else {
            Write-Info "Apply skipped. Run: terraform -chdir=$TfOutputDir apply `"$TfOutputDir\tfplan`""
        }
    } else {
        Write-Info "Generation complete. Files in: $TfOutputDir"
        Write-Info "Next: terraform -chdir=`"$TfOutputDir`" init && terraform -chdir=`"$TfOutputDir`" apply"
    }

    Write-OK "CloudBooter GCP run complete."
    if (Test-Path "$SshKeyFile.pub") { Write-Info "SSH private key: $SshKeyFile" }
}

Invoke-Main

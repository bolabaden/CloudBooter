# Oracle Cloud Always Free Tier Guide

**Complete reference for Oracle Cloud Infrastructure Always Free tier resources, maximization strategies, and Terraform bootstrap (updated February 2026).**

Oracle Cloud's **Always Free** tier provides indefinite access to specific production-grade resources at zero cost, available in your home region. This guide consolidates limits, policies, optimization strategies, and deployment automation verified against official OCI documentation (current as of February 12, 2026) and community consensus from r/oraclecloud. You can acquire every listed resource with zero charges if you stay within limits. Standout limits include:

- Arm A1 Flex pool: 4 OCPU + 24 GB RAM total
- Block storage: 200 GB combined
- Outbound data transfer: 10 TB/month

## Quick Utilization Checklist
1. Sign up at https://signup.cloud.oracle.com/ (valid credit/debit card for verification only; never charged within Always Free limits)
2. Choose home region carefully during signup—Ashburn and Frankfurt typically have better Ampere A1 availability
3. Use the provided Terraform bootstrap or console walkthrough to deploy near-maximum resource utilization safely

## Table of Contents
- [Oracle Cloud Always Free Tier Guide](#oracle-cloud-always-free-tier-guide)
  - [Table of Contents](#table-of-contents)
  - [Overview](#overview)
  - [Key Resources and Limits](#key-resources-and-limits)
    - [Compute Resources](#compute-resources)
    - [Storage](#storage)
    - [Databases](#databases)
    - [Networking](#networking)
    - [Observability, Security, and Additional Services](#observability-security-and-additional-services)
  - [Detailed Limits Tables](#detailed-limits-tables)
    - [Verbatim Idle Reclamation Policy](#verbatim-idle-reclamation-policy)
    - [Verbatim Object Storage Post-Trial Warning](#verbatim-object-storage-post-trial-warning)
    - [Home Region \& Capacity Notes](#home-region--capacity-notes)
  - [Maximizing Value](#maximizing-value)
    - [Recommended Configurations](#recommended-configurations)
    - [Compute Strategy](#compute-strategy)
    - [Storage Strategy](#storage-strategy)
    - [Networking \& Accessibility](#networking--accessibility)
    - [Databases Maximization](#databases-maximization)
    - [Keep-Alive Scripts (Anti-Reclamation)](#keep-alive-scripts-anti-reclamation)
    - [Avoiding Reclamation](#avoiding-reclamation)
    - [Risks and Considerations](#risks-and-considerations)
  - [Community Insights](#community-insights)
  - [Limitations and Conditions](#limitations-and-conditions)
  - [Getting Started](#getting-started)
    - [Manual Console Walkthrough](#manual-console-walkthrough)
    - [Automated Terraform Bootstrap](#automated-terraform-bootstrap)
      - [Key Script Features](#key-script-features)
      - [Example Maximized Terraform Configuration](#example-maximized-terraform-configuration)
      - [Running the Script](#running-the-script)
  - [References](#references)

## Overview

Oracle Cloud's **Always Free** tier provides indefinite access to specific resources with strict limits, available in your home region. These resources never expire if you stay within the caps.

## Key Resources and Limits

### Compute Resources

**AMD Micro Instances**:
- Limit: up to 2 instances
- Shape: `VM.Standard.E2.1.Micro`
- CPU/RAM: 1/8 OCPU (burstable), 1 GB RAM each
- Eligible images: Oracle Linux Cloud Developer, Oracle Linux, Ubuntu, CentOS
- Networking: up to 50 Mbps public or 480 Mbps private

**ARM A1 Flex Instances**:
- Limit: total 4 OCPUs + 24 GB RAM across the pool
- Shape: `VM.Standard.A1.Flex`
- Allocation: up to 4 instances (maximum 4 cores/24 GB total)
- Equivalent: 3,000 OCPU hours and 18,000 GB hours per month
- Minimum boot volume: ~47-50 GB per instance (counts against 200 GB block storage)
- Recommended allocation: single instance with the full 4 OCPUs and 24 GB
- Note: Oracle Linux Cloud Developer requires >=8 GB RAM

**To maximize compute value**:
- Recommended allocation: 4 OCPUs and 24 GB RAM on a single Arm instance for intensive workloads (media servers, VPNs, app hosting)
- Alternate layout: 2 AMD micro instances for lightweight services alongside the Arm instance

### Storage

**Block/Boot Volumes**:
- Total: 200 GB combined
- Backups: up to 5 total
- Region: home region only
- Default boot volume: ~50 GB per instance
- Extra volume headroom: ~150 GB remaining for a single A1 + two micros

**Object/Archive Storage**:
- Total: 20 GB combined post-trial
- Tiers: Standard, Infrequent Access, Archive
- API requests: 50,000/month
- Trial/paid tier: 10 GB per tier
- Use: backups and archives; high-performance needs are best served by block volumes
- Note: storage drops to 20 GB post-trial if not upgraded to paid tier

### Databases

**Autonomous Databases**:
- Limit: up to 2 instances
- CPU: 1 fixed OCPU each
- Storage: ~20 GB Exadata storage each
- Sessions: 20 max per database
- Types: Transaction Processing, Data Warehouse, JSON, APEX
- Architecture: serverless on Exadata infrastructure

**NoSQL Database**:
- Limit: 1 database, 3 tables
- Storage: 25 GB per table
- Throughput: 133 million reads/writes per month

**HeatWave MySQL**:
- Limit: 1 standalone single-node instance
- Storage: 50 GB data + 50 GB backup
- Best for: analytics and machine learning workloads

### Networking

**Load Balancers**:
- Flexible Load Balancer: 1 (10 Mbps)
- Network Load Balancer: 1

**VCNs**:
- Limit: up to 2
- IPv4/IPv6 supported
- Port 25 outbound blocked by default
- VCN flow logs: 10 GB/month

**Data Transfer**:
- 10 TB outbound per month

**VPN**:
- 50 Site-to-Site IPSec connections

**To maximize networking**: Set up VPN for secure remote access or load balance traffic across instances.

### Observability, Security, and Additional Services

**Observability**:
- Monitoring: 500M ingestion datapoints/month, 1B retrieval datapoints/month
- Notifications: 1M HTTPS + 1,000 email/month
- Logging: 10 GB/month
- APM: 1,000 tracing events + 10 synthetic monitors/hour

**Security and Access**:
- Vault: 150 secrets + 20 HSM key versions
- Email Delivery: 3,000/month
- Bastions: up to 5
- Certificates: 5 private CAs + 150 TLS certificates

## Detailed Limits Tables

**Table 1: Core Compute & Storage**

| Category | Resource | Exact Quota | Notes / Conditions |
|----------|----------|-------------|---------|
| Compute (AMD) | VM.Standard.E2.1.Micro | 2 instances | Each: 1/8 OCPU (burstable), 1 GB RAM; single AD only; images: Oracle Linux, Ubuntu, CentOS, Oracle Linux Cloud Developer |
| Compute (Arm) | VM.Standard.A1.Flex | 4 OCPU + 24 GB total (3,000 OCPU-h + 18,000 GB-h/month) | Up to 4 instances; flexible split; min boot volume 47 GB per instance; any AD in multi-AD regions; Oracle Linux Cloud Developer requires ≥8 GB RAM |
| Block Volume | Boot + Additional Volumes + Backups | 200 GB total combined + 5 backups | Includes all boot and attached volumes; home region only; default boot ~50 GB |
| Object/Archive Storage | Standard + Infrequent Access + Archive | 20 GB combined + 50,000 API requests/month | Post-trial Always Free only; 10 GB per tier during trial/paid; exceeding 20 GB at trial end deletes all objects |

#### Quick specs (table summary)
- Arm A1 Flex: 4 OCPU total, 24 GB RAM total
- AMD Micros: 2 instances (VM.Standard.E2.1.Micro)
- Block storage: 200 GB combined (includes boot volumes)
- Object storage: 20 GB combined, 50,000 API requests/month

**Table 2: Databases & Networking**

| Category | Resource | Exact Quota | Notes |
|----------|----------|-------------|-------|
| Databases | Autonomous AI Database | 2 instances | Each: 1 OCPU fixed, ~20 GB Exadata storage, ~20-30 sessions; workloads: OLTP, Data Warehouse, JSON, APEX; home region |
| Databases | MySQL HeatWave | 1 standalone single-node | 50 GB data + 50 GB backup; home region |
| Databases | NoSQL Database | 1 DB, 3 tables | 25 GB/table; 133M reads + 133M writes/month |
| Networking | Flexible Load Balancer | 1 (10 Mbps) | 16 listeners/backend sets, 1,024 backends; for tenancies post-Dec 2020 |
| Networking | Network Load Balancer | 1 | 50 listeners, 1,024 backends |
| Networking | VCNs | 2 | IPv4/IPv6; port 25 blocked by default (exemption requestable) |
| Networking | Outbound Data Transfer | 10 TB/month | Ingress unlimited |
| Networking | Site-to-Site VPN | 50 IPSec connections | — |
| Networking | VCN Flow Logs | 10 GB/month | Shared with Logging |

#### Quick specs (table summary)
- Autonomous Databases: 2 instances (1 OCPU each, ~20 GB storage)
- MySQL HeatWave: 1 node (50 GB data + 50 GB backup)
- NoSQL: 1 DB, 3 tables (25 GB per table)
- Outbound data transfer: 10 TB/month

**Table 3: Security, Observability & Other**

| Category | Resource | Exact Quota | Notes |
|----------|----------|-------------|-------|
| Security | Vault | 150 secrets + 20 HSM key versions | Unlimited software keys; 40 versions/secret max |
| Security | Bastions | 5 | Time-limited secure access to private resources |
| Security | Certificates | 5 private CAs + 150 TLS certificates | — |
| Observability | Monitoring | 500M ingestion + 1B retrieval datapoints/month | — |
| Observability | Logging | 10 GB/month | Shared with flow logs |
| Observability | Notifications | 1M HTTPS + 1,000 email/month | — |
| Observability | Email Delivery | 3,000 emails/month (~100/day) | Approved senders required |
| Observability | Application Performance Monitoring | 1,000 tracing events + 10 synthetic runs/hour | 1 free APM domain |
| Management | Resource Manager (Terraform) | 100 stacks, 2 concurrent jobs | Ideal for bootstrapping |
| Other | Console Dashboards | 100 | — |
| Other | Connector Hub | 2 connectors | — |

#### Quick specs (table summary)
- Vault: 150 secrets + 20 HSM key versions
- Monitoring: 500M data ingestion / month, 1B retrievals
- Logging: 10 GB/month
- Resource Manager (Terraform): 100 stacks, 2 concurrent jobs

### Verbatim Idle Reclamation Policy

From official OCI Always Free Resources page (February 2026):

"Idle Always Free compute instances may be reclaimed by Oracle. Oracle will deem virtual machine and bare metal compute instances as idle if, during a 7-day period, the following are true:
- CPU utilization for the 95th percentile is less than 20%
- Network utilization is less than 20%
- Memory utilization is less than 20% (applies to A1 shapes only)"

### Verbatim Object Storage Post-Trial Warning

"If you are using more than the 20-GB limit when your Free Trial ends, all of your objects will be deleted. You can then upload objects until you reach your Always Free usage limits."

### Home Region & Capacity Notes

Core resources (compute, block, Autonomous DBs, etc.) are home-region only and cannot be moved after account creation. "Out of host capacity" for A1 is common; mitigation options include:
- Try different availability domains
- Wait 24-48 hours
- Upgrade to PAYG (retains Always Free quotas, improves capacity pools, and remains $0 within limits)

One account per person is strictly enforced.

## Maximizing Value

### Recommended Configurations

Targets and constraints:
- Utilization target: near 100% without crossing limits
- Block storage total: 200 GB combined

| Configuration | Instances | Total Compute | Approx. Block Used | Best For | Utilization Notes |
|---------------|-----------|---------------|--------------------|----------|-------------------|
| **Maximum Single-VM Power** | 1× A1 (4/24) + 2× Micro | 4.25 OCPU / 26 GB | 200 GB (50 GB boot A1 + 2×50 GB Micro + 50 GB extra block) | Jellyfin, *arr suite, containers, VPN, heavy apps | Full A1 power + always-on light tasks on Micros |
| **Maximum Isolation** | 4× A1 (1 OCPU/6 GB each) | 4 OCPU / 24 GB | ~188 GB (47 GB boot each) | Microservices, testing, isolated workloads | Leaves minimal room for extra block |
| **Balanced Homelab (Recommended)** | 1× A1 (4/24) + 2× Micro | 4.25 OCPU / 26 GB | 200 GB full | Self-hosting, media + DB + monitoring | Attach remaining block to primary A1; LB for HA |

### Compute Strategy

Recommended allocation:
- Arm pool: 4 OCPUs + 24 GB RAM on a single instance for heavy services (media servers, game servers, VPNs, application hosting)
- Alternate split: up to four smaller Arm instances for isolation
- AMD micros: 2 instances for lightweight background services

### Storage Strategy

Use these storage targets to stay within limits while maximizing capacity:
- Block storage total: 200 GB combined
- Default boot volume: ~50 GB per instance
- Extra block volume headroom: ~150 GB for a single A1 + two micros
- Backups: up to 5 total
- Object storage: 20 GB for static assets, cold backups, and archives

### Networking & Accessibility

Recommended layout and limits:
- VCN design: public subnets for instances/load balancers, private subnets for databases
- Flexible Load Balancer: 10 Mbps is sufficient for personal or low-traffic services
- Bastions: use for secure SSH to private resources
- Outbound data: 10 TB/month for streaming, backups, or CDN-style distribution

### Databases Maximization

Use one Autonomous Database for transactional workloads or APEX, and the second for analytics or JSON. HeatWave is ideal for analytics and vector search use cases, while NoSQL works best for high-throughput key-value storage.

### Keep-Alive Scripts (Anti-Reclamation)

Run lightweight background processes to keep utilization above the reclamation thresholds:

```yaml
# Cloud-Init YAML (prevents reclamation)
runcmd:
  - while true; do stress-ng --cpu 1 --timeout 300s; sleep 60; done &
```

Alternatively, use cron-based monitoring or application-level activity.

### Avoiding Reclamation

**Important**: Oracle may reclaim idle instances if, over this window:
- Time window: 7-day period
- 95th percentile CPU is under 20%
- Network utilization is under 20%
- Memory utilization is under 20% (A1 only)

To avoid this, keep a small, steady workload running, monitor usage regularly, and use lightweight keep-alive scripts when needed.

### Risks and Considerations

**Account Type Tradeoffs**:

Pure Always Free tenancies are fully capable of running within the limits, but they often hit "out of capacity" errors in regions with tight supply. They also tend to see higher reclamation risk if utilization is low, and they do not include SLAs or full support. If you are patient and stay within limits, they can run indefinitely, but capacity and stability vary by region.

Upgrading to Pay As You Go (PAYG) does not change the Always Free limits or pricing, but it does change account verification and capacity access.

**PAYG specifics**:
- Always Free limits and pricing remain unchanged
- Account remains $0 as long as usage stays within Always Free limits
- $100 authorization charge is used for card verification
- Authorization is typically reversed the same day
- Better access to capacity pools, especially for `VM.Standard.A1.Flex`

**General Risks**:
- Idle reclamation still applies if utilization is low for a full 7-day period (CPU/network/memory <20%)
- Outbound port 25 is blocked by default unless you request an exemption
- Always back up data externally; rare terminations can occur due to inactivity or policy violations

## Community Insights

Users frequently report that PAYG upgrades keep Always Free usage at no charge while improving capacity availability in peak regions. Pure Always Free accounts still work, but users often need more patience during provisioning and should monitor utilization to avoid reclamation.

Real-world usage highlights include:
- Compose stacks and web services
- Game servers and media servers
- Lightweight background services on the AMD micros
- The 4 OCPU/24 GB Arm instance as a full-featured self-hosted server for personal workloads

For community tips and troubleshooting, the most active sources are [r/oraclecloud](https://www.reddit.com/r/oraclecloud/) and [r/selfhosted](https://www.reddit.com/r/selfhosted/), especially threads on capacity, PAYG upgrades, and idle policies.

## Limitations and Conditions

- Key resources (compute, databases, block storage) are limited to your home region
- Always Free accounts do not include SLAs
- One account per person is enforced
- Object storage drops to 20 GB after the trial if not upgraded
- Outbound port 25 is blocked by default unless you request an exemption

## Getting Started

### Manual Console Walkthrough

1. **Account Creation**: Sign up at https://signup.cloud.oracle.com/ — valid credit/debit card required for verification only (no virtual/prepaid). Choose home region carefully for A1 availability. Region cannot be changed after account creation.

2. **Login & Create Instance**: Hamburger menu (three lines) -> Compute -> Instances -> Create instance
  - Instance screenshots preserved in repository documentation

3. **Name & Region**: Ensure "Always Free-eligible" badge is visible on instance details

4. **Shape Selection**: 
  - Click Edit -> Change shape -> Select Ampere for `VM.Standard.A1.Flex` (use sliders for exactly 4 OCPU / 24 GB)
  - Or select AMD for `VM.Standard.E2.1.Micro` (fixed 1/8 OCPU / 1 GB)

5. **Image**: Ubuntu 22.04 or Oracle Linux 8 (Always Free eligible)
  - Note: Oracle Linux Cloud Developer requires >=8 GB RAM if selected

6. **Networking/SSH/Boot Volume**: 
   - Use default subnet or create custom VCN
   - Generate or paste SSH public key
   - Boot volume: default ~50 GB per instance (adjust total to fit 200 GB combined)

7. **Deploy**: Click Create. Wait for state = Running, then SSH: `ssh ubuntu@<public-ip>`

Repeat for additional instances, volumes, load balancers, and databases. Attach extra block volumes to reach 200 GB total.

### Automated Terraform Bootstrap

**Recommended approach**: Use the repository's `setup_oci_terraform.sh` for fully automated, idempotent deployment:

#### Key Script Features

- **Non-interactive mode**: Set `NON_INTERACTIVE=true AUTO_DEPLOY=true` for full automation
- **Prerequisites install**: Automatically installs OCI CLI, Terraform, jq
- **Browser-based auth**: Session tokens (no manual config file editing needed)
- **Resource inventory**: Discovers existing VCNs, instances, volumes
- **Strict validation**: Enforces Free Tier limits before deployment
- **File generation**: Creates provider.tf, variables.tf, main.tf, block_volumes.tf, cloud-init.yaml
- **Retry/backoff**: Auto-retries up to 8 times for "out of capacity" errors
- **Terraform menu**: Interactive plan/apply/destroy/import interface
- **Outputs**: Public IPs, SSH commands, resource summary

#### Example Maximized Terraform Configuration

Generated by script for 1× A1 (4/24) + 2× Micro + full 200 GB block + Flexible LB:

```hcl
# Max A1 Instance
resource "oci_core_instance" "a1_max" {
  shape = "VM.Standard.A1.Flex"
  shape_config { 
    ocpus = 4
    memory_in_gbs = 24 
  }
  source_details {
    source_type = "image"
    image_id    = data.oci_core_images.ubuntu_arm.id
    boot_volume_size_in_gbs = 50
  }
  # ... metadata with cloud-init for keep-alive
}

# Extra Block to reach 200 GB
resource "oci_core_volume" "extra" { 
  size_in_gbs = 150 
}
resource "oci_core_volume_attachment" "attach" { 
  instance_id = oci_core_instance.a1_max.id
  volume_id  = oci_core_volume.extra.id
}

# Flexible Load Balancer
resource "oci_load_balancer_load_balancer" "free_lb" {
  shape_details { 
    minimum_bandwidth_in_mbps = 10
    maximum_bandwidth_in_mbps = 10 
  }
}

# Autonomous Database (repeat for 2nd)
resource "oci_database_autonomous_database" "adb" {
  cpu_core_count = 1
  data_storage_size_in_tbs = 0.02
  is_free_tier = true
}
```

#### Running the Script

```bash
# Interactive mode (prompts for choices)
./implementations/bash/setup_oci_terraform.sh

# Non-interactive full automation
NON_INTERACTIVE=true AUTO_USE_EXISTING=true AUTO_DEPLOY=true \
  ./implementations/bash/setup_oci_terraform.sh

# Use specific OCI profile
OCI_PROFILE=myprofile ./implementations/bash/setup_oci_terraform.sh
```

The script is safe to re-run multiple times (idempotent); it handles existing resources via import.

## References

- **Oracle Cloud Infrastructure Always Free Resources** (Official, updated August 5, 2025): https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm
- **OCI Free Tier Overview** (October 17, 2025): https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier.htm
- **Oracle Cloud Free Tier Marketing Page**: https://www.oracle.com/cloud/free/
- **Free Tier FAQ** (Reclamation, PAYG, Capacity): https://www.oracle.com/cloud/free/faq/
- **OCI Service Limits** (February 12, 2026): https://docs.oracle.com/en-us/iaas/Content/General/Concepts/servicelimits.htm
- **r/oraclecloud Community Discussions** (2025–2026): https://www.reddit.com/r/oraclecloud/ — Threads on out-of-capacity fixes, long-term success stories, PAYG benefits, idle policies
- **r/selfhosted Community** (Use Cases): https://www.reddit.com/r/selfhosted/ — Jellyfin, *arr suite, and self-hosting examples on Always Free ARM

All content verified current as of **February 22, 2026**. Enjoy the full power of OCI Always Free!

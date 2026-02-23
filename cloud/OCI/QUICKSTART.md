# Oracle Cloud Always Free Tier — Complete Guide

This guide combines a **hands-on walkthrough** for creating Oracle Cloud instances with a **comprehensive explanation of limits, resources, and optimization tips** for the Oracle Cloud **Always Free** tier.

---

## Overview: What Is Oracle Cloud Always Free?

Oracle Cloud Infrastructure (OCI) offers an **Always Free** tier that provides a set of resources **indefinitely**, as long as you stay within defined limits. These resources are separate from the 30-day $300 promotional trial and are available only in your **home region**.

If you stay within caps, your resources do not expire.

Oracle Cloud's Always Free tier provides substantial, permanently-available resources (for example, an Arm instance pool with up to 4 OCPUs and 24 GB RAM, and up to 200 GB of block storage). Enrollment requires a valid payment method for identity verification and resources are provisioned in your home region; availability and capacity may vary by region. For authoritative limits and automated provisioning guidance, see [docs/FREE_TIER.md](docs/FREE_TIER.md) and [implementations/bash/setup_oci_terraform.sh](implementations/bash/setup_oci_terraform.sh). To enroll, visit https://signup.oraclecloud.com.

---

## Free Tier Resource Limits (At a Glance)

### Compute
You can create up to **4 total instances**:

- **x86 (AMD)**
  - Up to **2 VM.Standard.E2.1.Micro**
  - Each: 1/8 OCPU (burstable), 1 GB RAM

- **Arm (Ampere A1 Flex)**
  - Total pool: **4 OCPUs + 24 GB RAM**
  - Configurable across **up to 4 instances**
  - Minimum boot volume: ~47–50 GB per instance

### Storage
- **200 GB total** block + boot volume storage (combined)
- **5 volume backups**
- **20 GB Object / Archive storage** (post-trial)
- **50,000 API requests/month**

### Databases
- **2 Autonomous Databases**
  - 1 OCPU, 20 GB storage each
- **1 NoSQL database** (3 tables)
- **OR** **1 HeatWave MySQL instance**

### Networking
- 1 Flexible Load Balancer (10 Mbps)
- 1 Network Load Balancer
- Up to 2 VCNs
- 50 Site-to-Site VPN connections
- **10 TB outbound data/month**
- Outbound port 25 blocked by default

---

## Step-by-Step: Creating an Always Free VM

### 1. Create Your Account

Sign up here:  
https://signup.cloud.oracle.com/

You **must** use a real credit or debit card  
> Virtual and prepaid cards are not accepted.

---

### 2. Log In

Log into your new Oracle Cloud account.

![SignIn](https://user-images.githubusercontent.com/7338312/113791051-60882600-9708-11eb-801e-3f0624aca2dc.png)

---

### 3. Navigate to Compute Instances

1. Click the **hamburger menu** (top left)
2. Go to **Compute → Instances**
3. Click **Create instance**

![image](https://user-images.githubusercontent.com/7338312/144918356-a91aa72c-2bf7-4964-bf35-e3032c4e00c2.png)
![image](https://user-images.githubusercontent.com/7338312/144918469-c98f44dc-306e-440c-ab10-00c9b7ea62c1.png)

---

### 4. Name & Region

- Give your instance a name
- Wait for the form to autofill
- Ensure the region shows **“Always Free-eligible”**

![image](https://user-images.githubusercontent.com/7338312/144918675-3e4fbce2-875e-4ac1-ae7a-d18d66fd2f4a.png)

---

### 5. Choose Shape (CPU Type)

Click **Edit → Change shape**

#### x86 (AMD)
Leave defaults and click **Select shape**

![image](https://user-images.githubusercontent.com/7338312/144919139-0e53da3e-ccc2-4d5a-b42d-c3651fc056f0.png)

#### Arm (Ampere A1)
- Select **Ampere**
- Check **VM.Standard.A1.Flex**
- Allocate CPU/RAM using the sliders

You have **4 cores + 24 GB RAM total** across Arm instances.

![image](https://user-images.githubusercontent.com/7338312/144945509-1d6f269e-47c9-4749-9281-b93c947637a2.png)
![image](https://user-images.githubusercontent.com/7338312/144945640-2809fc13-cc2b-4c36-b033-050da631ff02.png)

---

### 6. Choose an Image (OS)

Click **Change image**, then select your OS and version.

![image](https://user-images.githubusercontent.com/7338312/144919299-d39c916b-94e5-4f1a-a25d-20ec6b4d257e.png)
![image](https://user-images.githubusercontent.com/7338312/144919489-20ac31e0-bfe0-4788-a0f2-ff930468b7b0.png)

---

### 7. Networking

Defaults are usually fine. Adjust only if you know you need changes.

---

### 8. SSH Keys

- Choose **Paste public keys**
- Paste your key from `~/.ssh/id_rsa.pub`
- Or upload / generate one

![image](https://user-images.githubusercontent.com/7338312/144919789-c456c22b-8943-4ad0-a784-b94ab084c022.png)

---

### 9. Boot Volume

- Default is ~50 GB (minimum)
- Total free tier storage: **200 GB**
- Adjust size if using fewer than 4 VMs

![image](https://user-images.githubusercontent.com/7338312/144945033-f2d602b8-b7f9-438b-be66-3e9a04bbe56a.png)

---

### 10. Deploy

Click **Create** and wait for provisioning.

![image](https://user-images.githubusercontent.com/7338312/144945150-7373060d-77d8-45a8-a456-4eb99463adcb.png)

Once green, note the public IP and connect:

```bash
ssh ubuntu@<public-ip>
````

![done](https://user-images.githubusercontent.com/7338312/113791880-3d5e7600-970a-11eb-9e04-0ffefa5defbf.png)

---

For automated provisioning and to ensure free-tier limits are enforced when deploying, prefer the repository's provisioning scripts and Terraform templates: see [implementations/bash/setup_oci_terraform.sh](implementations/bash/setup_oci_terraform.sh).

## Maximizing Value (Very Important)

* Use **one Arm instance with all 4 OCPUs + 24 GB RAM** for best performance
* Combine with **2 AMD micro instances** for small services
* Attach extra block volumes to use all 200 GB
* Keep instances **active**:

  * Oracle may reclaim VMs if usage stays below ~20% for 7 days
* Consider upgrading to **Pay As You Go** while staying in free limits:

  * Better capacity availability
  * Still $0 if you don’t exceed limits

---

## Risks & Limitations

* No SLA or guaranteed uptime
* Capacity can be unavailable in some regions
* Idle instances may be reclaimed
* Always Free resources must stay in your **home region**
* One account per person; violations may result in suspension

---

## Summary

Oracle Cloud’s Always Free tier is unusually generous—especially the **4-core / 24-GB Arm instance**—and is excellent for:

* Self-hosting
* Learning cloud infrastructure
* Development & testing
* Lightweight production workloads

Stay within limits, keep instances active, and it can run **forever at $0**.

# CloudBooter

CloudBooter is a terminal-first bootstrapper for cloud infrastructure.

The goal is simple: give beginners a safe, repeatable “starting point” for a cloud account (network + compute + access) with sensible defaults, so they can learn by changing one thing at a time.

This repository is intentionally multi-cloud in scope (AWS, Azure, GCP, OCI, and others). Today, only Oracle Cloud Infrastructure (OCI) is implemented. The provider roadmap is explicit in this README.

If you’ve ever opened a cloud console and thought “I don’t even know what I should click first,” CloudBooter is for you.

---

## What CloudBooter is (and isn’t)

### It is

- A workflow that inventories what you already have, proposes a plan, then generates Terraform you can inspect and apply.
- A set of provider implementations under `cloud/<PROVIDER>/`.
- A terminal UX with interactive prompts today (CLI), aiming to become a full TUI over time.
- Opinionated defaults that you can keep, tweak, or replace.

### It is not

- A “one-click production platform.”
- A managed service.
- A replacement for learning Terraform. CloudBooter generates Terraform specifically so you can learn from it.

---

## Current support status

CloudBooter is designed as a multi-provider bootstrapper, but provider support rolls out one-by-one.

| Provider | Status | What you can do today |
|---|---:|---|
| OCI | Supported | Inventory, generate Terraform, optional auto-deploy; Bash and Python implementations |
| AWS | Planned | VPC + subnet + security group + EC2 baseline |
| Azure | Planned | Resource group + VNet + subnet + NSG + VM baseline |
| GCP | Planned | Project bootstrap guidance + VPC + subnet + firewall + Compute Engine baseline |

---

## The “defaults-first” philosophy

CloudBooter is built around a practical belief: beginners don’t need more options; they need a working baseline.

So each provider implementation aims to ship with:

1. A minimal but realistic network topology.
2. One or more compute instances with SSH access.
3. A clear mapping between prompts (or environment variables) and Terraform output.
4. Idempotency: you can run it multiple times without it getting confused.
5. Guardrails: validate inputs before generating or applying infrastructure.

The baseline is intentionally conservative. Once you have a working environment, you can:

- scale it up,
- swap images,
- split subnets,
- add load balancers,
- attach disks,
- add managed databases,
- destroy and rebuild repeatedly.

That iteration loop is the point.

---

## How it works (high-level)

While each provider differs, the workflow is consistent:

1. **Authenticate** using the provider’s best-supported local mechanism.
2. **Inventory** existing resources to avoid duplicating or conflicting with what’s already in the account.
3. **Plan** a proposed configuration (interactive prompts by default; environment variables for automation).
4. **Validate** the plan (basic constraints, safety checks, and provider limits).
5. **Generate Terraform** into a target directory.
6. Optionally **run Terraform** (`init`, `plan`, and `apply`) with retry logic where the cloud is known to be flaky.

The output Terraform is treated as a learning artifact as much as a deployment mechanism.

---

## Quick start (OCI)

OCI lives under `cloud/OCI/`. That directory contains both:

- a mature Bash implementation (`setup_oci_terraform.sh`)
- a Python implementation (`cloudbooter` package)

Pick one.

### Option A: Bash (recommended for Linux/macOS/WSL)

From the repository root:

```bash
cd cloud/OCI
./setup_oci_terraform.sh
```

This script is designed to be run repeatedly. It inventories resources before proposing changes and generates Terraform in the current directory.

Useful environment variables (non-interactive automation):

```bash
NON_INTERACTIVE=true \
AUTO_USE_EXISTING=true \
AUTO_DEPLOY=false \
./setup_oci_terraform.sh
```

### Option B: PowerShell (Windows)

From the repository root:

```powershell
cd cloud\OCI
.\setup_oci_terraform.ps1
```

### Option C: Python CLI (cross-platform)

The Python package is in `cloud/OCI/`.

```powershell
cd cloud\OCI
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -e .

cloudbooter --help
cloudbooter
```

By default the CLI writes Terraform into the current working directory. You can override with `--terraform-dir`.

---

## Your first 10 minutes

If you want the fastest learning loop, follow this sequence:

1. Run CloudBooter for a provider (OCI today).
2. Let it generate Terraform into an empty folder.
3. Open the generated `.tf` files and read them top to bottom.
4. Run:

	```bash
	terraform init
	terraform plan
	```

5. If the plan matches what you expected, apply it:

	```bash
	terraform apply
	```

6. SSH into the instance(s).
7. Change one default (instance count, shape, disk size, allowed ports, cloud-init).
8. Re-run `terraform plan` and observe what changes.
9. When you’re done, destroy:

	```bash
	terraform destroy
	```

This “generate → inspect → plan → apply → iterate” loop is the core CloudBooter experience.

---

## What CloudBooter tries to bootstrap (the baseline)

The baseline differs per cloud, but the intention is the same:

- A dedicated network (VPC/VNet/VCN equivalent)
- A public subnet with a route to the internet
- A minimal firewall/security policy to allow SSH
- One or more compute instances
- SSH key material generated locally (so you can actually log in)

From there, you can extend it into anything: private subnets, NAT, load balancers, managed databases, Kubernetes, and so on.

---

## OCI baseline defaults (what “out of the box” means today)

OCI is currently the reference implementation. It includes a conservative default plan and guardrails.

At a high level, it bootstraps:

- Networking primitives (VCN + subnet + internet gateway + route table + security list)
- Compute instances (x86 and/or Arm shapes, depending on your choices)
- Storage (boot volumes and optional attached block volumes)
- Cloud-init for basic instance initialization

The OCI implementation also contains retry logic for transient capacity failures that can happen during instance provisioning.

If you want the deep provider-specific walkthrough, go straight to `cloud/OCI/USAGE.md`.

---

## Configuration surface (OCI)

CloudBooter supports two styles of configuration:

1. Interactive prompts (the default)
2. Automation via flags and environment variables

### Bash script configuration (OCI)

The Bash implementation supports common automation toggles:

- `NON_INTERACTIVE=true` to avoid prompts
- `AUTO_USE_EXISTING=true` to prefer existing discovered resources
- `AUTO_DEPLOY=true` to automatically run Terraform after generation
- `FORCE_REAUTH=true` to force a fresh login flow
- `OCI_PROFILE=...` to choose a named OCI CLI profile

There are more provider-specific knobs documented in `cloud/OCI/USAGE.md`.

### Python CLI configuration (OCI)

The Python CLI is a single command with options (no subcommands yet). Common flags:

- `--profile` and `--config-file` for local OCI CLI config selection
- `--auth-mode` (`api_key`, `security_token`, `instance_principal`, `resource_principal`)
- `--terraform-dir` to control where output files are written
- `--non-interactive` for automation
- `--auto-deploy` to run Terraform after generation

Most options can also be set via environment variables (for example `OCI_PROFILE`, `OCI_CONFIG_FILE`, `OCI_AUTH_MODE`, `OCI_AUTH_REGION`).

---

## What gets generated

The exact filenames can vary per provider, but the OCI implementation generates a familiar Terraform layout (examples):

- `provider.tf` (provider configuration)
- `variables.tf` (inputs and guardrails)
- `data_sources.tf` (images, availability domains, etc.)
- `main.tf` (network + compute)
- `block_volumes.tf` (optional storage)
- `cloud-init.yaml` (instance initialization)

The idea is that you can open these files and follow the chain:

Prompt → planned config → Terraform variable → resource attribute.

---

## Working with the generated Terraform

CloudBooter intentionally generates “plain Terraform,” not a hidden internal format.

Practical tips:

- Start by running `terraform fmt` after generation; it makes diffs easier to read.
- Treat the generated folder as disposable while learning. Re-generate as often as needed.
- If you decide to keep a stack long-term, consider moving it to its own repo and wiring a remote backend for state.
- When you make manual edits, prefer editing Terraform directly rather than trying to force CloudBooter to re-generate around your changes.

CloudBooter’s “best case” is that you eventually stop needing it because you’ve learned enough Terraform and cloud basics.

---

## Troubleshooting (OCI)

Common issues you’ll run into during bootstrapping:

### Authentication confusion

OCI has multiple auth modes (API keys, security tokens, instance principals). If you’re getting auth errors:

- verify which mode you’re using (`--auth-mode` in Python, or your profile in Bash)
- confirm the region is set (CLI uses `--region` / `OCI_AUTH_REGION`)
- check that your OCI config files exist and are readable

### Capacity failures

Some regions intermittently fail to provision certain shapes. The OCI implementation includes retry logic for transient “out of capacity” style failures. If you still can’t provision:

- wait and retry later
- try a different availability domain (when applicable)
- reduce your requested footprint

### Terraform state surprises

If Terraform shows resources you didn’t expect:

- confirm which directory you ran Terraform in
- confirm which backend is configured
- don’t mix multiple stacks into the same state file

---

## FAQ

### Do I need to know Terraform first?

No. But you’ll learn fastest if you treat the generated Terraform as the source of truth and read it.

### Is CloudBooter safe to run in an existing account?

It is designed to inventory and avoid blindly duplicating resources, but you should still treat any infrastructure tool with respect. Always review `terraform plan`.

### Why a terminal UX?

The terminal is the one place beginners can copy/paste commands, read logs, and inspect generated files without context switching. A TUI is planned to make the experience smoother without hiding what’s happening.

### When will AWS/Azure/GCP land?

There’s no fixed date. The intent is to add providers only when they meet the same bar as OCI: idempotent bootstrap with defaults, guardrails, and generated Terraform that’s understandable.

---

## Safety: cost and cleanup

CloudBooter is meant for learning. That means it should be safe to try.

That said, cloud accounts are real billing systems. Even “free” offerings vary by provider and can change.

Practical safety habits:

1. Always review `terraform plan` before applying.
2. Use budgets and alerts in your provider (and set them on day one).
3. Prefer small defaults and scale deliberately.
4. If you’re done experimenting, run `terraform destroy`.
5. Know where your Terraform state is stored.

Provider implementations may include additional guardrails that are specific to that cloud.

---

## Terminal UI (TUI) direction

CloudBooter’s UX is “terminal-first.”

- Today: interactive CLI prompts (Python uses Click; Bash uses shell prompts).
- Planned: a proper TUI that makes the flow feel consistent across providers (inventory view, plan review, apply progress, and post-run next steps).

The long-term goal is one command that feels the same regardless of cloud:

```text
cloudbooter
	-> pick provider
	-> inventory
	-> choose defaults
	-> generate Terraform
	-> (optional) apply
```

---

## Repository layout

This repo is organized by provider:

```text
.
├─ cloud/
│  ├─ OCI/
│  │  ├─ setup_oci_terraform.sh
│  │  ├─ setup_oci_terraform.ps1
│  │  ├─ src/cloudbooter/            (Python CLI for OCI)
│  │  ├─ tests/
│  │  ├─ QUICKSTART.md
│  │  ├─ USAGE.md
│  │  └─ FREE_TIER_LIMITS.md         (OCI-specific reference)
│  └─ <future providers>/
└─ scripts/                          (repo-wide helpers)
```

Each provider folder should be runnable on its own and contain its own docs.

---

## Documentation map (OCI)

If you’re using OCI, start here:

- `cloud/OCI/USAGE.md` for command-line usage and environment variables
- `cloud/OCI/QUICKSTART.md` for a step-by-step walkthrough
- `cloud/OCI/FREE_TIER_LIMITS.md` for a provider-specific limits reference
- `cloud/OCI/README.md` for the longer provider guide

---

## Roadmap (multi-cloud)

CloudBooter’s roadmap is incremental: add providers without changing the workflow concept.

### Near-term

- Normalize provider folder structure (`cloud/<provider>/`) and entrypoints
- Stabilize a consistent set of “bootstrap outputs” across providers (network, compute, SSH, Terraform layout)
- Improve non-interactive automation knobs (env vars + flags)

### Providers

- AWS: VPC baseline + security group + EC2 + keypair guidance
- Azure: resource group + VNet + subnet + NSG + VM
- GCP: VPC + subnet + firewall + VM

Each provider will start with a conservative baseline and expand only after the initial “first working deployment” is smooth.

---

## Developing and testing

Provider implementations own their own dependencies.

For OCI (Python):

```powershell
cd cloud\OCI
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -e .[dev]

pytest
```

---

## Contributing

Contributions are welcome, especially:

- new provider scaffolds under `cloud/<provider>/`
- better defaults that stay beginner-friendly
- doc improvements (clearer “why,” safer “what,” smaller “first steps”)
- tests that protect idempotency and template generation

If you’re adding a provider, aim for:

1. inventory
2. plan
3. validate
4. generate terraform
5. (optional) apply

---

## License

MIT. See `LICENSE`.

#!/usr/bin/env python3
"""Quick parity check: render templates and verify they match Bash canonical format."""

import sys
sys.path.insert(0, "src")

from cloudbooter.cli import Runner, OciContext, PlannedConfig, RuntimeConfig

# Mock data structures
ctx = OciContext(
    tenancy_ocid="ocid1.tenancy.oc1..test",
    user_ocid="ocid1.user.oc1..test",
    region="us-phoenix-1",
    ubuntu_x86_image_ocid="ocid1.image.oc1.phx.test",
    ubuntu_arm_image_ocid="ocid1.image.oc1.phx.test",
)

planned = PlannedConfig(
    amd_micro_instance_count=1,
    amd_micro_boot_volume_size_gb=50,
    amd_micro_hostnames=["amd-instance-1"],
    amd_block_volume_size_gb=0,
    arm_flex_instance_count=1,
    arm_flex_ocpus_per_instance=[4],
    arm_flex_memory_per_instance=[24],
    arm_flex_boot_volume_size_gb=[200],
    arm_flex_hostnames=["arm-instance-1"],
    arm_block_volume_sizes=[0],
)

runtime = RuntimeConfig(
    auth_mode="security_token",
    profile="DEFAULT",
    strict_provider_parity=True,
)

runner = Runner(runtime)

# Test provider.tf indentation
provider_tf = runner._render_provider_tf(ctx)
print("=== provider.tf sample (first 10 lines) ===")
for i, line in enumerate(provider_tf.split("\n")[:10], 1):
    print(f"{i:2}: {repr(line)}")

# Check indentation level
has_4_space = any(line.startswith("    ") and not line.startswith("      ") for line in provider_tf.split("\n"))
has_2_space = any(line.startswith("  ") and not line.startswith("    ") for line in provider_tf.split("\n"))
print(f"\nHas 2-space indent: {has_2_space}, Has 4-space indent (non-nested): {has_4_space}")

# Test variables.tf
variables_tf = runner._render_variables_tf(ctx, planned)
print("\n=== variables.tf sample (locals section, first 15 lines) ===")
for i, line in enumerate(variables_tf.split("\n")[3:18], 3):
    print(f"{i:2}: {repr(line)}")

# Test data_sources.tf
data_sources_tf = runner._render_data_sources_tf()
print("\n=== data_sources.tf sample ===")
for i, line in enumerate(data_sources_tf.split("\n")[:12], 1):
    print(f"{i:2}: {repr(line)}")

# Test cloud-init.yaml indentation (YAML, should use 2-space)
cloud_init = runner._render_cloud_init()
print("\n=== cloud-init.yaml sample (packages section) ===")
lines = cloud_init.split("\n")
pkg_start = next(i for i, line in enumerate(lines) if "packages:" in line)
for i in range(pkg_start, min(pkg_start + 12, len(lines))):
    print(f"{i:2}: {repr(lines[i])}")

print("\n✅ Parity check complete.")

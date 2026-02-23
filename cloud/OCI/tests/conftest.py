"""Shared test fixtures and configuration."""

import os
import sys
import tempfile
from pathlib import Path
from unittest.mock import MagicMock, Mock, patch

# Add src to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

import pytest

from cloudbooter.cli import (
    OciContext,
    PlannedConfig,
    RuntimeConfig,
    ExistingResources,
)


@pytest.fixture
def temp_dir():
    """Provide a temporary directory for test artifacts."""
    with tempfile.TemporaryDirectory() as tmpdir:
        yield Path(tmpdir)


@pytest.fixture
def mock_runtime_config(temp_dir):
    """Provide a mock RuntimeConfig for testing."""
    return RuntimeConfig(
        config_file=str(Path.home() / ".oci" / "config"),
        profile="DEFAULT",
        auth_mode="security_token",
        non_interactive=True,
        auto_use_existing=False,
        auto_deploy=False,
        terraform_dir=temp_dir / "terraform",
        tenancy_ocid="ocid1.tenancy.oc1..test",
        region="us-phoenix-1",
        strict_provider_parity=True,
    )


@pytest.fixture
def mock_oci_context():
    """Provide a mock OciContext for testing."""
    return OciContext(
        config={"DEFAULT": {"region": "us-phoenix-1"}},
        signer=None,
        tenancy_ocid="ocid1.tenancy.oc1..exampletenancy",
        user_ocid="ocid1.user.oc1..exampleuser",
        region="us-phoenix-1",
        availability_domain="phx-AD-1",
        ubuntu_x86_image_ocid="ocid1.image.oc1.phx..ubuntu2204",
        ubuntu_arm_image_ocid="ocid1.image.oc1.phx..ubuntuarm2204",
    )


@pytest.fixture
def mock_planned_config_amd():
    """Provide a basic AMD instance configuration."""
    return PlannedConfig(
        amd_micro_instance_count=2,
        amd_micro_boot_volume_size_gb=50,
        amd_micro_hostnames=["amd-1", "amd-2"],
        amd_block_volume_size_gb=0,
        arm_flex_instance_count=0,
        arm_flex_ocpus_per_instance=[],
        arm_flex_memory_per_instance=[],
        arm_flex_boot_volume_size_gb=[],
        arm_flex_hostnames=[],
        arm_block_volume_sizes=[],
    )


@pytest.fixture
def mock_planned_config_arm():
    """Provide a basic ARM instance configuration."""
    return PlannedConfig(
        amd_micro_instance_count=0,
        amd_micro_boot_volume_size_gb=50,
        amd_micro_hostnames=[],
        amd_block_volume_size_gb=0,
        arm_flex_instance_count=1,
        arm_flex_ocpus_per_instance=[4],
        arm_flex_memory_per_instance=[24],
        arm_flex_boot_volume_size_gb=[200],
        arm_flex_hostnames=["arm-1"],
        arm_block_volume_sizes=[0],
    )


@pytest.fixture
def mock_planned_config_mixed():
    """Provide a mixed AMD+ARM configuration."""
    return PlannedConfig(
        amd_micro_instance_count=1,
        amd_micro_boot_volume_size_gb=50,
        amd_micro_hostnames=["amd-1"],
        amd_block_volume_size_gb=0,
        arm_flex_instance_count=1,
        arm_flex_ocpus_per_instance=[4],
        arm_flex_memory_per_instance=[24],
        arm_flex_boot_volume_size_gb=[200],
        arm_flex_hostnames=["arm-1"],
        arm_block_volume_sizes=[0],
    )


@pytest.fixture
def mock_oci_clients(monkeypatch):
    """Mock OCI SDK clients."""
    mock_identity = MagicMock()
    mock_compute = MagicMock()
    mock_network = MagicMock()
    mock_block = MagicMock()

    # Setup mock responses
    mock_identity.get_tenancy.return_value = Mock(
        data=Mock(id="ocid1.tenancy.oc1..test")
    )
    mock_identity.list_regions.return_value = Mock(
        data=[Mock(name="us-phoenix-1", key="PHX")]
    )

    return {
        "identity": mock_identity,
        "compute": mock_compute,
        "network": mock_network,
        "block": mock_block,
    }


@pytest.fixture
def mock_existing_resources():
    """Provide pre-initialized ExistingResources."""
    resources = ExistingResources()
    resources.vcns["ocid1.vcn.oc1..test"] = "main-vcn"
    resources.subnets["ocid1.subnet.oc1..test"] = "main-subnet"
    resources.amd_instances["ocid1.instance.oc1..amd1"] = "amd-instance-1"
    resources.arm_instances["ocid1.instance.oc1..arm1"] = "arm-instance-1"
    return resources

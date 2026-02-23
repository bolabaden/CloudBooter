"""Integration tests for CloudBooter components."""

import pytest
from pathlib import Path
from cloudbooter.cli import (
    CloudBooterWorkflow,
    RuntimeConfig,
    PlannedConfig,
    ExistingResources,
)


class TestWorkflowIntegration:
    """Test integration between workflow components."""

    def test_workflow_with_temp_directory(self, temp_dir, mock_runtime_config):
        """Test workflow works with temporary directory setup."""
        mock_runtime_config.terraform_dir = temp_dir / "tf"

        workflow = CloudBooterWorkflow(mock_runtime_config)
        workflow.runtime.terraform_dir.mkdir(parents=True, exist_ok=True)

        assert workflow.runtime.terraform_dir.exists()
        assert workflow.resources is not None

    def test_existing_resources_tracking(self):
        """Test ExistingResources can track multiple resource types."""
        resources = ExistingResources()

        # Add resources
        resources.vcns["vcn-id-1"] = "main-vcn"
        resources.subnets["subnet-id-1"] = "main-subnet"
        resources.amd_instances["amd-id-1"] = "amd-instance-1"
        resources.arm_instances["arm-id-1"] = "arm-instance-1"

        # Verify tracking
        assert len(resources.vcns) == 1
        assert len(resources.subnets) == 1
        assert len(resources.amd_instances) == 1
        assert len(resources.arm_instances) == 1

    def test_planned_config_storage_calculation(self):
        """Test PlannedConfig calculates total storage correctly."""
        config = PlannedConfig(
            amd_micro_instance_count=1,
            amd_micro_boot_volume_size_gb=50,
            amd_micro_hostnames=["amd-1"],
            amd_block_volume_size_gb=100,
            arm_flex_instance_count=1,
            arm_flex_ocpus_per_instance=[4],
            arm_flex_memory_per_instance=[24],
            arm_flex_boot_volume_size_gb=[200],
            arm_flex_hostnames=["arm-1"],
            arm_block_volume_sizes=[50],
        )

        # Calculate totals
        amd_storage = (
            1 * 50 + 1 * 100
        )  # 1 instance * 50GB boot + 1 * 100GB block
        arm_storage = 1 * 200 + 1 * 50  # 1 instance * 200GB boot + 50GB block
        total = amd_storage + arm_storage

        assert total == 400  # 150 + 250


class TestMultipleConfigVariants:
    """Test workflow handles multiple configuration variants."""

    def test_amd_variant_single_instance(self, mock_runtime_config):
        """Test workflow with single AMD instance."""
        config = PlannedConfig(
            amd_micro_instance_count=1,
            amd_micro_boot_volume_size_gb=50,
            amd_micro_hostnames=["single-amd"],
            amd_block_volume_size_gb=0,
            arm_flex_instance_count=0,
            arm_flex_ocpus_per_instance=[],
            arm_flex_memory_per_instance=[],
            arm_flex_boot_volume_size_gb=[],
            arm_flex_hostnames=[],
            arm_block_volume_sizes=[],
        )

        workflow = CloudBooterWorkflow(mock_runtime_config)
        # Should not raise
        workflow._validate_proposed_config(config)

    def test_arm_variant_max_resources(self, mock_runtime_config):
        """Test workflow with maximum ARM resources."""
        config = PlannedConfig(
            amd_micro_instance_count=0,
            amd_micro_boot_volume_size_gb=50,
            amd_micro_hostnames=[],
            amd_block_volume_size_gb=0,
            arm_flex_instance_count=1,
            arm_flex_ocpus_per_instance=[4],
            arm_flex_memory_per_instance=[24],
            arm_flex_boot_volume_size_gb=[200],
            arm_flex_hostnames=["max-arm"],
            arm_block_volume_sizes=[0],
        )

        workflow = CloudBooterWorkflow(mock_runtime_config)
        # Should not raise
        workflow._validate_proposed_config(config)

    def test_mixed_variant_balanced(self, mock_runtime_config):
        """Test workflow with balanced mixed config."""
        config = PlannedConfig(
            amd_micro_instance_count=2,
            amd_micro_boot_volume_size_gb=50,
            amd_micro_hostnames=["amd-1", "amd-2"],
            amd_block_volume_size_gb=0,
            arm_flex_instance_count=1,
            arm_flex_ocpus_per_instance=[2],
            arm_flex_memory_per_instance=[12],
            arm_flex_boot_volume_size_gb=[50],
            arm_flex_hostnames=["arm-1"],
            arm_block_volume_sizes=[0],
        )

        workflow = CloudBooterWorkflow(mock_runtime_config)
        # Should not raise
        workflow._validate_proposed_config(config)


class TestRuntimeConfigVariants:
    """Test workflow with different runtime configurations."""

    def test_non_interactive_mode(self, temp_dir):
        """Test workflow in non-interactive mode."""
        config = RuntimeConfig(
            config_file="~/.oci/config",
            profile="DEFAULT",
            auth_mode="security_token",
            non_interactive=True,  # Non-interactive
            auto_use_existing=False,
            auto_deploy=False,
            terraform_dir=temp_dir / "terraform",
            tenancy_ocid="ocid1.test",
            region="us-phoenix-1",
            strict_provider_parity=True,
        )

        workflow = CloudBooterWorkflow(config)
        assert workflow.runtime.non_interactive is True

    def test_interactive_mode(self, temp_dir):
        """Test workflow in interactive mode."""
        config = RuntimeConfig(
            config_file="~/.oci/config",
            profile="DEFAULT",
            auth_mode="security_token",
            non_interactive=False,  # Interactive
            auto_use_existing=False,
            auto_deploy=False,
            terraform_dir=temp_dir / "terraform",
            tenancy_ocid="ocid1.test",
            region="us-phoenix-1",
            strict_provider_parity=True,
        )

        workflow = CloudBooterWorkflow(config)
        assert workflow.runtime.non_interactive is False

    def test_auto_deploy_mode(self, temp_dir):
        """Test workflow with auto-deploy enabled."""
        config = RuntimeConfig(
            config_file="~/.oci/config",
            profile="DEFAULT",
            auth_mode="security_token",
            non_interactive=True,
            auto_use_existing=True,
            auto_deploy=True,  # Auto-deploy
            terraform_dir=temp_dir / "terraform",
            tenancy_ocid="ocid1.test",
            region="us-phoenix-1",
            strict_provider_parity=True,
        )

        workflow = CloudBooterWorkflow(config)
        assert workflow.runtime.auto_deploy is True
        assert workflow.runtime.auto_use_existing is True


class TestFileSystemOperations:
    """Test file system operations in integration context."""

    def test_terraform_directory_isolation(self, temp_dir):
        """Test each workflow gets isolated Terraform directory."""
        tf_dir1 = temp_dir / "work1"
        tf_dir2 = temp_dir / "work2"

        config1 = RuntimeConfig(
            config_file="~/.oci/config",
            profile="DEFAULT",
            auth_mode="security_token",
            non_interactive=True,
            auto_use_existing=False,
            auto_deploy=False,
            terraform_dir=tf_dir1,
            tenancy_ocid="ocid1.test",
            region="us-phoenix-1",
            strict_provider_parity=True,
        )
        config2 = RuntimeConfig(
            config_file="~/.oci/config",
            profile="DEFAULT",
            auth_mode="security_token",
            non_interactive=True,
            auto_use_existing=False,
            auto_deploy=False,
            terraform_dir=tf_dir2,
            tenancy_ocid="ocid1.test",
            region="us-phoenix-1",
            strict_provider_parity=True,
        )

        workflow1 = CloudBooterWorkflow(config1)
        workflow2 = CloudBooterWorkflow(config2)

        workflow1.runtime.terraform_dir.mkdir(parents=True, exist_ok=True)
        workflow2.runtime.terraform_dir.mkdir(parents=True, exist_ok=True)

        assert tf_dir1 != tf_dir2
        assert tf_dir1.exists()
        assert tf_dir2.exists()

    def test_ssh_key_persistence(self, temp_dir):
        """Test SSH keys persist in filesystem."""
        config = RuntimeConfig(
            config_file="~/.oci/config",
            profile="DEFAULT",
            auth_mode="security_token",
            non_interactive=True,
            auto_use_existing=False,
            auto_deploy=False,
            terraform_dir=temp_dir / "terraform",
            tenancy_ocid="ocid1.test",
            region="us-phoenix-1",
            strict_provider_parity=True,
        )

        workflow = CloudBooterWorkflow(config)
        ssh_dir = temp_dir / "ssh_keys"
        ssh_dir.mkdir(parents=True, exist_ok=True)

        workflow._generate_ssh_keys(ssh_dir)

        # Verify keys exist
        assert (ssh_dir / "id_rsa").exists()
        assert (ssh_dir / "id_rsa.pub").exists()

        # Read and verify content
        private_content = (ssh_dir / "id_rsa").read_text()
        public_content = (ssh_dir / "id_rsa.pub").read_text()

        assert len(private_content) > 0
        assert len(public_content) > 0

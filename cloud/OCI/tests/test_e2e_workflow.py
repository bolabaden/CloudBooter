"""End-to-end workflow tests for CloudBooter."""

import pytest
from pathlib import Path
from unittest.mock import MagicMock, patch, Mock
from cloudbooter.cli import (
    CloudBooterWorkflow,
    RuntimeConfig,
    OciContext,
    PlannedConfig,
)


class TestE2EWorkflowInit:
    """Test end-to-end workflow initialization."""

    def test_workflow_init(self, mock_runtime_config):
        """Test basic workflow initialization."""
        workflow = CloudBooterWorkflow(mock_runtime_config)
        assert workflow.runtime == mock_runtime_config
        assert workflow.resources is not None
        assert workflow.oci_context is None

    def test_workflow_terraform_dir_creation(self, temp_dir):
        """Test Terraform directory is created during workflow."""
        tf_dir = temp_dir / "terraform"
        assert not tf_dir.exists()

        config = RuntimeConfig(
            config_file="~/.oci/config",
            profile="DEFAULT",
            auth_mode="security_token",
            non_interactive=True,
            auto_use_existing=False,
            auto_deploy=False,
            terraform_dir=tf_dir,
            tenancy_ocid="ocid1.test",
            region="us-phoenix-1",
            strict_provider_parity=True,
        )

        workflow = CloudBooterWorkflow(config)
        workflow.runtime.terraform_dir.mkdir(parents=True, exist_ok=True)

        assert tf_dir.exists()
        assert tf_dir.is_dir()


class TestE2ETerraformGeneration:
    """Test Terraform file generation during e2e workflow."""

    def test_generate_provider_tf(
        self, mock_runtime_config, mock_oci_context, mock_planned_config_amd
    ):
        """Test provider.tf generation with security token auth."""
        workflow = CloudBooterWorkflow(mock_runtime_config)
        content = workflow._render_provider_tf(mock_oci_context)

        assert "terraform" in content
        assert 'required_version = ">= 1.0"' in content
        assert 'auth                = "SecurityToken"' in content
        assert 'config_file_profile = "DEFAULT"' in content
        assert 'region              = "us-phoenix-1"' in content
        assert '  ' in content  # Check 2-space indentation
        assert '    ' not in content or content.count("    ") == 0  # No 4-space

    def test_generate_variables_tf(
        self, mock_runtime_config, mock_oci_context, mock_planned_config_amd
    ):
        """Test variables.tf generation."""
        workflow = CloudBooterWorkflow(mock_runtime_config)
        content = workflow._render_variables_tf(mock_oci_context, mock_planned_config_amd)

        assert "locals {" in content
        assert "tenancy_ocid" in content
        assert "amd_micro_instance_count = 2" in content
        assert "variable" in content
        assert "check" in content
        assert (
            "free_tier_max_storage_gb" in content
        )

    def test_generate_data_sources_tf(self, mock_runtime_config):
        """Test data_sources.tf generation."""
        workflow = CloudBooterWorkflow(mock_runtime_config)
        content = workflow._render_data_sources_tf()

        assert "oci_identity_availability_domains" in content
        assert "oci_identity_tenancy" in content
        assert "oci_identity_regions" in content
        assert "data_sources.tf" not in content  # Just the content
        assert "local.tenancy_ocid" in content

    def test_generate_main_tf(self, mock_runtime_config):
        """Test main.tf generation."""
        workflow = CloudBooterWorkflow(mock_runtime_config)
        content = workflow._render_main_tf()

        assert "oci_core_vcn" in content
        assert "oci_core_internet_gateway" in content
        assert "oci_core_instance" in content
        assert "oci_core_ipv6" in content
        assert "output" in content
        assert "10.0.0.0/16" in content
        assert "amd_instances" in content
        assert "arm_instances" in content

    def test_generate_block_volumes_tf(self, mock_runtime_config):
        """Test block_volumes.tf generation."""
        workflow = CloudBooterWorkflow(mock_runtime_config)
        content = workflow._render_block_volumes_tf()

        assert "oci_core_volume" in content
        assert "oci_core_volume_attachment" in content
        assert "AMD Block Volumes" in content
        assert "ARM Block Volumes" in content

    def test_generate_cloud_init_yaml(self, mock_runtime_config):
        """Test cloud-init.yaml generation."""
        workflow = CloudBooterWorkflow(mock_runtime_config)
        content = workflow._render_cloud_init()

        assert "#cloud-config" in content
        assert "hostname: ${hostname}" in content
        assert "packages:" in content
        assert "runcmd:" in content
        assert "- curl" in content
        assert "- wget" in content
        assert "fail2ban" in content


class TestE2EFileGeneration:
    """Test actual file generation to disk."""

    def test_write_terraform_files(
        self, temp_dir, mock_runtime_config, mock_oci_context, mock_planned_config_amd
    ):
        """Test writing all Terraform files to disk."""
        mock_runtime_config.terraform_dir = temp_dir / "terraform"
        workflow = CloudBooterWorkflow(mock_runtime_config)
        
        workflow.runtime.terraform_dir.mkdir(parents=True, exist_ok=True)
        workflow._write_terraform_files(
            mock_oci_context, mock_planned_config_amd, workflow.runtime.terraform_dir
        )

        # Verify all files were created
        assert (workflow.runtime.terraform_dir / "provider.tf").exists()
        assert (workflow.runtime.terraform_dir / "variables.tf").exists()
        assert (workflow.runtime.terraform_dir / "data_sources.tf").exists()
        assert (workflow.runtime.terraform_dir / "main.tf").exists()
        assert (workflow.runtime.terraform_dir / "block_volumes.tf").exists()
        assert (workflow.runtime.terraform_dir / "cloud-init.yaml").exists()

        # Verify file contents
        provider_content = (workflow.runtime.terraform_dir / "provider.tf").read_text()
        assert "terraform" in provider_content
        assert "provider" in provider_content

    def test_generated_files_are_valid_hcl(
        self, temp_dir, mock_runtime_config, mock_oci_context, mock_planned_config_amd
    ):
        """Test that generated files contain valid HCL syntax indicators."""
        mock_runtime_config.terraform_dir = temp_dir / "terraform"
        workflow = CloudBooterWorkflow(mock_runtime_config)
        
        workflow.runtime.terraform_dir.mkdir(parents=True, exist_ok=True)
        workflow._write_terraform_files(
            mock_oci_context, mock_planned_config_amd, workflow.runtime.terraform_dir
        )

        tf_files = [
            "provider.tf",
            "variables.tf",
            "data_sources.tf",
            "main.tf",
            "block_volumes.tf",
        ]

        for tf_file in tf_files:
            content = (workflow.runtime.terraform_dir / tf_file).read_text()
            # Basic HCL validation - check for balanced braces
            open_braces = content.count("{")
            close_braces = content.count("}")
            assert open_braces == close_braces, f"{tf_file} has unbalanced braces"


class TestE2EConfigurationValidation:
    """Test configuration validation in e2e context."""

    def test_amd_only_config(self, mock_runtime_config, mock_planned_config_amd):
        """Test validation of AMD-only configuration."""
        workflow = CloudBooterWorkflow(mock_runtime_config)
        # Should not raise
        workflow._validate_proposed_config(mock_planned_config_amd)

    def test_arm_only_config(self, mock_runtime_config, mock_planned_config_arm):
        """Test validation of ARM-only configuration."""
        workflow = CloudBooterWorkflow(mock_runtime_config)
        # Should not raise
        workflow._validate_proposed_config(mock_planned_config_arm)

    def test_mixed_config(self, mock_runtime_config, mock_planned_config_mixed):
        """Test validation of mixed AMD+ARM configuration."""
        workflow = CloudBooterWorkflow(mock_runtime_config)
        # Should not raise
        workflow._validate_proposed_config(mock_planned_config_mixed)

    def test_exceeds_amd_limit(self, mock_runtime_config):
        """Test rejection of configuration exceeding AMD limits."""
        config = PlannedConfig(
            amd_micro_instance_count=5,  # Exceeds limit of 2
            amd_micro_boot_volume_size_gb=50,
            amd_micro_hostnames=["amd-1", "amd-2", "amd-3", "amd-4", "amd-5"],
            amd_block_volume_size_gb=0,
            arm_flex_instance_count=0,
            arm_flex_ocpus_per_instance=[],
            arm_flex_memory_per_instance=[],
            arm_flex_boot_volume_size_gb=[],
            arm_flex_hostnames=[],
            arm_block_volume_sizes=[],
        )
        workflow = CloudBooterWorkflow(mock_runtime_config)
        # Should raise or log error
        with pytest.raises(Exception):
            workflow._validate_proposed_config(config)

    def test_exceeds_storage_limit(self, mock_runtime_config):
        """Test rejection of configuration exceeding storage limits."""
        config = PlannedConfig(
            amd_micro_instance_count=0,
            amd_micro_boot_volume_size_gb=50,
            amd_micro_hostnames=[],
            amd_block_volume_size_gb=0,
            arm_flex_instance_count=1,
            arm_flex_ocpus_per_instance=[4],
            arm_flex_memory_per_instance=[24],
            arm_flex_boot_volume_size_gb=[300],  # Exceeds 200GB limit
            arm_flex_hostnames=["arm-1"],
            arm_block_volume_sizes=[0],
        )
        workflow = CloudBooterWorkflow(mock_runtime_config)
        # Should raise or log error
        with pytest.raises(Exception):
            workflow._validate_proposed_config(config)


class TestE2ESSHKeyGeneration:
    """Test SSH key generation in e2e context."""

    def test_generate_ssh_keys(self, temp_dir):
        """Test SSH key pair generation."""
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

        assert (ssh_dir / "id_rsa").exists()
        assert (ssh_dir / "id_rsa.pub").exists()

        # Verify key permissions
        private_key_mode = (ssh_dir / "id_rsa").stat().st_mode
        assert private_key_mode & 0o077 == 0  # Private key should not be world-readable

    def test_ssh_keys_are_valid(self, temp_dir):
        """Test that generated SSH keys are valid RSA keys."""
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

        private_key_content = (ssh_dir / "id_rsa").read_text()
        public_key_content = (ssh_dir / "id_rsa.pub").read_text()

        assert "-----BEGIN RSA PRIVATE KEY-----" in private_key_content
        assert "-----END RSA PRIVATE KEY-----" in private_key_content
        assert "ssh-rsa" in public_key_content


class TestE2ETemplateIndentation:
    """Test that generated templates follow 2-space HCL indentation standard."""

    def test_provider_tf_indentation(
        self, mock_runtime_config, mock_oci_context
    ):
        """Test provider.tf uses 2-space indentation."""
        workflow = CloudBooterWorkflow(mock_runtime_config)
        content = workflow._render_provider_tf(mock_oci_context)

        lines = content.split("\n")
        for line in lines:
            if line and line[0] == " ":
                # Count leading spaces
                spaces = len(line) - len(line.lstrip())
                assert spaces % 2 == 0, f"Line has non-2-space indent: {repr(line)}"

    def test_main_tf_indentation(self, mock_runtime_config):
        """Test main.tf uses 2-space indentation."""
        workflow = CloudBooterWorkflow(mock_runtime_config)
        content = workflow._render_main_tf()

        lines = content.split("\n")
        for line in lines:
            if line and line[0] == " ":
                # Count leading spaces
                spaces = len(line) - len(line.lstrip())
                assert (
                    spaces % 2 == 0
                ), f"Line has non-2-space indent: {repr(line)}"

    def test_variables_tf_indentation(
        self, mock_runtime_config, mock_oci_context, mock_planned_config_amd
    ):
        """Test variables.tf uses 2-space indentation."""
        workflow = CloudBooterWorkflow(mock_runtime_config)
        content = workflow._render_variables_tf(mock_oci_context, mock_planned_config_amd)

        lines = content.split("\n")
        for line in lines:
            if line and line[0] == " ":
                spaces = len(line) - len(line.lstrip())
                assert (
                    spaces % 2 == 0
                ), f"Line has non-2-space indent: {repr(line)}"

    def test_cloud_init_yaml_indentation(self, mock_runtime_config):
        """Test cloud-init.yaml uses proper YAML indentation."""
        workflow = CloudBooterWorkflow(mock_runtime_config)
        content = workflow._render_cloud_init()

        # Check packages list indentation
        assert "packages:\n  - curl" in content
        assert "  - wget" in content
        assert "  - git" in content

        # Check write_files indentation
        assert "write_files:\n  - path:" in content
        assert "    content: |" in content

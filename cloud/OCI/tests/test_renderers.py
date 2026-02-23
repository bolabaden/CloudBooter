"""Test template renderers for correctness and parity with Bash."""

import pytest
from cloudbooter.cli import CloudBooterWorkflow, RuntimeConfig, OciContext, PlannedConfig


class TestProviderRenderer:
    """Test provider.tf renderer output."""

    def test_strict_provider_parity_session_token(
        self, mock_runtime_config, mock_oci_context
    ):
        """Test provider.tf with strict parity and session token."""
        mock_runtime_config.auth_mode = "security_token"
        mock_runtime_config.strict_provider_parity = True

        workflow = CloudBooterWorkflow(mock_runtime_config)
        content = workflow._render_provider_tf(mock_oci_context)

        # Check required blocks
        assert "terraform {" in content
        assert "required_version" in content
        assert "required_providers {" in content
        assert 'source  = "oracle/oci"' in content
        assert 'version = "~> 6.0"' in content

        # Check provider block with session token
        assert "provider \"oci\" {" in content
        assert 'auth                = "SecurityToken"' in content
        assert 'config_file_profile = "DEFAULT"' in content
        assert 'region              = "us-phoenix-1"' in content

    def test_provider_api_key_auth(self, mock_runtime_config, mock_oci_context):
        """Test provider.tf with API key auth."""
        mock_runtime_config.auth_mode = "api_key"
        mock_runtime_config.strict_provider_parity = False

        workflow = CloudBooterWorkflow(mock_runtime_config)
        content = workflow._render_provider_tf(mock_oci_context)

        assert 'auth = "APIKey"' in content

    def test_provider_instance_principal_auth(
        self, mock_runtime_config, mock_oci_context
    ):
        """Test provider.tf with instance principal auth."""
        mock_runtime_config.auth_mode = "instance_principal"
        mock_runtime_config.strict_provider_parity = False

        workflow = CloudBooterWorkflow(mock_runtime_config)
        content = workflow._render_provider_tf(mock_oci_context)

        assert 'auth = "InstancePrincipal"' in content


class TestVariablesRenderer:
    """Test variables.tf renderer output."""

    def test_variables_amd_only(
        self, mock_runtime_config, mock_oci_context, mock_planned_config_amd
    ):
        """Test variables.tf with AMD-only config."""
        workflow = CloudBooterWorkflow(mock_runtime_config)
        content = workflow._render_variables_tf(mock_oci_context, mock_planned_config_amd)

        # Check locals block
        assert "locals {" in content
        assert 'tenancy_ocid    = "ocid1.tenancy.oc1..exampletenancy"' in content
        assert 'region          = "us-phoenix-1"' in content

        # Check AMD config
        assert "amd_micro_instance_count      = 2" in content
        assert 'amd_micro_hostnames           = ["amd-1", "amd-2"]' in content

        # Check ARM is empty
        assert "arm_flex_instance_count       = 0" in content

    def test_variables_arm_only(
        self, mock_runtime_config, mock_oci_context, mock_planned_config_arm
    ):
        """Test variables.tf with ARM-only config."""
        workflow = CloudBooterWorkflow(mock_runtime_config)
        content = workflow._render_variables_tf(mock_oci_context, mock_planned_config_arm)

        # Check ARM config
        assert "arm_flex_instance_count       = 1" in content
        assert "arm_flex_ocpus_per_instance   = [4]" in content
        assert "arm_flex_memory_per_instance  = [24]" in content
        assert 'arm_flex_hostnames            = ["arm-1"]' in content

        # Check AMD is empty
        assert "amd_micro_instance_count      = 0" in content

    def test_variables_mixed_config(
        self, mock_runtime_config, mock_oci_context, mock_planned_config_mixed
    ):
        """Test variables.tf with mixed AMD+ARM config."""
        workflow = CloudBooterWorkflow(mock_runtime_config)
        content = workflow._render_variables_tf(mock_oci_context, mock_planned_config_mixed)

        # Check both AMD and ARM present
        assert "amd_micro_instance_count      = 1" in content
        assert 'amd_micro_hostnames           = ["amd-1"]' in content
        assert "arm_flex_instance_count       = 1" in content
        assert 'arm_flex_hostnames            = ["arm-1"]' in content

    def test_variables_free_tier_checks(
        self, mock_runtime_config, mock_oci_context, mock_planned_config_amd
    ):
        """Test that variables.tf includes Free Tier validation checks."""
        workflow = CloudBooterWorkflow(mock_runtime_config)
        content = workflow._render_variables_tf(mock_oci_context, mock_planned_config_amd)

        # Check validation checks
        assert 'check "storage_limit"' in content
        assert 'check "arm_ocpu_limit"' in content
        assert 'check "arm_memory_limit"' in content

        # Check limit variables
        assert "free_tier_max_storage_gb" in content
        assert "free_tier_max_arm_ocpus" in content
        assert "free_tier_max_arm_memory_gb" in content


class TestMainTFRenderer:
    """Test main.tf renderer output."""

    def test_main_tf_networking_resources(self, mock_runtime_config):
        """Test main.tf includes all networking resources."""
        workflow = CloudBooterWorkflow(mock_runtime_config)
        content = workflow._render_main_tf()

        # Check VCN
        assert 'resource "oci_core_vcn" "main"' in content
        assert 'cidr_blocks    = ["10.0.0.0/16"]' in content

        # Check Internet Gateway
        assert 'resource "oci_core_internet_gateway" "main"' in content

        # Check Route Table
        assert 'resource "oci_core_default_route_table" "main"' in content
        assert '"0.0.0.0/0"' in content
        assert '"::/0"' in content

        # Check Security List
        assert 'resource "oci_core_default_security_list" "main"' in content

        # Check Subnet
        assert 'resource "oci_core_subnet" "main"' in content

    def test_main_tf_compute_resources(self, mock_runtime_config):
        """Test main.tf includes all compute resources."""
        workflow = CloudBooterWorkflow(mock_runtime_config)
        content = workflow._render_main_tf()

        # Check AMD instances
        assert 'resource "oci_core_instance" "amd"' in content
        assert 'shape = "VM.Standard.E2.1.Micro"' in content

        # Check ARM instances
        assert 'resource "oci_core_instance" "arm"' in content
        assert 'shape = "VM.Standard.A1.Flex"' in content

        # Check IPv6 resources
        assert 'resource "oci_core_ipv6" "amd_ipv6"' in content
        assert 'resource "oci_core_ipv6" "arm_ipv6"' in content

    def test_main_tf_outputs(self, mock_runtime_config):
        """Test main.tf includes all expected outputs."""
        workflow = CloudBooterWorkflow(mock_runtime_config)
        content = workflow._render_main_tf()

        # Check output blocks
        assert 'output "amd_instances"' in content
        assert 'output "arm_instances"' in content
        assert 'output "network"' in content
        assert 'output "summary"' in content

        # Check output properties
        assert '"id"' in content
        assert '"public_ip"' in content
        assert '"private_ip"' in content
        assert '"state"' in content

    def test_main_tf_security_ingress_rules(self, mock_runtime_config):
        """Test main.tf security list includes all ingress rules."""
        workflow = CloudBooterWorkflow(mock_runtime_config)
        content = workflow._render_main_tf()

        # Check SSH ports
        assert "min = 22" in content and "max = 22" in content

        # Check HTTP
        assert "min = 80" in content and "max = 80" in content

        # Check HTTPS
        assert "min = 443" in content and "max = 443" in content

        # Check ICMP
        assert 'protocol = "1"' in content


class TestBlockVolumesRenderer:
    """Test block_volumes.tf renderer output."""

    def test_block_volumes_structure(self, mock_runtime_config):
        """Test block_volumes.tf has correct resource structure."""
        workflow = CloudBooterWorkflow(mock_runtime_config)
        content = workflow._render_block_volumes_tf()

        # Check AMD block volume resources
        assert 'resource "oci_core_volume" "amd_block"' in content
        assert 'resource "oci_core_volume_attachment" "amd_block"' in content

        # Check ARM block volume resources
        assert 'resource "oci_core_volume" "arm_block"' in content
        assert 'resource "oci_core_volume_attachment" "arm_block"' in content

        # Check count conditions
        assert "count =" in content
        assert "paravirtualized" in content


class TestCloudInitRenderer:
    """Test cloud-init.yaml renderer output."""

    def test_cloud_init_header(self, mock_runtime_config):
        """Test cloud-init.yaml starts with correct header."""
        workflow = CloudBooterWorkflow(mock_runtime_config)
        content = workflow._render_cloud_init()

        assert content.startswith("#cloud-config")

    def test_cloud_init_packages(self, mock_runtime_config):
        """Test cloud-init.yaml includes all required packages."""
        workflow = CloudBooterWorkflow(mock_runtime_config)
        content = workflow._render_cloud_init()

        required_packages = [
            "curl",
            "wget",
            "git",
            "htop",
            "vim",
            "unzip",
            "jq",
            "tmux",
            "net-tools",
            "iotop",
            "ncdu",
        ]

        for package in required_packages:
            assert f"- {package}" in content

    def test_cloud_init_runcmd(self, mock_runtime_config):
        """Test cloud-init.yaml runcmd section."""
        workflow = CloudBooterWorkflow(mock_runtime_config)
        content = workflow._render_cloud_init()

        assert "runcmd:" in content
        assert "fail2ban" in content

    def test_cloud_init_ssh_hardening(self, mock_runtime_config):
        """Test cloud-init.yaml SSH hardening configuration."""
        workflow = CloudBooterWorkflow(mock_runtime_config)
        content = workflow._render_cloud_init()

        assert "/etc/ssh/sshd_config.d/hardening.conf" in content
        assert "PermitRootLogin no" in content
        assert "PasswordAuthentication no" in content
        assert "MaxAuthTries 3" in content

    def test_cloud_init_final_message(self, mock_runtime_config):
        """Test cloud-init.yaml includes final message."""
        workflow = CloudBooterWorkflow(mock_runtime_config)
        content = workflow._render_cloud_init()

        assert "final_message:" in content
        assert "ready after" in content


class TestDataSourcesRenderer:
    """Test data_sources.tf renderer output."""

    def test_data_sources_availability_domains(self, mock_runtime_config):
        """Test data_sources.tf queries availability domains."""
        workflow = CloudBooterWorkflow(mock_runtime_config)
        content = workflow._render_data_sources_tf()

        assert 'data "oci_identity_availability_domains" "ads"' in content

    def test_data_sources_tenancy(self, mock_runtime_config):
        """Test data_sources.tf queries tenancy info."""
        workflow = CloudBooterWorkflow(mock_runtime_config)
        content = workflow._render_data_sources_tf()

        assert 'data "oci_identity_tenancy" "tenancy"' in content

    def test_data_sources_regions(self, mock_runtime_config):
        """Test data_sources.tf queries available regions."""
        workflow = CloudBooterWorkflow(mock_runtime_config)
        content = workflow._render_data_sources_tf()

        assert 'data "oci_identity_regions" "regions"' in content
        assert 'data "oci_identity_region_subscriptions" "subscriptions"' in content

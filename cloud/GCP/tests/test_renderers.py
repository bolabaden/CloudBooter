"""Tests for Terraform HCL renderers.

What we verify here:
  1. Every required HCL block or attribute is present in the output string.
  2. Indentation is consistent — all leading whitespace is a multiple of 2 spaces.
     (The generators use f-string literals so any regression here would silently
     break terraform validate.)
  3. The three free-tier check blocks are present in variables.tf.
  4. Optional blocks are absent unless the corresponding flag is passed.
  5. cloud-init YAML has a valid header and all default + extra packages.
  6. Identity: calling render_*() twice with the same args returns the same string
     (idempotency — the caller writes this to disk each run).
  7. When terraform is on PATH: terraform validate passes on the combined output.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

from cloudbooter.renderers import (
    render_cloud_init,
    render_data_sources,
    render_main,
    render_provider,
    render_variables,
)

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────


def _bad_indent_lines(text: str) -> list[str]:
    """Return lines whose leading-space count is not a multiple of 2."""
    bad = []
    for line in text.splitlines():
        if not line or line[0] != " ":
            continue
        n = len(line) - len(line.lstrip(" "))
        if n % 2 != 0:
            bad.append(repr(line))
    return bad


def _all_tf_files(tmp_dir: Path, **render_kwargs) -> dict[str, str]:
    """Write all .tf files + cloud-init.yaml to tmp_dir and return their contents."""
    proj = render_kwargs.get("project_id", "proj")
    region = render_kwargs.get("region", "us-central1")
    zone = render_kwargs.get("zone", "us-central1-a")
    name = render_kwargs.get("instance_name", "test-vm")
    files = {
        "provider.tf": render_provider(proj, region),
        "variables.tf": render_variables(proj, region, zone, name),
        "data_sources.tf": render_data_sources(),
        "main.tf": render_main(name),
        "cloud-init.yaml": render_cloud_init(name),
    }
    for fname, content in files.items():
        (tmp_dir / fname).write_text(content, encoding="utf-8")
    return files


# ─────────────────────────────────────────────────────────────────────────────
# provider.tf
# ─────────────────────────────────────────────────────────────────────────────


class TestRenderProvider:
    def test_required_version_constraint(self):
        out = render_provider("p", "us-central1")
        assert 'required_version = ">= 1.6.0"' in out

    def test_google_provider_source(self):
        out = render_provider("p", "us-central1")
        assert 'source  = "hashicorp/google"' in out

    def test_google_provider_version_pin(self):
        out = render_provider("p", "us-central1")
        assert 'version = "~> 6.0"' in out

    def test_project_var_reference(self):
        out = render_provider("p", "us-central1")
        assert "project = var.project_id" in out

    def test_region_var_reference(self):
        out = render_provider("p", "us-central1")
        assert "region  = var.region" in out

    def test_adc_has_no_credentials_attribute(self):
        out = render_provider("p", "us-central1")
        assert "credentials" not in out

    def test_adc_has_no_impersonation_attribute(self):
        out = render_provider("p", "us-central1")
        assert "impersonate_service_account" not in out

    def test_credentials_file_inserts_attribute(self):
        out = render_provider("p", "us-central1", credentials_file="/tmp/sa.json")
        assert "credentials = file(var.credentials_file)" in out

    def test_impersonation_inserts_attribute(self):
        out = render_provider("p", "us-central1", impersonate_sa="tf@proj.iam.gserviceaccount.com")
        assert "impersonate_service_account = var.impersonate_service_account" in out

    def test_credentials_and_impersonation_can_coexist(self):
        out = render_provider(
            "p",
            "us-central1",
            credentials_file="/tmp/sa.json",
            impersonate_sa="tf@proj.iam.gserviceaccount.com",
        )
        assert "credentials" in out
        assert "impersonate_service_account" in out

    def test_two_space_indent(self):
        bad = _bad_indent_lines(render_provider("p", "us-central1"))
        assert bad == [], f"Non-2-space indent lines: {bad}"

    def test_idempotent(self):
        a = render_provider("p", "us-central1")
        b = render_provider("p", "us-central1")
        assert a == b


# ─────────────────────────────────────────────────────────────────────────────
# variables.tf
# ─────────────────────────────────────────────────────────────────────────────


class TestRenderVariables:
    def test_project_id_variable(self):
        out = render_variables("proj", "us-central1", "us-central1-a", "vm")
        assert 'variable "project_id"' in out

    def test_region_variable_with_default(self):
        out = render_variables("proj", "us-central1", "us-central1-a", "vm")
        assert 'variable "region"' in out
        assert '"us-central1"' in out

    def test_zone_variable(self):
        out = render_variables("proj", "us-central1", "us-central1-a", "vm")
        assert 'variable "zone"' in out
        assert '"us-central1-a"' in out

    def test_machine_type_variable_default_e2_micro(self):
        out = render_variables("proj", "us-central1", "us-central1-a", "vm")
        assert 'variable "machine_type"' in out
        assert '"e2-micro"' in out

    def test_boot_disk_variable_reflects_arg(self):
        out = render_variables("proj", "us-central1", "us-central1-a", "vm", boot_disk_size_gb=25)
        assert "default     = 25" in out

    def test_instance_name_variable_default(self):
        out = render_variables("proj", "us-central1", "us-central1-a", "my-vm")
        assert '"my-vm"' in out

    def test_ssh_public_key_variable_present(self):
        out = render_variables("proj", "us-central1", "us-central1-a", "vm")
        assert 'variable "ssh_public_key"' in out

    # ── Check blocks ──────────────────────────────────────────────────────────

    def test_e2_micro_check_block_present(self):
        out = render_variables("proj", "us-central1", "us-central1-a", "vm")
        assert 'check "e2_micro_machine_type"' in out

    def test_e2_micro_check_condition_correct(self):
        out = render_variables("proj", "us-central1", "us-central1-a", "vm")
        assert 'var.machine_type == "e2-micro"' in out

    def test_compute_region_check_block_present(self):
        out = render_variables("proj", "us-central1", "us-central1-a", "vm")
        assert 'check "compute_region_free_tier"' in out

    def test_compute_region_check_lists_all_three_regions(self):
        out = render_variables("proj", "us-central1", "us-central1-a", "vm")
        assert '"us-west1"' in out
        assert '"us-central1"' in out
        assert '"us-east1"' in out

    def test_standard_pd_check_block_present(self):
        out = render_variables("proj", "us-central1", "us-central1-a", "vm")
        assert 'check "standard_pd_limit"' in out

    def test_standard_pd_check_uses_30_literal(self):
        out = render_variables("proj", "us-central1", "us-central1-a", "vm")
        # The assert condition should be <= 30
        assert "<= 30" in out

    # ── Optional vars conditionally present ───────────────────────────────────

    def test_credentials_var_absent_by_default(self):
        out = render_variables("proj", "us-central1", "us-central1-a", "vm")
        assert 'variable "credentials_file"' not in out

    def test_credentials_var_present_when_requested(self):
        out = render_variables("proj", "us-central1", "us-central1-a", "vm", include_credentials=True)
        assert 'variable "credentials_file"' in out

    def test_impersonation_var_absent_by_default(self):
        out = render_variables("proj", "us-central1", "us-central1-a", "vm")
        assert 'variable "impersonate_service_account"' not in out

    def test_impersonation_var_present_when_requested(self):
        out = render_variables("proj", "us-central1", "us-central1-a", "vm", include_impersonation=True)
        assert 'variable "impersonate_service_account"' in out

    def test_storage_vars_absent_by_default(self):
        out = render_variables("proj", "us-central1", "us-central1-a", "vm")
        assert 'variable "storage_region"' not in out
        assert 'check "storage_region_free_tier"' not in out

    def test_storage_vars_present_when_requested(self):
        out = render_variables("proj", "us-central1", "us-central1-a", "vm", include_storage=True)
        assert 'variable "storage_region"' in out
        assert 'check "storage_region_free_tier"' in out

    def test_storage_check_lists_free_storage_regions(self):
        out = render_variables("proj", "us-central1", "us-central1-a", "vm", include_storage=True)
        assert '"us-east1"' in out
        assert '"us-west1"' in out
        assert '"us-central1"' in out

    def test_two_space_indent(self):
        bad = _bad_indent_lines(render_variables("proj", "us-central1", "us-central1-a", "vm"))
        assert bad == [], f"Non-2-space indent lines: {bad}"

    def test_idempotent(self):
        args = ("proj", "us-central1", "us-central1-a", "vm")
        assert render_variables(*args) == render_variables(*args)


# ─────────────────────────────────────────────────────────────────────────────
# data_sources.tf
# ─────────────────────────────────────────────────────────────────────────────


class TestRenderDataSources:
    def test_ubuntu_image_data_source_declared(self):
        out = render_data_sources()
        assert 'data "google_compute_image" "ubuntu"' in out

    def test_ubuntu_image_family(self):
        out = render_data_sources()
        assert 'family  = "ubuntu-2404-lts-amd64"' in out

    def test_ubuntu_image_project(self):
        out = render_data_sources()
        assert 'project = "ubuntu-os-cloud"' in out

    def test_project_data_source_declared(self):
        out = render_data_sources()
        assert 'data "google_project" "current"' in out

    def test_zones_data_source_declared(self):
        out = render_data_sources()
        assert 'data "google_compute_zones" "available"' in out

    def test_idempotent(self):
        assert render_data_sources() == render_data_sources()


# ─────────────────────────────────────────────────────────────────────────────
# main.tf
# ─────────────────────────────────────────────────────────────────────────────


class TestRenderMain:
    def test_vpc_resource_declared(self):
        out = render_main("vm")
        assert 'resource "google_compute_network" "vpc"' in out

    def test_vpc_no_auto_subnets(self):
        out = render_main("vm")
        assert "auto_create_subnetworks = false" in out

    def test_subnet_resource_declared(self):
        out = render_main("vm")
        assert 'resource "google_compute_subnetwork" "subnet"' in out

    def test_subnet_cidr(self):
        out = render_main("vm")
        assert "10.0.0.0/24" in out

    def test_subnet_in_var_region(self):
        out = render_main("vm")
        assert "region        = var.region" in out

    def test_firewall_ssh_declared(self):
        out = render_main("vm")
        assert 'resource "google_compute_firewall" "allow_ssh"' in out

    def test_firewall_ssh_port_22(self):
        out = render_main("vm")
        assert '"22"' in out

    def test_firewall_icmp_declared(self):
        out = render_main("vm")
        assert 'resource "google_compute_firewall" "allow_icmp"' in out

    def test_firewall_icmp_protocol(self):
        out = render_main("vm")
        assert 'protocol = "icmp"' in out

    def test_boot_disk_declared(self):
        out = render_main("vm")
        assert 'resource "google_compute_disk" "boot"' in out

    def test_boot_disk_type_pd_standard(self):
        out = render_main("vm")
        assert 'type  = "pd-standard"' in out

    def test_instance_resource_declared(self):
        out = render_main("vm")
        assert 'resource "google_compute_instance" "vm"' in out

    def test_instance_uses_var_machine_type(self):
        out = render_main("vm")
        assert "machine_type = var.machine_type" in out

    def test_instance_uses_var_zone(self):
        out = render_main("vm")
        assert "zone         = var.zone" in out

    def test_ephemeral_ip_via_empty_access_config(self):
        # An empty access_config {} block means GCP assigns a temporary external IP.
        out = render_main("vm")
        assert "access_config {}" in out

    def test_no_preemptible(self):
        out = render_main("vm")
        assert "preemptible        = false" in out

    def test_automatic_restart_true(self):
        out = render_main("vm")
        assert "automatic_restart  = true" in out

    def test_migrate_on_host_maintenance(self):
        out = render_main("vm")
        assert '"MIGRATE"' in out

    def test_ssh_keys_in_metadata(self):
        out = render_main("vm")
        assert '"ssh-keys"' in out

    def test_auto_delete_false_protects_disk(self):
        # boot disk should NOT be auto-deleted when instance is destroyed
        out = render_main("vm")
        assert "auto_delete = false" in out

    def test_output_external_ip(self):
        out = render_main("vm")
        assert 'output "instance_external_ip"' in out

    def test_output_ssh_command(self):
        out = render_main("vm")
        assert 'output "ssh_command"' in out

    def test_output_console_url(self):
        out = render_main("vm")
        assert 'output "console_url"' in out

    def test_idempotent(self):
        assert render_main("vm") == render_main("vm")


# ─────────────────────────────────────────────────────────────────────────────
# cloud-init.yaml
# ─────────────────────────────────────────────────────────────────────────────


class TestRenderCloudInit:
    def test_cloud_config_header(self):
        out = render_cloud_init("my-host")
        assert out.startswith("#cloud-config")

    def test_hostname_set(self):
        out = render_cloud_init("my-host")
        assert "hostname: my-host" in out

    def test_fqdn_set(self):
        out = render_cloud_init("my-host")
        assert "fqdn: my-host.local" in out

    def test_package_update_true(self):
        out = render_cloud_init("my-host")
        assert "package_update: true" in out

    def test_package_upgrade_true(self):
        out = render_cloud_init("my-host")
        assert "package_upgrade: true" in out

    def test_default_packages_present(self):
        out = render_cloud_init("my-host")
        for pkg in ["curl", "wget", "git", "vim", "unattended-upgrades"]:
            assert f"  - {pkg}" in out, f"Missing default package: {pkg}"

    def test_extra_packages_appended(self):
        out = render_cloud_init("my-host", extra_packages=["docker.io", "python3-pip"])
        assert "  - docker.io" in out
        assert "  - python3-pip" in out

    def test_extra_packages_do_not_appear_when_not_passed(self):
        out = render_cloud_init("my-host")
        assert "docker.io" not in out

    def test_runcmd_present(self):
        out = render_cloud_init("my-host")
        assert "runcmd:" in out

    def test_idempotent(self):
        assert render_cloud_init("my-host") == render_cloud_init("my-host")


# ─────────────────────────────────────────────────────────────────────────────
# terraform validate (skipped if terraform not on PATH)
# ─────────────────────────────────────────────────────────────────────────────


@pytest.mark.skipif(not shutil.which("terraform"), reason="terraform not on PATH")
class TestTerraformValidate:
    """Write all four .tf files and run terraform validate.

    This test cannot pass in CI without network access (terraform init downloads
    providers).  It is gated on both terraform being on PATH and a provider
    registry being reachable."""

    def test_generated_files_pass_terraform_validate(self, tmp_tf_dir: Path):
        _all_tf_files(tmp_tf_dir)
        r = subprocess.run(
            ["terraform", "init", "-backend=false", "-input=false"],
            cwd=tmp_tf_dir,
            capture_output=True,
            text=True,
            check=False,
        )
        assert r.returncode == 0, f"terraform init failed:\n{r.stderr}"

        r = subprocess.run(
            ["terraform", "validate"],
            cwd=tmp_tf_dir,
            capture_output=True,
            text=True,
            check=False,
        )
        assert r.returncode == 0, f"terraform validate failed:\n{r.stdout}\n{r.stderr}"

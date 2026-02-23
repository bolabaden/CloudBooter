from __future__ import annotations

import os
import re
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import click
import oci
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

FREE_TIER_MAX_AMD_INSTANCES = 2
FREE_TIER_AMD_SHAPE = "VM.Standard.E2.1.Micro"
FREE_TIER_MAX_ARM_OCPUS = 4
FREE_TIER_MAX_ARM_MEMORY_GB = 24
FREE_TIER_ARM_SHAPE = "VM.Standard.A1.Flex"
FREE_TIER_MAX_STORAGE_GB = 200
FREE_TIER_MIN_BOOT_VOLUME_GB = 47
FREE_TIER_MAX_ARM_INSTANCES = 4
FREE_TIER_MAX_VCNS = 2

OUT_OF_CAPACITY_RE = re.compile(
    r"out of capacity|out of host capacity|OutOfCapacity|OutOfHostCapacity",
    re.IGNORECASE,
)


@dataclass
class ExistingResources:
    vcns: dict[str, str] = field(default_factory=dict)
    subnets: dict[str, str] = field(default_factory=dict)
    internet_gateways: dict[str, str] = field(default_factory=dict)
    route_tables: dict[str, str] = field(default_factory=dict)
    security_lists: dict[str, str] = field(default_factory=dict)
    amd_instances: dict[str, str] = field(default_factory=dict)
    arm_instances: dict[str, str] = field(default_factory=dict)
    boot_volumes: dict[str, str] = field(default_factory=dict)
    block_volumes: dict[str, str] = field(default_factory=dict)


@dataclass
class RuntimeConfig:
    config_file: str
    profile: str
    auth_mode: str
    non_interactive: bool
    auto_use_existing: bool
    auto_deploy: bool
    terraform_dir: Path
    tenancy_ocid: str | None
    region: str | None
    strict_provider_parity: bool


@dataclass
class OciContext:
    config: dict[str, Any]
    signer: Any | None
    tenancy_ocid: str
    user_ocid: str | None
    region: str
    availability_domain: str
    ubuntu_x86_image_ocid: str | None
    ubuntu_arm_image_ocid: str | None


@dataclass
class PlannedConfig:
    amd_micro_instance_count: int
    amd_micro_boot_volume_size_gb: int
    amd_micro_hostnames: list[str]
    amd_block_volume_size_gb: int
    arm_flex_instance_count: int
    arm_flex_ocpus_per_instance: list[int]
    arm_flex_memory_per_instance: list[int]
    arm_flex_boot_volume_size_gb: list[int]
    arm_flex_hostnames: list[str]
    arm_block_volume_sizes: list[int]


class CloudBooterWorkflow:
    def __init__(self, runtime: RuntimeConfig) -> None:
        self.runtime: RuntimeConfig = runtime
        self.identity_client: oci.identity.IdentityClient | None = None
        self.compute_client: oci.core.ComputeClient | None = None
        self.network_client: oci.core.VirtualNetworkClient | None = None
        self.block_client: oci.core.BlockstorageClient | None = None
        self.resources = ExistingResources()
        self.oci_context: OciContext | None = None

    def run(self) -> None:
        self.runtime.terraform_dir.mkdir(parents=True, exist_ok=True)
        self.oci_context = self._build_oci_context()
        self._inventory_all_resources(self.oci_context)
        planned = self._plan_configuration(self.oci_context, self.resources)
        self._validate_proposed_config(planned)
        self._generate_ssh_keys(Path.cwd() / "ssh_keys")
        self._write_terraform_files(
            self.oci_context,
            planned,
            self.runtime.terraform_dir,
        )

        click.echo(f"Terraform files generated in: {self.runtime.terraform_dir}")
        if self.runtime.auto_deploy:
            self._run_terraform_deploy(self.runtime.terraform_dir)

    def _build_oci_context(self) -> OciContext:
        cfg, signer = self._build_auth()
        self.identity_client = oci.identity.IdentityClient(cfg, signer=signer)
        self.compute_client = oci.core.ComputeClient(cfg, signer=signer)
        self.network_client = oci.core.VirtualNetworkClient(cfg, signer=signer)
        self.block_client = oci.core.BlockstorageClient(cfg, signer=signer)

        if self.runtime is not None:
            tenancy_ocid = self.runtime.tenancy_ocid or cfg.get("tenancy")
        else:
            tenancy_ocid = cfg.get("tenancy")
        if not tenancy_ocid and hasattr(signer, "tenancy_id"):
            tenancy_ocid = signer.tenancy_id
        if not tenancy_ocid:
            raise click.ClickException(
                "Unable to determine tenancy OCID. Pass --tenancy-ocid.",
            )

        region = self.runtime.region or cfg.get("region") or os.getenv("OCI_REGION")
        if not region:
            raise click.ClickException("Unable to determine OCI region. Pass --region.")

        user_ocid = cfg.get("user")
        availability_domain = self._fetch_availability_domain(tenancy_ocid)
        ubuntu_x86 = self._lookup_ubuntu_image(tenancy_ocid, FREE_TIER_AMD_SHAPE)
        ubuntu_arm = self._lookup_ubuntu_image(tenancy_ocid, FREE_TIER_ARM_SHAPE)

        return OciContext(
            config=cfg,
            signer=signer,
            tenancy_ocid=tenancy_ocid,
            user_ocid=user_ocid,
            region=region,
            availability_domain=availability_domain,
            ubuntu_x86_image_ocid=ubuntu_x86,
            ubuntu_arm_image_ocid=ubuntu_arm,
        )

    def _build_auth(self) -> tuple[dict[str, Any], Any | None]:
        auth_mode = self.runtime.auth_mode
        config = {"region": self.runtime.region or os.getenv("OCI_REGION", "")}

        if auth_mode == "api_key":
            api_cfg = oci.config.from_file(
                file_location=self.runtime.config_file,
                profile_name=self.runtime.profile,
            )
            if self.runtime.region:
                api_cfg["region"] = self.runtime.region
            oci.config.validate_config(api_cfg)
            return api_cfg, None

        if auth_mode == "instance_principal":
            signer = oci.auth.signers.InstancePrincipalsSecurityTokenSigner()
            config["tenancy"] = self.runtime.tenancy_ocid or getattr(
                signer,
                "tenancy_id",
                "",
            )
            if not config.get("region"):
                config["region"] = self.runtime.region or os.getenv("OCI_REGION", "")
            return config, signer

        if auth_mode == "resource_principal":
            signer = oci.auth.signers.get_resource_principals_signer()
            config["tenancy"] = self.runtime.tenancy_ocid or getattr(
                signer,
                "tenancy_id",
                "",
            )
            if not config.get("region"):
                config["region"] = self.runtime.region or os.getenv("OCI_REGION", "")
            return config, signer

        if auth_mode == "security_token":
            sec_cfg = oci.config.from_file(
                file_location=self.runtime.config_file,
                profile_name=self.runtime.profile,
            )
            token_file = sec_cfg.get("security_token_file")
            key_file = sec_cfg.get("key_file")
            if not token_file or not Path(token_file).exists():
                raise click.ClickException(
                    "security_token mode requires an existing security_token_file in OCI config profile.",
                )
            if not key_file or not Path(key_file).exists():
                raise click.ClickException(
                    "security_token mode requires an existing key_file in OCI config profile.",
                )
            token = Path(token_file).read_text(encoding="utf-8").strip()
            private_key = oci.signer.load_private_key_from_file(key_file)
            signer = oci.auth.signers.SecurityTokenSigner(token, private_key)
            if self.runtime.region:
                sec_cfg["region"] = self.runtime.region
            return sec_cfg, signer

        raise click.ClickException(f"Unsupported auth mode: {auth_mode}")

    def _fetch_availability_domain(self, tenancy_ocid: str) -> str:
        assert self.identity_client is not None
        ads = oci.pagination.list_call_get_all_results(
            self.identity_client.list_availability_domains,
            compartment_id=tenancy_ocid,
        ).data
        if not ads:
            raise click.ClickException(
                "No availability domains were returned for tenancy.",
            )
        return ads[0].name

    def _lookup_ubuntu_image(
        self,
        tenancy_ocid: str,
        shape: str,
    ) -> str | None:
        assert self.compute_client is not None
        result = oci.pagination.list_call_get_all_results(
            self.compute_client.list_images,
            compartment_id=tenancy_ocid,
            operating_system="Canonical Ubuntu",
            shape=shape,
            sort_by="TIMECREATED",
            sort_order="DESC",
        ).data
        for image in result:
            if getattr(image, "lifecycle_state", "") == "AVAILABLE":
                return image.id
        return None

    def _inventory_all_resources(self, ctx: OciContext) -> None:
        self._inventory_compute_instances(ctx)
        self._inventory_networking_resources(ctx)
        self._inventory_storage_resources(ctx)

    def _inventory_compute_instances(self, ctx: OciContext) -> None:
        assert self.compute_client is not None
        assert self.network_client is not None

        instances: list[oci.core.models.Instance] = oci.pagination.list_call_get_all_results(
            self.compute_client.list_instances,
            compartment_id=ctx.tenancy_ocid,
        ).data

        for instance in instances:
            if getattr(instance, "lifecycle_state", "") == "TERMINATED":
                continue

            public_ip = "none"
            private_ip = "none"
            vnic_attachments = oci.pagination.list_call_get_all_results(
                self.compute_client.list_vnic_attachments,
                compartment_id=ctx.tenancy_ocid,
                instance_id=instance.id,
            ).data
            attached = [
                va
                for va in vnic_attachments
                if getattr(va, "lifecycle_state", "") == "ATTACHED"
            ]
            if attached:
                vnic = self.network_client.get_vnic(attached[0].vnic_id).data
                public_ip = getattr(vnic, "public_ip", None) or "none"
                private_ip = getattr(vnic, "private_ip", None) or "none"

            base = f"{instance.display_name}|{instance.lifecycle_state}|{instance.shape}|{public_ip}|{private_ip}"
            if instance.shape == FREE_TIER_AMD_SHAPE:
                self.resources.amd_instances[instance.id] = base
            elif instance.shape == FREE_TIER_ARM_SHAPE:
                details = self.compute_client.get_instance(instance.id).data
                shape_cfg = getattr(details, "shape_config", None)
                ocpus = int(getattr(shape_cfg, "ocpus", 0) or 0)
                memory = int(getattr(shape_cfg, "memory_in_gbs", 0) or 0)
                self.resources.arm_instances[instance.id] = f"{base}|{ocpus}|{memory}"

    def _inventory_networking_resources(self, ctx: OciContext) -> None:
        assert self.network_client is not None

        vcns = oci.pagination.list_call_get_all_results(
            self.network_client.list_vcns,
            compartment_id=ctx.tenancy_ocid,
        ).data
        for vcn in vcns:
            if getattr(vcn, "lifecycle_state", "") != "AVAILABLE":
                continue
            self.resources.vcns[vcn.id] = f"{vcn.display_name}|{vcn.cidr_blocks[0]}"

            subnets = oci.pagination.list_call_get_all_results(
                self.network_client.list_subnets,
                compartment_id=ctx.tenancy_ocid,
                vcn_id=vcn.id,
            ).data
            for subnet in subnets:
                if getattr(subnet, "lifecycle_state", "") == "AVAILABLE":
                    self.resources.subnets[subnet.id] = (
                        f"{subnet.display_name}|{subnet.cidr_block}|{vcn.id}"
                    )

            igws = oci.pagination.list_call_get_all_results(
                self.network_client.list_internet_gateways,
                compartment_id=ctx.tenancy_ocid,
                vcn_id=vcn.id,
            ).data
            for igw in igws:
                if getattr(igw, "lifecycle_state", "") == "AVAILABLE":
                    self.resources.internet_gateways[igw.id] = (
                        f"{igw.display_name}|{vcn.id}"
                    )

            route_tables = oci.pagination.list_call_get_all_results(
                self.network_client.list_route_tables,
                compartment_id=ctx.tenancy_ocid,
                vcn_id=vcn.id,
            ).data
            for route_table in route_tables:
                self.resources.route_tables[route_table.id] = (
                    f"{route_table.display_name}|{vcn.id}"
                )

            security_lists = oci.pagination.list_call_get_all_results(
                self.network_client.list_security_lists,
                compartment_id=ctx.tenancy_ocid,
                vcn_id=vcn.id,
            ).data
            for security_list in security_lists:
                self.resources.security_lists[security_list.id] = (
                    f"{security_list.display_name}|{vcn.id}"
                )

    def _inventory_storage_resources(self, ctx: OciContext) -> None:
        assert self.block_client is not None

        boots = oci.pagination.list_call_get_all_results(
            self.block_client.list_boot_volumes,
            compartment_id=ctx.tenancy_ocid,
            availability_domain=ctx.availability_domain,
        ).data
        for boot in boots:
            if getattr(boot, "lifecycle_state", "") == "AVAILABLE":
                self.resources.boot_volumes[boot.id] = (
                    f"{boot.display_name}|{int(boot.size_in_gbs)}"
                )

        blocks = oci.pagination.list_call_get_all_results(
            self.block_client.list_volumes,
            compartment_id=ctx.tenancy_ocid,
            availability_domain=ctx.availability_domain,
        ).data
        for block in blocks:
            if getattr(block, "lifecycle_state", "") == "AVAILABLE":
                self.resources.block_volumes[block.id] = (
                    f"{block.display_name}|{int(block.size_in_gbs)}"
                )

    def _plan_configuration(
        self,
        ctx: OciContext,
        resources: ExistingResources,
    ) -> PlannedConfig:
        if self.runtime.auto_use_existing or self.runtime.non_interactive:
            return self._plan_from_existing(resources)

        click.echo("Configuration options:")
        click.echo("  1) Use existing instances")
        click.echo("  2) Configure new instances")
        click.echo("  3) Maximum free-tier configuration")
        choice = click.prompt(
            "Choose configuration",
            type=click.IntRange(1, 3),
            default=1,
        )

        if choice == 1:
            return self._plan_from_existing(resources)
        if choice == 2:
            return self._plan_custom(ctx)
        return self._plan_maximum()

    def _plan_from_existing(self, resources: ExistingResources) -> PlannedConfig:
        amd_entries = list(resources.amd_instances.values())
        arm_entries = list(resources.arm_instances.values())

        amd_hostnames = [entry.split("|")[0] for entry in amd_entries]
        arm_hostnames = [entry.split("|")[0] for entry in arm_entries]
        arm_ocpus = [int(entry.split("|")[5]) for entry in arm_entries]
        arm_memory = [int(entry.split("|")[6]) for entry in arm_entries]
        arm_boot = [FREE_TIER_MIN_BOOT_VOLUME_GB] * len(arm_entries)

        if not amd_entries and not arm_entries:
            has_arm_image = bool(
                self.oci_context and self.oci_context.ubuntu_arm_image_ocid,
            )
            return PlannedConfig(
                amd_micro_instance_count=0,
                amd_micro_boot_volume_size_gb=50,
                amd_micro_hostnames=[],
                amd_block_volume_size_gb=0,
                arm_flex_instance_count=1 if has_arm_image else 0,
                arm_flex_ocpus_per_instance=[4] if has_arm_image else [],
                arm_flex_memory_per_instance=[24] if has_arm_image else [],
                arm_flex_boot_volume_size_gb=[200] if has_arm_image else [],
                arm_flex_hostnames=["arm-instance-1"] if has_arm_image else [],
                arm_block_volume_sizes=[0] if has_arm_image else [],
            )

        return PlannedConfig(
            amd_micro_instance_count=len(amd_entries),
            amd_micro_boot_volume_size_gb=50,
            amd_micro_hostnames=amd_hostnames,
            amd_block_volume_size_gb=0,
            arm_flex_instance_count=len(arm_entries),
            arm_flex_ocpus_per_instance=arm_ocpus,
            arm_flex_memory_per_instance=arm_memory,
            arm_flex_boot_volume_size_gb=arm_boot,
            arm_flex_hostnames=arm_hostnames,
            arm_block_volume_sizes=[0] * len(arm_entries),
        )

    def _available_resources(self) -> tuple[int, int, int, int]:
        used_amd = len(self.resources.amd_instances)
        used_arm_ocpus = sum(
            int(v.split("|")[5]) for v in self.resources.arm_instances.values()
        )
        used_arm_memory = sum(
            int(v.split("|")[6]) for v in self.resources.arm_instances.values()
        )
        used_storage = 0
        for v in self.resources.boot_volumes.values():
            used_storage += int(v.split("|")[1])
        for v in self.resources.block_volumes.values():
            used_storage += int(v.split("|")[1])

        return (
            FREE_TIER_MAX_AMD_INSTANCES - used_amd,
            FREE_TIER_MAX_ARM_OCPUS - used_arm_ocpus,
            FREE_TIER_MAX_ARM_MEMORY_GB - used_arm_memory,
            FREE_TIER_MAX_STORAGE_GB - used_storage,
        )

    def _plan_custom(self, ctx: OciContext) -> PlannedConfig:
        available_amd, available_arm_ocpus, available_arm_memory, _ = (
            self._available_resources()
        )
        amd_count = click.prompt(
            "AMD instance count",
            type=click.IntRange(0, max(0, available_amd)),
            default=0,
        )
        amd_boot = (
            50
            if amd_count == 0
            else click.prompt(
                "AMD boot volume size (GB)",
                type=click.IntRange(50, 100),
                default=50,
            )
        )
        amd_hosts: list[str] = [
            click.prompt(f"AMD hostname {i}", default=f"amd-instance-{i}")
            for i in range(1, amd_count + 1)
        ]

        arm_count = 0
        arm_ocpus: list[int] = []
        arm_memory: list[int] = []
        arm_boot: list[int] = []
        arm_hosts: list[str] = []
        arm_blocks: list[int] = []

        if ctx.ubuntu_arm_image_ocid and available_arm_ocpus > 0:
            arm_count = click.prompt(
                "ARM instance count",
                type=click.IntRange(0, FREE_TIER_MAX_ARM_INSTANCES),
                default=1,
            )
            rem_ocpus = available_arm_ocpus
            rem_memory = available_arm_memory
            for i in range(1, arm_count + 1):
                arm_hosts.append(
                    click.prompt(f"ARM hostname {i}", default=f"arm-instance-{i}"),
                )
                ocpu = click.prompt(
                    f"ARM {i} OCPUs",
                    type=click.IntRange(1, max(1, rem_ocpus)),
                    default=max(1, rem_ocpus),
                )
                max_mem = min(rem_memory, ocpu * 6)
                mem = click.prompt(
                    f"ARM {i} memory GB",
                    type=click.IntRange(1, max(1, max_mem)),
                    default=max(1, max_mem),
                )
                boot = click.prompt(
                    f"ARM {i} boot volume GB",
                    type=click.IntRange(50, 200),
                    default=50,
                )
                arm_ocpus.append(ocpu)
                arm_memory.append(mem)
                arm_boot.append(boot)
                arm_blocks.append(0)
                rem_ocpus -= ocpu
                rem_memory -= mem

        return PlannedConfig(
            amd_micro_instance_count=amd_count,
            amd_micro_boot_volume_size_gb=amd_boot,
            amd_micro_hostnames=amd_hosts,
            amd_block_volume_size_gb=0,
            arm_flex_instance_count=arm_count,
            arm_flex_ocpus_per_instance=arm_ocpus,
            arm_flex_memory_per_instance=arm_memory,
            arm_flex_boot_volume_size_gb=arm_boot,
            arm_flex_hostnames=arm_hosts,
            arm_block_volume_sizes=arm_blocks,
        )

    def _plan_maximum(self) -> PlannedConfig:
        available_amd, available_arm_ocpus, available_arm_memory, available_storage = (
            self._available_resources()
        )

        amd_count = max(0, available_amd)
        amd_boot = 50
        amd_hosts = [f"amd-instance-{i}" for i in range(1, amd_count + 1)]

        arm_count = 0
        arm_ocpus: list[int] = []
        arm_memory: list[int] = []
        arm_boot: list[int] = []
        arm_hosts: list[str] = []
        arm_blocks: list[int] = []

        if (
            self.oci_context
            and self.oci_context.ubuntu_arm_image_ocid
            and available_arm_ocpus > 0
        ):
            arm_count = 1
            arm_ocpus = [available_arm_ocpus]
            arm_memory = [available_arm_memory]
            remaining_storage = max(
                FREE_TIER_MIN_BOOT_VOLUME_GB,
                available_storage - (amd_count * amd_boot),
            )
            arm_boot = [remaining_storage]
            arm_hosts = ["arm-instance-1"]
            arm_blocks = [0]

        return PlannedConfig(
            amd_micro_instance_count=amd_count,
            amd_micro_boot_volume_size_gb=amd_boot,
            amd_micro_hostnames=amd_hosts,
            amd_block_volume_size_gb=0,
            arm_flex_instance_count=arm_count,
            arm_flex_ocpus_per_instance=arm_ocpus,
            arm_flex_memory_per_instance=arm_memory,
            arm_flex_boot_volume_size_gb=arm_boot,
            arm_flex_hostnames=arm_hosts,
            arm_block_volume_sizes=arm_blocks,
        )

    def _validate_proposed_config(self, planned: PlannedConfig) -> None:
        available_amd, available_arm_ocpus, available_arm_memory, available_storage = (
            self._available_resources()
        )

        proposed_arm_ocpus = sum(planned.arm_flex_ocpus_per_instance)
        proposed_arm_memory = sum(planned.arm_flex_memory_per_instance)
        proposed_storage = (
            planned.amd_micro_instance_count * planned.amd_micro_boot_volume_size_gb
            + sum(planned.arm_flex_boot_volume_size_gb)
            + planned.amd_micro_instance_count * planned.amd_block_volume_size_gb
            + sum(planned.arm_block_volume_sizes)
        )

        errors: list[str] = []
        if planned.amd_micro_instance_count > available_amd:
            errors.append(
                f"Cannot create {planned.amd_micro_instance_count} AMD instances, only {available_amd} available.",
            )
        if proposed_arm_ocpus > available_arm_ocpus:
            errors.append(
                f"Cannot allocate {proposed_arm_ocpus} ARM OCPUs, only {available_arm_ocpus} available.",
            )
        if proposed_arm_memory > available_arm_memory:
            errors.append(
                f"Cannot allocate {proposed_arm_memory}GB ARM memory, only {available_arm_memory}GB available.",
            )
        if proposed_storage > available_storage:
            errors.append(
                f"Cannot use {proposed_storage}GB storage, only {available_storage}GB available.",
            )
        if len(self.resources.vcns) > FREE_TIER_MAX_VCNS:
            errors.append("Existing VCN count already exceeds free-tier VCN limit.")

        if errors:
            raise click.ClickException(
                "Free Tier validation failed:\n- " + "\n- ".join(errors),
            )

    def _generate_ssh_keys(self, ssh_dir: Path) -> None:
        ssh_dir.mkdir(parents=True, exist_ok=True)
        private_key_path = ssh_dir / "id_rsa"
        public_key_path = ssh_dir / "id_rsa.pub"

        if private_key_path.exists() and public_key_path.exists():
            return

        private_key = rsa.generate_private_key(public_exponent=65537, key_size=4096)
        private_pem = private_key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.TraditionalOpenSSL,
            encryption_algorithm=serialization.NoEncryption(),
        )
        public_ssh = private_key.public_key().public_bytes(
            encoding=serialization.Encoding.OpenSSH,
            format=serialization.PublicFormat.OpenSSH,
        )

        private_key_path.write_bytes(private_pem)
        public_key_path.write_bytes(public_ssh + b"\n")

        os.chmod(private_key_path, 0o600)
        os.chmod(public_key_path, 0o644)

    def _write_terraform_files(
        self,
        ctx: OciContext,
        planned: PlannedConfig,
        target_dir: Path,
    ) -> None:
        provider_content = self._render_provider_tf(ctx)
        variables_content = self._render_variables_tf(ctx, planned)
        data_sources_content = self._render_data_sources_tf()
        main_content = self._render_main_tf()
        block_volumes_content = self._render_block_volumes_tf()
        cloud_init_content = self._render_cloud_init()

        (target_dir / "provider.tf").write_text(provider_content, encoding="utf-8")
        (target_dir / "variables.tf").write_text(variables_content, encoding="utf-8")
        (target_dir / "data_sources.tf").write_text(
            data_sources_content,
            encoding="utf-8",
        )
        (target_dir / "main.tf").write_text(main_content, encoding="utf-8")
        (target_dir / "block_volumes.tf").write_text(
            block_volumes_content,
            encoding="utf-8",
        )
        (target_dir / "cloud-init.yaml").write_text(
            cloud_init_content,
            encoding="utf-8",
        )

    def _render_provider_tf(self, ctx: OciContext) -> str:
        generated = time.ctime()
        if self.runtime.strict_provider_parity:
            return f"""# Terraform Provider Configuration for Oracle Cloud Infrastructure
# Generated: {generated}
# Region: {ctx.region}

terraform {{
  required_version = ">= 1.0"
  required_providers {{
    oci = {{
      source  = "oracle/oci"
      version = "~> 6.0"
    }}
  }}
}}

# OCI Provider with session token authentication
provider "oci" {{
  auth                = "SecurityToken"
  config_file_profile = "DEFAULT"
  region              = "{ctx.region}"
}}
"""

        auth_value = {
            "api_key": "APIKey",
            "instance_principal": "InstancePrincipal",
            "resource_principal": "ResourcePrincipal",
            "security_token": "SecurityToken",
        }[self.runtime.auth_mode]
        profile_line = (
            f'  config_file_profile = "{self.runtime.profile}"\n'
            if self.runtime.auth_mode in {"api_key", "security_token"}
            else ""
        )
        return f"""# Terraform Provider Configuration for Oracle Cloud Infrastructure
# Generated: {generated}
# Region: {ctx.region}

terraform {{
  required_version = ">= 1.0"
  required_providers {{
    oci = {{
      source  = "oracle/oci"
      version = "~> 6.0"
    }}
  }}
}}

# OCI Provider configuration
provider "oci" {{
  auth   = "{auth_value}"
{profile_line}  region = "{ctx.region}"
}}
"""

    def _render_variables_tf(self, ctx: OciContext, planned: PlannedConfig) -> str:
        def q(items: list[str]) -> str:
            return "[" + ", ".join(f'"{x}"' for x in items) + "]"

        def nums(items: list[int]) -> str:
            return "[" + ", ".join(str(x) for x in items) + "]"

        generated = time.ctime()
        return f"""# Oracle Cloud Infrastructure Terraform Variables
# Generated: {generated}
# Configuration: {planned.amd_micro_instance_count}x AMD + {planned.arm_flex_instance_count}x ARM instances

locals {{
  # Core identifiers
  tenancy_ocid    = "{ctx.tenancy_ocid}"
  compartment_id  = "{ctx.tenancy_ocid}"
  user_ocid       = "{ctx.user_ocid or ""}"
  region          = "{ctx.region}"
  
  # Ubuntu Images (region-specific)
  ubuntu_x86_image_ocid = "{ctx.ubuntu_x86_image_ocid or ""}"
  ubuntu_arm_image_ocid = "{ctx.ubuntu_arm_image_ocid or ""}"
  
  # SSH Configuration
  ssh_pubkey_path      = pathexpand("./ssh_keys/id_rsa.pub")
  ssh_pubkey_data      = file(pathexpand("./ssh_keys/id_rsa.pub"))
  ssh_private_key_path = pathexpand("./ssh_keys/id_rsa")
  
  # AMD x86 Micro Instances Configuration
  amd_micro_instance_count      = {planned.amd_micro_instance_count}
  amd_micro_boot_volume_size_gb = {planned.amd_micro_boot_volume_size_gb}
  amd_micro_hostnames           = {q(planned.amd_micro_hostnames)}
  amd_block_volume_size_gb      = {planned.amd_block_volume_size_gb}
  
  # ARM A1 Flex Instances Configuration
  arm_flex_instance_count       = {planned.arm_flex_instance_count}
  arm_flex_ocpus_per_instance   = {nums(planned.arm_flex_ocpus_per_instance)}
  arm_flex_memory_per_instance  = {nums(planned.arm_flex_memory_per_instance)}
  arm_flex_boot_volume_size_gb  = {nums(planned.arm_flex_boot_volume_size_gb)}
  arm_flex_hostnames            = {q(planned.arm_flex_hostnames)}
  arm_block_volume_sizes        = {nums(planned.arm_block_volume_sizes)}
  
  # Storage calculations
  total_amd_storage = local.amd_micro_instance_count * local.amd_micro_boot_volume_size_gb
  total_arm_storage = local.arm_flex_instance_count > 0 ? sum(local.arm_flex_boot_volume_size_gb) : 0
  total_block_storage = (local.amd_micro_instance_count * local.amd_block_volume_size_gb) + (local.arm_flex_instance_count > 0 ? sum(local.arm_block_volume_sizes) : 0)
  total_storage = local.total_amd_storage + local.total_arm_storage + local.total_block_storage
}}

# Free Tier Limits
variable "free_tier_max_storage_gb" {{
  description = "Maximum storage for Oracle Free Tier"
  type        = number
  default     = {FREE_TIER_MAX_STORAGE_GB}
}}

variable "free_tier_max_arm_ocpus" {{
  description = "Maximum ARM OCPUs for Oracle Free Tier"
  type        = number
  default     = {FREE_TIER_MAX_ARM_OCPUS}
}}

variable "free_tier_max_arm_memory_gb" {{
  description = "Maximum ARM memory for Oracle Free Tier"
  type        = number
  default     = {FREE_TIER_MAX_ARM_MEMORY_GB}
}}

# Validation checks
check "storage_limit" {{
  assert {{
    condition     = local.total_storage <= var.free_tier_max_storage_gb
    error_message = "Total storage (${{local.total_storage}}GB) exceeds Free Tier limit (${{var.free_tier_max_storage_gb}}GB)"
  }}
}}

check "arm_ocpu_limit" {{
  assert {{
    condition     = local.arm_flex_instance_count == 0 || sum(local.arm_flex_ocpus_per_instance) <= var.free_tier_max_arm_ocpus
    error_message = "Total ARM OCPUs exceed Free Tier limit (${{var.free_tier_max_arm_ocpus}})"
  }}
}}

check "arm_memory_limit" {{
  assert {{
    condition     = local.arm_flex_instance_count == 0 || sum(local.arm_flex_memory_per_instance) <= var.free_tier_max_arm_memory_gb
    error_message = "Total ARM memory exceeds Free Tier limit (${{var.free_tier_max_arm_memory_gb}}GB)"
  }}
}}
"""

    def _render_data_sources_tf(self) -> str:
        return """# OCI Data Sources
# Fetches dynamic information from Oracle Cloud

# Availability Domains
data "oci_identity_availability_domains" "ads" {
  compartment_id = local.tenancy_ocid
}

# Tenancy Information
data "oci_identity_tenancy" "tenancy" {
  tenancy_id = local.tenancy_ocid
}

# Available Regions
data "oci_identity_regions" "regions" {}

# Region Subscriptions
data "oci_identity_region_subscriptions" "subscriptions" {
  tenancy_id = local.tenancy_ocid
}
"""

    def _render_main_tf(self) -> str:
        return """# Oracle Cloud Infrastructure - Main Configuration
# Always Free Tier Optimized

# ============================================================================
# NETWORKING
# ============================================================================

resource "oci_core_vcn" "main" {
  compartment_id = local.compartment_id
  cidr_blocks    = ["10.0.0.0/16"]
  display_name   = "main-vcn"
  dns_label      = "mainvcn"
  is_ipv6enabled = true
  
  freeform_tags = {
    "Purpose" = "AlwaysFreeTier"
    "Managed" = "Terraform"
  }
}

resource "oci_core_internet_gateway" "main" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "main-igw"
  enabled        = true
}

resource "oci_core_default_route_table" "main" {
  manage_default_resource_id = oci_core_vcn.main.default_route_table_id
  display_name               = "main-rt"
  
  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.main.id
  }
  
  route_rules {
    destination       = "::/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.main.id
  }
}

resource "oci_core_default_security_list" "main" {
  manage_default_resource_id = oci_core_vcn.main.default_security_list_id
  display_name               = "main-sl"
  
  # Allow all egress
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }
  
  egress_security_rules {
    destination = "::/0"
    protocol    = "all"
  }
  
  # SSH (IPv4)
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 22
      max = 22
    }
  }
  # SSH (IPv6)
  ingress_security_rules {
    protocol = "6"
    source   = "::/0"
    tcp_options {
      min = 22
      max = 22
    }
  }
  
  # HTTP (IPv4)
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 80
      max = 80
    }
  }
  # HTTP (IPv6)
  ingress_security_rules {
    protocol = "6"
    source   = "::/0"
    tcp_options {
      min = 80
      max = 80
    }
  }
  
  # HTTPS (IPv4)
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 443
      max = 443
    }
  }
  # HTTPS (IPv6)
  ingress_security_rules {
    protocol = "6"
    source   = "::/0"
    tcp_options {
      min = 443
      max = 443
    }
  }
  
  # ICMP (IPv4)
  ingress_security_rules {
    protocol = "1"
    source   = "0.0.0.0/0"
  }
  # ICMP (IPv6)
  ingress_security_rules {
    protocol = "1"
    source   = "::/0"
  }
}

resource "oci_core_subnet" "main" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.main.id
  cidr_block     = "10.0.1.0/24"
  display_name   = "main-subnet"
  dns_label      = "mainsubnet"
  
  route_table_id    = oci_core_default_route_table.main.id
  security_list_ids = [oci_core_default_security_list.main.id]
  
  # IPv6 - use first /64 block from VCN's /56
  ipv6cidr_blocks = [cidrsubnet(oci_core_vcn.main.ipv6cidr_blocks[0], 8, 0)]
}

# ============================================================================
# COMPUTE INSTANCES
# ============================================================================

# AMD x86 Micro Instances
resource "oci_core_instance" "amd" {
  count = local.amd_micro_instance_count
  
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = local.compartment_id
  display_name        = local.amd_micro_hostnames[count.index]
  shape               = "VM.Standard.E2.1.Micro"
  
  create_vnic_details {
    subnet_id        = oci_core_subnet.main.id
    display_name     = "${local.amd_micro_hostnames[count.index]}-vnic"
    assign_public_ip = true
    assign_ipv6ip    = true
    hostname_label   = local.amd_micro_hostnames[count.index]
  }
  
  source_details {
    source_type             = "image"
    source_id               = local.ubuntu_x86_image_ocid
    boot_volume_size_in_gbs = local.amd_micro_boot_volume_size_gb
  }
  
  metadata = {
    ssh_authorized_keys = local.ssh_pubkey_data
    user_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
      hostname = local.amd_micro_hostnames[count.index]
    }))
  }
  
  freeform_tags = {
    "Purpose"      = "AlwaysFreeTier"
    "InstanceType" = "AMD-Micro"
    "Managed"      = "Terraform"
  }
  
  lifecycle {
    ignore_changes = [
      source_details[0].source_id,
      defined_tags,
    ]
  }
}

# ARM A1 Flex Instances
resource "oci_core_instance" "arm" {
  count = local.arm_flex_instance_count
  
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = local.compartment_id
  display_name        = local.arm_flex_hostnames[count.index]
  shape               = "VM.Standard.A1.Flex"
  
  shape_config {
    ocpus         = local.arm_flex_ocpus_per_instance[count.index]
    memory_in_gbs = local.arm_flex_memory_per_instance[count.index]
  }
  
  create_vnic_details {
    subnet_id        = oci_core_subnet.main.id
    display_name     = "${local.arm_flex_hostnames[count.index]}-vnic"
    assign_public_ip = true
    assign_ipv6ip    = true
    hostname_label   = local.arm_flex_hostnames[count.index]
  }
  
  source_details {
    source_type             = "image"
    source_id               = local.ubuntu_arm_image_ocid
    boot_volume_size_in_gbs = local.arm_flex_boot_volume_size_gb[count.index]
  }
  
  metadata = {
    ssh_authorized_keys = local.ssh_pubkey_data
    user_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
      hostname = local.arm_flex_hostnames[count.index]
    }))
  }
  
  freeform_tags = {
    "Purpose"      = "AlwaysFreeTier"
    "InstanceType" = "ARM-A1-Flex"
    "Managed"      = "Terraform"
  }
  
  lifecycle {
    ignore_changes = [
      source_details[0].source_id,
      defined_tags,
    ]
  }
}

# ============================================================================
# PER-INSTANCE IPv6: Reserve an IPv6 for each instance VNIC
# Docs: "Creates an IPv6 for the specified VNIC." and "lifetime: Ephemeral | Reserved" (OCI Terraform provider)
# ============================================================================

data "oci_core_vnic_attachments" "amd_vnics" {
  count = local.amd_micro_instance_count
  compartment_id = local.compartment_id
  instance_id    = oci_core_instance.amd[count.index].id
}

resource "oci_core_ipv6" "amd_ipv6" {
  count = local.amd_micro_instance_count
  vnic_id = data.oci_core_vnic_attachments.amd_vnics[count.index].vnic_attachments[0].vnic_id
  lifetime = "RESERVED"
  subnet_id = oci_core_subnet.main.id
  route_table_id = oci_core_default_route_table.main.id
  display_name = "amd-${local.amd_micro_hostnames[count.index]}-ipv6"
  freeform_tags = {
    "Purpose" = "AlwaysFreeTier"
    "Managed" = "Terraform"
  }
}

data "oci_core_vnic_attachments" "arm_vnics" {
  count = local.arm_flex_instance_count
  compartment_id = local.compartment_id
  instance_id    = oci_core_instance.arm[count.index].id
}

resource "oci_core_ipv6" "arm_ipv6" {
  count = local.arm_flex_instance_count
  vnic_id = data.oci_core_vnic_attachments.arm_vnics[count.index].vnic_attachments[0].vnic_id
  lifetime = "RESERVED"
  subnet_id = oci_core_subnet.main.id
  route_table_id = oci_core_default_route_table.main.id
  display_name = "arm-${local.arm_flex_hostnames[count.index]}-ipv6"
  freeform_tags = {
    "Purpose" = "AlwaysFreeTier"
    "Managed" = "Terraform"
  }
}

# ============================================================================
# OUTPUTS
# ============================================================================

output "amd_instances" {
  description = "AMD instance information"
  value = local.amd_micro_instance_count > 0 ? {
    for i in range(local.amd_micro_instance_count) : local.amd_micro_hostnames[i] => {
      id         = oci_core_instance.amd[i].id
      public_ip  = oci_core_instance.amd[i].public_ip
      private_ip = oci_core_instance.amd[i].private_ip
      ipv6       = oci_core_ipv6.amd_ipv6[i].ip_address
      state      = oci_core_instance.amd[i].state
      ssh        = "ssh -i ./ssh_keys/id_rsa ubuntu@${oci_core_instance.amd[i].public_ip}"
    }
  } : {}
}

output "arm_instances" {
  description = "ARM instance information"
  value = local.arm_flex_instance_count > 0 ? {
    for i in range(local.arm_flex_instance_count) : local.arm_flex_hostnames[i] => {
      id         = oci_core_instance.arm[i].id
      public_ip  = oci_core_instance.arm[i].public_ip
      private_ip = oci_core_instance.arm[i].private_ip
      ipv6       = oci_core_ipv6.arm_ipv6[i].ip_address
      state      = oci_core_instance.arm[i].state
      ocpus      = local.arm_flex_ocpus_per_instance[i]
      memory_gb  = local.arm_flex_memory_per_instance[i]
      ssh        = "ssh -i ./ssh_keys/id_rsa ubuntu@${oci_core_instance.arm[i].public_ip}"
    }
  } : {}
}

output "network" {
  description = "Network information"
  value = {
    vcn_id     = oci_core_vcn.main.id
    vcn_cidr   = oci_core_vcn.main.cidr_blocks[0]
    subnet_id  = oci_core_subnet.main.id
    subnet_cidr = oci_core_subnet.main.cidr_block
  }
}

output "summary" {
  description = "Infrastructure summary"
  value = {
    region          = local.region
    total_amd       = local.amd_micro_instance_count
    total_arm       = local.arm_flex_instance_count
    total_storage   = local.total_storage
    free_tier_limit = 200
  }
}
"""

    def _render_block_volumes_tf(self) -> str:
        return '''# Block Volume Resources (Optional)
# Block volumes provide additional storage beyond boot volumes

# AMD Block Volumes
resource "oci_core_volume" "amd_block" {
  count = local.amd_block_volume_size_gb > 0 ? local.amd_micro_instance_count : 0
  
  compartment_id      = local.compartment_id
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  display_name        = "${local.amd_micro_hostnames[count.index]}-block"
  size_in_gbs         = local.amd_block_volume_size_gb
  
  freeform_tags = {
    "Purpose" = "AlwaysFreeTier"
    "Type"    = "BlockVolume"
    "Managed" = "Terraform"
  }
}

resource "oci_core_volume_attachment" "amd_block" {
  count = local.amd_block_volume_size_gb > 0 ? local.amd_micro_instance_count : 0
  
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.amd[count.index].id
  volume_id       = oci_core_volume.amd_block[count.index].id
}

# ARM Block Volumes
resource "oci_core_volume" "arm_block" {
  count = local.arm_flex_instance_count > 0 ? length([for s in local.arm_block_volume_sizes : s if s > 0]) : 0
  
  compartment_id      = local.compartment_id
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  display_name        = "${local.arm_flex_hostnames[count.index]}-block"
  size_in_gbs         = [for s in local.arm_block_volume_sizes : s if s > 0][count.index]
  
  freeform_tags = {
    "Purpose" = "AlwaysFreeTier"
    "Type"    = "BlockVolume"
    "Managed" = "Terraform"
  }
}

resource "oci_core_volume_attachment" "arm_block" {
  count = local.arm_flex_instance_count > 0 ? length([for s in local.arm_block_volume_sizes : s if s > 0]) : 0
  
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.arm[count.index].id
  volume_id       = oci_core_volume.arm_block[count.index].id
}
'''

    def _render_cloud_init(self) -> str:
        return '''#cloud-config
hostname: ${hostname}
fqdn: ${hostname}.local
manage_etc_hosts: true

package_update: true
package_upgrade: true

packages:
  - curl
  - wget
  - git
  - htop
  - vim
  - unzip
  - jq
  - tmux
  - net-tools
  - iotop
  - ncdu

runcmd:
  - echo "Instance ${hostname} initialized at $(date)" >> /var/log/cloud-init-complete.log
  - systemctl enable --now fail2ban || true

# Basic security hardening
write_files:
  - path: /etc/ssh/sshd_config.d/hardening.conf
    content: |
      PermitRootLogin no
      PasswordAuthentication no
      MaxAuthTries 3
      ClientAliveInterval 300
      ClientAliveCountMax 2

timezone: UTC
ssh_pwauth: false

final_message: "Instance ${hostname} ready after $UPTIME seconds"
'''

    def _run_terraform_deploy(self, terraform_dir: Path) -> None:
        self._run_terraform_cmd(["terraform", "init", "-input=false"], terraform_dir)
        self._run_terraform_cmd(["terraform", "plan", "-out", "tfplan"], terraform_dir)
        self._run_terraform_apply_with_retries(terraform_dir)

    def _run_terraform_cmd(
        self,
        cmd: list[str],
        cwd: Path,
    ) -> subprocess.CompletedProcess[str]:
        proc = subprocess.run(
            cmd,
            cwd=str(cwd),
            check=False,
            text=True,
            capture_output=True,
        )
        output = (proc.stdout or "") + (proc.stderr or "")
        if proc.returncode != 0:
            raise click.ClickException(f"Command failed ({' '.join(cmd)}):\n{output}")
        if output.strip():
            click.echo(output)
        return proc

    def _run_terraform_apply_with_retries(self, cwd: Path) -> None:
        max_attempts = int(os.getenv("RETRY_MAX_ATTEMPTS", "8"))
        base_delay = int(os.getenv("RETRY_BASE_DELAY", "15"))

        last_output = ""
        for attempt in range(1, max_attempts + 1):
            proc = subprocess.run(
                ["terraform", "apply", "-input=false", "tfplan"],
                cwd=str(cwd),
                check=False,
                text=True,
                capture_output=True,
            )
            output = (proc.stdout or "") + (proc.stderr or "")
            last_output = output
            if proc.returncode == 0:
                if output.strip():
                    click.echo(output)
                click.echo("terraform apply succeeded")
                return

            if not OUT_OF_CAPACITY_RE.search(output):
                raise click.ClickException(f"terraform apply failed:\n{output}")

            if attempt == max_attempts:
                break

            sleep_time = base_delay * (2 ** (attempt - 1))
            click.echo(
                f"Detected out-of-capacity condition on attempt {attempt}/{max_attempts}; retrying in {sleep_time}s...",
            )
            time.sleep(sleep_time)

        raise click.ClickException(
            f"terraform apply did not succeed after {max_attempts} attempts.\n{last_output}",
        )


@click.command(context_settings={"help_option_names": ["-h", "--help"]})
@click.option(
    "--profile",
    default=lambda: os.getenv("OCI_PROFILE", "DEFAULT"),
    show_default=True,
)
@click.option(
    "--config-file",
    default=lambda: os.getenv("OCI_CONFIG_FILE", str(Path.home() / ".oci" / "config")),
    show_default=True,
)
@click.option(
    "--auth-mode",
    type=click.Choice(
        ["api_key", "instance_principal", "resource_principal", "security_token"],
    ),
    default=lambda: os.getenv("OCI_AUTH_MODE", "api_key"),
    show_default=True,
)
@click.option("--non-interactive/--interactive", default=False, show_default=True)
@click.option(
    "--auto-use-existing/--no-auto-use-existing",
    default=False,
    show_default=True,
)
@click.option("--auto-deploy/--no-auto-deploy", default=False, show_default=True)
@click.option(
    "--terraform-dir",
    type=click.Path(file_okay=False, dir_okay=True, path_type=Path),
    default=Path.cwd(),
    show_default=True,
)
@click.option("--tenancy-ocid", default=lambda: os.getenv("OCI_TENANCY_OCID"))
@click.option(
    "--region",
    default=lambda: os.getenv("OCI_AUTH_REGION") or os.getenv("OCI_REGION"),
)
@click.option(
    "--strict-provider-parity/--no-strict-provider-parity",
    default=True,
    show_default=True,
)
def main(
    profile: str,
    config_file: str,
    auth_mode: str,
    non_interactive: bool,
    auto_use_existing: bool,
    auto_deploy: bool,
    terraform_dir: Path,
    tenancy_ocid: str | None,
    region: str | None,
    strict_provider_parity: bool,
) -> None:
    runtime = RuntimeConfig(
        profile=profile,
        config_file=config_file,
        auth_mode=auth_mode,
        non_interactive=non_interactive,
        auto_use_existing=auto_use_existing,
        auto_deploy=auto_deploy,
        terraform_dir=terraform_dir,
        tenancy_ocid=tenancy_ocid,
        region=region,
        strict_provider_parity=strict_provider_parity,
    )

    workflow = CloudBooterWorkflow(runtime)
    workflow.run()


if __name__ == "__main__":
    main()

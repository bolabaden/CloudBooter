"""GCP resource inventory — gcloud_cmd() with Python SDK fallback.

Populates EXISTING_* dicts before any Terraform generation.
All functions are idempotent and never create/modify resources.

Refs:
  https://cloud.google.com/compute/docs/reference/rest/v1/instances
  https://cloud.google.com/storage/docs/json_api/v1/buckets
  https://cloud.google.com/firestore/docs/reference/rest/v1/projects.databases
"""
from __future__ import annotations
import json
import os
import shutil
import subprocess
from dataclasses import dataclass, field
from typing import Any


@dataclass
class ResourceInventory:
    vpcs: dict[str, Any] = field(default_factory=dict)           # name → dict
    subnets: dict[str, Any] = field(default_factory=dict)        # name → dict
    firewalls: dict[str, Any] = field(default_factory=dict)      # name → dict
    instances: dict[str, Any] = field(default_factory=dict)      # name → dict
    disks: dict[str, Any] = field(default_factory=dict)          # name → dict
    static_ips: dict[str, Any] = field(default_factory=dict)     # name → dict
    buckets: dict[str, Any] = field(default_factory=dict)        # name → dict
    firestore_dbs: dict[str, Any] = field(default_factory=dict)  # name → dict


def _gcloud(*args: str, project: str | None = None) -> list[dict] | dict | None:
    """Run a gcloud command returning JSON.  Returns None on failure."""
    if not shutil.which("gcloud"):
        return None
    cmd = ["gcloud"] + list(args) + ["--format=json", "--quiet"]
    if project:
        cmd += [f"--project={project}"]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30, check=False)  # noqa: S603
        if r.returncode != 0:
            return None
        return json.loads(r.stdout)
    except Exception:  # noqa: BLE001
        return None


def _sdk_list_instances(project: str, zone: str | None = None) -> list[dict]:
    """Python SDK fallback for listing Compute instances."""
    try:
        from google.cloud import compute_v1
        from cloudbooter.auth import build_google_credentials

        creds = build_google_credentials()
        client = compute_v1.InstancesClient(credentials=creds)
        if zone:
            return list(client.list(project=project, zone=zone))
        # Aggregate across all zones
        agg_client = compute_v1.AggregatedListInstancesRequest(project=project)
        instances = []
        for _, resp in client.aggregated_list(request=agg_client):
            instances.extend(resp.instances)
        return instances
    except Exception:  # noqa: BLE001
        return []


def _sdk_list_buckets(project: str) -> list[dict]:
    """Python SDK fallback for listing Cloud Storage buckets."""
    try:
        from google.cloud import storage
        from cloudbooter.auth import build_google_credentials

        creds = build_google_credentials()
        client = storage.Client(project=project, credentials=creds)
        return [{"name": b.name, "location": b.location} for b in client.list_buckets()]
    except Exception:  # noqa: BLE001
        return []


def run_full_inventory(project: str, region: str | None = None) -> ResourceInventory:
    """Populate a ResourceInventory for the given project."""
    inv = ResourceInventory()

    # VPCs
    vpcs = _gcloud("compute", "networks", "list", project=project)
    if vpcs:
        for v in vpcs:
            inv.vpcs[v["name"]] = v

    # Subnets (filter to region if provided)
    subnets_args = ["compute", "subnets", "list"]
    if region:
        subnets_args += [f"--filter=region:{region}"]
    subnets = _gcloud(*subnets_args, project=project)
    if subnets:
        for s in subnets:
            inv.subnets[s["name"]] = s

    # Firewall rules
    firewalls = _gcloud("compute", "firewall-rules", "list", project=project)
    if firewalls:
        for f in firewalls:
            inv.firewalls[f["name"]] = f

    # Instances
    instance_args = ["compute", "instances", "list"]
    if region:
        instance_args += [f"--filter=zone~{region}"]
    instances = _gcloud(*instance_args, project=project)
    if instances is None:
        # SDK fallback
        instances = _sdk_list_instances(project)
    for inst in (instances or []):
        name = inst.get("name") or getattr(inst, "name", None)
        if name:
            inv.instances[name] = inst

    # Disks
    disk_args = ["compute", "disks", "list"]
    if region:
        disk_args += [f"--filter=zone~{region}"]
    disks = _gcloud(*disk_args, project=project)
    if disks:
        for d in disks:
            inv.disks[d["name"]] = d

    # Static IPs (addresses)
    addr_args = ["compute", "addresses", "list"]
    if region:
        addr_args += [f"--filter=region:{region}"]
    addrs = _gcloud(*addr_args, project=project)
    if addrs:
        for a in addrs:
            inv.static_ips[a["name"]] = a

    # Cloud Storage buckets
    buckets = _gcloud("storage", "ls", "--json", project=project)
    if buckets is None:
        buckets_raw = _sdk_list_buckets(project)
        for b in buckets_raw:
            inv.buckets[b["name"]] = b
    elif buckets:
        for b in buckets:
            name = b.get("name", "").rstrip("/")
            if name:
                inv.buckets[name] = b

    # Firestore databases
    fstore = _gcloud("firestore", "databases", "list", project=project)
    if fstore:
        for db in fstore:
            inv.firestore_dbs[db.get("name", "unknown")] = db

    return inv


def display_inventory_dashboard(inv: ResourceInventory, project: str, region: str) -> None:
    """Print an OCI-style inventory dashboard to stdout."""
    try:
        from rich.console import Console
        from rich.table import Table

        console = Console()
        console.print(f"\n[bold magenta]╔══ GCP Resource Inventory — {project} / {region} ══╗[/]")

        def _tbl(title: str, items: dict, cols: list[str]) -> None:
            if not items:
                console.print(f"  [cyan]{title}:[/] (none)")
                return
            t = Table(title=title, show_header=True, header_style="bold cyan")
            for c in cols:
                t.add_column(c)
            for name, data in items.items():
                row = [name] + [str(data.get(c, "—")) for c in cols[1:]]
                t.add_row(*row)
            console.print(t)

        _tbl("VPCs", inv.vpcs, ["name", "autoCreateSubnetworks", "routingConfig"])
        _tbl("Subnets", inv.subnets, ["name", "ipCidrRange", "region"])
        _tbl("Instances", inv.instances, ["name", "machineType", "status", "zone"])
        _tbl("Disks", inv.disks, ["name", "type", "sizeGb", "zone"])
        _tbl("Static IPs", inv.static_ips, ["name", "address", "status"])
        _tbl("Buckets", inv.buckets, ["name", "location"])
        _tbl("Firestore DBs", inv.firestore_dbs, ["name"])

        # Warn on billable static IPs
        for name, addr in inv.static_ips.items():
            status = str(addr.get("status", "")).upper()
            if status == "RESERVED":
                console.print(f"  [bold red]⚠ COST TRAP:[/] Static IP '{name}' is RESERVED but not attached — incurring charges!")

        console.print("[bold magenta]╚══════════════════════════════════════════════╝[/]\n")

    except ImportError:
        # Fallback plain text if rich not installed
        print(f"\n=== GCP Resource Inventory — {project} / {region} ===")
        print(f"  VPCs:        {len(inv.vpcs)}")
        print(f"  Subnets:     {len(inv.subnets)}")
        print(f"  Instances:   {len(inv.instances)}")
        print(f"  Disks:       {len(inv.disks)}")
        print(f"  Static IPs:  {len(inv.static_ips)}")
        print(f"  Buckets:     {len(inv.buckets)}")
        print(f"  Firestore:   {len(inv.firestore_dbs)}")
        print("=" * 48)

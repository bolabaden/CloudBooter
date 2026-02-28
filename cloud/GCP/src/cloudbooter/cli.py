"""cloudbooter-gcp CLI entrypoint.

Usage:
  cloudbooter-gcp deploy   [options]
  cloudbooter-gcp validate [options]
  cloudbooter-gcp inventory [options]
  cloudbooter-gcp install-deps
"""
from __future__ import annotations
import os
import sys
from pathlib import Path

import click


@click.group()
@click.version_option("0.1.0", prog_name="cloudbooter-gcp")
def main() -> None:
    """CloudBooter GCP — Always Free Tier provisioning toolkit."""


@main.command()
@click.option("--project", envvar="GCP_PROJECT_ID", required=True, help="GCP project ID")
@click.option("--region", envvar="GCP_REGION", default="us-central1", show_default=True)
@click.option("--zone", envvar="GCP_ZONE", default="", help="GCP zone (auto-selected if empty)")
@click.option("--instance-name", envvar="GCP_INSTANCE_NAME", default="cloudbooter-vm", show_default=True)
@click.option("--disk-size", envvar="GCP_BOOT_DISK_GB", default=20, show_default=True, type=int)
@click.option("--ssh-public-key", envvar="GCP_SSH_PUBLIC_KEY", default="", help="SSH pubkey string or @path")
@click.option("--credentials-file", envvar="GCP_CREDENTIALS_FILE", default="", help="SA key or WIF credential file")
@click.option("--impersonate-sa", envvar="GCP_IMPERSONATE_SERVICE_ACCOUNT", default="")
@click.option("--allow-paid/--no-allow-paid", envvar="GCP_ALLOW_PAID_RESOURCES", default=False)
@click.option("--auto-deploy/--no-auto-deploy", envvar="AUTO_DEPLOY", default=False)
@click.option("--non-interactive/--interactive", envvar="NON_INTERACTIVE", default=False)
@click.option("--output-dir", default=".", show_default=True, help="Directory to write .tf files into")
def deploy(
    project, region, zone, instance_name, disk_size, ssh_public_key,
    credentials_file, impersonate_sa, allow_paid, auto_deploy, non_interactive, output_dir,
):
    """Generate Terraform files and optionally deploy."""
    from cloudbooter.free_tier import validate_proposed_config
    from cloudbooter.renderers import (
        render_provider, render_variables, render_data_sources,
        render_main, render_cloud_init,
    )

    # Validate
    errors = validate_proposed_config(
        machine_type="e2-micro",
        region=region,
        boot_disk_size_gb=disk_size,
        allow_paid_resources=allow_paid,
    )
    hard_errors = [e for e in errors if e.startswith("ERROR:")]
    if hard_errors:
        for e in hard_errors:
            click.echo(click.style(e, fg="red"), err=True)
        sys.exit(1)

    # Zone auto-selection
    if not zone:
        zone = f"{region}-a"

    # SSH key handling
    if ssh_public_key.startswith("@"):
        ssh_public_key = Path(ssh_public_key[1:]).read_text().strip()

    out = Path(output_dir)
    out.mkdir(parents=True, exist_ok=True)

    include_creds = bool(credentials_file)
    include_imp = bool(impersonate_sa)

    # Write Terraform files
    (out / "provider.tf").write_text(
        render_provider(project, region, credentials_file or None, impersonate_sa or None),
        encoding="utf-8",
    )
    (out / "variables.tf").write_text(
        render_variables(
            project, region, zone, instance_name, disk_size,
            include_credentials=include_creds,
            include_impersonation=include_imp,
        ),
        encoding="utf-8",
    )
    (out / "data_sources.tf").write_text(render_data_sources(), encoding="utf-8")
    (out / "main.tf").write_text(render_main(instance_name), encoding="utf-8")
    (out / "cloud-init.yaml").write_text(render_cloud_init(instance_name), encoding="utf-8")

    click.echo(click.style(f"Terraform files written to {out.resolve()}", fg="green"))

    if auto_deploy:
        _terraform_deploy(out, non_interactive)


@main.command()
@click.option("--project", envvar="GCP_PROJECT_ID", required=True)
@click.option("--region", envvar="GCP_REGION", default="us-central1")
@click.option("--machine-type", default="e2-micro")
@click.option("--disk-size", default=20, type=int)
@click.option("--allow-paid/--no-allow-paid", envvar="GCP_ALLOW_PAID_RESOURCES", default=False)
def validate(project, region, machine_type, disk_size, allow_paid):
    """Validate a proposed config against free-tier limits."""
    from cloudbooter.free_tier import validate_proposed_config

    errors = validate_proposed_config(machine_type, region, disk_size, allow_paid_resources=allow_paid)
    if not errors:
        click.echo(click.style("✓ Config is within GCP Always Free limits.", fg="green"))
    else:
        for e in errors:
            color = "red" if e.startswith("ERROR") else "yellow"
            click.echo(click.style(e, fg=color))
        sys.exit(1 if any(e.startswith("ERROR") for e in errors) else 0)


@main.command()
@click.option("--project", envvar="GCP_PROJECT_ID", required=True)
@click.option("--region", envvar="GCP_REGION", default="us-central1")
def inventory(project, region):
    """Show existing GCP resources in the project."""
    from cloudbooter.inventory import run_full_inventory, display_inventory_dashboard

    click.echo(f"Fetching inventory for project={project} region={region} …")
    inv = run_full_inventory(project, region)
    display_inventory_dashboard(inv, project, region)


@main.command("install-deps")
@click.option("--requirements", default=None, help="Path to requirements.txt")
def install_deps(requirements):
    """Install gcloud CLI, Terraform, and Python dependencies."""
    from cloudbooter.installer import install_gcloud, install_terraform, ensure_python_deps

    mode = install_gcloud()
    click.echo(f"GCP_MODE={mode}")

    ok = install_terraform()
    click.echo(f"Terraform: {'installed' if ok else 'FAILED'}")

    ensure_python_deps(requirements)
    click.echo("Python deps: installed")


def _terraform_deploy(tf_dir: Path, non_interactive: bool) -> None:
    import subprocess

    env = os.environ.copy()
    env["TF_IN_AUTOMATION"] = "1" if non_interactive else ""

    for cmd in [["terraform", "init", "-input=false"],
                ["terraform", "plan", "-input=false", "-out=tfplan"],
                ["terraform", "apply", "-input=false", "tfplan"]]:
        click.echo(f"$ {' '.join(cmd)}")
        r = subprocess.run(cmd, cwd=tf_dir, env=env, check=False)  # noqa: S603
        if r.returncode != 0:
            click.echo(click.style(f"terraform command failed: {' '.join(cmd)}", fg="red"), err=True)
            sys.exit(r.returncode)

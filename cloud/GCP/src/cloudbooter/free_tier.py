"""GCP Always Free Tier hard limits — canonical source for all layers.

Keep in sync with:
  - shell: setup_gcp_terraform.sh constants block
  - Terraform: variables.tf check blocks
  - docs: FREE_TIER_LIMITS.md

Ref: https://cloud.google.com/free/docs/free-cloud-features (2026-02-20)
"""
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class GCPFreeTierLimits:
    # ── Compute ───────────────────────────────────────────────────────────────
    free_machine_type: str = "e2-micro"
    free_compute_hours_per_month: int = 744          # cumulative across all e2-micro in billing account
    free_compute_regions: tuple[str, ...] = ("us-west1", "us-central1", "us-east1")
    free_standard_pd_gb: int = 30
    free_compute_egress_gb: int = 1                  # NA → all (excl. China, AU)

    # ── Storage ───────────────────────────────────────────────────────────────
    free_storage_gb: int = 5                         # Cloud Storage, US regions only
    free_storage_regions: tuple[str, ...] = ("us-east1", "us-west1", "us-central1")
    free_storage_class_a_ops: int = 5_000
    free_storage_class_b_ops: int = 50_000
    free_storage_egress_gb: int = 100               # NA to all (excl. China, AU)

    # ── Firestore ─────────────────────────────────────────────────────────────
    free_firestore_storage_gib: int = 1
    free_firestore_reads_per_day: int = 50_000
    free_firestore_writes_per_day: int = 20_000
    free_firestore_deletes_per_day: int = 20_000
    free_firestore_egress_gib_month: int = 10

    # ── BigQuery ──────────────────────────────────────────────────────────────
    free_bigquery_query_tib: int = 1
    free_bigquery_storage_gib: int = 10

    # ── Messaging ─────────────────────────────────────────────────────────────
    free_pubsub_gib_month: int = 10

    # ── Serverless ────────────────────────────────────────────────────────────
    free_functions_invocations: int = 2_000_000
    free_functions_gb_seconds: int = 400_000
    free_functions_ghz_seconds: int = 200_000
    free_functions_egress_gb: int = 5
    free_cloudrun_requests: int = 2_000_000
    free_cloudrun_gb_seconds: int = 360_000
    free_cloudrun_vcpu_seconds: int = 180_000
    free_cloudrun_egress_gb: int = 1

    # ── Security ──────────────────────────────────────────────────────────────
    free_secret_versions: int = 6
    free_secret_access_ops: int = 10_000
    free_secret_rotation_notifications: int = 3

    # ── DevOps ────────────────────────────────────────────────────────────────
    free_artifact_registry_gb: float = 0.5
    free_build_minutes: int = 2_500

    # ── Observability ─────────────────────────────────────────────────────────
    free_logging_gib_per_project: int = 50

    # ── Kubernetes ────────────────────────────────────────────────────────────
    free_gke_clusters: int = 1                       # management fee waiver only

    # ── App Engine Standard ───────────────────────────────────────────────────
    free_app_engine_f1_hours_per_day: int = 28
    free_app_engine_b1_hours_per_day: int = 9

    # ── Budget guards (non-free — block/warn by default) ─────────────────────
    cost_trap_cloud_dns: bool = True                 # $0.20/zone/month
    cost_trap_cloud_nat: bool = True                 # $0.044/gateway/hr
    cost_trap_load_balancer: bool = True             # per-rule + data-processing


# Module-level singleton for convenience
LIMITS = GCPFreeTierLimits()


def validate_proposed_config(
    machine_type: str,
    region: str,
    boot_disk_size_gb: int,
    storage_region: str | None = None,
    allow_paid_resources: bool = False,
) -> list[str]:
    """Validate a proposed GCP resource configuration against free-tier limits.

    Returns a list of error strings.  An empty list means the config is valid.
    Warnings (non-blocking) are prefixed with 'WARN:'.
    """
    errors: list[str] = []
    limits = LIMITS

    if not allow_paid_resources:
        if machine_type != limits.free_machine_type:
            errors.append(
                f"ERROR: Machine type '{machine_type}' is not Always Free. "
                f"Only '{limits.free_machine_type}' is free. "
                f"Set GCP_ALLOW_PAID_RESOURCES=true to override."
            )

        if region not in limits.free_compute_regions:
            errors.append(
                f"ERROR: Region '{region}' is not Always Free for Compute Engine. "
                f"Free regions: {', '.join(limits.free_compute_regions)}."
            )

        if boot_disk_size_gb > limits.free_standard_pd_gb:
            errors.append(
                f"ERROR: Boot disk {boot_disk_size_gb} GB exceeds Always Free cap "
                f"of {limits.free_standard_pd_gb} GB standard PD."
            )

        if storage_region and storage_region not in limits.free_storage_regions:
            errors.append(
                f"ERROR: Cloud Storage region '{storage_region}' is not Always Free. "
                f"Free regions: {', '.join(limits.free_storage_regions)}."
            )

    return errors

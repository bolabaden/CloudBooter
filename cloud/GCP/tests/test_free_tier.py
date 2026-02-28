"""Tests for GCP free-tier constants and validation logic.

All tests are pure Python — no GCP credentials, no network, no gcloud.

Test philosophy:
  - Every field on GCPFreeTierLimits has an explicit assertion so regressions
    in the constants are caught immediately (they're the canonical source of
    truth for Bash and Terraform too).
  - validate_proposed_config() is tested as a state machine: valid inputs produce
    [], invalid inputs produce specific ERROR: prefixed strings, and
    allow_paid_resources=True always produces [].
  - Error message text is asserted against real substrings from the source,
    not vacuous truthy expressions.
"""
from __future__ import annotations

import pytest

from cloudbooter.free_tier import GCPFreeTierLimits, LIMITS, validate_proposed_config


# ─────────────────────────────────────────────────────────────────────────────
# GCPFreeTierLimits dataclass
# ─────────────────────────────────────────────────────────────────────────────

class TestGCPFreeTierLimitsConstants:
    """Every field is pinned.  If GCP changes a limit, update free_tier.py,
    the Bash constants, and the Terraform check blocks — then update this test."""

    # ── Compute ───────────────────────────────────────────────────────────────

    def test_free_machine_type_is_e2_micro(self):
        assert LIMITS.free_machine_type == "e2-micro"

    def test_compute_hours_is_744(self):
        # 744 = 31 days × 24 h, the longest month — covers 1 instance 24/7
        assert LIMITS.free_compute_hours_per_month == 744

    def test_free_compute_regions_exact(self):
        assert set(LIMITS.free_compute_regions) == {"us-west1", "us-central1", "us-east1"}

    def test_european_region_not_free_compute(self):
        assert "europe-west1" not in LIMITS.free_compute_regions

    def test_asia_region_not_free_compute(self):
        assert "asia-east1" not in LIMITS.free_compute_regions

    def test_standard_pd_cap_is_30gb(self):
        assert LIMITS.free_standard_pd_gb == 30

    def test_compute_egress_gb(self):
        assert LIMITS.free_compute_egress_gb == 1

    # ── Storage ───────────────────────────────────────────────────────────────

    def test_free_storage_gb_is_5(self):
        assert LIMITS.free_storage_gb == 5

    def test_free_storage_regions_exact(self):
        assert set(LIMITS.free_storage_regions) == {"us-east1", "us-west1", "us-central1"}

    def test_european_region_not_free_storage(self):
        assert "europe-west1" not in LIMITS.free_storage_regions

    def test_class_a_ops(self):
        assert LIMITS.free_storage_class_a_ops == 5_000

    def test_class_b_ops(self):
        assert LIMITS.free_storage_class_b_ops == 50_000

    # ── Secret Manager ────────────────────────────────────────────────────────

    def test_secret_versions_is_6(self):
        assert LIMITS.free_secret_versions == 6

    def test_secret_access_ops_is_10k(self):
        assert LIMITS.free_secret_access_ops == 10_000

    # ── Cost-trap flags ───────────────────────────────────────────────────────

    def test_cloud_dns_is_cost_trap(self):
        assert LIMITS.cost_trap_cloud_dns is True

    def test_cloud_nat_is_cost_trap(self):
        assert LIMITS.cost_trap_cloud_nat is True

    def test_load_balancer_is_cost_trap(self):
        assert LIMITS.cost_trap_load_balancer is True

    # ── Immutability ──────────────────────────────────────────────────────────

    def test_dataclass_is_frozen(self):
        """Mutation must raise — it's a frozen dataclass, not a mutable object."""
        with pytest.raises((AttributeError, TypeError)):
            LIMITS.free_machine_type = "n1-standard-1"  # type: ignore[misc]

    def test_module_singleton_is_correct_type(self):
        assert isinstance(LIMITS, GCPFreeTierLimits)

    def test_new_instance_equals_singleton(self):
        """Two default instances must be equal (frozen dataclass equality)."""
        assert GCPFreeTierLimits() == LIMITS


# ─────────────────────────────────────────────────────────────────────────────
# validate_proposed_config()
# ─────────────────────────────────────────────────────────────────────────────

class TestValidateProposedConfigValid:
    """All valid free-tier configs must return an empty list."""

    def test_canonical_free_config(self):
        assert validate_proposed_config("e2-micro", "us-central1", 20) == []

    def test_us_west1(self):
        assert validate_proposed_config("e2-micro", "us-west1", 20) == []

    def test_us_east1(self):
        assert validate_proposed_config("e2-micro", "us-east1", 20) == []

    def test_disk_exactly_at_cap(self):
        assert validate_proposed_config("e2-micro", "us-central1", 30) == []

    def test_disk_at_minimum(self):
        assert validate_proposed_config("e2-micro", "us-central1", 1) == []

    def test_storage_region_us_east1(self):
        assert validate_proposed_config("e2-micro", "us-central1", 20, storage_region="us-east1") == []

    def test_storage_region_us_west1(self):
        assert validate_proposed_config("e2-micro", "us-central1", 20, storage_region="us-west1") == []

    def test_storage_region_us_central1(self):
        assert validate_proposed_config("e2-micro", "us-central1", 20, storage_region="us-central1") == []

    def test_no_storage_region_specified(self):
        """storage_region=None means no GCS bucket — should not produce storage errors."""
        errors = validate_proposed_config("e2-micro", "us-central1", 20, storage_region=None)
        assert not any("Storage" in e for e in errors)


class TestValidateProposedConfigMachineType:
    """Wrong machine type must produce exactly one ERROR: entry."""

    def test_rejects_n1_standard(self):
        errors = validate_proposed_config("n1-standard-1", "us-central1", 20)
        assert len(errors) == 1
        assert errors[0].startswith("ERROR:")
        assert "n1-standard-1" in errors[0]
        assert "e2-micro" in errors[0]

    def test_rejects_e2_medium(self):
        errors = validate_proposed_config("e2-medium", "us-central1", 20)
        assert len(errors) == 1
        assert "e2-medium" in errors[0]

    def test_rejects_n2_standard(self):
        errors = validate_proposed_config("n2-standard-4", "us-central1", 20)
        assert any("n2-standard-4" in e for e in errors)

    def test_allow_paid_bypasses_machine_type(self):
        errors = validate_proposed_config("n1-standard-96", "us-central1", 20, allow_paid_resources=True)
        assert errors == []

    def test_machine_type_error_mentions_override(self):
        errors = validate_proposed_config("n1-standard-1", "us-central1", 20)
        assert "GCP_ALLOW_PAID_RESOURCES" in errors[0]


class TestValidateProposedConfigRegion:
    """Wrong region must produce exactly one ERROR: entry."""

    def test_rejects_europe_west1(self):
        errors = validate_proposed_config("e2-micro", "europe-west1", 20)
        assert len(errors) == 1
        assert errors[0].startswith("ERROR:")
        assert "europe-west1" in errors[0]

    def test_rejects_asia_east1(self):
        errors = validate_proposed_config("e2-micro", "asia-east1", 20)
        assert any("asia-east1" in e for e in errors)

    def test_rejects_southamerica(self):
        errors = validate_proposed_config("e2-micro", "southamerica-east1", 20)
        assert any("southamerica-east1" in e for e in errors)

    def test_region_error_lists_free_regions(self):
        errors = validate_proposed_config("e2-micro", "europe-west4", 20)
        # All three free regions should be mentioned in the error text
        assert "us-west1" in errors[0]
        assert "us-central1" in errors[0]
        assert "us-east1" in errors[0]

    def test_allow_paid_bypasses_region(self):
        assert validate_proposed_config("e2-micro", "europe-west1", 20, allow_paid_resources=True) == []


class TestValidateProposedConfigDiskSize:
    """Oversized disk must produce exactly one ERROR: entry."""

    def test_rejects_31gb(self):
        errors = validate_proposed_config("e2-micro", "us-central1", 31)
        assert len(errors) == 1
        assert errors[0].startswith("ERROR:")
        assert "31" in errors[0]
        assert "30" in errors[0]

    def test_rejects_100gb(self):
        errors = validate_proposed_config("e2-micro", "us-central1", 100)
        assert len(errors) == 1
        assert "100" in errors[0]

    def test_rejects_200gb(self):
        errors = validate_proposed_config("e2-micro", "us-central1", 200)
        assert len(errors) == 1

    def test_allow_paid_bypasses_disk(self):
        assert validate_proposed_config("e2-micro", "us-central1", 500, allow_paid_resources=True) == []


class TestValidateProposedConfigStorage:
    """Wrong storage region must produce exactly one ERROR: entry."""

    def test_rejects_europe_storage(self):
        errors = validate_proposed_config("e2-micro", "us-central1", 20, storage_region="europe-west1")
        assert len(errors) == 1
        assert errors[0].startswith("ERROR:")
        assert "europe-west1" in errors[0]
        assert "Storage" in errors[0]

    def test_rejects_asia_storage(self):
        errors = validate_proposed_config("e2-micro", "us-central1", 20, storage_region="asia-northeast1")
        assert any("Storage" in e for e in errors)

    def test_allow_paid_bypasses_storage(self):
        errors = validate_proposed_config(
            "e2-micro", "us-central1", 20,
            storage_region="europe-west1",
            allow_paid_resources=True,
        )
        assert errors == []


class TestValidateProposedConfigMultipleErrors:
    """Multiple violations must all appear — no short-circuit."""

    def test_bad_machine_and_bad_region(self):
        errors = validate_proposed_config("n1-standard-1", "europe-west1", 20)
        assert len(errors) == 2
        assert any("n1-standard-1" in e for e in errors)
        assert any("europe-west1" in e for e in errors)

    def test_bad_machine_bad_region_bad_disk(self):
        errors = validate_proposed_config("n2-standard-2", "asia-east1", 200)
        assert len(errors) == 3
        assert all(e.startswith("ERROR:") for e in errors)

    def test_all_four_violations(self):
        errors = validate_proposed_config(
            "n2-standard-2", "asia-east1", 200, storage_region="europe-west1"
        )
        assert len(errors) == 4

    def test_all_four_with_paid_override_yields_zero(self):
        errors = validate_proposed_config(
            "n2-standard-2", "asia-east1", 200,
            storage_region="europe-west1",
            allow_paid_resources=True,
        )
        assert errors == []


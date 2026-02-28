"""Shared pytest fixtures and canonical mock data for cloudbooter-gcp tests.

No GCP project, no gcloud, no network — everything is either:
  - pure Python (unit tests for free_tier, renderers)
  - monkeypatched at the subprocess/urllib boundary (integration tests)

Why no real GCP calls:
  The resources this tool creates (VPCs, firewall rules, disks, instances)
  are idempotent and can't be reliably cleaned up in a shared CI project.
  The parts that need real GCP (auth token refresh, quota behaviour) are
  exercised in the separate live/smoke test suite (not in this directory).
"""
from __future__ import annotations
import json
import os
from pathlib import Path
from unittest.mock import MagicMock

import pytest


# ─────────────────────────────────────────────────────────────────────────────
# Temp directory fixture
# ─────────────────────────────────────────────────────────────────────────────

@pytest.fixture()
def tmp_tf_dir(tmp_path: Path) -> Path:
    """Fresh empty directory for writing generated Terraform files."""
    return tmp_path


# ─────────────────────────────────────────────────────────────────────────────
# Credential file fixtures — written to disk, no real GCP keys
# ─────────────────────────────────────────────────────────────────────────────

@pytest.fixture()
def sa_key_file(tmp_path: Path) -> str:
    """Minimal service_account JSON — enough for type-detection, NOT cryptographically valid."""
    payload = {
        "type": "service_account",
        "project_id": "test-project",
        "private_key_id": "deadbeef",
        # RSA header/footer with obviously fake body — json.load() succeeds, google-auth will reject it
        "private_key": (
            "-----BEGIN RSA PRIVATE KEY-----\n"
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n"
            "-----END RSA PRIVATE KEY-----\n"
        ),
        "client_email": "cloudbooter@test-project.iam.gserviceaccount.com",
        "client_id": "111222333444555666",
        "auth_uri": "https://accounts.google.com/o/oauth2/auth",
        "token_uri": "https://oauth2.googleapis.com/token",
    }
    p = tmp_path / "sa_key.json"
    p.write_text(json.dumps(payload))
    return str(p)


@pytest.fixture()
def wif_cred_file(tmp_path: Path) -> str:
    """Minimal external_account (WIF) JSON credential config."""
    payload = {
        "type": "external_account",
        "audience": (
            "//iam.googleapis.com/projects/123456/locations/global"
            "/workloadIdentityPools/my-pool/providers/my-provider"
        ),
        "subject_token_type": "urn:ietf:params:oauth:token-type:id_token",
        "token_url": "https://sts.googleapis.com/v1/token",
        "credential_source": {"file": "/var/run/secrets/token"},
    }
    p = tmp_path / "wif_cred.json"
    p.write_text(json.dumps(payload))
    return str(p)


@pytest.fixture()
def unknown_cred_file(tmp_path: Path) -> str:
    """JSON credential with no 'type' field — should fall back gracefully."""
    payload = {"project_id": "test-project", "token": "ya29.fake"}
    p = tmp_path / "unknown_cred.json"
    p.write_text(json.dumps(payload))
    return str(p)


# ─────────────────────────────────────────────────────────────────────────────
# Environment isolation fixture
# ─────────────────────────────────────────────────────────────────────────────

_GCP_ENV_KEYS = [
    "GCP_PROJECT_ID", "GCP_REGION", "GCP_ZONE",
    "GCP_CREDENTIALS_FILE", "GOOGLE_APPLICATION_CREDENTIALS",
    "GCP_IMPERSONATE_SERVICE_ACCOUNT", "GCP_ALLOW_PAID_RESOURCES",
    "GCP_MODE", "GCP_INSTANCE_NAME", "GCP_BOOT_DISK_GB",
    "NON_INTERACTIVE", "AUTO_DEPLOY", "AUTO_USE_EXISTING", "SKIP_CONFIG",
]

@pytest.fixture()
def clean_gcp_env(monkeypatch: pytest.MonkeyPatch):
    """Remove every GCP-related env var so tests start from a blank slate."""
    for key in _GCP_ENV_KEYS:
        monkeypatch.delenv(key, raising=False)


# ─────────────────────────────────────────────────────────────────────────────
# Canonical gcloud-shaped mock data
# These dicts match the real JSON structure that `gcloud ... --format=json`
# returns.  Tests that mock _gcloud() must use this shape so assertions on
# ResourceInventory field contents are meaningful.
# ─────────────────────────────────────────────────────────────────────────────

MOCK_INSTANCES: list[dict] = [
    {
        "name": "existing-vm",
        "machineType": "https://www.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/machineTypes/e2-micro",
        "status": "RUNNING",
        "zone": "https://www.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a",
        "selfLink": "https://www.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/instances/existing-vm",
        "networkInterfaces": [{"accessConfigs": [{"natIP": "34.1.2.3"}]}],
    }
]

MOCK_VPCS: list[dict] = [
    {
        "name": "existing-vpc",
        "autoCreateSubnetworks": False,
        "selfLink": "https://www.googleapis.com/compute/v1/projects/test-project/global/networks/existing-vpc",
        "routingConfig": {"routingMode": "REGIONAL"},
    }
]

MOCK_SUBNETS: list[dict] = [
    {
        "name": "existing-subnet",
        "ipCidrRange": "10.0.0.0/24",
        "region": "https://www.googleapis.com/compute/v1/projects/test-project/regions/us-central1",
        "network": "https://www.googleapis.com/compute/v1/projects/test-project/global/networks/existing-vpc",
        "selfLink": "https://www.googleapis.com/compute/v1/projects/test-project/regions/us-central1/subnetworks/existing-subnet",
    }
]

MOCK_FIREWALLS: list[dict] = [
    {
        "name": "existing-vm-allow-ssh",
        "network": "https://www.googleapis.com/compute/v1/projects/test-project/global/networks/existing-vpc",
        "allowed": [{"IPProtocol": "tcp", "ports": ["22"]}],
        "direction": "INGRESS",
        "disabled": False,
    }
]

MOCK_DISKS: list[dict] = [
    {
        "name": "existing-vm-boot",
        "type": "https://www.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/diskTypes/pd-standard",
        "sizeGb": "20",
        "zone": "https://www.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a",
        "status": "READY",
    }
]

MOCK_STATIC_IPS_CLEAN: list[dict] = []

MOCK_STATIC_IPS_WITH_RESERVED: list[dict] = [
    {
        "name": "leaked-ip",
        "address": "34.99.0.1",
        "status": "RESERVED",   # ← billing trap: not attached to any instance
        "region": "https://www.googleapis.com/compute/v1/projects/test-project/regions/us-central1",
    }
]

MOCK_BUCKETS: list[dict] = [
    {"name": "my-free-bucket", "location": "US-CENTRAL1"},
]

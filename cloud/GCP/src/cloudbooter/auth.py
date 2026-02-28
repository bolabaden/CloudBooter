"""GCP authentication helpers.

Supports all four auth patterns:
  1. ADC  (gcloud application-default login)
  2. WIF  (credential config JSON)
  3. SA key JSON
  4. Impersonation

Ref:
  https://cloud.google.com/docs/authentication/application-default-credentials
  https://cloud.google.com/docs/authentication/workload-identity-federation
  https://cloud.google.com/iam/docs/impersonating-service-accounts
"""
from __future__ import annotations
import json
import os
import subprocess
import shutil
from pathlib import Path


def detect_auth_pattern() -> str:
    """Return the active auth pattern name."""
    creds_file = os.environ.get("GCP_CREDENTIALS_FILE") or os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    if creds_file and Path(creds_file).exists():
        try:
            with open(creds_file) as f:
                info = json.load(f)
            if info.get("type") == "service_account":
                return "sa_key"
            return "wif"
        except Exception:  # noqa: BLE001
            return "wif"

    if os.environ.get("GCP_IMPERSONATE_SERVICE_ACCOUNT"):
        return "impersonation"

    # Check for metadata server (GCE / Cloud Run / GKE)
    try:
        import urllib.request
        req = urllib.request.Request(
            "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token",
            headers={"Metadata-Flavor": "Google"},
        )
        with urllib.request.urlopen(req, timeout=1):
            return "metadata_server"
    except Exception:  # noqa: BLE001
        pass

    return "adc"


def build_google_credentials(pattern: str | None = None):
    """Return a google.auth.credentials.Credentials object for the active pattern."""
    import google.auth
    import google.auth.impersonated_credentials
    from google.oauth2 import service_account

    if pattern is None:
        pattern = detect_auth_pattern()

    creds_file = os.environ.get("GCP_CREDENTIALS_FILE") or os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    impersonate_sa = os.environ.get("GCP_IMPERSONATE_SERVICE_ACCOUNT")

    scopes = ["https://www.googleapis.com/auth/cloud-platform"]

    if pattern == "sa_key" and creds_file:
        return service_account.Credentials.from_service_account_file(creds_file, scopes=scopes)

    if pattern == "impersonation":
        source_creds, project = google.auth.default(scopes=scopes)
        return google.auth.impersonated_credentials.Credentials(
            source_credentials=source_creds,
            target_principal=impersonate_sa,
            target_scopes=scopes,
        )

    # ADC / WIF / metadata server — google.auth.default handles all
    if creds_file:
        os.environ.setdefault("GOOGLE_APPLICATION_CREDENTIALS", creds_file)
    creds, _ = google.auth.default(scopes=scopes)
    return creds


def setup_adc_interactive() -> bool:
    """Run gcloud init + application-default login for interactive setup."""
    if not shutil.which("gcloud"):
        return False
    print("[cloudbooter] Running 'gcloud init' for interactive auth setup…")
    r = subprocess.run(["gcloud", "init"], check=False)
    if r.returncode != 0:
        return False
    print("[cloudbooter] Running 'gcloud auth application-default login'…")
    r = subprocess.run(["gcloud", "auth", "application-default", "login"], check=False)
    return r.returncode == 0


def activate_service_account(key_file: str) -> bool:
    """Activate a SA key in gcloud (also sets GOOGLE_APPLICATION_CREDENTIALS)."""
    if not shutil.which("gcloud"):
        # Python-only path: just set the env var
        os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = key_file
        return True
    r = subprocess.run(
        ["gcloud", "auth", "activate-service-account", f"--key-file={key_file}", "--quiet"],
        check=False,
    )
    if r.returncode == 0:
        os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = key_file
    return r.returncode == 0


def verify_credentials() -> tuple[bool, str]:
    """Verify current credentials work.  Returns (ok, message)."""
    try:
        import google.auth
        import google.auth.transport.requests

        creds = build_google_credentials()
        req = google.auth.transport.requests.Request()
        creds.refresh(req)
        return True, f"Credentials valid (type={type(creds).__name__})"
    except Exception as exc:  # noqa: BLE001
        return False, str(exc)

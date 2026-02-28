"""GCP prerequisite installer — 3-tier strategy (pkg mgr → silent download → Python SDK mode).

Called by setup_gcp_terraform.sh and directly by the Python CLI.

Refs:
  https://cloud.google.com/sdk/docs/install
  https://cloud.google.com/sdk/docs/downloads-interactive
  https://dl.google.com/dl/cloudsdk/channels/rapid/GoogleCloudSDKInstaller.exe
  https://releases.hashicorp.com/terraform/
"""
from __future__ import annotations
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path


GCLOUD_WIN_INSTALLER = "https://dl.google.com/dl/cloudsdk/channels/rapid/GoogleCloudSDKInstaller.exe"
GCLOUD_POSIX_INSTALLER = "https://sdk.cloud.google.com"
TERRAFORM_RELEASES = "https://releases.hashicorp.com/terraform"


def _run(cmd: list[str], check: bool = True, capture: bool = False) -> subprocess.CompletedProcess:
    kwargs: dict = {"check": check}
    if capture:
        kwargs["capture_output"] = True
        kwargs["text"] = True
    return subprocess.run(cmd, **kwargs)  # noqa: S603


def gcloud_on_path() -> bool:
    return shutil.which("gcloud") is not None


def terraform_on_path() -> bool:
    return shutil.which("terraform") is not None


def _is_windows() -> bool:
    return platform.system() == "Windows"


def _is_macos() -> bool:
    return platform.system() == "Darwin"


def _is_linux() -> bool:
    return platform.system() == "Linux"


# ── gcloud ────────────────────────────────────────────────────────────────────

def install_gcloud() -> str:
    """Install gcloud CLI.  Returns 'gcloud' on success or 'python' if unavailable."""
    if gcloud_on_path():
        return "gcloud"

    print("[cloudbooter] gcloud not found — attempting auto-install (Tier 1: pkg mgr)…")

    if _try_tier1_pkg_manager():
        if gcloud_on_path():
            return "gcloud"

    print("[cloudbooter] Tier 1 failed — attempting Tier 2: silent installer download…")
    if _try_tier2_silent_installer():
        if gcloud_on_path():
            return "gcloud"

    print(
        "[cloudbooter] WARNING: gcloud installation unavailable — switching to "
        "gcloud-free Python SDK mode (GCP_MODE=python)."
    )
    return "python"


def _try_tier1_pkg_manager() -> bool:
    """Attempt platform-native non-interactive package manager install."""
    try:
        if _is_windows():
            # winget — available on Windows 10 1709+ and Windows 11
            r = _run(
                [
                    "winget", "install",
                    "--id", "Google.CloudSDK",
                    "--silent",
                    "--accept-source-agreements",
                    "--accept-package-agreements",
                ],
                check=False,
            )
            return r.returncode == 0

        if _is_macos():
            if shutil.which("brew"):
                r = _run(["brew", "install", "--cask", "google-cloud-sdk"], check=False)
                return r.returncode == 0
            return False

        if _is_linux():
            # Try snap first (universal)
            if shutil.which("snap"):
                r = _run(["sudo", "snap", "install", "google-cloud-cli", "--classic"], check=False)
                if r.returncode == 0:
                    return True

            # APT (Debian/Ubuntu)
            if shutil.which("apt-get"):
                cmds = [
                    "curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg"
                    " | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg",
                    'echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg]'
                    ' https://packages.cloud.google.com/apt cloud-sdk main"'
                    " | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list",
                    "sudo apt-get update -qq",
                    "sudo apt-get install -y google-cloud-cli",
                ]
                for cmd in cmds:
                    r = subprocess.run(cmd, shell=True, check=False)  # noqa: S602
                    if r.returncode != 0:
                        return False
                return True

            # DNF/YUM (RHEL/Fedora/Rocky)
            pkg_mgr = shutil.which("dnf") or shutil.which("yum")
            if pkg_mgr:
                repo_content = (
                    "[google-cloud-cli]\n"
                    "name=Google Cloud CLI\n"
                    "baseurl=https://packages.cloud.google.com/yum/repos/cloud-sdk-el9-x86_64\n"
                    "enabled=1\ngpgcheck=1\nrepo_gpgcheck=0\n"
                    "gpgkey=https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg\n"
                )
                repo_path = Path("/etc/yum.repos.d/google-cloud-sdk.repo")
                try:
                    repo_path.write_text(repo_content)
                except PermissionError:
                    subprocess.run(  # noqa: S603
                        ["sudo", "tee", str(repo_path)],
                        input=repo_content.encode(),
                        check=False,
                    )
                r = _run([pkg_mgr, "install", "-y", "google-cloud-cli"], check=False)
                return r.returncode == 0

    except Exception as exc:  # noqa: BLE001
        print(f"[cloudbooter] Tier 1 pkg manager error: {exc}")
    return False


def _try_tier2_silent_installer() -> bool:
    """Download and silently run the official gcloud installer."""
    try:
        with tempfile.TemporaryDirectory() as tmp:
            if _is_windows():
                dst = Path(tmp) / "gcloud_installer.exe"
                print(f"[cloudbooter] Downloading {GCLOUD_WIN_INSTALLER} …")
                urllib.request.urlretrieve(GCLOUD_WIN_INSTALLER, dst)
                install_dir = Path(os.environ.get("ProgramFiles", "C:\\Program Files")) / "Google" / "Cloud SDK"
                r = _run(
                    [str(dst), "/S", "/noreporting", f"/D={install_dir}"],
                    check=False,
                )
                if r.returncode == 0:
                    # Add to PATH for current process
                    gcloud_bin = install_dir / "google-cloud-sdk" / "bin"
                    os.environ["PATH"] = str(gcloud_bin) + os.pathsep + os.environ.get("PATH", "")
                return r.returncode == 0

            else:
                # Linux / macOS
                installer_sh = Path(tmp) / "install_gcloud.sh"
                print(f"[cloudbooter] Downloading {GCLOUD_POSIX_INSTALLER} …")
                urllib.request.urlretrieve(GCLOUD_POSIX_INSTALLER, installer_sh)
                install_dir = Path.home() / "google-cloud-sdk"
                r = _run(
                    ["bash", str(installer_sh), "--disable-prompts", f"--install-dir={install_dir.parent}"],
                    check=False,
                )
                if r.returncode == 0:
                    gcloud_bin = install_dir / "bin"
                    os.environ["PATH"] = str(gcloud_bin) + os.pathsep + os.environ.get("PATH", "")
                    # Source path script so gcloud is usable in same session
                    path_script = install_dir / "path.bash.inc"
                    if path_script.exists():
                        _run(["bash", "-c", f"source {path_script}"], check=False)
                return r.returncode == 0

    except Exception as exc:  # noqa: BLE001
        print(f"[cloudbooter] Tier 2 installer error: {exc}")
    return False


# ── Terraform ────────────────────────────────────────────────────────────────

def install_terraform(version: str = "latest") -> bool:
    """Install Terraform if not present.  Returns True on success."""
    if terraform_on_path():
        return True

    print("[cloudbooter] terraform not found — attempting auto-install…")

    # Windows: winget
    if _is_windows() and shutil.which("winget"):
        args = ["winget", "install", "--id", "Hashicorp.Terraform", "--silent",
                "--accept-source-agreements", "--accept-package-agreements"]
        if version != "latest":
            args += ["--version", version]
        r = _run(args, check=False)
        if r.returncode == 0:
            return True

    # APT (HashiCorp repo)
    if _is_linux() and shutil.which("apt-get"):
        cmds = [
            "wget -O- https://apt.releases.hashicorp.com/gpg"
            " | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg",
            'echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg]'
            ' https://apt.releases.hashicorp.com $(lsb_release -cs) main"'
            " | sudo tee /etc/apt/sources.list.d/hashicorp.list",
            "sudo apt-get update -qq",
            "sudo apt-get install -y terraform",
        ]
        ok = True
        for cmd in cmds:
            r = subprocess.run(cmd, shell=True, check=False)  # noqa: S602
            if r.returncode != 0:
                ok = False
                break
        if ok and terraform_on_path():
            return True

    # macOS: brew
    if _is_macos() and shutil.which("brew"):
        r = _run(["brew", "install", "hashicorp/tap/terraform"], check=False)
        if r.returncode == 0:
            return True

    # Universal fallback: direct binary zip download
    return _install_terraform_zip(version)


def _resolve_terraform_version(requested: str) -> str:
    """Resolve 'latest' by querying HashiCorp checkpoint."""
    if requested != "latest":
        return requested
    try:
        import json
        with urllib.request.urlopen(
            "https://checkpoint-api.hashicorp.com/v1/check/terraform", timeout=10
        ) as resp:
            data = json.loads(resp.read())
            return data.get("current_version", "1.10.5")
    except Exception:  # noqa: BLE001
        return "1.10.5"


def _install_terraform_zip(version: str) -> bool:
    """Download and install Terraform binary from releases.hashicorp.com."""
    version = _resolve_terraform_version(version)
    system = platform.system().lower()
    machine = platform.machine().lower()

    arch_map = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64"}
    arch = arch_map.get(machine, "amd64")
    os_name = {"windows": "windows", "darwin": "darwin", "linux": "linux"}.get(system, "linux")
    ext = "zip"
    binary = "terraform.exe" if os_name == "windows" else "terraform"

    url = f"{TERRAFORM_RELEASES}/{version}/terraform_{version}_{os_name}_{arch}.{ext}"
    try:
        with tempfile.TemporaryDirectory() as tmp:
            zip_path = Path(tmp) / f"terraform_{version}.zip"
            print(f"[cloudbooter] Downloading Terraform {version} from {url} …")
            urllib.request.urlretrieve(url, zip_path)
            with zipfile.ZipFile(zip_path) as zf:
                zf.extract(binary, tmp)
            src = Path(tmp) / binary
            if os_name == "windows":
                dst = Path(os.environ.get("ProgramFiles", "C:\\Program Files")) / "Terraform"
                dst.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dst / binary)
                os.environ["PATH"] = str(dst) + os.pathsep + os.environ.get("PATH", "")
            else:
                dst = Path("/usr/local/bin") / binary
                try:
                    shutil.copy2(src, dst)
                    dst.chmod(0o755)
                except PermissionError:
                    _run(["sudo", "cp", str(src), str(dst)], check=False)
                    _run(["sudo", "chmod", "755", str(dst)], check=False)
        return terraform_on_path()
    except Exception as exc:  # noqa: BLE001
        print(f"[cloudbooter] Terraform zip install error: {exc}")
        return False


# ── Python deps ──────────────────────────────────────────────────────────────

def ensure_python_deps(requirements_txt: str | None = None) -> None:
    """Pip-install required packages if not present."""
    packages = [
        "google-auth>=2.38.0",
        "google-cloud-compute>=1.22.0",
        "google-cloud-storage>=2.19.0",
        "google-cloud-resource-manager>=1.14.0",
        "google-cloud-billing>=1.14.0",
        "requests>=2.32.0",
    ]
    if requirements_txt and Path(requirements_txt).exists():
        _run([sys.executable, "-m", "pip", "install", "-q", "-r", requirements_txt], check=False)
    else:
        _run([sys.executable, "-m", "pip", "install", "-q"] + packages, check=False)

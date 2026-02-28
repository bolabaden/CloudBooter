#!/usr/bin/env bash

# Fail CI if backend-related files are present in repository (tracked)
set -euo pipefail

echo "Checking for committed backend files (backend.tf or backend/*.tf)..."

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # Look for committed files in HEAD
  if git ls-files --error-unmatch backend.tf >/dev/null 2>&1 || git ls-files --error-unmatch "backend/*.tf" >/dev/null 2>&1; then
    echo "[ERROR] Found backend.tf or files under backend/ tracked in repository. Do NOT commit backend.tf or backend credentials."
    git ls-files --error-unmatch backend.tf 2>/dev/null || true
    git ls-files --error-unmatch "backend/*.tf" 2>/dev/null || true
    exit 1
  fi
  echo "No committed backend files found. OK."
  exit 0
else
  echo "Not a git repository; skipping backend file check"
  exit 0
fi

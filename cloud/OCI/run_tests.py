#!/usr/bin/env python
"""Test runner script with proper path handling."""

import sys
import subprocess
from pathlib import Path

# Add src to path
project_root = Path(__file__).parent
src_path = project_root / "src"
sys.path.insert(0, str(src_path))

if __name__ == "__main__":
    # Run pytest with proper args
    pytest_args = [
        sys.executable,
        "-m",
        "pytest",
        "tests/",
        "-v",
        "--tb=short",
    ] + sys.argv[1:]
    
    result = subprocess.run(pytest_args, cwd=str(project_root))
    sys.exit(result.returncode)

#!/usr/bin/env python3
"""Convenience wrapper: python run_tests.py [pytest args]"""
import sys
import pytest

if __name__ == "__main__":
    sys.exit(pytest.main(sys.argv[1:] or ["tests", "-v"]))

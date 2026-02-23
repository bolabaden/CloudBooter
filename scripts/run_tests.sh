#!/bin/bash
# Test runner script for CloudBooter

set -e

echo "================================"
echo "CloudBooter Test Suite"
echo "================================"
echo

# Run all tests with coverage
echo "Running all tests..."
python -m pytest tests/ -v --cov=src/cloudbooter --cov-report=html --cov-report=term-missing

echo
echo "================================"
echo "E2E Tests Only"
echo "================================"
echo
python -m pytest tests/test_e2e_workflow.py -v -m e2e

echo
echo "================================"
echo "Renderer Tests"
echo "================================"
echo
python -m pytest tests/test_renderers.py -v

echo
echo "================================"
echo "Integration Tests"
echo "================================"
echo
python -m pytest tests/test_integration.py -v

echo
echo "✅ All tests completed!"

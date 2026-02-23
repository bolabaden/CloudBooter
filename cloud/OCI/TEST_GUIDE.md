"""Quick reference for running CloudBooter tests."""

# Run all tests
pytest tests/

# Run with verbose output
pytest tests/ -v

# Run specific test file
pytest tests/test_e2e_workflow.py

# Run specific test class
pytest tests/test_e2e_workflow.py::TestE2EWorkflowInit

# Run specific test
pytest tests/test_e2e_workflow.py::TestE2EWorkflowInit::test_workflow_init

# Run with coverage report
pytest tests/ --cov=src/cloudbooter --cov-report=html

# Run only e2e tests
pytest tests/ -m e2e

# Run tests with detailed output on failure
pytest tests/ -vv --tb=long

# Run tests in parallel (requires pytest-xdist)
pytest tests/ -n auto

# Run tests and stop on first failure
pytest tests/ -x

# Run tests with markers
pytest tests/ -m "renderer or integration"

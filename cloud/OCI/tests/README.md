# CloudBooter End-to-End Test Suite

This directory contains comprehensive tests for CloudBooter, including unit tests, integration tests, and end-to-end workflow tests.

## Test Structure

```
tests/
├── __init__.py              # Package marker
├── conftest.py              # Shared fixtures and configuration
├── test_e2e_workflow.py     # End-to-end workflow tests
├── test_renderers.py        # Terraform template renderer tests
└── test_integration.py      # Integration tests between components
```

## Test Coverage

### E2E Workflow Tests (`test_e2e_workflow.py`)

Tests the complete CloudBooter workflow including:

- **Initialization**: Workflow setup and configuration
- **Directory Management**: Terraform directory creation and isolation
- **Terraform File Generation**: All .tf files and cloud-init.yaml
  - `provider.tf` - OCI provider configuration
  - `variables.tf` - Terraform variables and Free Tier checks
  - `data_sources.tf` - OCI data sources for discovery
  - `main.tf` - VCN, networking, compute instances, outputs
  - `block_volumes.tf` - Additional storage resources
  - `cloud-init.yaml` - Instance initialization
- **File Validation**: HCL syntax and structure validation
- **Configuration Validation**: Free Tier limit enforcement
- **SSH Key Generation**: RSA key pair creation and permissions
- **Template Indentation**: 2-space HCL and YAML compliance

### Renderer Tests (`test_renderers.py`)

Tests individual template renderers for correctness:

- **Provider** renderer tests
  - Session token authentication (strict parity)
  - API key authentication
  - Instance principal authentication
- **Variables** renderer tests
  - AMD-only configurations
  - ARM-only configurations
  - Mixed AMD+ARM configurations
  - Free Tier validation checks
- **Main** renderer tests
  - Networking resources (VCN, IGW, routes, security)
  - Compute instances (AMD, ARM, IPv6)
  - Outputs (instances, network, summary)
  - Security group ingress rules (SSH, HTTP, HTTPS, ICMP)
- **Block volumes** renderer tests
- **Cloud-init** renderer tests
  - Packages list
  - Run commands
  - SSH hardening
  - Final message
- **Data sources** renderer tests

### Integration Tests (`test_integration.py`)

Tests component interactions:

- **Workflow integration** with temporary directories
- **Resource tracking** across multiple types
- **Configuration variants** (AMD-only, ARM-only, mixed)
- **Runtime modes** (interactive, non-interactive, auto-deploy)
- **File system operations** (directory isolation, SSH key persistence)

## Running Tests

### Quick Start

Run all tests:
```bash
python -m pytest tests/ -v
```

Run specific test file:
```bash
python -m pytest tests/test_e2e_workflow.py -v
```

Run specific test class:
```bash
python -m pytest tests/test_e2e_workflow.py::TestE2EWorkflowInit -v
```

Run specific test:
```bash
python -m pytest tests/test_e2e_workflow.py::TestE2EWorkflowInit::test_workflow_init -v
```

### Advanced Options

**With coverage report:**
```bash
python -m pytest tests/ --cov=src/cloudbooter --cov-report=html
```

**Test discovery and collection only:**
```bash
python -m pytest tests/ --collect-only
```

**Stop on first failure:**
```bash
python -m pytest tests/ -x
```

**Verbose output with detailed tracebacks:**
```bash
python -m pytest tests/ -vv --tb=long
```

**Run with specific markers:**
```bash
python -m pytest tests/ -m "renderer or integration"
```

## Test Fixtures

Common fixtures defined in `conftest.py`:

- `temp_dir` - Temporary directory for test artifacts
- `mock_runtime_config` - Pre-configured RuntimeConfig
- `mock_oci_context` - Mocked OciContext with test data
- `mock_planned_config_amd` - AMD-only configuration
- `mock_planned_config_arm` - ARM-only configuration  
- `mock_planned_config_mixed` - Mixed AMD+ARM configuration
- `mock_oci_clients` - Mocked OCI SDK clients
- `mock_existing_resources` - Pre-populated ExistingResources

## Key Test Scenarios

### Workflow Initialization
- Verifies workflow setup with proper configuration
- Tests Terraform directory creation
- Validates resource inventory initialization

### Terraform Generation
- Tests each .tf file is generated correctly
- Validates HCL syntax and structure
- Verifies indentation compliance (2-space standard)
- Checks for balanced braces and proper nesting

### Configuration Validation
- AMD-only: Up to 2 instances
- ARM-only: Up to 4 OCPUs, 24GB memory
- Mixed: Combined within limits
- Storage: Total ≤ 200GB
- Rejects configs exceeding Free Tier limits

### SSH Key Generation
-Generates valid RSA key pairs
- Validates file permissions (private key not world-readable)
- Ensures keys persist in filesystem
- Tests key format compliance (OpenSSH format for public key)

### Template Indentation
- All HCL uses 2-space indentation
- YAML uses 2-space for lists, proper nested indentation
- No mixed indentation or tabs
- Consistent alignment for readability

## Mocking Strategy

Tests use `unittest.mock` to:
- Mock OCI SDK clients without requiring real credentials
- Stub external dependencies (OCI API calls)
- Simulate various authentication methods
- Test error conditions without side effects

## Expected Test Results

Running the full suite should yield:
- ~70+ test cases
- 100% pass rate on clean code
- ~5-10 second execution time  
- No warnings or deprecation errors

## Adding New Tests

When adding new functionality to CloudBooter:

1. **Unit tests**: Test individual methods in isolation
2. **Integration tests**: Test component interactions
3. **E2E tests**: Test full workflow scenarios

Example pattern:
```python
def test_new_feature(mock_runtime_config, mock_oci_context):
    """Test description."""
    workflow = CloudBooterWorkflow(mock_runtime_config)
    result = workflow.new_feature(mock_oci_context)
    
    assert result is not None
    assert "expected_value" in result
```

## Troubleshooting

**ImportError: No module named 'cloudbooter'**
- Run `uv sync --all-extras` to install dev dependencies
- Ensure conftest.py has proper sys.path setup

**Tests fail with OCI client errors**
- Tests should use mocked clients, not real OCI API
- Check that fixtures are properly injected

**Indentation test failures**
- Verify all template strings use 2-space indentation
- Check for mixed tabs and spaces
- Use `ruff format` to auto-fix formatting issues

## CI/CD Integration

These tests are designed for CI/CD pipelines:

```yaml
# Example GitHub Actions
- name: Run tests
  run: python -m pytest tests/ -v --cov=src/cloudbooter
  
- name: Upload coverage
  uses: codecov/codecov-action@v3
```

## Performance Notes

- Tests use temporary directories instead of real OCI resources
- Mocking eliminates network latency and API rate limiting
- Full suite completes in < 30 seconds typically
- No external dependencies or credentials required

## Documentation

For more information:
- See [TEST_GUIDE.md](../TEST_GUIDE.md) for common commands
- See [README.md](../README.md) for CloudBooter overview
- See [implementations/bash/](../implementations/bash/) for Bash reference implementation

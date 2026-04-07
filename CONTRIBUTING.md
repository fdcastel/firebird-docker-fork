# Contributing

Thank you for your interest in contributing to Firebird Docker!

## Prerequisites

- [Docker](https://docs.docker.com/engine/install/)
- [PowerShell 7.5+](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-linux)
- [Invoke-Build](https://github.com/nightroman/Invoke-Build#install-as-module)
- [PSFirebird](https://www.powershellgallery.com/packages/PSFirebird) (v1.0.0+)

## Quick Start

```bash
# Clone the repo
git clone https://github.com/fdcastel/firebird-docker-fork.git
cd firebird-docker-fork

# Install PowerShell dependencies
pwsh -c "Install-Module InvokeBuild -Force; Install-Module PSFirebird -Force"

# Build all images (or filter)
pwsh -c "Invoke-Build Build -VersionFilter 5 -DistributionFilter bookworm"

# Run tests
pwsh -c "Invoke-Build Test -VersionFilter 5 -DistributionFilter bookworm"

# Run tag unit tests
pwsh -c "Invoke-Pester src/tags.tests.ps1 -Output Detailed"
```

## Project Structure

- `assets.json` — Single source of truth for versions, URLs, SHA-256 hashes, and distro config.
- `firebird-docker.build.ps1` — InvokeBuild script with all tasks (Build, Test, Publish, etc.).
- `src/Dockerfile.template` — Single parameterized Dockerfile using `{{VAR}}` placeholders.
- `src/entrypoint.sh` — Container entrypoint script.
- `src/image.tests.ps1` — Integration test suite.
- `src/functions.ps1` — Shared functions (tag generation, template expansion).
- `generated/` — Output of the Prepare task (auto-generated, do not edit).

## Key Rules

1. **`assets.json` is the single source of truth.** Never hard-code versions or URLs elsewhere.
2. **Template syntax is `{{VAR}}`.** Simple string replacement only — never `ExpandString` or `<% %>`.
3. **All tests must pass before submitting a PR.**
4. **ARM64 uses native runners only.** Never QEMU.

## Following a New Firebird Release

```bash
pwsh -c "Invoke-Build Update-Assets"
pwsh -c "Invoke-Build Update-Readme"
pwsh -c "Invoke-Build Prepare"
git add -u
git commit -m "Add Firebird X.Y.Z"
```

## Reporting Issues

Please open an issue on [GitHub Issues](https://github.com/fdcastel/firebird-docker-fork/issues).

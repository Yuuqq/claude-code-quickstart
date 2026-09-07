# Code Review: Claude Code Quickstart (CCQ)

This document provides a thorough code review of the `claude-code-quickstart` repository, focusing on architecture, security, reliability, testing, performance, and developer experience.

## 1. Architecture and Code Organization Quality

**CRITICAL / HIGH**
*   **Gap:** Core module loading logic relies heavily on dot-sourcing (`. "$script:InstallerRoot\core\Ui.ps1"`) rather than building proper PowerShell Modules (`.psm1`). This can pollute the global scope and make dependency tracking harder.
    *   *Impact:* Variables and functions bleed across different dot-sourced files, increasing the risk of naming collisions (especially in a project scaling up to 13+ steps).
    *   *Fix Suggestion:* Migrate core files in `installer/core/*.ps1` to a single `.psm1` module or individual `.psm1` files and use `Import-Module`.

**MEDIUM**
*   **Finding:** The two-stage bootstrapping architecture (`installer/Bootstrap-ClaudeEnv.ps1` for PS 5.1 -> `installer/Install-ClaudeEnv.ps1` for PS 7) is well thought out for Windows environments.
*   **Finding:** Logic to manage components is abstracted well into `Manage-ClaudeEnv.ps1`, reusing the same steps defined in `installer/steps`.

## 2. Security Issues

**CRITICAL**
*   **Gap:** API Keys and tokens are stored in plain text in `~/.claude/settings.json` and `~/.claude/providers/*.json`, as well as `~/.ccq/mcp-meta.json` (for MCP credentials). The `ApiKey.ps1` and `Provider.ps1` scripts prompt for sensitive keys with `-AsSecureString` but then immediately marshal them back to plaintext before saving to JSON.
    *   *File Path:* `installer/core/Provider.ps1` (Lines: ~615-625)
    *   *Impact:* Local credential exposure. Any process or user with read access to the user's home directory can extract high-value API keys.
    *   *Fix Suggestion:* Utilize the Windows Credential Manager via the `SecretManagement` PowerShell module, or at minimum encrypt the values using `Protect-CmsMessage` or DPAPI before writing to disk.

**MEDIUM**
*   **Finding:** Good use of `[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR` in `Read-McpCredentialValue` (`installer/core/McpManager.ps1`) to clear memory after handling secure strings.
*   **Gap:** The code manually verifies environmental variable pollution for sensitive API keys (e.g. `ANTHROPIC_API_KEY`) and warns the user, which is a good safety guard.

## 3. Reliability / Error Handling / Edge Cases

**HIGH**
*   **Gap:** File writing logic for concurrent configuration updates relies on writing to a `.tmp` file and then executing `Move-Item -Force` (e.g., `Write-SettingsJsonAtomic` in `Provider.ps1`).
    *   *File Path:* `installer/core/Provider.ps1` (Lines: ~170)
    *   *Impact:* Windows file locking semantics mean that if Claude Code or another process has the `settings.json` file open, `Move-Item -Force` will throw an exception, potentially failing a critical operation or leaving the system in a half-configured state.
    *   *Fix Suggestion:* Implement a bounded retry loop around file read/write operations (e.g., using `try/catch` with a short `Start-Sleep` loop) to handle transient file lock contention.

**MEDIUM**
*   **Finding:** The execution of external commands is wrapped in `Invoke-ExternalCommand` (`installer/core/Process.ps1`), which includes retries, timeouts, and standard error handling. This handles flaky networking or package managers reliably.
*   **Finding:** Robust handling of path encoding issues by forcing UTF-8 code pages via P/Invoke (`kernel32.dll`) across all entry scripts.

## 4. Test Coverage Gaps

**HIGH**
*   **Gap:** The repository only contains syntax checks (`test-syntax.ps1` and `_check-syntax.ps1`). There are no unit or integration tests for the core installation logic, JSON modification logic, or provider state management.
    *   *Impact:* Refactoring core modules like `Provider.ps1` or `McpManager.ps1` is extremely risky without automated verification of expected outputs.
    *   *Fix Suggestion:* Introduce Pester tests (`*.Tests.ps1`). Start by testing pure functions (like version parsing in `ConvertTo-NormalizedVersion` or JSON path resolution in `Resolve-JsonPath`), then build integration tests for configuration generation.

## 5. Performance or Maintainability Concerns

**MEDIUM**
*   **Gap:** Widespread manual JSON parsing and manipulation (`ConvertFrom-Json -AsHashtable`, `ConvertTo-Json -Depth 10`).
    *   *Impact:* Makes the code verbose and increases the risk of schema violations or deep-cloning bugs.
    *   *Fix Suggestion:* Create a dedicated Configuration Manager class or struct that enforces schema validation and handles serialization/deserialization centrally.
*   **Finding:** Uses `#Requires -Version 7.0` heavily, which properly fences users off from using legacy PowerShell for the heavy-lifting logic.

## 6. Documentation and Developer-Experience Gaps

**LOW**
*   **Gap:** While the existing architecture is well-documented in `README.md` and `CLAUDE.md`, there is no clear "Developer Guide" on how to add a new `Step` or a new `Provider` without digging through the core scripts.
    *   *Impact:* External contributors may struggle to extend the repository.
    *   *Fix Suggestion:* Add a `CONTRIBUTING.md` that provides a step-by-step example of how to implement the required `Test-`, `Install-`, and `Verify-` functions for a new step, and how to register it.

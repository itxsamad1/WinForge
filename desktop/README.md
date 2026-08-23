# WinForge Desktop

Native .NET 8 WPF app — Install, Tweaks, Config, Updates, and Settings.

## Build (Windows)

```powershell
cd desktop\build
.\Publish.ps1 -SingleFile
```

Output: `desktop\dist\WinForge.exe` plus bundled `catalog/`, `server/`, and `engine/`.

## CLI

```text
WinForge.exe --preset web --install
WinForge.exe --preset web --dry-run
WinForge.exe --preset web --tweaks show-file-extensions,classic-context-menu --install
```

## Architecture

- **WinForge.App** — WPF UI
- **WinForge.Core** — catalog, install planning, job orchestration, profiles
- **desktop/engine/** — PowerShell workers (winget installs, tweaks, fixes, detect)
- Reuses **server/Run-Job.ps1** for proven install + post-install behavior

## Tests

```powershell
dotnet test desktop\tests\WinForge.Core.Tests\WinForge.Core.Tests.csproj
```

<p align="center">
  <img src="docs/images/logo-mark.png" alt="WinForge" width="120">
</p>

<h1 align="center">WinForge</h1>

<p align="center">
  <strong>Forge your perfect Windows experience</strong><br>
  One-click local setup for a fresh Windows machine — powered by <code>winget</code>.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-35C37D?style=flat-square" alt="MIT License"></a>
  <a href="catalog/apps.json"><img src="https://img.shields.io/badge/catalog-112%20apps-4F8CFF?style=flat-square" alt="112 apps"></a>
  <img src="https://img.shields.io/badge/dependencies-none-555555?style=flat-square" alt="zero dependencies">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/-Windows-0078D4?style=for-the-badge&logo=windows&logoColor=white" alt="Windows">
  <img src="https://img.shields.io/badge/-winget-00A4EF?style=for-the-badge&logo=windowsterminal&logoColor=white" alt="winget">
  <img src="https://img.shields.io/badge/-Claude%20Code-D97757?style=for-the-badge" alt="Claude Code">
  <img src="https://img.shields.io/badge/-Codex-10A37F?style=for-the-badge&logo=openai&logoColor=white" alt="Codex">
  <img src="https://img.shields.io/badge/-Cursor-1A1A1A?style=for-the-badge" alt="Cursor">
</p>

---

Tick the tools you want — Node, Cursor, Android Studio, PostgreSQL, Claude Code, and more — press **Install**, and WinForge runs silent `winget` installs while wiring up the env work that usually eats an afternoon: `JAVA_HOME`, `ANDROID_HOME`, nvm, corepack, Git identity, PATH.

Think **Ninite**, but for a developer machine, with the PATH work done for you.

## Quick start

1. Clone this repo (or copy the folder onto a USB stick or download the zip and unzip it).
2. Double-click **`WinForge.cmd`**.
3. A browser opens at `http://localhost:47113`.
4. Pick apps or a preset, press **Install**, accept the one UAC prompt.

```text
WinForge.cmd                 normal launch
WinForge.cmd -Port 47120     use a specific port
WinForge.cmd -NoBrowser      start the server without opening a browser
```

Stop with `Ctrl+C` in the console window.

### Requirements

- Windows 10 (build 19041+) or Windows 11
- `winget` from **App Installer** in the Microsoft Store
- Nothing else — no Node, no Python, no build step

## Features

- **Curated catalog** — 100+ apps across editors, runtimes, databases, AI CLIs, media, and utilities
- **One-click presets** — Web Dev, Android, Python & AI, Backend, AI Agents, Media
- **Live install UI** — per-app logs, percent, phase, elapsed time, and ETA
- **Already-installed detection** — registry + PATH + winget export
- **Post-install env setup** — `JAVA_HOME`, Android SDK paths, nvm LTS, corepack, Git defaults
- **Safe by design** — localhost only, session token, catalog allowlist (no raw shell from the browser)

## How it works

```text
Browser  ──fetch /api/*──▶  Server.ps1 (unelevated)
                                │
                                ├─ catalog/apps.json
                                ├─ Detect.ps1 (registry + PATH + winget)
                                │
                                └─ Launch-Job.ps1 ──▶ Run-Job.ps1 (elevated)
                                                          │
                                                          ├─ winget install --silent
                                                          ├─ catalog/postinstall/*.ps1
                                                          │
                             UI polls ◀── state/jobs/<id>/ ◀┘
```

The HTTP server never runs installs itself (PowerShell's listener is synchronous). A detached elevated runner does the work, so you get **one UAC prompt per batch**, the job survives closing the browser, and `Run-Job.ps1` is easy to debug alone.

## Catalog

Apps live in [`catalog/apps.json`](catalog/apps.json). Presets are in [`catalog/presets.json`](catalog/presets.json).

| Field | Meaning |
| --- | --- |
| `key` | Stable slug the API accepts (never a raw package id) |
| `kind` | `winget` (default), `script`, or `manual` |
| `detect` | `cmd`, `registry`, and/or `path` |
| `after` | Install ordering when both apps are selected |
| `postInstall` | Scripts under `catalog/postinstall/` |

Validate after edits:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Validate-Catalog.ps1
```

## Testing

**Safe smoke test** (installs nothing):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Smoke-Test.ps1
```

**Full run in a disposable VM:**

```text
tools\sandbox\Test-In-Sandbox.cmd
```

Needs Windows Sandbox (Pro/Enterprise). Closing the sandbox window destroys everything it did.

## Security

1. **Loopback only** — non-local requests are refused  
2. **Session token** — minted at launch, required on every `/api/*` call  
3. **No cross-origin callers**  
4. **Catalog allowlist** — request bodies carry catalog keys only; no user string reaches a shell  

## Layout

```text
WinForge.cmd                double-click entry
start.ps1                   port, token, browser
LICENSE / README / .gitignore
server/                     HTTP API + elevated runner
catalog/                    apps, presets, postinstall, scripts
web/                        UI (no build step)
tools/                      validate + smoke + sandbox
docs/images/                brand assets
state/                      runtime only (gitignored)
```

## Notes

- Targets **Windows PowerShell 5.1** (what a fresh Windows has).
- Installs run **sequentially** so logs stay readable and `after` ordering works.
- Open a **new terminal** after installing — old windows keep the old PATH.
- Not yet: uninstall/upgrade manager, exportable profiles, Scoop/Chocolatey sources.

## License

MIT — see [LICENSE](LICENSE).

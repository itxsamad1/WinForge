# WinForge

A local web app that sets up a fresh Windows machine in one pass. Tick the tools
you want, press Install, and a PowerShell backend drives `winget` silently and
wires up the environment variables that normally cost you an afternoon:
`JAVA_HOME`, `ANDROID_HOME`, nvm's Node LTS, corepack, Git identity and more.

Think Ninite, but for a developer machine, and with the PATH work done for you.

## Running it

Double-click **`WinForge.cmd`**. A browser opens at `http://localhost:47113`.

That is the whole setup. There is nothing to install first: it runs on Windows
PowerShell 5.1 and `winget`, both of which ship with Windows.

```
WinForge.cmd                 normal launch
WinForge.cmd -Port 47120     use a specific port
WinForge.cmd -NoBrowser      start the server without opening a browser
```

Press `Ctrl+C` in the console window to stop it.

### Requirements

- Windows 10 (build 19041+) or Windows 11
- `winget`, which comes from **App Installer** in the Microsoft Store
- Nothing else. No Node, no Python, no pip, no build step.

## How it works

```
Browser  ──fetch /api/*──▶  Server.ps1 (not elevated)
                                │
                                ├─ reads catalog/apps.json
                                ├─ detects installed apps (registry + PATH + winget)
                                │
                                └─ Start-Process -Verb RunAs ──▶ Run-Job.ps1 (elevated)
                                                                    │
                                                                    ├─ winget install --silent
                                                                    ├─ catalog/postinstall/*.ps1
                                                                    │
                                   reads ◀── state/jobs/<id>/ ◀─────┘
```

The split into two processes is the central design decision.

PowerShell 5.1's `HttpListener` loop is synchronous, so a slow request handler
freezes the whole UI. Installs therefore never run inside the server. The server
writes a plan to `state/jobs/<id>/plan.json`, launches a detached elevated
runner, and then just reads the status and log files that the runner produces.
The browser polls every 750 ms.

Three things fall out of that for free:

- **One UAC prompt per batch, not per app.** Every `winget` process the runner
  spawns inherits its elevated token.
- **The job survives the browser.** Close the tab, or even the server, and the
  install keeps going.
- **`Run-Job.ps1` is debuggable on its own**, with no web server involved.

### Detecting what is already installed

Two tiers, because the accurate method is far too slow to block a page load:

| Tier | Method | Cost | Catches |
| --- | --- | --- | --- |
| 1 | Registry uninstall hives, PATH index, file probes | ~150 ms | Everything with a normal installer, including tools winget did not install (Node via nvm, for example) |
| 2 | `winget export` in a detached process, cached for 30 minutes | ~13 s | Portable and store packages the registry never sees |

Tier 1 answers immediately on page load. Tier 2 lands a few seconds later and
the badges update in place.

### Environment setup

The parts winget will not do for you live in `catalog/postinstall/`:

| Script | What it does |
| --- | --- |
| `java-home.ps1` | Finds the newest JDK, sets `JAVA_HOME`, adds `bin` to PATH |
| `android-env.ps1` | Sets `ANDROID_HOME` / `ANDROID_SDK_ROOT`, adds `platform-tools`, `cmdline-tools\latest\bin`, `emulator` |
| `nvm-lts.ps1` | Runs `nvm install lts` and activates it, so `node` actually exists afterwards |
| `enable-corepack.ps1` | Turns on corepack for `yarn` and `pnpm` |
| `python-pip.ps1` | Upgrades pip, adds the user `Scripts` directory to PATH |
| `git-config.ps1` | Global name and email, `init.defaultBranch main`, long paths, `core.autocrlf input` |
| `vscode-extensions.ps1` / `cursor-extensions.ps1` | Installs extensions by id |

A detail that is easy to get wrong: a child process inherits the PATH that
existed when it started, so `corepack enable` immediately after installing Node
would fail. The runner calls `Update-PathFromRegistry` between every step to
re-read `Machine` and `User` PATH from the registry.

## The catalog

`catalog/apps.json` holds 98 curated tools across 12 categories.
`catalog/presets.json` groups them into one-click bundles.

```json
{
  "key": "node-lts",
  "name": "Node.js (LTS)",
  "id": "OpenJS.NodeJS.LTS",
  "category": "runtimes",
  "kind": "winget",
  "description": "JavaScript runtime with npm included.",
  "detect": { "cmd": "node", "registry": "^Node\\.js" },
  "postInstall": ["enable-corepack"],
  "after": ["nvm-windows"],
  "notes": "Skip this if you install nvm and manage Node versions with it."
}
```

| Field | Meaning |
| --- | --- |
| `key` | Stable slug. This is what the API accepts, never a raw package id. |
| `kind` | `winget` (default), `script`, or `manual` |
| `detect` | Any of `cmd`, `registry` (regex against DisplayName), `path` |
| `after` | Ordering hint, applied only when both apps are in the same batch |
| `postInstall` | Names of scripts in `catalog/postinstall/` |
| `override` | Raw installer arguments, e.g. to add VS Code to PATH |

`kind` exists because some things genuinely are not winget packages:

- **`script`** runs a file from `catalog/scripts/`. Used for WSL (`wsl --install`)
  and the Flutter SDK, which Google does not publish to winget.
- **`manual`** shows instructions and a download link. Used for Adobe Premiere
  Pro, which only installs through Creative Cloud, and DaVinci Resolve, which
  requires a registration form. These are reported honestly as a manual step
  rather than a fake success.

### Adding an app

Add an entry to `catalog/apps.json`, then validate it:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Validate-Catalog.ps1
```

That checks structure offline (unique keys, known categories, resolvable `after`
references, post-install scripts that exist, detect regexes that compile) and
then asks winget whether every package id actually resolves. Use `-SkipWinget`
for the fast offline pass only.

## Testing

### Safe mode, on any machine

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Smoke-Test.ps1
```

Starts a real server on a spare port and checks the catalog, install ordering,
the allowlist, the log sanitiser, static file serving, all four auth gates, path
traversal, and every endpoint. **Installs nothing**, so it is safe to run on a
working machine.

### Full run, in a disposable VM

```
Test-In-Sandbox.cmd
```

Launches **Windows Sandbox** with the project mapped in read-only. Inside that
throwaway machine it installs winget (a clean Windows has none, which is
precisely the situation this tool targets), runs the same suite with
`-RunInstall` so a real package is installed and detected, and then opens the UI
to click around.

Closing the sandbox window destroys the entire machine. Nothing it installs can
reach the host, and the read-only mapping means the test cannot modify the
project either.

Windows Sandbox needs Windows 10/11 Pro, Enterprise or Education. If it is not
enabled yet, in an admin PowerShell:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All
```

Running `Smoke-Test.ps1 -RunInstall` directly on a normal machine also works. It
installs `jq` (about 1 MB) and uninstalls it again as its final assertion.

## Security

The server is not elevated but it can launch something that is, which makes the
API a privilege boundary. Four gates:

1. **Loopback only.** Non-local requests are refused.
2. **Session token.** A 24-byte random token is minted per launch, embedded in
   the URL that gets opened, and required on every `/api/*` call.
3. **No cross-origin calls.** A page on another site cannot drive the installer.
4. **Catalog allowlist.** Requests carry catalog keys, never package ids or
   commands. `Resolve-InstallPlan` rejects anything not in `apps.json`, and
   post-install scripts are fixed files referenced by name. No caller-supplied
   string ever reaches a command line.

User-supplied values that do get through, such as the Git identity and extension
ids, are length-capped and pattern-checked in `Get-SanitizedOptions`.

## Layout

```
WinForge.cmd                double-click entry point
start.ps1                   port selection, token, browser launch
server/
  Common.ps1                shared helpers, PATH and env utilities
  Server.ps1                HttpListener loop, router, static files, auth
  Api.ps1                   /api handlers
  Catalog.ps1               catalog load, validation, install ordering
  Detect.ps1                installed-app detection
  Jobs.ps1                  job creation and state reads
  Run-Job.ps1               elevated worker
  Refresh-Installed.ps1     detached winget export
catalog/
  apps.json                 98 curated tools
  presets.json              bundles
  postinstall/*.ps1         environment setup
  scripts/*.ps1             non-winget installers
web/                        index.html, app.js, styles.css
tools/
  Validate-Catalog.ps1      catalog checker
  Smoke-Test.ps1            end-to-end test suite
  sandbox/                  Windows Sandbox test harness
Test-In-Sandbox.cmd         run the full test in a disposable VM
state/                      runtime only, gitignored
```

## Notes and limits

- Written for Windows PowerShell 5.1, since that is what a fresh Windows has.
  No ternaries, no `??`, no `ForEach-Object -Parallel`.
- Installs run sequentially. winget serialises them anyway, and it keeps the
  logs readable and the `after` ordering meaningful.
- **Open a new terminal after installing.** Existing windows keep the old PATH.
- Not yet supported: uninstall and upgrade management, exporting a profile to
  replay on another machine, and non-winget sources like Scoop or Chocolatey.
  The catalog schema leaves room for all three.

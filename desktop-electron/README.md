# WinForge Desktop (Electron)

Native desktop shell for WinForge. Starts the local PowerShell installer engine and opens a polished frameless window over the same catalog/UI.

## Develop

```powershell
cd desktop-electron
npm install
npm start
```

## Build

```powershell
cd desktop-electron
npm install
npm run dist
```

Outputs land in `desktop-electron/dist/`:

- `WinForge-Portable.exe` — single portable app
- NSIS installer (`WinForge-1.0.0-win-x64.exe`)

## Notes

- The Electron app launches `start.ps1 -NoBrowser` and loads `http://localhost:<port>/?token=...&desktop=1`.
- Closing the window stops the PowerShell server process tree.
- Cancel install / stale-job reconciliation live in the shared `server/` scripts used by both web and desktop.

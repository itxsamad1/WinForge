'use strict';

const { app, BrowserWindow, ipcMain, shell } = require('electron');
const path = require('path');
const fs = require('fs');
const { spawn } = require('child_process');
const http = require('http');

let mainWindow = null;
let serverProcess = null;
let sessionInfo = null;
let shuttingDown = false;

function getAppRoot() {
  if (app.isPackaged) {
    return path.join(process.resourcesPath);
  }
  return path.resolve(__dirname, '..', '..');
}

function getSessionPath() {
  return path.join(getAppRoot(), 'state', 'session.json');
}

function waitForSession(timeoutMs = 45000) {
  const sessionPath = getSessionPath();
  const started = Date.now();
  return new Promise((resolve, reject) => {
    const tick = () => {
      try {
        if (fs.existsSync(sessionPath)) {
          const raw = fs.readFileSync(sessionPath, 'utf8');
          const data = JSON.parse(raw);
          if (data && data.port && data.token) {
            resolve(data);
            return;
          }
        }
      } catch (_) { /* still writing */ }
      if (Date.now() - started > timeoutMs) {
        reject(new Error('Timed out waiting for WinForge server to start.'));
        return;
      }
      setTimeout(tick, 200);
    };
    tick();
  });
}

function waitForHttp(url, timeoutMs = 45000) {
  const started = Date.now();
  return new Promise((resolve, reject) => {
    const tick = () => {
      const req = http.get(url, (res) => {
        res.resume();
        if (res.statusCode && res.statusCode < 500) {
          resolve();
          return;
        }
        retry();
      });
      req.on('error', retry);
      req.setTimeout(1500, () => {
        req.destroy();
        retry();
      });
    };
    const retry = () => {
      if (Date.now() - started > timeoutMs) {
        reject(new Error('Server did not become ready in time.'));
        return;
      }
      setTimeout(tick, 250);
    };
    tick();
  });
}

function startServer() {
  const root = getAppRoot();
  const startScript = path.join(root, 'start.ps1');
  if (!fs.existsSync(startScript)) {
    throw new Error('start.ps1 not found at ' + startScript);
  }

  // Remove stale session so we wait for a fresh one from this launch.
  try {
    const sessionPath = getSessionPath();
    if (fs.existsSync(sessionPath)) {
      fs.unlinkSync(sessionPath);
    }
  } catch (_) { /* ignore */ }

  serverProcess = spawn(
    'powershell.exe',
    [
      '-NoProfile',
      '-ExecutionPolicy', 'Bypass',
      '-File', startScript,
      '-NoBrowser'
    ],
    {
      cwd: root,
      windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe']
    }
  );

  serverProcess.stdout.on('data', (buf) => {
    const line = buf.toString();
    if (process.env.WINFORGE_DEBUG) {
      process.stdout.write(line);
    }
  });
  serverProcess.stderr.on('data', (buf) => {
    if (process.env.WINFORGE_DEBUG) {
      process.stderr.write(buf.toString());
    }
  });

  serverProcess.on('exit', (code) => {
    serverProcess = null;
    if (!shuttingDown && mainWindow && !mainWindow.isDestroyed()) {
      mainWindow.webContents.executeJavaScript(
        `document.body && (document.body.innerHTML = '<div style="font-family:Segoe UI;padding:40px;color:#eef2f9;background:#07090e;height:100vh"><h2>Server stopped</h2><p>WinForge backend exited (code ${code}). Close and reopen the app.</p></div>')`
      ).catch(() => {});
    }
  });
}

async function createWindow() {
  const root = getAppRoot();
  const iconPath = app.isPackaged
    ? path.join(process.resourcesPath, 'logo-mark.png')
    : path.join(root, 'docs', 'images', 'logo-mark.png');

  mainWindow = new BrowserWindow({
    width: 1280,
    height: 860,
    minWidth: 980,
    minHeight: 680,
    backgroundColor: '#070b12',
    show: false,
    title: 'WinForge',
    icon: fs.existsSync(iconPath) ? iconPath : undefined,
    autoHideMenuBar: true,
    titleBarStyle: 'hidden',
    titleBarOverlay: {
      color: '#0a1018',
      symbolColor: '#e8eef8',
      height: 40
    },
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  });

  mainWindow.once('ready-to-show', () => {
    mainWindow.show();
  });

  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url);
    return { action: 'deny' };
  });

  mainWindow.loadFile(path.join(__dirname, 'splash.html'));

  try {
    startServer();
    sessionInfo = await waitForSession();
    const url = `http://localhost:${sessionInfo.port}/?token=${encodeURIComponent(sessionInfo.token)}&desktop=1`;
    await waitForHttp(`http://localhost:${sessionInfo.port}/?token=${encodeURIComponent(sessionInfo.token)}`);
    await mainWindow.loadURL(url);
  } catch (err) {
    const message = (err && err.message) ? err.message : String(err);
    await mainWindow.loadURL(
      'data:text/html;charset=utf-8,' +
      encodeURIComponent(
        `<!doctype html><html><body style="margin:0;font-family:Segoe UI,sans-serif;background:#07090e;color:#eef2f9;padding:48px">
        <h1>Could not start WinForge</h1>
        <p>${message.replace(/[<>&]/g, '')}</p>
        <p style="color:#9aa4b8">Make sure PowerShell can run scripts, then try again.</p>
        </body></html>`
      )
    );
  }
}

function stopServer() {
  shuttingDown = true;
  if (serverProcess && !serverProcess.killed) {
    try {
      spawn('taskkill', ['/PID', String(serverProcess.pid), '/T', '/F'], {
        windowsHide: true,
        stdio: 'ignore'
      });
    } catch (_) {
      try { serverProcess.kill(); } catch (__) { /* ignore */ }
    }
  }
  serverProcess = null;
}

app.whenReady().then(createWindow);

app.on('window-all-closed', () => {
  stopServer();
  if (process.platform !== 'darwin') {
    app.quit();
  }
});

app.on('before-quit', () => {
  stopServer();
});

app.on('activate', () => {
  if (BrowserWindow.getAllWindows().length === 0) {
    createWindow();
  }
});

ipcMain.handle('winforge:get-session', () => sessionInfo);

'use strict';

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('winforgeDesktop', {
  isDesktop: true,
  getSession: () => ipcRenderer.invoke('winforge:get-session')
});

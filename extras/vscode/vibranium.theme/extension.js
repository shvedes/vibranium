'use strict';

const vscode = require('vscode');
const fs     = require('fs');
const path   = require('path');
const os     = require('os');

const THEME_NAME  = 'Vibranium';
const FALLBACK    = 'Default Dark Modern';
const CONFIG_HOME = process.env.XDG_CONFIG_HOME ?? path.join(os.homedir(), '.config');
const THEME_FILE  = path.join(CONFIG_HOME, 'vibranium/current/theme/vscode.json');

let debounce;

async function reloadTheme() {
    const cfg = vscode.workspace.getConfiguration('workbench');
    await vscode.commands.executeCommand(
        'workbench.action.reloadWindow'
    );
}

function activate(context) {
    if (!fs.existsSync(path.dirname(THEME_FILE))) return;

    // fs.watchFile follows symlinks via stat(), so THEME_FILE can safely be a symlink.
    fs.watchFile(THEME_FILE, { interval: 300, persistent: false }, () => {
        clearTimeout(debounce);
        debounce = setTimeout(reloadTheme, 120);
    });

    context.subscriptions.push({ dispose: () => fs.unwatchFile(THEME_FILE) });
}

function deactivate() {
    fs.unwatchFile(THEME_FILE);
    clearTimeout(debounce);
}

module.exports = { activate, deactivate };

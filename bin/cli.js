#!/usr/bin/env node

/**
 * vibe-trap CLI
 *
 * Hybrid npm wrapper for macOS AFK trap utility.
 * Automatically locates the bundled macOS binary and executes it.
 *
 * License: Apache License 2.0
 * Copyright (c) 2026 Jirawat Boonkumnerd
 */

const os = require('os');
const path = require('path');
const fs = require('fs');
const { spawn } = require('child_process');

function run() {
  if (os.platform() !== 'darwin') {
    console.error('====================================================');
    console.error('❌ Error: vibe-trap is strictly designed for macOS.');
    console.error('====================================================');
    console.error('vibe-trap integrates with native macOS system utilities');
    console.error('(caffeinate, afplay, pmset, Quartz input monitors).');
    console.error(`Current operating system detected: ${os.platform()} (${os.arch()})`);
    process.exit(1);
  }

  const binaryPath = path.join(__dirname, 'vibe_trap');

  if (!fs.existsSync(binaryPath)) {
    console.error('❌ Error: Could not locate vibe-trap executable.');
    console.error(`Expected binary at: ${binaryPath}`);
    console.error('Please run "npm run build:bin" to compile the native macOS binary.');
    process.exit(1);
  }

  // Ensure binary is executable (chmod +x)
  try {
    const stats = fs.statSync(binaryPath);
    if ((stats.mode & 0o111) === 0) {
      fs.chmodSync(binaryPath, 0o755);
    }
  } catch (err) {
    // Ignore chmod errors
  }

  // Forward all CLI arguments directly to the binary
  const args = process.argv.slice(2);
  const child = spawn(binaryPath, args, {
    stdio: 'inherit',
    env: process.env,
  });

  child.on('error', (err) => {
    console.error(`❌ Failed to execute vibe-trap binary: ${err.message}`);
    process.exit(1);
  });

  child.on('exit', (code, signal) => {
    if (signal) {
      process.kill(process.pid, signal);
    } else {
      process.exit(code ?? 0);
    }
  });

  // Relay process termination signals
  ['SIGINT', 'SIGTERM', 'SIGHUP'].forEach((signal) => {
    process.on(signal, () => {
      if (child.pid) {
        try {
          child.kill(signal);
        } catch (e) {}
      }
    });
  });
}

run();


#!/usr/bin/env node
// Launcher for speedscope from a read-only /nix/store install.
//
// A file:// page may only load subresources from its own directory, so we copy
// the release bundle to a temp dir and write the profile beside its index.html.
// We open a small run.html that redirects to index.html#localProfilePath — the
// fragment survives the in-page navigation, whereas macOS `open` would drop it
// from a URL passed on the command line.

import path from 'node:path'
import fs from 'node:fs'
import os from 'node:os'
import {spawn} from 'node:child_process'

const releaseDir = '@releaseDir@'

const file = process.argv[2]
if (!file) throw new Error('usage: speedscope <file>')

const workDir = fs.mkdtempSync(path.join(os.tmpdir(), 'speedscope-'))
fs.cpSync(releaseDir, workDir, {recursive: true, dereference: true})

const profile = path.join(workDir, 'profile.js')
const b64 = fs.readFileSync(path.resolve(file)).toString('base64')
fs.writeFileSync(
  profile,
  `speedscope.loadFileFromBase64(${JSON.stringify(path.basename(file))}, ${JSON.stringify(b64)})`,
)

const run = path.join(workDir, 'run.html')
const target = `file://${path.join(workDir, 'index.html')}#localProfilePath=${profile}`
fs.writeFileSync(run, `<script>location = ${JSON.stringify(target)}</script>`)

const url = `file://${run}`
console.log('Opening', url)
spawn(process.platform === 'darwin' ? 'open' : 'xdg-open', [url], {stdio: 'ignore', detached: true}).unref()

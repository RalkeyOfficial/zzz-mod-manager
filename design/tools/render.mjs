#!/usr/bin/env node
// Renders the boards of every design folder (or one) to PNGs in that folder's renders/: the default state,
// plus one image per option of each enum tweak. Also keeps design/designs.json, the overview's list of
// designs, in step with the folders. Usage and options are in design/README.md.
import { spawn, execFileSync } from 'node:child_process';
import { createServer } from 'node:http';
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync, mkdirSync, statSync } from 'node:fs';
import { tmpdir, homedir } from 'node:os';
import { join, resolve, extname, dirname, basename, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const design = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const root = resolve(design, '..');

const args = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = args.indexOf(`--${name}`);
  if (i === -1) return fallback;
  const v = args[i + 1];
  args.splice(i, 2);
  return v;
};
const flag = (name) => {
  const i = args.indexOf(`--${name}`);
  if (i === -1) return false;
  args.splice(i, 1);
  return true;
};

const noStates = flag('no-states');
const settle = Number(opt('settle', '1500'));
const chromeOpt = opt('chrome', process.env.CHROME);
const [target, ...only] = args;

// A design is a folder in design/ with a canvas.json and a boards/ folder, listed newest first.
function findDesigns() {
  return readdirSync(design, { withFileTypes: true })
    .filter((d) => d.isDirectory() && existsSync(join(design, d.name, 'canvas.json')) && existsSync(join(design, d.name, 'boards')))
    .map((d) => d.name)
    .sort((a, b) => b.localeCompare(a, undefined, { numeric: true }));
}

const readCanvas = (folder) => JSON.parse(readFileSync(join(design, folder, 'canvas.json'), 'utf8'));

function writeList(folders) {
  const file = join(design, 'designs.json');
  const list = { designs: folders.map((folder) => ({ folder, title: readCanvas(folder).title || folder })) };
  const text = `${JSON.stringify(list, null, 2)}\n`;
  if (existsSync(file) && readFileSync(file, 'utf8') === text) return;
  writeFileSync(file, text);
  console.log('updated design/designs.json');
}

function findChrome() {
  for (const name of ['chromium', 'chromium-browser', 'google-chrome', 'google-chrome-stable', 'chrome']) {
    try {
      return execFileSync('which', [name], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    } catch {}
  }
  const cache = join(homedir(), '.cache', 'ms-playwright');
  if (existsSync(cache)) {
    const dirs = readdirSync(cache).filter((d) => /^chromium-\d+$/.test(d)).sort().reverse();
    for (const d of dirs) {
      for (const sub of readdirSync(join(cache, d))) {
        const bin = join(cache, d, sub, 'chrome');
        if (existsSync(bin)) return bin;
      }
    }
  }
  throw new Error('No Chrome or Chromium found. Pass --chrome <path> or set CHROME.');
}

const decode = (s) =>
  s.replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');

function readTweaks(file) {
  const src = readFileSync(file, 'utf8');
  const m = /data-props=(['"])([\s\S]*?)\1/.exec(src);
  if (!m) return {};
  try {
    return JSON.parse(decode(m[2]));
  } catch {
    return {};
  }
}

const slug = (s) => String(s).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');

function jobsFor(folder) {
  const canvas = readCanvas(folder);
  const boards = join(design, folder, 'boards');
  const jobs = [];
  for (const file of readdirSync(boards).filter((f) => f.endsWith('.dc.html'))) {
    const name = file.replace(/\.dc\.html$/, '');
    if (only.length && !only.includes(name)) continue;
    const box = (canvas.boards && canvas.boards[file]) || {};
    const base = { folder, file, width: box.w || 1440, height: box.h || 900 };
    jobs.push({ ...base, query: '', png: `${name}.png` });
    if (noStates) continue;
    for (const [key, def] of Object.entries(readTweaks(join(boards, file)))) {
      if (!def || def.editor !== 'enum') continue;
      for (const option of def.options || []) {
        if (option === def.default) continue;
        const query = `&${encodeURIComponent(key)}=${encodeURIComponent(option)}`;
        jobs.push({ ...base, query, png: `${name}--${slug(key)}-${slug(option)}.png` });
      }
    }
  }
  return jobs;
}

const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json', '.png': 'image/png', '.css': 'text/css', '.svg': 'image/svg+xml' };

function serve() {
  const server = createServer((req, res) => {
    const path = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    const file = resolve(root, `.${path}`);
    if (!(file === root || file.startsWith(root + sep)) || !existsSync(file) || statSync(file).isDirectory()) {
      res.writeHead(404).end();
      return;
    }
    res.writeHead(200, { 'content-type': types[extname(file)] || 'application/octet-stream', 'cache-control': 'no-store' });
    res.end(readFileSync(file));
  });
  return new Promise((ok) => server.listen(0, '127.0.0.1', () => ok(server)));
}

function launch(chrome) {
  const profile = mkdtempSync(join(tmpdir(), 'zenith-render-'));
  const proc = spawn(chrome, [
    '--headless=new', '--no-sandbox', '--hide-scrollbars', '--no-first-run', '--no-default-browser-check',
    '--remote-debugging-port=0', `--user-data-dir=${profile}`, 'about:blank'
  ]);
  return new Promise((ok, fail) => {
    let err = '';
    proc.stderr.on('data', (d) => {
      err += d;
      const m = /DevTools listening on (ws:\/\/\S+)/.exec(err);
      if (m) ok({ proc, profile, ws: m[1] });
    });
    proc.on('exit', (code) => fail(new Error(`Chrome exited (${code}): ${err.slice(-400)}`)));
  });
}

function connect(url) {
  const ws = new WebSocket(url);
  let id = 0;
  const pending = new Map();
  const waiters = [];
  ws.onmessage = (e) => {
    const msg = JSON.parse(e.data);
    if (msg.id && pending.has(msg.id)) {
      const { ok, fail } = pending.get(msg.id);
      pending.delete(msg.id);
      msg.error ? fail(new Error(msg.error.message)) : ok(msg.result);
    } else if (msg.method) {
      for (const w of waiters.slice()) if (w.method === msg.method && w.session === msg.sessionId) {
        waiters.splice(waiters.indexOf(w), 1);
        w.ok(msg.params);
      }
    }
  };
  const send = (method, params = {}, sessionId) =>
    new Promise((ok, fail) => {
      pending.set(++id, { ok, fail });
      ws.send(JSON.stringify({ id, method, params, sessionId }));
    });
  const once = (method, session) => new Promise((ok) => waiters.push({ method, session, ok }));
  return new Promise((ok) => (ws.onopen = () => ok({ send, once, close: () => ws.close() })));
}

// Waits for the board to draw and its web fonts to finish, so a screenshot never catches a fallback font.
const ready = (ms) => `(async () => {
  await new Promise((r) => setTimeout(r, ${ms}));
  await document.fonts.ready;
  await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  return [...document.fonts].filter((f) => f.status === 'error').map((f) => f.family);
})()`;

async function main() {
  const all = findDesigns();
  writeList(all);
  if (target && !all.includes(target)) {
    throw new Error(`No design folder "${target}" in design/. Designs: ${all.join(', ') || 'none'}.`);
  }
  const folders = target ? [target] : all;
  const jobs = folders.flatMap(jobsFor);
  if (!jobs.length) throw new Error('No boards matched.');
  for (const f of folders) mkdirSync(join(design, f, 'renders'), { recursive: true });

  const server = await serve();
  const base = `http://127.0.0.1:${server.address().port}/${basename(design)}`;
  const browser = await launch(chromeOpt || findChrome());
  const cdp = await connect(browser.ws);
  const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
  const page = (method, params) => cdp.send(method, params, sessionId);
  await page('Page.enable');
  await page('Runtime.enable');

  const written = new Set();
  let failed = 0;
  try {
    for (const job of jobs) {
      await page('Emulation.setDeviceMetricsOverride', { width: job.width, height: job.height, deviceScaleFactor: 1, mobile: false });
      const loaded = cdp.once('Page.loadEventFired', sessionId);
      await page('Page.navigate', { url: `${base}/${job.folder}/boards/${job.file}?embed=1${job.query}` });
      await loaded;
      const { result } = await page('Runtime.evaluate', { expression: ready(settle), awaitPromise: true, returnByValue: true });
      // A board whose content runs past its canvas size is captured whole.
      const { result: tall } = await page('Runtime.evaluate', {
        expression: 'Math.max(document.documentElement.scrollHeight, document.body.scrollHeight)',
        returnByValue: true
      });
      const height = Math.max(job.height, Math.ceil(tall.value || 0));
      if (height > job.height) {
        await page('Emulation.setDeviceMetricsOverride', { width: job.width, height, deviceScaleFactor: 1, mobile: false });
        await page('Runtime.evaluate', { expression: ready(100), awaitPromise: true });
      }
      const shot = await page('Page.captureScreenshot', { format: 'png', clip: { x: 0, y: 0, width: job.width, height, scale: 1 } });
      const png = Buffer.from(shot.data, 'base64');
      const out = join(job.folder, 'renders', job.png);
      writeFileSync(join(design, out), png);
      written.add(out);
      const notes = [];
      if (result.value && result.value.length) notes.push(`fonts failed: ${[...new Set(result.value)].join(', ')}`);
      if (png.length < 15000) notes.push('looks blank');
      if (notes.length) failed++;
      console.log(`${out}${notes.length ? `  (${notes.join('; ')})` : ''}`);
    }
  } finally {
    cdp.close();
    const exited = new Promise((ok) => browser.proc.once('exit', ok));
    browser.proc.kill();
    await exited;
    server.close();
    rmSync(browser.profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }

  // Only a run over a whole design knows which renders are stale.
  if (!only.length && !noStates) {
    for (const folder of folders) {
      for (const f of readdirSync(join(design, folder, 'renders'))) {
        const out = join(folder, 'renders', f);
        if (f.endsWith('.png') && !written.has(out)) {
          rmSync(join(design, out));
          console.log(`removed ${out}, its board or state is gone`);
        }
      }
    }
  }
  if (failed) {
    console.error(`${failed} render(s) need a look.`);
    process.exitCode = 1;
  }
}

main().catch((e) => {
  console.error(e.message);
  process.exit(1);
});

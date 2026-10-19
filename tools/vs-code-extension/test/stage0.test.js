const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { Readable } = require('node:stream');
const { EventEmitter } = require('node:events');
const Module = require('node:module');
const https = require('node:https');

const originalLoad = Module._load;
Module._load = function(name, ...args) {
  if (name === 'vscode') return { ProgressLocation: { Notification: 1 }, window: { withProgress: (_options, run) => run() } };
  return originalLoad.call(this, name, ...args);
};
const { ensureStage0, resolvePlatform } = require('../out/stage0');
Module._load = originalLoad;
const platform = resolvePlatform();
assert.equal(platform.supported, true);
const payload = Buffer.from('verified stage0 fixture\n');
const hash = crypto.createHash('sha256').update(payload).digest('hex');
const sums = hash + '  ' + platform.assetName + '\n';
const repo = 'fixture/project';
const api = 'https://api.github.com/repos/' + repo;
const base = 'https://github.com/' + repo + '/releases/download/';
const good = 'stage0-20261018-120000-r100';
const bad = 'stage0-20261019-120000-r101';
const sha = '0123456789abcdef0123456789abcdef01234567';
const release = { tag_name: good, target_commitish: sha, draft: false, prerelease: false, published_at: '2026-10-18T12:00:00Z', assets: [{ name: platform.assetName, state: 'uploaded', size: payload.length }, { name: 'SHA256SUMS', state: 'uploaded', size: sums.length }] };

(async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'typelisp-stage0-test-'));
  const originalGet = https.get;
  const originalTimeout = global.setTimeout;
  // Advance the retry clock without changing the network/file verification.
  global.setTimeout = (run, _ms, ...args) => originalTimeout(run, 0, ...args);
  try {
    for (const scenario of ['public', 'missing', 'missing-asset', 'pagination', 'full-page', 'dangling-tag', 'no-release', 'bad-checksum', 'fallback-bad-checksum', 'no-sums', 'explicit-tag', 'api-failure', 'compare-failure', 'moved-tag', 'cached-bad-checksum', 'manifest-entry-lost', 'cached-current', 'cached-fallback-current', 'cached-offline']) {
      const dir = path.join(root, scenario);
      const logs = [];
      const calls = [];
      let manifestReads = 0;
      const responses = new Map();
      for (const tag of ['stage0-latest', good]) {
        responses.set(base + tag + '/SHA256SUMS', [200, sums]);
        responses.set(base + tag + '/' + platform.assetName, [200, payload]);
      }
      responses.set(api + '/releases?per_page=100&page=1', [200, JSON.stringify([{ ...release, tag_name: bad, published_at: '2026-10-19T12:00:00Z' }, release])]);
      responses.set(api + '/compare/' + bad + '...main', [200, JSON.stringify({ base_commit: { sha }, status: 'diverged' })]);
      responses.set(api + '/compare/' + good + '...main', [200, JSON.stringify({ base_commit: { sha }, status: 'ahead' })]);
      if (!['public', 'bad-checksum', 'cached-bad-checksum', 'manifest-entry-lost', 'missing-asset', 'cached-current'].includes(scenario)) responses.set(base + 'stage0-latest/SHA256SUMS', [404, '']);
      if (scenario === 'cached-offline') responses.set(base + 'stage0-latest/SHA256SUMS', [503, '']);
      if (scenario === 'missing-asset') responses.set(base + 'stage0-latest/' + platform.assetName, [404, '']);
      if (scenario === 'pagination') {
        responses.set(api + '/releases?per_page=100&page=2', responses.get(api + '/releases?per_page=100&page=1'));
        responses.set(api + '/releases?per_page=100&page=1', [200, JSON.stringify(Array.from({ length: 100 }, () => ({ draft: true })))]);
      }
      if (scenario === 'full-page') responses.set(api + '/releases?per_page=100&page=1', [200, JSON.stringify([release, ...Array.from({ length: 99 }, () => ({ draft: true }))])]);
      if (scenario === 'no-release') responses.set(api + '/releases?per_page=100&page=1', [200, '[]']);
      if (scenario === 'api-failure') responses.set(api + '/releases?per_page=100&page=1', [503, '']);
      if (scenario === 'compare-failure') responses.set(api + '/compare/' + bad + '...main', [503, '']);
      if (scenario === 'dangling-tag') responses.set(api + '/compare/' + bad + '...main', [404, '']);
      if (scenario === 'moved-tag') responses.set(api + '/compare/' + good + '...main', [200, JSON.stringify({ base_commit: { sha: 'wrong' }, status: 'ahead' })]);
      if (scenario === 'no-sums') responses.set(base + good + '/SHA256SUMS', [404, '']);
      if (scenario.includes('bad-checksum')) responses.set(base + 'stage0-latest/' + platform.assetName, [200, 'corrupted']);
      if (scenario === 'fallback-bad-checksum') responses.set(base + good + '/' + platform.assetName, [200, 'corrupted']);
      https.get = (url, _options, receive) => {
        calls.push(url);
        let [status, body] = responses.get(url) || [404, ''];
        if (scenario === 'manifest-entry-lost' && url === base + 'stage0-latest/SHA256SUMS' && ++manifestReads > 1) body = hash + '  another-asset\n';
        const response = Readable.from([Buffer.from(body)]);
        response.statusCode = status;
        response.headers = {};
        const request = new EventEmitter();
        request.setTimeout = () => request;
        request.destroy = (error) => request.emit('error', error);
        queueMicrotask(() => receive(response));
        return request;
      };
      const dest = path.join(dir, 'stage0', platform.outputName);
      if (scenario.startsWith('cached-')) {
        await fs.mkdir(path.dirname(dest), { recursive: true });
        await fs.writeFile(dest, scenario.endsWith('current') ? payload : 'previous compiler');
      }
      const result = await ensureStage0({ globalStorageUri: { fsPath: dir } }, { repo, releaseTag: scenario === 'explicit-tag' ? 'pinned-missing' : 'stage0-latest', autoUpdate: true }, { appendLine: (line) => logs.push(line) }, !['cached-current', 'cached-fallback-current', 'cached-offline'].includes(scenario));
      if (['public', 'missing', 'missing-asset', 'pagination', 'full-page', 'dangling-tag', 'cached-current', 'cached-fallback-current'].includes(scenario)) {
        assert.equal(result, dest, scenario + ': ' + logs.join('\n'));
        assert.deepEqual(await fs.readFile(dest), payload, scenario);
        if (!['public', 'cached-current'].includes(scenario)) assert(logs.some(line => line.includes('falling back to ' + repo + '@' + good)), scenario);
      } else if (['cached-bad-checksum', 'cached-offline'].includes(scenario)) {
        assert.equal(result, dest);
        assert.equal(await fs.readFile(dest, 'utf8'), 'previous compiler');
      } else {
        assert.equal(result, undefined, scenario + ': ' + logs.join('\n'));
        await assert.rejects(fs.access(dest), scenario);
      }
      if (['public', 'bad-checksum', 'cached-bad-checksum', 'explicit-tag', 'manifest-entry-lost'].includes(scenario)) assert(!calls.some(url => url.startsWith(api)), scenario + ' unexpectedly selected another release');
      if (['cached-current', 'cached-fallback-current', 'cached-offline'].includes(scenario)) assert(!calls.some(url => url.endsWith('/' + platform.assetName)), scenario + ' unnecessarily downloaded the cached binary');
      assert(!(await fs.readdir(path.dirname(dest))).some(name => name.startsWith('.download.')), scenario + ' left temporary state');
      console.log('stage0 editor/' + scenario + ' passed');
    }
  } finally {
    https.get = originalGet;
    global.setTimeout = originalTimeout;
    await fs.rm(root, { recursive: true, force: true });
  }
})().catch(error => { console.error(error); process.exitCode = 1; });

#!/usr/bin/env bash
set -euo pipefail
# Temporary D-C105 observation driver; removed from the final test-only head.
exec python - "$@" <<'PY'
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

p = argparse.ArgumentParser()
p.add_argument('--compiler', required=True)
p.add_argument('--base-compiler', required=True)
p.add_argument('--output', required=True)
p.add_argument('--preflight-only', action='store_true')
a = p.parse_args()
root = Path.cwd()
out = Path(a.output).resolve()
out.mkdir(parents=True, exist_ok=False)
refs = {'head': '4d03b42df93f5ea4c99df07c8e6584eab8c968f4',
        'base': 'd21da5c63648c891ed17126dd7d9224d2703565b'}
test_path = 'src/tests/compiler_package_runtime_lifetime_tests.tl'
test_name = 'package-runtime-direct-object-releases-side-backend'
bound = 131072
compilers = {'head': Path(a.compiler).resolve(),
             'base': Path(a.base_compiler).resolve()}
host = 'windows' if os.name == 'nt' else 'linux'
target = 'windows-x86_64' if host == 'windows' else 'linux-x86_64'

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def git(*args):
    return subprocess.check_output(['git', *args], cwd=root)

def lf_bytes(text):
    assert '\r' not in text, 'unexpected CR in intended TypeLisp source'
    return text.encode('utf-8')

def write_lf(path, text):
    path.write_bytes(lf_bytes(text))

def blob_hash(data):
    return hashlib.sha1(b'blob ' + str(len(data)).encode('ascii') + b'\0' + data).hexdigest()

identity = {'host': host, 'checkout': git('rev-parse', 'HEAD').decode().strip(),
            'refs': refs, 'bound': bound, 'linux_intact': 25216,
            'environment': {k: os.environ.get(k) for k in
                ('RUNNER_NAME', 'RUNNER_OS', 'RUNNER_ARCH', 'ImageOS',
                 'ImageVersion', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT',
                 'GITHUB_SHA', 'TMPDIR', 'TYPELISP_INLINE_TEST_WORKERS',
                 'TYPELISP_BUILD_INVARIANCE_WORKERS')}, 'compilers': {}}
identity['checkout_attributes_sha256'] = sha(root / '.gitattributes')
identity['core_autocrlf'] = subprocess.run(['git', 'config', '--get', 'core.autocrlf'],
    cwd=root, stdout=subprocess.PIPE, text=True).stdout.strip()
for name, compiler in compilers.items():
    identity['compilers'][name] = {'path': str(compiler), 'sha256': sha(compiler),
        'version': subprocess.check_output([str(compiler), '--version'], text=True).strip()}
assert refs['base'] in identity['compilers']['base']['version']
(out / 'identity.json').write_text(json.dumps(identity, indent=2) + '\n')
candidate_blob = git('show', 'HEAD:' + test_path)
assert (root / test_path).read_bytes() == candidate_blob
candidate = candidate_blob.decode('utf-8')
assert '[bound : i64 131072]' in candidate
assert 'C105_DISPOSABLE_DELTA=' in candidate
original_assertion = '''    (unless
      (< (- (profile.alloc-live) before) 1048576)
      (io.panic "direct object jobs retained private side-backend arenas"))))'''
observed_assertion = '''    (let
      [delta : i64 (- (profile.alloc-live) before)]
      [bound : i64 1048576]
      (io.eprintln "C105_DISPOSABLE_DELTA={} BOUND={}" delta bound)
      (unless
        (< delta bound)
        (io.panic "direct object jobs retained private side-backend arenas")))))'''
release = '''                  (compiler_backend.compiler-backend-state-release-final-arenas!
                    side-backend-state)'''
mutation = '''                  (let
                    [owner : i64
                      (compiler_backend.compiler-backend-state-lazy-table-arena
                        side-backend-state)]
                    (unless (> owner 0)
                      (io.panic "C105 mutation did not allocate a private arena"))
                    unit)'''
trees = {}
source_bytes = {}
blob_ids = {}
for name, ref in refs.items():
    exists = subprocess.run(['git', 'cat-file', '-e', ref + '^{commit}'],
                            cwd=root, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if exists.returncode:
        subprocess.run(['git', 'fetch', '--no-tags', '--depth=1', 'origin', ref],
                       cwd=root, check=True)
    tree = out / (name + '-pristine')
    tree.mkdir()
    # Use this runner's Git conversion rules, including CRLF TSV resources.
    # A private index keeps the real checkout/index untouched.
    index_env = dict(os.environ, GIT_INDEX_FILE=str(out / (name + '.index')))
    subprocess.run(['git', 'read-tree', ref], cwd=root, env=index_env, check=True)
    paths = git('ls-tree', '-rz', '--name-only', ref, '--', 'src', 'stdlib')
    subprocess.run(['git', 'checkout-index', '-z', '--stdin',
                    '--prefix=' + tree.as_posix() + '/'], cwd=root,
                   env=index_env, input=paths, check=True)
    trees[name] = tree
    entries = git('ls-tree', '-rz', ref, '--', 'src', 'stdlib').split(b'\0')
    blob_ids[name] = {entry.split(b'\t', 1)[1].decode('utf-8'):
                     entry.split(b'\t', 1)[0].split()[2].decode('ascii')
                     for entry in entries if entry}
    source_bytes[name] = {f.relative_to(tree).as_posix(): f.read_bytes()
                          for f in tree.rglob('*') if f.is_file()}
    for path, data in source_bytes[name].items():
        if path.endswith('.tl'):
            assert b'\r' not in data
            assert blob_hash(data) == blob_ids[name][path], path + ': checkout differs from Git blob'
    (out / (name + '-source.sha256')).write_text(''.join(
        sha(f) + '  ' + f.relative_to(tree).as_posix() + '\n'
        for f in sorted(tree.rglob('*')) if f.is_file()))

rows = []
try:
    for variant in ('original', 'entry-disabled', 'candidate', 'mutation'):
        for name in ('head', 'base'):
            label = name + '-' + variant
            tree = out / label
            shutil.copytree(trees[name], tree)
            path = tree / test_path
            original = source_bytes[name][test_path]
            assert path.read_bytes() == original
            text = original.decode('utf-8')
            assert text.count(original_assertion) == 1
            if variant in ('original', 'entry-disabled'):
                text = text.replace(original_assertion, observed_assertion)
                if variant == 'entry-disabled':
                    old = 'runtime-owner-smoke-for-route (string.copy source) Linux 0 true'
                    assert text.count(old) == 2
                    text = text.replace(old, 'runtime-owner-smoke-for-route-and-entry (string.copy source) Linux 0 true false')
            else:
                text = candidate
            write_lf(path, text)
            expected = dict(source_bytes[name])
            expected[test_path] = lf_bytes(text)
            if variant == 'mutation':
                driver = tree / 'src/compiler_driver_core.tl'
                old = source_bytes[name]['src/compiler_driver_core.tl'].decode('utf-8')
                assert old.count(release) == 1
                expected['src/compiler_driver_core.tl'] = lf_bytes(old.replace(release, mutation))
                driver.write_bytes(expected['src/compiler_driver_core.tl'])
                assert driver.read_bytes().replace(lf_bytes(mutation), lf_bytes(release), 1) == lf_bytes(old)
                (out / (name + '-mutant-driver.tl')).write_bytes(driver.read_bytes())
            if variant in ('candidate', 'mutation'):
                assert path.read_bytes() == candidate_blob
            else:
                restored = text
                if variant == 'entry-disabled':
                    restored = restored.replace('runtime-owner-smoke-for-route-and-entry (string.copy source) Linux 0 true false', old)
                restored = restored.replace(observed_assertion, original_assertion)
                assert lf_bytes(restored) == original
            prepared = {f.relative_to(tree).as_posix(): f.read_bytes()
                        for f in tree.rglob('*') if f.is_file()}
            assert prepared == expected, label + ': unintended source change'
            proof = {'case': label, 'checked_files': len(prepared),
                     'test_origin_blob': blob_ids[name][test_path],
                     'prepared_test_blob': blob_hash(path.read_bytes()),
                     'candidate_blob': blob_hash(candidate_blob),
                     'changed_paths': [p for p in expected if expected[p] != source_bytes[name][p]],
                     'exact_expected_bytes': True, 'driver_release_only': variant == 'mutation'}
            (out / (label + '-proof.json')).write_text(json.dumps(proof, indent=2) + '\n')
            (out / (label + '.tl')).write_bytes(path.read_bytes())
            if a.preflight_only:
                print(json.dumps(proof), flush=True)
                continue
            report = out / (label + '.memory')
            command = [str(compilers[name]), 'test', str(path), '--exact', test_name,
                       '--target', target, '--stdlib-root', str(tree / 'stdlib'),
                       '--stdlib-root', str(tree / 'src')]
            wrapped = ['bash', str(root / 'scripts/run-memory-bounded.sh'),
                       '--limit-mib', '8192', '--timeout-seconds', '180',
                       '--report', str(report), '--working-directory', str(tree),
                       '--', *command]
            if host == 'linux':
                available = int(re.search(r'MemAvailable:\s+(\d+)', Path('/proc/meminfo').read_text())[1])
                assert available > (8192 + 16384) * 1024
            start = time.monotonic()
            with (out / (label + '.stdout')).open('w') as stdout, (out / (label + '.stderr')).open('w') as stderr:
                result = subprocess.run(wrapped, cwd=root, env=os.environ, stdout=stdout, stderr=stderr)
            log = (out / (label + '.stderr')).read_text()
            match = re.search(r'C105_DISPOSABLE_DELTA=(-?\d+) BOUND=(\d+)', log)
            assert match, label + ': missing sampled counters'
            delta, limit = map(int, match.groups())
            memory = dict(line.split('=', 1) for line in report.read_text().splitlines())
            assert memory['reason'] in ('success', 'command-failure'), label + ': invalid bounded completion'
            row = {'case': label, 'delta': delta, 'bound': limit,
                   'exit': result.returncode, 'seconds': time.monotonic() - start,
                   'test_sha256': sha(path), 'driver_sha256': sha(tree / 'src/compiler_driver_core.tl'),
                   'argv': wrapped, 'memory': memory}
            rows.append(row)
            print(json.dumps(row), flush=True)
            if variant == 'original':
                assert result.returncode in (0, 2, 134)
                assert (delta < limit) == (result.returncode == 0)
                if result.returncode:
                    assert 'direct object jobs retained private side-backend arenas' in log
                    assert result.returncode == 134 or 'exit status: 134' in log
            elif variant == 'mutation':
                assert result.returncode in (2, 134), label + ': mutation did not fail its assertion'
                assert result.returncode == 134 or 'exit status: 134' in log
                assert 'direct object jobs retained private side-backend arenas' in log
                assert 'C105 mutation did not allocate' not in log
                assert delta * 4 >= bound * 5
                intact = next(r['delta'] for r in rows if r['case'] == name + '-candidate')
                assert delta * 16 >= intact * 25
            else:
                assert result.returncode == 0
                if variant == 'candidate':
                    assert delta * 5 <= bound * 4
                    assert delta * 4 <= 25216 * 5, label + ': exceeds Linux by more than25%'
    if a.preflight_only:
        (out / 'PREFLIGHT_PASS').write_text('All8 prepared source sets have exact intended bytes.\n')
    else:
        (out / 'PASS').write_text('All8 identity/case cells meet D-C105.\n')
finally:
    (out / 'results.json').write_text(json.dumps(rows, indent=2) + '\n')
PY

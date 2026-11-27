#!/usr/bin/env sh
set -eu

# verify-inline-tests.sh - auto-discover and run inline TypeLisp tests.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-ci-timing.sh"
. "$ROOT/scripts/lib-linux-memory-limit.sh"
BOUNDED_POOL_LABEL=inline-tests
. "$ROOT/scripts/lib-bounded-pool.sh"

usage() {
    cat <<'EOF'
usage: scripts/verify-inline-tests.sh [--self-test-chunks]

--self-test-chunks runs only the chunk accounting self-test: fabricated chunk
results that must pass, and mutations of them that must fail. Every ordinary
run performs it first.
EOF
}

SELF_TEST_ONLY=0
case "${1:-}" in
    "") ;;
    --self-test-chunks) SELF_TEST_ONLY=1 ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

# Each `typelisp` invocation runs exactly once: a crash is a real compiler bug,
# not a flake — do not retry it (see the no-retry policy in scripts/ci-verify.sh).

HOST_OS=linux
HOST_TARGET=linux-x86_64
case "$(uname -s)" in
    Linux*)
        HOST_OS=linux
        HOST_TARGET=linux-x86_64
        ;;
    MINGW* | MSYS* | CYGWIN*)
        HOST_OS=windows
        HOST_TARGET=windows-x86_64
        ;;
    *)
        echo "inline test verification is unsupported on this host" >&2
        exit 1
        ;;
esac

PATH_SEP=:
[ "$HOST_OS" = windows ] && PATH_SEP=';'
unset TYPELISP_STDLIB_TEST_MISSING_854
export TYPELISP_STDLIB_TEST_EMPTY=
export TYPELISP_STDLIB_TEST_VALUE=env-value-854
export TYPELISP_STDLIB_TEST_PATH="one${PATH_SEP}two${PATH_SEP}three"

# The discovered sources run as LPT-scheduled chunks in a bounded pool
# (scripts/lib-bounded-pool.sh): TYPELISP_INLINE_TEST_WORKERS `typelisp test
# --batch` processes at once (1-3, default 3), each under an enforced memory cap
# and timeout (a user cgroup on Linux, a Job Object on Windows). A batch shares
# nothing between its sources, because the driver resets for each one, so a
# chunk costs only its own process start. Heaviest sources (weighted by
# transitive import closure and file length) are placed into small chunks at
# the front of the queue and fast sources into full chunks at the tail, so all
# workers drain together without a late straggler. Every chunk's stdout is
# verified against its list and the combined paths against the discovered set.
INLINE_TEST_WORKERS=${TYPELISP_INLINE_TEST_WORKERS:-3}
case "$INLINE_TEST_WORKERS" in
    1 | 2 | 3) ;;
    *)
        echo "invalid TYPELISP_INLINE_TEST_WORKERS: $INLINE_TEST_WORKERS (expected 1-3)" >&2
        exit 2
        ;;
esac
INLINE_TEST_CHUNK_FILES=12
INLINE_TEST_CHUNK_TARGET_COUNT=32
INLINE_TEST_COMBINED_HEAVY_CHUNKS=3
INLINE_TEST_COMBINED_LIGHT_CHUNKS=2
INLINE_TEST_COMBINED_STDLIB_CHUNKS=2
INLINE_TEST_COMBINED_HUB_MIN_LINES=40000
INLINE_TEST_COMBINED_HUB_TARGET_WEIGHT=60000
# Linux cgroup MemoryMax bounds resident pages (RSS; measured heavy peak
# ~3.45 GiB on 16 GiB runners), so 3 Linux workers can admit three 4096 MiB
# heavy chunks concurrently (12288 MiB budget). Windows Job Objects bound
# committed virtual memory across the compiler and child test binary (~1.5-1.7x
# Linux RSS, historical peak ~5.5 GiB), so 3 Windows workers keep at most two
# heavy 6144 MiB chunks plus one light 5120 MiB chunk at once.
INLINE_TEST_CHUNK_CAP_MIB=4096
INLINE_TEST_LIGHT_CHUNK_CAP_MIB=3072
if [ "$HOST_OS" = windows ]; then
    INLINE_TEST_CHUNK_CAP_MIB=6144
    INLINE_TEST_LIGHT_CHUNK_CAP_MIB=5120
fi
if [ "$INLINE_TEST_WORKERS" -le 2 ] || [ "$HOST_OS" = linux ]; then
    INLINE_TEST_POOL_BUDGET_MIB=$((INLINE_TEST_WORKERS * INLINE_TEST_CHUNK_CAP_MIB))
else
    INLINE_TEST_POOL_BUDGET_MIB=$((2 * INLINE_TEST_CHUNK_CAP_MIB + (INLINE_TEST_WORKERS - 2) * INLINE_TEST_LIGHT_CHUNK_CAP_MIB))
fi
INLINE_TEST_JOB_TIMEOUT_SECONDS=1800
INLINE_TEST_PEAK_BYTES=0
INLINE_TEST_PEAK_JOB=
INLINE_TEST_PEAK_CAP_MIB=$INLINE_TEST_CHUNK_CAP_MIB

show_streams() {
    _stdout=$1
    _stderr=$2
    if [ -s "$_stdout" ]; then
        echo "stdout:" >&2
        sed 's/^/  /' "$_stdout" >&2 || true
    fi
    if [ -s "$_stderr" ]; then
        echo "stderr:" >&2
        sed 's/^/  /' "$_stderr" >&2 || true
    fi
}

# Write `<dir>/chunk-NNN.list` files and the pool queue (`chunk-NNN|<cap MiB>`).
# Compatible `src/`, `src/tests/`, `stdlib/`, and compiler-importing
# `tests/inline/` sources are grouped by shared large-module dependency closure
# into combined chunks (`<dir>/chunk-NNN.combined`) so each chunk compiles its
# shared module closure once and executes every source in its own fresh
# subprocess. Remaining standalone sources use the single-file LPT batch planner.
inline_test_plan_chunks() {
    _plan_sources=$1
    _plan_dir=$2
    _plan_queue=$3
    : > "$_plan_queue"
    awk -v size="$INLINE_TEST_CHUNK_FILES" \
        -v target_chunks="$INLINE_TEST_CHUNK_TARGET_COUNT" \
        -v heavy_chunks="$INLINE_TEST_COMBINED_HEAVY_CHUNKS" \
        -v light_chunks="$INLINE_TEST_COMBINED_LIGHT_CHUNKS" \
        -v std_chunks="$INLINE_TEST_COMBINED_STDLIB_CHUNKS" \
        -v hub_min_lines="$INLINE_TEST_COMBINED_HUB_MIN_LINES" \
        -v hub_target_w="$INLINE_TEST_COMBINED_HUB_TARGET_WEIGHT" \
        -v dir="$_plan_dir" \
        -v cap="$INLINE_TEST_CHUNK_CAP_MIB" \
        -v light_cap="$INLINE_TEST_LIGHT_CHUNK_CAP_MIB" \
        -v queue="$_plan_queue" '
        function flush_plain_chunk(    chunk_cap) {
            if (last == "") return
            close(dir "/" last ".list")
            chunk_cap = (cf <= 2 && (target_w == 0 || cw * 2 >= target_w)) ? cap : light_cap
            print last "|" chunk_cap >> queue
        }
        function resolve_mod(mod,    p, _line) {
            p = "src/" mod ".tl"
            if ((getline _line < p) >= 0) {
                close(p)
                return p
            }
            p = "src" "/tests/" mod ".tl"
            if ((getline _line < p) >= 0) {
                close(p)
                return p
            }
            p = mod
            gsub(/\./, "/", p)
            p = p ".tl"
            if ((getline _line < p) >= 0) {
                close(p)
                return p
            }
            return ""
        }
        function scan_file(path,    line, n, mod, dep, name, i, in_str, ch, esc, k, len) {
            if (path in scanned) return
            scanned[path] = 1
            n = 0
            deg[path] = 0
            sdef_cnt[path] = 0
            edef_cnt[path] = 0
            has_explicit_mod[path] = 0
            in_str = 0
            while ((getline line < path) > 0) {
                n++
                if (!in_str) {
                    if (line ~ /^[[:space:]]*\(module[[:space:]]+/) {
                        has_explicit_mod[path] = 1
                    }
                    if (line ~ /^\(defstruct[[:space:]]+[A-Za-z0-9_-]+/) {
                        name = line
                        sub(/^\(defstruct[[:space:]]+/, "", name)
                        sub(/[^A-Za-z0-9_-].*/, "", name)
                        if (name != "" && !seen_sdef[path SUBSEP name]++) {
                            sdef_cnt[path]++
                            sdef[path, sdef_cnt[path]] = name
                        }
                    } else if (line ~ /^\(defenum[[:space:]]+[A-Za-z0-9_-]+/) {
                        name = line
                        sub(/^\(defenum[[:space:]]+/, "", name)
                        sub(/[^A-Za-z0-9_-].*/, "", name)
                        if (name != "" && !seen_edef[path SUBSEP name]++) {
                            edef_cnt[path]++
                            edef[path, edef_cnt[path]] = name
                        }
                    }
                    if (line ~ /^[[:space:]]*(\(cfg[[:space:]]+[^()]+[[:space:]]+)?\(import[[:space:]]+/) {
                        mod = line
                        sub(/^[[:space:]]*(\(cfg[[:space:]]+[^()]+[[:space:]]+)?\(import[[:space:]]+\(?/, "", mod)
                        sub(/[[:space:]\)\r].*/, "", mod)
                        if (mod != "" && !seen_edge[path SUBSEP mod]++) {
                            dep = resolve_mod(mod)
                            if (dep != "" && dep != path) {
                                deg[path]++
                                edge[path, deg[path]] = dep
                            }
                        }
                    }
                }
                # Track multi-line string literals so test fixtures inside
                # strings are not mistaken for top-level type declarations.
                if (index(line, "\"") > 0) {
                    len = length(line)
                    esc = 0
                    for (k = 1; k <= len; k++) {
                        ch = substr(line, k, 1)
                        if (in_str) {
                            if (esc) { esc = 0 }
                            else if (ch == "\\") { esc = 1 }
                            else if (ch == "\"") { in_str = 0 }
                        } else {
                            if (ch == ";") { break }
                            else if (ch == "\"") { in_str = 1 }
                        }
                    }
                }
            }
            close(path)
            lines[path] = n
            for (i = 1; i <= deg[path]; i++) {
                scan_file(edge[path, i])
            }
        }
        function closure_weight(root,    qhead, qtail, u, v, i, tot, vis, q, hubs, nh, hkey, fhubs, nfh, fhkey) {
            qhead = 1
            qtail = 1
            q[1] = root
            vis[root] = 1
            tot = 0
            nh = 0
            nfh = 0
            imports_src[root] = 0
            cl_cnt[root] = 0
            while (qhead <= qtail) {
                u = q[qhead++]
                cl_cnt[root]++
                cl_node[root, cl_cnt[root]] = u
                tot += lines[u]
                if (lines[u] >= hub_min_lines) {
                    fhubs[++nfh] = u
                    if (!(u ~ /_tests\.tl$/)) {
                        hubs[++nh] = u
                    }
                }
                for (i = 1; i <= deg[u]; i++) {
                    v = edge[u, i]
                    if (!(v in vis)) {
                        vis[v] = 1
                        reaches[root SUBSEP v] = 1
                        if (v ~ /^src\//) imports_src[root] = 1
                        q[++qtail] = v
                    }
                }
            }
            sort_asc_path(hubs, nh)
            hkey = ""
            for (i = 1; i <= nh; i++) {
                hkey = (i == 1) ? hubs[i] : (hkey "," hubs[i])
            }
            sort_asc_path(fhubs, nfh)
            fhkey = ""
            for (i = 1; i <= nfh; i++) {
                fhkey = (i == 1) ? fhubs[i] : (fhkey "," fhubs[i])
            }
            core_hub_count[root] = nh
            core_hub_key[root] = hkey
            full_hub_count[root] = nfh
            full_hub_key[root] = fhkey
            return tot + lines[root] * 16 + 1000
        }
        function sort_desc_weight(arr, n,    i, j, kf, kw) {
            for (i = 2; i <= n; i++) {
                kf = arr[i]
                kw = w[kf]
                j = i - 1
                while (j >= 1 && (w[arr[j]] < kw || (w[arr[j]] == kw && arr[j] > kf))) {
                    arr[j + 1] = arr[j]
                    j--
                }
                arr[j + 1] = kf
            }
        }
        function sort_asc_path(arr, n,    i, j, kf) {
            for (i = 2; i <= n; i++) {
                kf = arr[i]
                j = i - 1
                while (j >= 1 && arr[j] > kf) {
                    arr[j + 1] = arr[j]
                    j--
                }
                arr[j + 1] = kf
            }
        }
        function file_has_chunk_type_dup(b, idx,    f, j, k, m, g, nm) {
            f = bfile[b, idx]
            for (k = 1; k <= sdef_cnt[f]; k++) {
                nm = sdef[f, k]
                for (j = 1; j <= bcount[b]; j++) {
                    if (j == idx) continue
                    g = bfile[b, j]
                    if ((g SUBSEP nm) in seen_sdef || (g SUBSEP nm) in seen_edef) return 1
                }
            }
            for (k = 1; k <= edef_cnt[f]; k++) {
                nm = edef[f, k]
                for (j = 1; j <= bcount[b]; j++) {
                    if (j == idx) continue
                    g = bfile[b, j]
                    if ((g SUBSEP nm) in seen_sdef || (g SUBSEP nm) in seen_edef) return 1
                }
            }
            return 0
        }
        function split_weight(path,    ln) {
            ln = lines[path]
            if (ln > 15000) ln = 15000
            return ln + 4000
        }
        function combined_hub_chunks(arr, n,    i, tot, k) {
            if (n <= 1 || hub_target_w <= 0) return 1
            tot = 0
            for (i = 1; i <= n; i++) tot += split_weight(arr[i])
            k = int((tot + hub_target_w - 1) / hub_target_w)
            if (k < 1) k = 1
            if (k > n) k = n
            return k
        }
        # Partition sorted arr[1..n] into k contiguous slices balanced by a
        # capped file weight so a single huge shared module (already in every
        # heavy chunk'\''s closure) does not force the remaining files into one
        # oversized tail chunk. Then promote each chunk'\''s largest
        # non-chunk-imported file to index 1 (the root-module leader) and
        # relocate any importer of that leader to the next unprocessed chunk,
        # or defer it to deff.
        function plan_contiguous_combined(arr, n, k, bcap, use_leader, no_prebuilt,    i, j, m, b, nb, tot, target, acc, f, u, best, best_dup, cur_dup, imp, leader, dst, job, defn, deff, cvis, u_lines, f_lines) {
            if (n <= 0) return
            sort_asc_path(arr, n)
            nb = (k > 0 && k < n) ? k : n
            delete bcount
            delete bfile
            tot = 0
            for (i = 1; i <= n; i++) tot += split_weight(arr[i])
            target = tot / nb
            b = 1
            acc = 0
            defn = 0
            for (i = 1; i <= n; i++) {
                f = arr[i]
                if (b < nb && bcount[b] > 0 && acc + split_weight(f) / 2 > target && (n - i + 1) >= (nb - b)) {
                    b++
                    acc = 0
                }
                bcount[b]++
                bfile[b, bcount[b]] = f
                acc += split_weight(f)
            }
            nb = b
            if (use_leader) {
                for (b = 1; b <= nb; b++) {
                    if (bcount[b] <= 1) continue
                    best = 0
                    best_dup = 1
                    for (i = 1; i <= bcount[b]; i++) {
                        f = bfile[b, i]
                        imp = 0
                        for (j = 1; j <= bcount[b]; j++) {
                            if (i != j && ((bfile[b, j] SUBSEP f) in reaches)) {
                                imp++
                            }
                        }
                        cur_dup = file_has_chunk_type_dup(b, i)
                        if ((imp == 0 || (nb > 1 && imp * 4 <= bcount[b])) && (best == 0 || cur_dup < best_dup || (cur_dup == best_dup && lines[f] > lines[bfile[b, best]]))) {
                            best = i
                            best_dup = cur_dup
                        }
                    }
                    if (best == 0) {
                        best = 1
                        for (i = 2; i <= bcount[b]; i++) {
                            if (lines[bfile[b, i]] > lines[bfile[b, best]]) best = i
                        }
                    }
                    if (best > 1) {
                        leader = bfile[b, best]
                        for (i = best; i > 1; i--) bfile[b, i] = bfile[b, i - 1]
                        bfile[b, 1] = leader
                    }
                    leader = bfile[b, 1]
                    if (nb > 1) {
                        dst = (b < nb) ? (b + 1) : 0
                        j = 1
                        for (i = 2; i <= bcount[b]; i++) {
                            f = bfile[b, i]
                            if ((f SUBSEP leader) in reaches) {
                                if (dst > 0) {
                                    bcount[dst]++
                                    bfile[dst, bcount[dst]] = f
                                } else {
                                    deff[++defn] = f
                                }
                            } else {
                                j++
                                bfile[b, j] = f
                            }
                        }
                        bcount[b] = j
                    }
                }
            }
            for (b = 1; b <= nb; b++) {
                if (bcount[b] <= 0) continue
                c++
                job = sprintf("chunk-%03d", c)
                delete cvis
                u_lines = 0
                f_lines = 0
                for (i = 1; i <= bcount[b]; i++) {
                    f = bfile[b, i]
                    print f > (dir "/" job ".list")
                    f_lines += lines[f]
                    for (m = 1; m <= cl_cnt[f]; m++) {
                        u = cl_node[f, m]
                        if (!(u in cvis)) {
                            cvis[u] = 1
                            u_lines += lines[u]
                        }
                    }
                }
                close(dir "/" job ".list")
                if (bcount[b] > 1) {
                    print "1" > (dir "/" job ".combined")
                    close(dir "/" job ".combined")
                }
                if (no_prebuilt) {
                    print "1" > (dir "/" job ".no-prebuilt-stdlib")
                    close(dir "/" job ".no-prebuilt-stdlib")
                }
                ncomb++
                comb_job[ncomb] = job
                comb_cap[ncomb] = bcap
                comb_w[ncomb] = u_lines + f_lines + bcount[b] * 4000
            }
            if (defn > 0) {
                plan_contiguous_combined(deff, defn, 1, bcap, use_leader, no_prebuilt)
            }
        }
        {
            sub(/\r$/, "")
            if ($0 == "") next
            files[++nfiles] = $0
            scan_file($0)
        }
        END {
            for (i = 1; i <= nfiles; i++) {
                f = files[i]
                w[f] = closure_weight(f)
                if (f ~ /^stdlib\//) {
                    std_files[++nstd] = f
                } else if (f == "tests/inline/hashmap_macro_aggregate_modules.tl") {
                    no_prebuilt_plain_files[++nno_prebuilt_plain] = f
                } else if ((f ~ /^src\//) || (f ~ /^tests\/inline\// && imports_src[f] && !has_explicit_mod[f])) {
                    if (core_hub_count[f] >= 2 && full_hub_count[f] > core_hub_count[f]) {
                        hk = full_hub_key[f]
                        if (!(hk in extra_hub_seen)) {
                            extra_hub_seen[hk] = 1
                            extra_hub_keys[++nextra_hubs] = hk
                        }
                        extra_hub_cnt[hk]++
                        extra_hub_file[hk, extra_hub_cnt[hk]] = f
                    } else if (core_hub_count[f] >= 2) {
                        heavy_files[++nheavy] = f
                    } else if (core_hub_count[f] == 1) {
                        hk = core_hub_key[f]
                        if (!(hk in single_hub_seen)) {
                            single_hub_seen[hk] = 1
                            single_hub_keys[++nsingle_hubs] = hk
                        }
                        single_hub_cnt[hk]++
                        single_hub_file[hk, single_hub_cnt[hk]] = f
                    } else if (f ~ /^tests\/inline\//) {
                        inline_light_files[++ninline_light] = f
                    } else {
                        light_files[++nlight] = f
                    }
                } else {
                    plain_files[++nplain] = f
                }
            }
            c = 0
            ncomb = 0
            sort_asc_path(extra_hub_keys, nextra_hubs)
            for (h = 1; h <= nextra_hubs; h++) {
                hk = extra_hub_keys[h]
                delete hfiles
                hn = extra_hub_cnt[hk]
                for (i = 1; i <= hn; i++) hfiles[i] = extra_hub_file[hk, i]
                plan_contiguous_combined(hfiles, hn, combined_hub_chunks(hfiles, hn), cap, 1, 0)
            }
            plan_contiguous_combined(heavy_files, nheavy, heavy_chunks, cap, 1, 0)
            sort_asc_path(single_hub_keys, nsingle_hubs)
            for (h = 1; h <= nsingle_hubs; h++) {
                hk = single_hub_keys[h]
                delete hfiles
                hn = single_hub_cnt[hk]
                for (i = 1; i <= hn; i++) hfiles[i] = single_hub_file[hk, i]
                plan_contiguous_combined(hfiles, hn, combined_hub_chunks(hfiles, hn), cap, 1, 0)
            }
            plan_contiguous_combined(light_files, nlight, light_chunks, light_cap, 1, 0)
            plan_contiguous_combined(inline_light_files, ninline_light, 1, light_cap, 1, 0)
            plan_contiguous_combined(std_files, nstd, std_chunks, light_cap, 0, 1)

            # Emit combined chunks in descending estimated weight order (LPT) so
            # the heaviest chunks start first regardless of group discovery order.
            for (i = 1; i <= ncomb; i++) comb_ord[i] = i
            for (i = 2; i <= ncomb; i++) {
                idx = comb_ord[i]
                kw = comb_w[idx]
                j = i - 1
                while (j >= 1 && comb_w[comb_ord[j]] < kw) {
                    comb_ord[j + 1] = comb_ord[j]
                    j--
                }
                comb_ord[j + 1] = idx
            }
            for (i = 1; i <= ncomb; i++) {
                idx = comb_ord[i]
                print comb_job[idx] "|" comb_cap[idx] >> queue
            }

            # Isolated non-stdlib files that depend on stdlib `(cfg test ...)`
            # definitions stay on `--no-prebuilt-stdlib` without disabling
            # prebuilt stdlib for other plain chunks.
            if (nno_prebuilt_plain > 0) {
                sort_asc_path(no_prebuilt_plain_files, nno_prebuilt_plain)
                c++
                last = sprintf("chunk-%03d", c)
                for (i = 1; i <= nno_prebuilt_plain; i++) {
                    print no_prebuilt_plain_files[i] > (dir "/" last ".list")
                }
                close(dir "/" last ".list")
                print "1" > (dir "/" last ".no-prebuilt-stdlib")
                close(dir "/" last ".no-prebuilt-stdlib")
                print last "|" light_cap >> queue
            }

            # Standalone / non-combined files in regular LPT chunks.
            if (nplain > 0) {
                total_w = 0
                for (i = 1; i <= nplain; i++) total_w += w[plain_files[i]]
                sort_desc_weight(plain_files, nplain)
                plain_target_chunks = (nplain == nfiles) ? target_chunks : 0
                target_w = (plain_target_chunks > 0) ? (total_w / plain_target_chunks) : 0
                cf = 0
                cw = 0
                last = ""
                for (i = 1; i <= nplain; i++) {
                    f = plain_files[i]
                    fw = w[f]
                    if (cf == 0 || cf >= size || (target_w > 0 && cw + fw > target_w)) {
                        flush_plain_chunk()
                        c++
                        last = sprintf("chunk-%03d", c)
                        cf = 0
                        cw = 0
                    }
                    print f > (dir "/" last ".list")
                    cf++
                    cw += fw
                }
                flush_plain_chunk()
            }
        }
    ' "$_plan_sources"
}

# Account for one finished chunk, in queue order, and append its streams to the
# combined output. A chunk that left no status, was stopped by its cap or
# timeout, failed, or whose own aggregate does not match its list fails the gate.
inline_test_settle_chunk() {
    _settle_job=$1
    _settle_dir=$2
    _settle_combined_stdout=$3
    _settle_combined_stderr=$4
    _settle_cap=${5:-$INLINE_TEST_CHUNK_CAP_MIB}
    _settle_list="$_settle_dir/$_settle_job.list"
    _settle_stdout="$_settle_dir/$_settle_job.stdout"
    _settle_stderr="$_settle_dir/$_settle_job.stderr"
    _settle_status="$_settle_dir/$_settle_job.status"
    _settle_report="$_settle_dir/$_settle_job.memory"
    if [ ! -s "$_settle_status" ] || [ ! -s "$_settle_list" ]; then
        echo "inline test $_settle_job left no status" >&2
        exit 1
    fi
    _settle_rc=$(cat "$_settle_status")
    if ! bounded_pool_read_report "$_settle_report" "$_settle_rc" "$_settle_cap" "$HOST_OS"; then
        echo "inline test $_settle_job $BOUNDED_POOL_REPORT_FAILURE" \
            "(reason=$BOUNDED_POOL_REPORT_REASON," \
            "cap $_settle_cap MiB," \
            "timeout $INLINE_TEST_JOB_TIMEOUT_SECONDS s)" >&2
        show_streams "$_settle_stdout" "$_settle_stderr"
        exit 1
    fi
    _settle_peak=$BOUNDED_POOL_REPORT_PEAK
    if [ "$_settle_peak" -gt "$INLINE_TEST_PEAK_BYTES" ]; then
        INLINE_TEST_PEAK_BYTES=$_settle_peak
        INLINE_TEST_PEAK_JOB=$_settle_job
        INLINE_TEST_PEAK_CAP_MIB=$_settle_cap
    fi
    if [ "$_settle_rc" != 0 ]; then
        echo "inline test batch execution failed in $_settle_job" >&2
        show_streams "$_settle_stdout" "$_settle_stderr"
        exit 1
    fi
    _settle_paths="$_settle_dir/$_settle_job.paths"
    sed -n 's/^TypeLisp test file: \(.*\) ([0-9][0-9]* test(s))$/\1/p' \
        "$_settle_stdout" | tr -d '\r' > "$_settle_paths"
    if ! cmp -s "$_settle_list" "$_settle_paths"; then
        echo "inline test $_settle_job output paths disagreed with its list" >&2
        show_streams "$_settle_stdout" "$_settle_stderr"
        exit 1
    fi
    _settle_files=$(wc -l < "$_settle_list" | tr -d ' ')
    _settle_tests=$(sed -n 's/^TypeLisp test file: .* (\([0-9][0-9]*\) test(s))$/\1/p' \
        "$_settle_stdout" | tr -d '\r' | awk '{ total += $1 } END { print total + 0 }')
    if ! grep -qF \
        "TypeLisp test batch passed: $_settle_tests test(s) in $_settle_files file(s)" \
        "$_settle_stdout"; then
        echo "inline test $_settle_job did not report the expected aggregate" \
            "($_settle_tests test(s) in $_settle_files file(s))" >&2
        show_streams "$_settle_stdout" "$_settle_stderr"
        exit 1
    fi
    if [ -f "$_settle_dir/$_settle_job.combined" ] &&
        grep -qF 'test: --combined fallback to single-file mode' "$_settle_stderr"; then
        echo "[inline-tests] warning: $_settle_job fell back to single-file mode" >&2
    fi
    cat "$_settle_stdout" >> "$_settle_combined_stdout"
    cat "$_settle_stderr" >> "$_settle_combined_stderr"
}

# Checks over the combined chunk streams: one count line and one success
# summary per discovered source, exact partition completeness (every discovered
# source ran in exactly one chunk), and no source that ran zero tests.
inline_test_check_combined() {
    _check_discovered=$1
    _check_stdout=$2
    _check_stderr=$3
    _check_counts=$4
    _check_paths=$5
    _check_files=$(wc -l < "$_check_discovered" | tr -d ' ')
    sed -n 's/^TypeLisp test file: .* (\([0-9][0-9]*\) test(s))$/\1/p' "$_check_stdout" \
        | tr -d '\r' > "$_check_counts"
    sed -n 's/^TypeLisp test file: \(.*\) ([0-9][0-9]* test(s))$/\1/p' "$_check_stdout" \
        | tr -d '\r' > "$_check_paths"
    _check_count_lines=$(wc -l < "$_check_counts" | tr -d ' ')
    if [ "$_check_count_lines" -ne "$_check_files" ]; then
        echo "inline test execution reported $_check_count_lines count line(s), expected $_check_files" >&2
        show_streams "$_check_stdout" "$_check_stderr"
        exit 1
    fi
    LC_ALL=C sort "$_check_discovered" > "$_check_discovered.sorted"
    LC_ALL=C sort "$_check_paths" > "$_check_paths.sorted"
    if ! cmp -s "$_check_discovered.sorted" "$_check_paths.sorted"; then
        echo "inline test execution did not cover the exact discovered source set" >&2
        show_streams "$_check_stdout" "$_check_stderr"
        exit 1
    fi
    if grep -q '^0$' "$_check_counts"; then
        echo "inline test execution reported zero tests for a discovered source" >&2
        show_streams "$_check_stdout" "$_check_stderr"
        exit 1
    fi
    _check_success=$(grep -c '^TypeLisp tests: .* passed; 0 failed; .* ignored; .* slow-skipped; .* total$' "$_check_stderr" || true)
    if [ "$_check_success" -ne "$_check_files" ]; then
        echo "inline test execution reported $_check_success success summary line(s), expected $_check_files" >&2
        show_streams "$_check_stdout" "$_check_stderr"
        exit 1
    fi
}

# Fabricated chunk results for the accounting above: a well-formed set must
# pass, and each single mutation of it must fail.
inline_test_self_test_fixture() {
    _fixture_dir=$(mktemp -d "$INLINE_TEST_SELF_TEST_ROOT/case.XXXXXX")
    _self_dir=$_fixture_dir
    printf ';; light\n' > "$_fixture_dir/a.tl"
    printf ';; light\n' > "$_fixture_dir/b.tl"
    awk 'BEGIN { for (i = 0; i < 200; i++) print ";; heavy" }' > "$_fixture_dir/c.tl"
    printf '%s\n' "$_fixture_dir/a.tl" "$_fixture_dir/b.tl" "$_fixture_dir/c.tl" > "$_fixture_dir/discovered.txt"
    _fixture_saved_size=$INLINE_TEST_CHUNK_FILES
    _fixture_saved_target=$INLINE_TEST_CHUNK_TARGET_COUNT
    INLINE_TEST_CHUNK_FILES=2
    INLINE_TEST_CHUNK_TARGET_COUNT=0
    inline_test_plan_chunks "$_fixture_dir/discovered.txt" "$_fixture_dir" "$_fixture_dir/queue"
    INLINE_TEST_CHUNK_FILES=$_fixture_saved_size
    INLINE_TEST_CHUNK_TARGET_COUNT=$_fixture_saved_target
    for _fixture_job in chunk-001 chunk-002; do
        : > "$_fixture_dir/$_fixture_job.stdout"
        : > "$_fixture_dir/$_fixture_job.stderr"
        _fixture_tests=0
        _fixture_files=0
        while IFS= read -r _fixture_source; do
            printf 'TypeLisp test file: %s (2 test(s))\n' "$_fixture_source" \
                >> "$_fixture_dir/$_fixture_job.stdout"
            printf 'TypeLisp tests: 2 passed; 0 failed; 0 ignored; 0 slow-skipped; 2 total\n' \
                >> "$_fixture_dir/$_fixture_job.stderr"
            _fixture_tests=$((_fixture_tests + 2))
            _fixture_files=$((_fixture_files + 1))
        done < "$_fixture_dir/$_fixture_job.list"
        printf 'TypeLisp test batch passed: %s test(s) in %s file(s)\n' \
            "$_fixture_tests" "$_fixture_files" >> "$_fixture_dir/$_fixture_job.stdout"
        bounded_completion_fixture "$_fixture_dir/$_fixture_job.memory" \
            "$_fixture_dir/$_fixture_job.status" "$HOST_OS" "$INLINE_TEST_CHUNK_CAP_MIB" success
    done
}

inline_test_self_test_settle_all() {
    _all_dir=$1
    : > "$_all_dir/combined.stdout"
    : > "$_all_dir/combined.stderr"
    while IFS='|' read -r _all_job _all_cap; do
        inline_test_settle_chunk "$_all_job" "$_all_dir" \
            "$_all_dir/combined.stdout" "$_all_dir/combined.stderr" "$_all_cap"
    done < "$_all_dir/queue"
    inline_test_check_combined "$_all_dir/discovered.txt" \
        "$_all_dir/combined.stdout" "$_all_dir/combined.stderr" \
        "$_all_dir/counts" "$_all_dir/paths"
}

inline_test_self_test_expect_failure() {
    _expect_name=$1
    _expect_dir=$2
    if ( inline_test_self_test_settle_all "$_expect_dir" ) > "$_expect_dir/out" 2>&1; then
        echo "inline test chunk self-test: $_expect_name was accepted" >&2
        exit 1
    fi
}

# Record ordinary failures for ordered diagnostics; invalid bounded completion
# aborts admission immediately. Timing and all outputs belong to this job.
bounded_pool_run_job() {
    _pool_job=$1
    _pool_cap=$2
    if ci_timing_enabled; then
        TYPELISP_CI_TIMING_FILE="$INLINE_TEST_POOL_DIR/timing/$_pool_job.tsv"
    fi
    _pool_phase=batch-run
    set -- "$COMPILER" test --batch "$WORKDIR/$_pool_job.list"
    if [ -f "$WORKDIR/$_pool_job.combined" ]; then
        _pool_phase=batch-run-combined
        set -- "$@" --combined
    fi
    if [ -f "$WORKDIR/$_pool_job.no-prebuilt-stdlib" ]; then
        set -- "$@" --no-prebuilt-stdlib
    fi
    _pool_rc=0
    ci_timing_run "$_pool_job" "$_pool_phase" \
        "$ROOT/scripts/run-memory-bounded.sh" \
        --limit-mib "$_pool_cap" --report "$WORKDIR/$_pool_job.memory" \
        --timeout-seconds "$INLINE_TEST_JOB_TIMEOUT_SECONDS" -- \
        "$@" --target "$HOST_TARGET" \
        --stdlib-root "$ROOT/stdlib" --stdlib-root "$ROOT/src" \
        > "$WORKDIR/$_pool_job.stdout" 2> "$WORKDIR/$_pool_job.stderr" ||
        _pool_rc=$?
    printf '%s\n' "$_pool_rc" > "$WORKDIR/$_pool_job.status"
    if ! bounded_pool_read_report "$WORKDIR/$_pool_job.memory" "$_pool_rc" "$_pool_cap" "$HOST_OS"; then
        echo "inline test $_pool_job $BOUNDED_POOL_REPORT_FAILURE" \
            "(reason=$BOUNDED_POOL_REPORT_REASON, reported-exit=$BOUNDED_POOL_REPORT_EXIT_CODE)" >&2
        show_streams "$WORKDIR/$_pool_job.stdout" "$WORKDIR/$_pool_job.stderr"
        return 1
    fi
}

inline_test_self_test_chunks() {
    ci_timing_set_now_ms
    _inline_fixture_started=$CI_TIMING_NOW_MS
    . "$ROOT/scripts/lib-bounded-completion-fixtures.sh"
    mkdir -p "$ROOT/target/exp/inline-test-verify-self-test"
    INLINE_TEST_SELF_TEST_ROOT=$(mktemp -d "$ROOT/target/exp/inline-test-verify-self-test/run.XXXXXX")
    _self_dir=$INLINE_TEST_SELF_TEST_ROOT
    inline_test_self_test_fixture "$_self_dir"
    printf 'chunk-001|%s\nchunk-002|%s\n' "$INLINE_TEST_CHUNK_CAP_MIB" \
        "$INLINE_TEST_CHUNK_CAP_MIB" > "$_self_dir/expected-queue"
    if ! cmp -s "$_self_dir/queue" "$_self_dir/expected-queue" ||
        [ "$(head -n 1 "$_self_dir/chunk-001.list")" != "$_self_dir/c.tl" ] ||
        [ "$(cat "$_self_dir/chunk-001.list" "$_self_dir/chunk-002.list" | LC_ALL=C sort)" != "$(LC_ALL=C sort "$_self_dir/discovered.txt")" ]; then
        echo "inline test chunk self-test: the LPT plan did not schedule heaviest first or partition all sources" >&2
        exit 1
    fi
    if ! ( inline_test_self_test_settle_all "$_self_dir" ) > "$_self_dir/out" 2>&1; then
        echo "inline test chunk self-test: well-formed chunks were rejected" >&2
        sed 's/^/  /' "$_self_dir/out" >&2
        exit 1
    fi

    _tier_dir=$(mktemp -d "$INLINE_TEST_SELF_TEST_ROOT/tier.XXXXXX")
    printf ';; light\n' > "$_tier_dir/l1.tl"
    printf ';; light\n' > "$_tier_dir/l2.tl"
    printf ';; light\n' > "$_tier_dir/l3.tl"
    printf '%s\n' "$_tier_dir/l1.tl" "$_tier_dir/l2.tl" "$_tier_dir/l3.tl" > "$_tier_dir/discovered.txt"
    _tier_saved_size=$INLINE_TEST_CHUNK_FILES
    _tier_saved_target=$INLINE_TEST_CHUNK_TARGET_COUNT
    INLINE_TEST_CHUNK_FILES=3
    INLINE_TEST_CHUNK_TARGET_COUNT=0
    inline_test_plan_chunks "$_tier_dir/discovered.txt" "$_tier_dir" "$_tier_dir/queue"
    INLINE_TEST_CHUNK_FILES=$_tier_saved_size
    INLINE_TEST_CHUNK_TARGET_COUNT=$_tier_saved_target
    if [ "$(cat "$_tier_dir/queue")" != "chunk-001|$INLINE_TEST_LIGHT_CHUNK_CAP_MIB" ]; then
        echo "inline test chunk self-test: >=3-file light chunk did not get light cap" >&2
        exit 1
    fi

    _comb_dir=$(mktemp -d "$INLINE_TEST_SELF_TEST_ROOT/combined.XXXXXX")
    mkdir -p "$_comb_dir/src" "$_comb_dir/stdlib"
    printf '(defstruct Item (v i64))\n(test a unit)\n' > "$_comb_dir/src/a.tl"
    printf '(defstruct Other (v i64))\n(test b unit)\n' > "$_comb_dir/src/b.tl"
    printf '(defenum Item (V))\n(test c unit)\n' > "$_comb_dir/src/c.tl"
    printf '(test s1 unit)\n' > "$_comb_dir/stdlib/s1.tl"
    printf '(test s2 unit)\n' > "$_comb_dir/stdlib/s2.tl"
    (
        cd "$_comb_dir" || exit 1
        printf '%s\n' src/a.tl src/b.tl src/c.tl stdlib/s1.tl stdlib/s2.tl > discovered.txt
        INLINE_TEST_COMBINED_LIGHT_CHUNKS=1
        INLINE_TEST_COMBINED_STDLIB_CHUNKS=1
        inline_test_plan_chunks discovered.txt "$_comb_dir" "$_comb_dir/queue"
    )
    if [ ! -f "$_comb_dir/chunk-001.combined" ] ||
        [ -f "$_comb_dir/chunk-001.no-prebuilt-stdlib" ] ||
        [ ! -f "$_comb_dir/chunk-002.combined" ] ||
        [ ! -f "$_comb_dir/chunk-002.no-prebuilt-stdlib" ] ||
        [ -f "$_comb_dir/chunk-003.list" ] ||
        [ "$(cat "$_comb_dir"/chunk-*.list | LC_ALL=C sort)" != "$(printf '%s\n' src/a.tl src/b.tl src/c.tl stdlib/s1.tl stdlib/s2.tl)" ]; then
        echo "inline test chunk self-test: combined chunk planner did not group and partition sources" >&2
        exit 1
    fi

    _hm_dir=$(mktemp -d "$INLINE_TEST_SELF_TEST_ROOT/hashmap-no-prebuilt.XXXXXX")
    mkdir -p "$_hm_dir/tests/inline"
    printf '(test a unit)\n' > "$_hm_dir/tests/inline/hashmap_macro_aggregate_modules.tl"
    printf '(test b unit)\n' > "$_hm_dir/tests/inline/other_inline.tl"
    (
        cd "$_hm_dir" || exit 1
        printf '%s\n' tests/inline/hashmap_macro_aggregate_modules.tl tests/inline/other_inline.tl > discovered.txt
        inline_test_plan_chunks discovered.txt "$_hm_dir" "$_hm_dir/queue"
    )
    if [ ! -f "$_hm_dir/chunk-001.no-prebuilt-stdlib" ] ||
        [ "$(cat "$_hm_dir/chunk-001.list")" != "tests/inline/hashmap_macro_aggregate_modules.tl" ] ||
        [ -f "$_hm_dir/chunk-002.no-prebuilt-stdlib" ] ||
        [ "$(cat "$_hm_dir/chunk-002.list")" != "tests/inline/other_inline.tl" ]; then
        echo "inline test chunk self-test: hashmap_macro_aggregate_modules.tl was not isolated with --no-prebuilt-stdlib" >&2
        exit 1
    fi

    _reloc_dir=$(mktemp -d "$INLINE_TEST_SELF_TEST_ROOT/reloc.XXXXXX")
    mkdir -p "$_reloc_dir/src"
    awk 'BEGIN { for (i = 0; i < 60; i++) print ";; pad"; print "(test a unit)" }' > "$_reloc_dir/src/a_big.tl"
    printf '(import a_big)\n(test b unit)\n' > "$_reloc_dir/src/b_imp.tl"
    printf '(test c unit)\n' > "$_reloc_dir/src/c_pad.tl"
    printf '(test d unit)\n' > "$_reloc_dir/src/d_pad.tl"
    printf '(test e unit)\n' > "$_reloc_dir/src/e_pad.tl"
    printf '(test f unit)\n' > "$_reloc_dir/src/f_pad.tl"
    printf '(test g unit)\n' > "$_reloc_dir/src/g_pad.tl"
    printf '(test h unit)\n' > "$_reloc_dir/src/h_pad.tl"
    (
        cd "$_reloc_dir" || exit 1
        printf '%s\n' src/a_big.tl src/b_imp.tl src/c_pad.tl src/d_pad.tl src/e_pad.tl src/f_pad.tl src/g_pad.tl src/h_pad.tl > discovered.txt
        INLINE_TEST_COMBINED_LIGHT_CHUNKS=2
        inline_test_plan_chunks discovered.txt "$_reloc_dir" "$_reloc_dir/queue"
    )
    if [ "$(cat "$_reloc_dir"/chunk-*.list | LC_ALL=C sort)" != "$(printf '%s\n' src/a_big.tl src/b_imp.tl src/c_pad.tl src/d_pad.tl src/e_pad.tl src/f_pad.tl src/g_pad.tl src/h_pad.tl)" ]; then
        echo "inline test chunk self-test: leader relocation lost or duplicated a source" >&2
        exit 1
    fi
    if [ "$(head -n 1 "$_reloc_dir/chunk-001.list")" != "src/a_big.tl" ] ||
        grep -qxF 'src/b_imp.tl' "$_reloc_dir/chunk-001.list"; then
        echo "inline test chunk self-test: leader relocation did not move importer out of leader chunk" >&2
        exit 1
    fi

    # A large single_hub group must split across multiple balanced chunks when
    # its total split_weight exceeds INLINE_TEST_COMBINED_HUB_TARGET_WEIGHT, and
    # combined chunks must be emitted in descending weight order (LPT) in queue.
    _hub_dir=$(mktemp -d "$INLINE_TEST_SELF_TEST_ROOT/single-hub.XXXXXX")
    mkdir -p "$_hub_dir/src"
    awk 'BEGIN { for (i = 0; i < 40; i++) print ";; small hub" }' > "$_hub_dir/src/a_small_hub.tl"
    awk 'BEGIN { for (i = 0; i < 12000; i++) print ";; large hub" }' > "$_hub_dir/src/z_large_hub.tl"
    printf '(import a_small_hub)\n(test s1 unit)\n' > "$_hub_dir/src/s1.tl"
    printf '(import a_small_hub)\n(test s2 unit)\n' > "$_hub_dir/src/s2.tl"
    for _hf in t1 t2 t3 t4 t5 t6; do
        printf '(import z_large_hub)\n(test %s unit)\n' "$_hf" > "$_hub_dir/src/$_hf.tl"
    done
    (
        cd "$_hub_dir" || exit 1
        printf '%s\n' src/s1.tl src/s2.tl src/t1.tl src/t2.tl src/t3.tl src/t4.tl src/t5.tl src/t6.tl > discovered.txt
        INLINE_TEST_COMBINED_HUB_MIN_LINES=30
        INLINE_TEST_COMBINED_HUB_TARGET_WEIGHT=10000
        inline_test_plan_chunks discovered.txt "$_hub_dir" "$_hub_dir/queue"
    )
    if [ "$(cat "$_hub_dir"/chunk-*.list | LC_ALL=C sort)" != "$(printf '%s\n' src/s1.tl src/s2.tl src/t1.tl src/t2.tl src/t3.tl src/t4.tl src/t5.tl src/t6.tl)" ]; then
        echo "inline test chunk self-test: single_hub split lost or duplicated a source" >&2
        exit 1
    fi
    _hub_large_chunks=$(grep -l '^src/t[1-6]\.tl$' "$_hub_dir"/chunk-*.list | wc -l | tr -d ' ')
    if [ "$_hub_large_chunks" -lt 2 ]; then
        echo "inline test chunk self-test: oversized single_hub group did not split (got $_hub_large_chunks chunk(s))" >&2
        exit 1
    fi
    _hub_first_job=$(head -n 1 "$_hub_dir/queue" | cut -d '|' -f 1)
    _hub_last_job=$(tail -n 1 "$_hub_dir/queue" | cut -d '|' -f 1)
    if ! grep -q '^src/t[1-6]\.tl$' "$_hub_dir/$_hub_first_job.list" ||
        ! grep -q '^src/s[12]\.tl$' "$_hub_dir/$_hub_last_job.list"; then
        echo "inline test chunk self-test: combined chunks were not ordered by descending weight (LPT)" >&2
        cat "$_hub_dir/queue" >&2
        exit 1
    fi

    inline_test_self_test_fixture "$_self_dir"
    mv "$_self_dir/chunk-002.status" "$_self_dir/chunk-002.status.saved"
    inline_test_self_test_expect_failure "a chunk without a status" "$_self_dir"

    inline_test_self_test_fixture "$_self_dir"
    printf '1\n' > "$_self_dir/chunk-001.status"
    inline_test_self_test_expect_failure "a failed chunk" "$_self_dir"

    inline_test_self_test_fixture "$_self_dir"
    printf 'reason=memory-limit\npeak_memory_bytes=1048576\n' > "$_self_dir/chunk-002.memory"
    inline_test_self_test_expect_failure "a chunk stopped by its cap" "$_self_dir"

    inline_test_self_test_fixture "$_self_dir"
    mv "$_self_dir/chunk-001.memory" "$_self_dir/chunk-001.memory.saved"
    inline_test_self_test_expect_failure "a chunk without a memory report" "$_self_dir"

    inline_test_self_test_fixture "$_self_dir"
    sed -i.bak 's/in 2 file(s)/in 1 file(s)/' "$_self_dir/chunk-001.stdout"
    inline_test_self_test_expect_failure "a chunk aggregate that disagrees with its list" "$_self_dir"

    inline_test_self_test_fixture "$_self_dir"
    printf 'z.tl\n' > "$_self_dir/chunk-002.list"
    sed -i.bak 's|[^ ]*b\.tl|z.tl|' "$_self_dir/chunk-002.stdout"
    inline_test_self_test_expect_failure "a chunk that ran a source outside the discovered list" "$_self_dir"

    inline_test_self_test_fixture "$_self_dir"
    sed -i.bak 's|[^ ]*b\.tl|z.tl|' "$_self_dir/chunk-002.stdout"
    inline_test_self_test_expect_failure "a chunk whose output paths disagreed with its list" "$_self_dir"

    inline_test_self_test_fixture "$_self_dir"
    printf 'chunk-001|%s\nchunk-001|%s\n' "$INLINE_TEST_CHUNK_CAP_MIB" \
        "$INLINE_TEST_CHUNK_CAP_MIB" > "$_self_dir/queue"
    inline_test_self_test_expect_failure "duplicate chunk skipping a discovered source" "$_self_dir"

    inline_test_self_test_fixture "$_self_dir"
    sed -i.bak 's/ 0 failed;/ 1 failed;/' "$_self_dir/chunk-002.stderr"
    inline_test_self_test_expect_failure "a source whose tests did not all pass" "$_self_dir"

    # Plausible passing stdout must not survive a cancelled or invalid attempt.
    # Ordinary failures retain diagnostics rather than successful summaries.
    ci_timing_set_now_ms
    _inline_matrix_started=$CI_TIMING_NOW_MS
    bounded_completion_fixture_matrix "$HOST_OS"
    _completion_checks="$INLINE_TEST_SELF_TEST_ROOT/checks.tsv"
    : > "$_completion_checks"
    set --
    for _completion_host in $BOUNDED_COMPLETION_HOSTS; do
        for _completion_case in $BOUNDED_COMPLETION_CASES; do
            set -- "$@" "$INLINE_TEST_SELF_TEST_ROOT/worker-$_completion_host-$_completion_case" \
                "$INLINE_TEST_SELF_TEST_ROOT/reader-$_completion_host-$_completion_case"
        done
    done
    mkdir -p "$@"
    for _completion_host in $BOUNDED_COMPLETION_HOSTS; do
        for _completion_case in $BOUNDED_COMPLETION_CASES; do
            _worker_dir="$INLINE_TEST_SELF_TEST_ROOT/worker-$_completion_host-$_completion_case"
            if ! bounded_completion_worker_fixture inline "$_worker_dir" "$_completion_host" \
                "$INLINE_TEST_CHUNK_CAP_MIB" "$_completion_case" > "$_worker_dir.log" 2>&1; then
                echo "inline worker fixture failed: $_completion_host/$_completion_case" >&2
                cat "$_worker_dir.log" >&2
                exit 1
            fi
            (
                HOST_OS=$_completion_host
                _self_dir="$INLINE_TEST_SELF_TEST_ROOT/reader-$_completion_host-$_completion_case"
                # The completion reader consumes only chunk-001. Retain that
                # chunk from the full accounting fixture exactly; its planner,
                # second chunk and complete accounting are exercised above.
                printf 'a.tl\nb.tl\n' > "$_self_dir/chunk-001.list"
                printf '%s\n' \
                    'TypeLisp test file: a.tl (2 test(s))' \
                    'TypeLisp test file: b.tl (2 test(s))' \
                    'TypeLisp test batch passed: 4 test(s) in 2 file(s)' \
                    > "$_self_dir/chunk-001.stdout"
                printf '%s\n' \
                    'TypeLisp tests: 2 passed; 0 failed; 0 ignored; 0 slow-skipped; 2 total' \
                    'TypeLisp tests: 2 passed; 0 failed; 0 ignored; 0 slow-skipped; 2 total' \
                    > "$_self_dir/chunk-001.stderr"
                bounded_completion_fixture "$_self_dir/chunk-001.memory" \
                    "$_self_dir/chunk-001.status" "$HOST_OS" "$INLINE_TEST_CHUNK_CAP_MIB" "$_completion_case"
                : > "$_self_dir/combined.stdout"
                : > "$_self_dir/combined.stderr"
                _completion_rc=0
                ( inline_test_settle_chunk chunk-001 "$_self_dir" \
                    "$_self_dir/combined.stdout" "$_self_dir/combined.stderr" ) \
                    > "$_self_dir/reader.log" 2>&1 || _completion_rc=$?
                if [ "$_completion_case" = success ]; then
                    [ "$_completion_rc" -eq 0 ] && [ -s "$_self_dir/combined.stdout" ] || exit 1
                else
                    [ "$_completion_rc" -ne 0 ] && [ ! -s "$_self_dir/combined.stdout" ] || exit 1
                    case $_completion_case in
                        command-*)
                            bounded_completion_fixture_expect "$_completion_checks" "$_completion_host/$_completion_case" contains \
                                "$_self_dir/reader.log" 'batch execution failed' ;;
                    esac
                fi
            ) || { echo "inline completion fixture failed: $_completion_host/$_completion_case" >&2; exit 1; }
        done
    done
    bounded_completion_fixture_check "$_completion_checks" || exit 1
    ci_timing_set_now_ms
    bounded_completion_fixture_cost inline-tests \
        "$((_inline_matrix_started - _inline_fixture_started))" \
        "$((CI_TIMING_NOW_MS - _inline_matrix_started))" || exit 1
    echo "[inline-tests] chunk accounting self-test passed"
}

inline_test_self_test_chunks
[ "$SELF_TEST_ONLY" -eq 0 ] || exit 0

. "$ROOT/scripts/lib-gate.sh"
gate_compiler
gate_require_compiler

WORKDIR="$ROOT/target/inline-test-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

DISCOVERED_RAW="$WORKDIR/discovered.raw"
DISCOVERED="$WORKDIR/discovered.txt"
: > "$DISCOVERED_RAW"
: > "$DISCOVERED"

set --
for root in src stdlib tools tests/integration tests/inline examples; do
    if [ -d "$root" ]; then
        set -- "$@" "$root"
    fi
done
if [ "$#" -gt 0 ]; then
    discover_rc=0
    grep -rlE --include='*.tl' --exclude-dir=target \
        '^[[:space:]]*\(test([[:space:]]|\)|$)' "$@" > "$DISCOVERED_RAW" ||
        discover_rc=$?
    if [ "$discover_rc" -gt 1 ]; then
        echo "inline test discovery failed (grep exit $discover_rc)" >&2
        exit "$discover_rc"
    fi
    LC_ALL=C sort -u "$DISCOVERED_RAW" > "$DISCOVERED"
fi

if [ ! -s "$DISCOVERED" ]; then
    echo "inline test verification found no inline test-bearing TypeLisp files" >&2
    exit 1
fi

discovered_file_count=$(wc -l < "$DISCOVERED" | tr -d ' ')

# Fixed-array `(init)` expanding the profile-summary tables into thousands of
# initializer AST nodes makes this single inline test's memory explode. A
# focused Linux hard-cap probe runs ahead of the aggregate batch so that
# regression fails deterministically without asking an uncapped runner to OOM.
#
# RLIMIT_AS is unsuitable here: the runtime reserves large virtual mappings,
# so `ulimit -v` can fail while RSS remains below 200 MiB. The helper applies a
# cgroup-v2 MemoryMax over the complete process tree and needs a usable user
# systemd manager.
if [ "$HOST_OS" = linux ]; then
    profile_summary_stdout="$WORKDIR/profile-summary.stdout"
    profile_summary_stderr="$WORKDIR/profile-summary.stderr"
    profile_summary_limit_bytes=1073741824
    linux_memory_limit_select_backend
    echo "[inline-tests] profile-summary memory cap (1 GiB resident/cgroup memory; $LINUX_MEMORY_LIMIT_BACKEND)"
    if linux_memory_limit_run "$profile_summary_limit_bytes" \
        "$COMPILER" test "$ROOT/src/compiler_profile_summary.tl" \
            --target "$HOST_TARGET" --stdlib-root "$ROOT/stdlib" \
            > "$profile_summary_stdout" 2> "$profile_summary_stderr"; then
        profile_summary_status=0
    else
        profile_summary_status=$?
    fi
    if [ "$profile_summary_status" -ne 0 ]; then
        echo "compiler_profile_summary inline test exceeded 1 GiB of resident/cgroup memory or failed" >&2
        show_streams "$profile_summary_stdout" "$profile_summary_stderr"
        exit 1
    fi
fi

run_stdout="$WORKDIR/run.batch.stdout"
run_stderr="$WORKDIR/run.batch.stderr"
run_counts="$WORKDIR/run.counts.txt"
run_paths="$WORKDIR/run.paths.txt"
INLINE_TEST_QUEUE="$WORKDIR/queue"
INLINE_TEST_POOL_DIR="$WORKDIR/pool"

# Publish the jobs' private timing rows in queue order. A passing pool requires
# a row from every job; a failing one still publishes what ran.
inline_test_merge_pool_timing() {
    ci_timing_enabled || return 0
    while IFS='|' read -r _merge_job _merge_cap; do
        _merge_rows="$INLINE_TEST_POOL_DIR/timing/$_merge_job.tsv"
        if [ -s "$_merge_rows" ]; then
            cat "$_merge_rows" >> "$TYPELISP_CI_TIMING_FILE"
        elif [ "$1" = required ]; then
            echo "inline test pool job published no timing row: $_merge_job" >&2
            exit 1
        fi
    done < "$INLINE_TEST_QUEUE"
}

inline_test_plan_chunks "$DISCOVERED" "$WORKDIR" "$INLINE_TEST_QUEUE"
chunk_count=$(wc -l < "$INLINE_TEST_QUEUE" | tr -d ' ')
bounded_pool_init "$INLINE_TEST_POOL_DIR" "$INLINE_TEST_POOL_BUDGET_MIB" \
    "$INLINE_TEST_QUEUE" || exit 1
mkdir -p "$INLINE_TEST_POOL_DIR/timing"

echo "[inline-tests] run ($discovered_file_count file(s) in $chunk_count chunk(s)" \
    "of up to $INLINE_TEST_CHUNK_FILES, $INLINE_TEST_WORKERS worker(s)," \
    "$INLINE_TEST_POOL_BUDGET_MIB MiB of enforced caps at once)"
# Execution batches keep every source inside its own destroyable scratch arena
# with a full driver reset, preserving one-process-per-file semantics without
# paying process/bootstrap overhead for every source.
ci_timing_set_now_ms
pool_started=$CI_TIMING_NOW_MS
bounded_pool_start "$INLINE_TEST_POOL_DIR" "$INLINE_TEST_WORKERS"
if ! bounded_pool_join "$INLINE_TEST_POOL_DIR"; then
    inline_test_merge_pool_timing available
    echo "inline test chunk pool did not complete every chunk" >&2
    exit 1
fi
ci_timing_set_now_ms
pool_wall_ms=$((CI_TIMING_NOW_MS - pool_started))
inline_test_merge_pool_timing required

: > "$run_stdout"
: > "$run_stderr"
while IFS='|' read -r settle_job settle_cap; do
    inline_test_settle_chunk "$settle_job" "$WORKDIR" "$run_stdout" "$run_stderr" "$settle_cap"
done < "$INLINE_TEST_QUEUE"
inline_test_check_combined "$DISCOVERED" "$run_stdout" "$run_stderr" \
    "$run_counts" "$run_paths"

test_count=$(awk '{ total += $1 } END { print total + 0 }' "$run_counts")
echo "[inline-tests] $chunk_count chunk(s) in $pool_wall_ms ms;" \
    "peak $((INLINE_TEST_PEAK_BYTES / 1048576)) MiB ($INLINE_TEST_PEAK_JOB)" \
    "of a $INLINE_TEST_PEAK_CAP_MIB MiB cap"
echo "inline test verification passed for $test_count test(s) in $discovered_file_count file(s)"

#!/usr/bin/env sh

# A chunk belongs to exactly one compiler invocation (target, cfg, backend,
# optimization and ordered roots). Only equal input paths inside that invocation
# may share an output. Keep the original case records for every byte comparison.
# There is no cross-chunk, cross-producer or on-disk cache lookup.
build_invariance_chunk_is_selfhost() {
    [ "$(wc -l < "$1" | tr -d ' ')" -eq 1 ] || return 1
    case "$(awk -F'|' 'NR == 1 { print $1; exit }' "$1")" in
        selfhost_main_opt1 | selfhost_main_opt2) return 0 ;;
    esac
    return 1
}

build_invariance_chunk_timeout_seconds() {
    # Selfhost compiles previously had only the workflow deadline. Give these
    # larger workloads their own bound when admitting them to the pool.
    if build_invariance_chunk_is_selfhost "$1"; then
        printf '1200\n'
    else
        printf '600\n'
    fi
}

build_invariance_plan_chunk() {
    _bib_cases=$1
    _bib_entries=$2
    _bib_aliases=$3
    _bib_opt=$4
    _bib_output_dir=$5
    : > "$_bib_entries"
    : > "$_bib_aliases"
    awk -F '|' -v entries="$_bib_entries" -v aliases="$_bib_aliases" \
        -v opt="$_bib_opt" -v output_dir="$_bib_output_dir" '
        function fail(message) {
            print "[build-invariance] invalid chunk: " message > "/dev/stderr"
            failed = 1
            exit 1
        }
        {
            if (NF != 5 || $1 !~ /^[A-Za-z0-9_-]+$/ || $2 == "" || $3 == "")
                fail("malformed case record")
            if ($5 !~ /^[12]$/ || $5 != opt || (opt != 1 && opt != 2))
                fail("optimization identity differs")
            if ($4 != output_dir "/" $1 ".s")
                fail("output does not belong to this producer")
            if (names[$1]++) fail("duplicate logical case " $1)
            if (++count > 64) fail("more than 64 logical cases")
            if ($3 in canonical) {
                print canonical[$3] "|" $4 > aliases
            } else {
                canonical[$3] = $4
                print $3 "|" $4 > entries
            }
        }
        END {
            if (!failed && count == 0) fail("empty chunk")
        }
    ' "$_bib_cases"
}

build_invariance_require_plan() {
    _bib_require_cases=$1
    _bib_require_entries=$2
    _bib_require_aliases=$3
    build_invariance_plan_chunk "$_bib_require_cases" \
        "$_bib_require_entries.expected" "$_bib_require_aliases.expected" "$4" "$5" || return 1
    if ! cmp -s "$_bib_require_entries" "$_bib_require_entries.expected" ||
        ! cmp -s "$_bib_require_aliases" "$_bib_require_aliases.expected"; then
        echo "[build-invariance] chunk plan differs from logical coverage" >&2
        return 1
    fi
    # Retain the reconstructed plans as evidence beside the executed plans.
}

# Compare the multiset of executed logical records with the complete prepared
# inventory, and that inventory with the authoritative corpus. Counts alone
# cannot detect a duplicated chunk substituted for a missing one.
build_invariance_require_coverage() {
    _bib_coverage_corpus=$1
    _bib_coverage_root=$2
    _bib_coverage_cases="$_bib_coverage_root/cases.txt"
    if ! awk -F '|' 'NF != 3 || $1 == "" || seen[$1]++ { exit 1 }
        { count++ } END { if (count == 0) exit 1 }' \
        "$_bib_coverage_corpus"; then
        echo "[build-invariance] malformed or duplicate corpus case" >&2
        return 1
    fi
    LC_ALL=C sort "$_bib_coverage_corpus" > "$_bib_coverage_root/coverage.corpus"
    awk -F '|' '{ print $1 "|" $2 "|" $5 }' "$_bib_coverage_cases" |
        LC_ALL=C sort > "$_bib_coverage_root/coverage.prepared"
    if ! cmp -s "$_bib_coverage_root/coverage.corpus" "$_bib_coverage_root/coverage.prepared"; then
        echo "[build-invariance] prepared inventory differs from corpus" >&2
        return 1
    fi
    : > "$_bib_coverage_root/coverage.chunks"
    for _bib_coverage_opt in 1 2; do
        for _bib_coverage_chunk in "$_bib_coverage_root/opt$_bib_coverage_opt/chunks"/cases.*.txt; do
            [ -f "$_bib_coverage_chunk" ] || continue
            cat "$_bib_coverage_chunk" >> "$_bib_coverage_root/coverage.chunks" || return 1
        done
    done
    LC_ALL=C sort "$_bib_coverage_cases" > "$_bib_coverage_root/coverage.expected"
    LC_ALL=C sort "$_bib_coverage_root/coverage.chunks" > "$_bib_coverage_root/coverage.actual"
    if ! cmp -s "$_bib_coverage_root/coverage.expected" "$_bib_coverage_root/coverage.actual"; then
        echo "[build-invariance] chunk coverage differs from prepared inventory" >&2
        return 1
    fi
}

build_invariance_copy_aliases() {
    _bib_alias_file=$1
    while IFS='|' read -r _bib_original _bib_alias; do
        if [ ! -f "$_bib_original" ] || [ ! -s "$_bib_original" ] ||
            [ -L "$_bib_original" ]; then
            echo "[build-invariance] missing fresh canonical assembly: $_bib_original" >&2
            return 1
        fi
        if [ -e "$_bib_alias" ] || [ -L "$_bib_alias" ]; then
            echo "[build-invariance] alias output already exists: $_bib_alias" >&2
            return 1
        fi
        cp "$_bib_original" "$_bib_alias" || return 1
        if ! cmp -s "$_bib_original" "$_bib_alias"; then
            echo "[build-invariance] alias assembly differs: $_bib_alias" >&2
            return 1
        fi
    done < "$_bib_alias_file"
}

# Compute transitive LOC for every unique `src/` path in column 2 of a corpus or
# prepared-cases file, writing `source|loc` rows (or `-1` if unreadable).
# Uses the same import-closure traversal as verify-integration.sh so heavy
# compiler-importing tests are isolated and right-sized without hardcoding names.
build_invariance_write_src_weights() {
    _bib_weight_input=$1
    _bib_weight_out=$2
    _bib_weight_root=${3:-.}
    awk -F'|' -v root="$_bib_weight_root" '
        function full_path(rel) {
            if (root == "" || root == ".") return rel
            return root "/" rel
        }
        function resolve_mod(mod,    p, fp, _line) {
            if (mod ~ /^stdlib\./ || mod == "stdlib") return ""
            p = "src" "/" mod ".tl"
            fp = full_path(p)
            if ((getline _line < fp) >= 0) {
                close(fp)
                return p
            }
            p = "src" "/tests/" mod ".tl"
            fp = full_path(p)
            if ((getline _line < fp) >= 0) {
                close(fp)
                return p
            }
            p = mod
            gsub(/\./, "/", p)
            p = p ".tl"
            fp = full_path(p)
            if ((getline _line < fp) >= 0) {
                close(fp)
                return p
            }
            return ""
        }
        function scan_file(path,    fp, line, n, mod, dep, i, in_str, ch, esc, k, len, rc) {
            if (path in scanned) return
            scanned[path] = 1
            n = 0
            deg[path] = 0
            in_str = 0
            fp = full_path(path)
            rc = (getline line < fp)
            if (rc < 0) {
                lines[path] = -1
                return
            }
            while (rc > 0) {
                n++
                if (!in_str && line ~ /^[[:space:]]*(\(cfg[[:space:]]+[^()]+[[:space:]]+)?\(import[[:space:]]+/) {
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
                rc = (getline line < fp)
            }
            close(fp)
            lines[path] = n
            for (i = 1; i <= deg[path]; i++) {
                scan_file(edge[path, i])
            }
        }
        function trans_loc(src,    qhead, qtail, u, v, i, tot, vis, q) {
            if (src == "") return -1
            if (src in cache) return cache[src]
            scan_file(src)
            if (lines[src] <= 0) {
                cache[src] = -1
                return -1
            }
            qhead = 1
            qtail = 1
            q[1] = src
            vis[src] = 1
            tot = 0
            while (qhead <= qtail) {
                u = q[qhead++]
                if (lines[u] > 0) tot += lines[u]
                for (i = 1; i <= deg[u]; i++) {
                    v = edge[u, i]
                    if (!(v in vis)) {
                        vis[v] = 1
                        q[++qtail] = v
                    }
                }
            }
            cache[src] = tot
            return tot
        }
        $2 ~ /^src\// && !emitted[$2]++ {
            print $2 "|" trans_loc($2)
        }
    ' "$_bib_weight_input" > "$_bib_weight_out"
}

# A large source remains the only unique input in its process. Consecutive
# logical aliases of that input share the fresh output through the ordinary
# chunk planner; they still count toward the logical-case ceiling. Sources
# under src/ import the compiler itself and never share a chunk with test
# programs, so one slow compiler-source chunk cannot carry a test-program tail
# and a test-program chunk keeps the light memory class. Any src/ source with
# >100k transitive LOC is isolated as a singleton so heavy non-compiler_* tests
# cannot pile into one multi-entry straggler chunk.
#
# When `use_src_core_tli=1`, eligible src/ test entries hydrate compiler modules
# from the producer's byte-verified `src_core.tli` via `--extra-tli`. Those
# entries never mix with full-source src/ entries or non-src/ test programs,
# and pack up to 10 cases per chunk so 4 workers run them in parallel well
# within 2048 MiB. Selfhost main compiles, the 8 GiB codegen/backend memory
# gates, and the three tests invoking `: Decls`-generated macros stay on full
# source.
build_invariance_source_uses_src_core_tli() {
    _bib_tli_name=$1
    _bib_tli_source=$2
    case "$_bib_tli_name" in
        selfhost_main_*) return 1 ;;
    esac
    case "$_bib_tli_source" in
        src/*) ;;
        *) return 1 ;;
    esac
    case "$_bib_tli_source" in
        src/main.tl | \
        src/tests/compiler_codegen_smoke_suite.tl | \
        src/tests/compiler_backend_smoke.tl | \
        src/tests/compiler_frontend_smoke_suite.tl | \
        src/tests/compiler_parse_smoke.tl | \
        src/tests/tlci_loader_smoke.tl)
            return 1
            ;;
    esac
    return 0
}

# Fail-closed check: every row in a chunk must be src_core.tli-eligible before
# the runner may pass `--extra-tli`.
build_invariance_chunk_uses_src_core_tli() {
    awk -F'|' '
        NF != 5 { exit 1 }
        $1 ~ /^selfhost_main_/ { exit 1 }
        $2 !~ /^src\// { exit 1 }
        $2 == "src/main.tl" ||
            $2 == "src/tests/compiler_codegen_smoke_suite.tl" ||
            $2 == "src/tests/compiler_backend_smoke.tl" ||
            $2 == "src/tests/compiler_frontend_smoke_suite.tl" ||
            $2 == "src/tests/compiler_parse_smoke.tl" ||
            $2 == "src/tests/tlci_loader_smoke.tl" { exit 1 }
        END { if (NR == 0) exit 1 }
    ' "$1"
}

build_invariance_write_chunks() {
    _bib_chunk_records=$1
    _bib_chunk_dir=$2
    _bib_chunk_size=$3
    _bib_chunk_weights=${4:-}
    _bib_chunk_root=${5:-.}
    _bib_chunk_src_core_tli=${6:-0}
    # A new invocation gets a fresh directory. Reject stale plans rather than
    # deleting a caller-supplied path or accidentally reusing earlier chunks.
    if ! mkdir "$_bib_chunk_dir"; then
        echo "[build-invariance] chunk directory must be fresh: $_bib_chunk_dir" >&2
        return 1
    fi
    _bib_chunk_tmp_weights=""
    if [ -z "$_bib_chunk_weights" ]; then
        _bib_chunk_tmp_weights="$_bib_chunk_dir/.src-weights.tmp"
        build_invariance_write_src_weights "$_bib_chunk_records" "$_bib_chunk_tmp_weights" "$_bib_chunk_root" || {
            rm -f -- "$_bib_chunk_tmp_weights"
            return 1
        }
        _bib_chunk_weights=$_bib_chunk_tmp_weights
    fi
    awk -F'|' -v chunk_dir="$_bib_chunk_dir" -v chunk_size="$_bib_chunk_size" \
        -v weights_file="$_bib_chunk_weights" \
        -v use_src_core_tli="$_bib_chunk_src_core_tli" '
        BEGIN {
            if (weights_file != "") {
                while ((getline wline < weights_file) > 0) {
                    sep = index(wline, "|")
                    if (sep > 1) {
                        src_loc[substr(wline, 1, sep - 1)] = substr(wline, sep + 1) + 0
                    }
                }
                close(weights_file)
            }
            hydrated_limit = (chunk_size < 10 ? chunk_size : 10)
        }
        function compiler_source(source) {
            return source ~ /^src\//
        }
        function hydrated_src_source(name, source) {
            if (!use_src_core_tli) return 0
            if (name ~ /^selfhost_main_/) return 0
            if (!compiler_source(source)) return 0
            if (source == "src/main.tl" ||
                source == "src/tests/compiler_codegen_smoke_suite.tl" ||
                source == "src/tests/compiler_backend_smoke.tl" ||
                source == "src/tests/compiler_frontend_smoke_suite.tl" ||
                source == "src/tests/compiler_parse_smoke.tl" ||
                source == "src/tests/tlci_loader_smoke.tl") {
                return 0
            }
            return 1
        }
        function singleton(name, source) {
            if (hydrated_src_source(name, source)) return 0
            return name ~ /^selfhost_main_/ ||
                source ~ /^src\/tests\/compiler_[^/]*\.tl$/ ||
                (compiler_source(source) && (source in src_loc) && src_loc[source] > 100000)
        }
        function lane_of(name, source) {
            if (hydrated_src_source(name, source)) return 2
            if (compiler_source(source)) return 1
            return 0
        }
        function finish_chunk() {
            if (chunk_entries > 0) {
                close(cases_path)
                chunk_index += 1
                chunk_entries = 0
            }
        }
        $1 != "" {
            alone = singleton($1, $2)
            lane = lane_of($1, $2)
            if (chunk_entries > 0 && (alone || chunk_alone) &&
                !(alone && chunk_alone && $3 == chunk_source && $5 == chunk_opt)) {
                finish_chunk()
            }
            if (chunk_entries > 0 && lane != chunk_lane) finish_chunk()
            if (chunk_entries == 0) {
                cases_path = chunk_dir "/cases." sprintf("%04d", chunk_index) ".txt"
                chunk_source = $3
                chunk_opt = $5
                chunk_alone = alone
                chunk_lane = lane
                chunk_limit = (lane == 2 ? hydrated_limit : chunk_size)
            }
            print $0 >> cases_path
            chunk_entries += 1
            if (chunk_entries >= chunk_limit) finish_chunk()
        }
        END { finish_chunk() }
    ' "$_bib_chunk_records"
    _bib_write_rc=$?
    if [ -n "$_bib_chunk_tmp_weights" ]; then
        rm -f -- "$_bib_chunk_tmp_weights"
    fi
    return "$_bib_write_rc"
}

# Several logical aliases still represent one complete smoke compilation.
# Classify every row so an unrelated input cannot borrow its memory class.
build_invariance_chunk_is_codegen_smoke() {
    awk -F'|' '
        NF != 5 || $3 != "src/tests/compiler_codegen_smoke_suite.tl" { exit 1 }
        END { if (NR == 0) exit 1 }
    ' "$1"
}

# Pool admission of one producer's chunk, printed as `CAP_MIB RANK`. Every
# chunk runs under its hard cap; the classes follow measured hosted peaks with
# >= 1.8x headroom. The opt1-built complete codegen smoke (3.5 GiB) keeps the
# full 8 GiB ownership-regression cap; whole-compiler opt2 selfhost compiles
# (3.7 GiB) get 6 GiB; the opt1 selfhost compile (1.1 GiB) and opt2-built
# codegen smoke get 4 GiB. Hydrated `src/` test chunks using `--extra-tli
# src_core.tli` (measured <= 1.05 GiB across all 43 entries at once) get
# 2048 MiB (rank 5). Full-source `src/` chunks use 3-tier right-sized caps by
# max transitive LOC across their src/ entries (fail-closed to 4 GiB if any
# src/ entry is unmeasured): >400k LOC -> 4096 MiB (rank 3), 100k-400k LOC ->
# 3072 MiB (rank 4, peaks <1.65 GiB), <100k LOC -> 2048 MiB (rank 5, peaks
# <730 MiB). Chunks of test programs alone (under 0.6 GiB) get 2048 MiB (rank 6).
# Within each rank/producer, check-build-invariance.sh orders chunks LPT
# (heaviest-first) by build_invariance_chunk_weight so 4 workers pack cleanly
# inside 14336 MiB without a long compile running alone at the tail.
build_invariance_chunk_class() {
    _bib_class_chunk=$1
    _bib_class_producer=$2
    _bib_class_weights=${3:-}
    _bib_class_root=${4:-.}
    _bib_class_src_core_tli=${5:-0}
    if build_invariance_chunk_is_codegen_smoke "$_bib_class_chunk"; then
        if [ "$_bib_class_producer" = opt1-built ]; then
            printf '8192 2\n'
        else
            printf '4096 2\n'
        fi
    elif build_invariance_chunk_is_selfhost "$_bib_class_chunk"; then
        case "$(awk -F'|' 'NR == 1 { print $1; exit }' "$_bib_class_chunk")" in
            selfhost_main_opt2) printf '6144 1\n' ;;
            *) printf '4096 4\n' ;;
        esac
    elif [ "$_bib_class_src_core_tli" -eq 1 ] && build_invariance_chunk_uses_src_core_tli "$_bib_class_chunk"; then
        printf '2048 5\n'
    elif awk -F'|' '$2 ~ /^src\// { found = 1; exit } END { exit !found }' "$_bib_class_chunk"; then
        _bib_class_tmp_weights=""
        if [ -z "$_bib_class_weights" ]; then
            _bib_class_tmp_weights="${_bib_class_chunk}.src-weights.$$"
            build_invariance_write_src_weights "$_bib_class_chunk" "$_bib_class_tmp_weights" "$_bib_class_root" || {
                rm -f -- "$_bib_class_tmp_weights"
                return 1
            }
            _bib_class_weights=$_bib_class_tmp_weights
        fi
        awk -F'|' -v weights_file="$_bib_class_weights" '
            BEGIN {
                if (weights_file != "") {
                    while ((getline wline < weights_file) > 0) {
                        sep = index(wline, "|")
                        if (sep > 1) {
                            src_loc[substr(wline, 1, sep - 1)] = substr(wline, sep + 1) + 0
                        }
                    }
                    close(weights_file)
                }
                max_loc = 0
                unmeasured = 0
            }
            $2 ~ /^src\// {
                if (!($2 in src_loc) || src_loc[$2] <= 0) {
                    unmeasured = 1
                } else if (src_loc[$2] > max_loc) {
                    max_loc = src_loc[$2]
                }
            }
            END {
                if (unmeasured || max_loc > 400000) {
                    print "4096 3"
                } else if (max_loc >= 100000) {
                    print "3072 4"
                } else {
                    print "2048 5"
                }
            }
        ' "$_bib_class_chunk"
        _bib_class_rc=$?
        if [ -n "$_bib_class_tmp_weights" ]; then
            rm -f -- "$_bib_class_tmp_weights"
        fi
        return "$_bib_class_rc"
    else
        printf '2048 6\n'
    fi
}

# LPT scheduling weight for one chunk: sum of transitive LOC across unique
# inputs (since aliases share the canonical compile), falling back to source
# line count or unique entry count for non-src/ chunks.
build_invariance_chunk_weight() {
    _bib_cw_chunk=$1
    _bib_cw_weights=${2:-}
    _bib_cw_root=${3:-.}
    _bib_cw_tmp_weights=""
    if [ -z "$_bib_cw_weights" ]; then
        _bib_cw_tmp_weights="${_bib_cw_chunk}.src-weights.$$"
        build_invariance_write_src_weights "$_bib_cw_chunk" "$_bib_cw_tmp_weights" "$_bib_cw_root" || {
            rm -f -- "$_bib_cw_tmp_weights"
            return 1
        }
        _bib_cw_weights=$_bib_cw_tmp_weights
    fi
    awk -F'|' -v weights_file="$_bib_cw_weights" -v root="$_bib_cw_root" '
        BEGIN {
            if (weights_file != "") {
                while ((getline wline < weights_file) > 0) {
                    sep = index(wline, "|")
                    if (sep > 1) {
                        src_loc[substr(wline, 1, sep - 1)] = substr(wline, sep + 1) + 0
                    }
                }
                close(weights_file)
            }
            total = 0
        }
        $1 != "" && !seen_input[$3]++ {
            if (($2 in src_loc) && src_loc[$2] > 0) {
                total += src_loc[$2]
            } else {
                fp = (root == "" || root == ".") ? $2 : (root "/" $2)
                n = 0
                while ((getline _l < fp) > 0) n++
                close(fp)
                total += (n > 0 ? n : 1)
            }
        }
        END { print total + 0 }
    ' "$_bib_cw_chunk"
    _bib_cw_rc=$?
    if [ -n "$_bib_cw_tmp_weights" ]; then
        rm -f -- "$_bib_cw_tmp_weights"
    fi
    return "$_bib_cw_rc"
}

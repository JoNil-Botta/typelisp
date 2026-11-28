#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

GATE_FAIL_PREFIX='FAIL: '
. "$ROOT/scripts/lib-gate.sh"
gate_compiler
gate_compiler_absolute

HOST_OS=linux
OBJ_SUFFIX=.o
EXE_SUFFIX=
LIB_PREFIX=lib
LIB_SUFFIX=.a
case "$(uname -s)" in
    Linux*) ;;
    MINGW* | MSYS* | CYGWIN*)
        HOST_OS=windows
        OBJ_SUFFIX=.obj
        EXE_SUFFIX=.exe
        LIB_PREFIX=
        LIB_SUFFIX=.lib
        ;;
    *)
        echo "package artifact freshness verification is unsupported on this host" >&2
        exit 1
        ;;
esac

WORK="$ROOT/target/package-artifact-freshness"
rm -rf "$WORK"
mkdir -p "$WORK/pkg/src" "$WORK/pkg/vendor/dep/src" "$WORK/serial/src"

# Package ELF preparation translates artifact kind and delegates to the shared
# source/package capability owner. Keep serializer decisions out of this seam.
check_direct_object_boundary() {
    awk '
        /^\(define \(build-package-render-linux-direct-object$/ { active = 1; found += 1; next }
        active && /^\(/ { active = 0 }
        active {
            if ($0 ~ /build_run_core[.]source-tool-render-linux-direct-object/) calls += 1
            if ($0 ~ /compiler_object_elf[.]|compiler-object-symbol-list-contains[?]|\(cond|\(if/) forbidden += 1
        }
        END { exit !(found == 1 && calls == 1 && forbidden == 0) }
    ' "$1"
}

check_direct_object_boundary src/build_cli_core.tl || fail "package ELF route bypasses shared capability owner"
sed 's/build_run_core.source-tool-render-linux-direct-object/unowned-renderer/' \
    src/build_cli_core.tl > "$WORK/bypassed-owner.tl"
if check_direct_object_boundary "$WORK/bypassed-owner.tl"; then
    fail "package ELF boundary guard accepted a bypassed owner"
fi
sed '/^  (build_run_core.source-tool-render-linux-direct-object$/a\
    (compiler_object_elf.compiler-object-elf-image-supported? image)' \
    src/build_cli_core.tl > "$WORK/duplicated-capability.tl"
if check_direct_object_boundary "$WORK/duplicated-capability.tl"; then
    fail "package ELF boundary guard accepted duplicated capability checks"
fi

# Route selection may read source declarations; artifact emission consumes the
# resulting route and one lowered program, with no source frontend to revisit.
check_package_lowered_route() {
    awk '
        /^[[:space:]]*\(define \(/ {
            mode = ""; route_lower = 0
            if ($0 ~ /\(build-package-prepare-owned-runtime$/) { mode = "prepare"; prepare += 1 }
            if ($0 ~ /\(build-package-(emit-preflighted-runtime|emit-assembly-fallback)$/) { mode = "emit"; emit += 1 }
        }
        mode == "prepare" {
            if ($0 ~ /compiler-driver-package-runtime-lower/) { lower_calls += 1; route_lower += 1 }
            if ($0 ~ /\(build-package-direct-object-preflight$/) { policy_calls += 1; if (route_lower) forbidden += 1 }
            if ($0 ~ /\(build-package-emit-preflighted-runtime$/) handoff += 1
        }
        mode == "emit" {
            if ($0 ~ /AstDecl|AstNode|compiler-driver-(lower|load|emit)-package/) forbidden += 1
            if ($0 ~ /\[lowered : compiler_driver_core.ResultCompilerDriverLowered\]/) inputs += 1
        }
        END { exit !(prepare == 1 && emit == 2 && lower_calls == 1 && policy_calls == 1 && handoff == 1 && inputs == 2 && forbidden == 0) }
    ' "$1"
}
check_package_lowered_route src/build_cli_core.tl || fail "package emission does not consume one lowered result"
sed 's/compiler-driver-emit-lowered-result-with-level-mode-entry-and-crt$/compiler-driver-emit-package-loaded/' \
    src/build_cli_core.tl > "$WORK/relowered-fallback.tl"
if check_package_lowered_route "$WORK/relowered-fallback.tl"; then
    fail "package route guard accepted lowering inside assembly fallback"
fi
sed '/^[[:space:]]*\[lowered : compiler_driver_core.ResultCompilerDriverLowered\]$/a\
  [decls : ast.AstDeclList]' \
    src/build_cli_core.tl > "$WORK/frontend-in-emission.tl"
if check_package_lowered_route "$WORK/frontend-in-emission.tl"; then
    fail "package route guard accepted source declarations in emission"
fi

# Artifact finishing consumes complete byte/text outputs. It cannot accept a
# frontend graph or invoke preparation again after the checked runtime capture.
check_prepared_runtime_boundary() {
    awk '
        /^[[:space:]]*\(define \(/ {
            mode = ""
            if ($0 ~ /\(build-package-finish-prepared-runtime$/) { mode = "finish"; finish += 1 }
            if ($0 ~ /\(build-package-finish-direct-fresh-artifacts$/) { mode = "direct"; direct += 1 }
            if ($0 ~ /\(build-package-finish-bin-artifacts$/) { mode = "capture"; capture += 1 }
        }
        mode == "finish" || mode == "direct" {
            if ($0 ~ /AstDecl|AstNode|CompilerIr|build-package-prepare-owned-runtime|compiler-driver-(emit|lower)-package|compiler-driver-package-runtime-lower/) forbidden += 1
        }
        mode == "finish" && $0 ~ /\(match prepared$/ { consume += 1 }
        mode == "capture" {
            if (handoff) {
                if ($0 ~ /^[[:space:]]*prepared$/) passed += 1
                handoff = 0
            }
            if ($0 ~ /\(build-package-prepare-owned-runtime$/) prepare += 1
            if ($0 ~ /\(build-package-finish-prepared-runtime$/) { finish_call += 1; handoff = 1 }
        }
        END { exit !(finish == 1 && direct == 1 && capture == 1 && forbidden == 0 && consume == 1 && prepare == 1 && finish_call == 1 && passed == 1) }
    ' "$1"
}

check_prepared_runtime_boundary src/build_cli_core.tl || fail "package artifact finishing does not consume one prepared runtime"
sed 's/(match prepared$/(match (build-package-prepare-owned-runtime scope request)/' \
    src/build_cli_core.tl > "$WORK/reprepared-runtime.tl"
if check_prepared_runtime_boundary "$WORK/reprepared-runtime.tl"; then
    fail "prepared runtime guard accepted preparation inside artifact finishing"
fi
sed '/^[[:space:]]*(build-package-finish-prepared-runtime$/ { n; s/^[[:space:]]*prepared$/                      (build-package-prepare-owned-runtime scope request)/; }' \
    src/build_cli_core.tl > "$WORK/reprepared-handoff.tl"
if check_prepared_runtime_boundary "$WORK/reprepared-handoff.tl"; then
    fail "prepared runtime guard accepted repeated preparation at handoff"
fi
sed '/^  \[prepared : ResultBuildPackagePreparedRuntime\]$/a\
  [decls : ast.AstDeclList]' \
    src/build_cli_core.tl > "$WORK/retained-frontend.tl"
if check_prepared_runtime_boundary "$WORK/retained-frontend.tl"; then
    fail "prepared runtime guard accepted a retained frontend graph"
fi
# Export finishing cannot keep or revisit the parsed frontend. The capture
# reads the expanded program before lowering, transfers only text/catalogs,
# and the companion is finished only after lowering and the package runtime
# are released on the success path itself (not merely on an error arm).
check_package_export_boundary() {
    awk '
        /^[[:space:]]*\(define \(/ {
            mode = ""
            if ($0 ~ /\(build-package-tlci-emit-optional$/) { mode = "finish"; finish += 1 }
            if ($0 ~ /\(build-package-emit-lib-tli!$/) { mode = "pipeline"; pipeline += 1 }
            if ($0 ~ /\(build-package-lib-lower-and-emit$/) { mode = "lower"; lower += 1 }
            if ($0 ~ /\(build-package-runtime-scope-release!$/) { mode = "release"; release_owner += 1 }
        }
        mode == "release" {
            if ($0 ~ /compiler_driver_core[.]compiler-driver-package-runtime-scope-release!/) release_call += 1
        }
        mode == "finish" {
            if ($0 ~ /AstDecl|AstNode|TlciNativeMacroCaptures|build-package-tlci-(callable|macro)-collector|embedded-native-emit-package$/) forbidden += 1
            if ($0 ~ /embedded-native-emit-package-source/) source_emit += 1
        }
        mode == "lower" {
            if ($0 ~ /tli_extract[.]tli-emit-partitioned-modules!/) partitioned += 1
            if ($0 ~ /lower[.]compiler-lower-arena-state-release!/ && partitioned && !arms) lower_released += 1
            if ($0 ~ /\(match part-result$/) arms += 1
        }
        mode == "pipeline" {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (line ~ /^;/ || line == "") next
            if (line ~ /^\(build-package-tlci-capture-exports$/) { capture += 1; if (lowered) forbidden += 1 }
            if (line ~ /^\(build-package-lib-lower-and-emit$/) lowered += 1
            if (line ~ /^\(build-package-tlci-emit-optional$/) {
                emits += 1
                if (!(p3 == "(build-package-runtime-scope-release! scope)" && p2 == "(let" && p1 ~ /^\[tlci-emitted : BuildPackageTlciEmitted$/ && lowered)) forbidden += 1
            }
            p3 = p2; p2 = p1; p1 = line
        }
        END { exit !(finish == 1 && pipeline == 1 && lower == 1 && source_emit == 1 && capture == 1 && lowered == 1 && partitioned == 1 && lower_released == 1 && emits == 1 && release_owner == 1 && release_call == 1 && forbidden == 0) }
    ' "$1"
}
check_package_export_boundary src/build_cli_core.tl || fail "package export finishing retains the parsed frontend"
sed '/^[[:space:]]*\[exports : ResultBuildPackageTlciExports\]$/a\
    [decls : ast.AstDeclList]' \
    src/build_cli_core.tl > "$WORK/retained-export-frontend.tl"
if check_package_export_boundary "$WORK/retained-export-frontend.tl"; then
    fail "package export guard accepted frontend inputs to finishing"
fi
sed 's/embedded-native-emit-package-source$/embedded-native-emit-package/' \
    src/build_cli_core.tl > "$WORK/recaptured-export-source.tl"
if check_package_export_boundary "$WORK/recaptured-export-source.tl"; then
    fail "package export guard accepted native capture during finishing"
fi
sed 's/(build-package-tlci-capture-exports$/(uncaptured-package-exports/' \
    src/build_cli_core.tl > "$WORK/uncaptured-export-source.tl"
if check_package_export_boundary "$WORK/uncaptured-export-source.tl"; then
    fail "package export guard accepted missing capture before runtime"
fi
sed 's/compiler_driver_core[.]compiler-driver-package-runtime-scope-release!/missing-runtime-release!/' \
    src/build_cli_core.tl > "$WORK/unreleased-runtime-source.tl"
if check_package_export_boundary "$WORK/unreleased-runtime-source.tl"; then
    fail "package export guard accepted a wrapper without runtime release"
fi
# Only the error arms release the runtime: the success path finishes live.
awk '
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    line == "(build-package-runtime-scope-release! scope)" { held = $0; next }
    held != "" {
        if (line != "(let") print held
        held = ""
    }
    { print }
' src/build_cli_core.tl > "$WORK/ok-path-unreleased-export.tl"
if check_package_export_boundary "$WORK/ok-path-unreleased-export.tl"; then
    fail "package export guard accepted companion finishing before the success-path runtime release"
fi
# Lowering arenas released only on an error arm.
awk '
    /\(match part-result$/ { moved = 1 }
    /lower[.]compiler-lower-arena-state-release!/ && !moved && seen_part { skip = 2 }
    /tli_extract[.]tli-emit-partitioned-modules!/ { seen_part = 1 }
    skip > 0 { skip -= 1; next }
    { print }
' src/build_cli_core.tl > "$WORK/ok-path-unreleased-lowering.tl"
if check_package_export_boundary "$WORK/ok-path-unreleased-lowering.tl"; then
    fail "package export guard accepted lowering arenas live through the success path"
fi
# Checked lowering has one owner for pool adoption, error cleanup and arena
# restoration. Source and PIC routes must share it with package retirement.
check_driver_checked_handoff() {
    awk '
        /^\(define \(/ {
            route = 0; owner = 0
            if ($0 ~ /\(compiler-driver-(load-and-lower-(escaping|pic-image)-with-state-and-retirement|package-runtime-lower)$/) { route = 1; routes += 1 }
            if ($0 ~ /\(compiler-driver-state-(begin|finish)-checked-lower!$/) { owner = 1; owners += 1 }
        }
        route {
            if ($0 ~ /compiler-driver-state-begin-checked-lower!/) begin_calls += 1
            if ($0 ~ /compiler-driver-state-finish-checked-lower!/) finish_calls += 1
            if ($0 ~ /compiler-lower-checked-dest-pools-(use|clear|abort-uncommitted)!|compiler-driver-state-adopt-pools!/) forbidden += 1
        }
        owner && $0 ~ /\(arena[.]from-raw-handle \(compiler-driver-state-surface-arena state\)\)/ { retained += 1 }
        END { exit !(routes == 3 && owners == 2 && begin_calls == 3 && finish_calls == 3 && retained == 2 && forbidden == 0) }
    ' "$1"
}
check_driver_checked_handoff src/compiler_driver_core.tl || fail "driver paths duplicate checked-pool ownership"
sed 's/(compiler-driver-state-finish-checked-lower!$/(unowned-checked-finish/' \
    src/compiler_driver_core.tl > "$WORK/bypassed-checked-handoff.tl"
if check_driver_checked_handoff "$WORK/bypassed-checked-handoff.tl"; then
    fail "checked handoff guard accepted a bypassed finish owner"
fi
sed 's/(arena.from-raw-handle (compiler-driver-state-surface-arena state))/(arena.current)/' \
    src/compiler_driver_core.tl > "$WORK/temporary-checked-handoff.tl"
if check_driver_checked_handoff "$WORK/temporary-checked-handoff.tl"; then
    fail "checked handoff guard accepted bookkeeping in a retiring arena"
fi
# Generated package specializations bypass ordinary function lowering. Their
# complete IR must cross the same canonical retention boundary.
check_package_spmd_ir_owner() {
    awk '
        /^\(define \(/ {
            active = ($0 ~ /\(lower-spmd-package-callable-functions$/)
            if (active) found += 1
        }
        active && /^ +\[lower-state : CompilerLowerState$/ { owner_next = 1; next }
        active && owner_next {
            if ($0 ~ /^ +\(compiler-lower-state-from-name-cache names\)\]$/) owner += 1
            owner_next = 0
        }
        active && /^ +\(lower-function-seq-escape-to-ir-arena$/ { retained_next = 1; next }
        active && retained_next == 1 {
            retained_next = ($0 ~ /^ +lower-state$/) ? 2 : 0
            next
        }
        active && retained_next == 2 {
            if ($0 ~ /^ +functions\)$/) retained += 1
            retained_next = 0
        }
        END { exit !(found == 1 && owner == 1 && retained == 1) }
    ' "$1"
}
check_package_spmd_ir_owner src/compiler_lower.tl || fail "package SPMD functions bypass retained IR ownership"
sed 's/(lower-function-seq-escape-to-ir-arena$/(unowned-package-functions/' \
    src/compiler_lower.tl > "$WORK/unowned-spmd-functions.tl"
if check_package_spmd_ir_owner "$WORK/unowned-spmd-functions.tl"; then
    fail "package SPMD guard accepted frontend-owned IR"
fi
sed 's/^ *lower-state$/                      foreign-owner/' \
    src/compiler_lower.tl > "$WORK/foreign-spmd-owner.tl"
if check_package_spmd_ir_owner "$WORK/foreign-spmd-owner.tl"; then
    fail "package SPMD guard accepted a foreign lower owner"
fi
if [ "${1:-}" = --boundary-self-test ]; then
    echo "package and driver ownership boundaries: owner and mutation checks passed"
    exit 0
fi

assert_contains() {
    file=$1
    text=$2
    grep -F -- "$text" "$file" >/dev/null || fail "$file missing: $text"
}

assert_artifact_role() {
    file=$1
    role=$2
    basename=$3
    grep -F -- "$role " "$file" | grep -F -- "$basename" >/dev/null || \
        fail "$file missing $role status for $basename"
}

snapshot() {
    output=$1
    shift
    : > "$output"
    for path in "$@"; do
        [ -f "$path" ] || fail "missing package artifact $path"
        cksum "$path" >> "$output"
        stat -c '%y' "$path" >> "$output"
    done
}

assert_same() {
    left=$1
    right=$2
    cmp -s "$left" "$right" || fail "package artifact snapshot changed: $left vs $right"
}

assert_different() {
    left=$1
    right=$2
    cmp -s "$left" "$right" && fail "package artifact snapshot did not change: $left vs $right"
    return 0
}

cat > "$WORK/pkg/typelisp.pkg" <<'EOF'
(package
  (name "fresh_root")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl")
  (dependencies
    (dep "vendor/dep")))
EOF

cat > "$WORK/pkg/src/main.tl" <<'EOF'
(import dep.src.lib as dep)
(define (main) : i64 (dep.add-one 41))
EOF

cat > "$WORK/pkg/vendor/dep/typelisp.pkg" <<'EOF'
(package
  (name "fresh_dep")
  (version "0.1.0")
  (kind "lib")
  (entry "src/lib.tl"))
EOF

cat > "$WORK/pkg/vendor/dep/src/lib.tl" <<'EOF'
(defmacro (unused-transform [value : Expr]) : Expr
  `(+ ,value 1))
(define (add-one [value : i64]) : i64 (+ value 1))
EOF

cat > "$WORK/serial/typelisp.pkg" <<'EOF'
(package
  (name "fresh_serial")
  (version "0.1.0")
  (kind "lib")
  (entry "src/lib.tl"))
EOF

cat > "$WORK/serial/src/lib.tl" <<'EOF'
(define (serial-value) : i64 7)
EOF

MODE=
run_graph() {
    tag=$1
    out="$WORK/$tag.out"
    err="$WORK/$tag.err"
    set +e
    if [ -n "$MODE" ]; then
        "$COMPILER" build --manifest-path "$WORK/pkg/typelisp.pkg" --backend-mode "$MODE" >"$out" 2>"$err"
    else
        "$COMPILER" build --manifest-path "$WORK/pkg/typelisp.pkg" >"$out" 2>"$err"
    fi
    code=$?
    set -e
    [ ! -e "$ROOT_TLCI" ] || fail "executable package wrote a tlci image"
    if grep -F 'fresh_root.tlci' "$out" >/dev/null; then
        fail "executable package reported a tlci image: $(cat "$out")"
    fi
}

run_serial() {
    tag=$1
    out="$WORK/$tag.out"
    err="$WORK/$tag.err"
    set +e
    "$COMPILER" build --package-worker --manifest-path "$WORK/serial/typelisp.pkg" >"$out" 2>"$err"
    code=$?
    set -e
}

ROOT_OUT="$WORK/pkg/target/release"
DEP_OUT="$WORK/pkg/vendor/dep/target/release"
ROOT_ASM="$ROOT_OUT/fresh_root.s"
ROOT_OBJ="$ROOT_OUT/fresh_root$OBJ_SUFFIX"
ROOT_RUNTIME="$ROOT_OUT/fresh_root$EXE_SUFFIX"
ROOT_TLCI="$ROOT_OUT/fresh_root.tlci"
ROOT_INPUTS="$ROOT_RUNTIME.runtime-inputs"
DEP_TLI="$DEP_OUT/fresh_dep.tli"
DEP_RUNTIME="$DEP_OUT/${LIB_PREFIX}fresh_dep$LIB_SUFFIX"
DEP_TLCI="$DEP_OUT/fresh_dep.tlci"
DEP_INPUTS="$DEP_RUNTIME.runtime-inputs"

run_graph initial
[ "$code" -eq 0 ] || fail "initial package build failed: $(cat "$err")"
[ ! -s "$err" ] || fail "initial package build wrote stderr: $(cat "$err")"
assert_artifact_role "$out" Built "fresh_root$EXE_SUFFIX"
assert_artifact_role "$out" Built "fresh_dep.tlci"
[ -s "$DEP_TLI" ] || fail "initial build did not emit fresh_dep.tli"

snapshot "$WORK/noop.before" \
    "$ROOT_ASM" "$ROOT_OBJ" "$ROOT_RUNTIME" "$ROOT_INPUTS" \
    "$DEP_TLI" "$DEP_RUNTIME" "$DEP_TLCI" "$DEP_INPUTS"
sleep 1
run_graph noop
[ "$code" -eq 0 ] || fail "no-op package build failed: $(cat "$err")"
[ ! -s "$err" ] || fail "no-op package build wrote stderr: $(cat "$err")"
assert_artifact_role "$out" Fresh "fresh_root$EXE_SUFFIX"
assert_artifact_role "$out" Fresh "${LIB_PREFIX}fresh_dep$LIB_SUFFIX"
assert_artifact_role "$out" Fresh "fresh_dep.tlci"
snapshot "$WORK/noop.after" \
    "$ROOT_ASM" "$ROOT_OBJ" "$ROOT_RUNTIME" "$ROOT_INPUTS" \
    "$DEP_TLI" "$DEP_RUNTIME" "$DEP_TLCI" "$DEP_INPUTS"
assert_same "$WORK/noop.before" "$WORK/noop.after"

if [ "$HOST_OS" = linux ]; then
    WRAP="$WORK/tool-wrappers"
    TOOL_LOG="$WORK/tool-invocations.log"
    ORIGINAL_PATH=$PATH
    mkdir -p "$WRAP"
    : > "$TOOL_LOG"
    export TOOL_LOG
    for tool in ar ld cc; do
        real=$(PATH=$ORIGINAL_PATH command -v "$tool") || fail "missing $tool for wrapper coverage"
        {
            echo '#!/usr/bin/env sh'
            printf 'printf "%%s\\n" %s >> "$TOOL_LOG"\n' "$tool"
            printf 'exec %s "$@"\n' "$real"
        } > "$WRAP/$tool"
        chmod +x "$WRAP/$tool"
    done
    cat > "$WRAP/as" <<'EOF'
#!/usr/bin/env sh
printf '%s\n' as >> "$TOOL_LOG"
exit 97
EOF
    chmod +x "$WRAP/as"
    PATH="$WRAP:$ORIGINAL_PATH"
    export PATH
    MODE=avx2
    run_graph wrapper-seed
    [ "$code" -eq 0 ] || fail "tool-wrapper seed build failed: $(cat "$err")"
    [ ! -s "$err" ] || fail "tool-wrapper seed build wrote stderr: $(cat "$err")"
    assert_contains "$ROOT_INPUTS" 'assembler 21:typelisp-linux-x86_64'
    assert_contains "$DEP_INPUTS" 'assembler 21:typelisp-linux-x86_64'
    assert_contains "$TOOL_LOG" ar
    assert_contains "$TOOL_LOG" ld
    if grep -Fxq cc "$TOOL_LOG"; then
        fail "archive-only package build used the C linker driver"
    fi
    wrapper_calls=$(wc -l < "$TOOL_LOG" | tr -d ' ')
    [ "$wrapper_calls" -gt 0 ] || fail "tool-wrapper seed recorded no native tools"
    sleep 1
    run_graph wrapper-noop
    [ "$code" -eq 0 ] || fail "tool-wrapper no-op build failed: $(cat "$err")"
    assert_artifact_role "$out" Fresh "fresh_root$EXE_SUFFIX"
    assert_artifact_role "$out" Fresh "${LIB_PREFIX}fresh_dep$LIB_SUFFIX"
    after_calls=$(wc -l < "$TOOL_LOG" | tr -d ' ')
    [ "$after_calls" -eq "$wrapper_calls" ] || fail "no-op package build invoked native tools"

    printf '\n# external assembler identity change\n' >> "$WRAP/as"
    run_graph assembler-identity
    [ "$code" -eq 0 ] || fail "external assembler identity check failed: $(cat "$err")"
    assert_artifact_role "$out" Fresh "fresh_root$EXE_SUFFIX"
    assert_artifact_role "$out" Fresh "${LIB_PREFIX}fresh_dep$LIB_SUFFIX"
    [ "$(wc -l < "$TOOL_LOG" | tr -d ' ')" -eq "$after_calls" ] || fail "external assembler identity change invoked native tools"
    if grep -Fxq as "$TOOL_LOG"; then
        fail "package build invoked an external assembler"
    fi

    printf '\n# tool identity change\n' >> "$WRAP/ar"
    printf '\n# tool identity change\n' >> "$WRAP/ld"
    run_graph tool-identity
    [ "$code" -eq 0 ] || fail "tool-identity rebuild failed: $(cat "$err")"
    assert_artifact_role "$out" Built "fresh_root$EXE_SUFFIX"
    assert_artifact_role "$out" Built "${LIB_PREFIX}fresh_dep$LIB_SUFFIX"
    assert_artifact_role "$out" Fresh "fresh_dep.tlci"
    identity_calls=$(wc -l < "$TOOL_LOG" | tr -d ' ')
    [ "$identity_calls" -gt "$after_calls" ] || fail "tool identity change did not invoke native tools"
fi

# A comptime-only (macro body) edit leaves the native archive alone but still
# rewrites fresh_dep.tli: its module records stamp the edited source's
# source_sha256 and the rebuilt companion's tlci_sha256, so the snapshot covers
# both interface files.
snapshot "$WORK/comptime-tlci.before" "$DEP_TLCI" "$DEP_TLI"
sed 's/`(+ ,value 1)/`(+ ,value 2)/' "$WORK/pkg/vendor/dep/src/lib.tl" > "$WORK/dep.next"
mv "$WORK/dep.next" "$WORK/pkg/vendor/dep/src/lib.tl"
sleep 1
run_graph comptime-only
[ "$code" -eq 0 ] || fail "comptime-only rebuild failed: $(cat "$err")"
assert_artifact_role "$out" Built "fresh_dep.tlci"
snapshot "$WORK/comptime-tlci.after" "$DEP_TLCI" "$DEP_TLI"
assert_different "$WORK/comptime-tlci.before" "$WORK/comptime-tlci.after"

sed 's/dep.add-one 41/dep.add-one 42/' "$WORK/pkg/src/main.tl" > "$WORK/main.next"
mv "$WORK/main.next" "$WORK/pkg/src/main.tl"
run_graph runtime-edit
[ "$code" -eq 0 ] || fail "runtime rebuild failed: $(cat "$err")"
assert_artifact_role "$out" Built "fresh_root$EXE_SUFFIX"
assert_artifact_role "$out" Fresh "${LIB_PREFIX}fresh_dep$LIB_SUFFIX"
assert_artifact_role "$out" Fresh "fresh_dep.tlci"

sed 's/+ value 1/+ value 2/' "$WORK/pkg/vendor/dep/src/lib.tl" > "$WORK/dep.next"
mv "$WORK/dep.next" "$WORK/pkg/vendor/dep/src/lib.tl"
run_graph dependency-edit
[ "$code" -eq 0 ] || fail "dependency rebuild failed: $(cat "$err")"
assert_artifact_role "$out" Built "${LIB_PREFIX}fresh_dep$LIB_SUFFIX"
assert_artifact_role "$out" Built "fresh_dep.tlci"
assert_artifact_role "$out" Built "fresh_root$EXE_SUFFIX"

run_serial serial-initial
[ "$code" -eq 0 ] || fail "serial worker build failed: $(cat "$err")"
SERIAL_OUT="$WORK/serial/target/release"
SERIAL_TLI="$SERIAL_OUT/fresh_serial.tli"
SERIAL_RUNTIME="$SERIAL_OUT/${LIB_PREFIX}fresh_serial$LIB_SUFFIX"
[ -s "$SERIAL_TLI" ] || fail "serial worker build did not emit fresh_serial.tli"
[ ! -e "$SERIAL_OUT/fresh_serial.tlci" ] || fail "pure library fresh_serial unexpectedly emitted .tlci"
snapshot "$WORK/serial.before" \
    "$SERIAL_TLI" \
    "$SERIAL_RUNTIME" \
    "$SERIAL_RUNTIME.runtime-inputs"
sleep 1
run_serial serial-noop
[ "$code" -eq 0 ] || fail "serial worker no-op failed: $(cat "$err")"
assert_artifact_role "$out" Fresh "${LIB_PREFIX}fresh_serial$LIB_SUFFIX"
snapshot "$WORK/serial.after" \
    "$SERIAL_TLI" \
    "$SERIAL_RUNTIME" \
    "$SERIAL_RUNTIME.runtime-inputs"
assert_same "$WORK/serial.before" "$WORK/serial.after"

# A failed library rebuild must preserve both runtime artifacts and the TLI.
printf '(define (serial-value) : i64 8)\n' > "$WORK/serial/src/lib.tl"
if [ "$HOST_OS" = linux ]; then
    mkdir -p "$WORK/fail-archive"
    printf '#!/usr/bin/env sh\nexit 97\n' > "$WORK/fail-archive/ar"
    chmod +x "$WORK/fail-archive/ar"
    PATH="$WORK/fail-archive:$PATH" run_serial failed-archive
else
    TYPELISP_WINDOWS_LIB=where.exe run_serial failed-archive
fi
[ "$code" -ne 0 ] || fail "failing archiver package build unexpectedly succeeded"
snapshot "$WORK/serial.failure" \
    "$SERIAL_TLI" \
    "$SERIAL_RUNTIME" \
    "$SERIAL_RUNTIME.runtime-inputs"
assert_same "$WORK/serial.before" "$WORK/serial.failure"

snapshot "$WORK/failure.before" \
    "$ROOT_ASM" "$ROOT_OBJ" "$ROOT_RUNTIME" "$ROOT_INPUTS"
sed 's/dep.add-one 42/dep.add-one 43/' "$WORK/pkg/src/main.tl" > "$WORK/main.next"
mv "$WORK/main.next" "$WORK/pkg/src/main.tl"
if [ "$HOST_OS" = linux ]; then
    FAIL_LINK_DIR="$WORK/fail-link"
    mkdir -p "$FAIL_LINK_DIR"
    cat > "$FAIL_LINK_DIR/ld" <<'EOF'
#!/usr/bin/env sh
exit 97
EOF
    chmod +x "$FAIL_LINK_DIR/ld"
    PATH="$FAIL_LINK_DIR:$PATH" run_graph failed-link
else
    TYPELISP_WINDOWS_LINK=where.exe
    export TYPELISP_WINDOWS_LINK
    run_graph failed-link
    unset TYPELISP_WINDOWS_LINK
fi
[ "$code" -ne 0 ] || fail "failing linker package build unexpectedly succeeded"
snapshot "$WORK/failure.after" \
    "$ROOT_ASM" "$ROOT_OBJ" "$ROOT_RUNTIME" "$ROOT_INPUTS"
assert_same "$WORK/failure.before" "$WORK/failure.after"

echo "package artifact freshness verification passed ($HOST_OS)"

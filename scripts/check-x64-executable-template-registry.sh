#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

fail() {
    echo "check-x64-executable-template-registry: $*" >&2
    exit 1
}

count_matches() {
    expected=$1
    pattern=$2
    shift 2
    actual=$(grep -En "$pattern" "$@" 2>/dev/null | wc -l | tr -d ' ')
    [ "$actual" -eq "$expected" ] || fail "expected $expected matches for $pattern, found $actual"
}

# Runtime leaf composition has one registration at every selected fragment.
# The Linux entry prefix has two mutually exclusive construction arms, so its
# source contains three registrations while one emitted program selects two.
count_matches 13 'compiler-x64-template-render-assembly' src/compiler_backend_runtime_linux.tl
count_matches 15 'compiler-x64-template-render-assembly' src/compiler_backend_runtime_windows.tl
count_matches 3 'compiler-x64-template-render-assembly' src/compiler_backend.tl

# Pin the full-file lexical census as a construction-site tripwire. The typed
# catalog remains authoritative; these counts make newly concatenated assembly
# visible even if its owner forgot to add a render gate.
count_matches 6 '\.globl' src/compiler_backend_runtime_common.tl
count_matches 9 '(^|[^[:alnum:]_])ret([^[:alnum:]_]|$)' src/compiler_backend_runtime_common.tl
count_matches 0 '(^|[^[:alnum:]_])call([^[:alnum:]_]|$)' src/compiler_backend_runtime_common.tl
count_matches 1 '(^|[^[:alnum:]_])jmp([^[:alnum:]_]|$)' src/compiler_backend_runtime_common.tl
count_matches 33 '\.globl' src/compiler_backend_runtime_linux.tl
count_matches 42 '(^|[^[:alnum:]_])ret([^[:alnum:]_]|$)' src/compiler_backend_runtime_linux.tl
count_matches 8 '(^|[^[:alnum:]_])call([^[:alnum:]_]|$)' src/compiler_backend_runtime_linux.tl
count_matches 18 '(^|[^[:alnum:]_])jmp([^[:alnum:]_]|$)' src/compiler_backend_runtime_linux.tl
count_matches 28 '\.globl' src/compiler_backend_runtime_windows.tl
count_matches 39 '(^|[^[:alnum:]_])ret([^[:alnum:]_]|$)' src/compiler_backend_runtime_windows.tl
count_matches 79 '(^|[^[:alnum:]_])call([^[:alnum:]_]|$)' src/compiler_backend_runtime_windows.tl
count_matches 36 '(^|[^[:alnum:]_])jmp([^[:alnum:]_]|$)' src/compiler_backend_runtime_windows.tl

# All target-owned executable byte helpers carry closed IDs.  Windows has two
# additional bytes-from-hex sites: the data-only UNWIND_INFO and resource tree.
count_matches 3 'CompilerX64ExecutableTemplateId\.LinuxObject.*Bytes' src/compiler_backend_object_target_linux.tl
count_matches 21 'CompilerX64ExecutableTemplateId\.WindowsObject.*Bytes' src/compiler_backend_object_target_windows.tl
count_matches 3 'compiler-backend-object-bytes-from-hex' src/compiler_backend_object_target_linux.tl
count_matches 3 'compiler-backend-object-bytes-from-hex' src/compiler_backend_object_target_windows.tl

# Opaque executable instructions enter target leaves through one registration
# gate. Generated ordinary-function Bytes/Raw sites live outside this owner set.
count_matches 1 'CompilerObjectX64Instr\.(Bytes|Raw)' \
    src/compiler_backend_object_target.tl \
    src/compiler_backend_object_target_linux.tl \
    src/compiler_backend_object_target_windows.tl
grep -Eq 'CompilerObjectX64Instr\.Bytes bytes' src/compiler_backend_object_target.tl \
    || fail "central target-owned Bytes gate is missing"

# Contribution boundaries are registered separately from reusable byte pieces.
count_matches 1 'LinuxObjectStartContribution' src/compiler_backend_object_target_linux.tl
count_matches 2 'LinuxObjectTlci(Image|Macro)Contribution' src/compiler_backend_object_target_linux.tl
count_matches 3 'WindowsObject(Start|MainFiber|OverflowFilter)Contribution' src/compiler_backend_object_target_windows.tl
count_matches 1 'WindowsObjectRuntimeSupportContribution' src/compiler_backend_object_target_windows.tl
count_matches 2 'WindowsObjectTlci(Image|Macro)Contribution' src/compiler_backend_object_target_windows.tl

# The only unregistered target byte literals are explicitly data-only.  Their
# owning functions and the executable contributions' .pdata/.xdata relations
# are both pinned, so moving either literal into text fails this census.
grep -Fq '(define (compiler-backend-object-entry-xdata-bytes)' \
    src/compiler_backend_object_target_windows.tl \
    || fail "Windows data-only unwind template is missing"
grep -Fq '(define (compiler-backend-object-manifest-resource-records)' \
    src/compiler_backend_object_target_windows.tl \
    || fail "Windows data-only resource template is missing"
CATALOG_DATA=src/compiler_x64_executable_template_catalog.tsv
EXPECTED_CATALOG_HEADER=$(printf 'variant\tid_name\tproducer\ttarget\tabi\tfeature\trender_kind\tcontribution_kind\tentry_anchor\tinterior_anchors\tend_anchor\tterminal\tevents\tevent_count\texpected_rendered_size\texpected_rendered_hash')
ACTUAL_CATALOG_HEADER=$(sed -n '1p' "$CATALOG_DATA")
[ "$ACTUAL_CATALOG_HEADER" = "$EXPECTED_CATALOG_HEADER" ] ||
    fail "catalog data header does not match the 16-field schema"

if ! awk -F '\t' '
    BEGIN {
        target["0:AnyX64"] = target["1:LinuxX64"] = target["2:WindowsX64"] = 1
        abi["0:InternalX64"] = abi["1:SystemV"] = abi["2:Win64"] = 1
        render["0:Assembly"] = render["1:OpaqueBytes"] = render["2:StructuredObject"] = 1
        contribution["0:RuntimeFunctions"] = contribution["1:Startup"] = contribution["2:TlciBridge"] = contribution["3:ExternalFiberCallback"] = contribution["4:ExternalExceptionCallback"] = contribution["5:ByteFragment"] = contribution["6:MixedRuntimeBundle"] = 1
        terminal["0:FallsThrough"] = terminal["1:Returns"] = terminal["2:TailTransfers"] = terminal["3:TerminatesProcess"] = terminal["4:SuspendsOrTerminates"] = terminal["5:ReturnsOrTerminates"] = terminal["6:Mixed"] = terminal["7:Unknown"] = 1
        feature["0:Always"] = feature["1:Alloc"] = feature["2:RegionMark"] = feature["3:RegionReset"] = feature["4:Profile"] = feature["5:StartupProfile"] = feature["6:TlciMacroEntry"] = feature["7:Backtrace"] = feature["8:ArenaDebug"] = feature["9:ProfileArenaDebug"] = feature["10:AllocProfile"] = feature["11:AllocArenaDebug"] = feature["12:AllocProfileArenaDebug"] = feature["13:RegionResetProfile"] = feature["14:RegionResetArenaDebug"] = feature["15:RegionResetProfileArenaDebug"] = feature["16:NativeEntryStartupProfile"] = feature["17:NativeEntryBacktrace"] = feature["18:NativeEntry"] = 1
    }
    NR == 1 { next }
    NF != 16 { exit 1 }
    $1 == "" || $2 == "" || $3 == "" { exit 1 }
    !($4 in target) || !($5 in abi) || !($6 in feature) { exit 1 }
    !($7 in render) || !($8 in contribution) || !($12 in terminal) { exit 1 }
    $14 !~ /^[0-9]+$/ || $15 !~ /^-?[0-9]+$/ || $16 !~ /^-?[0-9]+$/ { exit 1 }
    seen_variant[$1]++ { exit 1 }
    seen_name[$2]++ { exit 1 }
    END { if (NR != 83) exit 1 }
' "$CATALOG_DATA"; then
    fail "catalog data must contain 82 unique, typed 16-field rows"
fi

# Nullary enum tags are 0-based in declaration order (SPEC 3.5.1). Keep the
# compact payload in exactly that order so the bounded tag adapter cannot
# select another row after an enum edit.
DATA_VARIANTS=$(tail -n +2 "$CATALOG_DATA" | cut -f 1)
ENUM_VARIANTS=$(sed -n \
    '/(defenum CompilerX64ExecutableTemplateId/,/(defenum CompilerX64TemplateTarget/p' \
    src/compiler_x64_executable_template.tl |
    sed -n 's/^  (\([A-Za-z0-9]*\)).*/\1/p')
[ "$ENUM_VARIANTS" = "$DATA_VARIANTS" ] ||
    fail "nullary enum declaration order differs from catalog data"
count_matches 3 '\.pdata:.*->\.L_tl_start_xdata' \
    src/compiler_x64_executable_template_evidence.tl

echo "check-x64-executable-template-registry: 82 rows, 49 assembly variants, 24 opaque byte helpers, and 9 structured contributions covered"

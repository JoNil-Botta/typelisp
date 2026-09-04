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
    actual=$(rg -n "$pattern" "$@" 2>/dev/null | wc -l | tr -d ' ')
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
count_matches 9 '\bret\b' src/compiler_backend_runtime_common.tl
count_matches 0 '\bcall\b' src/compiler_backend_runtime_common.tl
count_matches 1 '\bjmp\b' src/compiler_backend_runtime_common.tl
count_matches 33 '\.globl' src/compiler_backend_runtime_linux.tl
count_matches 42 '\bret\b' src/compiler_backend_runtime_linux.tl
count_matches 8 '\bcall\b' src/compiler_backend_runtime_linux.tl
count_matches 18 '\bjmp\b' src/compiler_backend_runtime_linux.tl
count_matches 28 '\.globl' src/compiler_backend_runtime_windows.tl
count_matches 39 '\bret\b' src/compiler_backend_runtime_windows.tl
count_matches 79 '\bcall\b' src/compiler_backend_runtime_windows.tl
count_matches 36 '\bjmp\b' src/compiler_backend_runtime_windows.tl

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
rg -q 'CompilerObjectX64Instr.Bytes bytes' src/compiler_backend_object_target.tl \
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
rg -Fq '(define (compiler-backend-object-entry-xdata-bytes)' \
    src/compiler_backend_object_target_windows.tl \
    || fail "Windows data-only unwind template is missing"
rg -Fq '(define (compiler-backend-object-manifest-resource-records)' \
    src/compiler_backend_object_target_windows.tl \
    || fail "Windows data-only resource template is missing"
count_matches 3 '\.pdata:.*->\.L_tl_start_xdata' src/compiler_x64_executable_template_catalog.tl
count_matches 82 '^      \(compiler-x64-template-row$' src/compiler_x64_executable_template_catalog.tl

echo "check-x64-executable-template-registry: 82 rows, 49 assembly variants, 24 opaque byte helpers, and 9 structured contributions covered"

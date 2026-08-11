# Packages

This page describes package manifests, dependency resolution, lockfiles, and package builds.

## Creating a package

Run `typelisp new hello-app`, then
`typelisp run --manifest-path hello-app/typelisp.pkg`. The generated binary
prints `Hello, TypeLisp!`; `typelisp test --manifest-path
hello-app/typelisp.pkg` runs its included `answer-is-42` inline test. The
generated `.gitignore` keeps package build output out of version control.

## Package manifests

Local packages are described by a std-only S-expression manifest named
`typelisp.pkg`:

```lisp
(package
  (name "my-app")
  (version "0.1.0")
  (dependencies
    (math "../math")
    (lint (github "JoNil-Botta/typelisp-lint" (rev "abc123"))))
  (link
    (libraries "raylib")
    (search-paths "vendor/raylib/lib")
    (linux-libraries "GL" "m" "pthread" "dl" "rt" "X11")
    (windows-libraries "opengl32" "gdi32" "winmm" "shell32" "user32")))
```

`typelisp build [--manifest-path <typelisp.pkg>]` resolves `entry` relative
to the manifest directory and writes outputs under `target/<profile>/`
(profiles: `release` default, `--profile dev`; release defaults to
`--opt-level 2`, dev to `0`). `kind "bin"` builds a native executable;
`kind "staticlib"` builds a static archive. When both are omitted, `bin` is
inferred from `src/main.tl` and `staticlib` from `src/lib.tl`. Package
builds also emit a host comptime image `<name>.tlci` beside the native
artifact. Macro-free packages use a metadata-only image; macro-defining
packages include one deterministic registration-table record per package-owned
macro. Supported expression/value transformer bodies compile into native
template (nested calls, literals, plain symbols, unquoted operands, and
unquote-splicing), literal, computed-if, and fold entries; supported
let-rooted bodies evaluate computed binding inits through host session locals
and emit compiled template, bracket, borrow, array, match, and let
declarations the same way; unsupported bodies
retain explicit shells for interpreted fallback. `typelisp inspect <file.tlci>`
renders the image
header, sections, and package metadata. General dependency-catalog discovery
and consumer dispatch remain staged separately from emission.

Runtime outputs and the host comptime image have independent freshness. A
second identical build reports each as `Fresh`, preserves the assembly,
object, runtime artifact, and `.tlci` bytes and modification times, and does
not rerun the native assembler, archiver, or linker. A comptime-only edit may
therefore update `.tlci` while leaving the runtime side untouched; conversely,
a target, profile, backend, optimization, debug, link-input, dependency
archive, or native-tool identity change rebuilds only the affected runtime
side. The adjacent `<runtime-artifact>.runtime-inputs` file binds the retained
runtime outputs to those inputs and is managed as package build state. Changed
outputs are staged and committed together, so a failed build retains the last
complete artifact set. `typelisp clean` removes the sidecar with the runtime
artifact.

Self-host bootstrap builds the compiler's exact embedded stdlib source set into
a source-bound `stdlib.tlci`, embeds it in the next compiler stage, and validates
all registered macro identities through the production loader. A bootstrapped
compiler exposes that payload as `typelisp inspect embedded:stdlib.tlci`.
Published compilers use that trusted catalog by default on Linux and Windows.
Macro expansion maps the image once per expansion pass and checks each stdlib
macro whose source has exact embedded provenance against the native catalog. A
byte-identical checked-in source root may retain that provenance; any modified,
unavailable, or otherwise untrusted source stays on deterministic CTFE.

A cataloged macro with a compiled entry dispatches natively and commits the
transformer's result directly. Uncataloged identities and registration shells
fall back to CTFE. Compile-profile counters report catalog hits, misses, load
failures, native dispatches, native result kinds, and interpreted fallbacks
separately. The two-host profile differential compiles the same corpus through
trusted native and forced-source routes and requires byte-identical assembly
and equivalent diagnostics; the sustained batch gate also crosses repeated
pool reset and image release/remap cycles.
`typelisp run [--manifest-path <typelisp.pkg>]` uses the same package
resolution and build profile rules, then executes `bin` package artifacts;
runtime arguments are passed after `--`.

Windows `staticlib` archives are byte-reproducible when their COFF object input
is unchanged. TypeLisp invokes discovered MSVC `lib.exe` with `/Brepro`, or
falls back to `llvm-ar --format=coff rcsD`. `TYPELISP_WINDOWS_LIB` may override
the executable with a path or PATH-resolved name whose basename is
`lib[.exe]` or `llvm-ar[.exe]`; TypeLisp selects the corresponding deterministic
argument contract. Other basenames, including `llvm-lib`, are rejected rather
than silently producing a timestamp-bearing archive.

Dependencies may be local paths or git/GitHub pins (`rev`, `tag`, or
`branch`). Remote pins resolve through `typelisp.lock` — a deterministic
S-expression lockfile recording alias, normalized URL, pin, and exact
commit — and a content-keyed package cache under
`target/typelisp/cache/`. `--locked` requires matching lock entries and
never rewrites the lockfile; `--update-lock` intentionally refreshes remote
pins. Dependency packages must be static libraries; transitive dependencies
build once per invocation as a DAG (concurrently where the host supports
it), and cycles fail with a diagnostic. Inside a package build, an import
whose leading segment is a dependency alias, such as `(import math.src.lib)`,
resolves from that dependency root. The optional `(link ...)` section declares
native link inputs per target; on Linux any non-empty link input switches the
package to linking through `cc` instead of freestanding `ld`. Registry support,
semantic-version solving, and workspaces are deferred by design: the model
is deterministic zero-dependency builds through the host `git` CLI plus
checked-in lockfile replay. See [SPEC.md §4.6](../SPEC.md) for the full
contract.

Package source discovery walks `.tl` files below the manifest directory,
skipping build/VCS state, nested package roots, and `tests` directories
(reserved for `typelisp test` integration discovery and fixture corpora).
Package `check`/`build` validate the entry's reachable import closure;
package `lint` checks every discovered source.

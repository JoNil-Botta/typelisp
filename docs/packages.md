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
Self-host bootstrap builds the compiler's exact embedded stdlib source set into
a source-bound `stdlib.tlci`, embeds it in the next compiler stage, and validates
all registered macro identities through the production loader. A bootstrapped
compiler exposes that payload as `typelisp inspect embedded:stdlib.tlci`.
Dispatching stdlib macros through that image is **opt-in and not yet enabled in
shipped builds**. It requires `--cfg tlci-native-route`, and even with that flag
it stays off on Windows until the environmental sensitivity tracked by #5460 is
closed; `scripts/build-stage0.sh` passes only `--cfg embedded-stdlib-tlci`, so
the published stage0 never activates it. Today only
`scripts/verify-compile-profile.sh` turns it on, to run the route differential.

When the route *is* active, and compilation consumes the embedded stdlib with no
explicit `--stdlib-root`, macro expansion maps the image once per expansion pass
and checks each stdlib macro against its native registration catalog. A
cataloged macro with a compiled entry dispatches natively and commits the
transformer's result directly; anything else — an uncataloged identity, a
registration shell, or the route being off — falls back to CTFE, which is what a
default build does for every stdlib macro. Compile-profile counters report
catalog hits, catalog misses, load failures, native dispatches, and interpreted
fallbacks separately. Supplying an explicit stdlib root skips the TLCI route
regardless of the flag. The compile-profile gate compiles
the same corpus through both routes and requires byte-identical assembly.
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

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
to the manifest directory and writes two separate package interfaces under
`target/<profile>/` (profiles: `release` default, `--profile dev`; release
defaults to `--opt-level 2`, dev to `0`). The runtime side is a
target-specific executable or static archive. The compile-time side is the
build-host image `<name>.tlci`, beside the runtime artifact but independent of
its selected runtime target. `kind "bin"` builds the executable; `kind
"staticlib"` builds the archive. When both are omitted, `bin` is inferred from
`src/main.tl` and `staticlib` from `src/lib.tl`.

Macro-free packages use a metadata-only image. Macro-defining packages include
one deterministic registration-table record per package-owned macro. Supported
expression/value transformer bodies compile into native template (nested calls,
literals, plain symbols, unquoted operands, and unquote-splicing), literal,
computed-if, and fold entries; supported let-rooted bodies evaluate computed
binding inits through host session locals and emit compiled template, bracket,
borrow, array, match, and let declarations the same way. Unsupported bodies
retain explicit registration shells for interpreted fallback. For example,
after building the manifest above in the default profile, inspect its
compile-time interface with:

```text
typelisp inspect target/release/my-app.tlci
```

The command validates and renders the image header, sections, package metadata,
source binding, and frontend-surface inventory. It does not execute image code.

Package builds discover dependency images from the resolved package DAG and
retain their admission state in a job-owned registry. Container integrity,
package name/version, and the exact package-owned source set are checked before
native use. A code-bearing image must also match the compiler's build-host
platform and callback ABI, and every named host import must resolve before the
loader maps it. The producer-compiler identity participates in the stable image
key; exact identity with the running compiler is additionally required before
hydrating compiler-internal frontend payloads. Native callback catalogs remain
governed by their format, source, host, and callback-schema checks.

Ordinary source resolution still decides which macro declaration is visible,
including aliases and shadowing, before a catalog can affect execution. The
resolved declaration's physical defining source selects its owning dependency
catalog. Metadata-only images are portable trusted zero-entry catalogs: they
are admitted without executable mappings, fixups, imports, or registrations.
Code-bearing mappings are writable only while the loader applies fixups and
binds imports; rodata is then read-only and code is read/execute. The registry
owns the mapping and its indexed entries for the compiler job's lifetime.

A resolved native entry is a lifetime-bound capability containing its registry
handle, slot, package/image key, registry generation, and mapped-entry
generation. The compiler revalidates the complete capability immediately before
dispatch. `Expr` transformers consume the already checked direct operands;
`Module` and `Decls` transformers consume the exact bound environment. A
status-0 call that returns a result commits exactly one host-owned handle
through the ordinary transactional expansion path, while any nonzero status
discards the session without partially inserting generated syntax. A status-0
no-result call commits nothing and follows the shell policy below. Native
dispatch failures name the package and version, image path, and macro identity.

A first status-0 native no-result outcome marks that entry as a shell for its
current mapping generation and reuses the prepared operands for deterministic
source CTFE. Known shells, uncataloged identities, metadata-only catalogs, and
missing, stale, malformed, wrong-platform, unsupported, or otherwise
unavailable images never enter mapped code and follow the same source policy.
If package source no longer matches an image, admission records a stale,
zero-map replacement generation and invalidates capabilities from the old
mapping. Rebuilding the image admits a new generation and restores native
execution; an unchanged exact key is then reused within that generation.

The image content hash and exact-source binding are deterministic integrity and
rebuild identities. They establish that a local/source-built artifact matches
the resolved source, but they are not cryptographic signatures or proof of a
publisher's identity. A future distributed or prebuilt-package authenticity
scheme therefore remains a separate trust layer.

Runtime outputs and the host comptime image have independent freshness. A
second identical build reports each as `Fresh`, preserves the assembly,
object, runtime artifact, and `.tlci` bytes and modification times, and does
not rerun the native assembler, archiver, or linker. Every package-owned source
path and byte participates in the `.tlci` source binding, so any source
add/remove/edit updates that image even when its native runtime assembly is
unchanged. A comptime-only edit may therefore build only `.tlci`; a runtime
source edit normally builds both sides. Conversely, a runtime target, profile,
optimization/debug setting, link input, dependency archive, or native-tool
identity change builds the affected runtime side while preserving byte-identical
host `.tlci` output. Backend settings also affect `.tlci` when they change its
compile-time metadata or code.

The adjacent `<runtime-artifact>.runtime-inputs` file binds retained runtime
outputs to all material codegen, assembler, archiver, linker, compiler, tool,
and dependency inputs and is managed as package build state. The two freshness
decisions are independent, but every changed side is staged and committed in
one transaction. A failed build or commit restores the previous complete
runtime/image pair. `typelisp clean` removes the sidecar with the runtime
artifact.

Self-host bootstrap builds the compiler's exact embedded stdlib source set into
a source-bound `stdlib.tlci`, embeds it in the next compiler stage, and validates
all registered macro identities through the production loader. A bootstrapped
compiler exposes that payload as `typelisp inspect embedded:stdlib.tlci`.
Published compilers use that trusted catalog, and trusted dependency catalogs,
by default on Linux and Windows.
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

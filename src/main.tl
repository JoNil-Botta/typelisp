;; main.tl - Unified pure-TypeLisp toolchain dispatcher (the package entry).
;;
;; A single self-hosted entry point that dispatches every toolchain subcommand
;; in-process. Each command's logic lives in a main-free `*_cli_core.tl` (or
;; `*_driver_core.tl`) module, so this file only routes. Built as the package
;; binary (`typelisp build`), it is then invoked as:
;;
;;   typelisp <command> <args...>
;;
;; Recognized commands: build, run, check, fmt, lint, test, doc, compile, clean,
;; inspect, repl, lsp, new, and init. The command name is `(io.arg 1)`; each
;; `*-run-from` entry parses its own arguments starting at index 2.
;;
;; This is the shipped Rust-free stage0 dispatcher: the toolchain
;; needs neither a host-language compiler driver nor per-command driver
;; recompilation. Every command shares the single full typechecker frontend
;; (`compiler_check_core` ->
;; `compiler_typecheck`), so `check` does the same macro-expansion and
;; specialization as build/run/test.
(cfg
  compile-startup-profile
  (import compiler_startup_profile as startup_profile))
(import stdlib.io)
(import compiler_build_identity as build_identity)

;; Keep legacy root aliases for reader enum variants while stage0 expands the
;; build-version cfg declarations below. Dotted imports in the CLI cores share
;; the same `read` module; importing it unqualified here preserves both views.
;; lint-allow: unused-import -- the import's legacy alias side effect is required.
(import read)
(import "build_cli_core.tl")
(import "run_cli_core.tl")
(import "check_cli_core.tl")
(import "format_cli_core.tl")
(import "lint_driver_core.tl")
(import "test_cli_core.tl")
(import "doc_cli_core.tl")
(import "compile_cli_core.tl")
(import "clean_cli_core.tl")
(import "inspect_cli_core.tl")
(import "repl_cli_core.tl")
(import "scaffold_cli_core.tl")
(import "lsp_frame_core.tl")
(import stdlib.string)

(cfg
  stage0-build-version
  (include-str cli-build-date "../target/build-stage0/build-date.txt"))

(cfg
  (not stage0-build-version)
  (define cli-build-date : String
    "unknown"))

(define (cli-argc) : i64
  (arg-count))

(define (cli-arg [index : i64]) : String
  (io.arg index))

(define (cli-err [text : String]) : unit
  (io.print-error text))

(define (cli-eq? [left : String] [right : String]) : bool
  (string.eq left right))

(define (cli-cat [left : String] [right : String]) : String
  (string.append left right))

;; Keeps the shipped stage0 help surface stable while individual commands route
;; through selfhost entry points. The unified selfhost CLI presents the same
;; help surface as the published stage0 driver.
(define (cli-help-text) : String
  "Synopsis:
    typelisp - A typed Lisp/Scheme dialect with x86_64 backend

Usage:
    typelisp <command> [options]
    typelisp <command> --help

Commands:
    typelisp build          Build a source file or package artifact
    typelisp check          Type check a source file or package
    typelisp clean          Remove build artifacts
    typelisp compile        Generate assembly or IR
    typelisp doc            Generate documentation or run doc tests
    typelisp fmt            Format source files or a package
    typelisp init           Scaffold a package in the current directory
    typelisp inspect        Inspect a TypeLisp comptime image
    typelisp lint           Lint source files or a package
    typelisp lsp            Start stdio LSP diagnostics server
    typelisp new            Scaffold a new package directory
    typelisp repl           Start minimal stdio REPL
    typelisp run            Compile, link, and run a source file or package
    typelisp test           Run or check inline tests

Global Options:
    --help, -h                     Show root or command help
    --version                      Show the compiler build git hash and date

Common Command Options:
    --target <target>              linux-x86_64 or windows-x86_64
    --backend-mode <mode>          scalar, avx2, or avx512
    --manifest-path <file>         Package manifest path
    --stdlib-root <dir>            Search root for stdlib/... imports
    --opt-level <0|1|2>            Select optimizer level
    --debug, -g                    Emit source line and unwind debug information
    --cfg <name>                   Enable a compile-time cfg predicate name

Environment:
    TYPELISP_STDLIB_ROOT           Optional fallback root before embedded stdlib

Run `typelisp <command> --help` for command-specific usage.
")

(define (cli-build-help-text) : String
  "Usage:
    typelisp build <file.tl> [-o <exe>] [--debug|-g] [--target <target>] [--backend-mode <mode>] [--stdlib-root <dir>...]
    typelisp build [--manifest-path <typelisp.pkg>] [--debug|-g] [--profile dev|release] [--release] [--locked|--update-lock] [--target <target>] [--backend-mode <mode>] [--opt-level <0|1|2>] [--stdlib-root <dir>...]

Summary:
    Build a source file or package artifact.

Options:
    -o <exe>                       Source build executable output path
    --manifest-path <file>         Defaults to nearest typelisp.pkg upward
    --profile dev|release          Package build profile (default release)
    --release                      Alias for --profile release
    --target <target>              linux-x86_64 or windows-x86_64
    --backend-mode <mode>          scalar, avx2, or avx512
    --opt-level <0|1|2>            Override package optimizer level (release 2, dev 0)
    --debug, -g                    Emit line tables and linker debug information
    --locked                       Require matching typelisp.lock; do not rewrite
    --update-lock                  Refresh remote pins and rewrite typelisp.lock
    --link-lib <name>              Link a named native library for source builds
    --link-search <dir>            Add a native linker library search directory
    --link-arg <arg>               Pass a raw native linker argument
    --stdlib-root <dir>            Search root for stdlib/... imports
")

(define (cli-clean-help-text) : String
  "Usage:
    typelisp clean [<file.tl>] [--manifest-path <typelisp.pkg>] [--dry-run]
    typelisp clean --experiments [--manifest-path <typelisp.pkg>] [--dry-run]

Summary:
    Remove source, package, or dedicated ad-hoc experiment artifacts.

Options:
    --dry-run                      List artifacts without deleting them
    --experiments                  Remove only target/exp at the package root
    --manifest-path <file>         Defaults to nearest typelisp.pkg upward
")

(define (cli-run-help-text) : String
  "Usage:
    typelisp run <file.tl> [--debug|-g] [--target <target>] [--backend-mode <mode>] [--stdlib-root <dir>...] [--cfg <name>...] [-- args...]
    typelisp run [--manifest-path <typelisp.pkg>] [--debug|-g] [--profile dev|release] [--release] [--locked|--update-lock] [--target <target>] [--backend-mode <mode>] [--opt-level <0|1|2>] [--stdlib-root <dir>...] [-- args...]

Summary:
    Compile, link, and run a source file or package binary.

Options:
    --manifest-path <file>         Defaults to nearest typelisp.pkg upward for package runs
    --profile dev|release          Package build profile (default release)
    --release                      Alias for --profile release
    --locked                       Require matching typelisp.lock; do not rewrite
    --update-lock                  Refresh remote pins and rewrite typelisp.lock
    --target <target>              linux-x86_64 or windows-x86_64
    --backend-mode <mode>          scalar, avx2, or avx512
    --opt-level <0|1|2>            Select optimizer level
    --debug, -g                    Emit line tables and linker debug information
    --stdlib-root <dir>            Search root for stdlib/... imports
    --cfg <name>                   Enable a compile-time cfg predicate name for source runs
    --link-lib <name>              Link a named native library for source runs
    --link-search <dir>            Add a native linker library search directory for source runs
    --link-arg <arg>               Pass a raw native linker argument for source runs
")

(define (cli-check-help-text) : String
  "Usage:
    typelisp check [<file.tl>] [--manifest-path <typelisp.pkg>] [--target <target>] [--cfg <name>...] [--stdlib-root <dir>...]

Summary:
    Type check a source file or package.

Options:
    --manifest-path <file>         Defaults to nearest typelisp.pkg upward
    --target <target>              linux-x86_64 or windows-x86_64
    --cfg <name>                   Enable a compile-time cfg predicate name
    --stdlib-root <dir>            Search root for stdlib/... imports
")

(define (cli-fmt-help-text) : String
  "Usage:
    typelisp fmt [<file.tl>...] [--check] [--manifest-path <typelisp.pkg>] [--target <target>] [--cfg <name>...] [--stdlib-root <dir>...]

Summary:
    Format source files or every source in a package.

Options:
    --check                        Report files that would change without writing them
    --manifest-path <file>         Defaults to nearest typelisp.pkg upward
    --target <target>              linux-x86_64 or windows-x86_64
    --cfg <name>                   Accept cfg selection; every CST branch remains formatted
    --stdlib-root <dir>            Search root for stdlib/... imports
")

(define (cli-lint-help-text) : String
  "Usage:
    typelisp lint [<file.tl>...] [--check] [--deprecated-string-concat] [--redundant-function-name] [--prefer-dotted-field] [--name-case] [--legacy-path-import] [--manifest-path <typelisp.pkg>] [--target <target>] [--cfg <name>...] [--stdlib-root <dir>...]

Summary:
    Lint source files or every source in a package.

Options:
    --check                        Exit non-zero when lint findings are present
    --deprecated-string-concat     Enable staged string concat deprecation lint
    --redundant-function-name      Enable staged redundant module-prefix lint
    --prefer-dotted-field          Enable staged simple struct-get dotted field lint
    --name-case                    Enable staged declaration/binder casing lints
    --legacy-path-import           Enable staged string-path import migration lint
    --manifest-path <file>         Defaults to nearest typelisp.pkg upward
    --target <target>              linux-x86_64 or windows-x86_64
    --cfg <name>                   Enable a compile-time cfg predicate name
    --stdlib-root <dir>            Search root for stdlib/... imports
")

(define (cli-test-help-text) : String
  "Usage:
    typelisp test [--check] [--filter <substring>] [<file.tl>] [--manifest-path <typelisp.pkg>] [--target <target>] [--backend-mode <mode>] [--opt-level <0|1|2>] [--stdlib-root <dir>...]
    typelisp test [--check] [--filter <substring>] --batch <inputs.txt> [--target <target>] [--backend-mode <mode>] [--opt-level <0|1|2>] [--stdlib-root <dir>...] [--prefix-cache-stats]
    typelisp test --list [--filter <substring>] [<file.tl>] [--manifest-path <typelisp.pkg>] [--batch <inputs.txt>] [--stdlib-root <dir>...]

Summary:
    Run or typecheck inline `(test ...)` declarations.

Options:
    --check                        Typecheck inline tests without running them
    --filter <substring>           Select inline-test names and package integration paths containing text
    --list                         List selected test names without running them
    --batch <file>                 Read newline-separated inline-test input paths; runs them unless --check
    --prefix-cache-stats           Print typecheck prefix-cache stats for a batch
    --manifest-path <file>         Defaults to nearest typelisp.pkg upward when no file is provided
    --target <target>              linux-x86_64 or windows-x86_64
    --backend-mode <mode>          scalar, avx2, or avx512
    --opt-level <0|1|2>            Select selfhost test harness optimization
    --stdlib-root <dir>            Search root for stdlib/... imports
")

(define (cli-doc-help-text) : String
  "Usage:
    typelisp doc <file.tl> [<out.md>|-o <out.md>] [--stdlib-root <dir>...]
    typelisp doc -o <out.md> [--manifest-path <typelisp.pkg>] [--stdlib-root <dir>...]
    typelisp doc --test [<file.tl>...] [--manifest-path <typelisp.pkg>] [--stdlib-root <dir>...]
    typelisp doc --test --batch <inputs.txt> [--stdlib-root <dir>...] [--prefix-cache-stats]
    typelisp doc --html <file.tl> [<imported.tl>...] <out.html>
    typelisp doc --load <file.tl> <out.md> [--stdlib-root <dir>...]

Summary:
    Generate documentation or check TypeLisp fenced examples.

Options:
    -o <out.md>                    Output markdown path
    --test                         Check TypeLisp fenced examples in docs
    --batch <file>                 Read newline-separated doc-test input paths
    --prefix-cache-stats           Print typecheck prefix-cache stats for a batch
    --manifest-path <file>         Defaults to nearest typelisp.pkg upward for package docs
    --stdlib-root <dir>            Search root for stdlib/... imports
")

(define (cli-compile-help-text) : String
  "Usage:
    typelisp compile <file.tl> [-o <file>] [--debug|-g] [--emit-ir | --dump-ir [after-<pass>]] [--verify-ir] [--trace-passes] [--pic] [--target <target>] [--backend-mode <mode>] [--opt-level <0|1|2>] [--stdlib-root <dir>...] [--cfg <name>...] [--profile-allocations]
    typelisp compile --batch <input-output-list> [--debug|-g] [--target <target>] [--backend-mode <mode>] [--opt-level <0|1|2>] [--stdlib-root <dir>...] [--cfg <name>...] [--prefix-cache-stats] [--profile-allocations]
    typelisp compile --batch <artifact-list> --windows-coff-plan <result-plan> --target windows-x86_64 [--debug|-g] [--backend-mode <mode>] [--opt-level <0|1|2>] [--stdlib-root <dir>...] [--cfg <name>...] [--prefix-cache-stats] [--profile-allocations]

Summary:
    Generate assembly, an IR summary, or a deterministic textual IR dump.

Options:
    -o <file>                      Output assembly or IR file
    --batch <file>                 Read input|output pairs and compile them in one process
    --windows-coff-plan <file>     Read input|object|assembly[|force-assembly] rows and write source|kind|path|reason results
    --prefix-cache-stats           Print typecheck prefix-cache stats for a batch
    --emit-ir                      Emit intermediate representation
    --dump-ir [after-<pass>]       Emit textual IR, optionally after a pass
    --verify-ir                    Verify optimized IR before writing output
    --trace-passes                 Trace optimizer pass/function sizes to stderr
    --pic                          Emit runtime-free no-entry PIC assembly and <output>.fixups
    --target <target>              linux-x86_64 or windows-x86_64
    --backend-mode <mode>          scalar, avx2, or avx512
    --opt-level <0|1|2>            Select optimizer level
    --debug, -g                    Emit source line and unwind debug information
    --profile-allocations          Report compiler arena ownership by phase
    --stdlib-root <dir>            Search root for stdlib/... imports
    --cfg <name>                   Enable a compile-time cfg predicate name
")

(define (cli-inspect-help-text) : String
  (tlci-inspect-help-text))

(define (cli-repl-help-text) : String
  "Usage:
    typelisp repl

Summary:
    Start the TypeLisp REPL.

REPL Commands:
    .help                          Show REPL command help
    .type <expr>                   Print the inferred type without running code
    .load <file>                   Load declarations from a source file
    .exit                          Exit the REPL
")

(define (cli-lsp-help-text) : String
  "Usage:
    typelisp lsp [--stdlib-root <dir>...] [--prefix-cache-stats]
    typelisp lsp --transcript-batch <manifest> [--stdlib-root <dir>...] [--prefix-cache-stats]

Summary:
    Start the stdio LSP diagnostics server.

Options:
    --stdlib-root <dir>            Search root for stdlib/... imports
    --prefix-cache-stats           Print typecheck prefix-cache stats on stderr when the server exits
    --transcript-batch <file>      Run file-bounded transcript sessions serially (test tooling)

Initialization options:
    target                         linux-x86_64 or windows-x86_64 (default: server host)
    cfg                            Array of compile-time cfg predicate names
    Fields may be direct or nested under initializationOptions.typelisp.
")

(define (cli-new-help-text) : String
  "Usage:
    typelisp new [--lib] <name>

Summary:
    Scaffold a new package directory.

Options:
    --lib                          Scaffold a static library package
")

(define (cli-init-help-text) : String
  "Usage:
    typelisp init [--lib] <name>

Summary:
    Scaffold a package in the current directory.

Options:
    --lib                          Scaffold a static library package
")

(define (cli-help-flag? [value : String]) : bool
  (or (cli-eq? value "--help") (cli-eq? value "-h")))

(define (cli-subcommand-help-request? [count : i64]) : bool
  (and (= count 3) (cli-help-flag? (cli-arg 2))))

(define (cli-print-help-text [text : String] [code : i64]) : i64
  (begin
    (cli-err text)
    code))

(define (cli-print-help [code : i64]) : i64
  (cli-print-help-text (cli-help-text) code))

(define (cli-print-version) : i64
  (begin
    (io.print-string
      (cli-cat
        "typelisp "
        (cli-cat
          build_identity.compiler-build-git-hash
          (cli-cat " built " (cli-cat cli-build-date "\n")))))
    0))

(define (cli-print-producer-identity) : i64
  (begin
    (io.print-string (cli-cat build_identity.compiler-build-git-hash "\n"))
    0))

(define (cli-dispatch [command : String] [count : i64]) : i64
  (cond
    [(or
        (cli-eq? command "help")
        (cli-eq? command "--help")
        (cli-eq? command "-h"))
      (cli-print-help 0)]
    [(cli-eq? command "--version") (cli-print-version)]
    [(cli-eq? command "--producer-identity") (cli-print-producer-identity)]
    [(cli-eq? command "build")
      (if (cli-subcommand-help-request? count)
        (cli-print-help-text (cli-build-help-text) 0)
        (build-run-from 2 count build_identity.compiler-build-git-hash))]
    [(cli-eq? command "clean")
      (if (cli-subcommand-help-request? count)
        (cli-print-help-text (cli-clean-help-text) 0)
        (clean-run-from 2 count))]
    [(cli-eq? command "run")
      (if (cli-subcommand-help-request? count)
        (cli-print-help-text (cli-run-help-text) 0)
        (run-run-from 2 count build_identity.compiler-build-git-hash))]
    [(cli-eq? command "check")
      (if (cli-subcommand-help-request? count)
        (cli-print-help-text (cli-check-help-text) 0)
        (selfhost-check-run-from 2 count))]
    [(cli-eq? command "fmt")
      (if (cli-subcommand-help-request? count)
        (cli-print-help-text (cli-fmt-help-text) 0)
        (fmt-run-from 2 count))]
    [(cli-eq? command "lint")
      (if (cli-subcommand-help-request? count)
        (cli-print-help-text (cli-lint-help-text) 0)
        (selfhost-lint-run-from 2 count))]
    [(cli-eq? command "test")
      (if (cli-subcommand-help-request? count)
        (cli-print-help-text (cli-test-help-text) 0)
        (tltest-run-from 2 count))]
    [(cli-eq? command "doc")
      (if (cli-subcommand-help-request? count)
        (cli-print-help-text (cli-doc-help-text) 0)
        (doc-run-from 2 count))]
    [(cli-eq? command "compile")
      (if (cli-subcommand-help-request? count)
        (cli-print-help-text (cli-compile-help-text) 0)
        (compile-cli-run count))]
    [(cli-eq? command "inspect")
      (if (cli-subcommand-help-request? count)
        (cli-print-help-text (cli-inspect-help-text) 0)
        (tlci-inspect-run-from 2 count))]
    [(cli-eq? command "lsp")
      (if (cli-subcommand-help-request? count)
        (cli-print-help-text (cli-lsp-help-text) 0)
        (lsp-frame-run-from 2 count))]
    [(cli-eq? command "repl")
      (if (cli-subcommand-help-request? count)
        (cli-print-help-text (cli-repl-help-text) 0)
        (repl-run-from 2 count))]
    [(cli-eq? command "new")
      (if (cli-subcommand-help-request? count)
        (cli-print-help-text (cli-new-help-text) 0)
        (scaffold-new-run-from 2 count))]
    [(cli-eq? command "init")
      (if (cli-subcommand-help-request? count)
        (cli-print-help-text (cli-init-help-text) 0)
        (scaffold-init-run-from 2 count))]
    [else
      (begin
        (cli-err (cli-cat "typelisp: unknown subcommand " command))
        (cli-err "\n\n")
        (cli-print-help 1))]))

(define (main) : i64
  (begin
    (cfg
      compile-startup-profile
      (startup_profile.compiler-startup-profile-mark-main-entry!)
      unit)
    (if (< (cli-argc) 2)
      (cli-print-help 1)
      (cli-dispatch (cli-arg 1) (cli-argc)))))
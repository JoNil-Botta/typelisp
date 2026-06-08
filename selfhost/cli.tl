;; cli.tl - Unified pure-TypeLisp toolchain dispatcher.
;;
;; A single self-hosted entry point that dispatches every toolchain subcommand
;; in-process, instead of compiling and spawning a separate per-command driver
;; (build.tl, run.tl, check.tl, format.tl, lint.tl, test.tl, doc.tl). Each
;; command's logic lives in a main-free `*_cli_core.tl` (or `*_driver_core.tl`)
;; module shared with retained compatibility/coverage wrappers, so this file
;; only routes:
;;
;;   typelisp run selfhost/cli.tl -- <command> <args...>
;;
;; Recognized commands: build, run, check, fmt, lint, test, doc, compile, clean,
;; repl, lsp, new, and init. The command name is `(arg 1)`; each `*-run-from`
;; entry parses its own arguments starting at index 2.
;;
;; This is the shipped Rust-free stage0 dispatcher (#666/#795): the toolchain
;; needs neither a host-language compiler driver nor per-command driver
;; recompilation. Every command shares the single full typechecker frontend
;; (`compiler_check_core` ->
;; `compiler_typecheck`), so `check` does the same macro-expansion and
;; specialization as build/run/test.
(import "../stdlib/io.tl")

(import "build_cli_core.tl")

(import "run_cli_core.tl")

(import "check_cli_core.tl")

(import "format_cli_core.tl")

(import "lint_driver_core.tl")

(import "test_cli_core.tl")

(import "doc_cli_core.tl")

(import "compile_cli_core.tl")

(import "clean_cli_core.tl")

(import "repl_cli_core.tl")

(import "scaffold_cli_core.tl")

(import "lsp_frame_core.tl")

(import "../stdlib/string.tl")

;; Keeps the shipped stage0 help surface stable while individual commands route
;; through selfhost entry points. The unified selfhost CLI presents the same
;; help surface as the published stage0 driver.
(define (cli-help-text) : String
  "typelisp â€” A typed Lisp/Scheme dialect with x86_64 backend

Usage:
    typelisp lsp                            Start stdio LSP diagnostics server
    typelisp repl                           Start minimal stdio REPL
    typelisp check [<file.tl>] [--manifest-path <typelisp.pkg>] [--stdlib-root <dir>...]
    typelisp compile <file.tl> [-o <file>] [--emit-ir] [--target <target>] [--backend-mode <mode>] [--stdlib-root <dir>...] [--cfg <name>...]
    typelisp run <file.tl> [--target <target>] [--backend-mode <mode>] [--stdlib-root <dir>...] [-- args...]
    typelisp build <file.tl> [-o <exe>] [--target <target>] [--backend-mode <mode>] [--stdlib-root <dir>...]
    typelisp build [--manifest-path <typelisp.pkg>] [--profile dev|release] [--release] [--target <target>] [--backend-mode <mode>] [--opt-level <0|1|2>] [--stdlib-root <dir>...]
    typelisp clean [<file.tl>] [--manifest-path <typelisp.pkg>] [--dry-run]
    typelisp fmt [<file.tl>...] [--check] [--manifest-path <typelisp.pkg>] [--stdlib-root <dir>...]
    typelisp lint [<file.tl>...] [--check] [--manifest-path <typelisp.pkg>] [--stdlib-root <dir>...]
    typelisp test [--check] [<file.tl>] [--manifest-path <typelisp.pkg>] [--target <target>] [--opt-level <0|1|2>] [--stdlib-root <dir>...]
    typelisp doc <file.tl> [<out.md>|-o <out.md>] [--stdlib-root <dir>...]
    typelisp doc -o <out.md> [--manifest-path <typelisp.pkg>] [--stdlib-root <dir>...]
    typelisp doc --test [<file.tl>...] [--manifest-path <typelisp.pkg>] [--stdlib-root <dir>...]
    typelisp new [--lib] <name>    Scaffold a new package in <name>/
    typelisp init [--lib] <name>   Scaffold a package in the current directory

    --emit-ir                      Emit intermediate representation
    --link-lib <name>              Link a named native library for source build/run
    --link-search <dir>            Add a native linker library search directory
    --link-arg <arg>               Pass a raw native linker argument
    --backend-mode <mode>          scalar, avx2, or avx512; avx2/avx512 support simple foreach maps
    --target <target>              linux-x86_64 or windows-x86_64
    --manifest-path <file>         Package manifest for build/check/clean/fmt/lint/doc
    --stdlib-root <dir>            Search root for stdlib/... imports before env/embedded fallback
    --cfg <name>                   Enable a compile-time cfg predicate name
    TYPELISP_STDLIB_ROOT           Optional fallback root before embedded stdlib

Options for compile:
    -o <file>                      Output assembly file
Options for build:
    -o <exe>                       Source build executable output path
    --manifest-path <file>         Defaults to nearest typelisp.pkg upward
    --profile dev|release          Package build profile (default release)
    --release                      Alias for --profile release
    --opt-level <0|1|2>          Package-build optimizer level (default 1; 0 skips it)
Options for clean:
    --dry-run                      List artifacts without deleting them
    --manifest-path <file>         Defaults to nearest typelisp.pkg upward
Options for check:
    --manifest-path <file>         Defaults to nearest typelisp.pkg upward
Options for fmt:
    --check                        Report files that would change without writing them
    --manifest-path <file>         Defaults to nearest typelisp.pkg upward
Options for lint:
    --check                        Exit non-zero when lint findings are present
    --manifest-path <file>         Defaults to nearest typelisp.pkg upward
Options for test:
    --check                        Typecheck inline tests without running them
    --manifest-path <file>         Defaults to nearest typelisp.pkg upward when no file is provided
    --opt-level <0|1|2>          Select selfhost test harness optimization
Options for doc:
    --test [<file.tl>...]          Check TypeLisp fenced examples in docs
    --manifest-path <file>         Defaults to nearest typelisp.pkg upward for package docs
")

(define (cli-build-help-text) : String
  "Usage:
    typelisp build <file.tl> [-o <exe>] [--target <target>] [--backend-mode <mode>] [--stdlib-root <dir>...]
    typelisp build [--manifest-path <typelisp.pkg>] [--profile dev|release] [--release] [--target <target>] [--backend-mode <mode>] [--opt-level <0|1|2>] [--stdlib-root <dir>...]

Options:
    -o <exe>                       Source build executable output path
    --manifest-path <file>         Defaults to nearest typelisp.pkg upward
    --profile dev|release          Package build profile (default release)
    --release                      Alias for --profile release
    --target <target>              linux-x86_64 or windows-x86_64
    --backend-mode <mode>          scalar, avx2, or avx512
    --opt-level <0|1|2>            Package-build optimizer level
    --link-lib <name>              Link a named native library for source builds
    --link-search <dir>            Add a native linker library search directory
    --link-arg <arg>               Pass a raw native linker argument
    --stdlib-root <dir>            Search root for stdlib/... imports
")

(define (cli-clean-help-text) : String
  "Usage:
    typelisp clean [<file.tl>] [--manifest-path <typelisp.pkg>] [--dry-run]

Options:
    --dry-run                      List artifacts without deleting them
    --manifest-path <file>         Defaults to nearest typelisp.pkg upward
")

(define (cli-run-help-text) : String
  "Usage:
    typelisp run <file.tl> [--target <target>] [--backend-mode <mode>] [--stdlib-root <dir>...] [-- args...]

Options:
    --target <target>              linux-x86_64 or windows-x86_64
    --backend-mode <mode>          scalar, avx2, or avx512
    --opt-level <0|1|2>            Select optimizer level
    --stdlib-root <dir>            Search root for stdlib/... imports
    --link-lib <name>              Link a named native library
    --link-search <dir>            Add a native linker library search directory
    --link-arg <arg>               Pass a raw native linker argument
")

(define (cli-check-help-text) : String
  "Usage:
    typelisp check [<file.tl>] [--manifest-path <typelisp.pkg>] [--stdlib-root <dir>...]

Options:
    --manifest-path <file>         Defaults to nearest typelisp.pkg upward
    --stdlib-root <dir>            Search root for stdlib/... imports
")

(define (cli-fmt-help-text) : String
  "Usage:
    typelisp fmt [<file.tl>...] [--check] [--manifest-path <typelisp.pkg>] [--stdlib-root <dir>...]

Options:
    --check                        Report files that would change without writing them
    --manifest-path <file>         Defaults to nearest typelisp.pkg upward
    --stdlib-root <dir>            Search root for stdlib/... imports
")

(define (cli-lint-help-text) : String
  "Usage:
    typelisp lint [<file.tl>...] [--check] [--manifest-path <typelisp.pkg>] [--stdlib-root <dir>...]

Options:
    --check                        Exit non-zero when lint findings are present
    --manifest-path <file>         Defaults to nearest typelisp.pkg upward
    --stdlib-root <dir>            Search root for stdlib/... imports
")

(define (cli-test-help-text) : String
  "Usage:
    typelisp test [--check] [<file.tl>] [--manifest-path <typelisp.pkg>] [--target <target>] [--opt-level <0|1|2>] [--stdlib-root <dir>...]

Options:
    --check                        Typecheck inline tests without running them
    --manifest-path <file>         Defaults to nearest typelisp.pkg upward when no file is provided
    --target <target>              linux-x86_64 or windows-x86_64
    --opt-level <0|1|2>            Select selfhost test harness optimization
    --stdlib-root <dir>            Search root for stdlib/... imports
")

(define (cli-doc-help-text) : String
  "Usage:
    typelisp doc <file.tl> [<out.md>|-o <out.md>] [--stdlib-root <dir>...]
    typelisp doc -o <out.md> [--manifest-path <typelisp.pkg>] [--stdlib-root <dir>...]
    typelisp doc --test [<file.tl>...] [--manifest-path <typelisp.pkg>] [--stdlib-root <dir>...]
    typelisp doc --html <file.tl> [<imported.tl>...] <out.html>
    typelisp doc --load <file.tl> <out.md> [--stdlib-root <dir>...]

Options:
    -o <out.md>                    Output markdown path
    --test                         Check TypeLisp fenced examples in docs
    --manifest-path <file>         Defaults to nearest typelisp.pkg upward for package docs
    --stdlib-root <dir>            Search root for stdlib/... imports
")

(define (cli-compile-help-text) : String
  "Usage:
    typelisp compile <file.tl> [-o <file>] [--emit-ir] [--target <target>] [--backend-mode <mode>] [--opt-level <0|1|2>] [--stdlib-root <dir>...] [--cfg <name>...]

Options:
    -o <file>                      Output assembly or IR file
    --emit-ir                      Emit intermediate representation
    --target <target>              linux-x86_64 or windows-x86_64
    --backend-mode <mode>          scalar, avx2, or avx512
    --opt-level <0|1|2>            Select optimizer level
    --stdlib-root <dir>            Search root for stdlib/... imports
    --cfg <name>                   Enable a compile-time cfg predicate name
")

(define (cli-repl-help-text) : String
  "Usage:
    typelisp repl

Starts the TypeLisp REPL.

REPL commands:
    .help                          Show REPL command help
    .type <expr>                   Print the inferred type without running code
    .exit                          Exit the REPL
")

(define (cli-lsp-help-text) : String
  "Usage:
    typelisp lsp [--stdlib-root <dir>...]

Starts the stdio LSP diagnostics server.

Options:
    --stdlib-root <dir>            Search root for stdlib/... imports
")

(define (cli-new-help-text) : String
  "Usage:
    typelisp new [--lib] <name>

Options:
    --lib                          Scaffold a static library package
")

(define (cli-init-help-text) : String
  "Usage:
    typelisp init [--lib] <name>

Options:
    --lib                          Scaffold a static library package
")

(define (cli-help-flag? [value : String]) : bool
  (or (string-eq value "--help") (string-eq value "-h")))

(define (cli-subcommand-help-request? [count : i64]) : bool
  (and (= count 3) (cli-help-flag? (arg 2))))

(define (cli-print-help-text [text : String] [code : i64]) : i64
  (begin
    (print-error text)
    code))

(define (cli-print-help [code : i64]) : i64
  (cli-print-help-text (cli-help-text) code))

;; A stage0 command listed in the help but not yet wired into the selfhost CLI.
(define (cli-pending [command : String] [issue : String]) : i64
  (begin
    (print-error
      (string-append
        "typelisp: '"
        (string-append
          command
          (string-append
            "' is not yet available in the selfhost CLI (tracked in "
            (string-append issue ")\n")))))
    1))

(define (cli-dispatch [command : String] [count : i64]) : i64
  (cond
    [(or
        (string-eq command "help")
        (or (string-eq command "--help") (string-eq command "-h")))
      (cli-print-help 0)]
    [(string-eq command "build")
      (if (cli-subcommand-help-request? count)
        (cli-print-help-text (cli-build-help-text) 0)
        (build-run-from 2 count))]
    [(string-eq command "clean")
      (if (cli-subcommand-help-request? count)
        (cli-print-help-text (cli-clean-help-text) 0)
        (clean-run-from 2 count))]
    [(string-eq command "run")
      (if (cli-subcommand-help-request? count)
        (cli-print-help-text (cli-run-help-text) 0)
        (run-run-from 2 count))]
    [(string-eq command "check")
      (if (cli-subcommand-help-request? count)
        (cli-print-help-text (cli-check-help-text) 0)
        (selfhost-check-run-from 2 count))]
    [(string-eq command "fmt")
      (if (cli-subcommand-help-request? count)
        (cli-print-help-text (cli-fmt-help-text) 0)
        (fmt-run-from 2 count))]
    [(string-eq command "lint")
      (if (cli-subcommand-help-request? count)
        (cli-print-help-text (cli-lint-help-text) 0)
        (selfhost-lint-run-from 2 count))]
    [(string-eq command "test")
      (if (cli-subcommand-help-request? count)
        (cli-print-help-text (cli-test-help-text) 0)
        (tltest-run-from 2 count))]
    [(string-eq command "doc")
      (if (cli-subcommand-help-request? count)
        (cli-print-help-text (cli-doc-help-text) 0)
        (doc-run-from 2 count))]
    ;; The compiler command shares compile_cli_core (#1639); it reads (arg 1) as
    ;; the command, so the whole CLI is driven from this one binary.
    [(string-eq command "compile")
      (if (cli-subcommand-help-request? count)
        (cli-print-help-text (cli-compile-help-text) 0)
        (compile-cli-run count))]
    [(string-eq command "lsp")
      (if (cli-subcommand-help-request? count)
        (cli-print-help-text (cli-lsp-help-text) 0)
        (lsp-frame-run-from 2 count))]
    [(string-eq command "repl")
      (if (cli-subcommand-help-request? count)
        (cli-print-help-text (cli-repl-help-text) 0)
        (repl-run-from 2 count))]
    [(string-eq command "new")
      (if (cli-subcommand-help-request? count)
        (cli-print-help-text (cli-new-help-text) 0)
        (scaffold-new-run-from 2 count))]
    [(string-eq command "init")
      (if (cli-subcommand-help-request? count)
        (cli-print-help-text (cli-init-help-text) 0)
        (scaffold-init-run-from 2 count))]
    [else
      (begin
        (print-error (string-append "typelisp: unknown subcommand " command))
        (print-error "\n\n")
        (cli-print-help 1))]))

(define (main) : i64
  (if (< (arg-count) 2)
    (cli-print-help 1)
    (cli-dispatch (arg 1) (arg-count))))
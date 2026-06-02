;; cli.tl - Unified pure-TypeLisp toolchain dispatcher.
;;
;; A single self-hosted entry point that dispatches every toolchain subcommand
;; in-process, instead of compiling and spawning a separate per-command driver
;; (build.tl, run.tl, check.tl, format.tl, lint.tl, test.tl, doc.tl). Each
;; command's logic lives in a main-free `*_cli_core.tl` (or `*_driver_core.tl`)
;; module shared with its standalone driver, so this file only routes:
;;
;;   typelisp run selfhost/cli.tl -- <command> <args...>
;;
;; Recognized commands: build, run, check, fmt, lint, test, doc. The command
;; name is `(arg 1)`; each `*-run-from` entry parses its own arguments starting
;; at index 2.
;;
;; This is the single-binary step toward a Rust-free stage0 (#666/#795): once
;; this dispatcher is the shipped `typelisp`, the toolchain needs neither the
;; Rust host driver nor per-command driver recompilation. Every command shares
;; the single full typechecker frontend (`compiler_check_core` ->
;; `compiler_typecheck`), so `check` does the same macro-expansion and
;; specialization as build/run/test.
(import "build_cli_core.tl")

(import "run_cli_core.tl")

(import "check_cli_core.tl")

(import "format_cli_core.tl")

(import "lint_driver_core.tl")

(import "test_cli_core.tl")

(import "doc_cli_core.tl")

(import "compile_cli_core.tl")

(import "repl_cli_core.tl")

;; Mirrors the Rust stage0 `print_usage` (src/main.rs) so the unified selfhost
;; CLI presents the same help surface. Commands not yet routed here (lsp, new,
;; init) are still listed for parity but report their tracking issue when
;; invoked (see cli-pending), so the help matches stage0 without pretending the
;; command works yet.
(define (cli-help-text) : String
  "typelisp — A typed Lisp/Scheme dialect with x86_64 backend

Usage:
    typelisp debug tokenize <file.tl>    Show tokens
    typelisp debug parse <file.tl>       Show AST
    typelisp debug check <file.tl> [--stdlib-root <dir>...]
    typelisp lsp                            Start stdio LSP diagnostics server
    typelisp repl                           Start minimal stdio REPL
    typelisp check <file.tl> [--stdlib-root <dir>...]
    typelisp compile <file.tl> [-o <file>] [--emit-ir] [--target <target>] [--backend-mode <mode>] [--stdlib-root <dir>...]
    typelisp run <file.tl> [--target <target>] [--backend-mode <mode>] [--stdlib-root <dir>...] [-- args...]
    typelisp build <file.tl> [-o <exe>] [--target <target>] [--backend-mode <mode>] [--stdlib-root <dir>...]
    typelisp build [--manifest-path <typelisp.pkg>] [--target <target>] [--backend-mode <mode>] [--opt-level <0|1|2|3>] [--stdlib-root <dir>...]
    typelisp fmt [--check] <file.tl>... [--stdlib-root <dir>...]
    typelisp lint <file.tl> [--stdlib-root <dir>...]
    typelisp test [--check] <file.tl> [--target <target>] [--opt-level <0|1|2|3>] [--stdlib-root <dir>...]
    typelisp doc <file.tl> [-o <out.md>] [--stdlib-root <dir>...]
    typelisp doc --test <file.tl> [--stdlib-root <dir>...]
    typelisp new [--lib] <name>    Scaffold a new package in <name>/
    typelisp init [--lib] <name>   Scaffold a package in the current directory

    --emit-ir                      Emit intermediate representation
    --link-lib <name>              Link a named native library for source build/run
    --link-search <dir>            Add a native linker library search directory
    --link-arg <arg>               Pass a raw native linker argument
    --backend-mode <mode>          scalar, avx2, or avx512; avx2/avx512 support simple foreach maps
    --target <target>              linux-x86_64 or windows-x86_64
    --manifest-path <file>         Package manifest for build
    --stdlib-root <dir>            Search root for stdlib/... imports before env/embedded fallback
    TYPELISP_STDLIB_ROOT           Optional fallback root before embedded stdlib

Options for compile:
    -o <file>                      Output assembly file
Options for build:
    -o <exe>                       Source build executable output path
    --manifest-path <file>         Defaults to nearest typelisp.pkg upward
    --opt-level <0|1|2|3>          Package-build optimizer level (default 2; 0 skips it)
Options for fmt:
    --check                        Report files that would change without writing them
Options for test:
    --check                        Typecheck inline tests without running them
    --opt-level <0|1|2|3>          Select selfhost test harness optimization
Options for doc:
    --test <file.tl>               Check TypeLisp fenced examples in docs
")

(define (cli-print-help [code : i64]) : i64
  (begin
    (print-error (cli-help-text))
    code))

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
    [(string-eq command "build") (build-run-from 2 count)]
    [(string-eq command "run") (run-run-from 2 count)]
    [(string-eq command "check") (selfhost-check-run-from 2 count)]
    [(string-eq command "fmt") (fmt-run-from 2 count)]
    [(string-eq command "lint") (selfhost-lint-run-from 2 count)]
    [(string-eq command "test") (tltest-run-from 2 count)]
    [(string-eq command "doc") (doc-run-from 2 count)]
    ;; The compiler commands share compile_cli_core (#1639); it reads (arg 1) as
    ;; the command, so the whole CLI is driven from this one binary. tokenize and
    ;; parse are reached via their canonical `debug` forms (no top-level aliases).
    [(string-eq command "compile") (compile-cli-run count)]
    [(string-eq command "debug") (compile-cli-run count)]
    ;; Listed in the help for stage0 parity; wiring tracked under #1638.
    [(string-eq command "lsp") (cli-pending "lsp" "#1640")]
    [(string-eq command "repl") (repl-run-from 2 count)]
    [(string-eq command "new") (cli-pending "new" "#1642")]
    [(string-eq command "init") (cli-pending "init" "#1642")]
    [else
      (begin
        (print-error (string-append "typelisp: unknown subcommand " command))
        (print-error "\n\n")
        (cli-print-help 1))]))

(define (main) : i64
  (if (< (arg-count) 2)
    (cli-print-help 1)
    (cli-dispatch (arg 1) (arg-count))))
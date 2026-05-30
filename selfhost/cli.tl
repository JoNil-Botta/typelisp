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

(define (cli-usage) : i64
  (begin
    (print-error
      "typelisp: expected a subcommand: build, run, check, fmt, lint, test, doc\n")
    1))

(define (cli-dispatch [command : String] [count : i64]) : i64
  (cond
    [(string-eq command "build") (build-run-from 2 count)]
    [(string-eq command "run") (run-run-from 2 count)]
    [(string-eq command "check") (selfhost-check-run-from 2 count)]
    [(string-eq command "fmt") (fmt-run-from 2 count)]
    [(string-eq command "lint") (selfhost-lint-run-from 2 count)]
    [(string-eq command "test") (tltest-run-from 2 count)]
    [(string-eq command "doc") (doc-run-from 2 count)]
    [else
      (begin
        (print-error (string-append "typelisp: unknown subcommand " command))
        (print-error "\n")
        (cli-usage))]))

(define (main) : i64
  (if (< (arg-count) 2)
    (cli-usage)
    (cli-dispatch (arg 1) (arg-count))))
;; format_cli_core.tl - Self-hosted `fmt` command logic.
;;
;; The formatter CLI logic, main-free so the unified `main.tl` dispatcher and
;; the formatter tests can run the `fmt` command without duplicating a `main`.
(import compiler_owned_view as owned_view)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as fmt_svec)
(import cli_option_core as cli_option)
(import compiler_target_cfg_core as target_cfg)
(import format_tokens as tokens)
(import format_rules)
(import unified_diff_core as unified_diff)
(import package_source_core)

(defenum FmtConfig
  (File bool fmt_svec.Vec)
  (Package bool String bool))

(defenum ResultFmtConfig
  (Ok FmtConfig)
  (Err String))

(defenum ResultFmtWrite
  (Ok)
  (Err String))

(define (fmt-write-error-message [path : String] [error : io.IoError]) : String
  (str_cat.str-cat "fmt: failed to write " path ": " (io.error-message error)))

(define (fmt-try-write-formatted-file [path : String] [formatted : String]) : ResultFmtWrite
  (match (io.try-write-file (& path) (byte_buf.str-as-bytes (& formatted)))
    [(OkIoUnit) Ok]
    [(ErrIoUnit error) (Err (fmt-write-error-message path error))]))

(define (fmt-write-formatted-file [path : String] [formatted : String]) : i64
  (match (fmt-try-write-formatted-file path formatted)
    [(Ok) 0]
    [(Err message)
      (io.print-error (str_cat.str-cat message "\n"))
      1]))

(define (fmt-source-error-message
  [path : String]
  [err : tokens.FormatSourceError]) : String
  (let
    [span : tokens.FormatSourceSpan
      (tokens.format-source-error-span
        (owned_view.compiler-owned-shared-view err))]
    (str_cat.str-cat
      path
      ":"
      (string.int->string (tokens.format-source-span-start-line span))
      ":"
      (string.int->string (tokens.format-source-span-start-col span))
      ": "
      (tokens.format-source-error-message err))))

(define (fmt-config-from [start : i64] [count : i64]) : ResultFmtConfig
  (let
    [args : cli_option.CliArgs
      (cli_option.cli-args
        "fmt"
        "--stdlib-root <dir> --cfg <name> --target <target> --check --manifest-path <file>"
        start
        count)]
    [check : bool false]
    [paths : fmt_svec.Vec (fmt_svec.new)]
    [manifest-path : String ""]
    [has-manifest : bool false]
    [has-target : bool false]
    (while (cli_option.cli-args-next! (&mut args))
      (cond
        [(string.eq args.name "--target")
          (if has-target
            (cli_option.cli-args-fail!
              (&mut args)
              "fmt: --target was provided more than once")
            (match (target_cfg.compiler-target-cfg-parse
              (cli_option.cli-args-value (& args)))
              [(Ok _) (set! has-target true)]
              [(Err message)
                (cli_option.cli-args-fail!
                  (&mut args)
                  (str_cat.str-cat "fmt: " message))]))]
        ;; Formatting is CST-based and intentionally retains every cfg
        ;; branch; these options are accepted for source-tool CLI parity.
        [(or
            (string.eq args.name "--stdlib-root")
            (string.eq args.name "--cfg"))
          unit]
        [(string.eq args.name "--check") (set! check true)]
        [(string.eq args.name "--manifest-path")
          (if has-manifest
            (cli_option.cli-args-fail!
              (&mut args)
              "fmt: duplicate --manifest-path")
            (begin
              (set! manifest-path (cli_option.cli-args-value (& args)))
              (set! has-manifest true)))]
        [(cli_option.cli-flag? args.arg)
          (cli_option.cli-args-fail-arg! (&mut args) "fmt: unknown flag ")]
        [else (fmt_svec.push-ref! (&mut paths) (string.copy (& args.arg)))]))
    (cond
      [args.failed (Err args.error)]
      [(fmt_svec.is-empty? (& paths))
        (Ok (Package check manifest-path has-manifest))]
      [has-manifest
        (Err "fmt: cannot combine input paths with --manifest-path")]
      [else (Ok (FmtConfig.File check paths))])))

;; `io.stderr-write` exits 134 when stderr fails, as `io.print-error` does, so
;; this unbounded rendering either completes or ends the process.
(define (fmt-diff-stderr-sink [chunk : (& bytes)]) : i64
  (io.stderr-write chunk)
  0)

(define (fmt-check-diff [path : String] [source : String] [formatted : String]) : i64
  (match (unified_diff.render
    (& path)
    (& source)
    (& formatted)
    (unified_diff.unbounded)
    fmt-diff-stderr-sink).outcome
    [(Complete) 1]
    [_ (io.panic "fmt: unbounded stderr diff stopped early\n")]))

(define (fmt-format-file [check : bool] [path : String]) : i64
  (let
    [source : String
      (byte_buf.to-string
        (io.read-file (owned_view.compiler-owned-shared-view path)))]
    (match (format_rules.format-rules-render-source-width-result
      (owned_view.compiler-owned-shared-view source)
      80)
      [(Ok formatted)
        (if check
          (if (string.eq source formatted)
            0
            (begin
              (io.print-error
                (str_cat.str-cat
                  "fmt: would reformat "
                  (owned_view.compiler-owned-shared-view path)
                  "\n"))
              (fmt-check-diff path source formatted)))
          (if (string.eq source formatted)
            0
            (fmt-write-formatted-file path formatted)))]
      [(Err err)
        (io.print-error
          (str_cat.str-cat (fmt-source-error-message path err) "\n"))
        1])))

;; Parsing and rendering retain a complete token stream and CST. Reclaim that
;; scratch state after each file so multi-file formatter invocations do not grow
;; the process-lifetime arena with the size of the whole corpus.
(define (fmt-format-file-scoped [check : bool] [path : String]) : i64
  (with-arena file-arena (fmt-format-file check path)))

(define (fmt-files-from
  [check : bool]
  [paths : fmt_svec.Vec]
  [index : i64]
  [status : i64]) : i64
  (if (>= index (fmt_svec.len (& paths)))
    status
    (let
      [path : String (fmt_svec.get (& paths) index "")]
      [file-status : i64 (fmt-format-file-scoped check path)]
      (fmt-files-from
        check
        paths
        (+ index 1)
        (if (= status 0)
          file-status
          status)))))

(define (fmt-files [check : bool] [paths : fmt_svec.Vec] [status : i64]) : i64
  (fmt-files-from check paths 0 status))

(define (fmt-package-files-from
  [check : bool]
  [paths : fmt_svec.Vec]
  [index : i64]
  [status : i64]) : i64
  (if (>= index (fmt_svec.len (& paths)))
    status
    (let
      [path : String (fmt_svec.get (& paths) index "")]
      [file-status : i64 (fmt-format-file-scoped check path)]
      (fmt-package-files-from
        check
        paths
        (+ index 1)
        (if (= status 0)
          file-status
          status)))))

(define (fmt-package-files [check : bool] [paths : fmt_svec.Vec] [status : i64]) : i64
  (fmt-package-files-from check paths 0 status))

(define (fmt-package
  [check : bool]
  [manifest-path : String]
  [has-manifest : bool]) : i64
  (match (package_source_core.package-source-discover-for
    "fmt"
    manifest-path
    has-manifest)
    [(Err message)
      (io.print-error (str_cat.str-cat message "\n"))
      1]
    [(Ok source-set) (fmt-package-files check source-set.sources 0)]))

;; Run the `fmt` command over arguments starting at `start` (the index of the
;; first argument after any subcommand name); `count` is `(arg-count)`.
(define (fmt-run-from [start : i64] [count : i64]) : i64
  (match (fmt-config-from start count)
    [(Ok config)
      (match config
        [(File check paths) (fmt-files check paths 0)]
        [(Package check manifest-path has-manifest)
          (fmt-package check manifest-path has-manifest)])]
    [(Err message)
      (io.print-error (str_cat.str-cat message "\n"))
      1]))
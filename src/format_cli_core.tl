;; format_cli_core.tl - Self-hosted `fmt` command logic (#522).
;;
;; The formatter CLI logic, factored out of `format.tl` so both the retained
;; formatter compatibility/coverage driver and the unified `cli.tl` dispatcher
;; can run the `fmt` command without duplicating a `main`.
(import stdlib.io)
(import stdlib.vector)
(import "format_rules.tl")
(import "package_source_core.tl")
(import stdlib.string)

(defenum FmtConfig
  (File bool vector.StringVec)
  (Package bool String bool))

(defenum ResultFmtConfig
  (Ok FmtConfig)
  (Err String))

(defenum ResultFmtWrite
  (Ok)
  (Err String))

(define (fmt-write-error-message [path : String] [error : io.IoError]) : String
  (string.append
    "fmt: failed to write "
    (string.append path (string.append ": " (io.error-message error)))))

(define (fmt-try-write-formatted-file [path : String] [formatted : String]) : ResultFmtWrite
  (match (io.try-write-file (& path) (& formatted))
    [(io.OkIoUnit) ResultFmtWrite.Ok]
    [(io.ErrIoUnit error)
      (ResultFmtWrite.Err (fmt-write-error-message path error))]))

(define (fmt-write-formatted-file [path : String] [formatted : String]) : i64
  (match (fmt-try-write-formatted-file path formatted)
    [(ResultFmtWrite.Ok) 0]
    [(ResultFmtWrite.Err message)
      (begin
        (io.print-error (string.append message "\n"))
        1)]))

(define (fmt-source-error-message [path : String] [err : FormatSourceError]) : String
  (let
    [span : FormatSourceSpan (format-source-error-span err)]
    (string.append
      path
      (string.append
        ":"
        (string.append
          (string.int->string (format-source-span-start-line span))
          (string.append
            ":"
            (string.append
              (string.int->string (format-source-span-start-col span))
              (string.append ": " (format-source-error-message err)))))))))

(test
  fmt-write-failure-diagnostic-includes-path-and-reason
  (match (fmt-try-write-formatted-file "" "(define x 1)\n")
    [(ResultFmtWrite.Ok) (io.panic "fmt write unexpectedly succeeded")]
    [(ResultFmtWrite.Err message)
      (if (string.eq message "fmt: failed to write : io: invalid path: ")
        unit
        (io.panic (string.copy message)))]))

(test
  fmt-parse-diagnostic-includes-path-line-and-column
  (match (format-rules-render-source-width-result "(define x\n  ]" 80)
    [(ResultFormatString.Ok _) (io.panic "fmt parse unexpectedly succeeded")]
    [(ResultFormatString.Err err)
      (let
        [message : String (fmt-source-error-message "bad.tl" err)]
        (if (string.eq
          message
          "bad.tl:2:3: format cst: unexpected closing delimiter")
          unit
          (io.panic message)))]))

(define (fmt-malformed-int-error? [source : String]) : bool
  (match (format-rules-render-source-width-result source 80)
    [(ResultFormatString.Ok _) false]
    [(ResultFormatString.Err err)
      (string.eq
        (format-source-error-message err)
        "format lexer: malformed integer literal")]))

(test
  fmt-number-literal-diagnostics-preserved
  (if (and
    (fmt-malformed-int-error? "(define x 0x)")
    (fmt-malformed-int-error? "(define x 0xg)")
    (fmt-malformed-int-error? "(define x 0b)")
    (fmt-malformed-int-error? "(define x 0b2)"))
    unit
    (io.panic "fmt number literal diagnostics changed")))

(define (fmt-flag? [value : String]) : bool
  (and (> (string.string-length value) 0) (= (string.string-ref value 0) '-')))

(define (fmt-config-finish
  [check : bool]
  [paths : vector.StringVec]
  [manifest-path : String]
  [has-manifest : bool]) : ResultFmtConfig
  (if (vector.string-vec-is-empty? paths)
    (ResultFmtConfig.Ok (FmtConfig.Package check manifest-path has-manifest))
    (if has-manifest
      (ResultFmtConfig.Err
        "fmt: cannot combine input paths with --manifest-path")
      (ResultFmtConfig.Ok (FmtConfig.File check paths)))))

(define (fmt-parse-args
  [idx : i64]
  [count : i64]
  [check : bool]
  [paths : vector.StringVec]
  [manifest-path : String]
  [has-manifest : bool]) : ResultFmtConfig
  (if (>= idx count)
    (fmt-config-finish check paths manifest-path has-manifest)
    (let
      [current : String (io.arg idx)]
      (cond
        [(string.eq current "--check")
          (fmt-parse-args (+ idx 1) count true paths manifest-path has-manifest)]
        [(string.eq current "--manifest-path")
          (if (>= (+ idx 1) count)
            (ResultFmtConfig.Err "fmt: --manifest-path requires a value")
            (if has-manifest
              (ResultFmtConfig.Err "fmt: duplicate --manifest-path")
              (fmt-parse-args
                (+ idx 2)
                count
                check
                paths
                (io.arg (+ idx 1))
                true)))]
        [(string.eq current "--stdlib-root")
          (if (>= (+ idx 1) count)
            (ResultFmtConfig.Err "fmt: --stdlib-root requires a value")
            (fmt-parse-args
              (+ idx 2)
              count
              check
              paths
              manifest-path
              has-manifest))]
        [(fmt-flag? current)
          (ResultFmtConfig.Err (string.append "fmt: unknown flag " current))]
        [else
          (fmt-parse-args
            (+ idx 1)
            count
            check
            (vector.string-vec-push paths current)
            manifest-path
            has-manifest)]))))

(define (fmt-config-from [start : i64] [count : i64]) : ResultFmtConfig
  (fmt-parse-args start count false (vector.string-vec-new) "" false))

(define (fmt-format-file [check : bool] [path : String]) : i64
  (let
    [source : String (io.read-file path)]
    (match (format-rules-render-source-width-result source 80)
      [(ResultFormatString.Ok formatted)
        (if check
          (if (string.eq source formatted)
            0
            (begin
              (io.print-error
                (string.append "fmt: would reformat " (string.append path "\n")))
              1))
          (if (string.eq source formatted)
            0
            (fmt-write-formatted-file path formatted)))]
      [(ResultFormatString.Err err)
        (begin
          (io.print-error
            (string.append (fmt-source-error-message path err) "\n"))
          1)])))

(define (fmt-files-from
  [check : bool]
  [paths : vector.StringVec]
  [index : i64]
  [status : i64]) : i64
  (if (>= index (vector.string-vec-len paths))
    status
    (let
      [path : String (vector.string-vec-get paths index "")]
      [file-status : i64 (fmt-format-file check path)]
      (fmt-files-from
        check
        paths
        (+ index 1)
        (if (= status 0)
          file-status
          status)))))

(define (fmt-files [check : bool] [paths : vector.StringVec] [status : i64]) : i64
  (fmt-files-from check paths 0 status))

(define (fmt-package-files-from
  [check : bool]
  [paths : PackageSourceList]
  [index : i64]
  [status : i64]) : i64
  (if (>= index (package-source-list-len paths))
    status
    (let
      [path : String (package-source-list-get paths index "")]
      [file-status : i64 (fmt-format-file check path)]
      (fmt-package-files-from
        check
        paths
        (+ index 1)
        (if (= status 0)
          file-status
          status)))))

(define (fmt-package-files
  [check : bool]
  [paths : PackageSourceList]
  [status : i64]) : i64
  (fmt-package-files-from check paths 0 status))

(define (fmt-package
  [check : bool]
  [manifest-path : String]
  [has-manifest : bool]) : i64
  (match (package-source-discover-for "fmt" manifest-path has-manifest)
    [(ResultPackageSourceSet.Err message)
      (begin
        (io.print-error (string.append message "\n"))
        1)]
    [(ResultPackageSourceSet.Ok source-set)
      (fmt-package-files check (struct-get source-set sources) 0)]))

;; Run the `fmt` command over arguments starting at `start` (the index of the
;; first argument after any subcommand name); `count` is `(arg-count)`.
(define (fmt-run-from [start : i64] [count : i64]) : i64
  (match (fmt-config-from start count)
    [(ResultFmtConfig.Ok config)
      (match config
        [(FmtConfig.File check paths) (fmt-files check paths 0)]
        [(FmtConfig.Package check manifest-path has-manifest)
          (fmt-package check manifest-path has-manifest)])]
    [(ResultFmtConfig.Err message)
      (begin
        (io.print-error (string.append message "\n"))
        1)]))
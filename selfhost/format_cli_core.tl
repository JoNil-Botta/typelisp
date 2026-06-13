;; format_cli_core.tl - Self-hosted `fmt` command logic (#522).
;;
;; The formatter CLI logic, factored out of `format.tl` so both the retained
;; formatter compatibility/coverage driver and the unified `cli.tl` dispatcher
;; can run the `fmt` command without duplicating a `main`.
(import "../stdlib/io.tl")

(import "../stdlib/list.tl")

(import "format_rules.tl")

(import "package_source_core.tl")

(import "../stdlib/string.tl")

(defenum FmtConfig
  (FmtFileConfig bool StringList)
  (FmtPackageConfig bool String bool))

(defenum ResultFmtConfig
  (OkFmtConfig FmtConfig)
  (ErrFmtConfig String))

(defenum ResultFmtWrite
  (OkFmtWrite)
  (ErrFmtWrite String))

(define (fmt-write-error-message [path : String] [error : IoError]) : String
  (string-append
    "fmt: failed to write "
    (string-append path (string-append ": " (io-error-message error)))))

(define (fmt-try-write-formatted-file [path : String] [formatted : String]) : ResultFmtWrite
  (match (try-write-file (& path) (& formatted))
    [(OkIoUnit) OkFmtWrite]
    [(ErrIoUnit error) (ErrFmtWrite (fmt-write-error-message path error))]))

(define (fmt-write-formatted-file [path : String] [formatted : String]) : i64
  (match (fmt-try-write-formatted-file path formatted)
    [(OkFmtWrite) 0]
    [(ErrFmtWrite message)
      (begin
        (print-error (string-append message "\n"))
        1)]))

(define (fmt-source-error-message [path : String] [err : FormatSourceError]) : String
  (let
    [span : FormatSourceSpan (format-source-error-span err)]
    (string-append
      path
      (string-append
        ":"
        (string-append
          (int->string (format-source-span-start-line span))
          (string-append
            ":"
            (string-append
              (int->string (format-source-span-start-col span))
              (string-append ": " (format-source-error-message err)))))))))

(test
  fmt-write-failure-diagnostic-includes-path-and-reason
  (match (fmt-try-write-formatted-file "" "(define x 1)\n")
    [(OkFmtWrite) (panic "fmt write unexpectedly succeeded")]
    [(ErrFmtWrite message)
      (if (string-eq message "fmt: failed to write : io: invalid path: ")
        unit
        (panic message))]))

(test
  fmt-parse-diagnostic-includes-path-line-and-column
  (match (format-rules-render-source-width-result "(define x\n  ]" 80)
    [(OkFormatString _) (panic "fmt parse unexpectedly succeeded")]
    [(ErrFormatString err)
      (let
        [message : String (fmt-source-error-message "bad.tl" err)]
        (if (string-eq
          message
          "bad.tl:2:3: format cst: unexpected closing delimiter")
          unit
          (panic message)))]))

(define (fmt-flag? [value : String]) : bool
  (and (> (string-length value) 0) (= (string-ref value 0) #-')))

(define (fmt-path-list-empty? [paths : StringList]) : bool
  (match paths
    [(StringNil) true]
    [(StringCons _ _) false]))

(define (fmt-path-list-append [paths : StringList] [path : String]) : StringList
  (match paths
    [(StringNil) (StringCons path (box StringNil))]
    [(StringCons head rest)
      (StringCons head (box (fmt-path-list-append (box-get rest) path)))]))

(define (fmt-config-finish
  [check : bool]
  [paths : StringList]
  [manifest-path : String]
  [has-manifest : bool]) : ResultFmtConfig
  (if (fmt-path-list-empty? paths)
    (OkFmtConfig (FmtPackageConfig check manifest-path has-manifest))
    (if has-manifest
      (ErrFmtConfig "fmt: cannot combine input paths with --manifest-path")
      (OkFmtConfig (FmtFileConfig check paths)))))

(define (fmt-parse-args
  [idx : i64]
  [count : i64]
  [check : bool]
  [paths : StringList]
  [manifest-path : String]
  [has-manifest : bool]) : ResultFmtConfig
  (if (>= idx count)
    (fmt-config-finish check paths manifest-path has-manifest)
    (let
      [current : String (arg idx)]
      (cond
        (string-eq current "--check")
        (fmt-parse-args (+ idx 1) count true paths manifest-path has-manifest)
        (string-eq current "--manifest-path")
        (if (>= (+ idx 1) count)
          (ErrFmtConfig "fmt: --manifest-path requires a value")
          (if has-manifest
            (ErrFmtConfig "fmt: duplicate --manifest-path")
            (fmt-parse-args (+ idx 2) count check paths (arg (+ idx 1)) true)))
        (string-eq current "--stdlib-root")
        (if (>= (+ idx 1) count)
          (ErrFmtConfig "fmt: --stdlib-root requires a value")
          (fmt-parse-args
            (+ idx 2)
            count
            check
            paths
            manifest-path
            has-manifest))
        (fmt-flag? current)
        (ErrFmtConfig (string-append "fmt: unknown flag " current))
        (fmt-parse-args
          (+ idx 1)
          count
          check
          (fmt-path-list-append paths current)
          manifest-path
          has-manifest)))))

(define (fmt-config-from [start : i64] [count : i64]) : ResultFmtConfig
  (fmt-parse-args start count false StringNil "" false))

(define (fmt-format-file [check : bool] [path : String]) : i64
  (let
    [source : String (read-file path)]
    (match (format-rules-render-source-width-result source 80)
      [(OkFormatString formatted)
        (if check
          (if (string-eq source formatted)
            0
            (begin
              (print-error
                (string-append "fmt: would reformat " (string-append path "\n")))
              1))
          (if (string-eq source formatted)
            0
            (fmt-write-formatted-file path formatted)))]
      [(ErrFormatString err)
        (begin
          (print-error (string-append (fmt-source-error-message path err) "\n"))
          1)])))

(define (fmt-files [check : bool] [paths : StringList] [status : i64]) : i64
  (match paths
    [(StringNil) status]
    [(StringCons path rest)
      (let
        [file-status : i64 (fmt-format-file check path)]
        (fmt-files
          check
          (box-get rest)
          (if (= status 0)
            file-status
            status)))]))

(define (fmt-package
  [check : bool]
  [manifest-path : String]
  [has-manifest : bool]) : i64
  (match (package-source-discover-for "fmt" manifest-path has-manifest)
    [(ErrPackageSourceSet message)
      (begin
        (print-error (string-append message "\n"))
        1)]
    [(OkPackageSourceSet source-set)
      (fmt-files check (struct-get source-set sources) 0)]))

;; Run the `fmt` command over arguments starting at `start` (the index of the
;; first argument after any subcommand name); `count` is `(arg-count)`.
(define (fmt-run-from [start : i64] [count : i64]) : i64
  (match (fmt-config-from start count)
    [(OkFmtConfig config)
      (match config
        [(FmtFileConfig check paths) (fmt-files check paths 0)]
        [(FmtPackageConfig check manifest-path has-manifest)
          (fmt-package check manifest-path has-manifest)])]
    [(ErrFmtConfig message)
      (begin
        (print-error (string-append message "\n"))
        1)]))
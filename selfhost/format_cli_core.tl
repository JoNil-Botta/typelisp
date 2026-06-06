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
        [(string-eq current "--check")
          (fmt-parse-args (+ idx 1) count true paths manifest-path has-manifest)]
        [(string-eq current "--manifest-path")
          (if (>= (+ idx 1) count)
            (ErrFmtConfig "fmt: --manifest-path requires a value")
            (if has-manifest
              (ErrFmtConfig "fmt: duplicate --manifest-path")
              (fmt-parse-args (+ idx 2) count check paths (arg (+ idx 1)) true)))]
        [(string-eq current "--stdlib-root")
          (if (>= (+ idx 1) count)
            (ErrFmtConfig "fmt: --stdlib-root requires a value")
            (fmt-parse-args
              (+ idx 2)
              count
              check
              paths
              manifest-path
              has-manifest))]
        [(fmt-flag? current)
          (ErrFmtConfig (string-append "fmt: unknown flag " current))]
        [else
          (fmt-parse-args
            (+ idx 1)
            count
            check
            (fmt-path-list-append paths current)
            manifest-path
            has-manifest)]))))

(define (fmt-config-from [start : i64] [count : i64]) : ResultFmtConfig
  (fmt-parse-args start count false StringNil "" false))

(define (fmt-format-file [check : bool] [path : String]) : i64
  (let
    [source : String (read-file path)]
    [formatted : String (format-rules-render-source-width source 80)]
    (if check
      (if (string-eq source formatted)
        0
        (begin
          (print-error
            (string-append "fmt: would reformat " (string-append path "\n")))
          1))
      (if (string-eq source formatted)
        0
        (begin
          (write-file path formatted)
          0)))))

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
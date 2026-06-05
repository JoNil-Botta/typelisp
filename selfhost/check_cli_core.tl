;; check_cli_core.tl - Self-hosted `check` (typecheck) command logic.
;;
;; Factored out of `check.tl` so the unified `cli.tl` dispatcher and the
;; standalone `check.tl` driver share the command without a duplicate `main`.
(import "../stdlib/io.tl")

(import "compiler_check_core.tl")

(defenum SelfhostCheckConfig
  (SelfhostCheckConfig String CompilerLoadRootList))

(defenum ResultSelfhostCheckConfig
  (OkSelfhostCheckConfig SelfhostCheckConfig)
  (ErrSelfhostCheckConfig String))

(define (selfhost-check-flag? [value : String]) : bool
  (and (> (string-length value) 0) (= (string-ref value 0) #-')))

(define (selfhost-check-root-list-append
  [roots : CompilerLoadRootList]
  [root : String]) : CompilerLoadRootList
  (match roots
    [(CompilerLoadRootNil)
      (CompilerLoadRootCons root (box CompilerLoadRootNil))]
    [(CompilerLoadRootCons head rest)
      (CompilerLoadRootCons
        head
        (box (selfhost-check-root-list-append (box-get rest) root)))]))

(define (selfhost-check-parse-options
  [idx : i64]
  [count : i64]
  [input-path : String]
  [stdlib-roots : CompilerLoadRootList]) : ResultSelfhostCheckConfig
  (if (>= idx count)
    (OkSelfhostCheckConfig (SelfhostCheckConfig input-path stdlib-roots))
    (let
      [current : String (arg idx)]
      (if (string-eq current "--stdlib-root")
        (if (>= (+ idx 1) count)
          (ErrSelfhostCheckConfig
            "selfhost-check: --stdlib-root requires a value")
          (selfhost-check-parse-options
            (+ idx 2)
            count
            input-path
            (selfhost-check-root-list-append stdlib-roots (arg (+ idx 1)))))
        (if (selfhost-check-flag? current)
          (ErrSelfhostCheckConfig
            (string-append "selfhost-check: unknown flag " current))
          (ErrSelfhostCheckConfig
            (string-append "selfhost-check: unexpected argument " current)))))))

;; Parse the `check` config from arguments starting at `start` (the index of
;; the input path); options follow at `start+1`. `count` is `(arg-count)`.
(define (selfhost-check-config-from [start : i64] [count : i64]) : ResultSelfhostCheckConfig
  (if (< count (+ start 1))
    (ErrSelfhostCheckConfig "selfhost-check: expected input path")
    (let
      [input-path : String (arg start)]
      (if (selfhost-check-flag? input-path)
        (ErrSelfhostCheckConfig
          "selfhost-check: expected input path before flags")
        (selfhost-check-parse-options
          (+ start 1)
          count
          input-path
          CompilerLoadRootNil)))))

(define (selfhost-check-file
  [input-path : String]
  [stdlib-roots : CompilerLoadRootList]) : i64
  (match (compiler-check-file-with-roots input-path stdlib-roots)
    [(OkCompilerCheck _)
      (begin
        (print-string "Type checking passed!\n")
        0)]
    [(ErrCompilerCheck diag)
      (begin
        (print-error (compiler-diagnostic-render diag))
        1)]))

;; Run the `check` command over arguments starting at `start`.
(define (selfhost-check-run-from [start : i64] [count : i64]) : i64
  (match (selfhost-check-config-from start count)
    [(OkSelfhostCheckConfig config)
      (match config
        [(SelfhostCheckConfig input-path stdlib-roots)
          (selfhost-check-file input-path stdlib-roots)])]
    [(ErrSelfhostCheckConfig message)
      (begin
        (print-error message)
        1)]))
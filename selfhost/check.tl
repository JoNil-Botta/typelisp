;; check.tl - Short-lived selfhost typecheck CLI driver.
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
    [(CompilerLoadRootNil) (CompilerLoadRootCons root CompilerLoadRootNil)]
    [(CompilerLoadRootCons head rest)
      (CompilerLoadRootCons head (selfhost-check-root-list-append rest root))]))

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

(define (selfhost-check-config [count : i64]) : ResultSelfhostCheckConfig
  (if (< count 2)
    (ErrSelfhostCheckConfig "selfhost-check: expected input path")
    (let
      [input-path : String (arg 1)]
      (if (selfhost-check-flag? input-path)
        (ErrSelfhostCheckConfig
          "selfhost-check: expected input path before flags")
        (selfhost-check-parse-options 2 count input-path CompilerLoadRootNil)))))

(define (selfhost-check-file
  [input-path : String]
  [stdlib-roots : CompilerLoadRootList]) : i64
  (match (compiler-check-file-with-roots input-path stdlib-roots)
    [(OkCompilerCheck _) 0]
    [(ErrCompilerCheck diag)
      (begin
        (print-error (compiler-diagnostic-render diag))
        1)]))

(define (main) : i64
  (match (selfhost-check-config (arg-count))
    [(OkSelfhostCheckConfig config)
      (match config
        [(SelfhostCheckConfig input-path stdlib-roots)
          (selfhost-check-file input-path stdlib-roots)])]
    [(ErrSelfhostCheckConfig message)
      (begin
        (print-error message)
        1)]))
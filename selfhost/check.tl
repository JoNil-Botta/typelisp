;; check.tl - Short-lived selfhost typecheck CLI driver.

(import "compiler_load.tl")

(import "compiler_diagnostic.tl")

(import "compiler_typecheck.tl")

(define (selfhost-check-extra-args-status [i : i64]) : i64
  (let ([n : i64 (arg-count)] [status : i64 0])
    (begin
      (while (and (= status 0) (< i n))
        (let ([a : String (arg i)])
          (if (string-eq a "--stdlib-root")
            (begin
              (print-error "selfhost-check: --stdlib-root is not supported yet")
              (set! status 1))
            (begin
              (print-error
                (string-append "selfhost-check: unexpected argument " a))
              (set! status 1)))))
      status)))

(define (selfhost-check-file [input-path : String]) : i64
  (match (compiler-load-file input-path (sym-i64-empty))
    [(OkCompilerLoad decls _)
      (match (typecheck-compiler-program (AstProgram decls))
        [(OkCompilerTypecheck _) 0]
        [(ErrCompilerTypecheck message)
          (begin
            (print-error message)
            1)])]
    [(ErrCompilerLoad diag)
      (begin
        (print-error (compiler-diagnostic-render diag))
        1)]))

(define (main) : i64
  (if (< (arg-count) 2)
    (begin
      (print-error "selfhost-check: expected input path")
      1)
    (let ([extra-status : i64 (selfhost-check-extra-args-status 2)])
      (if (= extra-status 0)
        (selfhost-check-file (arg 1))
        extra-status))))
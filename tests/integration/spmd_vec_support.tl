(module spmd_vec_support)

;; Test-only constructors for caller-owned generated vectors. The SPMD
;; integration fixtures need initialized live elements before borrowing the
;; backing storage; `with-capacity` alone deliberately leaves the vector empty.
;; Generate only the element family each fixture imports so a small trap
;; program does not typecheck every numeric vector module.
(import stdlib.comptime)
(import stdlib.vector)

(defmacro (zeroed [T : type] [zero : Expr]) : Module
  (let
    [module-name : comptime.Expr
      (comptime.expr-var
        (comptime.string-append "tests.spmd.zeroed." (type-key T)))]
    `(begin
      (module ,module-name)
      (import (vector.vector ,T) as vec)
      (define (make [n : i64]) : vec.Vec
        (let
          [out : vec.Vec (vec.with-capacity n)]
          [i : i64 0]
          (begin
            (while (< i n)
              (begin
                (vec.push (&mut out) ,zero)
                (set! i (+ i 1))))
            out))))))
(import stdlib.comptime)

;; A consuming module can also be the explicit target of the expansion it
;; calls. Its local declarations and the target's declarations then share one
;; owner, but each output segment is admitted once, in either import order.
(defmacro (emit-bare) : Decls
  `(begin
    (define bare-local : i64
      5)
    (module generated.decls_self_bare)
    (define bare-shared : i64
      7)))

(defmacro (emit-body) : Decls
  `(begin
    (define body-local : i64
      9)
    (module
      generated.decls_self_body
      (define body-shared : i64
        7))))

(defmacro (make-bare [name : comptime.Expr]) : Module
  `(begin
    (module ,name)
    (emit-bare)))

;; The repeated call replays every segment in the same consuming module.
(defmacro (make-body [name : comptime.Expr]) : Module
  `(begin
    (module ,name)
    (emit-body)
    (emit-body)))

(import (make-bare generated.decls_self_bare_other) as bare-other)
(import (make-bare generated.decls_self_bare) as bare)
(import (make-body generated.decls_self_body) as body)
(import (make-body generated.decls_self_body_other) as body-other)

(define (main) : i64
  (+
    bare-other.bare-local
    bare.bare-local
    bare.bare-shared
    body.body-local
    body.body-shared
    body-other.body-local))
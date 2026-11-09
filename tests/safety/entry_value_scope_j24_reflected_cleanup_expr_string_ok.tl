;; #9687: expr-string of an entry type cleanup name.
(import stdlib.comptime)
(import stdlib.string)

(define hits : i64
  0)

(define (close-tok [_v : i64]) : unit
  (set! hits (+ hits 1)))

(defstruct Own
  (:cleanup clean)
  (v i64 (:cleanup close-tok)))

(defmacro (m [X : type]) : Expr
  (comptime.expr-string (type-cleanup-function X)))

(define (main) : i64
  (+ 37 (string.string-length (m Own))))
;; A with-arena directly inside a same-named with-arena is rejected at entry:
;; the inner arena would share the outer arena's identity (#9593, D-C121;
;; previously the residual #9598).
(define (probe) : i64
  (with-arena
    outer
    ; Must fail: rename the inner arena.
    (with-arena outer 42)))

(define (main) : i64
  (probe))
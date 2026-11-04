;; A with-arena named like a visible lexical owner (any binding in scope owns
;; storage that `(& owner T)` can name) is rejected at entry: the arena would
;; share the owner's identity (#9593, D-C121).
(define (probe) : i64
  (let
    [owner : i64 42]
    ; Must fail: rename the arena.
    (with-arena owner owner)))

(define (main) : i64
  (probe))
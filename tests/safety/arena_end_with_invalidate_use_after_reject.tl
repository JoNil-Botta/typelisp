;; A with exit destroying an `(:invalidate r)` parameter ends brand `r`.
(import stdlib.arena)
(import stdlib.string)

(define (release [owner : (arena.Arena r) (:invalidate r)]) : i64
  (let
    [t (in-arena owner (string.append "a" "b"))]
    (begin
      (with ([a owner arena.destroy-safe!]) unit)
      (string.string-length t))))

(define (main) : i64
  (let
    [o (arena.make)]
    (release o)))
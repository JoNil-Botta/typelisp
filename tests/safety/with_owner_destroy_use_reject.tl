;; A `with` owner whose value lives in the destroyed arena: the body's later
;; read and the owner's scope-exit cleanup would both touch unmapped memory.
(import stdlib.arena)
(import stdlib.string)

(define (drop-n [n : i64]) : unit
  unit)

(defstruct Owner
  (:cleanup cleanup-owner)
  (n i64 (:cleanup drop-n))
  (text String))

(define (make-owner) : Owner
  (Owner 1 (string.concat "ab" "cd")))

(define (main) : i64
  (let
    [scratch : arena.Arena (arena.make)]
    (with
      ([owner (in-arena scratch (make-owner)) cleanup-owner])
      (begin
        (arena.destroy-safe! scratch)
        (cast (string.string-ref (& owner.text) 0) : i64)))))
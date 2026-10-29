(import stdlib.arena)
(import stdlib.string)

(define (drop-n [n : i64]) : unit
  unit)

(defstruct Owner
  (:cleanup cleanup-owner)
  (n i64 (:cleanup drop-n))
  (text String))

;; Must pass: a `with` owner allocated in the younger owner `o2`, which no
;; store places the phase's values in (#9445).
(define (main) : i64
  (let
    [o (arena.make)]
    [phase (arena.phase o)]
    [o2 (arena.make)]
    (in-arena
      o2
      (with
        ([w (Owner 1 (string.concat "o2" "-own")) cleanup-owner])
        (begin
          (arena.rewind-safe! phase)
          42)))))
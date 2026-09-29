;; Shadowing the owner's name does not end its scope: its cleanup still runs
;; when the `with` scope ends.
(import stdlib.arena)
(import stdlib.string)

(define (drop-n [n : i64]) : unit
  unit)

(defstruct Owner
  (:cleanup cleanup-owner)
  (n i64 (:cleanup drop-n))
  (text String))

(define (main) : i64
  (let
    [scratch : arena.Arena (arena.make)]
    (with
      ([owner
          (in-arena scratch (Owner 1 (string.concat "ab" "cd")))
          cleanup-owner])
      (let
        [owner : i64 42]
        (begin
          (arena.destroy-safe! scratch)
          owner)))))
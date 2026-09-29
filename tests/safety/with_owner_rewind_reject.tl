;; A phase that covers the owner's allocation cannot be rewound while the owner
;; is live: rewinding reuses that memory before the owner's cleanup runs.
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
    [phase : arena.ArenaPhase (arena.phase scratch)]
    (with
      ([owner
          (in-arena scratch (Owner 1 (string.concat "ab" "cd")))
          cleanup-owner])
      (begin
        (arena.rewind-safe! phase)
        42))))
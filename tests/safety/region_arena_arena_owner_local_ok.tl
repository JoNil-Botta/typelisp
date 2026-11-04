;; Migrated for D-C121: its arena was spelled like the caller lifetime `r`,
;; which is now rejected at entry, so it is renamed to `ar` together with the
;; uses that meant it (#9593). It pins that a local arena owner named `r` inside
;; an arena is an ordinary owner whose `(& r r)` borrows it; runs to 42.
(import stdlib.arena)

(define (probe [p : (& r i64)]) : i64
  (with-arena
    ar
    (let
      [f
        (lambda ([owner : (arena.Arena ar)]) : i64
          (let
            [r : (arena.Arena ar) owner]
            (begin
              (& r r)
              42)))]
      (f (arena.make)))))

(define (main) : i64
  (let
    [seed : i64 0]
    (probe (& seed))))
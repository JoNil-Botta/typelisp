;; #9846: a cross-module helper taking a branded `(arena.Arena r)` allocates in
;; the owner's active phase, so its result must end at `arena.rewind-safe!`.
(import stdlib.arena)
(import stdlib.string)
(import arena_phase_rewind_branded_module_helper_mod as m)

(define (main) : i64
  (let
    [owner (arena.make)]
    [p (arena.phase owner)]
    [text (m.fill owner)]
    (arena.rewind-safe! p)
    (if (string.eq (& text) "ab")
      42
      7)))
;; Helper module for arena_phase_rewind_branded_module_helper_reject (#9846).
(import stdlib.arena)
(import stdlib.string)

(define (fill [a : (arena.Arena r)]) : (in r String)
  (in-arena a (string.append "a" "b")))
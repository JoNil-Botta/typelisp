;; dce_late_flag_loop.tl - the call-free `found`/`done` flag loop.
;;
;; The exit join of this loop is what the level-2 pipeline's final slot exists
;; for: `cfg_straighten` collapses the join's uniform phis into Movs and
;; `thread_branch_late` decides its condition per edge, so anything the two
;; leave behind is a literal materialized into a register and then tested --
;; a branch on a constant, plus the dead literal Movs feeding it. The
;; assembly-shape gate reads `main` from this fixture on both targets.
;;
;; `i * i` first hits 49 at i = 7, so `found` is 7, `done` is true, and the
;; returned exit code is 42.
(define (main) : i64
  (let
    [n : i64 100]
    [i : i64 0]
    [found : i64 -1]
    [done : bool false]
    (begin
      (while (and (< i n) (not done))
        (if (= (* i i) 49)
          (begin
            (set! found i)
            (set! done true))
          (set! i (+ i 1))))
      (if done
        (+ found 35)
        42))))
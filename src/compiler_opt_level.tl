;; Optimization levels shared by CLI, optimizer, and backend dispatch.
(define (opt-level-size? [level : i64]) : bool
  (= level 3))

(define (opt-level-full? [level : i64]) : bool
  (>= level 2))

(define (opt-level-speed? [level : i64]) : bool
  (= level 2))
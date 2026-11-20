;; switch formation: the copy is taken before a direct set! of the source, and
;; the chain is wide enough to become a switch.
;; Expected exit 20 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [v : i64 2]
    [c : i64 v]
    (set! v 3)
    (cond
      [(= c 0) 5]
      [(= c 1) 10]
      [(= c 2) 20]
      [(= c 3) 30]
      [(= c 4) 50]
      [else 40])))
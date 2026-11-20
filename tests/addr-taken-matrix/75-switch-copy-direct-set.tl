;; a switch on a copy of v taken before a direct set! of v.
;; Expected exit 10 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [v : i64 1]
    [c : i64 v]
    (set! v 3)
    (cond [(= c 1) 10] [(= c 2) 20] [(= c 3) 30] [else 40])))
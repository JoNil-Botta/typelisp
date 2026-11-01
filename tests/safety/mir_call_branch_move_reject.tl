;; A move on one branch leaves the binder possibly moved after the join.
(define (consume [_text : String]) : i64
  1)

(define (maybe [text : String] [flag : bool]) : i64
  (let
    [first : i64
      (if flag
        (consume text)
        0)]
    (+ first (consume text))))

(define (main) : i64
  0)
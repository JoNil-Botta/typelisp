;: A closure's result may be a reference it captured: it holds that loan, so
;: writing `p.l` while the result is used later conflicts (Rust E0506, #8449).
(defstruct Pair
  (l i64)
  (r i64))

(define (main) : i64
  (let
    [p : Pair (Pair 1 2)]
    [r : (& p i64) (& p.l)]
    [pick
      (lambda ([n : i64]) : (& p i64)
        r)]
    [v : (& p i64) (pick 0)]
    (set! p.l 9)
    (deref v)))
;; The join's phi must not overwrite value before the final pointer read.
;; Opt2's separate cross-block load-forwarding defect is owned by #8514.
(define (join-shape [flag : bool]) : i64
  (let
    [value : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of value))]
    [x : i64
      (if flag
        (let
          [loaded : i64
            (unsafe
              (ptr-read p))]
          (set! value 3)
          loaded)
        (let
          [loaded : i64
            (unsafe
              (ptr-read p))]
          (set! value 3)
          loaded))]
    (+
      x
      (unsafe
        (ptr-read p)))))

(define (main) : i64
  (if (and (= (join-shape false) 4) (= (join-shape true) 4))
    42
    1))
;; The opt1 frame-slot collision is tracked by #7975 in #8190.
(define (join-shape [flag : bool]) : i64
  (let
    [value : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of value))]
    [x : i64
      (if flag
        (let
          [t : i64
            (unsafe
              (ptr-read p))]
          (begin
            (set! value 3)
            t))
        (let
          [t : i64
            (unsafe
              (ptr-read p))]
          (begin
            (set! value 3)
            t)))]
    (+
      x
      (unsafe
        (ptr-read p)))))

(define (main) : i64
  (if (= (join-shape false) 4)
    42
    1))
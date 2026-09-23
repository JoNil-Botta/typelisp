;; Dynamic signed division keeps the operands intact while checking overflow.
(import stdlib.io)
(import stdlib.string)

(define (divide [width : i64] [a : i64] [b : i64]) : i64
  (cond
    [(= width 8) (cast (/ (cast a : i8) (cast b : i8)) : i64)]
    [(= width 16) (cast (/ (cast a : i16) (cast b : i16)) : i64)]
    [(= width 32) (cast (/ (cast a : i32) (cast b : i32)) : i64)]
    [else (/ a b)]))

(define (remainder [width : i64] [a : i64] [b : i64]) : i64
  (cond
    [(= width 8) (cast (% (cast a : i8) (cast b : i8)) : i64)]
    [(= width 16) (cast (% (cast a : i16) (cast b : i16)) : i64)]
    [(= width 32) (cast (% (cast a : i32) (cast b : i32)) : i64)]
    [else (% a b)]))

(define (valid-i8-pairs?) : bool
  (let
    [a : i64 -128]
    [ok : bool true]
    (begin
      (while (<= a 127)
        (begin
          (let
            [b : i64 -128]
            (while (<= b 127)
              (begin
                (when
                  (and (!= b 0) (not (and (= a -128) (= b -1))))
                  (let
                    [q : i64 (divide 8 a b)]
                    [r : i64 (remainder 8 a b)]
                    [abs-b : i64
                      (if (< b 0)
                        (neg b)
                        b)]
                    [abs-r : i64
                      (if (< r 0)
                        (neg r)
                        r)]
                    (set!
                      ok
                      (and
                        ok
                        (= (+ (* q b) r) a)
                        (< abs-r abs-b)
                        (or (= r 0) (= (< r 0) (< a 0)))))))
                (set! b (+ b 1)))))
          (set! a (+ a 1))))
      ok)))

(define (boundary-pairs? [width : i64] [minimum : i64]) : bool
  (and
    (= (divide width minimum 1) minimum)
    (= (remainder width minimum 1) 0)
    (= (divide width minimum 2) (shr minimum 1))
    (= (remainder width minimum 2) 0)
    (= (divide width minimum -2) (neg (shr minimum 1)))
    (= (remainder width minimum -2) 0)
    (= (divide width (+ minimum 1) -1) (neg (+ minimum 1)))
    (= (remainder width (+ minimum 1) -1) 0)
    (= (divide width (neg (+ minimum 1)) -1) (+ minimum 1))
    (= (remainder width (neg (+ minimum 1)) -1) 0)
    (= (divide width -7 3) -2)
    (= (remainder width -7 3) -1)
    (= (divide width 7 -3) -2)
    (= (remainder width 7 -3) 1)
    (= (divide width 0 -1) 0)
    (= (remainder width 0 -1) 0)))

(define (main) : i64
  (if (= (io.arg-count) 1)
    (if (and
      (valid-i8-pairs?)
      (boundary-pairs? 8 -128)
      (boundary-pairs? 16 -32768)
      (boundary-pairs? 32 -2147483648)
      (boundary-pairs? 64 (- (- 0 9223372036854775807) 1)))
      42
      1)
    (let
      [width : i64 (string.>int (io.arg 1))]
      [a : i64 (string.>int (io.arg 2))]
      [b : i64 (string.>int (io.arg 3))]
      [want-remainder : bool (= (string.>int (io.arg 4)) 1)]
      (if want-remainder
        (remainder width a b)
        (divide width a b)))))
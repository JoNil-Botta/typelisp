(import stdlib.io)
(import stdlib.byte_buf)

;; Distinct coefficients catch swapped words, including the scalar argument
;; between the two pairs. Recursion keeps an emitted function boundary.
(define (score [left : (& (Slice i64))] [scale : i64] [right : (& (Slice i64))]) : i64
  (if (< scale 0)
    (let
      [fallback : (Array i64 1) (array scale)]
      (+ 1 (score (& fallback) (+ scale 1) (& fallback))))
    (+
      (* 1000 (array-ref left 0))
      (+
        (* 100 (length left))
        (+ (* 10 (array-ref right 0)) (+ (length right) scale))))))

(define (reverse-score
  [left : (& (Slice i64))]
  [scale : i64]
  [right : (& (Slice i64))]) : i64
  (score right scale left))

(define (length-score [text : String] [extra : i64]) : i64
  (+ (string-length text) (* 3 extra)))

(define (other-score [text : String] [extra : i64]) : i64
  (+ (string-length text) (* 5 extra)))

;; Five GP words precede the final pair. SysV rolls it back to the stack
;; and uses its last GP register for d. Windows splits the pair across
;; its last internal argument register and the stack.
(define (crowded
  [text : String]
  [a : i64]
  [b : i64]
  [c : i64]
  [view : (& bytes)]
  [d : i64]
  [callback : (-> String i64 i64)]) : i64
  (let
    [size (string-length text)]
    (if (< d 0)
      (+ 1 (crowded "" a b c view (+ d 1) callback))
      (let
        [n (callback "" 1)]
        (+
          (* 1000 size)
          (+
            (* 100 a)
            (+
              (* 10 b)
              (+
                c
                (+
                  (cast (byte_buf.bytes-ref view 0) : i64)
                  (+ (* 10 (byte_buf.bytes-length view)) (+ (* 2 d) n)))))))))))

(define (main) : i64
  (let
    [n : i64 (io.arg-count)]
    [a : (Array i64 2) (array (+ n 2) 8)]
    [b : (Array i64 3) (array (+ n 4) 13 21)]
    [choose : (-> String i64 i64)
      (if (> n 1)
        other-score
        length-score)]
    [measured (choose "hello" 7)]
    [text : String "pear"]
    [bytes : String "ABC"]
    [first (score (& a) 7 (& b))]
    [second (reverse-score (& b) 11 (& a))]
    [last (crowded text 2 3 4 (byte_buf.str-as-bytes (& bytes)) 5 choose)]
    (if (and (= measured 26) (= first 3260) (= second 3264) (= last 4342))
      42
      1)))
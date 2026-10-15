(import stdlib.io)
(import stdlib.string)

(define g : i64
  10)
(define saved-ptr : (MutPtr i64)
  (ptr-null : (MutPtr i64)))

;; Recursion keeps the pointer write behind a call at every optimization level.
(define (set-via [p : (&mut p i64)] [v : i64] [depth : i64]) : i64
  (if (> depth 0)
    (set-via p v (- depth 1))
    (begin
      (set! (deref p) v)
      0)))

(define (set-raw [v : i64] [depth : i64]) : i64
  (if (> depth 0)
    (set-raw v (- depth 1))
    (begin
      (unsafe
        (ptr-write! saved-ptr v))
      0)))

(define (loop-read [d : i64]) : i64
  (if (< d 0)
    (loop-read (+ d 1))
    (let
      [acc : i64 0]
      [i : i64 0]
      (while (< i 3)
        (set! acc (+ acc g))
        (set! acc (+ acc (set-via (&mut g) (+ i 100) d)))
        (+= i 1))
      acc)))

(define (alias-read [d : i64]) : i64
  (if (< d 0)
    (alias-read (+ d 1))
    (let
      [saved : i64 g]
      [_r : i64 (set-via (&mut g) 777 d)]
      (+ saved 1))))

(define (raw-read [d : i64]) : i64
  (if (< d 0)
    (raw-read (+ d 1))
    (let
      [saved : i64 g]
      [_r : i64 (set-raw 555 d)]
      (+ saved 1))))

(define (twice-read [d : i64]) : i64
  (if (< d 0)
    (twice-read (+ d 1))
    (let
      [saved : i64 g]
      [r : i64 (set-via (&mut g) 5 d)]
      (+ (+ saved g) r))))

(define (case-ok? [mode : i64] [depth : i64]) : bool
  (set! g 10)
  (set!
    saved-ptr
    (unsafe
      (ptr-addr-of g)))
  (cond
    [(= mode 0)
      (let
        [result : i64 (loop-read depth)]
        (and (= result 211) (= g 102)))]
    [(= mode 1)
      (let
        [result : i64 (alias-read depth)]
        (and (= result 11) (= g 777)))]
    [(= mode 2)
      (let
        [result : i64 (raw-read depth)]
        (and (= result 11) (= g 555)))]
    [(= mode 3)
      (let
        [result : i64 (twice-read depth)]
        (and (= result 15) (= g 5)))]
    [else false]))

(define (main) : i64
  (let
    [mode : i64 (string.>int (io.arg 1))]
    [depth : i64 (string.>int (io.arg 2))]
    [direct : bool (case-ok? mode depth)]
    [recursive : bool (case-ok? mode (+ depth 3))]
    (if (and direct recursive)
      42
      (+ mode 1))))
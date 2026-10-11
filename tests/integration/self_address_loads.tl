(import stdlib.string)

(define (walk
  [text : String]
  [items : (__tl_dyn-array i64)]
  [remaining : i64]
  [total : i64]) : i64
  (if (= remaining 0)
    (+ total (string.string-length text))
    (walk
      (unsafe
        (ptr-read (ptr-addr-of text)))
      (unsafe
        (ptr-read (ptr-addr-of items)))
      (- remaining 1)
      (+ total (array-ref items (% remaining 3))))))

(define (reassigned [seed : i64]) : i64
  (let
    [value : i64 seed]
    [address : (MutPtr i64)
      (unsafe
        (ptr-addr-of value))]
    (set! value (+ value 25))
    (unsafe
      (ptr-read address))))

(define (sibling-write [seed : i64]) : i64
  (let
    [value : i64 seed]
    [reader : (MutPtr i64)
      (unsafe
        (ptr-addr-of value))]
    [writer : (MutPtr i64)
      (unsafe
        (ptr-addr-of value))]
    (unsafe
      (ptr-write! writer (+ seed 25)))
    (unsafe
      (ptr-read reader))))

(define (local-loop [limit : i64]) : i64
  (let
    [value : i64 0]
    [total : i64 0]
    (while (< value limit)
      (set!
        value
        (+
          (unsafe
            (ptr-read (ptr-addr-of value)))
          1))
      (+=
        total
        (unsafe
          (ptr-read (ptr-addr-of value)))))
    total))

(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 3)]
    (set! (array-ref items 0) 1)
    (set! (array-ref items 1) 2)
    (set! (array-ref items 2) 3)
    (if (and
      (=
        (walk
          "hé"
          (unsafe
            (ptr-read (ptr-addr-of items)))
          0
          0)
        3)
      (=
        (walk
          "hé"
          (unsafe
            (ptr-read (ptr-addr-of items)))
          5
          0)
        14)
      (= (walk "hé" items 100 0) 203)
      (= (reassigned 17) 42)
      (= (sibling-write 17) 42)
      (= (local-loop 0) 0)
      (= (local-loop 8) 36))
      42
      1)))
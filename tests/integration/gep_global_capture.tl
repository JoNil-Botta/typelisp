;; A selected raw address keeps the global base and index values from capture.
(import stdlib.test)

(define old : i64
  7)
(define fresh : i64
  11)
(define chosen : (MutPtr i64)
  (unsafe
    (ptr-addr-of old)))
(define index : i64
  1)

(define (capture-base [replacement : (MutPtr i64)]) : i64
  (unsafe
    (let
      [selected : (MutPtr i64) (ptr-offset chosen 0)]
      (set! chosen replacement)
      (+ (ptr-read selected) (ptr-read selected)))))

(define (capture-index) : i64
  (let
    [items : (Array i64 3) (array 5 13 17)]
    (unsafe
      (let
        [selected : (MutPtr i64)
          (ptr-offset (ptr-addr-of (array-ref items 0)) index)]
        (set! index 2)
        (+ (ptr-read selected) (ptr-read selected))))))

(define (main) : i64
  (test.assert-i64-eq
    (capture-base
      (unsafe
        (ptr-addr-of fresh)))
    14
    "captured global pointer keeps the old pointee")
  (test.assert-i64-eq
    (unsafe
      (ptr-read chosen))
    11
    "the global binding names the new pointee")
  (test.assert-i64-eq
    (capture-index)
    26
    "captured global offset keeps its value")
  (test.assert-i64-eq index 2 "the global offset is rebound")
  42)
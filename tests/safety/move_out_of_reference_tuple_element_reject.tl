;; A tuple element projected from a dereferenced reference is read through
;; the reference (#8554).
(import stdlib.string)

(define (len-of [s : String]) : i64
  (string.string-length s))

(define (via-ref [p : (& (Tuple String i64))]) : i64
  (len-of (tuple-ref (deref p) 0)))

(define (main) : i64
  (let
    [p (tuple "abc" 1)]
    (via-ref (& p))))
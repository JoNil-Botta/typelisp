(import "stdlib/core_macros.tl" module stdlib.core-macros as core)

; Capturing top-level scalar-element fixed `(Array T N)` values in closure
; environments (#571). `main` yields 42 only if every case holds. The
; "returned" case captures a fixed array whose inline storage is frame-owned in
; the maker, then reads it after the maker returns, so it only passes if the
; capture snapshots the storage onto the heap.
(define (make-reader) : (-> i64)
  (let
    [a : (Array i64 3) (array 40 1 1)]
    (lambda () : i64 (+ (array-ref a 0) (+ (array-ref a 1) (array-ref a 2))))))

(define (case-returned) : bool
  (= ((make-reader)) 42))

(define (case-immediate) : bool
  (let
    [a : (Array i64 4) (array 10 20 30 42)]
    [f : (-> i64) (lambda () : i64 (array-ref a 3))]
    (= (f) 42)))

; Captures snapshot fixed-array storage at lambda creation time, so later
; mutation of the original array does not affect the closure.
(define (case-mutated-after-capture) : bool
  (let
    [a : (Array i64 2) (array 42 7)]
    [f : (-> i64) (lambda () : i64 (array-ref a 0))]
    (begin
      (array-set! a 0 5)
      (= (f) 42))))

(define (main) : i64
  (begin
    (core/unless (case-immediate) (return 1))
    (core/unless (case-returned) (return 2))
    (core/unless (case-mutated-after-capture) (return 3))
    42))
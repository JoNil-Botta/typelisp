(import "stdlib/core_macros.tl" module stdlib.core_macros as core)

; Capturing scalar tuple values in closure environments (#542).
; Each case reads scalars out of a captured tuple so the test exercises capture
; (not by-value aggregate returns); `main` yields 42 only if every case holds.
; (Fixed-array capture is a separate representation gap, still rejected.)
; A scalar tuple captured and read while the creator scope is still live.
(define (case-tuple-immediate) : bool
  (let
    [t : (Tuple i64 i64) (tuple 17 25)]
    [f : (-> i64)
      (lambda () : i64
        (+ (tuple-ref t 0) (tuple-ref t 1)))]
    (= (f) 42)))

; A scalar tuple created inside a frame, captured by the returned closure, and
; read AFTER that frame returns (the key dangling case): only safe if capture
; snapshots the inline storage onto the heap.
(define (make-tuple-reader) : (-> i64)
  (let
    [t : (Tuple i64 i64) (tuple 40 2)]
    (lambda () : i64
      (+ (tuple-ref t 0) (tuple-ref t 1)))))

(define (case-tuple-returned) : bool
  (= ((make-tuple-reader)) 42))

; Mixed capture: a scalar and a scalar tuple captured together.
(define (case-tuple-mixed) : bool
  (let
    [n : i64 30]
    [t : (Tuple i64 i64) (tuple 8 4)]
    (=
      ((lambda () : i64
          (+ n (+ (tuple-ref t 0) (tuple-ref t 1)))))
      42)))

(define (main) : i64
  (begin
    (core/unless (case-tuple-immediate) (return 1))
    (core/unless (case-tuple-returned) (return 2))
    (core/unless (case-tuple-mixed) (return 3))
    42))
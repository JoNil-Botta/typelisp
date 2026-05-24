; Capturing scalar-element fixed `(Array T N)` values in closure environments
; (#571). `main` yields 42 only if every case holds. The "returned" case
; captures a fixed array whose inline storage is frame-owned in the maker, then
; reads it after the maker returns, so it only passes if the capture snapshots
; the storage onto the heap.

; Fixed array captured by a closure that OUTLIVES the frame that built it.
(define (make-reader) : (-> i64)
  (let ([a : (Array i64 3) (array 40 1 1)])
    (lambda () : i64 (+ (array-ref a 0) (+ (array-ref a 1) (array-ref a 2))))))

(define (case-returned) : bool
  (= ((make-reader)) 42))

; Fixed array captured and indexed while the creator scope is still live.
(define (case-immediate) : bool
  (let ([a : (Array i64 4) (array 10 20 30 42)]
        [f : (-> i64) (lambda () : i64 (array-ref a 3))])
    (= (f) 42)))

(define (main) : i64
  (if (case-immediate)
      (if (case-returned) 42 2)
      1))

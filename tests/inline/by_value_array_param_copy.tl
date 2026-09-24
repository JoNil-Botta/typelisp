;; A by-value aggregate parameter is the callee's own copy on every target: a
;; callee that writes its parameter never changes the caller's value (#8009).
;; Win64 passes a memory-class argument as a pointer to a caller-made copy;
;; when `typelisp test` lowered harnesses in the target-neutral mode that copy
;; was missing and the second call below saw the first call's write.
(import stdlib.test)

;; Writes a separator and a suffix into its own copy of `path`, as
;; `winsock-identity-from-paths` does, and reports what it saw first.
(define (append-suffix [path : (Array u16 64)] [length : i64]) : i64
  (let
    [before : i64 (cast (array-ref path length) : i64)]
    (begin
      (set! (array-ref path length) (cast 92 : u16))
      (set! (array-ref path (+ length 1)) (cast 88 : u16))
      before)))

(define (sum-prefix [path : (Array u16 64)] [length : i64]) : i64
  (let
    [total : i64 0]
    [index : i64 0]
    (begin
      (while (< index length)
        (begin
          (set! total (+ total (cast (array-ref path index) : i64)))
          (set! index (+ index 1))))
      total)))

(test
  by-value-array-parameter-writes-stay-in-the-callee
  (let
    [path : (Array u16 64) (init : (Array u16 64))]
    (begin
      (set! (array-ref path 0) (cast 67 : u16))
      (set! (array-ref path 1) (cast 58 : u16))
      (test.assert-i64-eq (append-suffix path 2) 0 "first call sees a NUL")
      (test.assert-i64-eq (append-suffix path 2) 0 "second call sees a NUL")
      (test.assert-i64-eq
        (cast (array-ref path 2) : i64)
        0
        "caller's element 2 is unchanged")
      (test.assert-i64-eq
        (cast (array-ref path 3) : i64)
        0
        "caller's element 3 is unchanged")
      (test.assert-i64-eq (sum-prefix path 2) 125 "caller's prefix is intact"))))
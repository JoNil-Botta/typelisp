;; Immediate raw atomic calls compile when the caller explicitly accepts the
;; storage validity, alignment, initialization, lifetime and concurrency proof.
;; This check-only fixture must never execute the helpers.
(import stdlib.runtime)

(define (exercise-i64 [read : (Ptr i64)] [write : (MutPtr i64)]) : i64
  (unsafe
    (begin
      (runtime.atomic-i64-store-ptr! write 1)
      (runtime.atomic-i64-add-ptr! write 1)
      (runtime.atomic-i64-fetch-add-ptr! write 1)
      (runtime.atomic-i64-cas-ptr! write 3 4)
      (runtime.atomic-i64-load-ptr read))))

(define (exercise-i32 [read : (Ptr i32)] [write : (MutPtr i32)]) : i32
  (unsafe
    (begin
      (runtime.atomic-i32-store-ptr! write (cast 1 : i32))
      (runtime.atomic-i32-add-ptr! write (cast 1 : i32))
      (runtime.atomic-i32-fetch-add-ptr! write (cast 1 : i32))
      (runtime.atomic-i32-cas-ptr! write (cast 3 : i32) (cast 4 : i32))
      (runtime.atomic-i32-load-ptr read))))

(define (main) : i64
  0)
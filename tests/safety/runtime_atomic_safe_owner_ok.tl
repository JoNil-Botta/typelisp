;; Owning atomic buffers establish storage validity and remain safe to use.
(import stdlib.atomic)

(define (exercise-i64 [items : (& source atomic.AtomicI64Buffer)]) : i64
  (begin
    (atomic.atomic-i64-store! items 0 1)
    (atomic.atomic-i64-add! items 0 1)
    (atomic.atomic-i64-fetch-add! items 0 1)
    (atomic.atomic-i64-load items 0)))

(define (exercise-i32 [items : (& source atomic.AtomicI32Buffer)]) : i32
  (begin
    (atomic.atomic-i32-store! items 0 (cast 1 : i32))
    (atomic.atomic-i32-add! items 0 (cast 1 : i32))
    (atomic.atomic-i32-fetch-add! items 0 (cast 1 : i32))
    (atomic.atomic-i32-load items 0)))

(define (main) : i64
  0)
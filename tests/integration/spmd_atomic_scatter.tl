(import "stdlib/atomic.tl")

(define (fill-indexes [ix : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n]) (array-set! ix i (% i 4))))

(define (clear-buckets
  [out64 : (Array i64)]
  [out32 : (Array i32)]
  [serial32 : (Array i32)]) : unit
  (begin
    (foreach
      ([i : i64 0 4])
      (begin
        (atomic-i64-store! out64 i 0)
        (atomic-i32-store! out32 i (cast 0 : i32))))
    (atomic-i32-store! serial32 0 (cast 0 : i32))))

(define (inactive-oob-body [out64 : (Array i64)] [out32 : (Array i32)]) : unit
  (foreach
    ([i : i64 0 0])
    (begin
      (atomic-i64-add! out64 99 1)
      (atomic-i32-store! out32 99 (cast 1 : i32)))))

(define (atomic-accumulate
  [ix : (Array i64)]
  [out64 : (Array i64)]
  [out32 : (Array i32)]
  [serial32 : (Array i32)]
  [old64 : (Array i64)]
  [old32 : (Array i32)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [bucket : i64 (array-ref ix i)]
      (begin
        (array-set! old64 i (atomic-i64-fetch-add! out64 bucket (+ i 1)))
        (atomic-i32-add! out32 bucket (cast (+ i 1) : i32))
        (array-set! old32 i (atomic-i32-fetch-add! serial32 0 (cast 1 : i32)))))))

(define (snapshot-loads
  [ix : (Array i64)]
  [out64 : (Array i64)]
  [snapshot : (Array i64)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! snapshot i (atomic-i64-load out64 (array-ref ix i)))))

(define (masked-even-add [ix : (Array i64)] [out64 : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (= (% i 2) 0)
      (atomic-i64-add! out64 (array-ref ix i) 1)
      unit)))

(define (check-accumulated
  [out64 : (Array i64)]
  [out32 : (Array i32)]
  [serial32 : (Array i32)]
  [old64 : (Array i64)]
  [old32 : (Array i32)]
  [snapshot : (Array i64)]) : bool
  (let
    [ok : bool true]
    (begin
      (if (= (atomic-i64-load out64 0) 45)
        unit
        (set! ok false))
      (if (= (atomic-i64-load out64 1) 32)
        unit
        (set! ok false))
      (if (= (atomic-i64-load out64 2) 36)
        unit
        (set! ok false))
      (if (= (atomic-i64-load out64 3) 40)
        unit
        (set! ok false))
      (if (= (atomic-i32-load out32 0) (cast 45 : i32))
        unit
        (set! ok false))
      (if (= (atomic-i32-load out32 1) (cast 32 : i32))
        unit
        (set! ok false))
      (if (= (atomic-i32-load out32 2) (cast 36 : i32))
        unit
        (set! ok false))
      (if (= (atomic-i32-load out32 3) (cast 40 : i32))
        unit
        (set! ok false))
      (if (= (atomic-i32-load serial32 0) (cast 17 : i32))
        unit
        (set! ok false))
      (if (= (array-ref old64 0) 0)
        unit
        (set! ok false))
      (if (= (array-ref old64 4) 1)
        unit
        (set! ok false))
      (if (= (array-ref old64 16) 28)
        unit
        (set! ok false))
      (if (= (array-ref old32 0) (cast 0 : i32))
        unit
        (set! ok false))
      (if (= (array-ref old32 16) (cast 16 : i32))
        unit
        (set! ok false))
      (if (= (array-ref snapshot 0) 45)
        unit
        (set! ok false))
      (if (= (array-ref snapshot 1) 32)
        unit
        (set! ok false))
      (if (= (array-ref snapshot 16) 45)
        unit
        (set! ok false))
      ok)))

(define (check-after-mask [out64 : (Array i64)]) : bool
  (let
    [ok : bool true]
    (begin
      (if (= (atomic-i64-load out64 0) 50)
        unit
        (set! ok false))
      (if (= (atomic-i64-load out64 1) 32)
        unit
        (set! ok false))
      (if (= (atomic-i64-load out64 2) 40)
        unit
        (set! ok false))
      (if (= (atomic-i64-load out64 3) 40)
        unit
        (set! ok false))
      ok)))

(define (main) : i64
  (let
    [n : i64 17]
    [ix : (Array i64) (make-array i64 n)]
    [out64 : (Array i64) (make-array i64 4)]
    [out32 : (Array i32) (make-array i32 4)]
    [serial32 : (Array i32) (make-array i32 1)]
    [old64 : (Array i64) (make-array i64 n)]
    [old32 : (Array i32) (make-array i32 n)]
    [snapshot : (Array i64) (make-array i64 n)]
    (begin
      (fill-indexes ix n)
      (atomic-i64-store! out64 0 7)
      (if (!= (atomic-i64-load out64 0) 7)
        1
        (begin
          (clear-buckets out64 out32 serial32)
          (inactive-oob-body out64 out32)
          (atomic-accumulate ix out64 out32 serial32 old64 old32 n)
          (snapshot-loads ix out64 snapshot n)
          (if (not
            (check-accumulated out64 out32 serial32 old64 old32 snapshot))
            2
            (begin
              (masked-even-add ix out64 n)
              (if (check-after-mask out64)
                42
                3))))))))
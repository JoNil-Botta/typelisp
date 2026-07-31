(import stdlib.vector)
(import stdlib.atomic)
(import (vector.vector i64) as i64v)
(import (vector.vector i32) as i32v)
(import "spmd_vec_support.tl" module spmd.vec.support as spmdv)
(import (spmdv.zeroed i64 0) as i64z)
(import (spmdv.zeroed i32 (cast 0 : i32)) as i32z)

(define (fill-indexes [ix : (&mut ix i64v.Vec)] [n : i64]) : unit
  (let
    [ix-slots (i64v.slots-mut ix)]
    (foreach ([i : i64 0 n]) (array-set! ix-slots i (% i 4)))))

(define (clear-buckets
  [out64 : (& out64 atomic.AtomicI64Buffer)]
  [out32 : (& out32 atomic.AtomicI32Buffer)]
  [serial32 : (& serial32 atomic.AtomicI32Buffer)]) : unit
  (begin
    (foreach
      ([i : i64 0 4])
      (begin
        (atomic.atomic-i64-store! out64 i 0)
        (atomic.atomic-i32-store! out32 i (cast 0 : i32))))
    (atomic.atomic-i32-store! serial32 0 (cast 0 : i32))))

(define (inactive-oob-body
  [out64 : (& out64 atomic.AtomicI64Buffer)]
  [out32 : (& out32 atomic.AtomicI32Buffer)]) : unit
  (foreach
    ([i : i64 0 0])
    (begin
      (atomic.atomic-i64-add! out64 99 1)
      (atomic.atomic-i32-store! out32 99 (cast 1 : i32)))))

(define (atomic-accumulate
  [ix : (& ix i64v.Vec)]
  [out64 : (& out64 atomic.AtomicI64Buffer)]
  [out32 : (& out32 atomic.AtomicI32Buffer)]
  [serial32 : (& serial32 atomic.AtomicI32Buffer)]
  [old64 : (&mut old64 i64v.Vec)]
  [old32 : (&mut old32 i32v.Vec)]
  [n : i64]) : unit
  (let
    [ix-slots (i64v.slots ix)]
    [old64-slots (i64v.slots-mut old64)]
    [old32-slots (i32v.slots-mut old32)]
    (foreach
      ([i : i64 0 n])
      (let
        [bucket : i64 (array-ref ix-slots i)]
        (begin
          (array-set!
            old64-slots
            i
            (atomic.atomic-i64-fetch-add! out64 bucket (+ i 1)))
          (atomic.atomic-i32-add! out32 bucket (cast (+ i 1) : i32))
          (array-set!
            old32-slots
            i
            (atomic.atomic-i32-fetch-add! serial32 0 (cast 1 : i32))))))))

(define (snapshot-loads
  [ix : (& ix i64v.Vec)]
  [out64 : (& out64 atomic.AtomicI64Buffer)]
  [snapshot : (&mut snapshot i64v.Vec)]
  [n : i64]) : unit
  (let
    [ix-slots (i64v.slots ix)]
    [snapshot-slots (i64v.slots-mut snapshot)]
    (foreach
      ([i : i64 0 n])
      (array-set!
        snapshot-slots
        i
        (atomic.atomic-i64-load out64 (array-ref ix-slots i))))))

(define (masked-even-add
  [ix : (& ix i64v.Vec)]
  [out64 : (& out64 atomic.AtomicI64Buffer)]
  [n : i64]) : unit
  (let
    [ix-slots (i64v.slots ix)]
    (foreach
      ([i : i64 0 n])
      (if (= (% i 2) 0)
        (atomic.atomic-i64-add! out64 (array-ref ix-slots i) 1)
        unit))))

(define (check-accumulated
  [out64 : (& out64 atomic.AtomicI64Buffer)]
  [out32 : (& out32 atomic.AtomicI32Buffer)]
  [serial32 : (& serial32 atomic.AtomicI32Buffer)]
  [old64 : (& old64 i64v.Vec)]
  [old32 : (& old32 i32v.Vec)]
  [snapshot : (& snapshot i64v.Vec)]) : bool
  (let
    [old64-slots (i64v.slots old64)]
    [old32-slots (i32v.slots old32)]
    [snapshot-slots (i64v.slots snapshot)]
    [ok : bool true]
    (begin
      (if (= (atomic.atomic-i64-load out64 0) 45)
        unit
        (set! ok false))
      (if (= (atomic.atomic-i64-load out64 1) 32)
        unit
        (set! ok false))
      (if (= (atomic.atomic-i64-load out64 2) 36)
        unit
        (set! ok false))
      (if (= (atomic.atomic-i64-load out64 3) 40)
        unit
        (set! ok false))
      (if (= (atomic.atomic-i32-load out32 0) (cast 45 : i32))
        unit
        (set! ok false))
      (if (= (atomic.atomic-i32-load out32 1) (cast 32 : i32))
        unit
        (set! ok false))
      (if (= (atomic.atomic-i32-load out32 2) (cast 36 : i32))
        unit
        (set! ok false))
      (if (= (atomic.atomic-i32-load out32 3) (cast 40 : i32))
        unit
        (set! ok false))
      (if (= (atomic.atomic-i32-load serial32 0) (cast 17 : i32))
        unit
        (set! ok false))
      (if (= (array-ref old64-slots 0) 0)
        unit
        (set! ok false))
      (if (= (array-ref old64-slots 4) 1)
        unit
        (set! ok false))
      (if (= (array-ref old64-slots 16) 28)
        unit
        (set! ok false))
      (if (= (array-ref old32-slots 0) (cast 0 : i32))
        unit
        (set! ok false))
      (if (= (array-ref old32-slots 16) (cast 16 : i32))
        unit
        (set! ok false))
      (if (= (array-ref snapshot-slots 0) 45)
        unit
        (set! ok false))
      (if (= (array-ref snapshot-slots 1) 32)
        unit
        (set! ok false))
      (if (= (array-ref snapshot-slots 16) 45)
        unit
        (set! ok false))
      ok)))

(define (check-after-mask [out64 : (& out64 atomic.AtomicI64Buffer)]) : bool
  (let
    [ok : bool true]
    (begin
      (if (= (atomic.atomic-i64-load out64 0) 50)
        unit
        (set! ok false))
      (if (= (atomic.atomic-i64-load out64 1) 32)
        unit
        (set! ok false))
      (if (= (atomic.atomic-i64-load out64 2) 40)
        unit
        (set! ok false))
      (if (= (atomic.atomic-i64-load out64 3) 40)
        unit
        (set! ok false))
      ok)))

(define (main) : i64
  (let
    [n : i64 17]
    [ix : i64v.Vec (i64z.make n)]
    [out64 : atomic.AtomicI64Buffer (atomic.i64-buffer 4)]
    [out32 : atomic.AtomicI32Buffer (atomic.i32-buffer 4)]
    [serial32 : atomic.AtomicI32Buffer (atomic.i32-buffer 1)]
    [old64 : i64v.Vec (i64z.make n)]
    [old32 : i32v.Vec (i32z.make n)]
    [snapshot : i64v.Vec (i64z.make n)]
    (begin
      (fill-indexes (&mut ix) n)
      (atomic.atomic-i64-store! (& out64) 0 7)
      (if (!= (atomic.atomic-i64-load (& out64) 0) 7)
        1
        (begin
          (clear-buckets (& out64) (& out32) (& serial32))
          (inactive-oob-body (& out64) (& out32))
          (atomic-accumulate
            (& ix)
            (& out64)
            (& out32)
            (& serial32)
            (&mut old64)
            (&mut old32)
            n)
          (snapshot-loads (& ix) (& out64) (&mut snapshot) n)
          (if (not
            (check-accumulated
              (& out64)
              (& out32)
              (& serial32)
              (& old64)
              (& old32)
              (& snapshot)))
            2
            (begin
              (masked-even-add (& ix) (& out64) n)
              (if (check-after-mask (& out64))
                42
                3))))))))
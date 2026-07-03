;; SPMD vector/slice surface migration (#3578): public APIs take generated
;; vectors and borrowed slices, while the SPMD body borrows their backing storage
;; before using varying lane indexes. This keeps public dynamic `(Array T)` out
;; of the user-facing function signatures.
(import stdlib.vector)
(import stdlib.vector_slice)
(import (vector.vector i64) as i64v)
(import (vector_slice.slice i64) as i64s)

(define (init-vec [v : (&mut v i64v.Vec)] [n : i64] [scale : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (i64v.push v (+ (* i scale) 1))
        (set! i (+ i 1))))))

(define (fill-vector-foreach
  [a : (& a i64v.Vec)]
  [b : (& b i64v.Vec)]
  [out : (&mut out i64v.Vec)]
  [n : i64]) : unit
  (let
    [a-slots : (& a (Array i64)) (i64v.slots a)]
    [b-slots : (& b (Array i64)) (i64v.slots b)]
    [out-slots : (&mut out (Array i64)) (i64v.slots-mut out)]
    (foreach
      ([i : i64 0 n])
      (array-set! out-slots i (+ (array-ref a-slots i) (array-ref b-slots i))))))

(define (fill-slice-foreach
  [a : (i64s.Slice a)]
  [b : (i64s.Slice b)]
  [out : (i64s.MutSlice out)]
  [n : i64]) : unit
  (let
    [a-slots : (& a (Array i64)) (struct-get a slots)]
    [b-slots : (& b (Array i64)) (struct-get b slots)]
    [out-slots : (&mut out (Array i64)) (struct-get out slots)]
    (foreach
      ([i : i64 0 n])
      (array-set! out-slots i (+ (array-ref a-slots i) (array-ref b-slots i))))))

(define (checksum [v : (& v i64v.Vec)] [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (i64v.get v i 0)))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 13]
    [a : i64v.Vec (i64v.with-capacity n)]
    [b : i64v.Vec (i64v.with-capacity n)]
    [out : i64v.Vec (i64v.with-capacity n)]
    (begin
      (init-vec (&mut a) n 1)
      (init-vec (&mut b) n 2)
      (init-vec (&mut out) n 0)
      (fill-vector-foreach (& a) (& b) (&mut out) n)
      (let
        [full-a : (i64s.Slice a) (i64s.all-vec (& a))]
        [full-b : (i64s.Slice b) (i64s.from-vec (& b) 0 n)]
        (begin
          (let
            [out-slice : (i64s.MutSlice out) (i64s.all-vec-mut (&mut out))]
            (fill-slice-foreach full-a full-b out-slice n))
          (bit-and (checksum (& out) n) 0xff))))))
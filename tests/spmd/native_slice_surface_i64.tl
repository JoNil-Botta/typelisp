;; SPMD vector/native Slice surface: public APIs take generated vectors and
;; native borrowed slices while varying lane indexes operate through the views.
(import stdlib.vector)
(import (vector.vector i64) as i64v)

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
    [a-slots (i64v.slots a)]
    [b-slots (i64v.slots b)]
    [out-slots (i64v.slots-mut out)]
    (foreach
      ([i : i64 0 n])
      (array-set! out-slots i (+ (array-ref a-slots i) (array-ref b-slots i))))))

(define (fill-slice-foreach
  [a : (& a (Slice i64))]
  [b : (& b (Slice i64))]
  [out : (&mut out (Slice i64))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))

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
        [full-a : (& a (Slice i64)) (i64v.view (& a))]
        [full-b : (& b (Slice i64)) (slice-view (i64v.view (& b)) 0 n)]
        (begin
          (let
            [out-slice : (&mut out (Slice i64)) (i64v.view-mut (&mut out))]
            (fill-slice-foreach full-a full-b out-slice n))
          (bit-and (checksum (& out) n) 0xff))))))
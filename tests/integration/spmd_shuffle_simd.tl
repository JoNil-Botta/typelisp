; SIMD intra-gang shuffle coverage. Identity shuffles cover a partial tail;
; selectors that use the backend gang width operate on full gangs.
(import stdlib.vector)
(import (vector.vector i64) as i64v)
(import (vector.vector i32) as i32v)
(import "spmd_vec_support.tl" module spmd.vec.support as spmdv)
(import (spmdv.zeroed i64 0) as i64z)
(import (spmdv.zeroed i32 (cast 0 : i32)) as i32z)

(define (init [xs : (&mut xs i64v.Vec)] [n : i64]) : unit
  (let
    [xs-slots (i64v.slots-mut xs)]
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! xs-slots i (+ (* i 3) 1))
        (set! i (+ i 1))))))

(define (sum [xs : (& xs i64v.Vec)] [n : i64]) : i64
  (let
    [xs-slots (i64v.slots xs)]
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (array-ref xs-slots i)))
          (set! i (+ i 1))))
      acc)))

(define (init32 [xs : (&mut xs i32v.Vec)] [n : i64]) : unit
  (let
    [xs-slots (i32v.slots-mut xs)]
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! xs-slots i (cast (+ (* i 5) 2) : i32))
        (set! i (+ i 1))))))

(define (sum32 [xs : (& xs i32v.Vec)] [n : i64]) : i64
  (let
    [xs-slots (i32v.slots xs)]
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (cast (array-ref xs-slots i) : i64)))
          (set! i (+ i 1))))
      acc)))

(define (same64
  [left : (& left i64v.Vec)]
  [right : (& right i64v.Vec)]
  [n : i64]) : bool
  (let
    [left-slots (i64v.slots left)]
    [right-slots (i64v.slots right)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (if (not (= (array-ref left-slots i) (array-ref right-slots i)))
            (set! ok false)
            unit)
          (set! i (+ i 1))))
      ok)))

(define (main) : i64
  (let
    [n : i64 19]
    [xs : i64v.Vec (i64z.make n)]
    [out : i64v.Vec (i64z.make n)]
    [rev1 : i64v.Vec (i64z.make n)]
    [rev2 : i64v.Vec (i64z.make n)]
    [xs32 : i32v.Vec (i32z.make n)]
    [out32 : i32v.Vec (i32z.make n)]
    [full : i64 16]
    [rot1 : i64v.Vec (i64z.make full)]
    [rot2 : i64v.Vec (i64z.make full)]
    [repeat : i64v.Vec (i64z.make full)]
    [uniform-selector : i64v.Vec (i64z.make full)]
    [uniform-source : i64v.Vec (i64z.make full)]
    (begin
      (init (&mut xs) n)
      (init32 (&mut xs32) n)
      (let
        [src (i64v.slots (& xs))]
        [dst (i64v.slots-mut (&mut out))]
        (foreach
          ([i : i64 0 n])
          (array-set! dst i (spmd-shuffle (array-ref src i) (program-index)))))
      (let
        [src (i64v.slots (& xs))]
        [dst (i64v.slots-mut (&mut rev1))]
        (foreach
          ([i : i64 0 full])
          (array-set!
            dst
            i
            (spmd-shuffle
              (array-ref src i)
              (+ (* -1 (program-index)) (+ (program-count) -1))))))
      (let
        [src (i64v.slots (& rev1))]
        [dst (i64v.slots-mut (&mut rev2))]
        (foreach
          ([i : i64 0 full])
          (array-set!
            dst
            i
            (spmd-shuffle
              (array-ref src i)
              (+ (* -1 (program-index)) (+ (program-count) -1))))))
      (let
        [src (i32v.slots (& xs32))]
        [dst (i32v.slots-mut (&mut out32))]
        (foreach
          ([i : i64 0 n])
          (array-set! dst i (spmd-shuffle (array-ref src i) (program-index)))))
      ; Full-gang rotate followed by the inverse rotate. `program-count` is a
      ; power of two in both native modes, so bit-and implements lane modulo.
      (let
        [src (i64v.slots (& xs))]
        [dst (i64v.slots-mut (&mut rot1))]
        (foreach
          ([i : i64 0 full])
          (array-set!
            dst
            i
            (spmd-shuffle
              (array-ref src i)
              (bit-and (+ (program-index) 1) (+ (program-count) -1))))))
      (let
        [src (i64v.slots (& rot1))]
        [dst (i64v.slots-mut (&mut rot2))]
        (foreach
          ([i : i64 0 full])
          (array-set!
            dst
            i
            (spmd-shuffle
              (array-ref src i)
              (bit-and
                (+ (program-index) (+ (program-count) -1))
                (+ (program-count) -1))))))
      ; Repeated and uniform selectors use lane identity as their source so
      ; their expected values are independent of the selected SIMD width.
      (let
        [dst (i64v.slots-mut (&mut repeat))]
        (foreach
          ([i : i64 0 full])
          (array-set!
            dst
            i
            (spmd-shuffle (program-index) (bit-and (program-index) 1)))))
      (let
        [dst (i64v.slots-mut (&mut uniform-selector))]
        (foreach
          ([i : i64 0 full])
          (array-set! dst i (spmd-shuffle (program-index) 0))))
      ; A uniform source must still evaluate and validate every varying
      ; selector, even though every valid permutation produces the same value.
      (let
        [dst (i64v.slots-mut (&mut uniform-source))]
        (foreach
          ([i : i64 0 full])
          (array-set! dst i (spmd-shuffle (cast 77 : i64) (program-index)))))
      (if (and
        (= (sum (& out) n) 532)
        (= (sum32 (& out32) n) 893)
        (same64 (& xs) (& rev2) full)
        (same64 (& xs) (& rot2) full)
        (or (= (sum (& repeat) full) 0) (= (sum (& repeat) full) 8))
        (= (sum (& uniform-selector) full) 0)
        (= (sum (& uniform-source) full) 1232))
        42
        1))))
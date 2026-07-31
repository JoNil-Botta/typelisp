(import stdlib.vector)
(import (vector.vector i64) as i64v)
(import (vector.vector i32) as i32v)
(import (vector.vector f32) as f32v)
(import (vector.vector f64) as f64v)
(import spmd_vec_support as spmdv)
(import (spmdv.zeroed i64 0) as i64z)
(import (spmdv.zeroed i32 (cast 0 : i32)) as i32z)
(import (spmdv.zeroed f64 (cast 0 : f64)) as f64z)
(import (spmdv.zeroed f32 (cast 0 : f32)) as f32z)

(define (init-source [xs : (&mut xs i64v.Vec)] [source-len : i64]) : unit
  (let
    [xs-slots (i64v.slots-mut xs)]
    [i : i64 0]
    (while (< i source-len)
      (begin
        (array-set! xs-slots i (+ 100 (* i 3)))
        (set! i (+ i 1))))))

(define (init-index [ix : (&mut ix i64v.Vec)] [n : i64] [source-len : i64]) : unit
  (let
    [ix-slots (i64v.slots-mut ix)]
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! ix-slots i (% (+ (* i 5) 3) source-len))
        (set! i (+ i 1))))))

(define (fill-gather-foreach
  [xs : (& xs i64v.Vec)]
  [ix : (& ix i64v.Vec)]
  [out : (&mut out i64v.Vec)]
  [n : i64]) : unit
  (let
    [xs-slots (i64v.slots xs)]
    [ix-slots (i64v.slots ix)]
    [out-slots (i64v.slots-mut out)]
    (foreach
      ([i : i64 0 n])
      (array-set! out-slots i (array-ref xs-slots (array-ref ix-slots i))))))

(define (fill-gather-scalar
  [xs : (& xs i64v.Vec)]
  [ix : (& ix i64v.Vec)]
  [out : (&mut out i64v.Vec)]
  [n : i64]) : unit
  (let
    [xs-slots (i64v.slots xs)]
    [ix-slots (i64v.slots ix)]
    [out-slots (i64v.slots-mut out)]
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! out-slots i (array-ref xs-slots (array-ref ix-slots i)))
        (set! i (+ i 1))))))

(define (eq-i64 [a : (& a i64v.Vec)] [b : (& b i64v.Vec)] [n : i64]) : bool
  (let
    [a-slots (i64v.slots a)]
    [b-slots (i64v.slots b)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (if (!= (array-ref a-slots i) (array-ref b-slots i))
            (set! ok false)
            unit)
          (set! i (+ i 1))))
      ok)))

(define (case-gather [n : i64]) : bool
  (let
    [source-len : i64 17]
    [xs : i64v.Vec (i64z.make source-len)]
    [ix : i64v.Vec (i64z.make n)]
    [got : i64v.Vec (i64z.make n)]
    [want : i64v.Vec (i64z.make n)]
    (begin
      (init-source (&mut xs) source-len)
      (init-index (&mut ix) n source-len)
      (fill-gather-foreach (& xs) (& ix) (&mut got) n)
      (fill-gather-scalar (& xs) (& ix) (&mut want) n)
      (eq-i64 (& got) (& want) n))))

(define (init-lane-offsets [offsets : (&mut offsets i64v.Vec)]) : unit
  (let
    [n : i64 (i64v.len-mut offsets)]
    [offset-slots (i64v.slots-mut offsets)]
    [i : i64 0]
    (while (< i n)
      (begin
        ;; Repeated, negative, zero, and positive offsets exercise the checked
        ;; logical-lane order without making an index array in memory.
        (array-set! offset-slots i (- (% (* i 3) 6) 3))
        (set! i (+ i 1))))))

(define (fill-lane-offset-gather
  [xs : (& xs i64v.Vec)]
  [offsets : (& offsets i64v.Vec)]
  [out : (&mut out i64v.Vec)]
  [start : i64]
  [end : i64]) : unit
  (let
    [xs-slots (i64v.slots xs)]
    [offset-slots (i64v.slots offsets)]
    [out-slots (i64v.slots-mut out)]
    (foreach
      ([i : i64 start end])
      (array-set!
        out-slots
        i
        (array-ref xs-slots (+ i (array-ref offset-slots (program-index))))))))

(define (fill-reversed-lane-offset-gather
  [xs : (& xs i64v.Vec)]
  [offsets : (& offsets i64v.Vec)]
  [out : (&mut out i64v.Vec)]
  [start : i64]
  [end : i64]) : unit
  (let
    [xs-slots (i64v.slots xs)]
    [offset-slots (i64v.slots offsets)]
    [out-slots (i64v.slots-mut out)]
    (foreach
      ([i : i64 start end])
      (array-set!
        out-slots
        i
        (array-ref xs-slots (+ (array-ref offset-slots (program-index)) i))))))

(define (fill-lane-offset-gather-scalar
  [xs : (& xs i64v.Vec)]
  [offsets : (& offsets i64v.Vec)]
  [lane-ids : (& lane-ids i64v.Vec)]
  [out : (&mut out i64v.Vec)]
  [start : i64]
  [end : i64]) : unit
  (let
    [xs-slots (i64v.slots xs)]
    [offset-slots (i64v.slots offsets)]
    [lane-slots (i64v.slots lane-ids)]
    [out-slots (i64v.slots-mut out)]
    [i : i64 start]
    (while (< i end)
      (begin
        (array-set!
          out-slots
          i
          (array-ref
            xs-slots
            (+ i (array-ref offset-slots (array-ref lane-slots i)))))
        (set! i (+ i 1))))))

(define (case-lane-offset-gather [n : i64] [reversed : bool]) : bool
  (let
    [start : i64 4]
    [end : i64 (+ start n)]
    [source-len : i64 (+ end 4)]
    [xs : i64v.Vec (i64z.make source-len)]
    [offset-count : i64
      (if (< n 4)
        n
        16)]
    [offsets : i64v.Vec (i64z.make offset-count)]
    [lane-ids : i64v.Vec (i64z.make source-len)]
    [got : i64v.Vec (i64z.make source-len)]
    [want : i64v.Vec (i64z.make source-len)]
    (begin
      (init-source (&mut xs) source-len)
      (init-lane-offsets (&mut offsets))
      (let
        [lane-slots (i64v.slots-mut (&mut lane-ids))]
        (foreach
          ([i : i64 start end])
          (array-set! lane-slots i (program-index))))
      (if reversed
        (fill-reversed-lane-offset-gather
          (& xs)
          (& offsets)
          (&mut got)
          start
          end)
        (fill-lane-offset-gather (& xs) (& offsets) (&mut got) start end))
      (fill-lane-offset-gather-scalar
        (& xs)
        (& offsets)
        (& lane-ids)
        (&mut want)
        start
        end)
      (eq-i64 (& got) (& want) source-len))))

(define (case-i32-gather [n : i64]) : bool
  (let
    [source-len : i64 17]
    [ix : i64v.Vec (i64z.make n)]
    [xs : i32v.Vec (i32z.make source-len)]
    [got : i32v.Vec (i32z.make n)]
    [want : i32v.Vec (i32z.make n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (init-index (&mut ix) n source-len)
      (while (< i source-len)
        (begin
          (i32v.set (&mut xs) i (cast (+ 11 (* i 7)) : i32))
          (set! i (+ i 1))))
      (let
        [ix-slots (i64v.slots (& ix))]
        [src (i32v.slots (& xs))]
        [dst (i32v.slots-mut (&mut got))]
        (foreach
          ([j : i64 0 n])
          (array-set! dst j (array-ref src (array-ref ix-slots j)))))
      (set! i 0)
      (while (< i n)
        (let
          [source-index : i64 (i64v.get (& ix) i 0)]
          (begin
            (i32v.set
              (&mut want)
              i
              (i32v.get (& xs) source-index (cast 0 : i32)))
            (set! i (+ i 1)))))
      (set! i 0)
      (while (< i n)
        (begin
          (if (=
            (i32v.get (& got) i (cast 0 : i32))
            (i32v.get (& want) i (cast 0 : i32)))
            unit
            (set! ok false))
          (set! i (+ i 1))))
      ok)))

(define (case-f32-gather [n : i64]) : bool
  (let
    [source-len : i64 17]
    [ix : i64v.Vec (i64z.make n)]
    [xs : f32v.Vec (f32z.make source-len)]
    [got : f32v.Vec (f32z.make n)]
    [want : f32v.Vec (f32z.make n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (init-index (&mut ix) n source-len)
      (while (< i source-len)
        (begin
          (f32v.set (&mut xs) i (cast (+ 21 (* i 5)) : f32))
          (set! i (+ i 1))))
      (let
        [ix-slots (i64v.slots (& ix))]
        [src (f32v.slots (& xs))]
        [dst (f32v.slots-mut (&mut got))]
        (foreach
          ([j : i64 0 n])
          (array-set! dst j (array-ref src (array-ref ix-slots j)))))
      (set! i 0)
      (while (< i n)
        (let
          [source-index : i64 (i64v.get (& ix) i 0)]
          (begin
            (f32v.set
              (&mut want)
              i
              (f32v.get (& xs) source-index (cast 0 : f32)))
            (set! i (+ i 1)))))
      (set! i 0)
      (while (< i n)
        (begin
          (if (=
            (f32v.get (& got) i (cast 0 : f32))
            (f32v.get (& want) i (cast 0 : f32)))
            unit
            (set! ok false))
          (set! i (+ i 1))))
      ok)))

(define (case-f64-gather [n : i64]) : bool
  (let
    [source-len : i64 17]
    [ix : i64v.Vec (i64z.make n)]
    [xs : f64v.Vec (f64z.make source-len)]
    [got : f64v.Vec (f64z.make n)]
    [want : f64v.Vec (f64z.make n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (init-index (&mut ix) n source-len)
      (while (< i source-len)
        (begin
          (f64v.set (&mut xs) i (cast (+ 31 (* i 9)) : f64))
          (set! i (+ i 1))))
      (let
        [ix-slots (i64v.slots (& ix))]
        [src (f64v.slots (& xs))]
        [dst (f64v.slots-mut (&mut got))]
        (foreach
          ([j : i64 0 n])
          (array-set! dst j (array-ref src (array-ref ix-slots j)))))
      (set! i 0)
      (while (< i n)
        (let
          [source-index : i64 (i64v.get (& ix) i 0)]
          (begin
            (f64v.set
              (&mut want)
              i
              (f64v.get (& xs) source-index (cast 0 : f64)))
            (set! i (+ i 1)))))
      (set! i 0)
      (while (< i n)
        (begin
          (if (=
            (f64v.get (& got) i (cast 0 : f64))
            (f64v.get (& want) i (cast 0 : f64)))
            unit
            (set! ok false))
          (set! i (+ i 1))))
      ok)))

(define (case-numeric-gathers [n : i64]) : bool
  (and (case-i32-gather n) (case-f32-gather n) (case-f64-gather n)))

(define (case-i32-lane-offset-gather [n : i64]) : bool
  (let
    [source-len : i64 (+ n 4)]
    [offsets : i64v.Vec (i64z.make 16)]
    [lane-ids : i64v.Vec (i64z.make n)]
    [xs : i32v.Vec (i32z.make source-len)]
    [got : i32v.Vec (i32z.make n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i 16)
        (begin
          (i64v.set (&mut offsets) i (% (* i 3) 4))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i source-len)
        (begin
          (i32v.set (&mut xs) i (cast (+ 11 (* i 7)) : i32))
          (set! i (+ i 1))))
      (let
        [dst (i64v.slots-mut (&mut lane-ids))]
        (foreach ([j : i64 0 n]) (array-set! dst j (program-index))))
      (let
        [offset-slots (i64v.slots (& offsets))]
        [src (i32v.slots (& xs))]
        [dst (i32v.slots-mut (&mut got))]
        (foreach
          ([j : i64 0 n])
          (array-set!
            dst
            j
            (array-ref src (+ j (array-ref offset-slots (program-index)))))))
      (set! i 0)
      (while (< i n)
        (let
          [lane : i64 (i64v.get (& lane-ids) i 0)]
          [source-index : i64 (+ i (i64v.get (& offsets) lane 0))]
          (begin
            (if (=
              (i32v.get (& got) i (cast 0 : i32))
              (i32v.get (& xs) source-index (cast 0 : i32)))
              unit
              (set! ok false))
            (set! i (+ i 1)))))
      ok)))

(define (case-f32-lane-offset-gather [n : i64]) : bool
  (let
    [source-len : i64 (+ n 4)]
    [offsets : i64v.Vec (i64z.make 16)]
    [lane-ids : i64v.Vec (i64z.make n)]
    [xs : f32v.Vec (f32z.make source-len)]
    [got : f32v.Vec (f32z.make n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i 16)
        (begin
          (i64v.set (&mut offsets) i (% (* i 3) 4))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i source-len)
        (begin
          (f32v.set (&mut xs) i (cast (+ 21 (* i 5)) : f32))
          (set! i (+ i 1))))
      (let
        [dst (i64v.slots-mut (&mut lane-ids))]
        (foreach ([j : i64 0 n]) (array-set! dst j (program-index))))
      (let
        [offset-slots (i64v.slots (& offsets))]
        [src (f32v.slots (& xs))]
        [dst (f32v.slots-mut (&mut got))]
        (foreach
          ([j : i64 0 n])
          (array-set!
            dst
            j
            (array-ref src (+ j (array-ref offset-slots (program-index)))))))
      (set! i 0)
      (while (< i n)
        (let
          [lane : i64 (i64v.get (& lane-ids) i 0)]
          [source-index : i64 (+ i (i64v.get (& offsets) lane 0))]
          (begin
            (if (=
              (f32v.get (& got) i (cast 0 : f32))
              (f32v.get (& xs) source-index (cast 0 : f32)))
              unit
              (set! ok false))
            (set! i (+ i 1)))))
      ok)))

(define (case-f64-lane-offset-gather [n : i64]) : bool
  (let
    [source-len : i64 (+ n 4)]
    [offsets : i64v.Vec (i64z.make 16)]
    [lane-ids : i64v.Vec (i64z.make n)]
    [xs : f64v.Vec (f64z.make source-len)]
    [got : f64v.Vec (f64z.make n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i 16)
        (begin
          (i64v.set (&mut offsets) i (% (* i 3) 4))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i source-len)
        (begin
          (f64v.set (&mut xs) i (cast (+ 31 (* i 9)) : f64))
          (set! i (+ i 1))))
      (let
        [dst (i64v.slots-mut (&mut lane-ids))]
        (foreach ([j : i64 0 n]) (array-set! dst j (program-index))))
      (let
        [offset-slots (i64v.slots (& offsets))]
        [src (f64v.slots (& xs))]
        [dst (f64v.slots-mut (&mut got))]
        (foreach
          ([j : i64 0 n])
          (array-set!
            dst
            j
            (array-ref src (+ j (array-ref offset-slots (program-index)))))))
      (set! i 0)
      (while (< i n)
        (let
          [lane : i64 (i64v.get (& lane-ids) i 0)]
          [source-index : i64 (+ i (i64v.get (& offsets) lane 0))]
          (begin
            (if (=
              (f64v.get (& got) i (cast 0 : f64))
              (f64v.get (& xs) source-index (cast 0 : f64)))
              unit
              (set! ok false))
            (set! i (+ i 1)))))
      ok)))

(define (case-numeric-lane-offset-gathers [n : i64]) : bool
  (and
    (case-i32-lane-offset-gather n)
    (case-f32-lane-offset-gather n)
    (case-f64-lane-offset-gather n)))

(define (all-cases) : bool
  (let
    [ok : bool true]
    (begin
      (if (case-gather 0)
        unit
        (set! ok false))
      (if (case-gather 1)
        unit
        (set! ok false))
      (if (case-gather 3)
        unit
        (set! ok false))
      (if (case-gather 13)
        unit
        (set! ok false))
      (if (case-gather 33)
        unit
        (set! ok false))
      (if (case-numeric-gathers 33)
        unit
        (set! ok false))
      (if (case-lane-offset-gather 0 false)
        unit
        (set! ok false))
      (if (case-lane-offset-gather 3 false)
        unit
        (set! ok false))
      (if (case-lane-offset-gather 8 false)
        unit
        (set! ok false))
      (if (case-lane-offset-gather 13 true)
        unit
        (set! ok false))
      (if (case-lane-offset-gather 33 false)
        unit
        (set! ok false))
      (if (case-numeric-lane-offset-gathers 33)
        unit
        (set! ok false))
      ok)))

(define (main) : i64
  (if (all-cases)
    42
    1))
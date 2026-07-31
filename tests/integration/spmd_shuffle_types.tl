; All supported shuffle value classes. Float checks compare representations so
; signed zero and NaN payloads must survive the integer permute unchanged.
(import stdlib.vector)
(import stdlib.math)
(import (vector.vector u64) as u64v)
(import (vector.vector u32) as u32v)
(import (vector.vector f64) as f64v)
(import (vector.vector f32) as f32v)
(import "spmd_vec_support.tl" module spmd.vec.support as spmdv)
(import (spmdv.zeroed u64 (cast 0 : u64)) as u64z)
(import (spmdv.zeroed u32 (cast 0 : u32)) as u32z)
(import (spmdv.zeroed f64 (cast 0 : f64)) as f64z)
(import (spmdv.zeroed f32 (cast 0 : f32)) as f32z)

(define (f64-bits [i : i64]) : u64
  (match (% i 4)
    [0 0x8000000000000000]
    [1 0x7ff8000000001234]
    [2 0x3ff0000000000000]
    [_ 0xbff0000000000000]))

(define (f32-bits [i : i64]) : u32
  (match (% i 4)
    [0 (cast 0x80000000 : u32)]
    [1 (cast 0x7fc01234 : u32)]
    [2 (cast 0x3f800000 : u32)]
    [_ (cast 0xbf800000 : u32)]))

(define (init
  [u64s : (&mut u64s u64v.Vec)]
  [u32s : (&mut u32s u32v.Vec)]
  [f64s : (&mut f64s f64v.Vec)]
  [f32s : (&mut f32s f32v.Vec)]
  [n : i64]) : unit
  (let
    [u64-slots (u64v.slots-mut u64s)]
    [u32-slots (u32v.slots-mut u32s)]
    [f64-slots (f64v.slots-mut f64s)]
    [f32-slots (f32v.slots-mut f32s)]
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! u64-slots i (cast (+ (* i 11) 7) : u64))
        (array-set! u32-slots i (cast (+ (* i 13) 9) : u32))
        (array-set! f64-slots i (math.f64-from-bits (f64-bits i)))
        (array-set! f32-slots i (math.f32-from-bits (f32-bits i)))
        (set! i (+ i 1))))))

(define (same
  [u64s : (& u64s u64v.Vec)]
  [out64 : (& out64 u64v.Vec)]
  [u32s : (& u32s u32v.Vec)]
  [out32 : (& out32 u32v.Vec)]
  [f64s : (& f64s f64v.Vec)]
  [outf64 : (& outf64 f64v.Vec)]
  [f32s : (& f32s f32v.Vec)]
  [outf32 : (& outf32 f32v.Vec)]
  [n : i64]) : bool
  (let
    [u64-slots (u64v.slots u64s)]
    [out64-slots (u64v.slots out64)]
    [u32-slots (u32v.slots u32s)]
    [out32-slots (u32v.slots out32)]
    [f64-slots (f64v.slots f64s)]
    [outf64-slots (f64v.slots outf64)]
    [f32-slots (f32v.slots f32s)]
    [outf32-slots (f32v.slots outf32)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (if (not (= (array-ref u64-slots i) (array-ref out64-slots i)))
            (set! ok false)
            unit)
          (if (not (= (array-ref u32-slots i) (array-ref out32-slots i)))
            (set! ok false)
            unit)
          (if (not
            (=
              (math.f64-to-bits (array-ref f64-slots i))
              (math.f64-to-bits (array-ref outf64-slots i))))
            (set! ok false)
            unit)
          (if (not
            (=
              (math.f32-to-bits (array-ref f32-slots i))
              (math.f32-to-bits (array-ref outf32-slots i))))
            (set! ok false)
            unit)
          (set! i (+ i 1))))
      ok)))

(define (main) : i64
  (let
    [n : i64 19]
    [u64s : u64v.Vec (u64z.make n)]
    [out64 : u64v.Vec (u64z.make n)]
    [u32s : u32v.Vec (u32z.make n)]
    [out32 : u32v.Vec (u32z.make n)]
    [f64s : f64v.Vec (f64z.make n)]
    [outf64 : f64v.Vec (f64z.make n)]
    [f32s : f32v.Vec (f32z.make n)]
    [outf32 : f32v.Vec (f32z.make n)]
    (begin
      (init (&mut u64s) (&mut u32s) (&mut f64s) (&mut f32s) n)
      (let
        [src (u64v.slots (& u64s))]
        [dst (u64v.slots-mut (&mut out64))]
        (foreach
          ([i : i64 0 n])
          (array-set! dst i (spmd-shuffle (array-ref src i) (program-index)))))
      (let
        [src (u32v.slots (& u32s))]
        [dst (u32v.slots-mut (&mut out32))]
        (foreach
          ([i : i64 0 n])
          (array-set! dst i (spmd-shuffle (array-ref src i) (program-index)))))
      (let
        [src (f64v.slots (& f64s))]
        [dst (f64v.slots-mut (&mut outf64))]
        (foreach
          ([i : i64 0 n])
          (array-set! dst i (spmd-shuffle (array-ref src i) (program-index)))))
      (let
        [src (f32v.slots (& f32s))]
        [dst (f32v.slots-mut (&mut outf32))]
        (foreach
          ([i : i64 0 n])
          (array-set! dst i (spmd-shuffle (array-ref src i) (program-index)))))
      (if (same
        (& u64s)
        (& out64)
        (& u32s)
        (& out32)
        (& f64s)
        (& outf64)
        (& f32s)
        (& outf32)
        n)
        42
        1))))
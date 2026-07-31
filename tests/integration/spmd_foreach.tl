(import stdlib.vector)
(import (vector.vector i64) as i64v)
(import (vector.vector i32) as i32v)
(import (vector.vector u64) as u64v)
(import (vector.vector u32) as u32v)
(import (vector.vector i16) as i16v)
(import (vector.vector u16) as u16v)
(import (vector.vector i8) as i8v)
(import (vector.vector u8) as u8v)
(import (vector.vector f64) as f64v)
(import (vector.vector f32) as f32v)
(import spmd_vec_support as spmdv)
(import (spmdv.zeroed i64 0) as i64z)
(import (spmdv.zeroed i32 (cast 0 : i32)) as i32z)
(import (spmdv.zeroed u64 (cast 0 : u64)) as u64z)
(import (spmdv.zeroed u32 (cast 0 : u32)) as u32z)
(import (spmdv.zeroed i16 (cast 0 : i16)) as i16z)
(import (spmdv.zeroed u16 (cast 0 : u16)) as u16z)
(import (spmdv.zeroed i8 (cast 0 : i8)) as i8z)
(import (spmdv.zeroed u8 (cast 0 : u8)) as u8z)
(import (spmdv.zeroed f64 (cast 0 : f64)) as f64z)
(import (spmdv.zeroed f32 (cast 0 : f32)) as f32z)

(define (init-i64 [a : (&mut a i64v.Vec)] [b : (&mut b i64v.Vec)] [n : i64]) : unit
  (let
    [a-slots (i64v.slots-mut a)]
    [b-slots (i64v.slots-mut b)]
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! a-slots i (+ i 1))
        (array-set! b-slots i (* i 2))
        (set! i (+ i 1))))))

(define (fill-i64-foreach
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
      (array-set!
        out-slots
        i
        (-
          (bit-or
            (+ (array-ref a-slots i) (array-ref b-slots i))
            (array-ref a-slots i))
          (bit-xor (array-ref b-slots i) 3))))))

(define (fill-i64-scalar
  [a : (& a i64v.Vec)]
  [b : (& b i64v.Vec)]
  [out : (&mut out i64v.Vec)]
  [n : i64]) : unit
  (let
    [a-slots (i64v.slots a)]
    [b-slots (i64v.slots b)]
    [out-slots (i64v.slots-mut out)]
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set!
          out-slots
          i
          (-
            (bit-or
              (+ (array-ref a-slots i) (array-ref b-slots i))
              (array-ref a-slots i))
            (bit-xor (array-ref b-slots i) 3)))
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

(define (case-i64 [n : i64]) : bool
  (let
    [a : i64v.Vec (i64z.make n)]
    [b : i64v.Vec (i64z.make n)]
    [got : i64v.Vec (i64z.make n)]
    [want : i64v.Vec (i64z.make n)]
    (begin
      (init-i64 (&mut a) (&mut b) n)
      (fill-i64-foreach (& a) (& b) (&mut got) n)
      (fill-i64-scalar (& a) (& b) (&mut want) n)
      (eq-i64 (& got) (& want) n))))

(define (init-i32 [a : (&mut a i32v.Vec)] [b : (&mut b i32v.Vec)] [n : i64]) : unit
  (let
    [a-slots (i32v.slots-mut a)]
    [b-slots (i32v.slots-mut b)]
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! a-slots i (cast (+ i 1) : i32))
        (array-set! b-slots i (cast (* i 2) : i32))
        (set! i (+ i 1))))))

(define (fill-i32-foreach
  [a : (& a i32v.Vec)]
  [b : (& b i32v.Vec)]
  [out : (&mut out i32v.Vec)]
  [n : i64]) : unit
  (let
    [a-slots (i32v.slots a)]
    [b-slots (i32v.slots b)]
    [out-slots (i32v.slots-mut out)]
    (foreach
      ([i : i64 0 n])
      (array-set!
        out-slots
        i
        (-
          (bit-or
            (+ (array-ref a-slots i) (array-ref b-slots i))
            (array-ref a-slots i))
          (bit-xor (array-ref b-slots i) 3))))))

(define (fill-i32-scalar
  [a : (& a i32v.Vec)]
  [b : (& b i32v.Vec)]
  [out : (&mut out i32v.Vec)]
  [n : i64]) : unit
  (let
    [a-slots (i32v.slots a)]
    [b-slots (i32v.slots b)]
    [out-slots (i32v.slots-mut out)]
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set!
          out-slots
          i
          (-
            (bit-or
              (+ (array-ref a-slots i) (array-ref b-slots i))
              (array-ref a-slots i))
            (bit-xor (array-ref b-slots i) 3)))
        (set! i (+ i 1))))))

(define (eq-i32 [a : (& a i32v.Vec)] [b : (& b i32v.Vec)] [n : i64]) : bool
  (let
    [a-slots (i32v.slots a)]
    [b-slots (i32v.slots b)]
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

(define (case-i32 [n : i64]) : bool
  (let
    [a : i32v.Vec (i32z.make n)]
    [b : i32v.Vec (i32z.make n)]
    [got : i32v.Vec (i32z.make n)]
    [want : i32v.Vec (i32z.make n)]
    (begin
      (init-i32 (&mut a) (&mut b) n)
      (fill-i32-foreach (& a) (& b) (&mut got) n)
      (fill-i32-scalar (& a) (& b) (&mut want) n)
      (eq-i32 (& got) (& want) n))))

(define (init-u64 [a : (&mut a u64v.Vec)] [b : (&mut b u64v.Vec)] [n : i64]) : unit
  (let
    [a-slots (u64v.slots-mut a)]
    [b-slots (u64v.slots-mut b)]
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! a-slots i (cast (+ (* i 17) 5) : u64))
        (array-set! b-slots i (cast (+ (* i 3) 11) : u64))
        (set! i (+ i 1))))))

(define (fill-u64-foreach
  [a : (& a u64v.Vec)]
  [b : (& b u64v.Vec)]
  [out : (&mut out u64v.Vec)]
  [n : i64]
  [factor : u64]) : unit
  (let
    [a-slots (u64v.slots a)]
    [b-slots (u64v.slots b)]
    [out-slots (u64v.slots-mut out)]
    (foreach
      ([i : i64 0 n])
      (array-set!
        out-slots
        i
        (-
          (bit-or
            (+
              (+ (array-ref a-slots i) (* (array-ref b-slots i) factor))
              (cast 7 : u64))
            (array-ref a-slots i))
          (bit-xor (array-ref b-slots i) (cast 3 : u64)))))))

(define (fill-u64-scalar
  [a : (& a u64v.Vec)]
  [b : (& b u64v.Vec)]
  [out : (&mut out u64v.Vec)]
  [n : i64]
  [factor : u64]) : unit
  (let
    [a-slots (u64v.slots a)]
    [b-slots (u64v.slots b)]
    [out-slots (u64v.slots-mut out)]
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set!
          out-slots
          i
          (-
            (bit-or
              (+
                (+ (array-ref a-slots i) (* (array-ref b-slots i) factor))
                (cast 7 : u64))
              (array-ref a-slots i))
            (bit-xor (array-ref b-slots i) (cast 3 : u64))))
        (set! i (+ i 1))))))

(define (eq-u64 [a : (& a u64v.Vec)] [b : (& b u64v.Vec)] [n : i64]) : bool
  (let
    [a-slots (u64v.slots a)]
    [b-slots (u64v.slots b)]
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

(define (case-u64 [n : i64]) : bool
  (let
    [a : u64v.Vec (u64z.make n)]
    [b : u64v.Vec (u64z.make n)]
    [got : u64v.Vec (u64z.make n)]
    [want : u64v.Vec (u64z.make n)]
    [factor : u64 (cast 13 : u64)]
    (begin
      (init-u64 (&mut a) (&mut b) n)
      (fill-u64-foreach (& a) (& b) (&mut got) n factor)
      (fill-u64-scalar (& a) (& b) (&mut want) n factor)
      (eq-u64 (& got) (& want) n))))

(define (init-u32 [a : (&mut a u32v.Vec)] [b : (&mut b u32v.Vec)] [n : i64]) : unit
  (let
    [a-slots (u32v.slots-mut a)]
    [b-slots (u32v.slots-mut b)]
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! a-slots i (cast (+ (* i 19) 7) : u32))
        (array-set! b-slots i (cast (+ (* i 5) 23) : u32))
        (set! i (+ i 1))))))

(define (fill-u32-foreach
  [a : (& a u32v.Vec)]
  [b : (& b u32v.Vec)]
  [out : (&mut out u32v.Vec)]
  [n : i64]
  [factor : u32]) : unit
  (let
    [a-slots (u32v.slots a)]
    [b-slots (u32v.slots b)]
    [out-slots (u32v.slots-mut out)]
    (foreach
      ([i : i64 0 n])
      (array-set!
        out-slots
        i
        (-
          (bit-or
            (+
              (+ (array-ref a-slots i) (* (array-ref b-slots i) factor))
              (cast 9 : u32))
            (array-ref a-slots i))
          (bit-xor (array-ref b-slots i) (cast 3 : u32)))))))

(define (fill-u32-scalar
  [a : (& a u32v.Vec)]
  [b : (& b u32v.Vec)]
  [out : (&mut out u32v.Vec)]
  [n : i64]
  [factor : u32]) : unit
  (let
    [a-slots (u32v.slots a)]
    [b-slots (u32v.slots b)]
    [out-slots (u32v.slots-mut out)]
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set!
          out-slots
          i
          (-
            (bit-or
              (+
                (+ (array-ref a-slots i) (* (array-ref b-slots i) factor))
                (cast 9 : u32))
              (array-ref a-slots i))
            (bit-xor (array-ref b-slots i) (cast 3 : u32))))
        (set! i (+ i 1))))))

(define (eq-u32 [a : (& a u32v.Vec)] [b : (& b u32v.Vec)] [n : i64]) : bool
  (let
    [a-slots (u32v.slots a)]
    [b-slots (u32v.slots b)]
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

(define (case-u32 [n : i64]) : bool
  (let
    [a : u32v.Vec (u32z.make n)]
    [b : u32v.Vec (u32z.make n)]
    [got : u32v.Vec (u32z.make n)]
    [want : u32v.Vec (u32z.make n)]
    [factor : u32 (cast 17 : u32)]
    (begin
      (init-u32 (&mut a) (&mut b) n)
      (fill-u32-foreach (& a) (& b) (&mut got) n factor)
      (fill-u32-scalar (& a) (& b) (&mut want) n factor)
      (eq-u32 (& got) (& want) n))))

(define (init-i8 [a : (&mut a i8v.Vec)] [b : (&mut b i8v.Vec)] [n : i64]) : unit
  (let
    [a-slots (i8v.slots-mut a)]
    [b-slots (i8v.slots-mut b)]
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! a-slots i (cast (+ i 1) : i8))
        (array-set! b-slots i (cast (+ (* i 2) 3) : i8))
        (set! i (+ i 1))))))

(define (fill-i8-foreach
  [a : (& a i8v.Vec)]
  [b : (& b i8v.Vec)]
  [out : (&mut out i8v.Vec)]
  [n : i64]) : unit
  (let
    [a-slots (i8v.slots a)]
    [b-slots (i8v.slots b)]
    [out-slots (i8v.slots-mut out)]
    (foreach
      ([i : i64 0 n])
      (array-set!
        out-slots
        i
        (-
          (bit-or
            (+ (array-ref a-slots i) (array-ref b-slots i))
            (array-ref a-slots i))
          (bit-xor (array-ref b-slots i) 3))))))

(define (fill-i8-scalar
  [a : (& a i8v.Vec)]
  [b : (& b i8v.Vec)]
  [out : (&mut out i8v.Vec)]
  [n : i64]) : unit
  (let
    [a-slots (i8v.slots a)]
    [b-slots (i8v.slots b)]
    [out-slots (i8v.slots-mut out)]
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set!
          out-slots
          i
          (-
            (bit-or
              (+ (array-ref a-slots i) (array-ref b-slots i))
              (array-ref a-slots i))
            (bit-xor (array-ref b-slots i) 3)))
        (set! i (+ i 1))))))

(define (eq-i8 [a : (& a i8v.Vec)] [b : (& b i8v.Vec)] [n : i64]) : bool
  (let
    [a-slots (i8v.slots a)]
    [b-slots (i8v.slots b)]
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

(define (case-i8 [n : i64]) : bool
  (let
    [a : i8v.Vec (i8z.make n)]
    [b : i8v.Vec (i8z.make n)]
    [got : i8v.Vec (i8z.make n)]
    [want : i8v.Vec (i8z.make n)]
    (begin
      (init-i8 (&mut a) (&mut b) n)
      (fill-i8-foreach (& a) (& b) (&mut got) n)
      (fill-i8-scalar (& a) (& b) (&mut want) n)
      (eq-i8 (& got) (& want) n))))

(define (init-u8 [a : (&mut a u8v.Vec)] [b : (&mut b u8v.Vec)] [n : i64]) : unit
  (let
    [a-slots (u8v.slots-mut a)]
    [b-slots (u8v.slots-mut b)]
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! a-slots i (cast (+ i 1) : u8))
        (array-set! b-slots i (cast (+ (* i 2) 3) : u8))
        (set! i (+ i 1))))))

(define (fill-u8-foreach
  [a : (& a u8v.Vec)]
  [b : (& b u8v.Vec)]
  [out : (&mut out u8v.Vec)]
  [n : i64]) : unit
  (let
    [a-slots (u8v.slots a)]
    [b-slots (u8v.slots b)]
    [out-slots (u8v.slots-mut out)]
    (foreach
      ([i : i64 0 n])
      (array-set!
        out-slots
        i
        (-
          (bit-or
            (+ (array-ref a-slots i) (array-ref b-slots i))
            (array-ref a-slots i))
          (bit-xor (array-ref b-slots i) 3))))))

(define (fill-u8-scalar
  [a : (& a u8v.Vec)]
  [b : (& b u8v.Vec)]
  [out : (&mut out u8v.Vec)]
  [n : i64]) : unit
  (let
    [a-slots (u8v.slots a)]
    [b-slots (u8v.slots b)]
    [out-slots (u8v.slots-mut out)]
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set!
          out-slots
          i
          (-
            (bit-or
              (+ (array-ref a-slots i) (array-ref b-slots i))
              (array-ref a-slots i))
            (bit-xor (array-ref b-slots i) 3)))
        (set! i (+ i 1))))))

(define (eq-u8 [a : (& a u8v.Vec)] [b : (& b u8v.Vec)] [n : i64]) : bool
  (let
    [a-slots (u8v.slots a)]
    [b-slots (u8v.slots b)]
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

(define (case-u8 [n : i64]) : bool
  (let
    [a : u8v.Vec (u8z.make n)]
    [b : u8v.Vec (u8z.make n)]
    [got : u8v.Vec (u8z.make n)]
    [want : u8v.Vec (u8z.make n)]
    (begin
      (init-u8 (&mut a) (&mut b) n)
      (fill-u8-foreach (& a) (& b) (&mut got) n)
      (fill-u8-scalar (& a) (& b) (&mut want) n)
      (eq-u8 (& got) (& want) n))))

(define (init-i16 [a : (&mut a i16v.Vec)] [b : (&mut b i16v.Vec)] [n : i64]) : unit
  (let
    [a-slots (i16v.slots-mut a)]
    [b-slots (i16v.slots-mut b)]
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! a-slots i (cast (+ (* i 257) 12000) : i16))
        (array-set! b-slots i (cast (+ (* i 13) 300) : i16))
        (set! i (+ i 1))))))

(define (fill-i16-foreach
  [a : (& a i16v.Vec)]
  [b : (& b i16v.Vec)]
  [out : (&mut out i16v.Vec)]
  [n : i64]
  [factor : i16]) : unit
  (let
    [a-slots (i16v.slots a)]
    [b-slots (i16v.slots b)]
    [out-slots (i16v.slots-mut out)]
    (foreach
      ([i : i64 0 n])
      (array-set!
        out-slots
        i
        (-
          (bit-or
            (+ (array-ref a-slots i) (* (array-ref b-slots i) factor))
            (array-ref a-slots i))
          (bit-xor (array-ref b-slots i) (cast 3 : i16)))))))

(define (fill-i16-scalar
  [a : (& a i16v.Vec)]
  [b : (& b i16v.Vec)]
  [out : (&mut out i16v.Vec)]
  [n : i64]
  [factor : i16]) : unit
  (let
    [a-slots (i16v.slots a)]
    [b-slots (i16v.slots b)]
    [out-slots (i16v.slots-mut out)]
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set!
          out-slots
          i
          (-
            (bit-or
              (+ (array-ref a-slots i) (* (array-ref b-slots i) factor))
              (array-ref a-slots i))
            (bit-xor (array-ref b-slots i) (cast 3 : i16))))
        (set! i (+ i 1))))))

(define (eq-i16 [a : (& a i16v.Vec)] [b : (& b i16v.Vec)] [n : i64]) : bool
  (let
    [a-slots (i16v.slots a)]
    [b-slots (i16v.slots b)]
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

(define (case-i16 [n : i64]) : bool
  (let
    [a : i16v.Vec (i16z.make n)]
    [b : i16v.Vec (i16z.make n)]
    [got : i16v.Vec (i16z.make n)]
    [want : i16v.Vec (i16z.make n)]
    [factor : i16 (cast 7 : i16)]
    (begin
      (init-i16 (&mut a) (&mut b) n)
      (fill-i16-foreach (& a) (& b) (&mut got) n factor)
      (fill-i16-scalar (& a) (& b) (&mut want) n factor)
      (eq-i16 (& got) (& want) n))))

(define (init-u16 [a : (&mut a u16v.Vec)] [b : (&mut b u16v.Vec)] [n : i64]) : unit
  (let
    [a-slots (u16v.slots-mut a)]
    [b-slots (u16v.slots-mut b)]
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! a-slots i (cast (+ (* i 257) 65000) : u16))
        (array-set! b-slots i (cast (+ (* i 37) 500) : u16))
        (set! i (+ i 1))))))

(define (fill-u16-foreach
  [a : (& a u16v.Vec)]
  [b : (& b u16v.Vec)]
  [out : (&mut out u16v.Vec)]
  [n : i64]
  [factor : u16]) : unit
  (let
    [a-slots (u16v.slots a)]
    [b-slots (u16v.slots b)]
    [out-slots (u16v.slots-mut out)]
    (foreach
      ([i : i64 0 n])
      (array-set!
        out-slots
        i
        (-
          (bit-or
            (+ (array-ref a-slots i) (* (array-ref b-slots i) factor))
            (array-ref a-slots i))
          (bit-xor (array-ref b-slots i) (cast 3 : u16)))))))

(define (fill-u16-scalar
  [a : (& a u16v.Vec)]
  [b : (& b u16v.Vec)]
  [out : (&mut out u16v.Vec)]
  [n : i64]
  [factor : u16]) : unit
  (let
    [a-slots (u16v.slots a)]
    [b-slots (u16v.slots b)]
    [out-slots (u16v.slots-mut out)]
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set!
          out-slots
          i
          (-
            (bit-or
              (+ (array-ref a-slots i) (* (array-ref b-slots i) factor))
              (array-ref a-slots i))
            (bit-xor (array-ref b-slots i) (cast 3 : u16))))
        (set! i (+ i 1))))))

(define (eq-u16 [a : (& a u16v.Vec)] [b : (& b u16v.Vec)] [n : i64]) : bool
  (let
    [a-slots (u16v.slots a)]
    [b-slots (u16v.slots b)]
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

(define (case-u16 [n : i64]) : bool
  (let
    [a : u16v.Vec (u16z.make n)]
    [b : u16v.Vec (u16z.make n)]
    [got : u16v.Vec (u16z.make n)]
    [want : u16v.Vec (u16z.make n)]
    [factor : u16 (cast 19 : u16)]
    (begin
      (init-u16 (&mut a) (&mut b) n)
      (fill-u16-foreach (& a) (& b) (&mut got) n factor)
      (fill-u16-scalar (& a) (& b) (&mut want) n factor)
      (eq-u16 (& got) (& want) n))))

(define (init-f64 [a : (&mut a f64v.Vec)] [b : (&mut b f64v.Vec)] [n : i64]) : unit
  (let
    [a-slots (f64v.slots-mut a)]
    [b-slots (f64v.slots-mut b)]
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! a-slots i 1.5)
        (array-set! b-slots i 2.25)
        (set! i (+ i 1))))))

(define (fill-f64-foreach
  [a : (& a f64v.Vec)]
  [b : (& b f64v.Vec)]
  [out : (&mut out f64v.Vec)]
  [n : i64]) : unit
  (let
    [a-slots (f64v.slots a)]
    [b-slots (f64v.slots b)]
    [out-slots (f64v.slots-mut out)]
    (foreach
      ([i : i64 0 n])
      (array-set!
        out-slots
        i
        (-
          (+ (array-ref a-slots i) (array-ref b-slots i))
          (array-ref b-slots i))))))

(define (fill-f64-scalar
  [a : (& a f64v.Vec)]
  [b : (& b f64v.Vec)]
  [out : (&mut out f64v.Vec)]
  [n : i64]) : unit
  (let
    [a-slots (f64v.slots a)]
    [b-slots (f64v.slots b)]
    [out-slots (f64v.slots-mut out)]
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set!
          out-slots
          i
          (-
            (+ (array-ref a-slots i) (array-ref b-slots i))
            (array-ref b-slots i)))
        (set! i (+ i 1))))))

(define (eq-f64 [a : (& a f64v.Vec)] [b : (& b f64v.Vec)] [n : i64]) : bool
  (let
    [a-slots (f64v.slots a)]
    [b-slots (f64v.slots b)]
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

(define (case-f64 [n : i64]) : bool
  (let
    [a : f64v.Vec (f64z.make n)]
    [b : f64v.Vec (f64z.make n)]
    [got : f64v.Vec (f64z.make n)]
    [want : f64v.Vec (f64z.make n)]
    (begin
      (init-f64 (&mut a) (&mut b) n)
      (fill-f64-foreach (& a) (& b) (&mut got) n)
      (fill-f64-scalar (& a) (& b) (&mut want) n)
      (eq-f64 (& got) (& want) n))))

(define (init-f32 [a : (&mut a f32v.Vec)] [b : (&mut b f32v.Vec)] [n : i64]) : unit
  (let
    [a-slots (f32v.slots-mut a)]
    [b-slots (f32v.slots-mut b)]
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! a-slots i 1.5)
        (array-set! b-slots i 2.25)
        (set! i (+ i 1))))))

(define (fill-f32-foreach
  [a : (& a f32v.Vec)]
  [b : (& b f32v.Vec)]
  [out : (&mut out f32v.Vec)]
  [n : i64]) : unit
  (let
    [a-slots (f32v.slots a)]
    [b-slots (f32v.slots b)]
    [out-slots (f32v.slots-mut out)]
    (foreach
      ([i : i64 0 n])
      (array-set!
        out-slots
        i
        (-
          (+ (array-ref a-slots i) (array-ref b-slots i))
          (array-ref b-slots i))))))

(define (fill-f32-scalar
  [a : (& a f32v.Vec)]
  [b : (& b f32v.Vec)]
  [out : (&mut out f32v.Vec)]
  [n : i64]) : unit
  (let
    [a-slots (f32v.slots a)]
    [b-slots (f32v.slots b)]
    [out-slots (f32v.slots-mut out)]
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set!
          out-slots
          i
          (-
            (+ (array-ref a-slots i) (array-ref b-slots i))
            (array-ref b-slots i)))
        (set! i (+ i 1))))))

(define (eq-f32 [a : (& a f32v.Vec)] [b : (& b f32v.Vec)] [n : i64]) : bool
  (let
    [a-slots (f32v.slots a)]
    [b-slots (f32v.slots b)]
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

(define (case-f32 [n : i64]) : bool
  (let
    [a : f32v.Vec (f32z.make n)]
    [b : f32v.Vec (f32z.make n)]
    [got : f32v.Vec (f32z.make n)]
    [want : f32v.Vec (f32z.make n)]
    (begin
      (init-f32 (&mut a) (&mut b) n)
      (fill-f32-foreach (& a) (& b) (&mut got) n)
      (fill-f32-scalar (& a) (& b) (&mut want) n)
      (eq-f32 (& got) (& want) n))))

(define (case-end-bound-evaluated-once) : bool
  (let
    [bounds : i64v.Vec (i64z.make 1)]
    [out : i64v.Vec (i64z.make 3)]
    (begin
      (i64v.set (&mut bounds) 0 3)
      (let
        [bound-slots (i64v.slots-mut (&mut bounds))]
        [out-slots (i64v.slots-mut (&mut out))]
        (foreach
          ([i : i64 0 (array-ref bound-slots 0)])
          (begin
            (array-set! bound-slots 0 0)
            (array-set! out-slots i (+ i 1)))))
      (= (i64v.get (& out) 2 0) 3))))

(define (case-index-binding-is-scoped) : bool
  (=
    (let
      [i : i64 7]
      (begin
        (foreach ([i : i64 0 3]) unit)
        i))
    7))

(define (all-cases) : bool
  (let
    [ok : bool true]
    (begin
      (if (case-i64 0)
        unit
        (set! ok false))
      (if (case-i64 3)
        unit
        (set! ok false))
      (if (case-i64 4)
        unit
        (set! ok false))
      (if (case-i64 9)
        unit
        (set! ok false))
      (if (case-i64 16)
        unit
        (set! ok false))
      (if (case-i64 17)
        unit
        (set! ok false))
      (if (case-i32 0)
        unit
        (set! ok false))
      (if (case-i32 3)
        unit
        (set! ok false))
      (if (case-i32 8)
        unit
        (set! ok false))
      (if (case-i32 9)
        unit
        (set! ok false))
      (if (case-i32 16)
        unit
        (set! ok false))
      (if (case-i32 17)
        unit
        (set! ok false))
      (if (case-u64 0)
        unit
        (set! ok false))
      (if (case-u64 3)
        unit
        (set! ok false))
      (if (case-u64 4)
        unit
        (set! ok false))
      (if (case-u64 8)
        unit
        (set! ok false))
      (if (case-u64 9)
        unit
        (set! ok false))
      (if (case-u64 17)
        unit
        (set! ok false))
      (if (case-u32 0)
        unit
        (set! ok false))
      (if (case-u32 3)
        unit
        (set! ok false))
      (if (case-u32 8)
        unit
        (set! ok false))
      (if (case-u32 9)
        unit
        (set! ok false))
      (if (case-u32 16)
        unit
        (set! ok false))
      (if (case-u32 17)
        unit
        (set! ok false))
      (if (case-i8 0)
        unit
        (set! ok false))
      (if (case-i8 3)
        unit
        (set! ok false))
      (if (case-i8 32)
        unit
        (set! ok false))
      (if (case-i8 33)
        unit
        (set! ok false))
      (if (case-i8 64)
        unit
        (set! ok false))
      (if (case-i8 65)
        unit
        (set! ok false))
      (if (case-u8 0)
        unit
        (set! ok false))
      (if (case-u8 3)
        unit
        (set! ok false))
      (if (case-u8 32)
        unit
        (set! ok false))
      (if (case-u8 33)
        unit
        (set! ok false))
      (if (case-u8 64)
        unit
        (set! ok false))
      (if (case-u8 65)
        unit
        (set! ok false))
      (if (case-i16 0)
        unit
        (set! ok false))
      (if (case-i16 3)
        unit
        (set! ok false))
      (if (case-i16 16)
        unit
        (set! ok false))
      (if (case-i16 17)
        unit
        (set! ok false))
      (if (case-i16 32)
        unit
        (set! ok false))
      (if (case-i16 33)
        unit
        (set! ok false))
      (if (case-u16 0)
        unit
        (set! ok false))
      (if (case-u16 3)
        unit
        (set! ok false))
      (if (case-u16 16)
        unit
        (set! ok false))
      (if (case-u16 17)
        unit
        (set! ok false))
      (if (case-u16 32)
        unit
        (set! ok false))
      (if (case-u16 33)
        unit
        (set! ok false))
      (if (case-f64 0)
        unit
        (set! ok false))
      (if (case-f64 3)
        unit
        (set! ok false))
      (if (case-f64 4)
        unit
        (set! ok false))
      (if (case-f64 9)
        unit
        (set! ok false))
      (if (case-f64 16)
        unit
        (set! ok false))
      (if (case-f64 17)
        unit
        (set! ok false))
      (if (case-f32 0)
        unit
        (set! ok false))
      (if (case-f32 3)
        unit
        (set! ok false))
      (if (case-f32 8)
        unit
        (set! ok false))
      (if (case-f32 9)
        unit
        (set! ok false))
      (if (case-f32 16)
        unit
        (set! ok false))
      (if (case-f32 17)
        unit
        (set! ok false))
      (if (case-end-bound-evaluated-once)
        unit
        (set! ok false))
      (if (case-index-binding-is-scoped)
        unit
        (set! ok false))
      ok)))

(define (main) : i64
  (if (all-cases)
    42
    1))
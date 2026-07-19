; All supported shuffle value classes. Float checks compare representations so
; signed zero and NaN payloads must survive the integer permute unchanged.
(import stdlib.array)
(import stdlib.math)

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
  [u64s : (Array u64)]
  [u32s : (Array u32)]
  [f64s : (Array f64)]
  [f32s : (Array f32)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! u64s i (cast (+ (* i 11) 7) : u64))
        (array-set! u32s i (cast (+ (* i 13) 9) : u32))
        (array-set! f64s i (math.f64-from-bits (f64-bits i)))
        (array-set! f32s i (math.f32-from-bits (f32-bits i)))
        (set! i (+ i 1))))))

(define (same
  [u64s : (Array u64)]
  [out64 : (Array u64)]
  [u32s : (Array u32)]
  [out32 : (Array u32)]
  [f64s : (Array f64)]
  [outf64 : (Array f64)]
  [f32s : (Array f32)]
  [outf32 : (Array f32)]
  [n : i64]) : bool
  (let
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (if (not (= (array-ref u64s i) (array-ref out64 i)))
            (set! ok false)
            unit)
          (if (not (= (array-ref u32s i) (array-ref out32 i)))
            (set! ok false)
            unit)
          (if (not
            (=
              (math.f64-to-bits (array-ref f64s i))
              (math.f64-to-bits (array-ref outf64 i))))
            (set! ok false)
            unit)
          (if (not
            (=
              (math.f32-to-bits (array-ref f32s i))
              (math.f32-to-bits (array-ref outf32 i))))
            (set! ok false)
            unit)
          (set! i (+ i 1))))
      ok)))

(define (main) : i64
  (let
    [n : i64 19]
    [u64s : (Array u64) (array.make-array u64 n)]
    [out64 : (Array u64) (array.make-array u64 n)]
    [u32s : (Array u32) (array.make-array u32 n)]
    [out32 : (Array u32) (array.make-array u32 n)]
    [f64s : (Array f64) (array.make-array f64 n)]
    [outf64 : (Array f64) (array.make-array f64 n)]
    [f32s : (Array f32) (array.make-array f32 n)]
    [outf32 : (Array f32) (array.make-array f32 n)]
    (begin
      (init u64s u32s f64s f32s n)
      (foreach
        ([i : i64 0 n])
        (array-set! out64 i (spmd-shuffle (array-ref u64s i) (program-index))))
      (foreach
        ([i : i64 0 n])
        (array-set! out32 i (spmd-shuffle (array-ref u32s i) (program-index))))
      (foreach
        ([i : i64 0 n])
        (array-set! outf64 i (spmd-shuffle (array-ref f64s i) (program-index))))
      (foreach
        ([i : i64 0 n])
        (array-set! outf32 i (spmd-shuffle (array-ref f32s i) (program-index))))
      (if (same u64s out64 u32s out32 f64s outf64 f32s outf32 n)
        42
        1))))
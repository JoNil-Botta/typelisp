;; Varying inputs remain live across clamp's ordinary uniform min/max calls.
;; Compare exact bits so NaN payloads and signed zero remain observable.
(import stdlib.math)

(define (min-f32 [a : f32] [b : f32]) : f32
  (if (< a b)
    a
    b))

(define (max-f32 [a : f32] [b : f32]) : f32
  (if (> a b)
    a
    b))

(define (clamp-f32 [value : f32] [a : f32] [b : f32] [take : bool]) : f32
  (let
    [lo : f32 (min-f32 a b)]
    [hi : f32 (max-f32 a b)]
    (if take
      (if (< value lo)
        lo
        (if (> value hi)
          hi
          value))
      (cast 17.0 : f32))))

(define (fill-f64
  [xs : (& xs (__tl_dyn-array f64))]
  [out : (&mut out (__tl_dyn-array f64))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (math.f64-clamp (array-ref xs i) -3.0 3.0))))

(define (fill-f32
  [xs : (& xs (__tl_dyn-array f32))]
  [out : (&mut out (__tl_dyn-array f32))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set!
      (array-ref out i)
      (clamp-f32
        (array-ref xs i)
        (cast -3.0 : f32)
        (cast 3.0 : f32)
        (!= (array-ref xs i) (cast -4.0 : f32))))))

(define (check-length [n : i64]) : bool
  (let
    [xs64 : (__tl_dyn-array f64) (__tl_make-array f64 n)]
    [out64 : (__tl_dyn-array f64) (__tl_make-array f64 n)]
    [xs32 : (__tl_dyn-array f32) (__tl_make-array f32 n)]
    [out32 : (__tl_dyn-array f32) (__tl_make-array f32 n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (set!
            (array-ref xs64 i)
            (if (= (% i 8) 0)
              (math.f64-from-bits 0x7ff8000000000155)
              (if (= (% i 8) 1)
                (math.f64-from-bits 0x8000000000000000)
                (cast (- (% i 13) 6) : f64))))
          (set!
            (array-ref xs32 i)
            (if (= (% i 8) 0)
              (math.f32-from-bits (cast 0x7fc00155 : u32))
              (if (= (% i 8) 1)
                (math.f32-from-bits (cast 0x80000000 : u32))
                (cast (- (% i 13) 6) : f32))))
          (set! (array-ref out32 i) (cast 17.0 : f32))
          (set! i (+ i 1))))
      (fill-f64 (& xs64) (&mut out64) n)
      (fill-f32 (& xs32) (&mut out32) n)
      (set! i 0)
      (while (< i n)
        (let
          [expected64 : f64 (math.f64-clamp (array-ref xs64 i) -3.0 3.0)]
          [expected32 : f32
            (if (= (array-ref xs32 i) (cast -4.0 : f32))
              (cast 17.0 : f32)
              (clamp-f32
                (array-ref xs32 i)
                (cast -3.0 : f32)
                (cast 3.0 : f32)
                true))]
          (begin
            (set!
              ok
              (and
                ok
                (=
                  (math.f64-to-bits (array-ref out64 i))
                  (math.f64-to-bits expected64))
                (=
                  (math.f32-to-bits (array-ref out32 i))
                  (math.f32-to-bits expected32))))
            (set! i (+ i 1)))))
      ok)))

(define (main) : i64
  (if (and
    (check-length 0)
    (check-length 1)
    (check-length 4)
    (check-length 8)
    (check-length 13)
    (check-length 32))
    42
    1))

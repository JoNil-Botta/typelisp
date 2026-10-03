;; Masked u32 -> f32 casts have no SIMD conversion yet (#7162). AVX2 and AVX-512
;; must reject the cast at its span rather than store the u32 lanes' bits as
;; f32 (#7306). The scalar run checks 19 lanes: full gangs and a masked tail,
;; each with active odd lanes and inactive even lanes that keep a sentinel.
(define (fill
  [src : (& src (__tl_dyn-array u32))]
  [out : (&mut out (__tl_dyn-array f32))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (> (array-ref src i) (cast 0 : u32))
      (set! (array-ref out i) (cast (array-ref src i) : f32))
      unit)))

(define (main) : i64
  (let
    [n : i64 19]
    [src : (__tl_dyn-array u32) (__tl_make-array u32 n)]
    [out : (__tl_dyn-array f32) (__tl_make-array f32 n)]
    [i : i64 0]
    [ok : bool true]
    (while (< i n)
      (set!
        (array-ref src i)
        (if (= (% i 2) 1)
          (cast i : u32)
          (cast 0 : u32)))
      (set! (array-ref out i) (cast 100 : f32))
      (set! i (+ i 1)))
    (fill (& src) (&mut out) n)
    (set! i 0)
    (while (< i n)
      (unless
        (=
          (array-ref out i)
          (if (= (% i 2) 1)
            (cast i : f32)
            (cast 100 : f32)))
        (set! ok false))
      (set! i (+ i 1)))
    (if ok
      42
      1)))
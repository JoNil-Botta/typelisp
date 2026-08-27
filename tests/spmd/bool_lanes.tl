
(define (init-bool
  [flags : (&mut flags (__tl_dyn-array bool))]
  [values : (&mut values (__tl_dyn-array i64))]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref flags i) (< i 5))
        (set! (array-ref values i) (- i 4))
        (set! i (+ i 1))))))

(define (init-i32 [values : (&mut values (__tl_dyn-array i32))] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref values i) (cast (- i 4) : i32))
        (set! i (+ i 1))))))

(define (init-i16 [values : (&mut values (__tl_dyn-array i16))] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref values i) (cast (- i 4) : i16))
        (set! i (+ i 1))))))

(define (init-i8 [values : (&mut values (__tl_dyn-array i8))] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref values i) (cast (- i 4) : i8))
        (set! i (+ i 1))))))

(define (fill-bool-copy-foreach
  [src : (& src (__tl_dyn-array bool))]
  [out : (&mut out (__tl_dyn-array bool))]
  [n : i64]) : unit
  (foreach ([i : i64 0 n]) (set! (array-ref out i) (array-ref src i))))

(define (fill-bool-copy-scalar
  [src : (& src (__tl_dyn-array bool))]
  [out : (&mut out (__tl_dyn-array bool))]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref out i) (array-ref src i))
        (set! i (+ i 1))))))

(define (fill-bool-compare-foreach
  [values : (& values (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array bool))]
  [n : i64]) : unit
  (foreach ([i : i64 0 n]) (set! (array-ref out i) (< (array-ref values i) 0))))

(define (fill-bool-compare-scalar
  [values : (& values (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array bool))]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref out i) (< (array-ref values i) 0))
        (set! i (+ i 1))))))

(define (fill-bool-compare-i32-foreach
  [values : (& values (__tl_dyn-array i32))]
  [out : (&mut out (__tl_dyn-array bool))]
  [n : i64]) : unit
  (foreach ([i : i64 0 n]) (set! (array-ref out i) (< (array-ref values i) 0))))

(define (fill-bool-compare-i32-scalar
  [values : (& values (__tl_dyn-array i32))]
  [out : (&mut out (__tl_dyn-array bool))]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref out i) (< (array-ref values i) 0))
        (set! i (+ i 1))))))

(define (fill-bool-compare-i16-foreach
  [values : (& values (__tl_dyn-array i16))]
  [out : (&mut out (__tl_dyn-array bool))]
  [n : i64]) : unit
  (foreach ([i : i64 0 n]) (set! (array-ref out i) (< (array-ref values i) 0))))

(define (fill-bool-compare-i16-scalar
  [values : (& values (__tl_dyn-array i16))]
  [out : (&mut out (__tl_dyn-array bool))]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref out i) (< (array-ref values i) 0))
        (set! i (+ i 1))))))

(define (fill-bool-compare-i8-foreach
  [values : (& values (__tl_dyn-array i8))]
  [out : (&mut out (__tl_dyn-array bool))]
  [n : i64]) : unit
  (foreach ([i : i64 0 n]) (set! (array-ref out i) (< (array-ref values i) 0))))

(define (fill-bool-compare-i8-scalar
  [values : (& values (__tl_dyn-array i8))]
  [out : (&mut out (__tl_dyn-array bool))]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref out i) (< (array-ref values i) 0))
        (set! i (+ i 1))))))

(define (eq-bool
  [a : (& a (__tl_dyn-array bool))]
  [b : (& b (__tl_dyn-array bool))]
  [n : i64]) : bool
  (let
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (if (array-ref a i)
            (if (array-ref b i)
              unit
              (set! ok false))
            (if (array-ref b i)
              (set! ok false)
              unit))
          (set! i (+ i 1))))
      ok)))

(define (case-bool [n : i64]) : bool
  (let
    [flags : (__tl_dyn-array bool) (__tl_make-array bool n)]
    [values : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [values32 : (__tl_dyn-array i32) (__tl_make-array i32 n)]
    [values16 : (__tl_dyn-array i16) (__tl_make-array i16 n)]
    [values8 : (__tl_dyn-array i8) (__tl_make-array i8 n)]
    [copy-got : (__tl_dyn-array bool) (__tl_make-array bool n)]
    [copy-want : (__tl_dyn-array bool) (__tl_make-array bool n)]
    [cmp-got : (__tl_dyn-array bool) (__tl_make-array bool n)]
    [cmp-want : (__tl_dyn-array bool) (__tl_make-array bool n)]
    [cmp32-got : (__tl_dyn-array bool) (__tl_make-array bool n)]
    [cmp32-want : (__tl_dyn-array bool) (__tl_make-array bool n)]
    [cmp16-got : (__tl_dyn-array bool) (__tl_make-array bool n)]
    [cmp16-want : (__tl_dyn-array bool) (__tl_make-array bool n)]
    [cmp8-got : (__tl_dyn-array bool) (__tl_make-array bool n)]
    [cmp8-want : (__tl_dyn-array bool) (__tl_make-array bool n)]
    (begin
      (init-bool (&mut flags) (&mut values) n)
      (init-i32 (&mut values32) n)
      (init-i16 (&mut values16) n)
      (init-i8 (&mut values8) n)
      (fill-bool-copy-foreach (& flags) (&mut copy-got) n)
      (fill-bool-copy-scalar (& flags) (&mut copy-want) n)
      (fill-bool-compare-foreach (& values) (&mut cmp-got) n)
      (fill-bool-compare-scalar (& values) (&mut cmp-want) n)
      (fill-bool-compare-i32-foreach (& values32) (&mut cmp32-got) n)
      (fill-bool-compare-i32-scalar (& values32) (&mut cmp32-want) n)
      (fill-bool-compare-i16-foreach (& values16) (&mut cmp16-got) n)
      (fill-bool-compare-i16-scalar (& values16) (&mut cmp16-want) n)
      (fill-bool-compare-i8-foreach (& values8) (&mut cmp8-got) n)
      (fill-bool-compare-i8-scalar (& values8) (&mut cmp8-want) n)
      (and
        (eq-bool (& copy-got) (& copy-want) n)
        (eq-bool (& cmp-got) (& cmp-want) n)
        (eq-bool (& cmp32-got) (& cmp32-want) n)
        (eq-bool (& cmp16-got) (& cmp16-want) n)
        (eq-bool (& cmp8-got) (& cmp8-want) n)))))

(define (all-cases) : bool
  (and
    (case-bool 0)
    (case-bool 3)
    (case-bool 8)
    (case-bool 9)
    (case-bool 64)
    (case-bool 65)))

(define (main) : i64
  (if (all-cases)
    42
    1))
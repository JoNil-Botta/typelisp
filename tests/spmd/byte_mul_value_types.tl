;; Packed i8/u8 multiplication corpus (#6684). The cases span sub-gang,
;; exact-gang, multi-gang, and tail lengths in AVX2 and AVX-512 modes. Scalar
;; reference loops cover the boundary bit patterns 00, 01, 7f, 80, and ff.
(define (i8-left [i : i64]) : i8
  (match (% i 8)
    [0 (cast 0 : i8)]
    [1 (cast 1 : i8)]
    [2 (cast 127 : i8)]
    [3 (cast -128 : i8)]
    [4 (cast -1 : i8)]
    [5 (cast 7 : i8)]
    [6 (cast -7 : i8)]
    [_ (cast 64 : i8)]))

(define (i8-right [i : i64]) : i8
  (match (% i 8)
    [0 (cast -1 : i8)]
    [1 (cast -128 : i8)]
    [2 (cast 2 : i8)]
    [3 (cast -1 : i8)]
    [4 (cast -1 : i8)]
    [5 (cast 19 : i8)]
    [6 (cast 36 : i8)]
    [_ (cast 4 : i8)]))

(define (i8-third [i : i64]) : i8
  (match (% i 5)
    [0 (cast 0 : i8)]
    [1 (cast -3 : i8)]
    [2 (cast 5 : i8)]
    [3 (cast 127 : i8)]
    [_ (cast -128 : i8)]))

(define (u8-left [i : i64]) : u8
  (match (% i 8)
    [0 (cast 0 : u8)]
    [1 (cast 1 : u8)]
    [2 (cast 127 : u8)]
    [3 (cast 128 : u8)]
    [4 (cast 255 : u8)]
    [5 (cast 7 : u8)]
    [6 (cast 249 : u8)]
    [_ (cast 64 : u8)]))

(define (u8-right [i : i64]) : u8
  (match (% i 8)
    [0 (cast 255 : u8)]
    [1 (cast 128 : u8)]
    [2 (cast 2 : u8)]
    [3 (cast 255 : u8)]
    [4 (cast 255 : u8)]
    [5 (cast 19 : u8)]
    [6 (cast 36 : u8)]
    [_ (cast 4 : u8)]))

(define (init
  [a : (__tl_dyn-array i8)]
  [b : (__tl_dyn-array i8)]
  [c : (__tl_dyn-array i8)]
  [ua : (__tl_dyn-array u8)]
  [ub : (__tl_dyn-array u8)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref a i) (i8-left i))
        (set! (array-ref b i) (i8-right i))
        (set! (array-ref c i) (i8-third i))
        (set! (array-ref ua i) (u8-left i))
        (set! (array-ref ub i) (u8-right i))
        (set! i (+ i 1))))))

(define (fill-i8
  [a : (__tl_dyn-array i8)]
  [b : (__tl_dyn-array i8)]
  [out : (__tl_dyn-array i8)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (* (array-ref a i) (array-ref b i)))))

(define (fill-i8-scalar
  [a : (__tl_dyn-array i8)]
  [b : (__tl_dyn-array i8)]
  [out : (__tl_dyn-array i8)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref out i) (* (array-ref a i) (array-ref b i)))
        (set! i (+ i 1))))))

(define (fill-u8
  [a : (__tl_dyn-array u8)]
  [b : (__tl_dyn-array u8)]
  [out : (__tl_dyn-array u8)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (* (array-ref a i) (array-ref b i)))))

(define (fill-u8-scalar
  [a : (__tl_dyn-array u8)]
  [b : (__tl_dyn-array u8)]
  [out : (__tl_dyn-array u8)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref out i) (* (array-ref a i) (array-ref b i)))
        (set! i (+ i 1))))))

(define (fill-masked
  [a : (__tl_dyn-array i8)]
  [b : (__tl_dyn-array i8)]
  [c : (__tl_dyn-array i8)]
  [if-out : (__tl_dyn-array i8)]
  [match-out : (__tl_dyn-array i8)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (begin
      (set!
        (array-ref if-out i)
        (if (< (array-ref a i) 0)
          (* (array-ref a i) (array-ref b i))
          (if (= (array-ref a i) 0)
            (* (array-ref b i) (array-ref c i))
            (* (array-ref c i) (array-ref a i)))))
      (set!
        (array-ref match-out i)
        (match (array-ref c i)
          [0 (* (array-ref a i) (array-ref b i))]
          [-3 (* (array-ref b i) (array-ref c i))]
          [5 (* (array-ref c i) (array-ref a i))]
          [_ (* (array-ref b i) (array-ref b i))])))))

(define (fill-masked-scalar
  [a : (__tl_dyn-array i8)]
  [b : (__tl_dyn-array i8)]
  [c : (__tl_dyn-array i8)]
  [if-out : (__tl_dyn-array i8)]
  [match-out : (__tl_dyn-array i8)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set!
          (array-ref if-out i)
          (if (< (array-ref a i) 0)
            (* (array-ref a i) (array-ref b i))
            (if (= (array-ref a i) 0)
              (* (array-ref b i) (array-ref c i))
              (* (array-ref c i) (array-ref a i)))))
        (set!
          (array-ref match-out i)
          (match (array-ref c i)
            [0 (* (array-ref a i) (array-ref b i))]
            [-3 (* (array-ref b i) (array-ref c i))]
            [5 (* (array-ref c i) (array-ref a i))]
            [_ (* (array-ref b i) (array-ref b i))]))
        (set! i (+ i 1))))))

(define (fill-masked-u8
  [a : (__tl_dyn-array u8)]
  [b : (__tl_dyn-array u8)]
  [if-out : (__tl_dyn-array u8)]
  [match-out : (__tl_dyn-array u8)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (begin
      (set!
        (array-ref if-out i)
        (if (< (array-ref a i) (cast 128 : u8))
          (* (array-ref a i) (array-ref b i))
          (if (= (array-ref a i) (cast 255 : u8))
            (* (array-ref b i) (array-ref b i))
            (* (array-ref a i) (array-ref a i)))))
      (set!
        (array-ref match-out i)
        (match (array-ref a i)
          [0 (* (array-ref a i) (array-ref b i))]
          [1 (* (array-ref b i) (array-ref b i))]
          [127 (* (array-ref a i) (array-ref a i))]
          [_ (* (array-ref b i) (array-ref a i))])))))

(define (fill-masked-u8-scalar
  [a : (__tl_dyn-array u8)]
  [b : (__tl_dyn-array u8)]
  [if-out : (__tl_dyn-array u8)]
  [match-out : (__tl_dyn-array u8)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set!
          (array-ref if-out i)
          (if (< (array-ref a i) (cast 128 : u8))
            (* (array-ref a i) (array-ref b i))
            (if (= (array-ref a i) (cast 255 : u8))
              (* (array-ref b i) (array-ref b i))
              (* (array-ref a i) (array-ref a i)))))
        (set!
          (array-ref match-out i)
          (match (array-ref a i)
            [0 (* (array-ref a i) (array-ref b i))]
            [1 (* (array-ref b i) (array-ref b i))]
            [127 (* (array-ref a i) (array-ref a i))]
            [_ (* (array-ref b i) (array-ref a i))]))
        (set! i (+ i 1))))))

(define (fill-while
  [factor : (__tl_dyn-array i8)]
  [remaining : (__tl_dyn-array i8)]
  [out : (__tl_dyn-array i8)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (while (> (array-ref remaining i) 0)
      (begin
        (set! (array-ref out i) (* (array-ref out i) (array-ref factor i)))
        (set! (array-ref remaining i) (+ (array-ref remaining i) -1))))))

(define (fill-while-scalar
  [factor : (__tl_dyn-array i8)]
  [remaining : (__tl_dyn-array i8)]
  [out : (__tl_dyn-array i8)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (while (> (array-ref remaining i) 0)
          (begin
            (set! (array-ref out i) (* (array-ref out i) (array-ref factor i)))
            (set! (array-ref remaining i) (+ (array-ref remaining i) -1))))
        (set! i (+ i 1))))))

(define (fill-while-u8
  [factor : (__tl_dyn-array u8)]
  [remaining : (__tl_dyn-array u8)]
  [out : (__tl_dyn-array u8)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (while (> (array-ref remaining i) (cast 0 : u8))
      (begin
        (set! (array-ref out i) (* (array-ref out i) (array-ref factor i)))
        (set!
          (array-ref remaining i)
          (+ (array-ref remaining i) (cast 255 : u8)))))))

(define (fill-while-u8-scalar
  [factor : (__tl_dyn-array u8)]
  [remaining : (__tl_dyn-array u8)]
  [out : (__tl_dyn-array u8)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (while (> (array-ref remaining i) (cast 0 : u8))
          (begin
            (set! (array-ref out i) (* (array-ref out i) (array-ref factor i)))
            (set!
              (array-ref remaining i)
              (+ (array-ref remaining i) (cast 255 : u8)))))
        (set! i (+ i 1))))))

(define (arrays-eq-i8
  [a : (__tl_dyn-array i8)]
  [b : (__tl_dyn-array i8)]
  [n : i64]) : bool
  (let
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (if (!= (array-ref a i) (array-ref b i))
            (set! ok false)
            unit)
          (set! i (+ i 1))))
      ok)))

(define (arrays-eq-u8
  [a : (__tl_dyn-array u8)]
  [b : (__tl_dyn-array u8)]
  [n : i64]) : bool
  (let
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (if (!= (array-ref a i) (array-ref b i))
            (set! ok false)
            unit)
          (set! i (+ i 1))))
      ok)))

(define (run-case [n : i64]) : bool
  (let
    [a : (__tl_dyn-array i8) (__tl_make-array i8 n)]
    [b : (__tl_dyn-array i8) (__tl_make-array i8 n)]
    [c : (__tl_dyn-array i8) (__tl_make-array i8 n)]
    [ua : (__tl_dyn-array u8) (__tl_make-array u8 n)]
    [ub : (__tl_dyn-array u8) (__tl_make-array u8 n)]
    [i8-got : (__tl_dyn-array i8) (__tl_make-array i8 n)]
    [i8-want : (__tl_dyn-array i8) (__tl_make-array i8 n)]
    [u8-got : (__tl_dyn-array u8) (__tl_make-array u8 n)]
    [u8-want : (__tl_dyn-array u8) (__tl_make-array u8 n)]
    [if-got : (__tl_dyn-array i8) (__tl_make-array i8 n)]
    [if-want : (__tl_dyn-array i8) (__tl_make-array i8 n)]
    [match-got : (__tl_dyn-array i8) (__tl_make-array i8 n)]
    [match-want : (__tl_dyn-array i8) (__tl_make-array i8 n)]
    [u8-if-got : (__tl_dyn-array u8) (__tl_make-array u8 n)]
    [u8-if-want : (__tl_dyn-array u8) (__tl_make-array u8 n)]
    [u8-match-got : (__tl_dyn-array u8) (__tl_make-array u8 n)]
    [u8-match-want : (__tl_dyn-array u8) (__tl_make-array u8 n)]
    [remaining : (__tl_dyn-array i8) (__tl_make-array i8 n)]
    [remaining-want : (__tl_dyn-array i8) (__tl_make-array i8 n)]
    [while-got : (__tl_dyn-array i8) (__tl_make-array i8 n)]
    [while-want : (__tl_dyn-array i8) (__tl_make-array i8 n)]
    [u8-remaining : (__tl_dyn-array u8) (__tl_make-array u8 n)]
    [u8-remaining-want : (__tl_dyn-array u8) (__tl_make-array u8 n)]
    [u8-while-got : (__tl_dyn-array u8) (__tl_make-array u8 n)]
    [u8-while-want : (__tl_dyn-array u8) (__tl_make-array u8 n)]
    [i : i64 0]
    (begin
      (init a b c ua ub n)
      (while (< i n)
        (begin
          (set! (array-ref remaining i) (cast (% i 4) : i8))
          (set! (array-ref remaining-want i) (cast (% i 4) : i8))
          (set! (array-ref while-got i) (cast 1 : i8))
          (set! (array-ref while-want i) (cast 1 : i8))
          (set! (array-ref u8-remaining i) (cast (% i 4) : u8))
          (set! (array-ref u8-remaining-want i) (cast (% i 4) : u8))
          (set! (array-ref u8-while-got i) (cast 1 : u8))
          (set! (array-ref u8-while-want i) (cast 1 : u8))
          (set! i (+ i 1))))
      (fill-i8 a b i8-got n)
      (fill-i8-scalar a b i8-want n)
      (fill-u8 ua ub u8-got n)
      (fill-u8-scalar ua ub u8-want n)
      (fill-masked a b c if-got match-got n)
      (fill-masked-scalar a b c if-want match-want n)
      (fill-masked-u8 ua ub u8-if-got u8-match-got n)
      (fill-masked-u8-scalar ua ub u8-if-want u8-match-want n)
      (fill-while a remaining while-got n)
      (fill-while-scalar a remaining-want while-want n)
      (fill-while-u8 ua u8-remaining u8-while-got n)
      (fill-while-u8-scalar ua u8-remaining-want u8-while-want n)
      (and
        (arrays-eq-i8 i8-got i8-want n)
        (arrays-eq-u8 u8-got u8-want n)
        (arrays-eq-i8 if-got if-want n)
        (arrays-eq-i8 match-got match-want n)
        (arrays-eq-u8 u8-if-got u8-if-want n)
        (arrays-eq-u8 u8-match-got u8-match-want n)
        (arrays-eq-i8 while-got while-want n)
        (arrays-eq-u8 u8-while-got u8-while-want n)))))

(define (main) : i64
  (begin
    (unless (run-case 17) (return 1))
    (unless (run-case 32) (return 2))
    (unless (run-case 64) (return 3))
    (unless (run-case 130) (return 4))
    42))
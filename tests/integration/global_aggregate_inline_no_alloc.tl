;; Every memory-class aggregate global is stored inline in its own static cell,
;; and its runtime initializer writes the value there through the leading
;; hidden result pointer (#7905): neither startup nor any later read or write of
;; such a global allocates. `alloc-before` and `alloc-after` are initialized
;; before and after every aggregate global (globals initialize in source order),
;; so equal totals mean the aggregate initializers allocated nothing. `main`
;; yields 42 only if every value is intact and every window is zero bytes.
(import stdlib.iterator)
(import stdlib.profile)

(defstruct S24
  (a i64)
  (b i64)
  (c i64))

(defstruct S64
  (w0 i64)
  (w1 i64)
  (w2 i64)
  (w3 i64)
  (w4 i64)
  (w5 i64)
  (w6 i64)
  (w7 i64))

(defstruct S72
  (head S64)
  (tail i64))

(defstruct Bytes3
  (x u8)
  (y u8)
  (z u8))

(defenum Shape
  (Rect i64 i64)
  (Dot i64)
  (Nothing))

(define (seed [x : i64]) : i64
  (+ x 0))

(define alloc-before : i64
  (profile.alloc-total))
(define g24 : S24
  (S24 (seed 1) 2 3))
(define g64 : S64
  (S64 (seed 1) 2 3 4 5 6 7 8))
(define g72 : S72
  (S72 (S64 (seed 10) 11 12 13 14 15 16 17) 18))
(define g416 : (Array i64 52)
  (make-array i64 52))
(define g-array : (Array i64 5)
  (array (seed 5) 6 7 8 9))
(define g-empty : (Array i64 0)
  (make-array i64 0))
(define g3 : Bytes3
  (Bytes3 (cast (seed 1) : u8) 2 3))
(define g-shape : Shape
  (Rect (seed 6) 7))
(define g-tuple : (Tuple i64 i64 i64)
  (tuple (seed 100) 200 300))

;; Reads another inline global while it initializes: the cell it reads is
;; already complete because globals initialize in source order.
(define g-copy : S24
  (S24 (+ g24.a 10) (+ g24.b 10) (+ g24.c 10)))
(define alloc-after : i64
  (profile.alloc-total))

(define (shape-sum [s : (& Shape)]) : i64
  (match s
    [(Rect w h) (+ w h)]
    [(Dot r) r]
    [(Nothing) 0]))

(define (check-initial) : i64
  (unless (= alloc-after alloc-before) (return 1))
  (unless (= (+ g24.a (+ g24.b g24.c)) 6) (return 2))
  (unless (= (+ g64.w0 g64.w7) 9) (return 3))
  (unless (= (+ g72.head.w0 (+ g72.head.w7 g72.tail)) 45) (return 4))
  (unless (= (length g416) 52) (return 5))
  (unless (= (array-ref g416 51) 0) (return 6))
  (unless (= (+ (array-ref g-array 0) (array-ref g-array 4)) 14) (return 7))
  (unless (= (length g-empty) 0) (return 8))
  (unless (= (+ (cast g3.x : i64) (cast g3.z : i64)) 4) (return 9))
  (unless (= (shape-sum (& g-shape)) 13) (return 10))
  (unless (= (tuple-ref g-tuple 2) 300) (return 11))
  (unless (= (+ g-copy.a g-copy.c) 24) (return 12))
  0)

(define (check-writes) : i64
  (let
    [before : i64 (profile.alloc-total)]
    (set! g24 (S24 (seed 4) 5 6))
    (set! g24.b 50)
    (set! g72.head.w3 (seed 30))
    (set! g72.tail 31)
    (set! (array-ref g416 51) (seed 7))
    (set! (array-ref g-array 2) 70)
    (set! g3.y (cast (seed 9) : u8))
    (set! g-shape (Dot (seed 21)))
    (set! g-tuple (tuple 1 2 (seed 3)))
    (set! g64 (S64 g72.tail 0 0 0 0 0 0 g72.head.w3))
    (let
      [after : i64 (profile.alloc-total)]
      (unless (= after before) (return 20))
      (unless (= (+ g24.a (+ g24.b g24.c)) 60) (return 21))
      (unless (= (+ g72.head.w3 g72.tail) 61) (return 22))
      (unless (= (array-ref g416 51) 7) (return 23))
      (unless (= (array-ref g-array 2) 70) (return 24))
      (unless (= (cast g3.y : i64) 9) (return 25))
      (unless (= (shape-sum (& g-shape)) 21) (return 26))
      (unless (= (tuple-ref g-tuple 2) 3) (return 27))
      (unless (= (+ g64.w0 g64.w7) 61) (return 28))
      0)))

;; Ten thousand whole and field updates of inline globals in a loop.
(define (check-loop) : i64
  (let
    [before : i64 (profile.alloc-total)]
    (for [i (iterator.range 0 10000)]
      (set! g24 (S24 i (+ g24.b 1) g24.a))
      (set! g72.tail (+ g72.tail 1))
      (set! (array-ref g416 (% i 52)) (+ (array-ref g416 (% i 52)) 1)))
    (let
      [after : i64 (profile.alloc-total)]
      (unless (= after before) (return 30))
      (unless (= g24.a 9999) (return 31))
      (unless (= g24.b 10050) (return 32))
      (unless (= g24.c 9998) (return 33))
      (unless (= g72.tail 10031) (return 34))
      (unless (= (array-ref g416 0) 193) (return 35))
      0)))

(define (main) : i64
  (let
    [initial : i64 (check-initial)]
    (unless (= initial 0) (return initial))
    (let
      [writes : i64 (check-writes)]
      (unless (= writes 0) (return writes))
      (let
        [looped : i64 (check-loop)]
        (if (= looped 0)
          42
          looped)))))
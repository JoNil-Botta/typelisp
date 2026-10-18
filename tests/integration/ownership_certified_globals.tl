(import global_reference_initializer_dep as dep)

(extern external (:symbol "tl_certified_global_integer") : i64)
(extern fraction (:symbol "tl_certified_global_float") : f32)
(extern callback (:symbol "tl_certified_global_callback") : (CFunc
  non-null
  (-> i64 i64)))

(define value : i64
  41)
(define narrow : u8
  255)
(define ratio : f32
  42.75)
(define flag : bool
  true)

(define (inc [x : i64]) : i64
  (+ x 1))

(define (dec [x : i64]) : i64
  (- x 1))

(define saved : (-> i64 i64)
  inc)

(define (change) : unit
  (set! value 99))

(define (replace-saved) : unit
  (set! saved dec))

(define (first [x : i64] [_later : unit]) : i64
  x)

(define (snapshot) : i64
  (first value (change)))

(define (callee-snapshot) : i64
  (saved
    (begin
      (replace-saved)
      41)))

(define (imported) : i64
  (+ dep.answer 28))

(define (shadowed) : i64
  (let
    [value : i64 17]
    (+ value 25)))

(define (main) : i64
  (let
    [before : i64 (snapshot)]
    [called : i64 (callee-snapshot)]
    [ffi : i64 (callback external)]
    [foreign-float : i64 (cast fraction : i64)]
    [imported-before : i64 (imported)]
    [_changed : unit (dep.set-answer! 20)]
    (if (and
      (= before 41)
      (= value 99)
      (= called 42)
      (= (saved 41) 40)
      (= ffi 42)
      (= foreign-float 42)
      (= (cast narrow : i64) 255)
      (= (cast ratio : i64) 42)
      flag
      (= imported-before 42)
      (= (imported) 48)
      (= (shadowed) 42))
      42
      1)))
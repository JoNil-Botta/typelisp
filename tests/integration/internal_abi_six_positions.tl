(import stdlib.io)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.runtime)

(extern (c-exports) : i64 (:symbol "tl_abi_c_exports"))
(extern (c-concat5
  [a : (Ptr u8)]
  [a-len : i64]
  [b : (Ptr u8)]
  [b-len : i64]
  [c : (Ptr u8)]
  [c-len : i64]
  [d : (Ptr u8)]
  [d-len : i64]
  [e : (Ptr u8)]
  [e-len : i64]) : String (:symbol "tl_abi_c_concat5"))
(extern (raw-concat5
  [a : (Ptr u8)]
  [a-len : i64]
  [b : (Ptr u8)]
  [b-len : i64]
  [c : (Ptr u8)]
  [c-len : i64]
  [d : (Ptr u8)]
  [d-len : i64]
  [e : (Ptr u8)]
  [e-len : i64]) : String (:symbol "tl_string_concat5"))
(extern (c-preserved) : i64 (:symbol "tl_abi_c_preserved"))
(extern (c-touch [value : i64]) : i64 (:symbol "tl_abi_c_touch"))
(extern (c-entry) : i64 (:symbol "tl_abi_c_entry"))
(extern (c-macro) : i64 (:symbol "tl_abi_c_macro"))
(extern (c-thread [callback : (-> i64 i64)]) : i64 (:symbol "tl_abi_c_thread"))
(extern (call-macro
  [entry : i64]
  [image : i64]
  [host : i64]
  [session : i64]
  [operands : i64]
  [count : i64]
  [result : i64]) : i64 (:symbol "tl_tlci_call_macro_entry"))

(define (four [a : i64] [b : f64] [c : i64] [d : f64])
  (:export-symbol "tl_abi_four") : i64
  (+ a (cast b : i64) c (cast d : i64)))

(define (five [a : i64] [b : i64] [c : i64] [d : i64] [e : i64])
  (:export-symbol "tl_abi_five") : i64
  (+ a b c d e))

(define (six [a : i64] [b : i64] [c : i64] [d : i64] [e : f64] [f : f32])
  (:export-symbol "tl_abi_six") : i64
  (+ a b c d (cast e : i64) (cast f : i64)))

(define (seven
  [a : i64]
  [b : f64]
  [c : i64]
  [d : f32]
  [e : i64]
  [f : f64]
  [g : i64]) : i64
  (+ a (cast b : i64) c (cast d : i64) e (cast f : i64) g))

(define (eight
  [a : i64]
  [b : f64]
  [c : i64]
  [d : f32]
  [e : f64]
  [f : i64]
  [g : i64]
  [h : f64])
  (:export-symbol "tl_abi_eight") : i64
  (+ a (cast b : i64) c (cast d : i64) (cast e : i64) f g (cast h : i64)))

;; The hidden result pointer consumes position zero before the explicit words.
(define (wide [a : i64] [b : i64] [c : i64] [d : i64] [e : i64] [f : i64]) : (Tuple
    i64
    i64
    i64)
  (tuple (+ a d) (+ b e) (+ c f)))

;; A Slice occupies positions four and five, across the Platform register limit.
(define (slice-six
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [items : (& items (Slice i64))]) : i64
  (+ a b c d (array-ref items 0) (array-ref items 1) (array-length items)))

(define (macro-target
  [_image-context : i64]
  [host : i64]
  [session : i64]
  [operands : i64]
  [count : i64]
  [result : i64])
  (:export-symbol "tl_abi_macro") : i64
  (+ host session operands count result))

;; The Slice straddles the final Internal register and first stack word.
(define (slice-seven
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [items : (& items (Slice i64))]) : i64
  (+ a b c d e (array-ref items 0) (array-ref items 1) (array-length items)))

(define (thread-target [value : i64]) : i64
  (+ value 7))

;; Live scalar values cross a C call and an Internal call under register pressure.
(define (pressure [x : i64]) : i64
  (let
    [a (+ x 1)]
    [b (+ x 2)]
    [c (+ x 3)]
    [d (+ x 4)]
    [e (+ x 5)]
    [f (+ x 6)]
    [g (+ x 7)]
    [h (+ x 8)]
    [i (+ x 9)]
    [j (+ x 10)]
    [k (+ x 11)]
    [l (+ x 12)]
    [t (c-touch x)]
    [u (five t a b c d)]
    (+ u a b c d e f g h i j k l)))

(define (main) : i64
  (let
    [x : i64 (io.arg-count)]
    [pair : (Tuple i64 i64 i64) (wide 1 2 3 4 5 6)]
    [items : (Array i64 2) (array 5 6)]
    [atomic-cell : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [atomic-old : i64 0]
    [atomic-loaded : i64 0]
    [closure : (-> i64 i64 i64 i64 i64 i64)
      (lambda ([a : i64] [b : i64] [c : i64] [d : i64] [e : i64]) : i64
        (+ x a b c d e))]
    ;; Keep the helpers reachable for both the direct intrinsic and raw C paths.
    (unsafe
      (let
        [ptr : (MutPtr i64) (__tl_array-data atomic-cell)]
        (set! atomic-old (runtime.atomic-i64-cas-ptr! ptr 0 42))
        (set!
          atomic-loaded
          (runtime.atomic-i64-load-ptr (ptr-cast ptr : (Ptr i64))))))
    (if (and
      (= atomic-old 0)
      (= atomic-loaded 42)
      (= (four x 2.0 3 4.0) (+ x 9))
      (= (five x 2 3 4 5) (+ x 14))
      (= (six x 2 3 4 5.0 (cast 6.0 : f32)) (+ x 20))
      (= (seven x 2.0 3 (cast 4.0 : f32) 5 6.0 7) (+ x 27))
      (= (eight x 2.0 3 (cast 4.0 : f32) 5.0 6 7 8.0) (+ x 35))
      (= (tuple-ref pair 0) 5)
      (= (tuple-ref pair 1) 7)
      (= (tuple-ref pair 2) 9)
      (= (slice-six 1 2 3 4 (& items)) 23)
      (= (slice-seven 1 2 3 4 5 (& items)) 28)
      (= (closure 1 2 3 4 5) (+ x 15))
      (= (pressure x) (+ (* 17 x) 89))
      (= (c-exports) 1)
      (string.eq
        (unsafe
          (c-concat5
            (string-data "a")
            1
            (string-data "b")
            1
            (string-data "c")
            1
            (string-data "d")
            1
            (string-data "e")
            1))
        "abcde")
      (string.eq
        (unsafe
          (raw-concat5
            (string-data "a")
            1
            (string-data "b")
            1
            (string-data "c")
            1
            (string-data "d")
            1
            (string-data "e")
            1))
        "abcde")
      (string.eq (str_cat.str-cat "a" "b" "c" "d" "e") "abcde")
      (= (call-macro (c-entry) 11 12 13 14 15 16) 70)
      (= (macro-target 11 12 13 14 15 16) 70)
      (= (c-macro) 1)
      (= (c-thread thread-target) 1)
      (= (c-preserved) 1))
      42
      1)))
;: A builtin reads an array element (or a temporary's part) by lending it.
(defstruct Pair
  (left (__tl_dyn-array i64))
  (right i64))

(define (make) : Pair
  (Pair (__tl_make-array i64 3) 4))

(define (names-len [names : (__tl_dyn-array String)] [i : i64]) : i64
  (+
    (__tl_string_length (array-ref names i))
    (__tl_string_length (array-ref names i))))

(define (temp-len) : i64
  (array-length (make).left))

(define (nested-len [rows : (__tl_dyn-array (__tl_dyn-array i64))]) : i64
  (array-length (array-ref rows 0)))

(define (main) : i64
  (let
    [names : (__tl_dyn-array String) (__tl_make-array String 1)]
    [rows : (__tl_dyn-array (__tl_dyn-array i64))
      (__tl_make-array (__tl_dyn-array i64) 1)]
    (begin
      (set! (array-ref names 0) "abcdefghijklmnopq")
      (set! (array-ref rows 0) (__tl_make-array i64 4))
      (+ (names-len names 0) (temp-len) (nested-len rows) 1))))
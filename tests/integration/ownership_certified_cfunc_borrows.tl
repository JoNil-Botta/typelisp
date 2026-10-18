(import stdlib.string)

(extern (first) : (CFunc non-null (-> String i64)) (:symbol "tl_cfunc_borrow_first"))
(extern (second) : (CFunc non-null (-> String i64)) (:symbol "tl_cfunc_borrow_second"))
(extern (calls) : i64 (:symbol "tl_cfunc_borrow_calls"))

(define (repeat [callback : (CFunc non-null (-> String i64))] [text : String]) : i64
  (let
    [a : i64 (callback text)]
    [b : i64 (callback text)]
    (if (and (= a 42) (= b 42) (string.eq text "answer"))
      42
      1)))

(defstruct Big
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(define global : Big
  (Big 1 2 3 4))

(define (rebind! [_text : String]) : i64
  (set! global (Big 5 6 7 8))
  42)

(define (read-through
  [r : (& r Big)]
  [callback : (CFunc non-null (-> String i64))]) : i64
  (callback "answer")
  r.a)

(define (main) : i64
  (let
    [text "answer"]
    [callback (first)]
    [captured : i64
      (callback
        (begin
          (set! callback (second))
          text))]
    [later : i64 (callback text)]
    [repeated : i64 (repeat (first) "answer")]
    [shared : i64 (read-through (& global) (first))]
    (if (and
      (= captured 42)
      (= later 1)
      (= repeated 42)
      (= shared 1)
      (= (calls) 5)
      (string.eq text "answer"))
      42
      1)))
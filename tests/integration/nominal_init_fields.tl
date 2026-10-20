(import nominal_init_dep as dep)

(defstruct Empty
  (value unit))

(defstruct Small
  (number i64))

(defstruct Pair
  (number i64)
  (flag bool))

(defstruct Wide
  (a i64)
  (b i64)
  (c i64))

(defenum Tag
  (Zero)
  (Other i64))

(defstruct Bundle
  (text String)
  (items (__tl_dyn-array i64))
  (cell (Box i64))
  (pair (Tuple i64 bool))
  (fixed (Array i64 2))
  (empty (Array i64 0))
  (tag Tag)
  (imported dep.Holder))

(defenum BundleChoice
  (BundleFirst Bundle)
  (BundleLast))

(define (small) : Small
  (init))

(define (bundle-zero? [value : (& value Bundle)]) : bool
  (and
    (= (__tl_string_length value.text) 0)
    (= (array-length value.items) 0)
    (= (deref value.cell) 0)
    (= (tuple-ref value.pair 0) 0)
    (not (tuple-ref value.pair 1))
    (= (array-ref value.fixed 1) 0)
    (= (array-length value.empty) 0)
    (match value.tag
      [(Zero) true]
      [_ false])
    (= value.imported.field.number 0)
    (= (__tl_string_length value.imported.field.text) 0)
    (match value.imported.choice
      [(dep.First field)
        (and (= field.number 0) (= (__tl_string_length field.text) 0))]
      [_ false])))

(define (main) : i64
  (let
    [empties : (__tl_dyn-array Empty) (__tl_make-array Empty 2)]
    [none : (__tl_dyn-array Bundle) (__tl_make-array Bundle 0)]
    [pairs : (__tl_dyn-array Pair) (__tl_make-array Pair 2)]
    [wide : Wide (Wide 3 4 5)]
    [values : (__tl_dyn-array Bundle) (__tl_make-array Bundle 2)]
    [choice : BundleChoice (init)]
    [ok : bool
      (and
        (= (array-length empties) 2)
        (= (array-length none) 0)
        (= (small).number 0)
        (= (array-ref pairs 1).number 0)
        (not (array-ref pairs 1).flag)
        (bundle-zero? (& (array-ref values 0)))
        (bundle-zero? (& (array-ref values 1))))]
    (set! wide (init))
    (set! choice (init))
    (set! (deref (array-ref values 0).cell) 17)
    (__tl_array-push! (array-ref values 0).items 23)
    (if (and
      ok
      (= wide.a 0)
      (= wide.b 0)
      (= wide.c 0)
      (= (deref (array-ref values 0).cell) 17)
      (= (array-ref (array-ref values 0).items 0) 23)
      (bundle-zero? (& (array-ref values 1)))
      (match choice
        [(BundleFirst value) (bundle-zero? (& value))]
        [_ false]))
      42
      1)))
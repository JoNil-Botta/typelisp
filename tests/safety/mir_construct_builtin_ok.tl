;: Constructors move their operands into a fresh value; read-only builtins
;: borrow their operands, so the operands stay usable afterwards.
(import stdlib.string)

(defstruct Holder
  (items (__tl_dyn-array i64))
  (count i64))

(defenum Shape
  (Sized (__tl_dyn-array i64) i64)
  (Empty))

(define (total [h : Holder]) : i64
  (+ h.count (array-length h.items)))

(define (shape-size [s : Shape]) : i64
  (match s
    [(Shape.Sized items n) (+ n (array-length items))]
    [Shape.Empty 0]))

(define (names-equal [a : String] [b : String]) : bool
  (and (string.eq a b) (= (string.string-length a) (string.string-length b))))

(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    [more : (__tl_dyn-array i64) (__tl_make-array i64 3)]
    [len : i64 (array-length items)]
    [h : Holder (Holder items 30)]
    [s : Shape (Shape.Sized more 4)]
    (+
      (total h)
      (shape-size s)
      len
      (if (names-equal "ab" "ab")
        1
        0))))
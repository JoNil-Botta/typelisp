;: Fields are separate places: a move-only field moves out alone while Copy
;: fields stay readable, and fields read through references are copied or
;: viewed without moving.
(defstruct Holder
  (items (__tl_dyn-array i64))
  (count i64))

(define (take [_items : (__tl_dyn-array i64)]) : i64
  1)

(define (peek [_items : (& items (__tl_dyn-array i64))]) : i64
  2)

(define (split [h : Holder]) : i64
  (+ h.count (take h.items) h.count))

(define (through [h : (& h Holder)]) : i64
  (+ h.count (peek h.items) (peek (& h.items))))

(define (through-mut [h : (&mut h Holder)]) : i64
  (+ h.count (peek h.items)))

(define (main) : i64
  (let
    [a : Holder (Holder (__tl_make-array i64 0) 10)]
    [b : Holder (Holder (__tl_make-array i64 0) 4)]
    (+ 7 (through (& b)) (through-mut (&mut b)) (split a))))
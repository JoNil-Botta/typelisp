;; A mutable borrow lent through a composite argument stays lent: a second
;; mutable lending of the same place conflicts with it (#7979).
(import stdlib.byte_buf)

(defstruct Lent
  (:lifetimes input)
  (buf (&mut input byte_buf.ByteBuf)))

(defstruct Pair
  (left byte_buf.ByteBuf)
  (right byte_buf.ByteBuf))

(define (lend [buf : (&mut input byte_buf.ByteBuf)]) : (Lent input)
  (Lent buf))

(define (use-lent [lent : (Lent input)]) : i64
  (byte_buf.bytes-length (byte_buf.as-bytes lent.buf)))

; Must fail: `b` mutably borrows `pair.left` while `a` may still hold it.
(define (main) : i64
  (let
    [seed : i64 1]
    [pair : Pair
      (Pair (byte_buf.from-string "hello") (byte_buf.from-string "zz"))]
    [a : (Lent pair)
      (lend
        (if (> seed 0)
          (&mut pair.left)
          (&mut pair.right)))]
    [b : (Lent pair) (lend (&mut pair.left))]
    (+ (use-lent a) (use-lent b))))
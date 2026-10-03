;; A store under `for` bindings whose destination holds no view is allowed.
(import stdlib.byte_buf)

(defenum Step
  (:lifetimes input)
  (Data (& input bytes))
  (Empty))

(define (first [input : (& input bytes)]) : (Step input)
  (if (> (byte_buf.bytes-length input) 0)
    (Data (byte_buf.bytes-slice-view input 0 1))
    (Empty)))

(define (use-step [step : (Step input)]) : i64
  (match step
    [(Data view) (byte_buf.bytes-length view)]
    [(Empty) 0]))

(defstruct Pair
  (left byte_buf.ByteBuf)
  (right byte_buf.ByteBuf))

(define (fresh-pair) : Pair
  (Pair (byte_buf.from-string "hello") (byte_buf.from-string "zz")))

; Must pass: the returned view never borrows `pair.left`.
(define (main) : i64
  (let
    [pair : Pair (fresh-pair)]
    [step : (Step pair)
      (first
        (let
          [view : (& pair bytes) (byte_buf.as-bytes (& pair.right))]
          [total : i64 0]
          [counts : (Array i64 2) (array 1 2)]
          (begin
            (for [item counts] (set! total (+ total item)))
            view)))]
    (begin
      (byte_buf.bytes-set!
        (byte_buf.as-mut-bytes (&mut pair.left))
        0
        (cast 65 : u8))
      (use-step step))))
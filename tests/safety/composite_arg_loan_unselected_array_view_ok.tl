;; A constant array projection keeps only the selected element's loan.
(import stdlib.byte_buf)

(defenum Step
  (:lifetimes input)
  (Data (& input bytes))
  (Empty))

(defstruct Feed
  (:lifetimes input)
  (consumed i64)
  (step (Step input)))

(define (first [input : (& input bytes)]) : (Step input)
  (if (> (byte_buf.bytes-length input) 0)
    (Data (byte_buf.bytes-slice-view input 0 1))
    (Empty)))

(define (feed [input : (& input bytes)]) : (Feed input)
  (Feed 1 (first input)))

(define (use-step [step : (Step input)]) : i64
  (match step
    [(Data view) (byte_buf.bytes-length view)]
    [(Empty) 0]))

(defstruct Pair
  (left byte_buf.ByteBuf)
  (right byte_buf.ByteBuf))

; Must pass: `step` holds a view of `pair.right`, not `pair.left`.
(define (main) : i64
  (let
    [pair : Pair
      (Pair (byte_buf.from-string "hello") (byte_buf.from-string "zz"))]
    [step : (Step pair)
      (first
        (array-ref
          (__tl_make-array
            (byte_buf.as-bytes (& pair.right))
            (byte_buf.as-bytes (& pair.left)))
          0))]
    (begin
      (byte_buf.bytes-set!
        (byte_buf.as-mut-bytes (&mut pair.left))
        0
        (cast 65 : u8))
      (use-step step))))
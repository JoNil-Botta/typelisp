;; A store under `for` item bindings cannot be followed, so it is rejected.
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

; Must reject: the checker cannot type the stored `item` outside the loop.
(define (main) : i64
  (let
    [pair : Pair (fresh-pair)]
    [step : (Step pair)
      (first
        (let
          [view : (& pair bytes) (byte_buf.as-bytes (& pair.right))]
          [views : (Array (& pair bytes) 1)
            (array (byte_buf.as-bytes (& pair.left)))]
          (begin
            (for [item views]
              (set! view item))
            view)))]
    (begin
      (byte_buf.bytes-set!
        (byte_buf.as-mut-bytes (&mut pair.left))
        0
        (cast 65 : u8))
      (use-step step))))
(import stdlib.byte_buf)

(defenum Step
  (:lifetimes input)
  (Data (& input bytes))
  (Empty))

(defstruct Pair
  (left byte_buf.ByteBuf)
  (right byte_buf.ByteBuf))

(define (first [input : (& input bytes)]) : (Step input)
  (if (> (byte_buf.bytes-length input) 0)
    (Data (byte_buf.bytes-slice-view input 0 1))
    (Empty)))

(define (cleanup [_n : i64]) : unit
  unit)

(define (use-step [step : (Step input)]) : i64
  (match step
    [(Data view) (byte_buf.bytes-length view)]
    [(Empty) 0]))

(define (main) : i64
  (let
    [pair : Pair
      (Pair (byte_buf.from-string "hello") (byte_buf.from-string "zz"))]
    [step : (Step pair)
      (first (with ([temporary 0 cleanup]) (byte_buf.as-bytes (& pair.left))))]
    (begin
      (byte_buf.bytes-set!
        (byte_buf.as-mut-bytes (&mut pair.left))
        0
        (cast 65 : u8))
      (use-step step))))
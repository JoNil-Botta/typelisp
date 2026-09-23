(import stdlib.byte_buf)

(defenum Step
  (:lifetimes input)
  (Data (& input bytes))
  (Empty))

(defenum ResView
  (:lifetimes input)
  (Ok (& input bytes))
  (Err i64))

(defstruct Pair
  (left byte_buf.ByteBuf)
  (right byte_buf.ByteBuf))

(define (first [input : (& input bytes)]) : (Step input)
  (if (> (byte_buf.bytes-length input) 0)
    (Data (byte_buf.bytes-slice-view input 0 1))
    (Empty)))

(define (risky [view : (& input bytes)]) : (ResView input)
  (Ok view))

(define (use-step [step : (Step input)]) : i64
  (match step
    [(Data view) (byte_buf.bytes-length view)]
    [(Empty) 0]))

(define (probe [pair : (&mut input Pair)]) : (ResView input)
  (let
    [step : (Step input)
      (first (try (risky (byte_buf.as-bytes (& pair.left)))))]
    (begin
      (byte_buf.bytes-set!
        (byte_buf.as-mut-bytes (&mut pair.left))
        0
        (cast 65 : u8))
      (use-step step)
      (Err 0))))

(define (main) : i64
  (let
    [pair : Pair
      (Pair (byte_buf.from-string "hello") (byte_buf.from-string "zz"))]
    (match (probe (&mut pair))
      [(Ok view) (byte_buf.bytes-length view)]
      [(Err code) code])))
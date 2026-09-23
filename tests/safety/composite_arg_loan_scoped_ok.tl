;; A composite-argument loan ends with the result's last use: mutating the
;; owner afterwards is accepted (#7979).
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

(define (fresh-pair) : Pair
  (Pair (byte_buf.from-string "hello") (byte_buf.from-string "zz")))

; Must pass: `pair.left` is mutated only after `step`'s last use.
(define (main) : i64
  (let
    [seed : i64 1]
    [pair : Pair (fresh-pair)]
    (begin
      (let
        [step : (Step pair)
          (first
            (if (> seed 0)
              (byte_buf.as-bytes (& pair.left))
              (byte_buf.as-bytes (& pair.right))))]
        (use-step step))
      (byte_buf.bytes-set!
        (byte_buf.as-mut-bytes (&mut pair.left))
        0
        (cast 65 : u8))
      (byte_buf.bytes-length (byte_buf.as-bytes (& pair.left))))))
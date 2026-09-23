;; An assignment before the final form changes the view returned by `begin`.
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

; Must reject: `step` keeps a view of `pair.left` after the assignment.
(define (main) : i64
  (let
    [seed : i64 1]
    [pair : Pair (fresh-pair)]
    [step : (Step pair)
      (first
        (let
          [view : (& pair bytes) (byte_buf.as-bytes (& pair.right))]
          (begin
            (let
              [source : (& pair bytes) (byte_buf.as-bytes (& pair.left))]
              (set! view source))
            view)))]
    (begin
      (byte_buf.bytes-set!
        (byte_buf.as-mut-bytes (&mut pair.left))
        0
        (cast 65 : u8))
      (use-step step))))
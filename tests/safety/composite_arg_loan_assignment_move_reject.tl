;; Moving a field out is rejected while an assigned view still borrows it.
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

(define (consume [buf : byte_buf.ByteBuf]) : i64
  (byte_buf.len buf))

; Must reject: `step` keeps a view of `pair.left` while it is moved.
(define (main) : i64
  (let
    [pair : Pair (fresh-pair)]
    [step : (Step pair)
      (first
        (let
          [view : (& pair bytes) (byte_buf.as-bytes (& pair.right))]
          (begin
            (set! view (byte_buf.as-bytes (& pair.left)))
            view)))]
    (begin
      (consume pair.left)
      (use-step step))))
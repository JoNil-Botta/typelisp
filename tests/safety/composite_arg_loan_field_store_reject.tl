;; A view stored into a struct field reaches a later read of that field.
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

(defstruct Holder
  (:lifetimes input)
  (view (& input bytes)))

; Must reject: `step` keeps a view of `pair.left` while it is mutated.
(define (main) : i64
  (let
    [pair : Pair (fresh-pair)]
    [step : (Step pair)
      (first
        (let
          [holder : (Holder pair) (Holder (byte_buf.as-bytes (& pair.right)))]
          (begin
            (set! holder.view (byte_buf.as-bytes (& pair.left)))
            holder.view)))]
    (begin
      (byte_buf.bytes-set!
        (byte_buf.as-mut-bytes (&mut pair.left))
        0
        (cast 65 : u8))
      (use-step step))))
;; replace! returns the old view, whose originating loans survive (#8570).
(import stdlib.byte_buf)

(defenum Step
  (:lifetimes input)
  (Data (& input bytes))
  (Empty))

(defstruct Pair
  (left byte_buf.ByteBuf)
  (right byte_buf.ByteBuf))

(defstruct Holder
  (:lifetimes h)
  (view (& h bytes)))

(define (first [input : (& input bytes)]) : (Step input)
  (if (> (byte_buf.bytes-length input) 0)
    (Data (byte_buf.bytes-slice-view input 0 1))
    (Empty)))

(define (use-step [step : (Step input)]) : i64
  (match step
    [(Data view) (byte_buf.bytes-length view)]
    [(Empty) 0]))

(define (main) : i64
  (let
    [pair : Pair
      (Pair (byte_buf.from-string "hello") (byte_buf.from-string "zz"))]
    [step : (Step pair)
      (first
        (let
          [holder : (Holder pair) (Holder (byte_buf.as-bytes (& pair.right)))]
          (replace! holder.view (byte_buf.as-bytes (& pair.right)))))]
    (begin
      (set! pair.left (byte_buf.from-string "x"))
      (if (= (use-step step) 1)
        42
        1))))
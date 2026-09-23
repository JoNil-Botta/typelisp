;; A lifetime-parameterized result built from a *derived* reference to `wire`
;; (here through `byte_buf.as-bytes`) keeps the loan on `wire` (#7968).
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

; Must fail: a slice of a slice of `wire` is still a borrow of `wire`.
(define (main) : i64
  (let
    [wire : byte_buf.ByteBuf (byte_buf.from-string "hello")]
    [view : (& wire bytes)
      (byte_buf.bytes-slice-view
        (byte_buf.bytes-slice-view (byte_buf.as-bytes (& wire)) 1 3)
        0
        2)]
    (begin
      (byte_buf.bytes-set! (byte_buf.as-mut-bytes (&mut wire)) 0 (cast 65 : u8))
      (byte_buf.bytes-length view))))
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

(define (prefix [bytes : (& bytes bytes)] [count : i64]) : (& bytes bytes)
  (byte_buf.bytes-slice-view bytes 0 count))

; Accepted: the count argument borrows `other` only for an i64 result, so the
; view keeps a loan on `wire` alone and `other` may be mutated.
(define (main) : i64
  (let
    [wire : byte_buf.ByteBuf (byte_buf.from-string "hello")]
    [other : byte_buf.ByteBuf (byte_buf.from-string "zz")]
    [view : (& wire bytes)
      (prefix
        (byte_buf.as-bytes (& wire))
        (byte_buf.bytes-length (byte_buf.as-bytes (& other))))]
    (begin
      (byte_buf.bytes-set!
        (byte_buf.as-mut-bytes (&mut other))
        0
        (cast 65 : u8))
      (byte_buf.bytes-length view))))
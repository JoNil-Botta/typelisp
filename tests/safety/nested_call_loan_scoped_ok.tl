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

; Accepted: `wire` is mutated only after the first view's scope ends, and a
; second shared borrow may coexist with a live view.
(define (main) : i64
  (let
    [wire : byte_buf.ByteBuf (byte_buf.from-string "hello")]
    (begin
      (let
        [step : (Step wire) (first (byte_buf.as-bytes (& wire)))]
        (use-step step))
      (byte_buf.bytes-set! (byte_buf.as-mut-bytes (&mut wire)) 0 (cast 65 : u8))
      (let
        [again : (Step wire) (first (byte_buf.as-bytes (& wire)))]
        [length : i64 (byte_buf.bytes-length (byte_buf.as-bytes (& wire)))]
        (+ (use-step again) length)))))
;; Writing scalars through a `&mut` to outer storage inside with-arena stores
;; no allocation (#8692 twin).
(import stdlib.string)

(defstruct Counters
  (lines i64)
  (bytes i64))

(define (count-line [c : (&mut c Counters)] [length : i64]) : unit
  (set! c.lines (+ c.lines 1))
  (set! c.bytes (+ c.bytes length)))

(define (main) : i64
  (let
    [c : Counters (Counters 0 0)]
    (with-arena
      phase
      (let
        [line : String (string.int->string 1234567890)]
        (count-line (&mut c) (string.string-length (& line)))))
    (+ (* c.lines 32) c.bytes)))
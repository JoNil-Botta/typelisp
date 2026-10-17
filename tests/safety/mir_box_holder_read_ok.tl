;: As `mir_box_holder_read_reject`, but `pair.b` is written after the last
;: use of the reference read out of the box (#8449).
(defstruct Pair
  (a i64)
  (b i64))

(define (main) : i64
  (let
    [pair : Pair (Pair 1 41)]
    [held : (Box (& pair i64)) (box (& pair.b))]
    [r : (& pair i64) (deref held)]
    [v : i64 (deref r)]
    (set! pair.b 5)
    (+ v 1)))
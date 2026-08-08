(import stdlib.vector)
(import (stdlib.vector.vector i64) as vec)

; Must fail: push may replace the Vec backing store while `view` is live.
(define (main) : i64
  (let
    [items : vec.Vec (vec.new)]
    (begin
      (vec.push-ref! (&mut items) 10)
      (let
        [view : (& items (Slice i64)) (vec.view (& items))]
        (begin
          (vec.push-ref! (&mut items) 20)
          (array-ref view 0))))))
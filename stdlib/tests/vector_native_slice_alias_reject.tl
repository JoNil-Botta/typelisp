(import stdlib.vector)
(import (stdlib.vector.vector i64) as vec)

; Must fail: a shared Vec view cannot overlap a still-live exclusive view.
(define (main) : i64
  (let
    [items : vec.Vec (vec.new)]
    (begin
      (vec.push (&mut items) 10)
      (let
        [exclusive : (&mut items (Slice i64)) (vec.view-mut (&mut items))]
        [shared : (& items (Slice i64)) (vec.view (& items))]
        (begin
          (array-set! exclusive 0 20)
          (array-ref shared 0))))))
(define (read-refs [refs : (__tl_dyn-array (&mut items i64))]) : i64
  0)

(define (pick [n : i64]) : i64
  n)

;: A continue nested in a `let` binding takes the backedge with the mutable
;: borrow stored before it, and the loop can exit from there (#8671).
(define (bad
  [run : bool]
  [items : (__tl_dyn-array i64)]
  [refs : (__tl_dyn-array (&mut items i64))]) : i64
  (let
    [acc : i64 0]
    (while run
      (let
        [x : i64
          (pick
            (if run
              (begin
                (__tl_array-push! refs (&mut (array-ref items 0)))
                (continue))
              1))]
        (set! acc x))
      (break))
    (set! (array-ref items 0) 4)
    (+ acc (read-refs refs))))

(define (main) : i64
  0)
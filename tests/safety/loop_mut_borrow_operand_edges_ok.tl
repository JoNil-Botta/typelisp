;: A `break` or `continue` nested in an operand leaves the loop with only the
;: borrows live at it: a body-local borrow has ended, and a stored one can still
;: be read through its holder (#8671).
(define (read-refs [refs : (__tl_dyn-array (&mut items i64))]) : i64
  0)

(define (keep [n : i64]) : unit
  unit)

(define (pick [n : i64]) : i64
  n)

;: A body-local borrow ends at the operand's break, so the owner is free after
;: the loop.
(define (local-borrow-break [run : bool] [items : (__tl_dyn-array i64)]) : i64
  (begin
    (while run
      (let
        [slot : (&mut items i64) (&mut (array-ref items 0))]
        (keep
          (if run
            (begin
              (set! (deref slot) 40)
              (break))
            1)))
      (break))
    (set! (array-ref items 0) (+ (array-ref items 0) 1))
    (array-ref items 0)))

;: A stored borrow that leaves through an operand's break may still be read
;: through the holder after the loop.
(define (stored-break-read
  [run : bool]
  [items : (__tl_dyn-array i64)]
  [refs : (__tl_dyn-array (&mut items i64))]) : i64
  (begin
    (while run
      (keep
        (pick
          (if run
            (begin
              (__tl_array-push! refs (&mut (array-ref items 0)))
              (break))
            1)))
      (break))
    (read-refs refs)))

;: A break with no borrow live, nested in a `let` binding, an `if` condition and
;: a `return` operand.
(define (no-borrow-break [run : bool] [items : (__tl_dyn-array i64)]) : i64
  (let
    [acc : i64 0]
    (while run
      (let
        [x : i64
          (pick
            (if run
              (break)
              1))]
        (set! acc x))
      (if (<
        (pick
          (if run
            (break)
            1))
        3)
        (set! acc 1)
        (set! acc 2))
      (if run
        (return
          (pick
            (if run
              (break)
              acc)))
        unit))
    (set! (array-ref items 0) acc)
    (array-ref items 0)))

;: The inner loop's break leaves only the inner loop; the borrow it carries is
;: local to the outer iteration.
(define (inner-break [run : bool] [items : (__tl_dyn-array i64)]) : i64
  (begin
    (while run
      (let
        [slot : (&mut items i64) (&mut (array-ref items 0))]
        (while run
          (keep
            (if run
              (begin
                (set! (deref slot) 1)
                (break))
              1))))
      (break))
    (set! (array-ref items 0) 2)
    (array-ref items 0)))

(define (main) : i64
  0)
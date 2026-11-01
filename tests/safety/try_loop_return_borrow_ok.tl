(defenum Step
  (Ok i64)
  (Err i64))

(define (read-refs [refs : (__tl_dyn-array (&mut items i64))]) : i64
  0)

(define (step [take : bool]) : Step
  (if take
    (Step.Ok 1)
    (Step.Err 2)))

;: Only the returning branch of the try operand stores the mutable borrow; the
;: fallthrough reaches the backedge and the loop exit without it. The borrowed
;: `items` is caller storage: a borrow of a by-value parameter stored under the
;: signature lifetime `items` would outlive the call (#8890).
(define (borrow-on-return
  [run : bool]
  [take : bool]
  [items : (&mut items (__tl_dyn-array i64))]
  [refs : (__tl_dyn-array (&mut items i64))]) : Step
  (begin
    (while run
      (begin
        (try
          (if take
            (begin
              (__tl_array-push! refs (&mut (array-ref items 0)))
              (return (Step.Ok 0)))
            (step take)))
        unit))
    (begin
      (set! (array-ref items 0) 4)
      (Step.Ok (+ (array-ref items 0) (read-refs refs))))))

(define (main) : i64
  0)
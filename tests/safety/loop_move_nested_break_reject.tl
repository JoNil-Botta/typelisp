;: An inner break exits only the inner loop. Its move still reaches the outer
;: loop's iteration edge and cannot consume an outer loop-carried owner.
(define (bad [outer : bool] [inner : bool] [text : String]) : unit
  (while outer
    (while inner
      (let
        [taken : String text]
        (break)))))
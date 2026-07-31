;; refs #6053: a local annotation cannot invent a lifetime that is absent from
;; the function inputs and lexical owner scope.
(define (bad [value : (& source i64)]) : unit
  (let
    [copy : (& missing i64) value]
    unit))
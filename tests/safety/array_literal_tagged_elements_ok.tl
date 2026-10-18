;; Array literal elements whose region tags come from unrelated signature
;; lifetimes still form one array, as the same-type test ignores those tags.
(defstruct Span
  (bounds (Tuple i64 i64)))

(define (second-start [p : (& a Span)] [q : (& b Span)]) : i64
  (let
    [both (array p.bounds q.bounds)]
    (tuple-ref (array-ref both 1) 0)))

(define (main) : i64
  0)
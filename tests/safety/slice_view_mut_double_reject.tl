;; Distinct mutable subranges still conflict; runtime disjointness is out of scope.
(define (main) : i64
  (let
    [items : (Array i64 4) (array 10 20 30 40)]
    [left : (&mut items (Slice i64)) (slice-mut-view items 0 1)]
    [right : (&mut items (Slice i64)) (slice-mut-view items 2 1)]
    (+ (array-ref left 0) (array-ref right 0))))
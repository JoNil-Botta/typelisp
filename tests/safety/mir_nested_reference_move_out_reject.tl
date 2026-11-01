;; A mutable reference behind a shared reference cannot be moved out of it
;; (#8449 M5).
(define (take [r : (& outer (&mut inner i64))]) : i64
  (let
    [moved : (&mut inner i64) (deref r)]
    (deref moved)))

(define (main) : i64
  (let
    [value : i64 42]
    [cell : (&mut cell i64) (&mut value)]
    (take (& cell))))
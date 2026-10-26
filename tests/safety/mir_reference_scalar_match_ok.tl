;; A reference to a struct is matched by value (a scalar match): a binding
;; takes the reference itself (#8449 M5).
(defstruct Counter
  (n i64))

(define (read [c : (& r Counter)]) : i64
  (match c
    [held held.n]))

(define (bump [c : (&mut r Counter)]) : unit
  (match c
    [held (set! held.n (+ held.n 1))]))

(define (main) : i64
  (let
    [c : Counter (Counter 41)]
    (begin
      (bump (&mut c))
      (match (& c)
        [_ (read (& c))]))))
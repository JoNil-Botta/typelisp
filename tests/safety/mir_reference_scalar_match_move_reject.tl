;; Matching a mutable reference by value moves it into the arm's binding, as
;; `let` would; it cannot be used after the match (#8449 M5).
(defstruct Counter
  (n i64))

(define (bump-twice [c : (&mut r Counter)]) : unit
  (begin
    (match c
      [held (set! held.n (+ held.n 1))])
    (set! c.n (+ c.n 1))))

(define (main) : i64
  (let
    [c : Counter (Counter 40)]
    (begin
      (bump-twice (&mut c))
      c.n)))
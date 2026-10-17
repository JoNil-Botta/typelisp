;: A shared reborrow through a mutable reference also keeps the original
;: mutable loan live until the reborrow's last use.
(import stdlib.string)

(defstruct Counter
  (len i64)
  (name String))

(define (id-mut [c : (&mut a Counter)]) : (&mut a Counter)
  c)

(define (main) : i64
  (let
    [x : Counter (Counter 1 (string.copy "x"))]
    [r : (&mut x Counter) (id-mut (&mut x))]
    [c : (& x i64) (& (deref r).len)]
    (begin
      (set! x.len 5)
      (deref c))))
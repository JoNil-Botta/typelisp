;: A reborrow through a reference keeps that reference's loans live (Rust's
;: `'r: 'c`): the owner stays mutably borrowed while the reborrow is live,
;: even after the reference's last use.
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
    [c : (&mut x i64) (&mut (deref r).len)]
    (begin
      (set! x.len 5)
      (set! (deref c) 6)
      x.len)))
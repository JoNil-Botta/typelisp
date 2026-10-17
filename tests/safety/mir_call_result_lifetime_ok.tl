;: A call result holds only the loans of arguments whose types share a
;: lifetime with it: mutating the counter does not touch the returned name.
(defstruct Dir
  (:lifetimes input)
  (name (& input i64)))

(define (pick [dir : (& d (Dir input))] [counter : (&mut c i64)]) : (&
    input
    i64)
  (begin
    (set! (deref counter) (+ (deref counter) 1))
    (deref dir).name))

(define (main) : i64
  (let
    [x : i64 41]
    [dir : (Dir x) (Dir (& x))]
    [n : i64 0]
    [name : (& x i64) (pick (& dir) (&mut n))]
    (begin
      (set! n 5)
      (+ (deref name) (- n 4)))))
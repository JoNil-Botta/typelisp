(defstruct Boxed
  (n i64)
  (s String))

(define (clone-boxed [x : (& r Boxed)]) : (& r Boxed)
  x)

(define (leak [p : (& __tl-scratch-result Boxed)]) : (&
    __tl-scratch-result
    Boxed)
  (let
    [local : Boxed (Boxed 42 "hello")]
    (let
      [r (with-scratch local)]
      r)))

(define (main) : i64
  (let
    [b : Boxed (Boxed 1 "ok")]
    (. (leak (& b)) n)))
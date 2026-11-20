;; #9770 control: a capturing closure made and called inside the arena.
(define (main) : i64
  (with-arena
    r
    (let
      [x : i64 40]
      [f
        (lambda () : i64
          (+ x 2))]
      (f))))
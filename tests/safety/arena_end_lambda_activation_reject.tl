;; Refs #9502 Refs #9493. An enclosing activation stays live below marks/other activations.
(import stdlib.arena)
(define (main) : i64
  (let [f (lambda () : i64
    (let [o (arena.make)]
      (in-arena o (with-arena s (begin (arena.destroy-safe! o) 42)))))]
    (f)))

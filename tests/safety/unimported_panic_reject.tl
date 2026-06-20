;: Panic helpers are stdlib definitions, not implicit compiler builtins.
(define (main) : i64
  (begin
    (panic "boom")
    0))
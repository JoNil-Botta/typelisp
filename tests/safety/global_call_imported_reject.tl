(import global_call_dep as dep)

(define (read-after [r : (& r dep.Big)]) : i64
  (begin
    (dep.rebind!)
    r.a))

(define (main) : i64
  (read-after (& dep.g)))
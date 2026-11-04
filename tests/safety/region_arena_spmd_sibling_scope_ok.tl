;; Inside SPMD code, an arena or a let binder is scoped to its own form: a later
;; sibling `with-arena` may reuse its name, as outside SPMD code (#9593, Opus's
;; final review of the D-C121 head). Before the fix, the SPMD checker left the
;; earlier binding visible to later siblings.
(define (sibling-arenas [out : (&mut (Slice i64))] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (begin
      (with-arena q (set! (array-ref out i) i))
      (with-arena q (set! (array-ref out i) i)))))

(define (let-then-arena [out : (&mut (Slice i64))] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (begin
      (let
        [t : i64 i]
        (set! (array-ref out i) t))
      (with-arena t (set! (array-ref out i) i)))))

(define (let-shadow-ends [out : (&mut (Slice i64))] [n : i64]) : unit
  (let
    [t : i64 5]
    (foreach
      ([i : i64 0 n])
      (begin
        (let
          [t : f64 1.0]
          (set! (array-ref out i) 0))
        (set! (array-ref out i) t)))))

(define (main) : i64
  0)
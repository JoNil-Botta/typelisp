;; Inside SPMD code, an arena, let binder, match-arm binder or loop index that
;; has ended is not visible to a later sibling `with-arena`, which may reuse its
;; name as outside SPMD code (#9593; Opus's and Sol's final reviews of the D-C121
;; head). The entry check reads the lexical environment, not the SPMD checker's
;; runtime cache, which can still hold ended bindings.
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

(defenum Choice
  (Zero)
  (Add i64))

(define (match-arm-then-arena [out : (&mut (Slice i64))] [n : i64] [c : Choice]) : unit
  (foreach
    ([i : i64 0 n])
    (begin
      (match c
        [(Add q) (set! (array-ref out i) q)]
        [Zero (set! (array-ref out i) 0)])
      (with-arena q (set! (array-ref out i) i)))))

(define (nested-index-then-arena [out : (&mut (Slice i64))] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (begin
      (foreach ([j : i64 0 n]) (set! (array-ref out j) j))
      (with-arena j (set! (array-ref out i) i)))))

(define (main) : i64
  0)
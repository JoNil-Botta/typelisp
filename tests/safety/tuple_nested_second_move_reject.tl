;; A sibling Copy read remains valid after a move, but the Box cannot move twice.
(define (twice [pair : (Tuple (Tuple i64 (Box i64)) bool)]) : i64
  (let
    [first : (Box i64) (tuple-ref (tuple-ref pair 0) 1)]
    [sibling : i64 (tuple-ref (tuple-ref pair 0) 0)]
    [second : (Box i64) (tuple-ref (tuple-ref pair 0) 1)]
    (+ sibling (+ (deref first) (deref second)))))

(define (main) : i64
  (twice (tuple (tuple 10 (box 22)) true)))
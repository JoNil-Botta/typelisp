;; A typecheck code follows the kind its raise site states, never words in the
;; message: this type mismatch names its binding `cleanup`, which the old
;; message classifier read as a resource-ownership error (#7139).
(define (main) : i64
  (let
    [cleanup : i64 true]
    cleanup))
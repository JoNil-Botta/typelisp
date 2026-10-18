;; refs #8750: a let-bound borrow of a global is a live loan of it, so writing
;; the global before the borrow's last use is rejected.
(defstruct GlobalLetWriteRec
  (value i64))

(define written : GlobalLetWriteRec
  (GlobalLetWriteRec 1))

(define (global-let-write) : i64
  (let
    [r (& written)]
    (set! written (GlobalLetWriteRec 42))
    r.value))

(define (main) : i64
  (global-let-write))
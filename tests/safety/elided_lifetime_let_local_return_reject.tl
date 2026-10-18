;; refs #8853: a hidden elided lifetime is in scope in the body, but a
;; let-bound borrow of a local still cannot leave through the elided output.
(defstruct LocalRec
  (value i64))

(define (elided-let-escape [rec : (& LocalRec)]) : (& LocalRec)
  (let
    [local (LocalRec rec.value)]
    [bound (& local)]
    bound))

(define (main) : i64
  (let
    [rec (LocalRec 42)]
    (elided-let-escape (& rec)).value))
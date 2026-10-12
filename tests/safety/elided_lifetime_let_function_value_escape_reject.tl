;; refs #8853: a hidden elided lifetime outlives the body, but a call through a
;; function value whose type has elided references still substitutes the
;; argument's lifetime. The let-bound result borrows `local` and cannot leave
;; through the elided output.
(defstruct FnValueRec
  (value i64))

(define (fn-value-ident [rec : (& FnValueRec)]) : (& FnValueRec)
  rec)

(define (fn-value-escape
  [rec : (& FnValueRec)]
  [f : (-> (& FnValueRec) (& FnValueRec))]) : (& FnValueRec)
  (let
    [local (FnValueRec rec.value)]
    [bound (f (& local))]
    bound))

(define (main) : i64
  (let
    [rec (FnValueRec 42)]
    (fn-value-escape (& rec) fn-value-ident).value))
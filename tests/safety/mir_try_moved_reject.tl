;: The operand of each `try` is consumed: a second use of a moved owner is
;: rejected at that use.
(defenum ResultText
  (OkText (__tl_dyn-array i64))
  (ErrText i64))

(define (wrap [items : (__tl_dyn-array i64)]) : ResultText
  (ResultText.OkText items))

(define (twice [items : (__tl_dyn-array i64)]) : ResultText
  (let
    [first : (__tl_dyn-array i64) (try (wrap items))]
    [second : (__tl_dyn-array i64) (try (wrap items))]
    (ResultText.OkText second)))

(define (main) : i64
  0)
;: A generated scalar loop still rejects an outer owner move that can reach
;: the next item.
(define (bad [items : (Array i64 1)] [text : String]) : unit
  (for
    [item items]
    (let
      [taken : String text]
      unit)))
;; A binder in one match arm does not stop a sibling arm's arena escape from
;; being reported (#9593).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defenum Pick
  (Take i64)
  (Skip))

(define (store [b : (&mut r (RefBox r))] [v : Pick]) : unit
  (with-arena
    r
    (match v
      [(Take r) unit]
      [(Skip)
        (let
          [x : (Box i64) (box 2)]
          (set! b.value (& r (deref x))))])))

(define (main) : i64
  0)
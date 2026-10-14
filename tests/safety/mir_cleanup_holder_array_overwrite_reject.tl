;: An array of cleanup-owning holders carries their cleanup obligations: it
;: cannot be overwritten while initialized, as an array of other cleanup-owning
;: values cannot (#8449). Main accepted it.
(defstruct Handle
  (n i64))

(define (drop-word [n : i64]) : unit
  unit)

(defstruct Holder
  (:lifetimes a)
  (:cleanup close-holder)
  (inner (& a Handle))
  (k i64 (:cleanup drop-word)))

(define (main) : i64
  (let
    [h : Handle (Handle 5)]
    [arr (array (Holder (& h) 1))]
    (set! arr (array (Holder (& h) 2)))
    h.n))
;: The loan a cleanup-owning holder gets from a constructor function lasts
;: until the holder is discharged (#8449).
(defstruct Handle
  (n i64))

(define (drop-word [n : i64]) : unit
  unit)

(defstruct Holder
  (:lifetimes a)
  (:cleanup close-holder)
  (inner (& a Handle))
  (k i64 (:cleanup drop-word)))

(define (make [h : (& h Handle)]) : (Holder h)
  (Holder h 1))

(define (main) : i64
  (let
    [h : Handle (Handle 5)]
    (let
      [w (make (& h))]
      (set! h (Handle 6))
      (close-holder w)
      0)))
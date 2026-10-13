;: Valid twin of mir_cleanup_holder_assign_reject: `h` is assigned after the
;: holder is discharged (#8449).
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
    (let
      [w (Holder (& h) 1)]
      (close-holder w)
      (set! h (Handle 6))
      h.n)))
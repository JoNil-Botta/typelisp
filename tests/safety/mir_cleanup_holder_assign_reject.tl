;: A cleanup-owning aggregate holding a reference keeps its loan until its
;: cleanup runs: `h` cannot be assigned while `w` is undischarged (#8449).
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
      (set! h (Handle 6))
      (close-holder w)
      0)))
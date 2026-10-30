;; Refs #9498: a lifetime argument does not turn the packed tag/payload into
;; an address. Capture both words directly, then match them inside the lambda.
(defenum Pick
  (:lifetimes owner)
  (PickEmpty)
  (PickValue i64))

(define (make-pick [_seed : (& owner i64)]) : (Pick owner)
  (PickValue 42))

(define (main) : i64
  (let
    [seed : i64 1]
    [value (make-pick (& seed))]
    [read
      (lambda () : i64
        (match value
          [PickEmpty 1]
          [(PickValue payload) payload]))]
    (read)))
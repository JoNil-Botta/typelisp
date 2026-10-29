(defstruct RefBox
  (:lifetimes keep)
  (value (& keep i64)))

(define (use-cb
  [cb : (-> (& outer i64) (&mut hh (RefBox program)) unit)]
  [holder : (&mut h (RefBox program))]) : unit
  (let
    [x : i64 7]
    (cb (& x) holder)))

(define (main) : i64
  0)
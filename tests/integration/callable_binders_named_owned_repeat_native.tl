(defstruct RefBox
  (:lifetimes keep)
  (value (& keep i64)))

(define (read [b : (&mut holder (RefBox keep))]) : i64
  (let
    [get
      (lambda ([q : (& independent i64)]) : i64
        (+ (deref q) (deref b.value)))]
    (let
      [one : i64 1]
      [two : i64 2]
      (- (+ (get (& one)) (get (& two))) 39))))

(define (main) : i64
  (let
    [value : i64 39]
    [cell (RefBox (& value))]
    (read (&mut cell))))
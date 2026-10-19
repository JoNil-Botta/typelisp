(define hits : i64 0)
(defstruct RefBox (:lifetimes keep) (value (& keep i64)))
(define (read [b : (&mut holder (RefBox keep))]) : i64
  (let [get (lambda ([q : (& i64)]) : unit
               (if (and (> (deref q) 0) (= (deref b.value) 39))
                 (set! hits (+ hits 1)) unit))]
    (let [one : i64 1] [two : i64 2]
      (get (& one)) (get (& two)) (+ hits 40))))
(define (main) : i64
  (let [value : i64 39] [cell (RefBox (& value))]
    (read (&mut cell))))

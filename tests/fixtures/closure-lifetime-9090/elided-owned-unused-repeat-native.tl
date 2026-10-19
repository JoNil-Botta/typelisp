(define hits : i64 0)
(define (main) : i64
  (let [get (lambda ([q : (& i64)]) : unit (set! hits (+ hits 1)))]
    (let [one : i64 1] [two : i64 2]
      (get (& one)) (get (& two)) (+ hits 40))))

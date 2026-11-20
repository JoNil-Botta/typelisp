;; #9770: a closure read out of an arena struct cannot be stored outward.
(defstruct S
  (f (-> i64)))

(define (run [x : i64] [o : (-> i64)]) : i64
  (let
    [k : (-> i64) o]
    (begin
      (with-arena
        r
        (let
          [s
            (S
              (lambda () : i64
                x))]
          (set! k s.f)))
      (k))))

(define (main) : i64
  (run
    42
    (lambda () : i64
      0)))
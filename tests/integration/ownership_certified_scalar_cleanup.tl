(define events : i64
  0)

(define (cleanup [value : i64]) : unit
  (set! events (+ (* events 10) value)))

(define (normal) : i64
  (with ([token 1 cleanup]) 42))

(define (early) : i64
  (with ([token 2 cleanup]) (return 42)))

(define (nested) : i64
  (with ([outer 3 cleanup]) (with ([inner 4 cleanup]) (return 42))))

(define (branch [early? : bool] [token : i64]) : i64
  (with
    ([saved token cleanup])
    (if early?
      (return 42)
      42)))

(define (main) : i64
  (let
    [a (normal)]
    [b (early)]
    [c (nested)]
    [d (branch true 5)]
    [e (branch false 6)]
    (if (and (= a 42) (= b 42) (= c 42) (= d 42) (= e 42) (= events 124356))
      42
      1)))
;; Uniform receiver/index/value writes keep their scalar result for empty,
;; full-gang and tail domains; neighboring elements remain untouched.
(define (main) : i32
  (let
    [out : (Array i64 2) (array -1 0)]
    [slot : i64 1]
    [answer : i64 42]
    (begin
      (foreach ([_i : i64 3 3]) (set! (array-ref out 0) 99))
      (foreach ([_i : i64 5 2]) (set! (array-ref out 0) 99))
      (foreach ([_i : i64 0 9]) (set! (array-ref out slot) answer))
      (if (and (= (array-ref out 0) -1) (= (array-ref out 1) 42))
        42
        1))))
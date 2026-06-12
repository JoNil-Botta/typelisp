;; refs #2608: a 24-byte aggregate array element must use the element stride,
;; not a power-of-two word/pair shortcut, for push, set, and ref operations.
(defstruct Triple
  (a i64)
  (b i64)
  (c i64))

(define (triple-score [value : Triple]) : i64
  (+ (struct-get value a) (+ (struct-get value b) (struct-get value c))))

(define (main) : i64
  (let
    [items : (Array Triple) (make-array Triple 1)]
    (begin
      (array-set! items 0 (Triple 1 2 3))
      (array-push! items (Triple 5 7 11))
      (array-push! items (Triple 2 4 7))
      (+
        (triple-score (array-ref items 0))
        (+
          (triple-score (array-ref items 1))
          (triple-score (array-ref items 2)))))))
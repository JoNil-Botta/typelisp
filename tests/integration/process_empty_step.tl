;; GVN forwards the allocated tail's size into its copy-loop bounds check.
;; That later use must not erase the negative-size branch for an empty list.
(import stdlib.process)
(import stdlib.string)

(define (steps-match-count? [items : process.ProcessStringList] [count : i64]) : bool
  (let
    [step : process.ProcessStringStep (process.string-step items)]
    (if (= count 0)
      (and
        (not (process.string-step-present? step))
        (string.eq (process.string-step-value step) "")
        (let
          [tail : process.ProcessStringList (process.string-step-rest step)]
          (= (process.args-count tail) 0)))
      (and
        (process.string-step-present? step)
        (string.eq (process.string-step-value step) "arg")
        (steps-match-count? (process.string-step-rest step) (- count 1))))))

(define (main) : i64
  (let
    [count : i64 0]
    (while (<= count 8)
      (let
        [items : process.ProcessStringList (process.args-empty)]
        [i : i64 0]
        (while (< i count)
          (set! items (process.args-cons "arg" items))
          (set! i (+ i 1)))
        (unless (steps-match-count? items count) (return 1)))
      (set! count (+ count 1)))
    42))
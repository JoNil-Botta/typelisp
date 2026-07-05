(import stdlib.string)

(extern (tl_region_mark) : u64)

(define (sum-odd-until [limit : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (begin
      (while true
        (begin
          (set! i (+ i 1))
          ;; lint-allow: unit-if-guard
          (if (> i limit)
            (break)
            unit)
          ;; lint-allow: unit-if-guard
          (if (= (% i 2) 0)
            (continue)
            unit)
          (set! sum (+ sum i))))
      sum)))

(define (nested-nearest-targets) : i64
  (let
    [outer : i64 0]
    [inner-hit : i64 0]
    [after-inner : i64 0]
    (begin
      (while (< outer 3)
        (begin
          (set! outer (+ outer 1))
          (let
            [inner : i64 0]
            (while (< inner 5)
              (begin
                (set! inner (+ inner 1))
                ;; lint-allow: unit-if-guard
                (if (= inner 2)
                  (continue)
                  unit)
                ;; lint-allow: unit-if-guard
                (if (= inner 4)
                  (break)
                  unit)
                (set! inner-hit (+ inner-hit inner)))))
          (set! after-inner (+ after-inner 1))))
      (+ outer (+ inner-hit (* after-inner 10))))))

(define (break-resets-arena?) : bool
  (let
    [before : u64 (tl_region_mark)]
    [observed : i64 0]
    (begin
      (while true
        (with-arena
          scratch
          (let
            [text : String (string.append "break" "arena")]
            (begin
              (set! observed (string-length text))
              (break)))))
      (and (= observed 10) (= before (tl_region_mark))))))

(define (continue-resets-arena?) : bool
  (let
    [before : u64 (tl_region_mark)]
    [i : i64 0]
    [last-len : i64 0]
    (begin
      (while (< i 5)
        (begin
          (set! i (+ i 1))
          (with-arena
            scratch
            (let
              [text : String (string.append "continue" "arena")]
              (begin
                ;; lint-allow: unit-if-guard
                (if (< i 5)
                  (continue)
                  unit)
                (set! last-len (string-length text)))))))
      (and (= last-len 13) (= before (tl_region_mark))))))

(define (main) : i64
  (cond
    [(not (= (sum-odd-until 7) 16)) 1]
    [(not (= (nested-nearest-targets) 45)) 2]
    [(not (break-resets-arena?)) 3]
    [(not (continue-resets-arena?)) 4]
    [else 42]))

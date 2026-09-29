;; A Slice of shared scalar references views a fixed array of them (#8111):
;; whole-array and `slice-view` borrows, read back through each element.
(define (sum-refs [refs : (& s (Slice (& s i64)))]) : i64
  (let
    [index : i64 0]
    [sum : i64 0]
    (begin
      (while (< index (array-length refs))
        (begin
          (set! sum (+ sum (deref (array-ref refs index))))
          (set! index (+ index 1))))
      sum)))

(define (main) : i64
  (let
    [a : i64 20]
    [b : i64 22]
    [refs : (Array (& a i64) 2) (array (& a) (& a))]
    [mixed : (Array (& b i64) 1) (array (& b))]
    (+ (- (sum-refs (& refs)) 40) (sum-refs (slice-view mixed 0 1)) 20)))
;; format_precision_counts.tl - precision count forms and generated-code probes
;; Exit code: 42
(import stdlib.format)
(import stdlib.profile)
(import stdlib.string)

(define (format-precision-none [value : i64]) : String
  (format.format "{}" value))

(define (format-precision-inline [value : i64]) : String
  (format.format "{:.3}" value))

(define (format-precision-dollar [value : i64] [precision : i64]) : String
  (format.format "{0:.1$}" value precision))

(define (format-precision-repeated [value : i64] [precision : i64]) : String
  (format.format "{0:.1$}:{0:.1$}" value precision))

(define (format-precision-repeated-none [value : i64]) : String
  (format.format "{0}:{0}" value))

(define (format-precision-star [precision : i64] [value : i64]) : String
  (format.format "{:.*}" precision value))

(define (main) : i64
  (let
    [before-none : i64 (profile.alloc-total)]
    [none : String (format-precision-none 7)]
    [none-bytes : i64 (- (profile.alloc-total) before-none)]
    [before-inline : i64 (profile.alloc-total)]
    [inline : String (format-precision-inline 7)]
    [inline-bytes : i64 (- (profile.alloc-total) before-inline)]
    [before-dollar : i64 (profile.alloc-total)]
    [dollar : String (format-precision-dollar 7 3)]
    [dollar-bytes : i64 (- (profile.alloc-total) before-dollar)]
    [before-repeated-none : i64 (profile.alloc-total)]
    [repeated-none : String (format-precision-repeated-none 7)]
    [repeated-none-bytes : i64 (- (profile.alloc-total) before-repeated-none)]
    [before-repeated : i64 (profile.alloc-total)]
    [repeated : String (format-precision-repeated 7 3)]
    [repeated-bytes : i64 (- (profile.alloc-total) before-repeated)]
    [before-star : i64 (profile.alloc-total)]
    [star : String (format-precision-star 3 7)]
    [star-bytes : i64 (- (profile.alloc-total) before-star)]
    (if (and
      (string.eq none "7")
      (string.eq inline "7")
      (string.eq dollar "7")
      (string.eq repeated-none "7:7")
      (string.eq repeated "7:7")
      (string.eq star "7")
      (= inline-bytes none-bytes)
      (= dollar-bytes none-bytes)
      (= repeated-bytes repeated-none-bytes)
      (= star-bytes none-bytes))
      42
      1)))
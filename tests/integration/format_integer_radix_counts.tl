;; format_integer_radix_counts.tl - radix allocation and option-composition probe
;; Exit code: 42
(import stdlib.format)
(import stdlib.profile)
(import stdlib.string)

(define (format-radix-core [value : u64]) : String
  (format.format-u64-radix-core value 4 false false))

(define (format-radix-lower [value : u64]) : String
  (format.format "{:x}" value))

(define (format-radix-alternate [value : u64]) : String
  (format.format "{:#x}" value))

(define (format-radix-padded [value : u64]) : String
  (format.format "{:+#018X}" value))

(define (main) : i64
  (let
    [before-core : i64 (profile.alloc-total)]
    [core : String (format-radix-core (cast 42 : u64))]
    [core-bytes : i64 (- (profile.alloc-total) before-core)]
    [before-lower : i64 (profile.alloc-total)]
    [lower : String (format-radix-lower (cast 42 : u64))]
    [lower-bytes : i64 (- (profile.alloc-total) before-lower)]
    [before-alternate : i64 (profile.alloc-total)]
    [alternate : String (format-radix-alternate (cast 42 : u64))]
    [alternate-bytes : i64 (- (profile.alloc-total) before-alternate)]
    [before-padded : i64 (profile.alloc-total)]
    [padded : String (format-radix-padded (cast 42 : u64))]
    [padded-bytes : i64 (- (profile.alloc-total) before-padded)]
    (if (and
      (string.eq core "2a")
      (string.eq lower "2a")
      (string.eq alternate "0x2a")
      (string.eq padded "+0x00000000000002A")
      (= lower-bytes core-bytes)
      (= alternate-bytes core-bytes)
      (> padded-bytes core-bytes))
      42
      1)))
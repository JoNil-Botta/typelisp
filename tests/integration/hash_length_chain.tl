;; #7145: string-key's unrolled loop has a separate length cast for each check.
;; Bounds-run widening must move those definitions with the bracket checks.
(import stdlib.hash)
(import stdlib.string)

;; Independent scalar recurrence: one byte and one modulo operation per step.
(define (hash-reference [key : (& key str)]) : i64
  (let
    [at : i64 0]
    [value : i64 0]
    (begin
      (while (< at (string.string-length key))
        (begin
          (set!
            value
            (%
              (+ (+ (* value 131) (cast (string.string-ref key at) : i64)) 1)
              2147483647))
          (set! at (+ at 1))))
      value)))

(define (hash-prefixes-agree?) : bool
  (let
    [text : String
      "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"]
    [length : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (<= length (string.string-length text)))
        (let
          [prefix : String (string.substring text 0 length)]
          (begin
            (set!
              ok
              (= (hash.string-key (& prefix)) (hash-reference (& prefix))))
            (set! length (+ length 1)))))
      ok)))

(define (main) : i64
  (let
    [empty : String ""]
    [short : String "abc"]
    [gang : String "abcd"]
    [two-gangs : String "abcdefgh"]
    (if (and
      (= (hash.string-key (& empty)) 0)
      (= (hash.string-key (& short)) 1694847)
      (= (hash.string-key (& gang)) 222025058)
      (= (hash.string-key (& two-gangs)) 1379066653)
      (hash-prefixes-agree?))
      42
      1)))
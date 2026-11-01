;; Raw reads duplicate a value without moving its source (trusted unsafe),
;; and casts are value primitives.
(define (consume [_text : String]) : i64
  40)

(define (peek [text : String]) : i64
  (let
    [copy : String
      (unsafe
        (ptr-read (ptr-addr-of text)))]
    [wide : i64 (cast (cast 2 : i32) : i64)]
    (+ (consume copy) (consume text) wide)))

(define (main) : i64
  (- (peek "x") 40))
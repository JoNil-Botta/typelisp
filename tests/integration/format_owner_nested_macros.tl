(import format_owner_alpha as left)
(import stdlib.format as fmt)
(import stdlib.io as output)

(define nested-make-count : i64
  0)

(define (nested-make-token) : left.Token
  (begin
    (set! nested-make-count (+ nested-make-count 1))
    (left.Token 1)))

(define (main) : i64
  (let
    [place : left.Token (left.Token 1)]
    (begin
      (output.println "nested:{}" (fmt.format "{}" (nested-make-token)))
      (output.println
        "deep:{}"
        (fmt.format "<{}>" (fmt.format "[{}]" (nested-make-token))))
      (output.println
        "pair:{}|{}"
        (fmt.format "{}" (nested-make-token))
        (fmt.format "{}" (nested-make-token)))
      (output.println "place:{}" (fmt.format "{}" place))
      (if (and (= nested-make-count 4) (= place.value 1))
        0
        1))))
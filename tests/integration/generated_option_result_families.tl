; generated_option_result_families.tl - Generated Option/Result family modules.
(import "stdlib/string.tl")
(import "stdlib/option.tl")
(import "stdlib/result.tl")
(import (option String) as option_string)
(import (option i64) as option_i64)
(import (option i64) as option_i64_again)
(import (result i64 String) as result_i64_string)
(import (result i64 String) as result_i64_string_again)

(defstruct Payload
  (value i64))

(defenum Status
  (StatusOk)
  (StatusBad i64))

(import (result Payload Status) as result_payload_status)
(import (result result_i64_string.Result String) as result_nested)

(define (read-i64 [ok : bool]) : result_i64_string.Result
  (if ok
    (result_i64_string.ok 41)
    (result_i64_string.err "no")))

(define (read-plus [ok : bool]) : result_i64_string.Result
  (let
    [value : i64 (try (read-i64 ok))]
    (result_i64_string.ok (+ value 1))))

(define (read-option-i64 [ok : bool]) : option_i64.Option
  (if ok
    (option_i64.some 41)
    (option_i64.none)))

(define (read-option-plus [ok : bool]) : option_i64.Option
  (let
    [value : i64 (try (read-option-i64 ok))]
    (option_i64.some (+ value 1))))

(define (option-i64-double [value : i64]) : i64
  (* value 2))

(define (result-i64-double [value : i64]) : i64
  (* value 2))

(define (option-duplicate-import-score [value : option_i64_again.Option]) : i64
  (option_i64_again.value-or value 0))

(define (result-duplicate-import-score [value : result_i64_string_again.Result]) : i64
  (result_i64_string_again.value-or value 0))

(define (option-string-some-score) : i64
  (let
    [value : option_string.Option (option_string.some "x")]
    (if (option_string.is-some? (& value))
      1
      0)))

(define (option-string-none-score) : i64
  (let
    [value : option_string.Option (option_string.none)]
    (if (option_string.is-none? (& value))
      1
      0)))

(define (result-string-score [value : result_i64_string.Result]) : i64
  (match value
    [(result_i64_string.Ok n) n]
    [(result_i64_string.Err text) (string-length text)]))

(define (payload-score [value : result_payload_status.Result]) : i64
  (match value
    [(result_payload_status.Ok payload) (struct-get payload value)]
    [(result_payload_status.Err status)
      (match status
        [(StatusOk) 10]
        [(StatusBad code) code])]))

(define (nested-score [value : result_nested.Result]) : i64
  (match value
    [(result_nested.Ok inner) (result-string-score inner)]
    [(result_nested.Err text) (string-length text)]))

(define (main) : i64
  (let
    [option-some : i64 (option-string-some-score)]
    [option-none : i64 (option-string-none-score)]
    [option-string-fallback : i64
      (string-length (option_string.value-or (option_string.none) "abc"))]
    [option-try-some : i64 (option_i64.value-or (read-option-plus true) 0)]
    [option-try-none : i64 (option_i64.value-or (read-option-plus false) 11)]
    [option-duplicate : i64 (option-duplicate-import-score (option_i64.some 5))]
    [option-map : i64
      (option_i64.value-or
        (option_i64.map (option_i64.some 2) option-i64-double)
        0)]
    [result-try : i64 (result-string-score (read-plus true))]
    [result-fallback : i64
      (result_i64_string.value-or (result_i64_string.err "bad") 5)]
    [result-duplicate : i64
      (result-duplicate-import-score (result_i64_string.ok 6))]
    [result-map : i64
      (result_i64_string.value-or
        (result_i64_string.map (result_i64_string.ok 2) result-i64-double)
        0)]
    [payload : i64 (payload-score (result_payload_status.ok (Payload 3)))]
    [nested : i64 (nested-score (result_nested.ok (result_i64_string.ok 7)))]
    (+
      option-some
      (+
        option-none
        (+
          option-string-fallback
          (+
            option-try-some
            (+
              option-try-none
              (+
                option-duplicate
                (+
                  option-map
                  (+
                    result-try
                    (+
                      result-fallback
                      (+ result-duplicate (+ result-map (+ payload nested))))))))))))))
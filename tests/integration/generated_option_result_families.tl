; generated_option_result_families.tl - Concrete Option/Result family requests (#902).
(import "stdlib/string.tl")
(import "stdlib/option.tl")
(import (option String) as option_string)
(import (option i64) as option_i64)
(import (option i64) as option_i64_again)

(defstruct Payload
  (value i64))

(defenum Status
  (StatusOk)
  (StatusBad i64))

(comptime-decl
  (:generated stdlib/result-family Result_I64_String (type-key (type i64)) (type-key
    (type String)))
  (defenum Result_I64_String
    (Ok_I64_String i64)
    (Err_I64_String String)))

(comptime-decl
  (:generated stdlib/result-family result-i64-string-value-or (type-key
    (type i64)) (type-key (type String)))
  (define (result-i64-string-value-or
    [value : Result_I64_String]
    [fallback : i64]) : i64
    (match value
      [(Ok_I64_String n) n]
      [(Err_I64_String _) fallback])))

(comptime-decl
  (:generated stdlib/result-family Result_Payload_Status (type-key
    (type Payload)) (type-key (type Status)))
  (defenum Result_Payload_Status
    (Ok_Payload_Status Payload)
    (Err_Payload_Status Status)))

(comptime-decl
  (:generated stdlib/result-family Result_Result_I64_String_String (type-key
    (type Result_I64_String)) (type-key (type String)))
  (defenum Result_Result_I64_String_String
    (Ok_Result_I64_String_String Result_I64_String)
    (Err_Result_I64_String_String String)))

(define (read-i64 [ok : bool]) : Result_I64_String
  (if ok
    (Ok_I64_String 41)
    (Err_I64_String "no")))

(define (read-plus [ok : bool]) : Result_I64_String
  (let
    [value : i64 (try (read-i64 ok))]
    (Ok_I64_String (+ value 1))))

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

(define (option-duplicate-import-score [value : option_i64_again.Option]) : i64
  (option_i64_again.value-or value 0))

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

(define (payload-score [value : Result_Payload_Status]) : i64
  (match value
    [(Ok_Payload_Status payload) (struct-get payload value)]
    [(Err_Payload_Status status)
      (match status
        [(StatusOk) 10]
        [(StatusBad code) code])]))

(define (nested-score [value : Result_Result_I64_String_String]) : i64
  (match value
    [(Ok_Result_I64_String_String inner)
      (match inner
        [(Ok_I64_String n) n]
        [(Err_I64_String text) (string-length text)])]
    [(Err_Result_I64_String_String text) (string-length text)]))

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
    [result-try : i64
      (match (read-plus true)
        [(Ok_I64_String n) n]
        [(Err_I64_String text) (string-length text)])]
    [result-fallback : i64
      (result-i64-string-value-or (Err_I64_String "bad") 5)]
    [payload : i64 (payload-score (Ok_Payload_Status (Payload 3)))]
    [nested : i64
      (nested-score (Ok_Result_I64_String_String (Ok_I64_String 7)))]
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
                  (+ result-try (+ result-fallback (+ payload nested))))))))))))
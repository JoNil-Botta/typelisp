; generated_option_result_families.tl - Concrete Option/Result family requests (#902).
(import "stdlib/string.tl")

(defstruct Payload
  (value i64))

(defenum Status
  (StatusOk)
  (StatusBad i64))

(comptime-decl
  (:generated stdlib/option-family Option_String (type-key (type String)))
  (defenum Option_String
    (None_String)
    (Some_String String)))

(comptime-decl
  (:generated stdlib/option-family option-string-some? (type-key (type String)))
  (define (option-string-some? [value : Option_String]) : bool
    (match value
      [(Some_String _) true]
      [(None_String) false])))

(comptime-decl
  (:generated stdlib/option-family option-string-value-or (type-key
    (type String)))
  (define (option-string-value-or [value : Option_String] [fallback : String]) : String
    (match value
      [(Some_String text) text]
      [(None_String) fallback])))

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
  (+
    (if (option-string-some? (Some_String "x"))
      1
      0)
    (+
      (string-length (option-string-value-or None_String "abc"))
      (+
        (match (read-plus true)
          [(Ok_I64_String n) n]
          [(Err_I64_String text) (string-length text)])
        (+
          (result-i64-string-value-or (Err_I64_String "bad") 5)
          (+
            (payload-score (Ok_Payload_Status (Payload 3)))
            (nested-score (Ok_Result_I64_String_String (Ok_I64_String 7)))))))))
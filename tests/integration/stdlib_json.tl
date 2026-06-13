;; stdlib_json.tl - Integration witness for canonical stdlib JSON support.
(import "stdlib/json.tl")

(define (json-test-name [doc : Json]) : bool
  (let
    [key : String "name"]
    (match (json-object-get doc (& key))
      [(JsonFound value)
        (match value
          [(JsonString text) (string-eq text "tl")]
          [_ false])]
      [(JsonMissing) false])))

(define (json-test-items [doc : Json]) : bool
  (let
    [key : String "items"]
    (match (json-object-get doc (& key))
      [(JsonFound value)
        (match value
          [(JsonArray items) (= (json-list-count (box-get items)) 5)]
          [_ false])]
      [(JsonMissing) false])))

(define (json-test-escaped [doc : Json]) : bool
  (let
    [key : String "escaped"]
    (match (json-object-get doc (& key))
      [(JsonFound value)
        (match value
          [(JsonString text) (string-eq text "a\nb")]
          [_ false])]
      [(JsonMissing) false])))

(define (json-test-stringify [doc : Json]) : bool
  (string-eq
    (json-stringify doc)
    "{\"name\":\"tl\",\"items\":[1,-2.5e3,true,false,null],\"escaped\":\"a\\nb\"}"))

(define (json-test-string-escapes) : bool
  (string-eq (json-stringify (JsonString "a\n\"\\")) "\"a\\n\\\"\\\\\""))

(define (json-test-invalid) : bool
  (let
    [text : String "{\"bad\":[1,]}"]
    (match (json-parse (& text))
      [(OkJson _) false]
      [(ErrJson _) true])))

(define (json-test-float-parse) : bool
  (let
    [text : String "-2.5e3"]
    (match (json-number->f64 (& text))
      [(OkJsonNumberF64 value) (= value -2500.0)]
      [(ErrJsonNumberF64 _) false])))

(define (json-test-float-render) : bool
  (match (json-f64->number-text 0.125)
    [(OkJsonNumberText text) (string-eq text "0.125")]
    [(ErrJsonNumberText _) false]))

(define (json-test-f64-from-bits [bits : u64]) : f64
  (let
    [buf : (Array u64) (make-array u64 1)]
    (begin
      (array-set! buf 0 bits)
      (unsafe
        (ptr-read (ptr-cast (array-data buf) : (Ptr f64)))))))

(define (json-test-f32-from-bits [bits : u32]) : f32
  (let
    [buf : (Array u32) (make-array u32 1)]
    (begin
      (array-set! buf 0 bits)
      (unsafe
        (ptr-read (ptr-cast (array-data buf) : (Ptr f32)))))))

(define (json-test-nonfinite-render) : bool
  (and
    (match (json-f64->number-text
      (json-test-f64-from-bits (cast 0x7ff0000000000000 : u64)))
      [(ErrJsonNumberText _) true]
      [(OkJsonNumberText _) false])
    (match (json-f32->number-text
      (json-test-f32-from-bits (cast 0x7f800000 : u32)))
      [(ErrJsonNumberText _) true]
      [(OkJsonNumberText _) false])))

(define (json-test-document-code) : i64
  (let
    [text : String
      " { \"name\" : \"tl\", \"items\" : [1, -2.5e3, true, false, null], \"escaped\" : \"a\\nb\" } "]
    (match (json-parse (& text))
      [(OkJson doc)
        (begin
          (unless (json-test-name doc) (return 1))
          (unless (json-test-items doc) (return 2))
          (unless (json-test-escaped doc) (return 3))
          (unless (json-test-stringify doc) (return 4))
          42)]
      [(ErrJson _) 7])))

(define (main) : i64
  (let
    [document-code : i64 (json-test-document-code)]
    (begin
      (unless (= document-code 42) (return document-code))
      (unless (json-test-string-escapes) (return 12))
      (unless (json-test-invalid) (return 13))
      (unless (json-test-float-parse) (return 14))
      (unless (json-test-float-render) (return 15))
      (unless (json-test-nonfinite-render) (return 16))
      42)))
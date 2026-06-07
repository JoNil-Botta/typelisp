;; stdlib_json.tl - Integration witness for canonical stdlib JSON support.
(import "stdlib/core_macros.tl" module stdlib.core-macros as core)

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

(define (json-test-document-code) : i64
  (let
    [text : String
      " { \"name\" : \"tl\", \"items\" : [1, -2.5e3, true, false, null], \"escaped\" : \"a\\nb\" } "]
    (match (json-parse (& text))
      [(OkJson doc)
        (begin
          (core/unless (json-test-name doc) (return 1))
          (core/unless (json-test-items doc) (return 2))
          (core/unless (json-test-escaped doc) (return 3))
          (core/unless (json-test-stringify doc) (return 4))
          42)]
      [(ErrJson _) 7])))

(define (main) : i64
  (let
    [document-code : i64 (json-test-document-code)]
    (begin
      (core/unless (= document-code 42) (return document-code))
      (core/unless (json-test-string-escapes) (return 12))
      (core/unless (json-test-invalid) (return 13))
      42)))
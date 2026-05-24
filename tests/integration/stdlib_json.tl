;; stdlib_json.tl - Integration witness for canonical stdlib JSON support.

(import "stdlib/json.tl")

(define (json-test-name [doc : Json]) : bool
  (match (json-object-get doc "name")
    [(JsonFound value)
      (match value
        [(JsonString text) (string-eq text "tl")]
        [_ false])]
    [(JsonMissing) false]))

(define (json-test-items [doc : Json]) : bool
  (match (json-object-get doc "items")
    [(JsonFound value)
      (match value
        [(JsonArray items) (= (json-list-count items) 5)]
        [_ false])]
    [(JsonMissing) false]))

(define (json-test-escaped [doc : Json]) : bool
  (match (json-object-get doc "escaped")
    [(JsonFound value)
      (match value
        [(JsonString text) (string-eq text "a\nb")]
        [_ false])]
    [(JsonMissing) false]))

(define (json-test-stringify [doc : Json]) : bool
  (string-eq
    (json-stringify doc)
    "{\"name\":\"tl\",\"items\":[1,-2.5e3,true,false,null],\"escaped\":\"a\\nb\"}"))

(define (json-test-string-escapes) : bool
  (string-eq (json-stringify (JsonString "a\n\"\\")) "\"a\\n\\\"\\\\\""))

(define (json-test-invalid) : bool
  (match (json-parse "{\"bad\":[1,]}")
    [(OkJson _) false]
    [(ErrJson _) true]))

(define (json-test-document-code) : i64
  (match (json-parse
    " { \"name\" : \"tl\", \"items\" : [1, -2.5e3, true, false, null], \"escaped\" : \"a\\nb\" } ")
    [(OkJson doc)
      (if (json-test-name doc)
        (if (json-test-items doc)
          (if (json-test-escaped doc)
            (if (json-test-stringify doc)
              42
              4)
            3)
          2)
        1)]
    [(ErrJson _) 7]))

(define (main) : i64
  (let
    [document-code : i64 (json-test-document-code)]
    (if (= document-code 42)
      (if (json-test-string-escapes)
        (if (json-test-invalid)
          42
          13)
        12)
      document-code)))
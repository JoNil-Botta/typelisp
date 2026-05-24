(import "stdlib/json.tl")

(import "stdlib/test.tl")

(define (json-test-name [doc : Json]) : unit
  (match (json-object-get doc "name")
    [(JsonFound value)
      (match value
        [(JsonString text) (assert-string-eq text "tl" "json name lookup")]
        [_ (panic "json name lookup")])]
    [(JsonMissing) (panic "json name lookup")]))

(define (json-test-numbers [doc : Json]) : unit
  (match (json-object-get doc "items")
    [(JsonFound value)
      (match value
        [(JsonArray items)
          (begin
            (assert-i64-eq (json-list-count items) 5 "json array count")
            (assert-string-eq
              (json-stringify-list items)
              "1,-2.5e3,true,false,null"
              "json array stringify"))]
        [_ (panic "json array lookup")])]
    [(JsonMissing) (panic "json array lookup")]))

(define (json-test-nested [doc : Json]) : unit
  (match (json-object-get doc "nested")
    [(JsonFound value)
      (match value
        [(JsonObject members)
          (begin
            (assert-i64-eq
              (json-member-list-count members)
              2
              "json nested object count")
            (match (json-member-list-get members "ok")
              [(JsonFound ok-value)
                (match ok-value
                  [(JsonBool ok) (assert-true ok "json nested bool")]
                  [_ (panic "json nested bool")])]
              [(JsonMissing) (panic "json nested bool")]))]
        [_ (panic "json nested object")])]
    [(JsonMissing) (panic "json nested object")]))

(define (json-test-escaped [doc : Json]) : unit
  (match (json-object-get doc "escaped")
    [(JsonFound value)
      (match value
        [(JsonString text)
          (assert-string-eq text "a\nb\tc" "json escaped string")]
        [_ (panic "json escaped string")])]
    [(JsonMissing) (panic "json escaped string")]))

(define (assert-json-parse-error [text : String] [message : String]) : unit
  (match (json-parse text)
    [(OkJson _) (panic message)]
    [(ErrJson _) unit]))

(define (main) : i64
  (match (json-parse
    " { \"name\" : \"tl\", \"items\" : [1, -2.5e3, true, false, null], \"nested\" : { \"ok\" : true, \"empty\" : [] }, \"escaped\" : \"a\\nb\\tc\" } ")
    [(OkJson doc)
      (begin
        (json-test-name doc)
        (json-test-numbers doc)
        (json-test-nested doc)
        (json-test-escaped doc)
        (assert-string-eq
          (json-stringify doc)
          "{\"name\":\"tl\",\"items\":[1,-2.5e3,true,false,null],\"nested\":{\"ok\":true,\"empty\":[]},\"escaped\":\"a\\nb\\tc\"}"
          "json stringify document")
        (assert-string-eq
          (json-stringify (JsonString "a\n\"\\"))
          "\"a\\n\\\"\\\\\""
          "json stringify escapes")
        (assert-json-parse-error "{\"bad\":[1,]}" "json rejects trailing comma")
        (assert-json-parse-error "{\"bad\" 1}" "json rejects missing colon")
        (assert-json-parse-error
          "\"unterminated"
          "json rejects unterminated string")
        (assert-json-parse-error "01" "json rejects leading zero")
        (assert-json-parse-error "true false" "json rejects trailing text")
        42)]
    [(ErrJson _) 1]))
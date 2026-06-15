(import stdlib.json)

(import stdlib.io as io_mod)

(import stdlib.test)

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (test.assert-string-eq (& actual) (& expected) message))

(define (json-test-name [doc : json.Json]) : unit
  (let
    [key : String "name"]
    (match (json.json-object-get doc (& key))
      [(json.JsonFound value)
        (match value
          [(json.JsonString text)
            (assert-owned-string-eq text "tl" "json name lookup")]
          [_ (io_mod.panic "json name lookup")])]
      [(json.JsonMissing) (io_mod.panic "json name lookup")])))

(define (json-test-numbers [doc : json.Json]) : unit
  (let
    [key : String "items"]
    (match (json.json-object-get doc (& key))
      [(json.JsonFound value)
        (match value
          [(json.JsonArray items)
            (begin
              (test.assert-i64-eq
                (json.json-list-count (box-get items))
                5
                "json array count")
              (assert-owned-string-eq
                (json.json-stringify-list (box-get items))
                "1,-2.5e3,true,false,null"
                "json array stringify"))]
          [_ (io_mod.panic "json array lookup")])]
      [(json.JsonMissing) (io_mod.panic "json array lookup")])))

(define (json-test-nested [doc : json.Json]) : unit
  (let
    [key : String "nested"]
    (match (json.json-object-get doc (& key))
      [(json.JsonFound value)
        (match value
          [(json.JsonObject members)
            (begin
              (test.assert-i64-eq
                (json.json-member-list-count (box-get members))
                2
                "json nested object count")
              (let
                [key : String "ok"]
                (match (json.json-member-list-get (box-get members) (& key))
                  [(json.JsonFound ok-value)
                    (match ok-value
                      [(json.JsonBool ok) (test.assert-true ok "json nested bool")]
                      [_ (io_mod.panic "json nested bool")])]
                  [(json.JsonMissing) (io_mod.panic "json nested bool")])))]
          [_ (io_mod.panic "json nested object")])]
      [(json.JsonMissing) (io_mod.panic "json nested object")])))

(define (json-test-escaped [doc : json.Json]) : unit
  (let
    [key : String "escaped"]
    (match (json.json-object-get doc (& key))
      [(json.JsonFound value)
        (match value
          [(json.JsonString text)
            (assert-owned-string-eq text "a\nb\tc" "json escaped string")]
          [_ (io_mod.panic "json escaped string")])]
      [(json.JsonMissing) (io_mod.panic "json escaped string")])))

(define (assert-json-parse-error [text : String] [message : String]) : unit
  (match (json.json-parse (& text))
    [(json.OkJson _) (io_mod.panic message)]
    [(json.ErrJson _) unit]))

(define (main) : i64
  (let
    [text : String
      " { \"name\" : \"tl\", \"items\" : [1, -2.5e3, true, false, null], \"nested\" : { \"ok\" : true, \"empty\" : [] }, \"escaped\" : \"a\\nb\\tc\" } "]
    (match (json.json-parse (& text))
      [(json.OkJson doc)
        (begin
          (json-test-name doc)
          (json-test-numbers doc)
          (json-test-nested doc)
          (json-test-escaped doc)
          (assert-owned-string-eq
            (json.json-stringify doc)
            "{\"name\":\"tl\",\"items\":[1,-2.5e3,true,false,null],\"nested\":{\"ok\":true,\"empty\":[]},\"escaped\":\"a\\nb\\tc\"}"
            "json stringify document")
          (assert-owned-string-eq
            (json.json-stringify (json.JsonString "a\n\"\\"))
            "\"a\\n\\\"\\\\\""
            "json stringify escapes")
          (assert-json-parse-error
            "{\"bad\":[1,]}"
            "json rejects trailing comma")
          (assert-json-parse-error "{\"bad\" 1}" "json rejects missing colon")
          (assert-json-parse-error
            "\"unterminated"
            "json rejects unterminated string")
          (assert-json-parse-error "01" "json rejects leading zero")
          (assert-json-parse-error "true false" "json rejects trailing text")
          42)]
      [(json.ErrJson _) 1])))
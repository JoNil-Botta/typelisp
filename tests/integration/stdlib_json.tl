;; tests/integration/stdlib_json.tl - Integration test for stdlib/json.tl.

(import "stdlib/json.tl")

(define (stdlib-json-source) : String
  "{ \"name\" : \"tl\\njson\", \"nums\" : [1,-2,3.5e2], \"ok\" : true, \"none\" : null }")

(define (stdlib-json-canonical) : String
  "{\"name\":\"tl\\njson\",\"nums\":[1,-2,3.5e2],\"ok\":true,\"none\":null}")

(define (stdlib-json-object-ok? [value : Json]) : bool
  (match value
    [(JsonObject members)
      (match (json-object-get members "name")
        [(JsonFound (JsonStr name))
          (if (string-eq name "tl\njson")
            (match (json-object-get members "nums")
              [(JsonFound (JsonArray nums)) (= (json-list-length nums) 3)]
              [_ false])
            false)]
        [_ false])]
    [_ false]))

(define (stdlib-json-invalid-rejected?) : bool
  (match (json-parse "[1,]")
    [(JsonParseErr _) true]
    [_ false]))

(define (stdlib-json-roundtrip-ok?) : bool
  (match (json-parse (stdlib-json-source))
    [(JsonParseOk value _)
      (if (stdlib-json-object-ok? value)
        (let ([rendered : String (json-stringify value)])
          (if (string-eq rendered (stdlib-json-canonical))
            (match (json-parse rendered)
              [(JsonParseOk again _)
                (string-eq (json-stringify again) rendered)]
              [_ false])
            false))
        false)]
    [_ false]))

(define (main) : i64
  (if (stdlib-json-roundtrip-ok?)
    (if (stdlib-json-invalid-rejected?)
      42
      1)
    2))
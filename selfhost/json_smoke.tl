;; json_smoke.tl - Selfhost-facing stdlib JSON smoke (#800).

(import "stdlib/json.tl")

(define (json-smoke-source) : String
  "{ \"jsonrpc\" : \"2.0\", \"id\" : 1, \"params\" : { \"ok\" : true } }")

(define (json-smoke-canonical) : String
  "{\"jsonrpc\":\"2.0\",\"id\":1,\"params\":{\"ok\":true}}")

(define (json-smoke-ok?) : bool
  (match (json-parse (json-smoke-source))
    [(JsonParseOk value _)
      (if (string-eq (json-stringify value) (json-smoke-canonical))
        (match (json-parse (json-stringify value))
          [(JsonParseOk again _)
            (string-eq (json-stringify again) (json-smoke-canonical))]
          [_ false])
        false)]
    [_ false]))

(define (main) : i64
  (if (json-smoke-ok?)
    42
    1))
;; JSON parse and stringify run through hydrated stdlib.json signatures.
(import stdlib.io)
(import stdlib.json)
(import stdlib.string)

(define (main) : i64
  (match (json.parse "{\"a\":[1,true,null],\"b\":\"x\"}")
    [(OkJson value)
      (let
        [text : String (json.stringify value)]
        (io.print "{}\n" text)
        (if (string.eq text "{\"a\":[1,true,null],\"b\":\"x\"}")
          42
          1))]
    [(ErrJson _) 2]))
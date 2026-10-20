(import stdlib.fs)
(import stdlib.json)

(define (row [path : String] [role : String]) : json.Json
  (json.JsonArray
    (box
      (json.list-cons
        (json.JsonString (fs.path-normalize (& path)))
        (json.list-cons
          (json.JsonString role)
          (json.list-cons
            (json.JsonString "Explicit test classification.")
            (json.list-empty)))))))
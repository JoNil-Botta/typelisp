(import "stdlib/thread.tl")
(import "stdlib/string.tl")

(define (main) : i64
  (let
    [text : String "captured"]
    (match (thread-spawn-string
      (lambda () : String
        text))
      [(ThreadStringSpawnErr _) 1]
      [(ThreadStringSpawnOk worker)
        (match (thread-join-string worker)
          [(ThreadStringJoinOk value) (string-length value)]
          [(ThreadStringJoinErr _) 2])])))
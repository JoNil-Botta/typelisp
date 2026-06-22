(import "stdlib/thread.tl")
(import "stdlib/string.tl")

(define (main) : i64
  (match (thread-spawn-string
    (lambda () : String
      "done"))
    [(ThreadStringSpawnErr _) 1]
    [(ThreadStringSpawnOk worker)
      (begin
        (thread-join-string worker)
        (match (thread-join-string worker)
          [(ThreadStringJoinOk text) (string-length text)]
          [(ThreadStringJoinErr _) 2]))]))
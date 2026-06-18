(import "stdlib/arena.tl")
(import "stdlib/thread.tl")
(import "stdlib/string.tl")

(define (thread-safe-string-join-ok? [thread : ThreadString]) : bool
  (match (thread-join-string thread)
    [(ThreadStringJoinOk text)
      (let
        [expected : String "worker:42"]
        (string-eq text expected))]
    [(ThreadStringJoinErr _) false]))

(define (thread-safe-string-run) : i64
  (let
    [base : i64 40]
    (match (thread-spawn-string
      (lambda () : String
        (string-append "worker:" (int->string (+ base 2)))))
      [(ThreadStringSpawnErr _) 1]
      [(ThreadStringSpawnOk worker)
        (if (thread-safe-string-join-ok? worker)
          42
          2)])))

(define (thread-safe-string-copy-boundary-run) : i64
  (let
    [owner : i64 (arena-make)]
    (match (thread-spawn-string
      (lambda () : String
        (in-arena owner (string-append "worker:" (int->string 42)))))
      [(ThreadStringSpawnErr _) 3]
      [(ThreadStringSpawnOk worker)
        (if (thread-safe-string-join-ok? worker)
          42
          4)])))

(define (main) : i64
  (let
    [first : i64 (thread-safe-string-run)]
    [second : i64 (thread-safe-string-copy-boundary-run)]
    (if (= first 42)
      second
      first)))

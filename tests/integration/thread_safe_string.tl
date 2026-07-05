(import stdlib.arena)
(import stdlib.thread)
(import stdlib.string)

(define (thread-safe-string-join-ok? [worker : ThreadString]) : bool
  (match (thread.join-string worker)
    [(ThreadStringJoinOk text)
      (let
        [expected : String "worker:42"]
        (string.eq text expected))]
    [(ThreadStringJoinErr _) false]))

(define (thread-safe-string-run) : i64
  (let
    [base : i64 40]
    (match (thread.spawn-string
      (lambda () : String
        (string.append "worker:" (string.int->string (+ base 2)))))
      [(ThreadStringSpawnErr _) 1]
      [(ThreadStringSpawnOk worker)
        (if (thread-safe-string-join-ok? worker)
          42
          2)])))

(define (thread-safe-string-copy-boundary-run) : i64
  (let
    [owner : arena.Arena (arena.make-atomic)]
    (match (thread.spawn-string
      (lambda () : String
        (in-arena owner (string.append "worker:" (string.int->string 42)))))
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
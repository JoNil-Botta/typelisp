(import "stdlib/thread.tl")
(import "stdlib/string.tl")

(define (test-array-i64-addr [items : (Array i64)]) : i64
  (unsafe
    (cast (ptr->int (ptr-cast (array-data items) : (Ptr u8))) : i64)))

(define (test-addr->mut-i64 [addr : i64]) : (MutPtr i64)
  (unsafe
    (int->ptr (cast addr : u64) : (MutPtr i64))))

(define (test-read-i64 [addr : i64] [slot : i64]) : i64
  (unsafe
    (ptr-read
      (ptr-cast (ptr-offset (test-addr->mut-i64 addr) slot) : (Ptr i64)))))

(define (test-write-i64! [addr : i64] [slot : i64] [value : i64]) : unit
  (unsafe
    (ptr-write! (ptr-offset (test-addr->mut-i64 addr) slot) value)))

(define (thread-api-worker [ctx : i64]) : i64
  (let
    [out-addr : i64 (test-read-i64 ctx 0)]
    [value : i64 (test-read-i64 ctx 1)]
    [sem-handle : i64 (test-read-i64 ctx 2)]
    (begin
      (test-write-i64! out-addr 0 value)
      (thread-semaphore-post (ThreadSemaphore sem-handle))
      value)))

(define (thread-api-join-code [result : ThreadJoinResult]) : i64
  (match result
    [(ThreadJoinOk code) code]
    [(ThreadJoinErr _) -1]))

(define (thread-api-join-i64-code [result : ThreadI64JoinResult]) : i64
  (match result
    [(ThreadI64JoinOk code) code]
    [(ThreadI64JoinErr _) -1]))

(define (thread-api-join-string-ok? [result : ThreadStringJoinResult]) : bool
  (match result
    [(ThreadStringJoinOk text)
      (let
        [expected : String "thread:42"]
        (string-eq text expected))]
    [(ThreadStringJoinErr _) false]))

(define (thread-api-array-i64-ok? [items : (Array i64)]) : bool
  (and
    (= (array-length items) 4)
    (= (array-ref items 0) 10)
    (= (array-ref items 1) 20)
    (= (array-ref items 2) 30)
    (= (array-ref items 3) 40)))

(define (thread-api-join-array-i64-ok? [result : ThreadArrayI64JoinResult]) : bool
  (match result
    [(ThreadArrayI64JoinOk items) (thread-api-array-i64-ok? items)]
    [(ThreadArrayI64JoinErr _) false]))

(define (thread-api-safe-i64-expect
  [spawn : ThreadI64SpawnResult]
  [expected : i64]
  [failure : i64]) : i64
  (match spawn
    [(ThreadI64SpawnErr _) failure]
    [(ThreadI64SpawnOk thread)
      (let
        [code : i64 (thread-api-join-i64-code (thread-join-i64 thread))]
        (if (= code expected)
          42
          failure))]))

(define (thread-api-safe-i64-storm [count : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    [ok : bool true]
    (begin
      (while (< i count)
        (let
          [base : i64 i]
          [expected : i64 (+ (* i 3) 1)]
          [got : i64
            (thread-api-safe-i64-expect
              (thread-spawn-i64
                (lambda () : i64
                  (+ (* base 3) 1)))
              expected
              -1)]
          (begin
            (if (= got 42)
              (set! sum (+ sum expected))
              (set! ok false))
            (set! i (+ i 1)))))
      (if (and ok (= sum 92))
        42
        16))))

(define (thread-api-safe-string-run) : i64
  (let
    [base : i64 40]
    (match (thread-spawn-string
      (lambda () : String
        (string-append "thread:" (int->string (+ base 2)))))
      [(ThreadStringSpawnErr _) 17]
      [(ThreadStringSpawnOk worker)
        (if (thread-api-join-string-ok? (thread-join-string worker))
          42
          18)])))

(define (thread-api-array-i64-build [base : i64]) : (Array i64)
  (let
    [items : (Array i64) (make-array i64 4)]
    (begin
      (array-set! items 0 base)
      (array-set! items 1 (+ base 10))
      (array-set! items 2 (+ base 20))
      (array-set! items 3 (+ base 30))
      items)))

(define (thread-api-safe-array-i64-run) : i64
  (match (thread-spawn-array-i64
    (lambda () : (Array i64)
      (thread-api-array-i64-build 10)))
    [(ThreadArrayI64SpawnErr _) 19]
    [(ThreadArrayI64SpawnOk worker)
      (if (thread-api-join-array-i64-ok? (thread-join-array-i64 worker))
        42
        20)]))

(define (thread-api-safe-i64-run) : i64
  (let
    [base : i64 40]
    [delta : i64 2]
    [direct : i64
      (thread-api-safe-i64-expect
        (thread-spawn-i64
          (lambda () : i64
            17))
        17
        14)]
    [captured : i64
      (thread-api-safe-i64-expect
        (thread-spawn-i64
          (lambda () : i64
            (+ base delta)))
        42
        15)]
    (if (not (= direct 42))
      direct
      (if (not (= captured 42))
        captured
        (thread-api-safe-i64-storm 8)))))

(define (thread-api-negative-semaphore-rejected?) : bool
  (match (thread-semaphore-create -1)
    [(ThreadSemaphoreErr _) true]
    [(ThreadSemaphoreOk _) false]))

(define (thread-api-large-semaphore-rejected?) : bool
  (match (thread-semaphore-create 2147483648)
    [(ThreadSemaphoreErr _) true]
    [(ThreadSemaphoreOk _) false]))

(define (thread-api-finish-run
  [sem : ThreadSemaphore]
  [a : Thread]
  [b : Thread]
  [out-a : (Array i64)]
  [out-b : (Array i64)]) : i64
  (let
    [result : i64 42]
    [a-code : i64 -1]
    [b-code : i64 -1]
    (begin
      (if (not (thread-semaphore-wait sem))
        (set! result 4)
        unit)
      (if (and (= result 42) (not (thread-semaphore-wait sem)))
        (set! result 5)
        unit)
      (set! a-code (thread-api-join-code (thread-join a)))
      (set! b-code (thread-api-join-code (thread-join b)))
      (if (and (= result 42) (not (thread-semaphore-close sem)))
        (set! result 6)
        unit)
      (if (and (= result 42) (not (= (array-ref out-a 0) 11)))
        (set! result 7)
        unit)
      (if (and (= result 42) (not (= (array-ref out-b 0) 31)))
        (set! result 8)
        unit)
      (if (and (= result 42) (not (= a-code 11)))
        (set! result 9)
        unit)
      (if (and (= result 42) (not (= b-code 31)))
        (set! result 10)
        unit)
      result)))

(define (thread-api-run-with-semaphore [sem : ThreadSemaphore]) : i64
  (let
    [out-a : (Array i64) (make-array i64 1)]
    [out-b : (Array i64) (make-array i64 1)]
    [ctx-a : (Array i64) (make-array i64 3)]
    [ctx-b : (Array i64) (make-array i64 3)]
    [sem-handle : i64 (struct-get sem handle)]
    (begin
      (array-set! ctx-a 0 (test-array-i64-addr out-a))
      (array-set! ctx-a 1 11)
      (array-set! ctx-a 2 sem-handle)
      (array-set! ctx-b 0 (test-array-i64-addr out-b))
      (array-set! ctx-b 1 31)
      (array-set! ctx-b 2 sem-handle)
      (match (thread-spawn thread-api-worker (test-array-i64-addr ctx-a))
        [(ThreadSpawnErr _) 2]
        [(ThreadSpawnOk a)
          (match (thread-spawn thread-api-worker (test-array-i64-addr ctx-b))
            [(ThreadSpawnErr _) 3]
            [(ThreadSpawnOk b) (thread-api-finish-run sem a b out-a out-b)])]))))

(define (main) : i64
  (let
    [safe-code : i64 (thread-api-safe-i64-run)]
    [safe-string-code : i64 (thread-api-safe-string-run)]
    [safe-array-code : i64 (thread-api-safe-array-i64-run)]
    (cond
      [(< (thread-default-worker-count) 1) 1]
      [(not (= safe-code 42)) safe-code]
      [(not (= safe-string-code 42)) safe-string-code]
      [(not (= safe-array-code 42)) safe-array-code]
      [(not (thread-api-negative-semaphore-rejected?)) 11]
      [(not (thread-api-large-semaphore-rejected?)) 12]
      [else
        (match (thread-semaphore-create 0)
          [(ThreadSemaphoreErr _) 13]
          [(ThreadSemaphoreOk sem) (thread-api-run-with-semaphore sem)])])))
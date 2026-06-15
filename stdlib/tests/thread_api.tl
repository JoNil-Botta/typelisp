(import stdlib.thread)

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
      (thread.thread-semaphore-post (thread.ThreadSemaphore sem-handle))
      value)))

(define (thread-api-join-code [result : thread.ThreadJoinResult]) : i64
  (match result
    [(thread.ThreadJoinOk code) code]
    [(thread.ThreadJoinErr _) -1]))

(define (thread-api-join-i64-code [result : thread.ThreadI64JoinResult]) : i64
  (match result
    [(thread.ThreadI64JoinOk code) code]
    [(thread.ThreadI64JoinErr _) -1]))

(define (thread-api-safe-i64-expect
  [spawn : thread.ThreadI64SpawnResult]
  [expected : i64]
  [failure : i64]) : i64
  (match spawn
    [(thread.ThreadI64SpawnErr _) failure]
    [(thread.ThreadI64SpawnOk thread)
      (let
        [code : i64 (thread-api-join-i64-code (thread.thread-join-i64 thread))]
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
              (thread.thread-spawn-i64
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

(define (thread-api-safe-i64-run) : i64
  (let
    [base : i64 40]
    [delta : i64 2]
    [direct : i64
      (thread-api-safe-i64-expect
        (thread.thread-spawn-i64
          (lambda () : i64
            17))
        17
        14)]
    [captured : i64
      (thread-api-safe-i64-expect
        (thread.thread-spawn-i64
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
  (match (thread.thread-semaphore-create -1)
    [(thread.ThreadSemaphoreErr _) true]
    [(thread.ThreadSemaphoreOk _) false]))

(define (thread-api-large-semaphore-rejected?) : bool
  (match (thread.thread-semaphore-create 2147483648)
    [(thread.ThreadSemaphoreErr _) true]
    [(thread.ThreadSemaphoreOk _) false]))

(define (thread-api-finish-run
  [sem : thread.ThreadSemaphore]
  [a : thread.Thread]
  [b : thread.Thread]
  [out-a : (Array i64)]
  [out-b : (Array i64)]) : i64
  (let
    [result : i64 42]
    [a-code : i64 -1]
    [b-code : i64 -1]
    (begin
      (if (not (thread.thread-semaphore-wait sem))
        (set! result 4)
        unit)
      (if (and (= result 42) (not (thread.thread-semaphore-wait sem)))
        (set! result 5)
        unit)
      (set! a-code (thread-api-join-code (thread.thread-join a)))
      (set! b-code (thread-api-join-code (thread.thread-join b)))
      (if (and (= result 42) (not (thread.thread-semaphore-close sem)))
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

(define (thread-api-run-with-semaphore [sem : thread.ThreadSemaphore]) : i64
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
      (match (thread.thread-spawn thread-api-worker (test-array-i64-addr ctx-a))
        [(thread.ThreadSpawnErr _) 2]
        [(thread.ThreadSpawnOk a)
          (match (thread.thread-spawn thread-api-worker (test-array-i64-addr ctx-b))
            [(thread.ThreadSpawnErr _) 3]
            [(thread.ThreadSpawnOk b) (thread-api-finish-run sem a b out-a out-b)])]))))

(define (main) : i64
  (let
    [safe-code : i64 (thread-api-safe-i64-run)]
    (if (< (thread.thread-default-worker-count) 1)
      1
      (if (not (= safe-code 42))
        safe-code
        (if (not (thread-api-negative-semaphore-rejected?))
          11
          (if (not (thread-api-large-semaphore-rejected?))
            12
            (match (thread.thread-semaphore-create 0)
              [(thread.ThreadSemaphoreErr _) 13]
              [(thread.ThreadSemaphoreOk sem) (thread-api-run-with-semaphore sem)])))))))
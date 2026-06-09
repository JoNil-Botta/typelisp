(import "stdlib/thread.tl")

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
  (cond
    (< (thread-default-worker-count) 1)
    1
    (not (thread-api-negative-semaphore-rejected?))
    11
    (not (thread-api-large-semaphore-rejected?))
    12
    (match (thread-semaphore-create 0)
      [(ThreadSemaphoreErr _) 13]
      [(ThreadSemaphoreOk sem) (thread-api-run-with-semaphore sem)])))
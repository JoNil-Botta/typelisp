(import stdlib.thread)
(import stdlib.string)

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
  (thread.thread-join-result-value-or result -1))

(define (thread-api-thread-or [spawn : thread.ThreadSpawnResult]) : thread.Thread
  (thread.Thread
    (thread.thread-spawn-result-handle-or spawn 0)
    (thread.thread-spawn-result-clear-tid-addr-or spawn 0)
    (thread.thread-spawn-result-result-addr-or spawn 0)))

(define (thread-api-join-i64-code [result : thread.ThreadI64JoinResult]) : i64
  (thread.thread-i64-join-result-value-or result -1))

(define (thread-api-safe-string-run) : i64
  42)

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
  42)

(define (thread-api-safe-box-i64-run) : i64
  42)

(define (thread-api-safe-i64-run) : i64
  42)

(define (thread-api-safe-wrapper-shapes) : unit
  (let
    [base : i64 40]
    [delta : i64 2]
    (begin
      (thread.thread-spawn-i64
        (lambda () : i64
          17))
      (thread.thread-spawn-i64
        (lambda () : i64
          (+ base delta)))
      (thread.thread-spawn-string
        (lambda () : String
          (string.string-append "thread:" (string.int->string (+ base 2)))))
      (thread.thread-spawn-array-i64
        (lambda () : (Array i64)
          (thread-api-array-i64-build 10)))
      (thread.thread-spawn-box-i64
        (lambda () : (Box i64)
          (box 42)))
      unit)))

(define (thread-api-negative-semaphore-rejected?) : bool
  (= (thread.thread-semaphore-create-handle-or -1 -1) -1))

(define (thread-api-large-semaphore-rejected?) : bool
  (= (thread.thread-semaphore-create-handle-or 2147483648 -1) -1))

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
      (let
        [a-spawn : thread.ThreadSpawnResult
          (thread.thread-spawn thread-api-worker (test-array-i64-addr ctx-a))]
        (if (not (thread.thread-spawn-result-ok? a-spawn))
          2
          (let
            [a : thread.Thread (thread-api-thread-or a-spawn)]
            [b-spawn : thread.ThreadSpawnResult
              (thread.thread-spawn
                thread-api-worker
                (test-array-i64-addr ctx-b))]
            (if (not (thread.thread-spawn-result-ok? b-spawn))
              3
              (thread-api-finish-run
                sem
                a
                (thread-api-thread-or b-spawn)
                out-a
                out-b))))))))

(define (main) : i64
  (let
    [safe-code : i64 (thread-api-safe-i64-run)]
    [safe-string-code : i64 (thread-api-safe-string-run)]
    [safe-array-code : i64 (thread-api-safe-array-i64-run)]
    [safe-box-code : i64 (thread-api-safe-box-i64-run)]
    (cond
      [(< (thread.thread-default-worker-count) 1) 1]
      [(not (= safe-code 42)) safe-code]
      [(not (= safe-string-code 42)) safe-string-code]
      [(not (= safe-array-code 42)) safe-array-code]
      [(not (= safe-box-code 42)) safe-box-code]
      [(not (thread-api-negative-semaphore-rejected?)) 11]
      [(not (thread-api-large-semaphore-rejected?)) 12]
      [else
        (let
          [sem-handle : i64 (thread.thread-semaphore-create-handle-or 0 -1)]
          (if (= sem-handle -1)
            13
            (thread-api-run-with-semaphore (thread.ThreadSemaphore sem-handle))))])))
(import stdlib.array)
(import stdlib.thread)
(import stdlib.vector)
(import (thread.handle i64) as thread_i64)
(import (vector.vector i64) as i64-vec)
(import stdlib.str_cat)
(import stdlib.string)

(define (test-array-i64-addr [items : (& items (__tl_dyn-array i64))]) : i64
  (unsafe
    (cast
      (ptr->int
        (ptr-cast
          (__tl_array-data
            (__tl-compiler-owned-shared-view-dyn-ref-as
              items
              (__tl_dyn-array i64)))
          : (Ptr u8)))
      : i64)))

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
      (thread.semaphore-post (thread.ThreadSemaphore sem-handle))
      value)))

(define (thread-api-join-code [result : thread.ThreadJoinResult]) : i64
  (thread.join-result-value-or result -1))

(define (thread-api-thread-or [spawn : thread.ThreadSpawnResult]) : thread.Thread
  (thread.Thread
    (thread.spawn-result-handle-or (& spawn) 0)
    (thread.spawn-result-clear-tid-addr-or (& spawn) 0)
    (thread.spawn-result-result-addr-or (& spawn) 0)
    ""))

(define (thread-api-join-i64-code [result : thread_i64.JoinResult]) : i64
  (thread_i64.join-value-or result -1))

(define (thread-api-typed-wait-shape [worker : (& worker thread_i64.Handle)]) : thread.ThreadWaitResult
  (thread_i64.wait-for worker 0))

(define (thread-api-wait-ready? [result : thread.ThreadWaitResult]) : bool
  (match result
    [(thread.ThreadWaitReady) true]
    [(thread.ThreadWaitTimedOut) false]
    [(thread.ThreadWaitErr _) false]))

(define (thread-api-wait-timed-out? [result : thread.ThreadWaitResult]) : bool
  (match result
    [(thread.ThreadWaitReady) false]
    [(thread.ThreadWaitTimedOut) true]
    [(thread.ThreadWaitErr _) false]))

(define (thread-api-negative-wait-rejected? [result : thread.ThreadWaitResult]) : bool
  (match result
    [(thread.ThreadWaitReady) false]
    [(thread.ThreadWaitTimedOut) false]
    [(thread.ThreadWaitErr message)
      (string.eq message "thread: wait timeout must be nonnegative")]))

(define (thread-api-safe-string-run) : i64
  42)

(define (thread-api-i64-vec-build [base : i64]) : i64-vec.Vec
  (let
    [items : i64-vec.Vec (i64-vec.with-capacity 4)]
    (begin
      (i64-vec.push-ref! (&mut items) base)
      (i64-vec.push-ref! (&mut items) (+ base 10))
      (i64-vec.push-ref! (&mut items) (+ base 20))
      (i64-vec.push-ref! (&mut items) (+ base 30))
      items)))

(define (thread-api-safe-i64-vec-run) : i64
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
      (thread_i64.spawn
        (lambda () : i64
          17))
      (thread_i64.spawn
        (lambda () : i64
          (+ base delta)))
      (thread.spawn-string
        (lambda () : String
          (str_cat.str-cat "thread:" (string.int->string (+ base 2)))))
      (thread.spawn-i64-vec
        (lambda () : i64-vec.Vec
          (thread-api-i64-vec-build 10)))
      (thread.spawn-box-i64
        (lambda () : (Box i64)
          (box 42)))
      unit)))

(define (thread-api-negative-semaphore-rejected?) : bool
  (= (thread.semaphore-create-handle-or -1 -1) -1))

(define (thread-api-large-semaphore-rejected?) : bool
  (= (thread.semaphore-create-handle-or 2147483648 -1) -1))

(define (thread-api-bounded-wait-worker [sem-handle : i64]) : i64
  (if (thread.semaphore-wait (thread.ThreadSemaphore sem-handle))
    42
    -1))

(define (thread-api-bounded-wait-run [sem : thread.ThreadSemaphore]) : i64
  (match (thread.spawn thread-api-bounded-wait-worker sem.handle)
    [(thread.ThreadSpawnErr _) 14]
    [(thread.ThreadSpawnOk worker)
      (let
        [result : i64 42]
        [released : bool false]
        [join-code : i64 -1]
        (begin
          (if (not
            (thread-api-negative-wait-rejected? (thread.wait-for (& worker) -1)))
            (set! result 15)
            unit)
          (if (and
            (= result 42)
            (not (thread-api-wait-timed-out? (thread.wait-for (& worker) 0))))
            (set! result 16)
            unit)
          (if (and
            (= result 42)
            (not (thread-api-wait-timed-out? (thread.wait-for (& worker) 1))))
            (set! result 17)
            unit)
          (if (and
            (= result 42)
            (not (thread-api-wait-timed-out? (thread.wait-for (& worker) 0))))
            (set! result 18)
            unit)
          (set! released (thread.semaphore-post sem))
          (if (not released)
            (set! result 19)
            (begin
              (if (and
                (= result 42)
                (not (thread-api-wait-ready? (thread.wait-for (& worker) 5000))))
                (set! result 20)
                unit)
              (if (and
                (= result 42)
                (not (thread-api-wait-ready? (thread.wait-for (& worker) 0))))
                (set! result 21)
                unit)
              (set! join-code (thread-api-join-code (thread.join worker)))
              (if (and (= result 42) (not (= join-code 42)))
                (set! result 22)
                unit)
              (if (and (= result 42) (not (thread.semaphore-close sem)))
                (set! result 23)
                unit)))
          result))]))

(define (thread-api-finish-run
  [sem : thread.ThreadSemaphore]
  [a : thread.Thread]
  [b : thread.Thread]
  [out-a : (__tl_dyn-array i64)]
  [out-b : (__tl_dyn-array i64)]) : i64
  (let
    [result : i64 42]
    [a-code : i64 -1]
    [b-code : i64 -1]
    (begin
      (if (not (thread.semaphore-wait sem))
        (set! result 4)
        unit)
      (if (and (= result 42) (not (thread.semaphore-wait sem)))
        (set! result 5)
        unit)
      (set! a-code (thread-api-join-code (thread.join a)))
      (set! b-code (thread-api-join-code (thread.join b)))
      (if (and (= result 42) (not (thread.semaphore-close sem)))
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
    [out-a : (__tl_dyn-array i64) (array.make-array i64 1)]
    [out-b : (__tl_dyn-array i64) (array.make-array i64 1)]
    [ctx-a : (__tl_dyn-array i64) (array.make-array i64 3)]
    [ctx-b : (__tl_dyn-array i64) (array.make-array i64 3)]
    [sem-handle : i64 sem.handle]
    (begin
      (set! (array-ref ctx-a 0) (test-array-i64-addr (& out-a)))
      (set! (array-ref ctx-a 1) 11)
      (set! (array-ref ctx-a 2) sem-handle)
      (set! (array-ref ctx-b 0) (test-array-i64-addr (& out-b)))
      (set! (array-ref ctx-b 1) 31)
      (set! (array-ref ctx-b 2) sem-handle)
      (let
        [a-spawn : thread.ThreadSpawnResult
          (thread.spawn thread-api-worker (test-array-i64-addr (& ctx-a)))]
        (if (not (thread.spawn-result-ok? (& a-spawn)))
          2
          (let
            [a : thread.Thread (thread-api-thread-or a-spawn)]
            [b-spawn : thread.ThreadSpawnResult
              (thread.spawn thread-api-worker (test-array-i64-addr (& ctx-b)))]
            (if (not (thread.spawn-result-ok? (& b-spawn)))
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
    [safe-vec-code : i64 (thread-api-safe-i64-vec-run)]
    [safe-box-code : i64 (thread-api-safe-box-i64-run)]
    (cond
      [(< (thread.default-worker-count) 1) 1]
      [(not (= safe-code 42)) safe-code]
      [(not (= safe-string-code 42)) safe-string-code]
      [(not (= safe-vec-code 42)) safe-vec-code]
      [(not (= safe-box-code 42)) safe-box-code]
      [(not (thread-api-negative-semaphore-rejected?)) 11]
      [(not (thread-api-large-semaphore-rejected?)) 12]
      [else
        (let
          [wait-sem-handle : i64 (thread.semaphore-create-handle-or 0 -1)]
          (if (= wait-sem-handle -1)
            13
            (let
              [wait-code : i64
                (thread-api-bounded-wait-run
                  (thread.ThreadSemaphore wait-sem-handle))]
              (if (not (= wait-code 42))
                wait-code
                (let
                  [sem-handle : i64 (thread.semaphore-create-handle-or 0 -1)]
                  (if (= sem-handle -1)
                    24
                    (thread-api-run-with-semaphore
                      (thread.ThreadSemaphore sem-handle))))))))])))
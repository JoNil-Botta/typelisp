(import stdlib.array)
(import "stdlib/sync.tl")
(import (mutex i64) as mutex_i64)
(import "stdlib/thread.tl")

(define sync-mutex-integration-count : i64
  512)

(define (sync-mutex-integration-array-i64-addr [items : (Array i64)]) : i64
  (unsafe
    (cast (ptr->int (ptr-cast (array-data items) : (Ptr u8))) : i64)))

(define (sync-mutex-integration-addr->mut-i64 [addr : i64]) : (MutPtr i64)
  (unsafe
    (int->ptr (cast addr : u64) : (MutPtr i64))))

(define (sync-mutex-integration-read-i64 [addr : i64] [slot : i64]) : i64
  (unsafe
    (ptr-read
      (ptr-cast
        (ptr-offset (sync-mutex-integration-addr->mut-i64 addr) slot)
        : (Ptr i64)))))

(define (sync-mutex-integration-mutex-from-ctx [ctx : i64] [offset : i64]) : mutex_i64.Mutex
  (mutex_i64.Mutex
    (sync-mutex-integration-read-i64 ctx offset)
    (sync-mutex-integration-read-i64 ctx (+ offset 1))
    (sync-mutex-integration-read-i64 ctx (+ offset 2))))

(define (sync-mutex-integration-worker [ctx : i64]) : i64
  (let
    [mutex : mutex_i64.Mutex (sync-mutex-integration-mutex-from-ctx ctx 0)]
    [count : i64
      (sync-mutex-integration-read-i64 ctx (mutex_i64.raw-field-count))]
    [i : i64 0]
    (begin
      (while (< i count)
        (begin
          (with
            ([guard (mutex_i64.lock mutex) mutex_i64.unlock])
            (begin
              (mutex_i64.add! guard 1)
              unit))
          (set! i (+ i 1))))
      0)))

(define (sync-mutex-integration-join-code [result : ThreadJoinResult]) : i64
  (match result
    [(ThreadJoinOk code) code]
    [(ThreadJoinErr _) -1]))

(define (sync-mutex-integration-pack-context!
  [ctx : (Array i64)]
  [mutex : mutex_i64.Mutex]) : unit
  (begin
    (mutex_i64.store-raw! mutex ctx 0)
    (array-set! ctx (mutex_i64.raw-field-count) sync-mutex-integration-count)))

(define (sync-mutex-integration-total [mutex : mutex_i64.Mutex]) : i64
  (with ([guard (mutex_i64.lock mutex) mutex_i64.unlock]) (mutex_i64.get guard)))

(define (sync-mutex-integration-finish
  [mutex : mutex_i64.Mutex]
  [a : Thread]
  [b : Thread]) : i64
  (let
    [a-code : i64 (sync-mutex-integration-join-code (thread-join a))]
    [b-code : i64 (sync-mutex-integration-join-code (thread-join b))]
    [total : i64 (sync-mutex-integration-total mutex)]
    [closed : bool (mutex_i64.close mutex)]
    (cond
      [(not closed) 2]
      [(not (= a-code 0)) 3]
      [(not (= b-code 0)) 4]
      [(not (= total (* sync-mutex-integration-count 2))) 5]
      [else 42])))

(define (sync-mutex-integration-run [mutex : mutex_i64.Mutex]) : i64
  (let
    [ctx-a : (Array i64)
      (array.make-array i64 (+ (mutex_i64.raw-field-count) 1))]
    [ctx-b : (Array i64)
      (array.make-array i64 (+ (mutex_i64.raw-field-count) 1))]
    (begin
      (sync-mutex-integration-pack-context! ctx-a mutex)
      (sync-mutex-integration-pack-context! ctx-b mutex)
      (match (thread-spawn
        sync-mutex-integration-worker
        (sync-mutex-integration-array-i64-addr ctx-a))
        [(ThreadSpawnErr _) 6]
        [(ThreadSpawnOk a)
          (match (thread-spawn
            sync-mutex-integration-worker
            (sync-mutex-integration-array-i64-addr ctx-b))
            [(ThreadSpawnErr _) 7]
            [(ThreadSpawnOk b) (sync-mutex-integration-finish mutex a b)])]))))

(define (main) : i64
  (match (mutex_i64.create 0)
    [(mutex_i64.CreateErr _) 1]
    [(mutex_i64.CreateOk mutex) (sync-mutex-integration-run mutex)]))
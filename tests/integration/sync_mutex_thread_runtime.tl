(import stdlib.sync)
(import (sync.mutex i64) as mutex_i64)
(import stdlib.thread)

;; Two workers increment one checked mutex through handles transferred as raw
;; words. A start barrier makes both contend from their first lock; the main
;; thread's handle closes the mutex only after both joins.
(define sync-mutex-integration-count : i64
  2048)

;: Context words: the worker's transferred handle, its increment count, and the
;: shared start-barrier arrival counter's address.
(define sync-mutex-integration-context-words : i64
  3)

(defmacro (sync-mutex-integration-array-i64-addr [items : Expr]) : i64
  `(unsafe
    (cast (ptr->int (ptr-cast (__tl_array-data ,items) : (Ptr u8))) : i64)))

(define (sync-mutex-integration-addr->mut-i64 [addr : i64]) : (MutPtr i64)
  (unsafe
    (int->ptr (cast addr : u64) : (MutPtr i64))))

(define (sync-mutex-integration-read-i64 [addr : i64] [slot : i64]) : i64
  (unsafe
    (ptr-read
      (ptr-cast
        (ptr-offset (sync-mutex-integration-addr->mut-i64 addr) slot)
        : (Ptr i64)))))

;: Arrive at the start barrier and spin until both workers have arrived.
(define (sync-mutex-integration-barrier! [barrier : i64]) : unit
  (begin
    (unsafe
      (sync.atomic-i64-fetch-add! barrier 0 1))
    (while (<
      (unsafe
        (sync.atomic-i64-load barrier 0))
      2)
      unit)))

(define (sync-mutex-integration-worker [ctx : i64]) : i64
  (let
    [words : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [count : i64 (sync-mutex-integration-read-i64 ctx 1)]
    [barrier : i64 (sync-mutex-integration-read-i64 ctx 2)]
    (begin
      (set! (array-ref words 0) (sync-mutex-integration-read-i64 ctx 0))
      (with
        ([mutex
            (unsafe
              (mutex_i64.load-raw words 0))
            mutex_i64.release])
        (let
          [i : i64 0]
          (begin
            (sync-mutex-integration-barrier! barrier)
            (while (< i count)
              (begin
                (with
                  ([guard (mutex_i64.lock (& mutex)) mutex_i64.unlock])
                  (begin
                    (mutex_i64.add! guard 1)
                    unit))
                (set! i (+ i 1))))
            0))))))

(define (sync-mutex-integration-join-code [result : ThreadJoinResult]) : i64
  (match result
    [(ThreadJoinOk code) code]
    [(ThreadJoinErr _) -1]))

;: Store a fresh transferred handle, the count and the barrier address.
(define (sync-mutex-integration-pack-context!
  [ctx : (&mut ctx (__tl_dyn-array i64))]
  [mutex : (& mutex mutex_i64.Mutex)]
  [barrier : i64]) : bool
  (let
    [stored : bool
      (unsafe
        (mutex_i64.store-raw! mutex ctx 0))]
    (begin
      (set! (array-ref ctx 1) sync-mutex-integration-count)
      (set! (array-ref ctx 2) barrier)
      stored)))

(define (sync-mutex-integration-total [mutex : (& mutex mutex_i64.Mutex)]) : i64
  (with ([guard (mutex_i64.lock mutex) mutex_i64.unlock]) (mutex_i64.get guard)))

(define (sync-mutex-integration-finish
  [mutex : (& mutex mutex_i64.Mutex)]
  [a : Thread]
  [b : Thread]) : i64
  (let
    [a-code : i64
      (sync-mutex-integration-join-code
        (unsafe
          (thread.join a)))]
    [b-code : i64
      (sync-mutex-integration-join-code
        (unsafe
          (thread.join b)))]
    [total : i64 (sync-mutex-integration-total mutex)]
    [closed : bool (mutex_i64.close mutex)]
    (cond
      [(not closed) 2]
      [(not (= a-code 0)) 3]
      [(not (= b-code 0)) 4]
      [(not (= total (* sync-mutex-integration-count 2))) 5]
      [else 42])))

(define (sync-mutex-integration-run [mutex : (& mutex mutex_i64.Mutex)]) : i64
  (let
    [ctx-a : (__tl_dyn-array i64)
      (__tl_make-array i64 sync-mutex-integration-context-words)]
    [ctx-b : (__tl_dyn-array i64)
      (__tl_make-array i64 sync-mutex-integration-context-words)]
    [barrier-cell : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [barrier : i64 (sync-mutex-integration-array-i64-addr barrier-cell)]
    (if (not
      (and
        (sync-mutex-integration-pack-context! (&mut ctx-a) mutex barrier)
        (sync-mutex-integration-pack-context! (&mut ctx-b) mutex barrier)))
      8
      (match (unsafe
        (thread.spawn
          sync-mutex-integration-worker
          (sync-mutex-integration-array-i64-addr ctx-a)))
        [(ThreadSpawnErr _) 6]
        [(ThreadSpawnOk a)
          (match (unsafe
            (thread.spawn
              sync-mutex-integration-worker
              (sync-mutex-integration-array-i64-addr ctx-b)))
            [(ThreadSpawnErr _) 7]
            [(ThreadSpawnOk b) (sync-mutex-integration-finish mutex a b)])]))))

(define (main) : i64
  (match (mutex_i64.create 0)
    [(mutex_i64.CreateErr _) 1]
    [(mutex_i64.CreateOk mutex) (sync-mutex-integration-run (& mutex))]))
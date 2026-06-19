(import "stdlib/thread.tl")

(define atomic-counter-iterations : i64
  128)

(define (atomic-counter-array-i64-addr [items : (Array i64)]) : i64
  (unsafe
    (cast (ptr->int (ptr-cast (array-data items) : (Ptr u8))) : i64)))

(define (atomic-counter-addr->mut-i64 [addr : i64]) : (MutPtr i64)
  (unsafe
    (int->ptr (cast addr : u64) : (MutPtr i64))))

(define (atomic-counter-read-slot [ctx : i64] [slot : i64]) : i64
  (unsafe
    (ptr-read
      (ptr-cast
        (ptr-offset (atomic-counter-addr->mut-i64 ctx) slot)
        : (Ptr i64)))))

(define (atomic-counter-write-slot!
  [ctx : (Array i64)]
  [slot : i64]
  [value : i64]) : unit
  (array-set! ctx slot value))

(define (atomic-counter-worker [ctx : i64]) : i64
  (let
    [counter : (MutPtr i64)
      (atomic-counter-addr->mut-i64 (atomic-counter-read-slot ctx 0))]
    [limit : i64 (atomic-counter-read-slot ctx 1)]
    [i : i64 0]
    (begin
      (while (< i limit)
        (begin
          (unsafe
            (atomic-fetch-add! counter 1))
          (set! i (+ i 1))))
      0)))

(define (atomic-counter-join-code [result : ThreadJoinResult]) : i64
  (match result
    [(ThreadJoinOk code) code]
    [(ThreadJoinErr _) -1]))

(define (atomic-counter-final-value [counter : (Array i64)]) : i64
  (unsafe
    (atomic-load (array-data counter))))

(define (atomic-counter-finish
  [counter : (Array i64)]
  [a : Thread]
  [b : Thread]) : i64
  (let
    [a-code : i64 (atomic-counter-join-code (thread-join a))]
    [b-code : i64 (atomic-counter-join-code (thread-join b))]
    [value : i64 (atomic-counter-final-value counter)]
    (cond
      [(not (= a-code 0)) 1]
      [(not (= b-code 0)) 2]
      [(not (= value (* atomic-counter-iterations 2))) 3]
      [else 42])))

(define (main) : i64
  (let
    [counter : (Array i64) (make-array i64 1)]
    [ctx-a : (Array i64) (make-array i64 2)]
    [ctx-b : (Array i64) (make-array i64 2)]
    [counter-addr : i64 (atomic-counter-array-i64-addr counter)]
    (begin
      (array-set! counter 0 0)
      (atomic-counter-write-slot! ctx-a 0 counter-addr)
      (atomic-counter-write-slot! ctx-a 1 atomic-counter-iterations)
      (atomic-counter-write-slot! ctx-b 0 counter-addr)
      (atomic-counter-write-slot! ctx-b 1 atomic-counter-iterations)
      (match (thread-spawn
        atomic-counter-worker
        (atomic-counter-array-i64-addr ctx-a))
        [(ThreadSpawnErr _) 4]
        [(ThreadSpawnOk a)
          (match (thread-spawn
            atomic-counter-worker
            (atomic-counter-array-i64-addr ctx-b))
            [(ThreadSpawnErr _) 5]
            [(ThreadSpawnOk b) (atomic-counter-finish counter a b)])]))))
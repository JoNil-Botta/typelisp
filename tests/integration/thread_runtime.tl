(import "stdlib/thread.tl")

(define (integration-array-i64-addr [items : (Array i64)]) : i64
  (unsafe
    (cast (ptr->int (ptr-cast (array-data items) : (Ptr u8))) : i64)))

(define (integration-addr->mut-i64 [addr : i64]) : (MutPtr i64)
  (unsafe
    (int->ptr (cast addr : u64) : (MutPtr i64))))

(define (integration-read-i64 [addr : i64] [slot : i64]) : i64
  (unsafe
    (ptr-read
      (ptr-cast (ptr-offset (integration-addr->mut-i64 addr) slot) : (Ptr i64)))))

(define (integration-write-i64! [addr : i64] [slot : i64] [value : i64]) : unit
  (unsafe
    (ptr-write! (ptr-offset (integration-addr->mut-i64 addr) slot) value)))

(define (integration-worker [ctx : i64]) : i64
  (let
    [out-addr : i64 (integration-read-i64 ctx 0)]
    [value : i64 (integration-read-i64 ctx 1)]
    (begin
      (integration-write-i64! out-addr 0 value)
      value)))

(define (integration-join-code [result : ThreadJoinResult]) : i64
  (match result
    [(ThreadJoinOk code) code]
    [(ThreadJoinErr _) -1]))

(define (main) : i64
  (let
    [out : (Array i64) (make-array i64 1)]
    [ctx : (Array i64) (make-array i64 2)]
    (begin
      (array-set! ctx 0 (integration-array-i64-addr out))
      (array-set! ctx 1 42)
      (if (< (thread-default-worker-count) 1)
        1
        (match (thread-spawn
          integration-worker
          (integration-array-i64-addr ctx))
          [(ThreadSpawnErr _) 2]
          [(ThreadSpawnOk thread)
            (let
              [code : i64 (integration-join-code (thread-join thread))]
              (if (not (= code 42))
                3
                (array-ref out 0)))])))))
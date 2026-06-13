(import "stdlib/sync.tl")

(import "stdlib/thread.tl")

(define sync-integration-count : i64
  64)

(define (sync-integration-array-i64-addr [items : (Array i64)]) : i64
  (unsafe
    (cast (ptr->int (ptr-cast (array-data items) : (Ptr u8))) : i64)))

(define (sync-integration-addr->mut-i64 [addr : i64]) : (MutPtr i64)
  (unsafe
    (int->ptr (cast addr : u64) : (MutPtr i64))))

(define (sync-integration-read-i64 [addr : i64] [slot : i64]) : i64
  (unsafe
    (ptr-read
      (ptr-cast
        (ptr-offset (sync-integration-addr->mut-i64 addr) slot)
        : (Ptr i64)))))

(define (sync-integration-channel-from-ctx [ctx : i64] [offset : i64]) : ChannelI64
  (ChannelI64
    (sync-integration-read-i64 ctx offset)
    (sync-integration-read-i64 ctx (+ offset 1))
    (sync-integration-read-i64 ctx (+ offset 2))
    (sync-integration-read-i64 ctx (+ offset 3))
    (sync-integration-read-i64 ctx (+ offset 4))
    (sync-integration-read-i64 ctx (+ offset 5))
    (sync-integration-read-i64 ctx (+ offset 6))))

(define (sync-integration-send-ok? [result : ChannelI64SendResult]) : bool
  (match result
    [(ChannelI64SendOk) true]
    [(ChannelI64SendErr _) false]))

(define (sync-integration-recv-value-or
  [result : ChannelI64RecvResult]
  [fallback : i64]) : i64
  (match result
    [(ChannelI64RecvOk value) value]
    [(ChannelI64RecvErr _) fallback]))

(define (sync-integration-sum [base : i64] [count : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (begin
      (while (< i count)
        (begin
          (set! sum (+ sum (+ base i)))
          (set! i (+ i 1))))
      sum)))

(define (sync-integration-producer [ctx : i64]) : i64
  (let
    [channel : ChannelI64 (sync-integration-channel-from-ctx ctx 0)]
    [base : i64 (sync-integration-read-i64 ctx channel-i64-raw-field-count)]
    [count : i64
      (sync-integration-read-i64 ctx (+ channel-i64-raw-field-count 1))]
    [i : i64 0]
    [sum : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< i count))
        (let
          [value : i64 (+ base i)]
          (begin
            (if (sync-integration-send-ok? (channel-i64-send channel value))
              (begin
                (set! sum (+ sum value))
                (set! i (+ i 1)))
              (set! ok false)))))
      (if ok
        sum
        -1))))

(define (sync-integration-join-code [result : ThreadJoinResult]) : i64
  (match result
    [(ThreadJoinOk code) code]
    [(ThreadJoinErr _) -1]))

(define (sync-integration-pack-context!
  [ctx : (Array i64)]
  [channel : ChannelI64]
  [base : i64]
  [count : i64]) : unit
  (begin
    (channel-i64-store-raw! channel ctx 0)
    (array-set! ctx channel-i64-raw-field-count base)
    (array-set! ctx (+ channel-i64-raw-field-count 1) count)))

(define (sync-integration-receive-sum [channel : ChannelI64] [count : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< i count))
        (let
          [value : i64
            (sync-integration-recv-value-or (channel-i64-recv channel) -1)]
          (if (< value 0)
            (set! ok false)
            (begin
              (set! sum (+ sum value))
              (set! i (+ i 1))))))
      (if ok
        sum
        -1))))

(define (sync-integration-finish
  [channel : ChannelI64]
  [a : Thread]
  [b : Thread]) : i64
  (let
    [received : i64
      (sync-integration-receive-sum channel (* sync-integration-count 2))]
    [a-code : i64 (sync-integration-join-code (thread-join a))]
    [b-code : i64 (sync-integration-join-code (thread-join b))]
    [a-expected : i64 (sync-integration-sum 100 sync-integration-count)]
    [b-expected : i64 (sync-integration-sum 1000 sync-integration-count)]
    [closed : bool (channel-i64-close channel)]
    (cond
      (not closed)
      2
      (not (= a-code a-expected))
      3
      (not (= b-code b-expected))
      4
      (not (= received (+ a-expected b-expected)))
      5
      42)))

(define (sync-integration-run [channel : ChannelI64]) : i64
  (let
    [ctx-a : (Array i64) (make-array i64 (+ channel-i64-raw-field-count 2))]
    [ctx-b : (Array i64) (make-array i64 (+ channel-i64-raw-field-count 2))]
    (begin
      (sync-integration-pack-context! ctx-a channel 100 sync-integration-count)
      (sync-integration-pack-context! ctx-b channel 1000 sync-integration-count)
      (match (thread-spawn
        sync-integration-producer
        (sync-integration-array-i64-addr ctx-a))
        [(ThreadSpawnErr _) 6]
        [(ThreadSpawnOk a)
          (match (thread-spawn
            sync-integration-producer
            (sync-integration-array-i64-addr ctx-b))
            [(ThreadSpawnErr _) 7]
            [(ThreadSpawnOk b) (sync-integration-finish channel a b)])]))))

(define (main) : i64
  (match (channel-i64-create 8)
    [(ChannelI64CreateErr _) 1]
    [(ChannelI64CreateOk channel) (sync-integration-run channel)]))
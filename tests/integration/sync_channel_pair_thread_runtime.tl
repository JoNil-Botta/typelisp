(import stdlib.array)
(import stdlib.sync)
(import stdlib.thread)

(define sync-pair-integration-count : i64
  64)

(define (sync-pair-integration-array-i64-addr [items : (__tl_dyn-array i64)]) : i64
  (unsafe
    (cast (ptr->int (ptr-cast (array-data items) : (Ptr u8))) : i64)))

(define (sync-pair-integration-addr->mut-i64 [addr : i64]) : (MutPtr i64)
  (unsafe
    (int->ptr (cast addr : u64) : (MutPtr i64))))

(define (sync-pair-integration-read-i64 [addr : i64] [slot : i64]) : i64
  (unsafe
    (ptr-read
      (ptr-cast
        (ptr-offset (sync-pair-integration-addr->mut-i64 addr) slot)
        : (Ptr i64)))))

(define (sync-pair-integration-channel-from-ctx [ctx : i64] [offset : i64]) : sync.ChannelI64PairChannel
  (sync.ChannelI64PairChannel
    (sync-pair-integration-read-i64 ctx offset)
    (sync-pair-integration-read-i64 ctx (+ offset 1))
    (sync-pair-integration-read-i64 ctx (+ offset 2))
    (sync-pair-integration-read-i64 ctx (+ offset 3))
    (sync-pair-integration-read-i64 ctx (+ offset 4))
    (sync-pair-integration-read-i64 ctx (+ offset 5))
    (sync-pair-integration-read-i64 ctx (+ offset 6))))

(define (sync-pair-integration-send-ok?
  [result : sync.ChannelI64PairSendResult]) : bool
  (match result
    [(sync.ChannelI64PairSendOk) true]
    [(sync.ChannelI64PairSendErr _) false]))

(define (sync-pair-integration-recv-value-or
  [result : sync.ChannelI64PairRecvResult]
  [fallback : sync.ChannelI64Pair]) : sync.ChannelI64Pair
  (match result
    [(sync.ChannelI64PairRecvOk value) value]
    [(sync.ChannelI64PairRecvErr _) fallback]))

(define (sync-pair-integration-message-sum [value : sync.ChannelI64Pair]) : i64
  (+ (struct-get value left) (struct-get value right)))

(define (sync-pair-integration-sum [base : i64] [count : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (begin
      (while (< i count)
        (begin
          (set! sum (+ sum (+ (+ base i) i)))
          (set! i (+ i 1))))
      sum)))

(define (sync-pair-integration-producer [ctx : i64]) : i64
  (let
    [channel : sync.ChannelI64PairChannel
      (sync-pair-integration-channel-from-ctx ctx 0)]
    [base : i64
      (sync-pair-integration-read-i64 ctx sync.channel-i64-pair-raw-field-count)]
    [count : i64
      (sync-pair-integration-read-i64
        ctx
        (+ sync.channel-i64-pair-raw-field-count 1))]
    [i : i64 0]
    [sum : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< i count))
        (let
          [message : sync.ChannelI64Pair (sync.ChannelI64Pair (+ base i) i)]
          [value : i64 (sync-pair-integration-message-sum message)]
          (if (sync-pair-integration-send-ok?
            (sync.channel-i64-pair-send channel message))
            (begin
              (set! sum (+ sum value))
              (set! i (+ i 1)))
            (set! ok false))))
      (if ok
        sum
        -1))))

(define (sync-pair-integration-join-code [result : ThreadJoinResult]) : i64
  (match result
    [(ThreadJoinOk code) code]
    [(ThreadJoinErr _) -1]))

(define (sync-pair-integration-pack-context!
  [ctx : (__tl_dyn-array i64)]
  [channel : sync.ChannelI64PairChannel]
  [base : i64]
  [count : i64]) : unit
  (begin
    (sync.channel-i64-pair-store-raw! channel ctx 0)
    (array-set! ctx sync.channel-i64-pair-raw-field-count base)
    (array-set! ctx (+ sync.channel-i64-pair-raw-field-count 1) count)))

(define (sync-pair-integration-receive-sum
  [channel : sync.ChannelI64PairChannel]
  [count : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< i count))
        (let
          [value : sync.ChannelI64Pair
            (sync-pair-integration-recv-value-or
              (sync.channel-i64-pair-recv channel)
              (sync.ChannelI64Pair -1 -1))]
          [message-sum : i64 (sync-pair-integration-message-sum value)]
          (if (< message-sum 0)
            (set! ok false)
            (begin
              (set! sum (+ sum message-sum))
              (set! i (+ i 1))))))
      (if ok
        sum
        -1))))

(define (sync-pair-integration-finish
  [channel : sync.ChannelI64PairChannel]
  [a : Thread]
  [b : Thread]) : i64
  (let
    [received : i64
      (sync-pair-integration-receive-sum
        channel
        (* sync-pair-integration-count 2))]
    [a-code : i64 (sync-pair-integration-join-code (thread.join a))]
    [b-code : i64 (sync-pair-integration-join-code (thread.join b))]
    [a-expected : i64
      (sync-pair-integration-sum 100 sync-pair-integration-count)]
    [b-expected : i64
      (sync-pair-integration-sum 1000 sync-pair-integration-count)]
    [closed : bool (sync.channel-i64-pair-close channel)]
    (cond
      [(not closed) 2]
      [(not (= a-code a-expected)) 3]
      [(not (= b-code b-expected)) 4]
      [(not (= received (+ a-expected b-expected))) 5]
      [else 42])))

(define (sync-pair-integration-run [channel : sync.ChannelI64PairChannel]) : i64
  (let
    [ctx-a : (__tl_dyn-array i64)
      (array.make-array i64 (+ sync.channel-i64-pair-raw-field-count 2))]
    [ctx-b : (__tl_dyn-array i64)
      (array.make-array i64 (+ sync.channel-i64-pair-raw-field-count 2))]
    (begin
      (sync-pair-integration-pack-context!
        ctx-a
        channel
        100
        sync-pair-integration-count)
      (sync-pair-integration-pack-context!
        ctx-b
        channel
        1000
        sync-pair-integration-count)
      (match (thread.spawn
        sync-pair-integration-producer
        (sync-pair-integration-array-i64-addr ctx-a))
        [(ThreadSpawnErr _) 6]
        [(ThreadSpawnOk a)
          (match (thread.spawn
            sync-pair-integration-producer
            (sync-pair-integration-array-i64-addr ctx-b))
            [(ThreadSpawnErr _) 7]
            [(ThreadSpawnOk b) (sync-pair-integration-finish channel a b)])]))))

(define (main) : i64
  (match (sync.channel-i64-pair-create 8)
    [(sync.ChannelI64PairCreateErr _) 1]
    [(sync.ChannelI64PairCreateOk channel) (sync-pair-integration-run channel)]))
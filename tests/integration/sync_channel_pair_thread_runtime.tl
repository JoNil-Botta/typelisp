(import "stdlib/sync.tl")
(import "stdlib/thread.tl")

(define sync-pair-integration-count : i64
  64)

(define (sync-pair-integration-array-i64-addr [items : (Array i64)]) : i64
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

(define (sync-pair-integration-channel-from-ctx [ctx : i64] [offset : i64]) : ChannelI64PairChannel
  (ChannelI64PairChannel
    (sync-pair-integration-read-i64 ctx offset)
    (sync-pair-integration-read-i64 ctx (+ offset 1))
    (sync-pair-integration-read-i64 ctx (+ offset 2))
    (sync-pair-integration-read-i64 ctx (+ offset 3))
    (sync-pair-integration-read-i64 ctx (+ offset 4))
    (sync-pair-integration-read-i64 ctx (+ offset 5))
    (sync-pair-integration-read-i64 ctx (+ offset 6))))

(define (sync-pair-integration-send-ok? [result : ChannelI64PairSendResult]) : bool
  (match result
    [(ChannelI64PairSendOk) true]
    [(ChannelI64PairSendErr _) false]))

(define (sync-pair-integration-recv-value-or
  [result : ChannelI64PairRecvResult]
  [fallback : ChannelI64Pair]) : ChannelI64Pair
  (match result
    [(ChannelI64PairRecvOk value) value]
    [(ChannelI64PairRecvErr _) fallback]))

(define (sync-pair-integration-message-sum [value : ChannelI64Pair]) : i64
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
    [channel : ChannelI64PairChannel
      (sync-pair-integration-channel-from-ctx ctx 0)]
    [base : i64
      (sync-pair-integration-read-i64 ctx channel-i64-pair-raw-field-count)]
    [count : i64
      (sync-pair-integration-read-i64
        ctx
        (+ channel-i64-pair-raw-field-count 1))]
    [i : i64 0]
    [sum : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< i count))
        (let
          [message : ChannelI64Pair (ChannelI64Pair (+ base i) i)]
          [value : i64 (sync-pair-integration-message-sum message)]
          (if (sync-pair-integration-send-ok?
            (channel-i64-pair-send channel message))
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
  [ctx : (Array i64)]
  [channel : ChannelI64PairChannel]
  [base : i64]
  [count : i64]) : unit
  (begin
    (channel-i64-pair-store-raw! channel ctx 0)
    (array-set! ctx channel-i64-pair-raw-field-count base)
    (array-set! ctx (+ channel-i64-pair-raw-field-count 1) count)))

(define (sync-pair-integration-receive-sum
  [channel : ChannelI64PairChannel]
  [count : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< i count))
        (let
          [value : ChannelI64Pair
            (sync-pair-integration-recv-value-or
              (channel-i64-pair-recv channel)
              (ChannelI64Pair -1 -1))]
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
  [channel : ChannelI64PairChannel]
  [a : Thread]
  [b : Thread]) : i64
  (let
    [received : i64
      (sync-pair-integration-receive-sum
        channel
        (* sync-pair-integration-count 2))]
    [a-code : i64 (sync-pair-integration-join-code (thread-join a))]
    [b-code : i64 (sync-pair-integration-join-code (thread-join b))]
    [a-expected : i64
      (sync-pair-integration-sum 100 sync-pair-integration-count)]
    [b-expected : i64
      (sync-pair-integration-sum 1000 sync-pair-integration-count)]
    [closed : bool (channel-i64-pair-close channel)]
    (cond
      [(not closed) 2]
      [(not (= a-code a-expected)) 3]
      [(not (= b-code b-expected)) 4]
      [(not (= received (+ a-expected b-expected))) 5]
      [else 42])))

(define (sync-pair-integration-run [channel : ChannelI64PairChannel]) : i64
  (let
    [ctx-a : (Array i64)
      (make-array i64 (+ channel-i64-pair-raw-field-count 2))]
    [ctx-b : (Array i64)
      (make-array i64 (+ channel-i64-pair-raw-field-count 2))]
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
      (match (thread-spawn
        sync-pair-integration-producer
        (sync-pair-integration-array-i64-addr ctx-a))
        [(ThreadSpawnErr _) 6]
        [(ThreadSpawnOk a)
          (match (thread-spawn
            sync-pair-integration-producer
            (sync-pair-integration-array-i64-addr ctx-b))
            [(ThreadSpawnErr _) 7]
            [(ThreadSpawnOk b) (sync-pair-integration-finish channel a b)])]))))

(define (main) : i64
  (match (channel-i64-pair-create 8)
    [(ChannelI64PairCreateErr _) 1]
    [(ChannelI64PairCreateOk channel) (sync-pair-integration-run channel)]))
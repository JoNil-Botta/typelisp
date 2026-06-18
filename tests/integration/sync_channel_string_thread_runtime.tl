(import "stdlib/arena.tl")
(import "stdlib/sync.tl")
(import "stdlib/thread.tl")
(import "stdlib/string.tl")

(define sync-string-integration-count : i64
  48)

(define (sync-string-integration-array-i64-addr [items : (Array i64)]) : i64
  (unsafe
    (cast (ptr->int (ptr-cast (array-data items) : (Ptr u8))) : i64)))

(define (sync-string-integration-addr->mut-i64 [addr : i64]) : (MutPtr i64)
  (unsafe
    (int->ptr (cast addr : u64) : (MutPtr i64))))

(define (sync-string-integration-read-i64 [addr : i64] [slot : i64]) : i64
  (unsafe
    (ptr-read
      (ptr-cast
        (ptr-offset (sync-string-integration-addr->mut-i64 addr) slot)
        : (Ptr i64)))))

(define (sync-string-integration-channel-from-ctx [ctx : i64] [offset : i64]) : ChannelString
  (ChannelString
    (sync-string-integration-read-i64 ctx offset)
    (sync-string-integration-read-i64 ctx (+ offset 1))
    (sync-string-integration-read-i64 ctx (+ offset 2))
    (sync-string-integration-read-i64 ctx (+ offset 3))
    (sync-string-integration-read-i64 ctx (+ offset 4))
    (sync-string-integration-read-i64 ctx (+ offset 5))
    (sync-string-integration-read-i64 ctx (+ offset 6))))

(define (sync-string-integration-send-ok? [result : ChannelStringSendResult]) : bool
  (match result
    [(ChannelStringSendOk) true]
    [(ChannelStringSendErr _) false]))

(define (sync-string-integration-recv-value-or
  [result : ChannelStringRecvResult]
  [fallback : String]) : String
  (match result
    [(ChannelStringRecvOk value) value]
    [(ChannelStringRecvErr _) fallback]))

(define (sync-string-integration-message [index : i64]) : String
  (string-append "message:" (int->string index)))

(define (sync-string-integration-expected-sum [count : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (begin
      (while (< i count)
        (let
          [message : String (sync-string-integration-message i)]
          (begin
            (set! sum (+ sum (string-length message)))
            (set! i (+ i 1)))))
      sum)))

(define (sync-string-integration-consumer [ctx : i64]) : i64
  (let
    [channel : ChannelString (sync-string-integration-channel-from-ctx ctx 0)]
    [count : i64
      (sync-string-integration-read-i64 ctx channel-string-raw-field-count)]
    [i : i64 0]
    [sum : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< i count))
        (let
          [value : String
            (sync-string-integration-recv-value-or
              (channel-string-recv channel)
              "missing")]
          [expected : String (sync-string-integration-message i)]
          (if (string-eq value expected)
            (begin
              (set! sum (+ sum (string-length value)))
              (set! i (+ i 1)))
            (set! ok false))))
      (if ok
        sum
        -1))))

(define (sync-string-integration-join-code [result : ThreadJoinResult]) : i64
  (match result
    [(ThreadJoinOk code) code]
    [(ThreadJoinErr _) -1]))

(define (sync-string-integration-pack-context!
  [ctx : (Array i64)]
  [channel : ChannelString]
  [count : i64]) : unit
  (begin
    (channel-string-store-raw! channel ctx 0)
    (array-set! ctx channel-string-raw-field-count count)))

(define (sync-string-integration-run [channel : ChannelString]) : i64
  (let
    [owner : i64 (arena-make-atomic)]
    [ctx : (Array i64) (make-array i64 (+ channel-string-raw-field-count 1))]
    [expected : i64
      (sync-string-integration-expected-sum sync-string-integration-count)]
    [sent : i64 0]
    [i : i64 0]
    [ok : bool true]
    (begin
      (sync-string-integration-pack-context!
        ctx
        channel
        sync-string-integration-count)
      (match (thread-spawn
        sync-string-integration-consumer
        (sync-string-integration-array-i64-addr ctx))
        [(ThreadSpawnErr _) 2]
        [(ThreadSpawnOk worker)
          (begin
            (while (and ok (< i sync-string-integration-count))
              (let
                [message-len : i64
                  (string-length (sync-string-integration-message i))]
                [message-sent : bool
                  (sync-string-integration-send-ok?
                    (channel-string-send
                      channel
                      (in-arena owner (sync-string-integration-message i))))]
                (if message-sent
                  (begin
                    (set! sent (+ sent message-len))
                    (set! i (+ i 1)))
                  (set! ok false))))
            (let
              [worker-code : i64
                (sync-string-integration-join-code (thread-join worker))]
              [closed : bool (channel-string-close channel)]
              (cond
                [(not ok) 3]
                [(not closed) 4]
                [(not (= sent expected)) 5]
                [(not (= worker-code expected)) 6]
                [else 42])))]))))

(define (main) : i64
  (match (channel-string-create 4)
    [(ChannelStringCreateErr _) 1]
    [(ChannelStringCreateOk channel) (sync-string-integration-run channel)]))
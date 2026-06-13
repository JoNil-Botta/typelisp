(import "stdlib/sync.tl")

(define (sync-api-create-rejects-invalid?) : bool
  (and
    (match (channel-i64-create 0)
      [(ChannelI64CreateErr _) true]
      [(ChannelI64CreateOk ch)
        (begin
          (channel-i64-close ch)
          false)])
    (match (channel-i64-create (+ channel-i64-max-capacity 1))
      [(ChannelI64CreateErr _) true]
      [(ChannelI64CreateOk ch)
        (begin
          (channel-i64-close ch)
          false)])))

(define (sync-api-send-ok? [result : ChannelI64SendResult]) : bool
  (match result
    [(ChannelI64SendOk) true]
    [(ChannelI64SendErr _) false]))

(define (sync-api-recv-value-or
  [result : ChannelI64RecvResult]
  [fallback : i64]) : i64
  (match result
    [(ChannelI64RecvOk value) value]
    [(ChannelI64RecvErr _) fallback]))

(define (sync-api-run-channel [channel : ChannelI64]) : i64
  (let
    [packed : (Array i64) (make-array i64 channel-i64-raw-field-count)]
    (begin
      (channel-i64-store-raw! channel packed 0)
      (let
        [loaded : ChannelI64 (channel-i64-load-raw packed 0)]
        [send-a : bool (sync-api-send-ok? (channel-i64-send loaded 11))]
        [send-b : bool (sync-api-send-ok? (channel-i64-send loaded 31))]
        [first : i64 (sync-api-recv-value-or (channel-i64-recv loaded) -1)]
        [send-c : bool (sync-api-send-ok? (channel-i64-send loaded 43))]
        [second : i64 (sync-api-recv-value-or (channel-i64-recv loaded) -1)]
        [third : i64 (sync-api-recv-value-or (channel-i64-recv loaded) -1)]
        [closed : bool (channel-i64-close loaded)]
        (if (and
          send-a
          send-b
          send-c
          closed
          (= first 11)
          (= second 31)
          (= third 43))
          42
          2)))))

(define (main) : i64
  (if (not (sync-api-create-rejects-invalid?))
    1
    (match (channel-i64-create 2)
      [(ChannelI64CreateErr _) 3]
      [(ChannelI64CreateOk channel) (sync-api-run-channel channel)])))
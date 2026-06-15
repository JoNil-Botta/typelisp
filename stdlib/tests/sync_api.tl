(import stdlib.sync)

(define (sync-api-create-rejects-invalid?) : bool
  (and
    (match (sync.channel-i64-create 0)
      [(sync.ChannelI64CreateErr _) true]
      [(sync.ChannelI64CreateOk ch)
        (begin
          (sync.channel-i64-close ch)
          false)])
    (match (sync.channel-i64-create (+ sync.channel-i64-max-capacity 1))
      [(sync.ChannelI64CreateErr _) true]
      [(sync.ChannelI64CreateOk ch)
        (begin
          (sync.channel-i64-close ch)
          false)])))

(define (sync-api-send-ok? [result : sync.ChannelI64SendResult]) : bool
  (match result
    [(sync.ChannelI64SendOk) true]
    [(sync.ChannelI64SendErr _) false]))

(define (sync-api-recv-value-or
  [result : sync.ChannelI64RecvResult]
  [fallback : i64]) : i64
  (match result
    [(sync.ChannelI64RecvOk value) value]
    [(sync.ChannelI64RecvErr _) fallback]))

(define (sync-api-run-channel [channel : sync.ChannelI64]) : i64
  (let
    [packed : (Array i64) (make-array i64 sync.channel-i64-raw-field-count)]
    (begin
      (sync.channel-i64-store-raw! channel packed 0)
      (let
        [loaded : sync.ChannelI64 (sync.channel-i64-load-raw packed 0)]
        [send-a : bool (sync-api-send-ok? (sync.channel-i64-send loaded 11))]
        [send-b : bool (sync-api-send-ok? (sync.channel-i64-send loaded 31))]
        [first : i64 (sync-api-recv-value-or (sync.channel-i64-recv loaded) -1)]
        [send-c : bool (sync-api-send-ok? (sync.channel-i64-send loaded 43))]
        [second : i64 (sync-api-recv-value-or (sync.channel-i64-recv loaded) -1)]
        [third : i64 (sync-api-recv-value-or (sync.channel-i64-recv loaded) -1)]
        [closed : bool (sync.channel-i64-close loaded)]
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

(define (sync-api-run-mutex [mutex : sync.MutexI64]) : i64
  (let
    [packed : (Array i64) (make-array i64 sync.mutex-i64-raw-field-count)]
    (begin
      (sync.mutex-i64-store-raw! mutex packed 0)
      (let
        [loaded : sync.MutexI64 (sync.mutex-i64-load-raw packed 0)]
        [first : i64
          (with
            ([guard (sync.mutex-i64-lock loaded) mutex-i64-unlock])
            (begin
              (sync.mutex-i64-set! guard 17)
              (sync.mutex-i64-add! guard 25)))]
        [second : i64
          (with
            ([guard (sync.mutex-i64-lock loaded) mutex-i64-unlock])
            (sync.mutex-i64-get guard))]
        [closed : bool (sync.mutex-i64-close loaded)]
        (if (and closed (= first 42) (= second 42))
          42
          4)))))

(define (main) : i64
  (if (not (sync-api-create-rejects-invalid?))
    1
    (match (sync.channel-i64-create 2)
      [(sync.ChannelI64CreateErr _) 3]
      [(sync.ChannelI64CreateOk channel)
        (let
          [channel-code : i64 (sync-api-run-channel channel)]
          (if (not (= channel-code 42))
            channel-code
            (match (sync.mutex-i64-create 5)
              [(sync.MutexI64CreateErr _) 5]
              [(sync.MutexI64CreateOk mutex) (sync-api-run-mutex mutex)])))])))
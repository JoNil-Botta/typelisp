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

(define (sync-api-run-mutex [mutex : MutexI64]) : i64
  (let
    [packed : (Array i64) (make-array i64 mutex-i64-raw-field-count)]
    (begin
      (mutex-i64-store-raw! mutex packed 0)
      (let
        [loaded : MutexI64 (mutex-i64-load-raw packed 0)]
        [first : i64
          (with
            ([guard (mutex-i64-lock loaded) mutex-i64-unlock])
            (begin
              (mutex-i64-set! guard 17)
              (mutex-i64-add! guard 25)))]
        [second : i64
          (with
            ([guard (mutex-i64-lock loaded) mutex-i64-unlock])
            (mutex-i64-get guard))]
        [live-close-code : i64
          (with
            ([guard (mutex-i64-lock loaded) mutex-i64-unlock])
            (let
              [blocked-close : bool (mutex-i64-close loaded)]
              [after : i64 (mutex-i64-add! guard 1)]
              (if (not blocked-close)
                (if (= after 43)
                  42
                  6)
                6)))]
        [third : i64
          (with
            ([guard (mutex-i64-lock loaded) mutex-i64-unlock])
            (mutex-i64-get guard))]
        [closed : bool (mutex-i64-close loaded)]
        [closed-again : bool (mutex-i64-close loaded)]
        (if (and
          closed
          (not closed-again)
          (= first 42)
          (= second 42)
          (= live-close-code 42)
          (= third 43))
          42
          4)))))

(define (sync-api-close-fresh-mutex?) : bool
  (match (mutex-i64-create 9)
    [(MutexI64CreateErr _) false]
    [(MutexI64CreateOk mutex)
      (let
        [closed : bool (mutex-i64-close mutex)]
        [closed-again : bool (mutex-i64-close mutex)]
        (and closed (not closed-again)))]))

(define (main) : i64
  (cond
    [(not (sync-api-create-rejects-invalid?)) 1]
    [(not (sync-api-close-fresh-mutex?)) 7]
    [else
      (match (channel-i64-create 2)
        [(ChannelI64CreateErr _) 3]
        [(ChannelI64CreateOk channel)
          (let
            [channel-code : i64 (sync-api-run-channel channel)]
            (if (not (= channel-code 42))
              channel-code
              (match (mutex-i64-create 5)
                [(MutexI64CreateErr _) 5]
                [(MutexI64CreateOk mutex) (sync-api-run-mutex mutex)])))])]))
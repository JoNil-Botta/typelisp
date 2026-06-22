(import stdlib.arena)
(import stdlib.sync)
(import stdlib.string)

(define (sync-api-create-rejects-invalid?) : bool
  (and
    (not (sync.channel-i64-create-capacity-ok? 0))
    (not
      (sync.channel-i64-create-capacity-ok? (+ sync.channel-i64-max-capacity 1)))
    (not (sync.channel-string-create-capacity-ok? 0))
    (not
      (sync.channel-string-create-capacity-ok?
        (+ sync.channel-i64-max-capacity 1)))))

(define (sync-api-run-channel [channel : sync.ChannelI64]) : i64
  (let
    [packed : (Array i64) (make-array i64 sync.channel-i64-raw-field-count)]
    (begin
      (sync.channel-i64-store-raw! channel packed 0)
      (let
        [loaded : sync.ChannelI64 (sync.channel-i64-load-raw packed 0)]
        [send-a : bool (sync.channel-i64-send-value-ok? loaded 11)]
        [send-b : bool (sync.channel-i64-send-value-ok? loaded 31)]
        [first : i64 (sync.channel-i64-recv-or loaded -1)]
        [send-c : bool (sync.channel-i64-send-value-ok? loaded 43)]
        [second : i64 (sync.channel-i64-recv-or loaded -1)]
        [third : i64 (sync.channel-i64-recv-or loaded -1)]
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

(define (sync-api-pair-sum [value : sync.ChannelI64Pair]) : i64
  (+ (struct-get value left) (struct-get value right)))

(define (sync-api-run-pair-channel [channel : sync.ChannelI64PairChannel]) : i64
  (let
    [packed : (Array i64)
      (make-array i64 sync.channel-i64-pair-raw-field-count)]
    (begin
      (sync.channel-i64-pair-store-raw! channel packed 0)
      (let
        [loaded : sync.ChannelI64PairChannel
          (sync.channel-i64-pair-load-raw packed 0)]
        [first-msg : sync.ChannelI64Pair (sync.ChannelI64Pair 5 7)]
        [second-msg : sync.ChannelI64Pair (sync.ChannelI64Pair 11 13)]
        [third-msg : sync.ChannelI64Pair (sync.ChannelI64Pair 17 19)]
        [send-a : bool (sync.channel-i64-pair-send-value-ok? loaded first-msg)]
        [send-b : bool (sync.channel-i64-pair-send-value-ok? loaded second-msg)]
        [first : sync.ChannelI64Pair
          (sync.channel-i64-pair-recv-or loaded (sync.ChannelI64Pair -1 -1))]
        [send-c : bool (sync.channel-i64-pair-send-value-ok? loaded third-msg)]
        [second : sync.ChannelI64Pair
          (sync.channel-i64-pair-recv-or loaded (sync.ChannelI64Pair -1 -1))]
        [third : sync.ChannelI64Pair
          (sync.channel-i64-pair-recv-or loaded (sync.ChannelI64Pair -1 -1))]
        [closed : bool (sync.channel-i64-pair-close loaded)]
        (if (and
          send-a
          send-b
          send-c
          closed
          (= (sync-api-pair-sum first) 12)
          (= (sync-api-pair-sum second) 24)
          (= (sync-api-pair-sum third) 36))
          42
          8)))))

(define (sync-api-run-string-channel [channel : sync.ChannelString]) : i64
  (let
    [owner : i64 (arena.arena-make-atomic)]
    [packed : (Array i64) (make-array i64 sync.channel-string-raw-field-count)]
    (begin
      (sync.channel-string-store-raw! channel packed 0)
      (let
        [loaded : sync.ChannelString (sync.channel-string-load-raw packed 0)]
        [send-a : bool
          (sync.channel-string-send-value-ok?
            loaded
            (in-arena owner (string.string-append "alpha" ":one")))]
        [send-b : bool
          (sync.channel-string-send-value-ok?
            loaded
            (in-arena owner (string.string-append "beta" ":two")))]
        [first : String (sync.channel-string-recv-or loaded "missing")]
        [send-c : bool
          (sync.channel-string-send-value-ok?
            loaded
            (in-arena owner (string.string-append "gamma" ":three")))]
        [second : String (sync.channel-string-recv-or loaded "missing")]
        [third : String (sync.channel-string-recv-or loaded "missing")]
        [closed : bool (sync.channel-string-close loaded)]
        (if (and
          send-a
          send-b
          send-c
          closed
          (string.string-eq first "alpha:one")
          (string.string-eq second "beta:two")
          (string.string-eq third "gamma:three"))
          42
          9)))))

(define (sync-api-unlock-mutex-guard [guard : sync.MutexI64Guard]) : unit
  (begin
    (sync.mutex-i64-unlock-handle (sync.mutex-i64-guard-mutex-handle guard))
    (sync.mutex-i64-untrack-user (sync.mutex-i64-guard-control-addr guard))))

(define (sync-api-run-mutex [mutex : sync.MutexI64]) : i64
  (let
    [packed : (Array i64) (make-array i64 sync.mutex-i64-raw-field-count)]
    (begin
      (sync.mutex-i64-store-raw! mutex packed 0)
      (let
        [loaded : sync.MutexI64 (sync.mutex-i64-load-raw packed 0)]
        [first : i64
          (with
            ([guard (sync.mutex-i64-lock loaded) sync-api-unlock-mutex-guard])
            (begin
              (sync.mutex-i64-set! guard 17)
              (sync.mutex-i64-add! guard 25)))]
        [second : i64
          (with
            ([guard (sync.mutex-i64-lock loaded) sync-api-unlock-mutex-guard])
            (sync.mutex-i64-get guard))]
        [live-close-code : i64
          (with
            ([guard (sync.mutex-i64-lock loaded) sync-api-unlock-mutex-guard])
            (let
              [blocked-close : bool (sync.mutex-i64-close loaded)]
              [after : i64 (sync.mutex-i64-add! guard 1)]
              (if (not blocked-close)
                (if (= after 43)
                  42
                  6)
                6)))]
        [third : i64
          (with
            ([guard (sync.mutex-i64-lock loaded) sync-api-unlock-mutex-guard])
            (sync.mutex-i64-get guard))]
        [closed : bool (sync.mutex-i64-close loaded)]
        [closed-again : bool (sync.mutex-i64-close loaded)]
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
  (let
    [mutex : sync.MutexI64
      (sync.mutex-i64-create-initial-or 9 (sync.MutexI64 0 0 0))]
    [closed : bool (sync.mutex-i64-close mutex)]
    [closed-again : bool (sync.mutex-i64-close mutex)]
    (and closed (not closed-again))))

(define (sync-api-run-mutex-create) : i64
  (let
    [mutex : sync.MutexI64
      (sync.mutex-i64-create-initial-or 5 (sync.MutexI64 0 0 0))]
    (sync-api-run-mutex mutex)))

(define (sync-api-run-pair-create) : i64
  (let
    [pair-channel : sync.ChannelI64PairChannel
      (sync.channel-i64-pair-create-capacity-or
        2
        (sync.ChannelI64PairChannel 0 0 0 0 0 0 0))]
    [pair-code : i64 (sync-api-run-pair-channel pair-channel)]
    (if (not (= pair-code 42))
      pair-code
      (sync-api-run-string-create))))

(define (sync-api-run-string-create) : i64
  (let
    [string-channel : sync.ChannelString
      (sync.channel-string-create-capacity-or
        2
        (sync.ChannelString 0 0 0 0 0 0 0))]
    [string-code : i64 (sync-api-run-string-channel string-channel)]
    (if (not (= string-code 42))
      string-code
      (sync-api-run-mutex-create))))

(define (sync-api-run-channel-create) : i64
  (let
    [channel : sync.ChannelI64
      (sync.channel-i64-create-capacity-or 2 (sync.ChannelI64 0 0 0 0 0 0 0))]
    [channel-code : i64 (sync-api-run-channel channel)]
    (if (not (= channel-code 42))
      channel-code
      (sync-api-run-pair-create))))

(define (main) : i64
  (cond
    [(not (sync-api-create-rejects-invalid?)) 1]
    [(not (sync-api-close-fresh-mutex?)) 7]
    [else (sync-api-run-channel-create)]))
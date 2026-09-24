(cfg windows (import stdlib.io))
(cfg windows (import stdlib.net_windows_winsock as winsock))

(cfg
  windows
  (extern (winsock-measure-counter [ticks : (MutPtr i64)]) : i32 (:symbol "QueryPerformanceCounter")))
(cfg
  windows
  (extern (winsock-measure-frequency [ticks : (MutPtr i64)]) : i32 (:symbol "QueryPerformanceFrequency")))

(cfg
  windows
  (define (winsock-measure-now) : i64
    (let
      [ticks : i64 0]
      (if (=
        (winsock-measure-counter
          (unsafe
            (ptr-addr-of ticks)))
        0)
        -1
        ticks))))

;: Keep all 512 successful startups live until the final timestamp, so the
;: warm measurement excludes cleanup and includes one Box/registry insertion.
(cfg
  windows
  (define (winsock-measure-warm-end [remaining : i64]) : i64
    (if (= remaining 0)
      (winsock-measure-now)
      (match (winsock.winsock-acquire)
        [(winsock.WinsockAcquireErr _) -1]
        [(winsock.WinsockAcquired lease)
          (with
            ([owned lease winsock.cleanup-winsock-lease])
            (winsock-measure-warm-end (- remaining 1)))]))))

(cfg
  windows
  (define (winsock-measure) : i64
    (let
      [frequency : i64 0]
      (when
        (=
          (winsock-measure-frequency
            (unsafe
              (ptr-addr-of frequency)))
          0)
        (return 1))
      (when (<= frequency 0) (return 2))
      (let
        [first-start : i64 (winsock-measure-now)]
        [first-end : i64
          (match (winsock.winsock-acquire)
            [(winsock.WinsockAcquireErr _) -1]
            [(winsock.WinsockAcquired lease)
              (with
                ([owned lease winsock.cleanup-winsock-lease])
                (winsock-measure-now))])]
        (when (or (< first-start 0) (< first-end first-start)) (return 3))
        (let
          [warm-start : i64 (winsock-measure-now)]
          [warm-end : i64 (winsock-measure-warm-end 512)]
          (when (or (< warm-start 0) (< warm-end warm-start)) (return 4))
          (io.println
            "winsock first_load_acquire_ns={} warm_acquire_ns_per_call={} samples={}"
            (/ (* (- first-end first-start) 1000000000) frequency)
            (/ (* (- warm-end warm-start) 1000000000) (* frequency 512))
            512)
          42)))))

(define (main) : i64
  (cfg windows (winsock-measure) 42))
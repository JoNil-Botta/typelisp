(import stdlib.time)
(import stdlib.profile)
(import stdlib.thread)
(import (thread.handle i64) as thread_i64)

(define (time-ratio-grid-ok?) : bool
  (let
    [denominator : i64 1]
    [ok : bool true]
    (begin
      (while (and ok (<= denominator 256))
        (let
          [numerator : i64 0]
          (begin
            (while (and ok (< numerator denominator))
              (begin
                (if (not
                  (=
                    (time.timespec-ms 1 1 1 numerator denominator)
                    (/ (* numerator 1000) denominator)))
                  (set! ok false)
                  unit)
                (set! numerator (+ numerator 1))))
            (set! denominator (+ denominator 1)))))
      ok)))

(define (time-conversions-ok?) : bool
  (and
    (time-ratio-grid-ok?)
    (= (time.timespec-ms 0 0 1 0 999999) 0)
    (= (time.timespec-ms 0 0 1 9223372036854775 807000000) 9223372036854775807)
    (= (time.timespec-ms 0 0 1 -1 0) -1)
    (= (time.timespec-ms 0 0 1 0 -1) -1)
    (= (time.timespec-ms 0 0 1 0 1000000000) -1)
    (= (time.timespec-ms 0 0 1 9223372036854775 808000000) -2)
    (= (time.timespec-ms 0 0 1 9223372036854776 0) -2)
    (= (time.timespec-ms 0 -1 1 0 0) -3)
    (= (time.timespec-ms 1 1 1 0 1) 0)
    (= (time.timespec-ms 1 1 1 1 2000) 0)
    (= (time.timespec-ms 1 1 1 1999 2000) 999)
    (= (time.timespec-ms 1 1 1 9223372036854775806 9223372036854775807) 999)
    (= (time.timespec-ms 1 1 1 9223372036854775807 1000) 9223372036854775807)
    (= (time.timespec-ms 1 1 1 9223372036854775807 999) -2)
    (= (time.timespec-ms 1 0 1 0 1) -3)
    (= (time.timespec-ms 1 1 0 0 1) -3)
    (= (time.timespec-ms 1 1 1 -1 1) -1)
    (= (time.timespec-ms 1 1 1 1 0) -1)
    (= (time.timespec-ms 1 1 1 1 -1) -1)
    (= (time.timespec-ms 2 1 1 0 0) -1)
    (= (time.timespec-ms 2 1 1 3577643008 27111902) 0)
    (= (time.timespec-ms 2 1 1 3577653007 27111902) 0)
    (= (time.timespec-ms 2 1 1 3577653008 27111902) 1)
    (= (time.timespec-ms 2 1 1 4294967295 4294967295) 1833029933770955)
    (= (time.timespec-ms 2 1 1 -1 0) -1)
    (= (time.timespec-ms 2 1 1 4294967296 0) -1)))

(define (time-read-series [count : i64]) : i64
  (let
    [index : i64 0]
    [previous : i64 -1]
    [ok : bool true]
    (begin
      (while (< index count)
        (begin
          (match (time.monotonic-ms)
            [(time.OkTimeMs current)
              (begin
                (if (and (>= previous 0) (< current previous))
                  (set! ok false)
                  unit)
                (set! previous current))]
            [(time.ErrTimeMs _) (set! ok false)])
          (set! index (+ index 1))))
      (if ok
        count
        0))))

(define (time-read-worker) : i64
  (time-read-series 2000))

(define (time-unix-read-series [count : i64]) : i64
  (let
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (< index count)
        (begin
          (match (time.unix-ms)
            [(time.OkTimeMs current)
              (if (< current 0)
                (set! ok false)
                unit)]
            [(time.ErrTimeMs _) (set! ok false)])
          (set! index (+ index 1))))
      (if ok
        count
        0))))

(define (time-join-value [worker : thread_i64.Handle]) : i64
  (match (thread_i64.join worker)
    [(thread_i64.I64JoinOk value) value]
    [(thread_i64.I64JoinErr _) -1]))

(define (time-concurrent-reads-ok?) : bool
  (match (thread_i64.spawn
    (lambda () : i64
      (time-read-worker)))
    [(thread_i64.I64SpawnErr _) false]
    [(thread_i64.I64SpawnOk a)
      (match (thread_i64.spawn
        (lambda () : i64
          (time-read-worker)))
        [(thread_i64.I64SpawnErr _) false]
        [(thread_i64.I64SpawnOk b)
          (match (thread_i64.spawn
            (lambda () : i64
              (time-read-worker)))
            [(thread_i64.I64SpawnErr _) false]
            [(thread_i64.I64SpawnOk c)
              (match (thread_i64.spawn
                (lambda () : i64
                  (time-read-worker)))
                [(thread_i64.I64SpawnErr _) false]
                [(thread_i64.I64SpawnOk d)
                  (let
                    [av : i64 (time-join-value a)]
                    [bv : i64 (time-join-value b)]
                    [cv : i64 (time-join-value c)]
                    [dv : i64 (time-join-value d)]
                    (and (= av 2000) (= bv 2000) (= cv 2000) (= dv 2000)))])])])]))

(define (time-allocation-free-reads-ok?) : bool
  (let
    [_warm-monotonic : i64 (time-read-series 100)]
    [_warm-unix : i64 (time-unix-read-series 100)]
    [before-monotonic-total : i64 (profile.alloc-total)]
    [before-monotonic-live : i64 (profile.alloc-live)]
    [monotonic-read : i64 (time-read-series 10000)]
    [after-monotonic-live : i64 (profile.alloc-live)]
    [after-monotonic-total : i64 (profile.alloc-total)]
    [before-unix-total : i64 (profile.alloc-total)]
    [before-unix-live : i64 (profile.alloc-live)]
    [unix-read : i64 (time-unix-read-series 10000)]
    [after-unix-live : i64 (profile.alloc-live)]
    [after-unix-total : i64 (profile.alloc-total)]
    (and
      (= monotonic-read 10000)
      (= unix-read 10000)
      (= after-monotonic-total before-monotonic-total)
      (= after-monotonic-live before-monotonic-live)
      (= after-unix-total before-unix-total)
      (= after-unix-live before-unix-live))))

(define (main) : i64
  (if (and
    (time-conversions-ok?)
    (time-allocation-free-reads-ok?)
    (time-concurrent-reads-ok?))
    42
    1))
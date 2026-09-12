;; Deterministic allocation and throughput fixture for rooted Linux reads.
;; The shell gate runs `reuse`; `chunk` preserves a same-build baseline for
;; before/after measurements without weakening the zero-allocation assertion.
(import stdlib.byte_buf)
(import stdlib.fs_rooted_linux as rooted)
(import stdlib.io)
(import stdlib.profile)
(import stdlib.string)

(define read-request-bytes : i64
  1048576)

(define (print-measurement
  [mode : (& mode str)]
  [expected : i64]
  [reads : i64]
  [consumed : i64]
  [total-delta : i64]
  [live-delta : i64]
  [peak-delta : i64]
  [elapsed : i64]) : unit
  (io.print-format
    "{} {} {} {} {} {} {} {} {}\n"
    mode
    expected
    reads
    consumed
    total-delta
    live-delta
    peak-delta
    elapsed
    (profile.ticks-per-second)))

(define (measure-reuse
  [root-path : (& root-path str)]
  [component : (& component str)]
  [expected : i64]) : i64
  (let
    [outcome : i64 10]
    (begin
      (with
        ([root
            (rooted.linux-rooted-open-root
              root-path
              rooted.linux-rooted-never-cancelled)
            rooted.cleanup-linux-rooted-directory])
        (if (not (rooted.linux-rooted-directory-open? (& root)))
          (set! outcome 10)
          (with
            ([reader
                (rooted.linux-rooted-reopen-file
                  (& root)
                  component
                  rooted.linux-rooted-never-cancelled)
                rooted.cleanup-linux-rooted-read-file])
            (if (not (rooted.linux-rooted-read-file-open? (& reader)))
              (set! outcome 11)
              (let
                [buffer : byte_buf.ByteBuf
                  (byte_buf.from-array (__tl_make-array u8 read-request-bytes))]
                [view : (&mut buffer bytes)
                  (byte_buf.as-mut-bytes (&mut buffer))]
                [_peak-reset : unit (profile.alloc-reset-peak)]
                [before-total : i64 (profile.alloc-total)]
                [before-live : i64 (profile.alloc-live)]
                [before-ticks : i64 (profile.now-ticks)]
                [reads : i64 0]
                [consumed : i64 0]
                [status : i64 0]
                (begin
                  (while (= status 0)
                    (let
                      [result : rooted.FsLinuxRootedReadIntoResult
                        (rooted.linux-rooted-read-file-into!
                          (&mut reader)
                          view
                          read-request-bytes
                          rooted.linux-rooted-never-cancelled)]
                      [count : i64
                        (rooted.linux-rooted-read-into-count (& result))]
                      (begin
                        (set! reads (+ reads 1))
                        (cond
                          [(not
                              (rooted.linux-rooted-result-ok?
                                (rooted.linux-rooted-read-into-operation
                                  (& result))))
                            (set! status 12)]
                          [(rooted.linux-rooted-read-into-eof? (& result))
                            (if (or
                              (not (= count 0))
                              (rooted.linux-rooted-read-into-short? (& result)))
                              (set! status 13)
                              (set! status 42))]
                          [(or (<= count 0) (> count read-request-bytes))
                            (set! status 14)]
                          [else (set! consumed (+ consumed count))]))))
                  (let
                    [after-ticks : i64 (profile.now-ticks)]
                    [after-total : i64 (profile.alloc-total)]
                    [after-live : i64 (profile.alloc-live)]
                    [peak : i64 (profile.alloc-peak)]
                    [total-delta : i64 (- after-total before-total)]
                    [live-delta : i64 (- after-live before-live)]
                    [peak-delta : i64 (- peak before-live)]
                    (begin
                      (print-measurement
                        "reuse"
                        expected
                        reads
                        consumed
                        total-delta
                        live-delta
                        peak-delta
                        (- after-ticks before-ticks))
                      (set!
                        outcome
                        (if (and
                          (= status 42)
                          (= consumed expected)
                          (= total-delta 0)
                          (= live-delta 0)
                          (= peak-delta 0))
                          42
                          (if (= status 42)
                            15
                            status)))))))))))
      outcome)))

(define (measure-chunk
  [root-path : (& root-path str)]
  [component : (& component str)]
  [expected : i64]) : i64
  (let
    [outcome : i64 20]
    (begin
      (with
        ([root
            (rooted.linux-rooted-open-root
              root-path
              rooted.linux-rooted-never-cancelled)
            rooted.cleanup-linux-rooted-directory])
        (if (not (rooted.linux-rooted-directory-open? (& root)))
          (set! outcome 20)
          (with
            ([reader
                (rooted.linux-rooted-reopen-file
                  (& root)
                  component
                  rooted.linux-rooted-never-cancelled)
                rooted.cleanup-linux-rooted-read-file])
            (if (not (rooted.linux-rooted-read-file-open? (& reader)))
              (set! outcome 21)
              (let
                [_peak-reset : unit (profile.alloc-reset-peak)]
                [before-total : i64 (profile.alloc-total)]
                [before-live : i64 (profile.alloc-live)]
                [before-ticks : i64 (profile.now-ticks)]
                [reads : i64 0]
                [consumed : i64 0]
                [status : i64 0]
                (begin
                  (while (= status 0)
                    (let
                      [result : rooted.FsLinuxRootedReadResult
                        (rooted.linux-rooted-read-file-chunk!
                          (&mut reader)
                          read-request-bytes
                          rooted.linux-rooted-never-cancelled)]
                      [operation : rooted.FsLinuxRootedResult
                        (rooted.linux-rooted-read-operation (& result))]
                      [eof : bool (rooted.linux-rooted-read-eof? (& result))]
                      [short : bool
                        (rooted.linux-rooted-read-short? (& result))]
                      [bytes-read : byte_buf.ByteBuf
                        (rooted.linux-rooted-read-bytes result)]
                      [count : i64 (byte_buf.length (& bytes-read))]
                      (begin
                        (set! reads (+ reads 1))
                        (cond
                          [(not (rooted.linux-rooted-result-ok? operation))
                            (set! status 22)]
                          [eof
                            (if (or (not (= count 0)) short)
                              (set! status 23)
                              (set! status 42))]
                          [(or (<= count 0) (> count read-request-bytes))
                            (set! status 24)]
                          [else (set! consumed (+ consumed count))]))))
                  (let
                    [after-ticks : i64 (profile.now-ticks)]
                    [after-total : i64 (profile.alloc-total)]
                    [after-live : i64 (profile.alloc-live)]
                    [peak : i64 (profile.alloc-peak)]
                    (begin
                      (print-measurement
                        "chunk"
                        expected
                        reads
                        consumed
                        (- after-total before-total)
                        (- after-live before-live)
                        (- peak before-live)
                        (- after-ticks before-ticks))
                      (set!
                        outcome
                        (if (and (= status 42) (= consumed expected))
                          42
                          status))))))))))
      outcome)))

(define (main) : i64
  (if (< (io.arg-count) 5)
    2
    (let
      [mode : String (io.arg 1)]
      [root-path : String (io.arg 2)]
      [component : String (io.arg 3)]
      [expected : i64 (string.>int (io.arg 4))]
      (cond
        [(string.eq (& mode) "reuse")
          (measure-reuse (& root-path) (& component) expected)]
        [(string.eq (& mode) "chunk")
          (measure-chunk (& root-path) (& component) expected)]
        [else 3]))))
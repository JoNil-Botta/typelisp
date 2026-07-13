;; counter.tl - Linux inherited user-space retired-instruction launcher.
;;
;; Usage: counter --cpu N -- executable [arg ...]
;; Success prints one tab-separated row:
;; counter <retired> <exit-status> <signal> <time-enabled> <time-running>
(import stdlib.array)
(import stdlib.io)
(import stdlib.str_cat)
(import stdlib.string)

(define perf-attr-size : i64
  128)

;; disabled | inherit | exclude_kernel | exclude_hv | enable_on_exec
(define perf-attr-flags : u64
  (cast 4195 : u64))

(define (array-u8-addr [items : (Array u8)]) : i64
  (unsafe
    (cast (ptr->int (ptr-cast (array-data items) : (Ptr u8))) : i64)))

(define (array-i32-addr [items : (Array i32)]) : i64
  (unsafe
    (cast (ptr->int (ptr-cast (array-data items) : (Ptr u8))) : i64)))

(define (array-u64-addr [items : (Array u64)]) : i64
  (unsafe
    (cast (ptr->int (ptr-cast (array-data items) : (Ptr u8))) : i64)))

(define (program-argv-at [index : i64]) : (Ptr u8)
  (unsafe
    (ptr-read (ptr-offset (program-argv) index))))

(define (program-argv-addr [index : i64]) : i64
  (unsafe
    (cast
      (ptr->int (ptr-cast (ptr-offset (program-argv) index) : (Ptr u8)))
      : i64)))

(define (program-envp-addr) : i64
  (program-argv-addr (+ (program-argc) 1)))

(define (parse-cpu [text : String]) : i64
  (let
    [n : i64 (string-length text)]
    [index : i64 0]
    [value : i64 0]
    [valid : bool (> n 0)]
    (begin
      (while (and valid (< index n))
        (let
          [digit : i64 (- (cast (string-ref text index) : i64) 48)]
          (if (and (>= digit 0) (<= digit 9))
            (begin
              (set! value (+ (* value 10) digit))
              (if (> value 1023)
                (set! valid false)
                unit)
              (set! index (+ index 1)))
            (set! valid false))))
      (if valid
        value
        -1))))

(define (decode-signal [status : i32]) : i64
  (bit-and (cast status : i64) 0x7f))

(define (decode-exit [status : i32]) : i64
  (let
    [signal : i64 (decode-signal status)]
    (if (= signal 0)
      (bit-and (shr (cast status : i64) 8) 0xff)
      (+ 128 signal))))

(define (perf-attr) : (Array u64)
  (let
    [attr : (Array u64) (array.make-array u64 16)]
    (begin
      ;; perf_event_attr starts with u32 type followed by u32 size.
      (array-set! attr 0 (shl (cast perf-attr-size : u64) 32))
      ;; PERF_TYPE_HARDWARE / PERF_COUNT_HW_INSTRUCTIONS.
      (array-set! attr 1 (cast 1 : u64))
      ;; PERF_FORMAT_TOTAL_TIME_ENABLED | PERF_FORMAT_TOTAL_TIME_RUNNING.
      (array-set! attr 4 (cast 3 : u64))
      (array-set! attr 5 perf-attr-flags)
      attr)))

(define (affinity-mask [cpu : i64]) : (Array u64)
  (let
    [mask : (Array u64) (array.make-array u64 16)]
    (begin
      (array-set! mask (/ cpu 64) (shl (cast 1 : u64) (% cpu 64)))
      mask)))

(define (close-fd [fd : i64]) : unit
  (if (>= fd 0)
    (begin
      (unsafe
        (syscall 3 fd))
      unit)
    unit))

(define (child-fail [marker-fd : i64] [marker-addr : i64] [status : i64]) : never
  (begin
    (unsafe
      (syscall 1 marker-fd marker-addr 1))
    (unsafe
      (syscall 60 status))
    (child-fail marker-fd marker-addr status)))

(define (child-run
  [sync-read : i64]
  [sync-write : i64]
  [exec-read : i64]
  [exec-write : i64]
  [devnull : i64]
  [scratch-addr : i64]
  [affinity-addr : i64]
  [exec-addr : i64]
  [argv-addr : i64]
  [envp-addr : i64]) : never
  (begin
    (close-fd sync-write)
    (close-fd exec-read)
    (if (<
      (unsafe
        (syscall 203 0 128 affinity-addr))
      0)
      (child-fail exec-write scratch-addr 125)
      unit)
    ;; Wait until the parent has attached the disabled enable-on-exec event.
    (if (not
      (=
        (unsafe
          (syscall 0 sync-read scratch-addr 1))
        1))
      (child-fail exec-write scratch-addr 125)
      unit)
    (close-fd sync-read)
    (if (>= devnull 0)
      (begin
        (unsafe
          (syscall 33 devnull 0))
        (unsafe
          (syscall 33 devnull 1))
        (unsafe
          (syscall 33 devnull 2))
        (close-fd devnull))
      unit)
    (unsafe
      (syscall 59 exec-addr argv-addr envp-addr))
    (child-fail exec-write scratch-addr 127)))

(define (perf-open-error [error : i64]) : String
  (cond
    [(= error -1)
      "counter: perf_event_open failed with EPERM; check perf_event_paranoid/PMU access"]
    [(= error -13)
      "counter: perf_event_open failed with EACCES; check perf_event_paranoid/PMU access"]
    [(= error -38)
      "counter: perf_event_open failed with ENOSYS; kernel perf events are unavailable"]
    [else
      (str_cat.str-cat
        "counter: perf_event_open failed with raw errno "
        (string.int->string error))]))

(define (kill-and-wait
  [pid : i64]
  [sync-write : i64]
  [status-buffer : (Array i32)]) : unit
  (begin
    (unsafe
      (syscall 62 pid 9))
    (close-fd sync-write)
    (unsafe
      (syscall 61 pid (array-i32-addr status-buffer) 0 0))
    unit))

(define (run-counter [cpu : i64]) : i64
  (let
    [attr : (Array u64) (perf-attr)]
    [affinity : (Array u64) (affinity-mask cpu)]
    [sync-pipe : (Array i32) (array.make-array i32 2)]
    [exec-pipe : (Array i32) (array.make-array i32 2)]
    [scratch : (Array u8) (array.make-array u8 1)]
    [status-buffer : (Array i32) (array.make-array i32 1)]
    [counter-buffer : (Array u64) (array.make-array u64 3)]
    [devnull-path : (Array u8) (io.c-string "/dev/null")]
    [exec-addr : i64
      (unsafe
        (cast (ptr->int (program-argv-at 4)) : i64))]
    [argv-addr : i64 (program-argv-addr 4)]
    [envp-addr : i64 (program-envp-addr)]
    [sync-status : i64
      (unsafe
        (syscall 293 (array-i32-addr sync-pipe) 524288))]
    [exec-status : i64
      (if (>= sync-status 0)
        (unsafe
          (syscall 293 (array-i32-addr exec-pipe) 524288))
        -1)]
    [devnull : i64
      (if (and (>= sync-status 0) (>= exec-status 0))
        (unsafe
          (syscall 2 (array-u8-addr devnull-path) 2 0))
        -1)]
    (if (or (< sync-status 0) (< exec-status 0) (< devnull 0))
      (begin
        (close-fd (cast (array-ref sync-pipe 0) : i64))
        (close-fd (cast (array-ref sync-pipe 1) : i64))
        (close-fd (cast (array-ref exec-pipe 0) : i64))
        (close-fd (cast (array-ref exec-pipe 1) : i64))
        (close-fd devnull)
        (io.print-error
          "counter: failed to prepare synchronization descriptors")
        2)
      (let
        [sync-read : i64 (cast (array-ref sync-pipe 0) : i64)]
        [sync-write : i64 (cast (array-ref sync-pipe 1) : i64)]
        [exec-read : i64 (cast (array-ref exec-pipe 0) : i64)]
        [exec-write : i64 (cast (array-ref exec-pipe 1) : i64)]
        [pid : i64
          (unsafe
            (syscall 57))]
        (if (< pid 0)
          (begin
            (close-fd sync-read)
            (close-fd sync-write)
            (close-fd exec-read)
            (close-fd exec-write)
            (close-fd devnull)
            (io.print-error "counter: fork failed")
            2)
          (if (= pid 0)
            (child-run
              sync-read
              sync-write
              exec-read
              exec-write
              devnull
              (array-u8-addr scratch)
              (array-u64-addr affinity)
              exec-addr
              argv-addr
              envp-addr)
            (begin
              (close-fd sync-read)
              (close-fd exec-write)
              (close-fd devnull)
              (let
                [event-fd : i64
                  (unsafe
                    (syscall 298 (array-u64-addr attr) pid -1 -1 8))]
                (if (< event-fd 0)
                  (begin
                    (kill-and-wait pid sync-write status-buffer)
                    (close-fd exec-read)
                    (io.print-error (perf-open-error event-fd))
                    2)
                  (begin
                    (array-set! scratch 0 (cast 1 : u8))
                    (let
                      [released : i64
                        (unsafe
                          (syscall 1 sync-write (array-u8-addr scratch) 1))]
                      (begin
                        (close-fd sync-write)
                        (if (not (= released 1))
                          (begin
                            (unsafe
                              (syscall 62 pid 9))
                            unit)
                          unit)
                        (let
                          [waited : i64
                            (unsafe
                              (syscall
                                61
                                pid
                                (array-i32-addr status-buffer)
                                0
                                0))]
                          [exec-failed : i64
                            (unsafe
                              (syscall 0 exec-read (array-u8-addr scratch) 1))]
                          [read-count : i64
                            (unsafe
                              (syscall
                                0
                                event-fd
                                (array-u64-addr counter-buffer)
                                24))]
                          (begin
                            (close-fd exec-read)
                            (close-fd event-fd)
                            (cond
                              [(< waited 0)
                                (begin
                                  (io.print-error "counter: wait4 failed")
                                  2)]
                              [(> exec-failed 0)
                                (begin
                                  (io.print-error
                                    "counter: child setup or execve failed")
                                  2)]
                              [(not (= read-count 24))
                                (begin
                                  (io.print-error
                                    "counter: retired-instruction read failed")
                                  2)]
                              [else
                                (let
                                  [retired : u64 (array-ref counter-buffer 0)]
                                  [enabled : u64 (array-ref counter-buffer 1)]
                                  [running : u64 (array-ref counter-buffer 2)]
                                  [raw-status : i32 (array-ref status-buffer 0)]
                                  [exit-status : i64 (decode-exit raw-status)]
                                  [signal : i64 (decode-signal raw-status)]
                                  (if (or
                                    (= retired (cast 0 : u64))
                                    (= enabled (cast 0 : u64))
                                    (= running (cast 0 : u64))
                                    (not (= enabled running)))
                                    (begin
                                      (io.print-error
                                        "counter: counter was zero, not running, or multiplexed")
                                      2)
                                    (begin
                                      (io.print-string
                                        (str_cat.str-cat
                                          "counter\t"
                                          (string.int->string
                                            (cast retired : i64))
                                          "\t"
                                          (string.int->string exit-status)
                                          "\t"
                                          (string.int->string signal)
                                          "\t"
                                          (string.int->string
                                            (cast enabled : i64))
                                          "\t"
                                          (string.int->string
                                            (cast running : i64))
                                          "\n"))
                                      0)))])))))))))))))))

(define (usage-error) : i64
  (begin
    (io.print-error "usage: counter --cpu N -- executable [arg ...]")
    2))

(define (main) : i64
  (if (and
    (>= (io.arg-count) 5)
    (string.eq (io.arg 1) "--cpu")
    (string.eq (io.arg 3) "--"))
    (let
      [cpu : i64 (parse-cpu (io.arg 2))]
      (if (>= cpu 0)
        (run-counter cpu)
        (usage-error)))
    (usage-error)))

(define (test-assert [condition : bool]) : unit
  (if condition
    unit
    (begin
      (/ 1 0)
      unit)))

(test
  spmd-avx512-counter-pure-helpers
  (begin
    (test-assert (= (parse-cpu "0") 0))
    (test-assert (= (parse-cpu "1023") 1023))
    (test-assert (= (parse-cpu "") -1))
    (test-assert (= (parse-cpu "-1") -1))
    (test-assert (= (parse-cpu "1024") -1))
    (test-assert (= (decode-exit (cast (shl 7 8) : i32)) 7))
    (test-assert (= (decode-exit (cast 4 : i32)) 132))
    (test-assert (= (decode-signal (cast 4 : i32)) 4))
    (test-assert (= perf-attr-flags (cast 4195 : u64)))))
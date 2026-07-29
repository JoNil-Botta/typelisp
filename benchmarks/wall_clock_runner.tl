;; wall_clock_runner.tl - Linux wall-clock child launcher for scripts/bench.sh.
;;
;; Usage: wall-clock-runner STDOUT_FILE STDERR_FILE -- PROGRAM [ARG ...]
;;
;; Success prints:
;;   elapsed-seconds exit-status signal launch-errno
;; as one tab-separated row. A child terminated by a signal reports exit -1.
;; The close-on-exec pipe distinguishes an ordinary exit above 128 from a
;; signal and reports redirect/execve failures without relying on shell status.
(import stdlib.array)
(import stdlib.io)
(import stdlib.profile)
(import stdlib.str_cat)
(import stdlib.string)

(define open-output-flags : i64
  ;; O_WRONLY | O_CREAT | O_TRUNC.
  577)
(define open-output-mode : i64
  ;; 0666, filtered by the caller's umask.
  438)
(define pipe-close-on-exec : i64
  ;; O_CLOEXEC.
  524288)

(define (array-i32-addr [items : (Array i32)]) : i64
  (unsafe
    (cast (ptr->int (ptr-cast (array-data items) : (Ptr u8))) : i64)))

(define (array-i64-addr [items : (Array i64)]) : i64
  (unsafe
    (cast (ptr->int (ptr-cast (array-data items) : (Ptr u8))) : i64)))

(define (array-u8-addr [items : (Array u8)]) : i64
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

(define (close-fd [fd : i64]) : unit
  (if (>= fd 0)
    (begin
      (unsafe
        (syscall 3 fd))
      unit)
    unit))

(define (positive-errno [status : i64]) : i64
  (if (< status 0)
    (- 0 status)
    status))

(define (child-fail
  [exec-write : i64]
  [error-buffer : (Array i64)]
  [status : i64]) : never
  (begin
    (array-set! error-buffer 0 (positive-errno status))
    (unsafe
      (syscall 1 exec-write (array-i64-addr error-buffer) 8))
    (unsafe
      (syscall 60 127))
    (child-fail exec-write error-buffer status)))

(define (close-redirect-fd [fd : i64]) : unit
  (if (> fd 2)
    (close-fd fd)
    unit))

(define (child-run
  [exec-read : i64]
  [exec-write : i64]
  [error-buffer : (Array i64)]
  [stdout-path-addr : i64]
  [stderr-path-addr : i64]
  [exec-addr : i64]
  [argv-addr : i64]
  [envp-addr : i64]) : never
  (begin
    (close-fd exec-read)
    (let
      [stdout-fd : i64
        (unsafe
          (syscall 2 stdout-path-addr open-output-flags open-output-mode))]
      (if (< stdout-fd 0)
        (child-fail exec-write error-buffer stdout-fd)
        (let
          [stderr-fd : i64
            (unsafe
              (syscall 2 stderr-path-addr open-output-flags open-output-mode))]
          (if (< stderr-fd 0)
            (begin
              (close-redirect-fd stdout-fd)
              (child-fail exec-write error-buffer stderr-fd))
            (let
              [stdout-status : i64
                (unsafe
                  (syscall 33 stdout-fd 1))]
              (if (< stdout-status 0)
                (begin
                  (close-redirect-fd stdout-fd)
                  (close-redirect-fd stderr-fd)
                  (child-fail exec-write error-buffer stdout-status))
                (let
                  [stderr-status : i64
                    (unsafe
                      (syscall 33 stderr-fd 2))]
                  (if (< stderr-status 0)
                    (begin
                      (close-redirect-fd stdout-fd)
                      (close-redirect-fd stderr-fd)
                      (child-fail exec-write error-buffer stderr-status))
                    (begin
                      (close-redirect-fd stdout-fd)
                      (close-redirect-fd stderr-fd)
                      (let
                        [exec-status : i64
                          (unsafe
                            (syscall 59 exec-addr argv-addr envp-addr))]
                        (child-fail exec-write error-buffer exec-status)))))))))))
    (child-fail exec-write error-buffer -1)))

(define (read-launch-error [fd : i64] [error-buffer : (Array i64)]) : i64
  (let
    [total : i64 0]
    [done : bool false]
    (begin
      (while (and (not done) (< total 8))
        (let
          [count : i64
            (unsafe
              (syscall 0 fd (+ (array-i64-addr error-buffer) total) (- 8 total)))]
          (cond
            [(= count 0) (set! done true)]
            [(= count -4) unit]
            [(< count 0)
              (begin
                (set! total -1)
                (set! done true))]
            [else (set! total (+ total count))])))
      total)))

(define (wait-child [pid : i64] [status-buffer : (Array i32)]) : i64
  (let
    [waited : i64 -4]
    (begin
      (while (= waited -4)
        (set!
          waited
          (unsafe
            (syscall 61 pid (array-i32-addr status-buffer) 0 0))))
      waited)))

(define (decode-signal [status : i32]) : i64
  (bit-and (cast status : i64) 0x7f))

(define (decode-exit [status : i32]) : i64
  (if (= (decode-signal status) 0)
    (bit-and (shr (cast status : i64) 8) 0xff)
    -1))

(define (pad-nanoseconds [value : i64]) : String
  (let
    [text : String (string.int->string value)]
    (begin
      (while (< (string.string-length text) 9)
        (set! text (str_cat.str-cat "0" text)))
      text)))

(define (render-result
  [elapsed-nanoseconds : i64]
  [exit-status : i64]
  [signal : i64]
  [launch-errno : i64]) : String
  (str_cat.str-cat
    (string.int->string (/ elapsed-nanoseconds 1000000000))
    "."
    (pad-nanoseconds (% elapsed-nanoseconds 1000000000))
    "\t"
    (string.int->string exit-status)
    "\t"
    (string.int->string signal)
    "\t"
    (string.int->string launch-errno)
    "\n"))

(define (run-child) : i64
  (let
    [stdout-path : (Array u8) (io.c-string (io.arg 1))]
    [stderr-path : (Array u8) (io.c-string (io.arg 2))]
    [exec-pipe : (Array i32) (array.make-array i32 2)]
    [error-buffer : (Array i64) (array.make-array i64 1)]
    [status-buffer : (Array i32) (array.make-array i32 1)]
    [pipe-status : i64
      (unsafe
        (syscall 293 (array-i32-addr exec-pipe) pipe-close-on-exec))]
    (if (< pipe-status 0)
      (begin
        (io.print-error "wall-clock-runner: pipe2 failed\n")
        1)
      (let
        [exec-read : i64 (cast (array-ref exec-pipe 0) : i64)]
        [exec-write : i64 (cast (array-ref exec-pipe 1) : i64)]
        [start : i64 (profile.now-ticks)]
        [pid : i64
          (unsafe
            (syscall 57))]
        (if (< pid 0)
          (begin
            (close-fd exec-read)
            (close-fd exec-write)
            (io.print-error "wall-clock-runner: fork failed\n")
            1)
          (if (= pid 0)
            (child-run
              exec-read
              exec-write
              error-buffer
              (array-u8-addr stdout-path)
              (array-u8-addr stderr-path)
              (unsafe
                (cast (ptr->int (program-argv-at 4)) : i64))
              (program-argv-addr 4)
              (program-envp-addr))
            (begin
              (close-fd exec-write)
              (let
                [launch-bytes : i64 (read-launch-error exec-read error-buffer)]
                [waited : i64 (wait-child pid status-buffer)]
                [end : i64 (profile.now-ticks)]
                (begin
                  (close-fd exec-read)
                  (cond
                    [(< launch-bytes 0)
                      (begin
                        (io.print-error
                          "wall-clock-runner: launch-status read failed\n")
                        1)]
                    [(and (not (= launch-bytes 0)) (not (= launch-bytes 8)))
                      (begin
                        (io.print-error
                          "wall-clock-runner: incomplete launch status\n")
                        1)]
                    [(< waited 0)
                      (begin
                        (io.print-error "wall-clock-runner: wait4 failed\n")
                        1)]
                    [(or (= start 0) (= end 0) (< end start))
                      (begin
                        (io.print-error
                          "wall-clock-runner: monotonic clock failed\n")
                        1)]
                    [else
                      (let
                        [raw-status : i32 (array-ref status-buffer 0)]
                        [signal : i64 (decode-signal raw-status)]
                        [exit-status : i64 (decode-exit raw-status)]
                        [launch-errno : i64
                          (if (= launch-bytes 8)
                            (array-ref error-buffer 0)
                            0)]
                        [line : String
                          (render-result
                            (- end start)
                            exit-status
                            signal
                            launch-errno)]
                        (begin
                          (io.print-string line)
                          0))]))))))))))

(define (usage-error) : i64
  (begin
    (io.print-error
      "usage: wall-clock-runner STDOUT_FILE STDERR_FILE -- PROGRAM [ARG ...]\n")
    2))

(define (main) : i64
  (if (and (>= (io.arg-count) 5) (string.eq (io.arg 3) "--"))
    (run-child)
    (usage-error)))

(define (test-assert [condition : bool]) : unit
  (if condition
    unit
    (begin
      (/ 1 0)
      unit)))

(test
  wall-clock-runner-pure-helpers
  (begin
    (test-assert (= (decode-exit (cast (shl 172 8) : i32)) 172))
    (test-assert (= (decode-signal (cast (shl 172 8) : i32)) 0))
    (test-assert (= (decode-exit (cast 15 : i32)) -1))
    (test-assert (= (decode-signal (cast 15 : i32)) 15))
    (test-assert (string.eq (pad-nanoseconds 42) "000000042"))
    (test-assert
      (string.eq (render-result 1234567890 172 0 0) "1.234567890\t172\t0\t0\n"))))
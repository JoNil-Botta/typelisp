;; The canary is genuinely MAP_SHARED across fork. The child runs the
;; production worker protect/clone path on its owned reservation; the parent
;; verifies signal termination and every canary word after the child dies.
(import stdlib.thread)

(define stack-base : i64
  0)
(define heap-sentinel : i64
  0)
(define body-count : i64
  0)

(cfg
  linux-stack-large
  (unsafe
    (define (large-dive [input : (Ptr (Array i64 8192))] [n : i64])
      (:export-symbol "stack_worker_dive") : i64
      (let
        [page : (Array i64 8192)
          (unsafe
            (ptr-read input))]
        [_marked : i64
          (unsafe
            (atomic-fetch-add! (ptr-addr-of body-count) 1))]
        [_stored : unit (set! (array-ref page 0) n)]
        [child : i64
          (unsafe
            (large-dive input (+ n 1)))]
        (+ child (array-ref page 0))))))

(define (dive [n : i64])
  (:export-symbol "stack_worker_small_dive") : i64
  (+ (dive (+ n 1)) n))

(define (worker [_arg : i64]) : i64
  (cfg
    linux-stack-large
    (unsafe
      (large-dive (int->ptr (cast _arg : u64) : (Ptr (Array i64 8192))) 1))
    (dive 1)))

(define (main) : i64
  (let
    [length : i64 (+ (+ thread.default-stack-size 65536) 4096)]
    [base : i64
      (unsafe
        (syscall 9 0 length 0 0x22 -1 0))]
    [control : i64
      (unsafe
        (syscall 9 0 4096 3 0x22 -1 0))]
    [sentinel : (__tl_dyn-array i64) (__tl_make-array i64 512)]
    [input : i64
      (unsafe
        (syscall 9 0 65536 3 0x22 -1 0))]
    (when (or (< base 0) (< control 0)) (return 125))
    (when (< input 0) (return 125))
    ;; MAP_FIXED replaces only the first page of our own reservation.
    (when
      (not
        (=
          (unsafe
            (syscall 9 base 4096 3 0x31 -1 0))
          base))
      (return 125))
    (set! stack-base base)
    (set!
      heap-sentinel
      (unsafe
        (thread.array-i64-addr (& sentinel))))
    (let
      [i : i64 0]
      (while (< i 512)
        (unsafe
          (thread.write-i64! (+ base (* i 8)) 0x1234567812345678))
        (set! (array-ref sentinel i) 0x1234567812345678)
        (+= i 1)))
    (let
      [child : i64
        (unsafe
          (syscall 57))]
      (when (< child 0) (return 125))
      (when
        (= child 0)
        (match (unsafe
          (thread.linux-spawn-protected worker input control (+ base 4096)))
          [(thread.ThreadSpawnErr _)
            (unsafe
              (syscall 231 125))
            unit]
          [(thread.ThreadSpawnOk task)
            (unsafe
              (thread.join task))
            (unsafe
              (syscall 231 126))
            unit])
        (return 126))
      (let
        [status : i64 0]
        [waited : i64
          (unsafe
            (syscall 61 child (cast (ptr->int (ptr-addr-of status)) : i64) 0 0))]
        [unchanged : bool true]
        [i : i64 0]
        (while (< i 512)
          (when
            (not
              (=
                (unsafe
                  (thread.read-i64 (+ base (* i 8))))
                0x1234567812345678))
            (set! unchanged false))
          (+= i 1))
        (unsafe
          (syscall 11 base length))
        (unsafe
          (syscall 11 control 4096))
        (unsafe
          (syscall 11 input 65536))
        (if (and (= waited child) (= (bit-and status 0x7f) 11) unchanged)
          42
          1)))))
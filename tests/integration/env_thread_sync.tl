;; Safe environment mutation is synchronized (#7659). Two consecutive stress jobs
;; run two mutators and a reader concurrently and then require every update to be
;; present with its exact value. On Linux a publication gate parks one mutator
;; after it has built its replacement table and before it publishes it; while it
;; is parked, a lookup, the raw table walk used by process spawning, and a real
;; spawned child must all see the complete previous environment, and a second
;; mutator queued behind the lock must not lose the first one's update.
(import stdlib.env)
(import stdlib.process)
(import stdlib.str_cat)
(import stdlib.string)
(import stdlib.thread)
(import (thread.handle i64) as thread_i64)

(define env-sync-writes-per-worker : i64
  96)
(define env-sync-reads : i64
  1500)

(define (env-sync-name [job : i64] [worker : i64] [index : i64]) : String
  (str_cat.str-cat
    "TL_ENV_SYNC_J"
    (string.int->string job)
    "_W"
    (string.int->string worker)
    "_"
    (string.int->string index)))

(define (env-sync-value [job : i64] [worker : i64] [index : i64]) : String
  (str_cat.str-cat
    "value-"
    (string.int->string (+ (* job 100000) (+ (* worker 1000) index)))))

(define (env-sync-value-is? [name : String] [want : String]) : bool
  (and (env.var-exists? (& name)) (string.eq (env.var-value (& name)) want)))

;; Set each of this worker's names, replace its value, and set and remove a
;; scratch name each round, so set, replace and unset all race the other threads. Returns the
;; number of failed calls.
(define (env-sync-writer [job : i64] [worker : i64]) : i64
  (let
    [index : i64 0]
    [failures : i64 0]
    (begin
      (while (< index env-sync-writes-per-worker)
        (let
          [name : String (env-sync-name job worker index)]
          [scratch : String
            (str_cat.str-cat
              "TL_ENV_SYNC_SCRATCH_W"
              (string.int->string worker))]
          [value : String (env-sync-value job worker index)]
          (begin
            (if (env.set! (& name) "stale")
              unit
              (set! failures (+ failures 1)))
            (if (env.set! (& scratch) "scratch")
              unit
              (set! failures (+ failures 1)))
            (if (env.set! (& name) (& value))
              unit
              (set! failures (+ failures 1)))
            (if (env.unset! (& scratch))
              unit
              (set! failures (+ failures 1)))
            (set! index (+ index 1)))))
      failures)))

;; Read a name no mutator touches while tables are being replaced. Any value
;; other than the exact sentinel means a partial or dangling table was observed.
(define (env-sync-reader) : i64
  (let
    [index : i64 0]
    [bad : i64 0]
    (begin
      (while (< index env-sync-reads)
        (begin
          (if (env-sync-value-is? "TL_ENV_SYNC_SENTINEL" "steady")
            unit
            (set! bad (+ bad 1)))
          (set! index (+ index 1))))
      bad)))

(define (env-sync-join [handle : thread_i64.Handle]) : i64
  (match (thread_i64.join handle)
    [(thread_i64.I64JoinOk value) value]
    [(thread_i64.I64JoinErr _) 1000000]))

(define (env-sync-job-complete? [job : i64]) : bool
  (let
    [worker : i64 1]
    [ok : bool true]
    (begin
      (while (and ok (<= worker 2))
        (let
          [index : i64 0]
          (begin
            (while (and ok (< index env-sync-writes-per-worker))
              (begin
                (set!
                  ok
                  (env-sync-value-is?
                    (env-sync-name job worker index)
                    (env-sync-value job worker index)))
                (set! index (+ index 1))))
            (set! worker (+ worker 1)))))
      (and
        ok
        (not (env.var-exists? "TL_ENV_SYNC_SCRATCH_W1"))
        (not (env.var-exists? "TL_ENV_SYNC_SCRATCH_W2"))))))

;; One stress job: 0 on success, otherwise a small code naming the failed check.
(define (env-sync-stress-job [job : i64]) : i64
  (match (thread_i64.spawn
    (lambda () : i64
      (env-sync-writer job 1)))
    [(thread_i64.I64SpawnErr _) 1]
    [(thread_i64.I64SpawnOk first)
      (match (thread_i64.spawn
        (lambda () : i64
          (env-sync-writer job 2)))
        [(thread_i64.I64SpawnErr _) 2]
        [(thread_i64.I64SpawnOk second)
          (match (thread_i64.spawn
            (lambda () : i64
              (env-sync-reader)))
            [(thread_i64.I64SpawnErr _) 3]
            [(thread_i64.I64SpawnOk reader)
              (let
                [main-bad : i64 (env-sync-reader)]
                [first-failures : i64 (env-sync-join first)]
                [second-failures : i64 (env-sync-join second)]
                [reader-bad : i64 (env-sync-join reader)]
                (cond
                  [(not (= first-failures 0)) 4]
                  [(not (= second-failures 0)) 5]
                  [(not (= reader-bad 0)) 6]
                  [(not (= main-bad 0)) 7]
                  [(not (env-sync-job-complete? job)) 8]
                  [else 0]))])])]))

;; True when the raw table that process spawning loads is complete: terminated,
;; holding the sentinel, and not holding `absent`.
(define (env-sync-raw-table-ok? [absent : String]) : bool
  (let
    [environ : (Ptr (Ptr u8))
      (unsafe
        (env.linux-environ))]
    [index : i64 0]
    [sentinel? : bool false]
    [absent? : bool true]
    [done : bool false]
    (begin
      (while (not done)
        (let
          [entry : (Ptr u8)
            (unsafe
              (ptr-read (ptr-offset environ index)))]
          (if (ptr-null? entry)
            (set! done true)
            (begin
              (if (not
                (ptr-null?
                  (unsafe
                    (env.match-entry "TL_ENV_SYNC_SENTINEL" entry false))))
                (set! sentinel? true)
                unit)
              (if (not
                (ptr-null?
                  (unsafe
                    (env.match-entry (& absent) entry false))))
                (set! absent? false)
                unit)
              (set! index (+ index 1))))))
      (and sentinel? absent?))))

;; A child spawned while a replacement is parked inherits the previous table.
(define (env-sync-child-sees-previous?) : bool
  (match (process.output
    (process.command
      "/bin/sh"
      (process.args-cons
        "-c"
        (process.args-cons
          "printf '%s|%s' \"$TL_ENV_SYNC_GATED\" \"$TL_ENV_SYNC_SENTINEL\""
          (process.args-empty)))))
    [(process.OkProcessOutput output)
      (and
        (= (process.output-status output) 0)
        (string.eq (process.output-stdout output) "|steady"))]
    [(process.ErrProcessOutput _) false]))

(define (env-sync-gate-cell [gate-addr : i64] [cell : i64]) : (MutPtr i64)
  (unsafe
    (ptr-offset (int->ptr (cast gate-addr : u64) : (MutPtr i64)) cell)))

;; Open the gate, join both mutators, remove the gate, and check that neither
;; update was lost. `observed` is the code for what was seen while parked.
(define (env-sync-gated-finish
  [gate-addr : i64]
  [first : thread_i64.Handle]
  [second : thread_i64.Handle]
  [observed : i64]) : i64
  (begin
    (unsafe
      (atomic-store! (env-sync-gate-cell gate-addr 1) 1))
    (unsafe
      (env.linux-futex-wake-all (+ gate-addr 8)))
    (let
      [first-code : i64 (env-sync-join first)]
      [second-code : i64 (env-sync-join second)]
      (begin
        (unsafe
          (env.linux-publication-gate-set! 0))
        (cond
          [(not (= observed 0)) observed]
          [(not (= first-code 0)) 27]
          [(not (= second-code 0)) 28]
          [(not (env-sync-value-is? "TL_ENV_SYNC_GATED" "first")) 29]
          [(not (env-sync-value-is? "TL_ENV_SYNC_QUEUED" "second")) 30]
          [else 0])))))

;; Everything another thread can observe while the first mutator is parked with
;; its replacement built and unpublished: 0, or the code of the first violation.
(define (env-sync-observe-parked) : i64
  (cond
    [(env.var-exists? "TL_ENV_SYNC_GATED") 22]
    [(not (env-sync-value-is? "TL_ENV_SYNC_SENTINEL" "steady")) 23]
    [(not (env-sync-raw-table-ok? "TL_ENV_SYNC_GATED")) 24]
    [(not (env-sync-child-sees-previous?)) 25]
    [else 0]))

;; Linux only: 0 on success, otherwise a code naming the failed check.
(define (env-sync-gated-publication) : i64
  (let
    [gate : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    [_reached : unit (set! (array-ref gate 0) 0)]
    [_open : unit (set! (array-ref gate 1) 0)]
    [gate-addr : i64
      (unsafe
        (cast (ptr->int (ptr-cast (__tl_array-data gate) : (Ptr u8))) : i64))]
    (begin
      (unsafe
        (env.linux-publication-gate-set! gate-addr))
      (match (thread_i64.spawn
        (lambda () : i64
          (if (env.set! "TL_ENV_SYNC_GATED" "first")
            0
            1)))
        [(thread_i64.I64SpawnErr _) 20]
        [(thread_i64.I64SpawnOk first)
          (begin
            ;; Wait until the first mutator has built its table and parked.
            (while (=
              (unsafe
                (atomic-load (env-sync-gate-cell gate-addr 0)))
              0)
              (unsafe
                (env.linux-futex-wait gate-addr 0)))
            (let
              [parked : i64 (env-sync-observe-parked)]
              (match (thread_i64.spawn
                (lambda () : i64
                  (if (env.set! "TL_ENV_SYNC_QUEUED" "second")
                    0
                    1)))
                [(thread_i64.I64SpawnErr _) 21]
                [(thread_i64.I64SpawnOk second)
                  ;; The queued mutator cannot publish while the first one holds
                  ;; the lock, whether or not it has reached the lock yet.
                  (env-sync-gated-finish
                    gate-addr
                    first
                    second
                    (if (and
                      (= parked 0)
                      (env.var-exists? "TL_ENV_SYNC_QUEUED"))
                      26
                      parked))])))]))))

(define (main) : i64
  (if (not (env.set! "TL_ENV_SYNC_SENTINEL" "steady"))
    90
    (let
      [first-job : i64 (env-sync-stress-job 1)]
      [second-job : i64 (env-sync-stress-job 2)]
      [gated : i64 (cfg windows 0 (env-sync-gated-publication))]
      (cond
        [(not (= first-job 0)) first-job]
        [(not (= second-job 0)) (+ 10 second-job)]
        [(not (= gated 0)) gated]
        ;; The first job's updates survive the second job's table replacements.
        [(not (env-sync-job-complete? 1)) 91]
        [else 42]))))
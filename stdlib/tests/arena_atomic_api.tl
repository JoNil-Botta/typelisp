(import stdlib.array)
(import stdlib.arena)
(import stdlib.thread)

;; Four workers retain eight differently sized buffers apiece. The aggregate
;; payload is 134,623,232 bytes (about 128.4 MiB): bounded below 256 MiB while
;; crossing two 64 MiB arena chunk boundaries and exercising both atomic bump
;; reservation and serialized chunk linking.
(define arena-atomic-worker-count : i64
  4)
(define arena-atomic-allocations-per-worker : i64
  8)
(define arena-atomic-publication-count : i64
  (* arena-atomic-worker-count arena-atomic-allocations-per-worker))
(define arena-atomic-allocation-base-elements : i64
  510000)
(define arena-atomic-allocation-worker-step : i64
  1024)
(define arena-atomic-allocation-iteration-step : i64
  4096)

;; The raw thread bridge accepts and returns only i64. These helpers isolate
;; the unsafe conversion used to pass context/publication storage to workers
;; and to inspect retained arena allocations after every worker has joined.
(define (arena-atomic-array-i64-addr [items : (Array i64)]) : i64
  (unsafe
    (cast (ptr->int (ptr-cast (array-data items) : (Ptr u8))) : i64)))

(define (arena-atomic-raw-read [base : i64] [index : i64]) : i64
  (unsafe
    (ptr-read (ptr-offset (int->ptr (cast base : u64) : (Ptr i64)) index))))

(define (arena-atomic-raw-write! [base : i64] [index : i64] [value : i64]) : unit
  (unsafe
    (ptr-write!
      (ptr-offset (int->ptr (cast base : u64) : (MutPtr i64)) index)
      value)))

(define (arena-atomic-raw-load [address : i64]) : i64
  (unsafe
    (atomic-load (int->ptr (cast address : u64) : (Ptr i64)))))

(define (arena-atomic-raw-store! [address : i64] [value : i64]) : unit
  (unsafe
    (atomic-store! (int->ptr (cast address : u64) : (MutPtr i64)) value)))

(define (arena-atomic-allocation-length [worker : i64] [iteration : i64]) : i64
  (+
    arena-atomic-allocation-base-elements
    (+
      (* worker arena-atomic-allocation-worker-step)
      (* iteration arena-atomic-allocation-iteration-step))))

(define (arena-atomic-first-sentinel [worker : i64] [iteration : i64]) : i64
  (+ 1000000 (+ (* worker 1000) (* iteration 2))))

(define (arena-atomic-last-sentinel [worker : i64] [iteration : i64]) : i64
  (+ (arena-atomic-first-sentinel worker iteration) 1))

(define (arena-atomic-publication-slot [worker : i64] [iteration : i64]) : i64
  (+ (* worker arena-atomic-allocations-per-worker) iteration))

(define (arena-atomic-worker-loop
  [worker : i64]
  [iteration : i64]
  [addresses : i64]
  [lengths : i64]) : unit
  (when
    (< iteration arena-atomic-allocations-per-worker)
    (let
      [length : i64 (arena-atomic-allocation-length worker iteration)]
      [items : (Array i64) (array.make-array i64 length)]
      [slot : i64 (arena-atomic-publication-slot worker iteration)]
      (begin
        (array-set! items 0 (arena-atomic-first-sentinel worker iteration))
        (array-set!
          items
          (- length 1)
          (arena-atomic-last-sentinel worker iteration))
        (arena-atomic-raw-write!
          addresses
          slot
          (arena-atomic-array-i64-addr items))
        (arena-atomic-raw-write! lengths slot length)
        (arena-atomic-worker-loop worker (+ iteration 1) addresses lengths)))))

(define (arena-atomic-worker [context : i64]) : i64
  (let
    [owner : i64 (arena-atomic-raw-read context 0)]
    [worker : i64 (arena-atomic-raw-read context 1)]
    [addresses : i64 (arena-atomic-raw-read context 2)]
    [lengths : i64 (arena-atomic-raw-read context 3)]
    [start-gate : i64 (arena-atomic-raw-read context 4)]
    [home : i64 (arena.tl_arena_current)]
    (begin
      (unsafe
        (arena.tl_arena_set owner))
      (while (= (arena-atomic-raw-load start-gate) 0)
        unit)
      (arena-atomic-worker-loop worker 0 addresses lengths)
      (unsafe
        (arena.tl_arena_set home))
      42)))

(define (arena-atomic-context
  [owner : i64]
  [worker : i64]
  [addresses : i64]
  [lengths : i64]
  [start-gate : i64]) : (Array i64)
  (make-array owner worker addresses lengths start-gate))

(define (arena-atomic-thread-or [spawn : thread.ThreadSpawnResult]) : thread.Thread
  (thread.Thread
    (thread.spawn-result-handle-or spawn 0)
    (thread.spawn-result-clear-tid-addr-or spawn 0)
    (thread.spawn-result-result-addr-or spawn 0)))

(define (arena-atomic-join [worker : thread.Thread]) : i64
  (thread.join-result-value-or (thread.join worker) 8))

(define (arena-atomic-validate-slot
  [addresses : i64]
  [lengths : i64]
  [slot : i64]) : i64
  (let
    [worker : i64 (/ slot arena-atomic-allocations-per-worker)]
    [iteration : i64 (% slot arena-atomic-allocations-per-worker)]
    [address : i64 (arena-atomic-raw-read addresses slot)]
    [length : i64 (arena-atomic-raw-read lengths slot)]
    [expected-length : i64 (arena-atomic-allocation-length worker iteration)]
    (cond
      [(or (= address 0) (not (= length expected-length))) 10]
      [(not (= (bit-and address 7) 0)) 11]
      [(!=
          (arena-atomic-raw-read address 0)
          (arena-atomic-first-sentinel worker iteration))
        12]
      [(!=
          (arena-atomic-raw-read address (- length 1))
          (arena-atomic-last-sentinel worker iteration))
        13]
      [else 42])))

(define (arena-atomic-validate-slots
  [addresses : i64]
  [lengths : i64]
  [slot : i64]) : i64
  (if (>= slot arena-atomic-publication-count)
    42
    (let
      [result : i64 (arena-atomic-validate-slot addresses lengths slot)]
      (if (= result 42)
        (arena-atomic-validate-slots addresses lengths (+ slot 1))
        result))))

(define (arena-atomic-validate-right
  [addresses : i64]
  [lengths : i64]
  [left : i64]
  [right : i64]) : i64
  (if (>= right arena-atomic-publication-count)
    42
    (let
      [left-address : i64 (arena-atomic-raw-read addresses left)]
      [left-length : i64 (arena-atomic-raw-read lengths left)]
      [right-address : i64 (arena-atomic-raw-read addresses right)]
      [right-length : i64 (arena-atomic-raw-read lengths right)]
      [left-end : i64 (+ left-address (* left-length 8))]
      [right-end : i64 (+ right-address (* right-length 8))]
      (if (or (<= left-end right-address) (<= right-end left-address))
        (arena-atomic-validate-right addresses lengths left (+ right 1))
        14))))

(define (arena-atomic-validate-pairs
  [addresses : i64]
  [lengths : i64]
  [left : i64]) : i64
  (if (>= left (- arena-atomic-publication-count 1))
    42
    (let
      [result : i64
        (arena-atomic-validate-right addresses lengths left (+ left 1))]
      (if (= result 42)
        (arena-atomic-validate-pairs addresses lengths (+ left 1))
        result))))

(define (arena-atomic-validate [addresses : i64] [lengths : i64]) : i64
  (let
    [slots-result : i64 (arena-atomic-validate-slots addresses lengths 0)]
    (if (= slots-result 42)
      (arena-atomic-validate-pairs addresses lengths 0)
      slots-result)))

(define (arena-atomic-spawn-fourth
  [owner : i64]
  [addresses : i64]
  [lengths : i64]
  [start-gate : i64]
  [first : thread.Thread]
  [second : thread.Thread]
  [third : thread.Thread]) : i64
  (let
    [context : (Array i64)
      (arena-atomic-context owner 3 addresses lengths start-gate)]
    [spawn : thread.ThreadSpawnResult
      (thread.spawn arena-atomic-worker (arena-atomic-array-i64-addr context))]
    (if (not (thread.spawn-result-ok? spawn))
      5
      (let
        [fourth : thread.Thread (arena-atomic-thread-or spawn)]
        [_ : unit (arena-atomic-raw-store! start-gate 1)]
        [first-code : i64 (arena-atomic-join first)]
        [second-code : i64 (arena-atomic-join second)]
        [third-code : i64 (arena-atomic-join third)]
        [fourth-code : i64 (arena-atomic-join fourth)]
        (if (and
          (= first-code 42)
          (= second-code 42)
          (= third-code 42)
          (= fourth-code 42))
          (arena-atomic-validate addresses lengths)
          6)))))

(define (arena-atomic-spawn-third
  [owner : i64]
  [addresses : i64]
  [lengths : i64]
  [start-gate : i64]
  [first : thread.Thread]
  [second : thread.Thread]) : i64
  (let
    [context : (Array i64)
      (arena-atomic-context owner 2 addresses lengths start-gate)]
    [spawn : thread.ThreadSpawnResult
      (thread.spawn arena-atomic-worker (arena-atomic-array-i64-addr context))]
    (if (not (thread.spawn-result-ok? spawn))
      4
      (arena-atomic-spawn-fourth
        owner
        addresses
        lengths
        start-gate
        first
        second
        (arena-atomic-thread-or spawn)))))

(define (arena-atomic-spawn-second
  [owner : i64]
  [addresses : i64]
  [lengths : i64]
  [start-gate : i64]
  [first : thread.Thread]) : i64
  (let
    [context : (Array i64)
      (arena-atomic-context owner 1 addresses lengths start-gate)]
    [spawn : thread.ThreadSpawnResult
      (thread.spawn arena-atomic-worker (arena-atomic-array-i64-addr context))]
    (if (not (thread.spawn-result-ok? spawn))
      3
      (arena-atomic-spawn-third
        owner
        addresses
        lengths
        start-gate
        first
        (arena-atomic-thread-or spawn)))))

(define (arena-atomic-run
  [owner : i64]
  [addresses : i64]
  [lengths : i64]
  [start-gate : i64]) : i64
  (let
    [context : (Array i64)
      (arena-atomic-context owner 0 addresses lengths start-gate)]
    [spawn : thread.ThreadSpawnResult
      (thread.spawn arena-atomic-worker (arena-atomic-array-i64-addr context))]
    (if (not (thread.spawn-result-ok? spawn))
      2
      (arena-atomic-spawn-second
        owner
        addresses
        lengths
        start-gate
        (arena-atomic-thread-or spawn)))))

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make-atomic)]
    [published-addresses : (Array i64)
      (array.make-array i64 arena-atomic-publication-count)]
    [published-lengths : (Array i64)
      (array.make-array i64 arena-atomic-publication-count)]
    [start-gate : (Array i64) (array.make-array i64 1)]
    [start-gate-address : i64 (arena-atomic-array-i64-addr start-gate)]
    [_ : unit (arena-atomic-raw-store! start-gate-address 0)]
    [result : i64
      (arena-atomic-run
        (arena.raw-handle owner)
        (arena-atomic-array-i64-addr published-addresses)
        (arena-atomic-array-i64-addr published-lengths)
        start-gate-address)]
    (begin
      (unsafe
        (arena.destroy owner))
      result)))
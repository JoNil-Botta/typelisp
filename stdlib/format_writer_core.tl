;# Generation-checked registry for stateful Formatter writer cells.
;#
;# A formatter callback receives a scalar token, never a caller-owned cell
;# address.  The registry validates the token generation and canonical writer
;# key under a process-wide lock before lending the address to the writer's
;# checked capability adapter.  Active callbacks own the slot until release;
;# unregister waits for that lease, so a retained cross-thread callback cannot
;# race a caller returning from `format.write!`.
(import stdlib.comptime)
(import stdlib.string)

;: Stable nonzero status returned for forged, stale, wrong-writer, or busy
;: formatter capability tokens.
(define invalid-context-status : i64
  86)

;: Fixed simultaneous-writer capacity. Registration allocates no storage, and
;: callback acquisition is allocation-free.
(define format-writer-registry-capacity : i64
  256)

;: Largest generation whose encoded token remains in positive i64 range.
(define format-writer-registry-max-generation : i64
  36028797018963966)

;: Return the canonical registry key for one nominal writer type.
(defmacro (format-writer-key [T : type]) : String
  (comptime.expr-string
    (comptime.string-append
      (comptime.string-append (type-nominal-module T) "/")
      (type-nominal-name T))))

;: Allocate one initialized process-lifetime scalar table and retain only its
;: raw pointer. Safe importers can copy that opaque pointer but cannot read or
;: mutate the table behind it.
(unsafe
  (define (format-writer-registry-make-i64-table) : (MutPtr i64)
    (let
      [items : (__tl_dyn-array i64)
        (__tl_make-array i64 format-writer-registry-capacity)]
      (unsafe
        (__tl_array-data items)))))

;: Allocate the corresponding initialized canonical-key table.
(unsafe
  (define (format-writer-registry-make-key-table) : (MutPtr String)
    (let
      [items : (__tl_dyn-array String)
        (__tl_make-array String format-writer-registry-capacity)]
      (unsafe
        (__tl_array-data items)))))

;: Registry state: 0 is free, 1 is active, 2 is leased by one callback, 3 is
;: permanently exhausted after the generation bound is reached, and 4 is a
;: leased slot whose owner is waiting to unregister it.
(define format-writer-registry-states : (MutPtr i64)
  (unsafe
    (format-writer-registry-make-i64-table)))
(define format-writer-registry-generations : (MutPtr i64)
  (unsafe
    (format-writer-registry-make-i64-table)))
(define format-writer-registry-addresses : (MutPtr i64)
  (unsafe
    (format-writer-registry-make-i64-table)))
(define format-writer-registry-keys : (MutPtr String)
  (unsafe
    (format-writer-registry-make-key-table)))
(define format-writer-registry-next : i64
  0)
(define format-writer-registry-lock : i64
  0)

;: Read one scalar registry field. Callers own the lock and bounds proof.
(unsafe
  (define (format-writer-registry-i64-ref [items : (MutPtr i64)] [index : i64]) : i64
    (unsafe
      (ptr-read (ptr-cast (ptr-offset items index) : (Ptr i64))))))

;: Write one scalar registry field. Callers own the lock and bounds proof.
(unsafe
  (define (format-writer-registry-i64-set!
    [items : (MutPtr i64)]
    [index : i64]
    [value : i64]) : unit
    (unsafe
      (ptr-write! (ptr-offset items index) value))))

;: Read one canonical writer key. Callers own the lock and bounds proof.
(unsafe
  (define (format-writer-registry-key-ref [index : i64]) : String
    (unsafe
      (ptr-read
        (ptr-cast (ptr-offset format-writer-registry-keys index) : (Ptr String))))))

;: Write one canonical writer key. Callers own the lock and bounds proof.
(unsafe
  (define (format-writer-registry-key-set! [index : i64] [value : String]) : unit
    (unsafe
      (ptr-write! (ptr-offset format-writer-registry-keys index) value))))

;: Runtime abort entry used when every bounded registry slot is active.
(extern (format-writer-registry-abort [message : String]) : never (:symbol "tl_abort_string"))

;: Acquire the process-wide registry lock.
(unsafe
  (define (format-writer-registry-lock!) : unit
    (let
      [lock : (MutPtr i64)
        (unsafe
          (ptr-addr-of format-writer-registry-lock))]
      (while (!=
        (unsafe
          (atomic-cas! lock 0 1))
        0)
        unit))))

;: Release the process-wide registry lock.
(unsafe
  (define (format-writer-registry-unlock!) : unit
    (unsafe
      (atomic-store! (ptr-addr-of format-writer-registry-lock) 0))))

;: Find one reusable slot while the caller owns the registry lock.
(unsafe
  (define (format-writer-registry-find-free-from [start : i64]) : i64
    (let
      [offset : i64 0]
      [found : i64 -1]
      (begin
        (while (and (< offset format-writer-registry-capacity) (< found 0))
          (let
            [slot : i64 (% (+ start offset) format-writer-registry-capacity)]
            (begin
              (if (=
                (unsafe
                  (format-writer-registry-i64-ref
                    format-writer-registry-states
                    slot))
                0)
                (set! found slot)
                unit)
              (set! offset (+ offset 1)))))
        found))))

;: Register one caller-proven live writer-cell address and return an opaque
;: generation token. The address must stay live until `unregister` returns.
(unsafe
  (define (format-writer-register [address : i64] [writer-key : String]) : i64
    (begin
      (unsafe
        (format-writer-registry-lock!))
      (let
        [slot : i64
          (unsafe
            (format-writer-registry-find-free-from format-writer-registry-next))]
        (if (< slot 0)
          (begin
            (unsafe
              (format-writer-registry-unlock!))
            (format-writer-registry-abort
              "format: writer capability registry exhausted"))
          (let
            [previous : i64
              (unsafe
                (format-writer-registry-i64-ref
                  format-writer-registry-generations
                  slot))]
            [generation : i64 (+ previous 1)]
            [token : i64
              (+ (* generation format-writer-registry-capacity) slot)]
            (if (> generation format-writer-registry-max-generation)
              (begin
                (unsafe
                  (format-writer-registry-i64-set!
                    format-writer-registry-states
                    slot
                    3))
                (unsafe
                  (format-writer-registry-unlock!))
                (unsafe
                  (format-writer-register address writer-key)))
              (begin
                (unsafe
                  (format-writer-registry-i64-set!
                    format-writer-registry-generations
                    slot
                    generation))
                (unsafe
                  (format-writer-registry-i64-set!
                    format-writer-registry-addresses
                    slot
                    address))
                (unsafe
                  (format-writer-registry-key-set! slot writer-key))
                (unsafe
                  (format-writer-registry-i64-set!
                    format-writer-registry-states
                    slot
                    1))
                (set!
                  format-writer-registry-next
                  (% (+ slot 1) format-writer-registry-capacity))
                (unsafe
                  (format-writer-registry-unlock!))
                token))))))))

;: Acquire the live, type-matched writer address for one synchronous callback.
;: The returned address is zero when the token is forged, stale, belongs to a
;: different writer type, or is already executing a reentrant/concurrent call.
;: A nonzero return must be paired with one unsafe `release` call.
(unsafe
  (define (format-writer-acquire-address
    [token : i64]
    [expected-key : (& expected str)]) : i64
    (let
      [address : i64 0]
      (begin
        (unsafe
          (format-writer-registry-lock!))
        (if (> token 0)
          (let
            [slot : i64 (% token format-writer-registry-capacity)]
            [generation : i64 (/ token format-writer-registry-capacity)]
            [registered-key : String
              (unsafe
                (format-writer-registry-key-ref slot))]
            (if (and
              (> generation 0)
              (< slot format-writer-registry-capacity)
              (=
                (unsafe
                  (format-writer-registry-i64-ref
                    format-writer-registry-states
                    slot))
                1)
              (=
                (unsafe
                  (format-writer-registry-i64-ref
                    format-writer-registry-generations
                    slot))
                generation)
              (string.eq (& registered-key) expected-key))
              (begin
                (set!
                  address
                  (unsafe
                    (format-writer-registry-i64-ref
                      format-writer-registry-addresses
                      slot)))
                (if (= address 0)
                  unit
                  (unsafe
                    (format-writer-registry-i64-set!
                      format-writer-registry-states
                      slot
                      2))))
              unit))
          unit)
        (unsafe
          (format-writer-registry-unlock!))
        address))))

;: Release a callback lease acquired for `token`.
(unsafe
  (define (format-writer-release [token : i64]) : unit
    (begin
      (unsafe
        (format-writer-registry-lock!))
      (if (> token 0)
        (let
          [slot : i64 (% token format-writer-registry-capacity)]
          [generation : i64 (/ token format-writer-registry-capacity)]
          [registered-generation : i64
            (unsafe
              (format-writer-registry-i64-ref
                format-writer-registry-generations
                slot))]
          [state : i64
            (unsafe
              (format-writer-registry-i64-ref
                format-writer-registry-states
                slot))]
          (if (and
            (> generation 0)
            (< slot format-writer-registry-capacity)
            (= registered-generation generation))
            (if (= state 2)
              (unsafe
                (format-writer-registry-i64-set!
                  format-writer-registry-states
                  slot
                  1))
              (if (= state 4)
                (begin
                  (unsafe
                    (format-writer-registry-i64-set!
                      format-writer-registry-addresses
                      slot
                      0))
                  (unsafe
                    (format-writer-registry-key-set! slot ""))
                  (unsafe
                    (format-writer-registry-i64-set!
                      format-writer-registry-states
                      slot
                      0)))
                unit))
            unit))
        unit)
      (unsafe
        (format-writer-registry-unlock!)))))

;: Invalidate one token after every in-flight callback releases its lease.
;: New acquisitions cannot begin after the locked state transition to free.
(unsafe
  (define (format-writer-unregister [token : i64]) : unit
    (let
      [done : bool false]
      (while (not done)
        (begin
          (unsafe
            (format-writer-registry-lock!))
          (if (> token 0)
            (let
              [slot : i64 (% token format-writer-registry-capacity)]
              [generation : i64 (/ token format-writer-registry-capacity)]
              [registered-generation : i64
                (unsafe
                  (format-writer-registry-i64-ref
                    format-writer-registry-generations
                    slot))]
              [state : i64
                (unsafe
                  (format-writer-registry-i64-ref
                    format-writer-registry-states
                    slot))]
              (if (and
                (> generation 0)
                (< slot format-writer-registry-capacity)
                (= registered-generation generation))
                (if (= state 2)
                  (unsafe
                    (format-writer-registry-i64-set!
                      format-writer-registry-states
                      slot
                      4))
                  (if (= state 4)
                    unit
                    (begin
                      (unsafe
                        (format-writer-registry-i64-set!
                          format-writer-registry-addresses
                          slot
                          0))
                      (unsafe
                        (format-writer-registry-key-set! slot ""))
                      (unsafe
                        (format-writer-registry-i64-set!
                          format-writer-registry-states
                          slot
                          0))
                      (set! done true))))
                (set! done true)))
            (set! done true))
          (unsafe
            (format-writer-registry-unlock!)))))))
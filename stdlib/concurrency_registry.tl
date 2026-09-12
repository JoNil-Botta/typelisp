;# Shared generation-checked authority for native concurrency resources.
;#
;# The registry is deliberately independent of thread and sync OS operations.
;# A resource row owns up to seven raw words, and any number of distinct issued
;# Box authorities can name it. Both the Box address and the slot generation
;# must match before an authority can lease or close a resource. A caller that
;# safely constructs a Box containing a guessed scalar gains no authority.
;#
;# Native adapters are unsafe: they must register only fully constructed
;# resources, release every successful lease, and destroy a detached close
;# claim exactly once. No raw word is exposed by a safe function. Issued Box
;# storage follows the caller's active arena; a cross-thread wrapper must issue
;# in its own spanning atomic arena and keep that owner live through close.
;: One move-only, source-constructible but non-forgeable issued authority.
(defstruct ConcurrencyAuthority
  (:cleanup cleanup-concurrency-authority)
  (token (Box i64) (:cleanup concurrency-authority-token-cleanup)))

;: Checked share result. Sharing issues a fresh Box identity.
(defenum ConcurrencyShareResult
  (:cleanup cleanup-concurrency-share-result)
  (ConcurrencyShared ConcurrencyAuthority (:owned))
  (ConcurrencyShareErr))

;: Internal snapshot returned with a live lease. Raw fields are unsafe-only.
(defstruct ConcurrencyLease
  (ok bool)
  (resource-slot i64)
  (resource-generation i64)
  (family i64)
  (field-count i64)
  (field0 i64)
  (field1 i64)
  (field2 i64)
  (field3 i64)
  (field4 i64)
  (field5 i64)
  (field6 i64)
  (ownership-marker String))

;: Internal exact-once detached resource returned by a successful close.
(defstruct ConcurrencyClaim
  (ok bool)
  (family i64)
  (field-count i64)
  (field0 i64)
  (field1 i64)
  (field2 i64)
  (field3 i64)
  (field4 i64)
  (field5 i64)
  (field6 i64)
  (ownership-marker String))

;: Bounded registry occupancy; Box storage follows each authority's arena.
(defstruct ConcurrencyStats
  (live-resources i64)
  (live-authorities i64)
  (retired-resources i64)
  (retired-authorities i64)
  (active-leases i64))

;: The registry bounds retained memory even when callers retain stale values.
(define concurrency-resource-capacity : i64
  1024)

;: Maximum number of simultaneously issued authority identities.
(define concurrency-authority-capacity : i64
  4096)

;: Last resource generation before permanently retiring a slot.
(define concurrency-max-resource-generation : i64
  9007199254740990)

;: Last authority generation before permanently retiring a slot.
(define concurrency-max-authority-generation : i64
  2251799813685246)

;: Family tags checked by each future safe wrapper.
(define concurrency-family-thread : i64
  1)

;: Registry family assigned to semaphore resources.
(define concurrency-family-semaphore : i64
  2)

;: Registry family assigned to integer channels.
(define concurrency-family-channel-i64 : i64
  3)

;: Registry family assigned to pair channels.
(define concurrency-family-channel-pair : i64
  4)

;: Registry family assigned to string channels.
(define concurrency-family-channel-string : i64
  5)

;: Registry family assigned to integer mutexes.
(define concurrency-family-mutex-i64 : i64
  6)

;: Allocate one initialized program-lifetime registry table.
(unsafe
  (define (concurrency-make-table [count : i64]) : (MutPtr i64)
    (let
      [items : (__tl_dyn-array i64) (__tl_make-array i64 count)]
      (unsafe
        (__tl_array-data items)))))

;: Resource state: 0 free, 1 live, 2 permanently exhausted.
(define concurrency-resource-state : (MutPtr i64)
  (unsafe
    (concurrency-make-table concurrency-resource-capacity)))

;: Generation counters invalidate stale resource-slot references.
(define concurrency-resource-generation : (MutPtr i64)
  (unsafe
    (concurrency-make-table concurrency-resource-capacity)))

;: Family tags prevent authorities from crossing resource kinds.
(define concurrency-resource-family : (MutPtr i64)
  (unsafe
    (concurrency-make-table concurrency-resource-capacity)))

;: Number of live raw words in each resource row.
(define concurrency-resource-field-count : (MutPtr i64)
  (unsafe
    (concurrency-make-table concurrency-resource-capacity)))

;: Outstanding leases that must drain before close can detach a row.
(define concurrency-resource-leases : (MutPtr i64)
  (unsafe
    (concurrency-make-table concurrency-resource-capacity)))

;: Linked-list head for each resource's issued authorities.
(define concurrency-resource-authority-head : (MutPtr i64)
  (unsafe
    (concurrency-make-table concurrency-resource-capacity)))

;: Seven raw words reserved per resource for native adapter payloads.
(define concurrency-resource-fields : (MutPtr i64)
  (unsafe
    (concurrency-make-table (* concurrency-resource-capacity 7))))

;: Authority state: 0 free, 1 live, 2 permanently exhausted.
(define concurrency-authority-state : (MutPtr i64)
  (unsafe
    (concurrency-make-table concurrency-authority-capacity)))

;: Generation counters invalidate reused authority slots.
(define concurrency-authority-generation : (MutPtr i64)
  (unsafe
    (concurrency-make-table concurrency-authority-capacity)))

;: Backing Box address proving the authority was issued by this registry.
(define concurrency-authority-box-address : (MutPtr i64)
  (unsafe
    (concurrency-make-table concurrency-authority-capacity)))

;: Resource slot named by each live authority.
(define concurrency-authority-resource-slot : (MutPtr i64)
  (unsafe
    (concurrency-make-table concurrency-authority-capacity)))

;: Generation of the resource named by each authority.
(define concurrency-authority-resource-generation : (MutPtr i64)
  (unsafe
    (concurrency-make-table concurrency-authority-capacity)))

;: Next issued authority in a resource's linked list.
(define concurrency-authority-next : (MutPtr i64)
  (unsafe
    (concurrency-make-table concurrency-authority-capacity)))

;: Rotating resource-slot allocation cursor.
(define concurrency-next-resource : i64
  0)

;: Rotating authority-slot allocation cursor.
(define concurrency-next-authority : i64
  0)

;: Spin-lock word protecting all registry state.
(define concurrency-lock : i64
  0)

;: Registry word access requires the lock and a previously checked index.
(unsafe
  (define (concurrency-ref [table : (MutPtr i64)] [index : i64]) : i64
    (unsafe
      (ptr-read (ptr-cast (ptr-offset table index) : (Ptr i64))))))

(unsafe
  (define (concurrency-set! [table : (MutPtr i64)] [index : i64] [value : i64]) : unit
    (unsafe
      (ptr-write! (ptr-offset table index) value))))

(unsafe
  (define (concurrency-lock!) : unit
    (let
      [cell : (MutPtr i64)
        (unsafe
          (ptr-addr-of concurrency-lock))]
      (while (!=
        (unsafe
          (atomic-cas! cell 0 1))
        0)
        unit))))

(unsafe
  (define (concurrency-unlock!) : unit
    (unsafe
      (atomic-store! (ptr-addr-of concurrency-lock) 0))))

;: Find one reusable row, starting at a rotating cursor. The caller owns lock.
(unsafe
  (define (concurrency-find-free
    [states : (MutPtr i64)]
    [capacity : i64]
    [start : i64]) : i64
    (let
      [offset : i64 0]
      [found : i64 -1]
      (begin
        (while (and (< offset capacity) (< found 0))
          (let
            [slot : i64 (% (+ start offset) capacity)]
            (begin
              (if (=
                (unsafe
                  (concurrency-ref states slot))
                0)
                (set! found slot)
                unit)
              (set! offset (+ offset 1)))))
        found))))

;: Return the backing address of an owned Box without losing its owner.
(defstruct ConcurrencyBoxIdentity
  (box (Box i64))
  (address i64)
  (token i64))

;: Capture an owned Box together with its address and issued token.
(define (concurrency-owned-box-identity [box : (Box i64)]) : ConcurrencyBoxIdentity
  (let
    [address : i64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of box) : (Ptr i64))))]
    [token : i64 (deref box)]
    (ConcurrencyBoxIdentity box address token)))

;: Inspect a borrowed authority without consuming it. The first read follows
;: the borrowed struct's field place; it does not dereference a raw OS pointer.
(define (concurrency-authority-address
  [authority : (& authority ConcurrencyAuthority)]) : i64
  (let
    [struct-address : i64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of authority) : (Ptr i64))))]
    (unsafe
      (ptr-read (int->ptr (cast struct-address : u64) : (Ptr i64))))))

;: Read the scalar token from a borrowed issued authority.
(define (concurrency-authority-token
  [authority : (& authority ConcurrencyAuthority)]) : i64
  (deref authority.token))

;: Dropping an issued Box removes its address from the registry before the
;: caller's arena may recycle that storage. A native adapter still owns the
;: resource cleanup policy; this hook only revokes one authority.
(define (concurrency-authority-token-cleanup [token-box : (Box i64)]) : unit
  (let
    [identity : ConcurrencyBoxIdentity
      (concurrency-owned-box-identity token-box)]
    (begin
      (unsafe
        (concurrency-lock!))
      (if (> identity.token 0)
        (let
          [slot : i64 (% identity.token concurrency-authority-capacity)]
          [generation : i64 (/ identity.token concurrency-authority-capacity)]
          (if (and
            (> generation 0)
            (=
              (unsafe
                (concurrency-ref concurrency-authority-state slot))
              1)
            (=
              (unsafe
                (concurrency-ref concurrency-authority-generation slot))
              generation)
            (=
              (unsafe
                (concurrency-ref concurrency-authority-box-address slot))
              identity.address))
            (let
              [resource-slot : i64
                (unsafe
                  (concurrency-ref concurrency-authority-resource-slot slot))]
              [resource-generation : i64
                (unsafe
                  (concurrency-ref
                    concurrency-authority-resource-generation
                    slot))]
              (begin
                (if (and
                  (>= resource-slot 0)
                  (< resource-slot concurrency-resource-capacity)
                  (=
                    (unsafe
                      (concurrency-ref concurrency-resource-state resource-slot))
                    1)
                  (=
                    (unsafe
                      (concurrency-ref
                        concurrency-resource-generation
                        resource-slot))
                    resource-generation))
                  (let
                    [current : i64
                      (unsafe
                        (concurrency-ref
                          concurrency-resource-authority-head
                          resource-slot))]
                    [previous : i64 -1]
                    (begin
                      (while (and (>= current 0) (!= current slot))
                        (begin
                          (set! previous current)
                          (set!
                            current
                            (unsafe
                              (concurrency-ref
                                concurrency-authority-next
                                current)))))
                      (if (= current slot)
                        (let
                          [next : i64
                            (unsafe
                              (concurrency-ref concurrency-authority-next slot))]
                          (if (< previous 0)
                            (unsafe
                              (concurrency-set!
                                concurrency-resource-authority-head
                                resource-slot
                                next))
                            (unsafe
                              (concurrency-set!
                                concurrency-authority-next
                                previous
                                next))))
                        unit)))
                  unit)
                (unsafe
                  (concurrency-set! concurrency-authority-state slot 0))
                (unsafe
                  (concurrency-set! concurrency-authority-box-address slot 0))
                (unsafe
                  (concurrency-set! concurrency-authority-resource-slot slot -1))
                (unsafe
                  (concurrency-set!
                    concurrency-authority-resource-generation
                    slot
                    0))
                (unsafe
                  (concurrency-set! concurrency-authority-next slot -1))))
            unit))
        unit)
      (unsafe
        (concurrency-unlock!)))))

;: Validate one issued authority and family while holding the registry lock.
;: Returns the resource slot or -1. No resource field is read on failure.
(unsafe
  (define (concurrency-validated-resource
    [token : i64]
    [box-address : i64]
    [family : i64]) : i64
    (if (or (<= token 0) (= box-address 0))
      -1
      (let
        [authority-slot : i64 (% token concurrency-authority-capacity)]
        [authority-generation : i64 (/ token concurrency-authority-capacity)]
        (if (or
          (<= authority-generation 0)
          (!=
            (unsafe
              (concurrency-ref concurrency-authority-state authority-slot))
            1)
          (!=
            (unsafe
              (concurrency-ref concurrency-authority-generation authority-slot))
            authority-generation)
          (!=
            (unsafe
              (concurrency-ref concurrency-authority-box-address authority-slot))
            box-address))
          -1
          (let
            [resource-slot : i64
              (unsafe
                (concurrency-ref
                  concurrency-authority-resource-slot
                  authority-slot))]
            [resource-generation : i64
              (unsafe
                (concurrency-ref
                  concurrency-authority-resource-generation
                  authority-slot))]
            (if (or
              (< resource-slot 0)
              (>= resource-slot concurrency-resource-capacity)
              (!=
                (unsafe
                  (concurrency-ref concurrency-resource-state resource-slot))
                1)
              (!=
                (unsafe
                  (concurrency-ref
                    concurrency-resource-generation
                    resource-slot))
                resource-generation)
              (!=
                (unsafe
                  (concurrency-ref concurrency-resource-family resource-slot))
                family))
              -1
              resource-slot)))))))

;: Issue an authority for a known live resource while holding the lock.
;: The caller has already reserved/validated that resource. A failed issue
;: leaves it unchanged; register must then free its reserved row.
(unsafe
  (define (concurrency-issue [resource-slot : i64]) : ConcurrencyShareResult
    (let
      [slot : i64
        (unsafe
          (concurrency-find-free
            concurrency-authority-state
            concurrency-authority-capacity
            concurrency-next-authority))]
      (if (< slot 0)
        (ConcurrencyShareErr)
        (let
          [generation : i64
            (+
              1
              (unsafe
                (concurrency-ref concurrency-authority-generation slot)))]
          (if (> generation concurrency-max-authority-generation)
            (begin
              (unsafe
                (concurrency-set! concurrency-authority-state slot 2))
              (unsafe
                (concurrency-issue resource-slot)))
            (let
              [token : i64
                (+ (* generation concurrency-authority-capacity) slot)]
              [identity : ConcurrencyBoxIdentity
                (concurrency-owned-box-identity (box token))]
              (begin
                (unsafe
                  (concurrency-set!
                    concurrency-authority-generation
                    slot
                    generation))
                (unsafe
                  (concurrency-set!
                    concurrency-authority-box-address
                    slot
                    identity.address))
                (unsafe
                  (concurrency-set!
                    concurrency-authority-resource-slot
                    slot
                    resource-slot))
                (unsafe
                  (concurrency-set!
                    concurrency-authority-resource-generation
                    slot
                    (unsafe
                      (concurrency-ref
                        concurrency-resource-generation
                        resource-slot))))
                (unsafe
                  (concurrency-set!
                    concurrency-authority-next
                    slot
                    (unsafe
                      (concurrency-ref
                        concurrency-resource-authority-head
                        resource-slot))))
                (unsafe
                  (concurrency-set!
                    concurrency-resource-authority-head
                    resource-slot
                    slot))
                (unsafe
                  (concurrency-set! concurrency-authority-state slot 1))
                (set!
                  concurrency-next-authority
                  (% (+ slot 1) concurrency-authority-capacity))
                (ConcurrencyShared (ConcurrencyAuthority identity.box))))))))))

;: Register seven or fewer raw fields. Only an unsafe constructor that owns
;: those fields may call this function. On failure it still owns all fields.
(unsafe
  (define (concurrency-register
    [family : i64]
    [field-count : i64]
    [field0 : i64]
    [field1 : i64]
    [field2 : i64]
    [field3 : i64]
    [field4 : i64]
    [field5 : i64]
    [field6 : i64]) : ConcurrencyShareResult
    (if (or (<= family 0) (< field-count 0) (> field-count 7))
      (ConcurrencyShareErr)
      (begin
        (unsafe
          (concurrency-lock!))
        (let
          [slot : i64
            (unsafe
              (concurrency-find-free
                concurrency-resource-state
                concurrency-resource-capacity
                concurrency-next-resource))]
          (if (< slot 0)
            (begin
              (unsafe
                (concurrency-unlock!))
              (ConcurrencyShareErr))
            (let
              [generation : i64
                (+
                  1
                  (unsafe
                    (concurrency-ref concurrency-resource-generation slot)))]
              (if (> generation concurrency-max-resource-generation)
                (begin
                  (unsafe
                    (concurrency-set! concurrency-resource-state slot 2))
                  (unsafe
                    (concurrency-unlock!))
                  (unsafe
                    (concurrency-register
                      family
                      field-count
                      field0
                      field1
                      field2
                      field3
                      field4
                      field5
                      field6)))
                (begin
                  (unsafe
                    (concurrency-set!
                      concurrency-resource-generation
                      slot
                      generation))
                  (unsafe
                    (concurrency-set! concurrency-resource-family slot family))
                  (unsafe
                    (concurrency-set!
                      concurrency-resource-field-count
                      slot
                      field-count))
                  (unsafe
                    (concurrency-set! concurrency-resource-leases slot 0))
                  (unsafe
                    (concurrency-set!
                      concurrency-resource-authority-head
                      slot
                      -1))
                  (unsafe
                    (concurrency-set!
                      concurrency-resource-fields
                      (* slot 7)
                      field0))
                  (unsafe
                    (concurrency-set!
                      concurrency-resource-fields
                      (+ (* slot 7) 1)
                      field1))
                  (unsafe
                    (concurrency-set!
                      concurrency-resource-fields
                      (+ (* slot 7) 2)
                      field2))
                  (unsafe
                    (concurrency-set!
                      concurrency-resource-fields
                      (+ (* slot 7) 3)
                      field3))
                  (unsafe
                    (concurrency-set!
                      concurrency-resource-fields
                      (+ (* slot 7) 4)
                      field4))
                  (unsafe
                    (concurrency-set!
                      concurrency-resource-fields
                      (+ (* slot 7) 5)
                      field5))
                  (unsafe
                    (concurrency-set!
                      concurrency-resource-fields
                      (+ (* slot 7) 6)
                      field6))
                  (unsafe
                    (concurrency-set! concurrency-resource-state slot 1))
                  (match (unsafe
                    (concurrency-issue slot))
                    [(ConcurrencyShareErr)
                      (begin
                        (unsafe
                          (concurrency-set! concurrency-resource-state slot 0))
                        (unsafe
                          (concurrency-unlock!))
                        (ConcurrencyShareErr))]
                    [(ConcurrencyShared authority)
                      (begin
                        (set!
                          concurrency-next-resource
                          (% (+ slot 1) concurrency-resource-capacity))
                        (unsafe
                          (concurrency-unlock!))
                        (ConcurrencyShared authority))]))))))))))

;: Issue a second authority for one live shareable resource.
(define (concurrency-share
  [authority : (& authority ConcurrencyAuthority)]
  [family : i64]) : ConcurrencyShareResult
  (let
    [token : i64 (concurrency-authority-token authority)]
    [box-address : i64 (concurrency-authority-address authority)]
    (begin
      (unsafe
        (concurrency-lock!))
      (let
        [slot : i64
          (unsafe
            (concurrency-validated-resource token box-address family))]
        (match (if (< slot 0)
          (ConcurrencyShareErr)
          (unsafe
            (concurrency-issue slot)))
          [(ConcurrencyShareErr)
            (begin
              (unsafe
                (concurrency-unlock!))
              (ConcurrencyShareErr))]
          [(ConcurrencyShared issued)
            (begin
              (unsafe
                (concurrency-unlock!))
              (ConcurrencyShared issued))])))))

;: Lease one resource, returning raw fields only to an unsafe adapter.
(unsafe
  (define (concurrency-acquire
    [authority : (& authority ConcurrencyAuthority)]
    [family : i64]
    [field-count : i64]) : ConcurrencyLease
    (let
      [token : i64 (concurrency-authority-token authority)]
      [box-address : i64 (concurrency-authority-address authority)]
      [empty : ConcurrencyLease
        (ConcurrencyLease false -1 0 0 0 0 0 0 0 0 0 0 "")]
      (begin
        (unsafe
          (concurrency-lock!))
        (let
          [slot : i64
            (unsafe
              (concurrency-validated-resource token box-address family))]
          [lease : ConcurrencyLease
            (if (or
              (< slot 0)
              (!=
                (unsafe
                  (concurrency-ref concurrency-resource-field-count slot))
                field-count))
              empty
              (begin
                (unsafe
                  (concurrency-set!
                    concurrency-resource-leases
                    slot
                    (+
                      1
                      (unsafe
                        (concurrency-ref concurrency-resource-leases slot)))))
                (ConcurrencyLease
                  true
                  slot
                  (unsafe
                    (concurrency-ref concurrency-resource-generation slot))
                  family
                  field-count
                  (unsafe
                    (concurrency-ref concurrency-resource-fields (* slot 7)))
                  (unsafe
                    (concurrency-ref
                      concurrency-resource-fields
                      (+ (* slot 7) 1)))
                  (unsafe
                    (concurrency-ref
                      concurrency-resource-fields
                      (+ (* slot 7) 2)))
                  (unsafe
                    (concurrency-ref
                      concurrency-resource-fields
                      (+ (* slot 7) 3)))
                  (unsafe
                    (concurrency-ref
                      concurrency-resource-fields
                      (+ (* slot 7) 4)))
                  (unsafe
                    (concurrency-ref
                      concurrency-resource-fields
                      (+ (* slot 7) 5)))
                  (unsafe
                    (concurrency-ref
                      concurrency-resource-fields
                      (+ (* slot 7) 6)))
                  "")))]
          (begin
            (unsafe
              (concurrency-unlock!))
            lease))))))

;: Release exactly one acquired lease. Invalid snapshots cannot alter counters.
(unsafe
  (define (concurrency-release [lease : ConcurrencyLease]) : bool
    (begin
      (unsafe
        (concurrency-lock!))
      (let
        [valid : bool
          (and
            lease.ok
            (>= lease.resource-slot 0)
            (< lease.resource-slot concurrency-resource-capacity)
            (=
              (unsafe
                (concurrency-ref concurrency-resource-state lease.resource-slot))
              1)
            (=
              (unsafe
                (concurrency-ref
                  concurrency-resource-generation
                  lease.resource-slot))
              lease.resource-generation)
            (>
              (unsafe
                (concurrency-ref
                  concurrency-resource-leases
                  lease.resource-slot))
              0))]
        (begin
          (if valid
            (unsafe
              (concurrency-set!
                concurrency-resource-leases
                lease.resource-slot
                (-
                  (unsafe
                    (concurrency-ref
                      concurrency-resource-leases
                      lease.resource-slot))
                  1)))
            unit)
          (unsafe
            (concurrency-unlock!))
          valid)))))

;: Detach one quiescent resource exactly once. Any retained aliases fail closed
;: before their resource slot can be reused, even if the native handle recycles.
(unsafe
  (define (concurrency-close
    [authority : (& authority ConcurrencyAuthority)]
    [family : i64]
    [field-count : i64]) : ConcurrencyClaim
    (let
      [token : i64 (concurrency-authority-token authority)]
      [box-address : i64 (concurrency-authority-address authority)]
      [empty : ConcurrencyClaim (ConcurrencyClaim false 0 0 0 0 0 0 0 0 0 "")]
      (begin
        (unsafe
          (concurrency-lock!))
        (let
          [slot : i64
            (unsafe
              (concurrency-validated-resource token box-address family))]
          [claim : ConcurrencyClaim
            (if (or
              (< slot 0)
              (!=
                (unsafe
                  (concurrency-ref concurrency-resource-field-count slot))
                field-count)
              (!=
                (unsafe
                  (concurrency-ref concurrency-resource-leases slot))
                0))
              empty
              (let
                [detached : ConcurrencyClaim
                  (ConcurrencyClaim
                    true
                    family
                    field-count
                    (unsafe
                      (concurrency-ref concurrency-resource-fields (* slot 7)))
                    (unsafe
                      (concurrency-ref
                        concurrency-resource-fields
                        (+ (* slot 7) 1)))
                    (unsafe
                      (concurrency-ref
                        concurrency-resource-fields
                        (+ (* slot 7) 2)))
                    (unsafe
                      (concurrency-ref
                        concurrency-resource-fields
                        (+ (* slot 7) 3)))
                    (unsafe
                      (concurrency-ref
                        concurrency-resource-fields
                        (+ (* slot 7) 4)))
                    (unsafe
                      (concurrency-ref
                        concurrency-resource-fields
                        (+ (* slot 7) 5)))
                    (unsafe
                      (concurrency-ref
                        concurrency-resource-fields
                        (+ (* slot 7) 6)))
                    "")]
                (begin
                  (let
                    [authority-slot : i64
                      (unsafe
                        (concurrency-ref
                          concurrency-resource-authority-head
                          slot))]
                    (while (>= authority-slot 0)
                      (let
                        [next-slot : i64
                          (unsafe
                            (concurrency-ref
                              concurrency-authority-next
                              authority-slot))]
                        (begin
                          (unsafe
                            (concurrency-set!
                              concurrency-authority-state
                              authority-slot
                              0))
                          (unsafe
                            (concurrency-set!
                              concurrency-authority-box-address
                              authority-slot
                              0))
                          (unsafe
                            (concurrency-set!
                              concurrency-authority-resource-slot
                              authority-slot
                              -1))
                          (unsafe
                            (concurrency-set!
                              concurrency-authority-resource-generation
                              authority-slot
                              0))
                          (unsafe
                            (concurrency-set!
                              concurrency-authority-next
                              authority-slot
                              -1))
                          (set! authority-slot next-slot)))))
                  (unsafe
                    (concurrency-set!
                      concurrency-resource-authority-head
                      slot
                      -1))
                  (unsafe
                    (concurrency-set! concurrency-resource-state slot 0))
                  (unsafe
                    (concurrency-set! concurrency-resource-family slot 0))
                  (unsafe
                    (concurrency-set! concurrency-resource-field-count slot 0))
                  (let
                    [i : i64 0]
                    (while (< i 7)
                      (begin
                        (unsafe
                          (concurrency-set!
                            concurrency-resource-fields
                            (+ (* slot 7) i)
                            0))
                        (set! i (+ i 1)))))
                  detached)))]
          (begin
            (unsafe
              (concurrency-unlock!))
            claim))))))

;: Observe table occupancy without exposing raw native resource fields.
(define (concurrency-stats) : ConcurrencyStats
  (let
    [live-resources : i64 0]
    [live-authorities : i64 0]
    [retired-resources : i64 0]
    [retired-authorities : i64 0]
    [active-leases : i64 0]
    [slot : i64 0]
    (begin
      (unsafe
        (concurrency-lock!))
      (while (< slot concurrency-resource-capacity)
        (begin
          (let
            [state : i64
              (unsafe
                (concurrency-ref concurrency-resource-state slot))]
            (begin
              (if (= state 1)
                (begin
                  (set! live-resources (+ live-resources 1))
                  (set!
                    active-leases
                    (+
                      active-leases
                      (unsafe
                        (concurrency-ref concurrency-resource-leases slot)))))
                unit)
              (if (= state 2)
                (set! retired-resources (+ retired-resources 1))
                unit)))
          (set! slot (+ slot 1))))
      (set! slot 0)
      (while (< slot concurrency-authority-capacity)
        (begin
          (let
            [state : i64
              (unsafe
                (concurrency-ref concurrency-authority-state slot))]
            (begin
              (if (= state 1)
                (set! live-authorities (+ live-authorities 1))
                unit)
              (if (= state 2)
                (set! retired-authorities (+ retired-authorities 1))
                unit)))
          (set! slot (+ slot 1))))
      (unsafe
        (concurrency-unlock!))
      (ConcurrencyStats
        live-resources
        live-authorities
        retired-resources
        retired-authorities
        active-leases))))

;: Inline registry tests use inert fields, never OS handles or addresses.
(define (concurrency-test-assert [ok : bool] [code : i64]) : unit
  (if ok
    unit
    (begin
      (/ code 0)
      unit)))

;: Assert that a valid authority can close its inert test resource.
(define (concurrency-test-close-ok
  [authority : (& authority ConcurrencyAuthority)]) : bool
  (let
    [claim : ConcurrencyClaim
      (unsafe
        (concurrency-close authority concurrency-family-channel-i64 2))]
    claim.ok))

;: Assert that a valid authority can acquire and release a lease.
(define (concurrency-test-acquire-ok
  [authority : (& authority ConcurrencyAuthority)]) : bool
  (let
    [lease : ConcurrencyLease
      (unsafe
        (concurrency-acquire authority concurrency-family-channel-i64 2))]
    (if lease.ok
      (unsafe
        (concurrency-release lease))
      false)))

;: A caller-constructed Box must never acquire a resource lease.
(define (concurrency-test-forged-acquire-ok [token : i64]) : bool
  (with
    ([forged (ConcurrencyAuthority (box token)) cleanup-concurrency-authority])
    (concurrency-test-acquire-ok (& forged))))

;: A shared authority remains usable until its own cleanup runs.
(define (concurrency-test-share-and-drop
  [authority : (& authority ConcurrencyAuthority)]) : bool
  (match (concurrency-share authority concurrency-family-channel-i64)
    [(ConcurrencyShareErr) false]
    [(ConcurrencyShared issued)
      (with
        ([temporary issued cleanup-concurrency-authority])
        (concurrency-test-acquire-ok (& temporary)))]))

(test
  concurrency-registry-identity-and-lease
  (match (unsafe
    (concurrency-register concurrency-family-channel-i64 2 17 29 0 0 0 0 0))
    [(ConcurrencyShareErr) (concurrency-test-assert false 1)]
    [(ConcurrencyShared authority)
      (let
        [wrong-family : ConcurrencyLease
          (unsafe
            (concurrency-acquire (& authority) concurrency-family-mutex-i64 2))]
        [wrong-count : ConcurrencyLease
          (unsafe
            (concurrency-acquire (& authority) concurrency-family-channel-i64 3))]
        [lease : ConcurrencyLease
          (unsafe
            (concurrency-acquire (& authority) concurrency-family-channel-i64 2))]
        (begin
          (concurrency-test-assert (not wrong-family.ok) 2)
          (concurrency-test-assert
            (not
              (concurrency-test-forged-acquire-ok
                (concurrency-authority-token (& authority))))
            3)
          (concurrency-test-assert
            (not (concurrency-test-forged-acquire-ok 0))
            13)
          (concurrency-test-assert
            (not (concurrency-test-forged-acquire-ok 1))
            14)
          (concurrency-test-assert (not wrong-count.ok) 15)
          (concurrency-test-assert lease.ok 4)
          (concurrency-test-assert (= lease.field0 17) 5)
          (concurrency-test-assert (= lease.field1 29) 6)
          (let
            [before : ConcurrencyStats (concurrency-stats)]
            (begin
              (concurrency-test-assert
                (concurrency-test-share-and-drop (& authority))
                16)
              (let
                [after : ConcurrencyStats (concurrency-stats)]
                (concurrency-test-assert
                  (= after.live-authorities before.live-authorities)
                  17))))
          (match (concurrency-share
            (& authority)
            concurrency-family-channel-i64)
            [(ConcurrencyShareErr) (concurrency-test-assert false 7)]
            [(ConcurrencyShared alias)
              (begin
                (concurrency-test-assert
                  (not (concurrency-test-close-ok (& alias)))
                  8)
                (concurrency-test-assert
                  (unsafe
                    (concurrency-release lease))
                  9)
                (concurrency-test-assert
                  (concurrency-test-close-ok (& alias))
                  10)
                (concurrency-test-assert
                  (not (concurrency-test-close-ok (& authority)))
                  11)
                (concurrency-test-assert
                  (not (concurrency-test-acquire-ok (& authority)))
                  12))])))]))

(test
  concurrency-registry-drop-original-authority
  (match (unsafe
    (concurrency-register concurrency-family-channel-i64 2 61 67 0 0 0 0 0))
    [(ConcurrencyShareErr) (concurrency-test-assert false 40)]
    [(ConcurrencyShared original)
      (match (concurrency-share (& original) concurrency-family-channel-i64)
        [(ConcurrencyShareErr) (concurrency-test-assert false 41)]
        [(ConcurrencyShared successor)
          (let
            [lease : ConcurrencyLease
              (unsafe
                (concurrency-acquire
                  (& original)
                  concurrency-family-channel-i64
                  2))]
            (begin
              (concurrency-test-assert lease.ok 45)
              (with ([retired original cleanup-concurrency-authority]) unit)
              (let
                [stats : ConcurrencyStats (concurrency-stats)]
                (begin
                  (concurrency-test-assert (= stats.live-authorities 1) 43)
                  (concurrency-test-assert (= stats.active-leases 1) 46)))
              (concurrency-test-assert
                (not (concurrency-test-close-ok (& successor)))
                47)
              (concurrency-test-assert
                (unsafe
                  (concurrency-release lease))
                48)
              (concurrency-test-assert
                (concurrency-test-acquire-ok (& successor))
                42)
              (concurrency-test-assert
                (concurrency-test-close-ok (& successor))
                44)))])]))

(test
  concurrency-registry-slot-reuse
  (match (unsafe
    (concurrency-register concurrency-family-channel-i64 2 31 37 0 0 0 0 0))
    [(ConcurrencyShareErr) (concurrency-test-assert false 20)]
    [(ConcurrencyShared stale)
      (begin
        (concurrency-test-assert (concurrency-test-close-ok (& stale)) 21)
        (let
          [i : i64 0]
          (while (< i (+ concurrency-authority-capacity 1))
            (begin
              (match (unsafe
                (concurrency-register
                  concurrency-family-channel-i64
                  2
                  i
                  0
                  0
                  0
                  0
                  0
                  0))
                [(ConcurrencyShareErr) (concurrency-test-assert false 22)]
                [(ConcurrencyShared current)
                  (begin
                    (concurrency-test-assert
                      (concurrency-test-close-ok (& current))
                      23)
                    (concurrency-test-assert
                      (not (concurrency-test-acquire-ok (& stale)))
                      24))])
              (set! i (+ i 1)))))
        (let
          [stats : ConcurrencyStats (concurrency-stats)]
          (begin
            (concurrency-test-assert (= stats.live-resources 0) 25)
            (concurrency-test-assert (= stats.live-authorities 0) 26)
            (concurrency-test-assert (= stats.active-leases 0) 27))))]))

(test
  concurrency-registry-generation-exhaustion
  (let
    [before : ConcurrencyStats (concurrency-stats)]
    (begin
      (unsafe
        (concurrency-lock!))
      (let
        [resource-slot : i64
          (unsafe
            (concurrency-find-free
              concurrency-resource-state
              concurrency-resource-capacity
              concurrency-next-resource))]
        [authority-slot : i64
          (unsafe
            (concurrency-find-free
              concurrency-authority-state
              concurrency-authority-capacity
              concurrency-next-authority))]
        (begin
          (concurrency-test-assert (>= resource-slot 0) 30)
          (concurrency-test-assert (>= authority-slot 0) 31)
          (unsafe
            (concurrency-set!
              concurrency-resource-generation
              resource-slot
              concurrency-max-resource-generation))
          (unsafe
            (concurrency-set!
              concurrency-authority-generation
              authority-slot
              concurrency-max-authority-generation))
          (unsafe
            (concurrency-unlock!))))
      (match (unsafe
        (concurrency-register concurrency-family-channel-i64 2 41 43 0 0 0 0 0))
        [(ConcurrencyShareErr) (concurrency-test-assert false 32)]
        [(ConcurrencyShared authority)
          (concurrency-test-assert (concurrency-test-close-ok (& authority)) 33)])
      (let
        [after : ConcurrencyStats (concurrency-stats)]
        (begin
          (concurrency-test-assert
            (= after.retired-resources (+ before.retired-resources 1))
            34)
          (concurrency-test-assert
            (= after.retired-authorities (+ before.retired-authorities 1))
            35)
          (concurrency-test-assert
            (= after.live-resources before.live-resources)
            36)
          (concurrency-test-assert
            (= after.live-authorities before.live-authorities)
            37))))))
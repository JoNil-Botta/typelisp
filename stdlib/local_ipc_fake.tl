;# Scripted `LocalIpcAdapter` for the local-IPC conformance matrix.
;#
;# Test support only. Each fake is one row of `i64` slots in a table allocated
;# once for the whole process, and its `context` is the row number: a virtual
;# clock, scripted step queues for connect, data, pending-poll and readiness
;# calls, and counters that let a test prove how often, in which order and with
;# which arguments the contract reached the adapter. Nothing here sleeps or
;# performs I/O: waits advance the clock.
;#
;# The adapter functions are ordinary function values anyone can call, so the
;# fake is written without `unsafe`: a context no `new` returned, or a slot
;# outside the row, traps with the array bounds diagnostic, and bytes are read
;# and written only through checked `ByteBuf` operations.
;#
;# Step codes (queues are consumed front to back; an exhausted queue repeats
;# its last entry, and an empty one answers with the queue's default):
;#
;# - connect: `0` connected, `1` retry, `97` retry handing the name back with
;#   every byte zeroed, `98` retry handing back an empty name buffer, `99` a
;#   negative handle, `100 + k` failed with error kind `k`.
;# - data and pending: `n >= 1` progress of `n` bytes, `-1` would block,
;#   `-2` interrupted, `-3` peer closed, `-4` pending, `-5` progress larger
;#   than requested, `-6` zero progress, `-7` one byte of progress with an
;#   empty buffer handed back, `-(100 + k)` failed with kind `k`.
;# - wait: `0` ready, `1` not ready, `2` interrupted, `100 + k` failed.
(import stdlib.byte_buf)
(import stdlib.local_ipc)
(import stdlib.string)

;: Slots in one fake.
(define slot-count : i64
  168)

;: Fakes one process can create; `new` traps past this.
(define fake-capacity : i64
  128)

;: Every fake's slots, one row after another. It is allocated once for the
;: process, so a context stays valid whatever arena was active at `new`.
(define fake-table : (__tl_dyn-array i64)
  (__tl_make-array i64 (* fake-capacity slot-count)))

;: Fakes created so far. A context is valid exactly when it is below this.
(define fake-count : i64
  0)

;: Virtual monotonic clock in milliseconds; negative makes the clock unavailable.
(define slot-clock : i64
  0)

;: Milliseconds the clock advances on every `now-ms` call.
(define slot-clock-step : i64
  1)

;: Number of `now-ms` calls so far.
(define slot-now-calls : i64
  2)

;: Cancellation becomes visible once `now-ms` was called this many times; -1 never.
(define slot-cancel-after-now-calls : i64
  3)

;: Counters: connect, peer, read, write, poll, cancel-pending, wait, delay, close.
(define slot-connect-calls : i64
  4)

;: See `slot-connect-calls`.
(define slot-peer-calls : i64
  5)

;: See `slot-connect-calls`.
(define slot-read-calls : i64
  6)

;: See `slot-connect-calls`.
(define slot-write-calls : i64
  7)

;: See `slot-connect-calls`.
(define slot-poll-calls : i64
  8)

;: See `slot-connect-calls`.
(define slot-cancel-pending-calls : i64
  9)

;: See `slot-connect-calls`.
(define slot-wait-calls : i64
  10)

;: See `slot-connect-calls`.
(define slot-delay-calls : i64
  11)

;: See `slot-connect-calls`.
(define slot-close-calls : i64
  12)

;: Largest wait, poll or delay slice the contract ever requested.
(define slot-max-slice : i64
  13)

;: Smallest wait, poll or delay slice the contract ever requested.
(define slot-min-slice : i64
  14)

;: Handle the next successful connect returns; each success increments it.
(define slot-next-handle : i64
  15)

;: Handle passed to the most recent close, or -1.
(define slot-last-closed-handle : i64
  16)

;: Error kind code returned by close, or 0 for success.
(define slot-close-kind : i64
  17)

;: Error kind code returned by the peer query, or 0 to return the peer facts.
(define slot-peer-kind : i64
  18)

;: Scripted peer process id.
(define slot-peer-process : i64
  19)

;: Scripted peer user id.
(define slot-peer-user : i64
  20)

;: Scripted peer group id.
(define slot-peer-group : i64
  21)

;: Scripted peer session id.
(define slot-peer-session : i64
  22)

;: Family number of the most recent connect attempt.
(define slot-last-family : i64
  23)

;: Name length of the most recent connect attempt.
(define slot-last-name-len : i64
  24)

;: Sum of every byte the contract handed to write-once.
(define slot-written-sum : i64
  25)

;: Total bytes accepted by write-once and produced by read-once.
(define slot-bytes-moved : i64
  26)

;: Host calls made while an operation was pending and not yet drained.
(define slot-calls-while-pending : i64
  27)

;: 1 while an operation reported `Pending` and no terminal poll was seen.
(define slot-pending-active : i64
  28)

;: Sum of the name bytes of the most recent connect attempt.
(define slot-last-name-sum : i64
  29)

;: Host code of every adapter-built error when nonzero, carried unbounded;
;: 0 keeps each call's default code.
(define slot-host-code : i64
  30)

;: Live length of the buffer handed to the most recent read-once or write-once.
(define slot-last-request : i64
  31)

;: 1 when the pending operation is a read, so its terminal poll delivers bytes.
(define slot-pending-read : i64
  32)

;: Live length of the buffer handed to the most recent poll.
(define slot-last-poll-request : i64
  33)

;: Queue bases. Each queue is `[length, position, entries...]`.
(define queue-connect : i64
  40)

;: See `queue-connect`.
(define queue-data : i64
  72)

;: See `queue-connect`.
(define queue-pending : i64
  104)

;: See `queue-connect`.
(define queue-wait : i64
  136)

;: Entries one queue can hold.
(define queue-capacity : i64
  30)

;: Table index of one slot. It traps for a context no `new` returned and for a
;: slot outside the row.
(define (slot-index [context : i64] [slot : i64]) : i64
  (if (and
    (>= context 0)
    (< context fake-count)
    (>= slot 0)
    (< slot slot-count))
    (+ (* context slot-count) slot)
    (string.tl_oob_abort)))

;: Read one slot.
(define (get [context : i64] [slot : i64]) : i64
  (array-ref fake-table (slot-index context slot)))

;: Write one slot.
(define (put! [context : i64] [slot : i64] [value : i64]) : unit
  (set! (array-ref fake-table (slot-index context slot)) value))

;: Add one to a counter slot.
(define (bump! [context : i64] [slot : i64]) : unit
  (put! context slot (+ (get context slot) 1)))

;: Append one step code to a queue. Entries past `queue-capacity` are dropped.
(define (push! [context : i64] [queue : i64] [code : i64]) : unit
  (let
    [length : i64 (get context queue)]
    (if (< length queue-capacity)
      (begin
        (put! context (+ queue (+ 2 length)) code)
        (put! context queue (+ length 1)))
      unit)))

;: Take the next step code of a queue, repeating the last entry when the queue
;: is exhausted and answering `fallback` when it is empty.
(define (next! [context : i64] [queue : i64] [fallback : i64]) : i64
  (let
    [length : i64 (get context queue)]
    [position : i64 (get context (+ queue 1))]
    (if (= length 0)
      fallback
      (if (< position length)
        (begin
          (put! context (+ queue 1) (+ position 1))
          (get context (+ queue (+ 2 position))))
        (get context (+ queue (+ 1 length)))))))

;: Note a host call; it is a contract violation while an operation is pending.
(define (note-call! [context : i64]) : unit
  (if (= (get context slot-pending-active) 1)
    (bump! context slot-calls-while-pending)
    unit))

;: Record a requested slice and advance the virtual clock by it.
(define (spend-slice! [context : i64] [slice-ms : i64]) : unit
  (begin
    (if (> slice-ms (get context slot-max-slice))
      (put! context slot-max-slice slice-ms)
      unit)
    (if (< slice-ms (get context slot-min-slice))
      (put! context slot-min-slice slice-ms)
      unit)
    (if (>= (get context slot-clock) 0)
      (put! context slot-clock (+ (get context slot-clock) slice-ms))
      unit)))

;: Error kind for a stable kind code; unknown codes map to `HostFailure`.
(define (kind-from-code [code : i64]) : local_ipc.LocalIpcErrorKind
  (cond
    [(= code 1) (local_ipc.LocalIpcErrorKind.InvalidEndpoint)]
    [(= code 2) (local_ipc.LocalIpcErrorKind.Unavailable)]
    [(= code 3) (local_ipc.LocalIpcErrorKind.PermissionDenied)]
    [(= code 4) (local_ipc.LocalIpcErrorKind.Busy)]
    [(= code 5) (local_ipc.LocalIpcErrorKind.TimedOut)]
    [(= code 6) (local_ipc.LocalIpcErrorKind.Canceled)]
    [(= code 7) (local_ipc.LocalIpcErrorKind.PeerClosed)]
    [(= code 8) (local_ipc.LocalIpcErrorKind.ResourceExhausted)]
    [(= code 9) (local_ipc.LocalIpcErrorKind.UnsupportedTarget)]
    [(= code 10) (local_ipc.LocalIpcErrorKind.AdapterCorrupt)]
    [(= code 11) (local_ipc.LocalIpcErrorKind.Closed)]
    [(= code 12) (local_ipc.LocalIpcErrorKind.InvalidRange)]
    [(= code 13) (local_ipc.LocalIpcErrorKind.WorkExhausted)]
    [(= code 14) (local_ipc.LocalIpcErrorKind.PolicyRejected)]
    [else (local_ipc.LocalIpcErrorKind.HostFailure)]))

;: An adapter-built error with kind code `kind`. Its host code is
;: `slot-host-code` when that is set and `default` otherwise, and it is built
;: directly rather than with `make-error`: bounding it is the contract's job.
(define (fake-error [context : i64] [kind : i64] [default : i64]) : local_ipc.LocalIpcError
  (let
    [code : i64 (get context slot-host-code)]
    (local_ipc.LocalIpcError
      (kind-from-code kind)
      (if (= code 0)
        default
        code))))

;: Sum of the first `count` live bytes of `buffer`.
(define (byte-sum [buffer : (& buffer byte_buf.ByteBuf)] [count : i64]) : i64
  (let
    [index : i64 0]
    [total : i64 0]
    (begin
      (while (< index count)
        (begin
          (set! total (+ total (cast (byte_buf.ref buffer index) : i64)))
          (set! index (+ index 1))))
      total)))

;: Fill the first `count` live bytes of `buffer` with 1, 2, 3, ...
(define (fill-counted [buffer : byte_buf.ByteBuf] [count : i64]) : byte_buf.ByteBuf
  (let
    [index : i64 0]
    [ready : byte_buf.ByteBuf buffer]
    (begin
      (while (< index count)
        (begin
          (set! ready (byte_buf.set! ready index (cast (+ index 1) : u8)))
          (set! index (+ index 1))))
      ready)))

;: Zero the first `count` live bytes of `buffer`.
(define (zero-fill [buffer : byte_buf.ByteBuf] [count : i64]) : byte_buf.ByteBuf
  (let
    [index : i64 0]
    [ready : byte_buf.ByteBuf buffer]
    (begin
      (while (< index count)
        (begin
          (set! ready (byte_buf.set! ready index (cast 0 : u8)))
          (set! index (+ index 1))))
      ready)))

;: Adapter `now-ms`: report the clock, then advance it by the clock step.
(define (fake-now-ms [context : i64]) : i64
  (let
    [now : i64 (get context slot-clock)]
    (begin
      (bump! context slot-now-calls)
      (if (>= now 0)
        (put! context slot-clock (+ now (get context slot-clock-step)))
        unit)
      now)))

;: Adapter `connect-attempt`: records the family and the exact name bytes.
;: Codes 97 and 98 hand back a damaged name buffer.
(define (fake-connect-attempt
  [context : i64]
  [family : i64]
  [name : byte_buf.ByteBuf]) : local_ipc.LocalIpcConnectReply
  (let
    [code : i64 (next! context queue-connect 0)]
    [length : i64 (byte_buf.len name)]
    (begin
      (note-call! context)
      (bump! context slot-connect-calls)
      (put! context slot-last-family family)
      (put! context slot-last-name-len length)
      (put! context slot-last-name-sum (byte-sum (& name) length))
      (local_ipc.LocalIpcConnectReply
        (cond
          [(= code 0)
            (let
              [handle : i64 (get context slot-next-handle)]
              (begin
                (put! context slot-next-handle (+ handle 1))
                (local_ipc.LocalIpcConnectStep.Connected handle)))]
          [(or (= code 1) (= code 97) (= code 98))
            (local_ipc.LocalIpcConnectStep.RetryConnect)]
          [(= code 99) (local_ipc.LocalIpcConnectStep.Connected -5)]
          [else
            (local_ipc.LocalIpcConnectStep.ConnectFailed
              (fake-error context (- code 100) 111))])
        (cond
          [(= code 97) (zero-fill name length)]
          [(= code 98) (byte_buf.from-array (__tl_make-array u8 0))]
          [else name])))))

;: Adapter `peer`.
(define (fake-peer [context : i64] [_handle : i64]) : local_ipc.LocalIpcPeerStep
  (begin
    (note-call! context)
    (bump! context slot-peer-calls)
    (if (= (get context slot-peer-kind) 0)
      (local_ipc.LocalIpcPeerStep.PeerKnown
        (local_ipc.LocalIpcPeer
          (get context slot-peer-process)
          (get context slot-peer-user)
          (get context slot-peer-group)
          (get context slot-peer-session)))
      (local_ipc.LocalIpcPeerStep.PeerFailed
        (fake-error context (get context slot-peer-kind) 0)))))

;: Turn a data step code into an adapter step for a request of `length` bytes.
;: Progress larger than the request is clamped, so only `-5` is corrupt.
(define (data-step [context : i64] [code : i64] [length : i64]) : local_ipc.LocalIpcIoStep
  (cond
    [(>= code 1)
      (let
        [count : i64
          (if (< code length)
            code
            length)]
        (begin
          (put!
            context
            slot-bytes-moved
            (+ (get context slot-bytes-moved) count))
          (local_ipc.LocalIpcIoStep.Progress count)))]
    [(= code -1) (local_ipc.LocalIpcIoStep.WouldBlock)]
    [(= code -2) (local_ipc.LocalIpcIoStep.Interrupted)]
    [(= code -3) (local_ipc.LocalIpcIoStep.PeerClosed)]
    [(= code -4) (local_ipc.LocalIpcIoStep.Pending)]
    [(= code -5) (local_ipc.LocalIpcIoStep.Progress (+ length 1))]
    [(= code -6) (local_ipc.LocalIpcIoStep.Progress 0)]
    [(= code -7) (local_ipc.LocalIpcIoStep.Progress 1)]
    [else
      (local_ipc.LocalIpcIoStep.IoFailed
        (fake-error context (- (- 0 code) 100) 222))]))

;: Remember whether `step` leaves an operation pending.
(define (track-pending! [context : i64] [step : local_ipc.LocalIpcIoStep]) : unit
  (put!
    context
    slot-pending-active
    (match step
      [(local_ipc.LocalIpcIoStep.Pending) 1]
      [_ 0])))

;: Build the reply for `step` and hand the buffer back. Progress within the
;: buffer fills it with 1, 2, 3, ... for a read and adds its bytes to the
;: written sum for a write. Code `-7` hands back an empty buffer instead.
(define (reply
  [context : i64]
  [code : i64]
  [step : local_ipc.LocalIpcIoStep]
  [buffer : byte_buf.ByteBuf]
  [reading : bool]) : local_ipc.LocalIpcIoReply
  (if (= code -7)
    (local_ipc.LocalIpcIoReply
      step
      (byte_buf.from-array (__tl_make-array u8 0)))
    (match step
      [(local_ipc.LocalIpcIoStep.Progress count)
        (if (and (>= count 1) (<= count (byte_buf.len buffer)))
          (if reading
            (local_ipc.LocalIpcIoReply step (fill-counted buffer count))
            (begin
              (put!
                context
                slot-written-sum
                (+ (get context slot-written-sum) (byte-sum (& buffer) count)))
              (local_ipc.LocalIpcIoReply step buffer)))
          (local_ipc.LocalIpcIoReply step buffer))]
      [_ (local_ipc.LocalIpcIoReply step buffer)])))

;: One data attempt for read-once and write-once.
(define (data-once [context : i64] [buffer : byte_buf.ByteBuf] [reading : bool]) : local_ipc.LocalIpcIoReply
  (let
    [length : i64 (byte_buf.len buffer)]
    [code : i64 (next! context queue-data -1)]
    [step : local_ipc.LocalIpcIoStep (data-step context code length)]
    (begin
      (put! context slot-last-request length)
      (put!
        context
        slot-pending-read
        (if reading
          1
          0))
      (track-pending! context step)
      (reply context code step buffer reading))))

;: Adapter `read-once`: progress fills the buffer with 1, 2, 3, ...
(define (fake-read-once
  [context : i64]
  [_handle : i64]
  [buffer : byte_buf.ByteBuf]) : local_ipc.LocalIpcIoReply
  (begin
    (note-call! context)
    (bump! context slot-read-calls)
    (data-once context buffer true)))

;: Adapter `write-once`: progress adds the accepted bytes to the written sum.
(define (fake-write-once
  [context : i64]
  [_handle : i64]
  [buffer : byte_buf.ByteBuf]) : local_ipc.LocalIpcIoReply
  (begin
    (note-call! context)
    (bump! context slot-write-calls)
    (data-once context buffer false)))

;: Adapter `poll-pending`: spends the slice, then answers from the pending
;: queue. Scripted progress is returned as written, so the contract checks it
;: against the original request; a pending read that completes delivers its
;: bytes into the buffer of this poll.
(define (fake-poll-pending
  [context : i64]
  [_handle : i64]
  [buffer : byte_buf.ByteBuf]
  [slice-ms : i64]) : local_ipc.LocalIpcIoReply
  (let
    [_count : unit (bump! context slot-poll-calls)]
    [_slice : unit (spend-slice! context slice-ms)]
    [_request : unit
      (put! context slot-last-poll-request (byte_buf.len buffer))]
    [code : i64 (next! context queue-pending -4)]
    [step : local_ipc.LocalIpcIoStep
      (if (>= code 1)
        (local_ipc.LocalIpcIoStep.Progress code)
        (data-step context code 0))]
    (begin
      (track-pending! context step)
      (reply context code step buffer (= (get context slot-pending-read) 1)))))

;: Adapter `cancel-pending`.
(define (fake-cancel-pending [context : i64] [_handle : i64]) : unit
  (bump! context slot-cancel-pending-calls))

;: Adapter `wait-ready`.
(define (fake-wait-ready
  [context : i64]
  [_handle : i64]
  [_interest : i64]
  [slice-ms : i64]) : local_ipc.LocalIpcWaitStep
  (let
    [code : i64 (next! context queue-wait 0)]
    (begin
      (note-call! context)
      (bump! context slot-wait-calls)
      (spend-slice! context slice-ms)
      (cond
        [(= code 0) (local_ipc.LocalIpcWaitStep.Ready)]
        [(= code 1) (local_ipc.LocalIpcWaitStep.NotReady)]
        [(= code 2) (local_ipc.LocalIpcWaitStep.WaitInterrupted)]
        [else
          (local_ipc.LocalIpcWaitStep.WaitFailed
            (fake-error context (- code 100) 333))]))))

;: Adapter `delay`.
(define (fake-delay [context : i64] [ms : i64]) : unit
  (begin
    (note-call! context)
    (bump! context slot-delay-calls)
    (spend-slice! context ms)))

;: Adapter `close`. Closing ends any pending operation.
(define (fake-close [context : i64] [handle : i64]) : local_ipc.LocalIpcStatus
  (begin
    (bump! context slot-close-calls)
    (put! context slot-last-closed-handle handle)
    (put! context slot-pending-active 0)
    (if (= (get context slot-close-kind) 0)
      (local_ipc.LocalIpcStatus.Ok)
      (local_ipc.LocalIpcStatus.Err
        (fake-error context (get context slot-close-kind) 444)))))

;: Create a fake and return its context: clock 1000, no clock step, never
;: canceled, first handle 7, peer facts 41/42/43/44, empty queues.
(define (new) : i64
  (let
    [context : i64 fake-count]
    (begin
      (if (>= context fake-capacity)
        (string.tl_oob_abort)
        unit)
      (set! fake-count (+ context 1))
      (put! context slot-clock 1000)
      (put! context slot-cancel-after-now-calls -1)
      (put! context slot-min-slice 1000000)
      (put! context slot-next-handle 7)
      (put! context slot-last-closed-handle -1)
      (put! context slot-peer-process 41)
      (put! context slot-peer-user 42)
      (put! context slot-peer-group 43)
      (put! context slot-peer-session 44)
      context)))

;: The adapter value for a fake.
(define (adapter [context : i64]) : local_ipc.LocalIpcAdapter
  (local_ipc.LocalIpcAdapter
    context
    fake-now-ms
    fake-connect-attempt
    fake-peer
    fake-read-once
    fake-write-once
    fake-poll-pending
    fake-cancel-pending
    fake-wait-ready
    fake-delay
    fake-close))

;: True once the fake's cancellation point was reached.
(define (canceled? [context : i64]) : bool
  (let
    [after : i64 (get context slot-cancel-after-now-calls)]
    (and (>= after 0) (>= (get context slot-now-calls) after))))
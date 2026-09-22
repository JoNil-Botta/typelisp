;; Runtime contract test: a `LocalIpcConnection` has one effective owner.
;;
;; TypeLisp has no private fields, so safe code can copy a connection's owner
;; words into a second `LocalIpcConnection`. These cases pin what the
;; generation check makes of that: whichever value operates first keeps the
;; connection, the other is stale, a stale value reaches the adapter neither
;; for data nor for close, and the adapter's close runs exactly once. It also
;; pins that the whole-buffer helpers agree with the primitives on a closed
;; connection and on a zero-length range.
(import stdlib.byte_buf)
(import stdlib.local_ipc)
(import stdlib.local_ipc_fake as fake)

(define (first-failure [current : i64] [ok : bool] [id : i64]) : i64
  (if (and (= current 0) (not ok))
    id
    current))

(define (first-nonzero [current : i64] [next : i64]) : i64
  (if (= current 0)
    next
    current))

(define (io-kind [result : local_ipc.LocalIpcIoResult]) : i64
  (match result
    [(local_ipc.LocalIpcIoResult.Failed failure)
      (local_ipc.error-kind-code failure.kind)]
    [_ 0]))

(define (io-done [result : local_ipc.LocalIpcIoResult]) : i64
  (match result
    [(local_ipc.LocalIpcIoResult.Done count) count]
    [_ -1]))

(define kind-closed : i64
  11)
(define far-deadline : i64
  1000000)
(define agent-socket : local_ipc.LocalIpcEndpoint
  (local_ipc.LocalIpcEndpoint.UnixPath "/run/user/1000/agent.sock"))

(define (open [context : i64]) : local_ipc.LocalIpcConnection
  (local_ipc.connect
    (fake.adapter context)
    (& agent-socket)
    local_ipc.accept-any-peer
    far-deadline
    local_ipc.never-canceled
    16))

(define (zero-buf [count : i64]) : byte_buf.ByteBuf
  (byte_buf.from-array (__tl_make-array u8 count)))

(define (adapter-data-calls [context : i64]) : i64
  (+
    (fake.get context fake.slot-read-calls)
    (fake.get context fake.slot-write-calls)))

;; The original operates first: the copy is stale for data, for the accessors
;; and for close, and ending its scope closes nothing.
(define (case-owner-wins) : i64
  (let
    [context : i64 (fake.new)]
    [buffer : byte_buf.ByteBuf (zero-buf 8)]
    [_a : unit (fake.push! context fake.queue-data 4)]
    [failed : i64 0]
    (begin
      (with
        ([original (open context) local_ipc.cleanup-local-ipc-connection])
        (begin
          (with
            ([copy
                (local_ipc.LocalIpcConnection original.owner)
                local_ipc.cleanup-local-ipc-connection])
            (let
              [first : local_ipc.LocalIpcIoResult
                (local_ipc.write-some!
                  (&mut original)
                  (byte_buf.as-bytes (& buffer))
                  0
                  8)]
              [calls-after-first : i64 (adapter-data-calls context)]
              [stale-write : local_ipc.LocalIpcIoResult
                (local_ipc.write-some!
                  (&mut copy)
                  (byte_buf.as-bytes (& buffer))
                  0
                  8)]
              [stale-wait : local_ipc.LocalIpcIoResult
                (local_ipc.read-wait!
                  (&mut copy)
                  (byte_buf.as-mut-bytes (&mut buffer))
                  0
                  8
                  far-deadline
                  local_ipc.never-canceled
                  8)]
              [stale-all : local_ipc.LocalIpcTransfer
                (local_ipc.write-all!
                  (&mut copy)
                  (byte_buf.as-bytes (& buffer))
                  0
                  8
                  far-deadline
                  local_ipc.never-canceled
                  8)]
              [stale-close : local_ipc.LocalIpcStatus
                (local_ipc.close! (&mut copy))]
              (begin
                (set! failed (first-failure failed (= (io-done first) 4) 1))
                (set!
                  failed
                  (first-failure failed (= (io-kind stale-write) kind-closed) 2))
                (set!
                  failed
                  (first-failure failed (= (io-kind stale-wait) kind-closed) 3))
                (set!
                  failed
                  (first-failure
                    failed
                    (and
                      (= stale-all.count 0)
                      (=
                        (local_ipc.status-kind-code stale-all.status)
                        kind-closed))
                    4))
                (set!
                  failed
                  (first-failure
                    failed
                    (= (local_ipc.status-kind-code stale-close) kind-closed)
                    5))
                (set!
                  failed
                  (first-failure
                    failed
                    (= (adapter-data-calls context) calls-after-first)
                    6))
                (set!
                  failed
                  (first-failure
                    failed
                    (not (local_ipc.connection-open? (& copy)))
                    7))
                (set!
                  failed
                  (first-failure
                    failed
                    (=
                      (local_ipc.status-kind-code
                        (local_ipc.connection-result (& copy)))
                      kind-closed)
                    8)))))
          ;; The stale copy's scope has ended: nothing was closed, and the
          ;; original still works.
          (set!
            failed
            (first-failure
              failed
              (= (fake.get context fake.slot-close-calls) 0)
              9))
          (set!
            failed
            (first-failure failed (local_ipc.connection-open? (& original)) 10))))
      (set!
        failed
        (first-failure failed (= (fake.get context fake.slot-close-calls) 1) 11))
      failed)))

;; The copy operates first: now the original is the stale one, and the handle
;; is closed exactly once, by the copy.
(define (case-copy-wins) : i64
  (let
    [context : i64 (fake.new)]
    [buffer : byte_buf.ByteBuf (zero-buf 8)]
    [_a : unit (fake.push! context fake.queue-data 2)]
    [failed : i64 0]
    (begin
      (with
        ([original (open context) local_ipc.cleanup-local-ipc-connection])
        (begin
          (with
            ([copy
                (local_ipc.LocalIpcConnection original.owner)
                local_ipc.cleanup-local-ipc-connection])
            (set!
              failed
              (first-failure
                failed
                (=
                  (io-done
                    (local_ipc.write-some!
                      (&mut copy)
                      (byte_buf.as-bytes (& buffer))
                      0
                      8))
                  2)
                21)))
          (set!
            failed
            (first-failure
              failed
              (= (fake.get context fake.slot-close-calls) 1)
              22))
          (set!
            failed
            (first-failure
              failed
              (=
                (io-kind
                  (local_ipc.write-some!
                    (&mut original)
                    (byte_buf.as-bytes (& buffer))
                    0
                    8))
                kind-closed)
              23))
          (set!
            failed
            (first-failure
              failed
              (=
                (local_ipc.status-kind-code (local_ipc.close! (&mut original)))
                kind-closed)
              24))))
      (set!
        failed
        (first-failure failed (= (fake.get context fake.slot-close-calls) 1) 25))
      failed)))

;; A copy that never operates still ends the connection when its scope ends:
;; it was current, so its cleanup is the one close. The original then reports
;; `Closed` and closes nothing.
(define (case-idle-copy-closes-once) : i64
  (let
    [context : i64 (fake.new)]
    [buffer : byte_buf.ByteBuf (zero-buf 8)]
    [failed : i64 0]
    (begin
      (with
        ([original (open context) local_ipc.cleanup-local-ipc-connection])
        (begin
          (with
            ([copy
                (local_ipc.LocalIpcConnection original.owner)
                local_ipc.cleanup-local-ipc-connection])
            (set!
              failed
              (first-failure failed (local_ipc.connection-open? (& copy)) 31)))
          (set!
            failed
            (first-failure
              failed
              (= (fake.get context fake.slot-close-calls) 1)
              32))
          (set!
            failed
            (first-failure
              failed
              (not (local_ipc.connection-open? (& original)))
              33))
          (set!
            failed
            (first-failure
              failed
              (=
                (io-kind
                  (local_ipc.read-some!
                    (&mut original)
                    (byte_buf.as-mut-bytes (&mut buffer))
                    0
                    8))
                kind-closed)
              34))))
      (set!
        failed
        (first-failure failed (= (fake.get context fake.slot-close-calls) 1) 35))
      (set! failed (first-failure failed (= (adapter-data-calls context) 0) 36))
      failed)))

;; Zero-length ranges: every tier succeeds without a host call on an open
;; connection and reports `Closed` on a closed one.
(define (case-zero-length-tiers) : i64
  (let
    [context : i64 (fake.new)]
    [buffer : byte_buf.ByteBuf (zero-buf 8)]
    [failed : i64 0]
    (with
      ([connection (open context) local_ipc.cleanup-local-ipc-connection])
      (let
        [clock-before : i64 (fake.get context fake.slot-now-calls)]
        [open-some : local_ipc.LocalIpcIoResult
          (local_ipc.write-some!
            (&mut connection)
            (byte_buf.as-bytes (& buffer))
            8
            0)]
        [open-wait : local_ipc.LocalIpcIoResult
          (local_ipc.read-wait!
            (&mut connection)
            (byte_buf.as-mut-bytes (&mut buffer))
            0
            0
            far-deadline
            local_ipc.never-canceled
            0)]
        [open-all : local_ipc.LocalIpcTransfer
          (local_ipc.write-all!
            (&mut connection)
            (byte_buf.as-bytes (& buffer))
            3
            0
            far-deadline
            local_ipc.never-canceled
            0)]
        [clock-calls : i64 (fake.get context fake.slot-now-calls)]
        [_closed : local_ipc.LocalIpcStatus
          (local_ipc.close! (&mut connection))]
        [closed-some : local_ipc.LocalIpcIoResult
          (local_ipc.write-some!
            (&mut connection)
            (byte_buf.as-bytes (& buffer))
            0
            0)]
        [closed-all : local_ipc.LocalIpcTransfer
          (local_ipc.write-all!
            (&mut connection)
            (byte_buf.as-bytes (& buffer))
            0
            0
            far-deadline
            local_ipc.never-canceled
            8)]
        [closed-exact : local_ipc.LocalIpcTransfer
          (local_ipc.read-exact!
            (&mut connection)
            (byte_buf.as-mut-bytes (&mut buffer))
            0
            0
            far-deadline
            local_ipc.never-canceled
            8)]
        (begin
          (set! failed (first-failure failed (= (io-done open-some) 0) 41))
          (set! failed (first-failure failed (= (io-done open-wait) 0) 42))
          (set!
            failed
            (first-failure
              failed
              (and (= open-all.count 0) (local_ipc.status-ok? open-all.status))
              43))
          (set!
            failed
            (first-failure failed (= (adapter-data-calls context) 0) 44))
          (set!
            failed
            (first-failure failed (= (io-kind closed-some) kind-closed) 45))
          (set!
            failed
            (first-failure
              failed
              (= (local_ipc.status-kind-code closed-all.status) kind-closed)
              46))
          (set!
            failed
            (first-failure
              failed
              (= (local_ipc.status-kind-code closed-exact.status) kind-closed)
              47))
          (set! failed (first-failure failed (= clock-calls clock-before) 48))
          failed)))))

(define (main) : i64
  (let
    [failed : i64 0]
    (begin
      (set! failed (first-nonzero failed (case-owner-wins)))
      (set! failed (first-nonzero failed (case-copy-wins)))
      (set! failed (first-nonzero failed (case-idle-copy-closes-once)))
      (set! failed (first-nonzero failed (case-zero-length-tiers)))
      (if (= failed 0)
        42
        failed))))
;; Conformance matrix for stdlib.local_ipc, driven by the scripted fake adapter.
;; Every case returns 0, or the number of its first failed expectation.
(import stdlib.byte_buf)
(import stdlib.local_ipc)
(import stdlib.local_ipc_fake as fake)
(import stdlib.string)

(define (first-failure [current : i64] [ok : bool] [id : i64]) : i64
  (if (and (= current 0) (not ok))
    id
    current))

(define (kind-of [status : local_ipc.LocalIpcStatus]) : i64
  (local_ipc.status-kind-code status))

(define (io-kind [result : local_ipc.LocalIpcIoResult]) : i64
  (match result
    [(local_ipc.LocalIpcIoResult.Failed failure)
      (local_ipc.error-kind-code failure.kind)]
    [_ 0]))

(define (io-done [result : local_ipc.LocalIpcIoResult]) : i64
  (match result
    [(local_ipc.LocalIpcIoResult.Done count) count]
    [_ -1]))

(define (io-host-code [result : local_ipc.LocalIpcIoResult]) : i64
  (match result
    [(local_ipc.LocalIpcIoResult.Failed failure) failure.host-code]
    [_ -1]))

(define (io-would-block? [result : local_ipc.LocalIpcIoResult]) : bool
  (match result
    [(local_ipc.LocalIpcIoResult.WouldBlock) true]
    [_ false]))

(define (io-interrupted? [result : local_ipc.LocalIpcIoResult]) : bool
  (match result
    [(local_ipc.LocalIpcIoResult.Interrupted) true]
    [_ false]))

(define (io-eof? [result : local_ipc.LocalIpcIoResult]) : bool
  (match result
    [(local_ipc.LocalIpcIoResult.Eof) true]
    [_ false]))

;; Bytes 1, 2, 3, ... count.
(define (counted-buf [count : i64]) : byte_buf.ByteBuf
  (let
    [slots : (__tl_dyn-array u8) (__tl_make-array u8 count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set! (array-ref slots index) (cast (+ index 1) : u8))
          (set! index (+ index 1))))
      (byte_buf.from-array slots))))

(define (zero-buf [count : i64]) : byte_buf.ByteBuf
  (byte_buf.from-array (__tl_make-array u8 count)))

(define (repeat-char [count : i64]) : String
  (let
    [slots : (__tl_dyn-array u8) (__tl_make-array u8 count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set! (array-ref slots index) (cast 97 : u8))
          (set! index (+ index 1))))
      (let
        [buffer : byte_buf.ByteBuf (byte_buf.from-array slots)]
        (byte_buf.bytes-to-string (byte_buf.as-bytes (& buffer)))))))

(define (text-with-nul) : String
  (let
    [slots : (__tl_dyn-array u8) (__tl_make-array u8 4)]
    (begin
      (set! (array-ref slots 0) (cast 47 : u8))
      (set! (array-ref slots 1) (cast 97 : u8))
      (set! (array-ref slots 2) (cast 0 : u8))
      (set! (array-ref slots 3) (cast 98 : u8))
      (let
        [buffer : byte_buf.ByteBuf (byte_buf.from-array slots)]
        (byte_buf.bytes-to-string (byte_buf.as-bytes (& buffer)))))))

(define (reject-peer [_peer : local_ipc.LocalIpcPeer]) : bool
  false)

(define (only-user-42 [peer : local_ipc.LocalIpcPeer]) : bool
  (= peer.user-id 42))

(define far-deadline : i64
  1000000)
(define agent-socket : local_ipc.LocalIpcEndpoint
  (local_ipc.LocalIpcEndpoint.UnixPath "/run/agent.sock"))
(define agent-pipe : local_ipc.LocalIpcEndpoint
  (local_ipc.LocalIpcEndpoint.WindowsPipe "\\\\.\\pipe\\agent"))
(define remote-pipe : local_ipc.LocalIpcEndpoint
  (local_ipc.LocalIpcEndpoint.WindowsPipe "\\\\server\\pipe\\agent"))

;; Connect on `context`; cleanup-owning values live in a `with` scope.
(define (open [context : i64]) : local_ipc.LocalIpcConnection
  (local_ipc.connect
    (fake.adapter context)
    (& agent-socket)
    local_ipc.accept-any-peer
    far-deadline
    local_ipc.never-canceled
    16))

(define (connect-with [context : i64] [deadline-ms : i64] [work-budget : i64]) : local_ipc.LocalIpcConnection
  (local_ipc.connect
    (fake.adapter context)
    (& agent-socket)
    local_ipc.accept-any-peer
    deadline-ms
    (lambda () : bool
      (fake.canceled? context))
    work-budget))

;; Kind code of a connect's construction result (0 when connected).
(define (connect-kind [context : i64] [deadline-ms : i64] [work-budget : i64]) : i64
  (with
    ([connection
        (connect-with context deadline-ms work-budget)
        local_ipc.cleanup-local-ipc-connection])
    (kind-of (local_ipc.connection-result (& connection)))))

(define (connect-kind-with-policy
  [context : i64]
  [policy : (-> local_ipc.LocalIpcPeer bool)]) : i64
  (with
    ([connection
        (local_ipc.connect
          (fake.adapter context)
          (& agent-socket)
          policy
          far-deadline
          local_ipc.never-canceled
          16)
        local_ipc.cleanup-local-ipc-connection])
    (if (local_ipc.connection-open? (& connection))
      0
      (kind-of (local_ipc.connection-result (& connection))))))

;; One wait-capable 8-byte read on a fresh connection.
(define (read-wait-case
  [context : i64]
  [deadline-ms : i64]
  [work-budget : i64]
  [close-first : bool]) : local_ipc.LocalIpcIoResult
  (with
    ([connection (open context) local_ipc.cleanup-local-ipc-connection])
    (let
      [buffer : byte_buf.ByteBuf (zero-buf 8)]
      (begin
        (if close-first
          (begin
            (local_ipc.close! (&mut connection))
            unit)
          unit)
        (local_ipc.read-wait!
          (&mut connection)
          (byte_buf.as-mut-bytes (&mut buffer))
          0
          8
          deadline-ms
          (lambda () : bool
            (fake.canceled? context))
          work-budget)))))

;; One 10-byte write-all of the bytes 1..10 on a fresh connection.
(define (write-all-case [context : i64] [deadline-ms : i64] [work-budget : i64]) : local_ipc.LocalIpcTransfer
  (with
    ([connection (open context) local_ipc.cleanup-local-ipc-connection])
    (let
      [buffer : byte_buf.ByteBuf (counted-buf 10)]
      (local_ipc.write-all!
        (&mut connection)
        (byte_buf.as-bytes (& buffer))
        0
        10
        deadline-ms
        (lambda () : bool
          (fake.canceled? context))
        work-budget))))

;; One primitive 8-byte read on a fresh connection.
(define (pending-read [context : i64]) : local_ipc.LocalIpcIoResult
  (with
    ([connection (open context) local_ipc.cleanup-local-ipc-connection])
    (let
      [buffer : byte_buf.ByteBuf (zero-buf 8)]
      (local_ipc.read-some!
        (&mut connection)
        (byte_buf.as-mut-bytes (&mut buffer))
        0
        8))))

(define (case-endpoints) : i64
  (let
    [failed : i64 0]
    [long-ok : String (string.concat "/" (repeat-char 106))]
    [long-bad : String (string.concat "/" (repeat-char 107))]
    [pipe-long-ok : String (string.concat "\\\\.\\pipe\\" (repeat-char 247))]
    [pipe-long-bad : String (string.concat "\\\\.\\pipe\\" (repeat-char 248))]
    [with-nul : String (text-with-nul)]
    (begin
      (set!
        failed
        (first-failure failed (local_ipc.unix-path-valid? "/run/agent.sock") 1))
      (set!
        failed
        (first-failure failed (not (local_ipc.unix-path-valid? "")) 2))
      (set!
        failed
        (first-failure
          failed
          (not (local_ipc.unix-path-valid? "run/agent.sock"))
          3))
      (set!
        failed
        (first-failure failed (local_ipc.unix-path-valid? (& long-ok)) 4))
      (set!
        failed
        (first-failure failed (not (local_ipc.unix-path-valid? (& long-bad))) 5))
      (set!
        failed
        (first-failure failed (not (local_ipc.unix-path-valid? (& with-nul))) 6))
      (set!
        failed
        (first-failure
          failed
          (local_ipc.windows-pipe-valid? "\\\\.\\pipe\\agent")
          7))
      (set!
        failed
        (first-failure
          failed
          (local_ipc.windows-pipe-valid? "\\\\.\\PIPE\\agent")
          8))
      (set!
        failed
        (first-failure
          failed
          (not (local_ipc.windows-pipe-valid? "\\\\server\\pipe\\agent"))
          9))
      (set!
        failed
        (first-failure
          failed
          (not (local_ipc.windows-pipe-valid? "\\\\.\\pipe\\"))
          10))
      (set!
        failed
        (first-failure
          failed
          (not (local_ipc.windows-pipe-valid? "\\\\.\\pipe\\a\\b"))
          11))
      (set!
        failed
        (first-failure
          failed
          (not (local_ipc.windows-pipe-valid? "//./pipe/agent"))
          12))
      (set!
        failed
        (first-failure failed (not (local_ipc.windows-pipe-valid? "")) 13))
      (set!
        failed
        (first-failure
          failed
          (local_ipc.windows-pipe-valid? (& pipe-long-ok))
          14))
      (set!
        failed
        (first-failure
          failed
          (not (local_ipc.windows-pipe-valid? (& pipe-long-bad)))
          15))
      failed)))

;; An invalid endpoint never reaches the adapter.
(define (case-invalid-endpoint-no-dispatch) : i64
  (let
    [context : i64 (fake.new)]
    [failed : i64 0]
    (with
      ([connection
          (local_ipc.connect
            (fake.adapter context)
            (& remote-pipe)
            local_ipc.accept-any-peer
            far-deadline
            local_ipc.never-canceled
            16)
          local_ipc.cleanup-local-ipc-connection])
      (begin
        (set!
          failed
          (first-failure
            failed
            (= (kind-of (local_ipc.connection-result (& connection))) 1)
            20))
        (set!
          failed
          (first-failure
            failed
            (not (local_ipc.connection-open? (& connection)))
            21))
        (set!
          failed
          (first-failure
            failed
            (= (fake.get context fake.slot-connect-calls) 0)
            22))
        (set!
          failed
          (first-failure failed (= (fake.get context fake.slot-now-calls) 0) 23))
        failed))))

(define (case-connect-and-close) : i64
  (let
    [context : i64 (fake.new)]
    [buffer : byte_buf.ByteBuf (zero-buf 8)]
    [failed : i64 0]
    (with
      ([connection (open context) local_ipc.cleanup-local-ipc-connection])
      (let
        [peer : local_ipc.LocalIpcPeer
          (local_ipc.connection-peer (& connection))]
        (begin
          (set!
            failed
            (first-failure
              failed
              (= (kind-of (local_ipc.connection-result (& connection))) 0)
              30))
          (set!
            failed
            (first-failure
              failed
              (local_ipc.connection-open? (& connection))
              31))
          (set!
            failed
            (first-failure
              failed
              (= (fake.get context fake.slot-connect-calls) 1)
              32))
          (set!
            failed
            (first-failure
              failed
              (= (fake.get context fake.slot-peer-calls) 1)
              33))
          (set!
            failed
            (first-failure
              failed
              (= (fake.get context fake.slot-last-family) 0)
              34))
          (set!
            failed
            (first-failure
              failed
              (= (fake.get context fake.slot-last-name-len) 15)
              35))
          (set!
            failed
            (first-failure
              failed
              (and
                (= peer.process-id 41)
                (= peer.user-id 42)
                (= peer.group-id 43)
                (= peer.session-id 44))
              36))
          (set!
            failed
            (first-failure
              failed
              (= (kind-of (local_ipc.close! (&mut connection))) 0)
              37))
          (set!
            failed
            (first-failure
              failed
              (= (fake.get context fake.slot-close-calls) 1)
              38))
          (set!
            failed
            (first-failure
              failed
              (= (fake.get context fake.slot-last-closed-handle) 7)
              39))
          ;; Closing again, and any use after close, fails before dispatch.
          (set!
            failed
            (first-failure
              failed
              (= (kind-of (local_ipc.close! (&mut connection))) 11)
              40))
          (set!
            failed
            (first-failure
              failed
              (= (fake.get context fake.slot-close-calls) 1)
              41))
          (set!
            failed
            (first-failure
              failed
              (=
                (io-kind
                  (local_ipc.read-some!
                    (&mut connection)
                    (byte_buf.as-mut-bytes (&mut buffer))
                    0
                    8))
                11)
              43))
          (set!
            failed
            (first-failure
              failed
              (= (fake.get context fake.slot-read-calls) 0)
              44))
          ;; The construction result does not change when the connection closes.
          (set!
            failed
            (first-failure
              failed
              (= (kind-of (local_ipc.connection-result (& connection))) 0)
              45))
          (set!
            failed
            (first-failure
              failed
              (not (local_ipc.connection-open? (& connection)))
              46))
          failed)))))

;; A reported close failure is returned once; the handle is still released.
(define (case-close-failure) : i64
  (let
    [context : i64 (fake.new)]
    [_kind : unit (fake.put! context fake.slot-close-kind 15)]
    [failed : i64 0]
    (with
      ([connection (open context) local_ipc.cleanup-local-ipc-connection])
      (begin
        (set!
          failed
          (first-failure
            failed
            (= (kind-of (local_ipc.close! (&mut connection))) 15)
            50))
        (set!
          failed
          (first-failure
            failed
            (= (kind-of (local_ipc.close! (&mut connection))) 11)
            51))
        (set!
          failed
          (first-failure
            failed
            (= (fake.get context fake.slot-close-calls) 1)
            52))
        failed))))

(define (scoped-connection [context : i64]) : bool
  (with
    ([connection (open context) local_ipc.cleanup-local-ipc-connection])
    (local_ipc.connection-open? (& connection))))

(define (scoped-closed-connection [context : i64]) : bool
  (with
    ([connection (open context) local_ipc.cleanup-local-ipc-connection])
    (local_ipc.status-ok? (local_ipc.close! (&mut connection)))))

;; Lexical cleanup closes exactly once and is a no-op after an explicit close.
(define (case-lexical-cleanup) : i64
  (let
    [first : i64 (fake.new)]
    [second : i64 (fake.new)]
    [was-open : bool (scoped-connection first)]
    [was-closed : bool (scoped-closed-connection second)]
    [failed : i64 0]
    (begin
      (set! failed (first-failure failed was-open 55))
      (set!
        failed
        (first-failure failed (= (fake.get first fake.slot-close-calls) 1) 56))
      (set! failed (first-failure failed was-closed 57))
      (set!
        failed
        (first-failure failed (= (fake.get second fake.slot-close-calls) 1) 58))
      failed)))

(define (case-windows-family) : i64
  (let
    [context : i64 (fake.new)]
    [failed : i64 0]
    (with
      ([connection
          (local_ipc.connect
            (fake.adapter context)
            (& agent-pipe)
            local_ipc.accept-any-peer
            far-deadline
            local_ipc.never-canceled
            16)
          local_ipc.cleanup-local-ipc-connection])
      (begin
        (set!
          failed
          (first-failure failed (local_ipc.connection-open? (& connection)) 60))
        (set!
          failed
          (first-failure
            failed
            (= (fake.get context fake.slot-last-family) 1)
            61))
        (set!
          failed
          (first-failure
            failed
            (= (fake.get context fake.slot-last-name-len) 14)
            62))
        failed))))

;; RetryConnect publishes nothing, pauses one bounded slice and tries afresh.
(define (case-connect-retry) : i64
  (let
    [context : i64 (fake.new)]
    [_a : unit (fake.push! context fake.queue-connect 1)]
    [_b : unit (fake.push! context fake.queue-connect 1)]
    [_c : unit (fake.push! context fake.queue-connect 0)]
    [kind : i64 (connect-kind context far-deadline 16)]
    [failed : i64 0]
    (begin
      (set! failed (first-failure failed (= kind 0) 65))
      (set!
        failed
        (first-failure
          failed
          (= (fake.get context fake.slot-connect-calls) 3)
          66))
      (set!
        failed
        (first-failure failed (= (fake.get context fake.slot-delay-calls) 2) 67))
      (set!
        failed
        (first-failure failed (= (fake.get context fake.slot-max-slice) 100) 68))
      ;; The published connection is closed once, by its scope.
      (set!
        failed
        (first-failure failed (= (fake.get context fake.slot-close-calls) 1) 69))
      failed)))

;; A busy endpoint is retried in slices that shrink to the deadline.
(define (case-connect-timeout) : i64
  (let
    [context : i64 (fake.new)]
    [_a : unit (fake.push! context fake.queue-connect 1)]
    [kind : i64 (connect-kind context 1250 64)]
    [failed : i64 0]
    (begin
      (set! failed (first-failure failed (= kind 5) 70))
      (set!
        failed
        (first-failure
          failed
          (= (fake.get context fake.slot-connect-calls) 3)
          71))
      (set!
        failed
        (first-failure failed (= (fake.get context fake.slot-delay-calls) 3) 72))
      (set!
        failed
        (first-failure failed (= (fake.get context fake.slot-max-slice) 100) 73))
      (set!
        failed
        (first-failure failed (= (fake.get context fake.slot-min-slice) 50) 74))
      (set!
        failed
        (first-failure failed (= (fake.get context fake.slot-close-calls) 0) 75))
      failed)))

(define (case-connect-cancel-between-attempts) : i64
  (let
    [context : i64 (fake.new)]
    [_a : unit (fake.push! context fake.queue-connect 1)]
    [_b : unit (fake.put! context fake.slot-cancel-after-now-calls 2)]
    [kind : i64 (connect-kind context far-deadline 64)]
    [failed : i64 0]
    (begin
      (set! failed (first-failure failed (= kind 6) 80))
      (set!
        failed
        (first-failure
          failed
          (= (fake.get context fake.slot-connect-calls) 1)
          81))
      failed)))

;; Cancellation beats an expired deadline; an expired deadline beats an attempt.
(define (case-connect-precedence) : i64
  (let
    [canceled : i64 (fake.new)]
    [_a : unit (fake.put! canceled fake.slot-cancel-after-now-calls 0)]
    [first : i64 (connect-kind canceled 1000 64)]
    [expired : i64 (fake.new)]
    [second : i64 (connect-kind expired 1000 64)]
    [no-clock : i64 (fake.new)]
    [_b : unit (fake.put! no-clock fake.slot-clock -1)]
    [third : i64 (connect-kind no-clock far-deadline 64)]
    [failed : i64 0]
    (begin
      (set! failed (first-failure failed (= first 6) 85))
      (set!
        failed
        (first-failure
          failed
          (= (fake.get canceled fake.slot-connect-calls) 0)
          86))
      (set! failed (first-failure failed (= second 5) 87))
      (set!
        failed
        (first-failure
          failed
          (= (fake.get expired fake.slot-connect-calls) 0)
          88))
      (set! failed (first-failure failed (= third 9) 89))
      (set!
        failed
        (first-failure
          failed
          (= (fake.get no-clock fake.slot-connect-calls) 0)
          90))
      failed)))

(define (case-connect-budget) : i64
  (let
    [context : i64 (fake.new)]
    [_a : unit (fake.push! context fake.queue-connect 1)]
    [kind : i64 (connect-kind context far-deadline 2)]
    [failed : i64 0]
    (begin
      (set! failed (first-failure failed (= kind 13) 95))
      (set!
        failed
        (first-failure
          failed
          (= (fake.get context fake.slot-connect-calls) 2)
          96))
      (set!
        failed
        (first-failure failed (= (fake.get context fake.slot-delay-calls) 1) 97))
      failed)))

;; Failures after the kernel connected close the handle exactly once.
(define (case-connect-rejections) : i64
  (let
    [denied : i64 (fake.new)]
    [_a : unit (fake.push! denied fake.queue-connect 103)]
    [first : i64 (connect-kind-with-policy denied local_ipc.accept-any-peer)]
    [policy : i64 (fake.new)]
    [second : i64 (connect-kind-with-policy policy reject-peer)]
    [peer-failed : i64 (fake.new)]
    [_b : unit (fake.put! peer-failed fake.slot-peer-kind 2)]
    [third : i64
      (connect-kind-with-policy peer-failed local_ipc.accept-any-peer)]
    [peer-corrupt : i64 (fake.new)]
    [_c : unit (fake.put! peer-corrupt fake.slot-peer-process -7)]
    [fourth : i64
      (connect-kind-with-policy peer-corrupt local_ipc.accept-any-peer)]
    [bad-handle : i64 (fake.new)]
    [_d : unit (fake.push! bad-handle fake.queue-connect 99)]
    [fifth : i64
      (connect-kind-with-policy bad-handle local_ipc.accept-any-peer)]
    [selective : i64 (fake.new)]
    [sixth : i64 (connect-kind-with-policy selective only-user-42)]
    [failed : i64 0]
    (begin
      (set! failed (first-failure failed (= first 3) 100))
      (set!
        failed
        (first-failure failed (= (fake.get denied fake.slot-close-calls) 0) 101))
      (set! failed (first-failure failed (= second 14) 102))
      (set!
        failed
        (first-failure failed (= (fake.get policy fake.slot-close-calls) 1) 103))
      (set! failed (first-failure failed (= third 2) 105))
      (set!
        failed
        (first-failure
          failed
          (= (fake.get peer-failed fake.slot-close-calls) 1)
          106))
      (set! failed (first-failure failed (= fourth 10) 107))
      (set!
        failed
        (first-failure
          failed
          (= (fake.get peer-corrupt fake.slot-close-calls) 1)
          108))
      (set! failed (first-failure failed (= fifth 10) 109))
      (set!
        failed
        (first-failure
          failed
          (= (fake.get bad-handle fake.slot-close-calls) 0)
          110))
      (set! failed (first-failure failed (= sixth 0) 111))
      failed)))

(define (case-primitive-read) : i64
  (let
    [context : i64 (fake.new)]
    [buffer : byte_buf.ByteBuf (zero-buf 8)]
    [_a : unit (fake.push! context fake.queue-data 3)]
    [_b : unit (fake.push! context fake.queue-data -1)]
    [_c : unit (fake.push! context fake.queue-data -2)]
    [_d : unit (fake.push! context fake.queue-data -3)]
    [_e : unit (fake.push! context fake.queue-data -108)]
    [_f : unit (fake.push! context fake.queue-data -5)]
    [_g : unit (fake.push! context fake.queue-data -6)]
    [failed : i64 0]
    (with
      ([connection (open context) local_ipc.cleanup-local-ipc-connection])
      (let
        [partial : local_ipc.LocalIpcIoResult
          (local_ipc.read-some!
            (&mut connection)
            (byte_buf.as-mut-bytes (&mut buffer))
            2
            6)]
        [blocked : local_ipc.LocalIpcIoResult
          (local_ipc.read-some!
            (&mut connection)
            (byte_buf.as-mut-bytes (&mut buffer))
            0
            8)]
        [interrupted : local_ipc.LocalIpcIoResult
          (local_ipc.read-some!
            (&mut connection)
            (byte_buf.as-mut-bytes (&mut buffer))
            0
            8)]
        [eof : local_ipc.LocalIpcIoResult
          (local_ipc.read-some!
            (&mut connection)
            (byte_buf.as-mut-bytes (&mut buffer))
            0
            8)]
        [host : local_ipc.LocalIpcIoResult
          (local_ipc.read-some!
            (&mut connection)
            (byte_buf.as-mut-bytes (&mut buffer))
            0
            8)]
        [too-many : local_ipc.LocalIpcIoResult
          (local_ipc.read-some!
            (&mut connection)
            (byte_buf.as-mut-bytes (&mut buffer))
            0
            8)]
        [calls-before-zero : i64 (fake.get context fake.slot-read-calls)]
        [empty : local_ipc.LocalIpcIoResult
          (local_ipc.read-some!
            (&mut connection)
            (byte_buf.as-mut-bytes (&mut buffer))
            8
            0)]
        [negative-start : local_ipc.LocalIpcIoResult
          (local_ipc.read-some!
            (&mut connection)
            (byte_buf.as-mut-bytes (&mut buffer))
            -1
            2)]
        [negative-count : local_ipc.LocalIpcIoResult
          (local_ipc.read-some!
            (&mut connection)
            (byte_buf.as-mut-bytes (&mut buffer))
            0
            -1)]
        [past-end : local_ipc.LocalIpcIoResult
          (local_ipc.read-some!
            (&mut connection)
            (byte_buf.as-mut-bytes (&mut buffer))
            4
            5)]
        [calls-after-rejected : i64 (fake.get context fake.slot-read-calls)]
        [zero-progress : local_ipc.LocalIpcIoResult
          (local_ipc.read-some!
            (&mut connection)
            (byte_buf.as-mut-bytes (&mut buffer))
            0
            8)]
        (begin
          (set! failed (first-failure failed (= (io-done partial) 3) 120))
          (set!
            failed
            (first-failure
              failed
              (and
                (= (cast (byte_buf.ref (& buffer) 1) : i64) 0)
                (= (cast (byte_buf.ref (& buffer) 2) : i64) 1)
                (= (cast (byte_buf.ref (& buffer) 4) : i64) 3)
                (= (cast (byte_buf.ref (& buffer) 5) : i64) 0))
              121))
          (set! failed (first-failure failed (io-would-block? blocked) 122))
          (set! failed (first-failure failed (io-interrupted? interrupted) 123))
          (set! failed (first-failure failed (io-eof? eof) 124))
          (set!
            failed
            (first-failure
              failed
              (and (= (io-kind host) 8) (= (io-host-code host) 222))
              125))
          (set! failed (first-failure failed (= (io-kind too-many) 10) 126))
          (set! failed (first-failure failed (= (io-done empty) 0) 128))
          (set!
            failed
            (first-failure failed (= (io-kind negative-start) 12) 129))
          (set!
            failed
            (first-failure failed (= (io-kind negative-count) 12) 130))
          (set! failed (first-failure failed (= (io-kind past-end) 12) 131))
          ;; The zero-length and rejected ranges made no host call.
          (set! failed (first-failure failed (= calls-before-zero 6) 132))
          (set! failed (first-failure failed (= calls-after-rejected 6) 133))
          (set!
            failed
            (first-failure failed (= (io-kind zero-progress) 10) 127))
          failed)))))

(define (case-primitive-write) : i64
  (let
    [context : i64 (fake.new)]
    [buffer : byte_buf.ByteBuf (counted-buf 6)]
    [_a : unit (fake.push! context fake.queue-data 2)]
    [failed : i64 0]
    (with
      ([connection (open context) local_ipc.cleanup-local-ipc-connection])
      (let
        [written : local_ipc.LocalIpcIoResult
          (local_ipc.write-some!
            (&mut connection)
            (byte_buf.as-bytes (& buffer))
            3
            3)]
        [past-end : local_ipc.LocalIpcIoResult
          (local_ipc.write-some!
            (&mut connection)
            (byte_buf.as-bytes (& buffer))
            6
            1)]
        (begin
          (set! failed (first-failure failed (= (io-done written) 2) 135))
          ;; Bytes 4 and 5 of 1..6 were handed to the adapter.
          (set!
            failed
            (first-failure
              failed
              (= (fake.get context fake.slot-written-sum) 9)
              136))
          (set! failed (first-failure failed (= (io-kind past-end) 12) 137))
          (set!
            failed
            (first-failure
              failed
              (= (fake.get context fake.slot-write-calls) 1)
              138))
          failed)))))

;; A pending operation owns the buffer until its terminal completion: the
;; contract requests cancellation, then drains in bounded slices and issues no
;; other host call meanwhile.
(define (case-pending) : i64
  (let
    [wins : i64 (fake.new)]
    [_a : unit (fake.push! wins fake.queue-data -4)]
    [_b : unit (fake.push! wins fake.queue-pending -4)]
    [_c : unit (fake.push! wins fake.queue-pending -4)]
    [_d : unit (fake.push! wins fake.queue-pending 5)]
    [progress : local_ipc.LocalIpcIoResult (pending-read wins)]
    [lost : i64 (fake.new)]
    [_e : unit (fake.push! lost fake.queue-data -4)]
    [_f : unit (fake.push! lost fake.queue-pending -106)]
    [canceled : local_ipc.LocalIpcIoResult (pending-read lost)]
    [other : i64 (fake.new)]
    [_g : unit (fake.push! other fake.queue-data -4)]
    [_h : unit (fake.push! other fake.queue-pending -4)]
    [_i : unit (fake.push! other fake.queue-pending -115)]
    [errored : local_ipc.LocalIpcIoResult (pending-read other)]
    [oversized : i64 (fake.new)]
    [_j : unit (fake.push! oversized fake.queue-data -4)]
    [_k : unit (fake.push! oversized fake.queue-pending 9)]
    [too-many : local_ipc.LocalIpcIoResult (pending-read oversized)]
    [failed : i64 0]
    (begin
      (set! failed (first-failure failed (= (io-done progress) 5) 140))
      (set!
        failed
        (first-failure
          failed
          (= (fake.get wins fake.slot-cancel-pending-calls) 1)
          141))
      (set!
        failed
        (first-failure failed (= (fake.get wins fake.slot-poll-calls) 3) 142))
      (set!
        failed
        (first-failure
          failed
          (= (fake.get wins fake.slot-calls-while-pending) 0)
          143))
      (set!
        failed
        (first-failure failed (<= (fake.get wins fake.slot-max-slice) 100) 144))
      (set! failed (first-failure failed (= (io-kind canceled) 6) 145))
      (set! failed (first-failure failed (= (io-kind errored) 15) 146))
      (set!
        failed
        (first-failure failed (= (fake.get other fake.slot-poll-calls) 2) 147))
      (set! failed (first-failure failed (= (io-kind too-many) 10) 148))
      failed)))

;; An operation that never completes ends with a forced close, not a return
;; that would leave the buffer owned by the adapter.
(define (case-pending-never-completes) : i64
  (let
    [context : i64 (fake.new)]
    [_a : unit (fake.push! context fake.queue-data -4)]
    [buffer : byte_buf.ByteBuf (zero-buf 8)]
    [failed : i64 0]
    (with
      ([connection (open context) local_ipc.cleanup-local-ipc-connection])
      (let
        [result : local_ipc.LocalIpcIoResult
          (local_ipc.read-some!
            (&mut connection)
            (byte_buf.as-mut-bytes (&mut buffer))
            0
            8)]
        (begin
          (set! failed (first-failure failed (= (io-kind result) 10) 150))
          (set!
            failed
            (first-failure
              failed
              (= (fake.get context fake.slot-poll-calls) 600)
              151))
          (set!
            failed
            (first-failure
              failed
              (= (fake.get context fake.slot-close-calls) 1)
              152))
          (set!
            failed
            (first-failure
              failed
              (not (local_ipc.connection-open? (& connection)))
              153))
          (set!
            failed
            (first-failure
              failed
              (= (fake.get context fake.slot-calls-while-pending) 0)
              154))
          failed)))))

(define (case-wait-retries) : i64
  (let
    [context : i64 (fake.new)]
    [_a : unit (fake.push! context fake.queue-data -1)]
    [_b : unit (fake.push! context fake.queue-data -2)]
    [_c : unit (fake.push! context fake.queue-data 4)]
    [result : local_ipc.LocalIpcIoResult
      (read-wait-case context far-deadline 16 false)]
    [failed : i64 0]
    (begin
      (set! failed (first-failure failed (= (io-done result) 4) 160))
      (set!
        failed
        (first-failure failed (= (fake.get context fake.slot-read-calls) 3) 161))
      (set!
        failed
        (first-failure failed (= (fake.get context fake.slot-wait-calls) 1) 162))
      (set!
        failed
        (first-failure
          failed
          (= (fake.get context fake.slot-max-slice) 100)
          163))
      failed)))

;; Waits are at most 100 ms and are recomputed after every wake.
(define (case-wait-timeout-slices) : i64
  (let
    [context : i64 (fake.new)]
    [_a : unit (fake.push! context fake.queue-data -1)]
    [_b : unit (fake.push! context fake.queue-wait 1)]
    [result : local_ipc.LocalIpcIoResult (read-wait-case context 1130 64 false)]
    [failed : i64 0]
    (begin
      (set! failed (first-failure failed (= (io-kind result) 5) 165))
      (set!
        failed
        (first-failure failed (= (fake.get context fake.slot-read-calls) 2) 166))
      (set!
        failed
        (first-failure failed (= (fake.get context fake.slot-wait-calls) 2) 167))
      (set!
        failed
        (first-failure
          failed
          (= (fake.get context fake.slot-max-slice) 100)
          168))
      (set!
        failed
        (first-failure failed (= (fake.get context fake.slot-min-slice) 30) 169))
      failed)))

(define (case-wait-precedence) : i64
  (let
    [expired : i64 (fake.new)]
    [timed-out : local_ipc.LocalIpcIoResult
      (read-wait-case expired 1000 16 false)]
    [both : i64 (fake.new)]
    [_a : unit (fake.put! both fake.slot-cancel-after-now-calls 0)]
    [canceled : local_ipc.LocalIpcIoResult (read-wait-case both 1000 16 false)]
    ;; Progress committed by the attempt is kept although cancellation became
    ;; visible while it ran: connect reads the clock once, the read once more.
    [late : i64 (fake.new)]
    [_b : unit (fake.push! late fake.queue-data 2)]
    [_c : unit (fake.put! late fake.slot-cancel-after-now-calls 2)]
    [kept : local_ipc.LocalIpcIoResult
      (read-wait-case late far-deadline 16 false)]
    [failed : i64 0]
    (begin
      (set! failed (first-failure failed (= (io-kind timed-out) 5) 170))
      (set!
        failed
        (first-failure failed (= (fake.get expired fake.slot-read-calls) 0) 171))
      (set! failed (first-failure failed (= (io-kind canceled) 6) 172))
      (set!
        failed
        (first-failure failed (= (fake.get both fake.slot-read-calls) 0) 173))
      (set! failed (first-failure failed (= (io-done kept) 2) 174))
      (set! failed (first-failure failed (fake.canceled? late) 175))
      failed)))

;; A wait-capable helper waits for a pending operation in bounded slices. It
;; requests cancellation only once a stop reason appears, then drains, and the
;; stop reason is the result unless progress won the race.
(define (case-wait-pending) : i64
  (let
    [completes : i64 (fake.new)]
    [_a : unit (fake.push! completes fake.queue-data -4)]
    [_b : unit (fake.push! completes fake.queue-pending -4)]
    [_c : unit (fake.push! completes fake.queue-pending -4)]
    [_d : unit (fake.push! completes fake.queue-pending 6)]
    [done : local_ipc.LocalIpcIoResult
      (read-wait-case completes far-deadline 16 false)]
    [stopped : i64 (fake.new)]
    [_e : unit (fake.push! stopped fake.queue-data -4)]
    [_f : unit (fake.push! stopped fake.queue-pending -4)]
    [_g : unit (fake.push! stopped fake.queue-pending -4)]
    [_h : unit (fake.push! stopped fake.queue-pending -106)]
    [timed-out : local_ipc.LocalIpcIoResult
      (read-wait-case stopped 1150 16 false)]
    [raced : i64 (fake.new)]
    [_i : unit (fake.push! raced fake.queue-data -4)]
    [_j : unit (fake.push! raced fake.queue-pending -4)]
    [_k : unit (fake.push! raced fake.queue-pending -4)]
    [_l : unit (fake.push! raced fake.queue-pending 5)]
    [won : local_ipc.LocalIpcIoResult (read-wait-case raced 1150 16 false)]
    [failed : i64 0]
    (begin
      (set! failed (first-failure failed (= (io-done done) 6) 225))
      (set!
        failed
        (first-failure
          failed
          (= (fake.get completes fake.slot-cancel-pending-calls) 0)
          226))
      (set!
        failed
        (first-failure
          failed
          (= (fake.get completes fake.slot-poll-calls) 3)
          227))
      (set!
        failed
        (first-failure
          failed
          (= (fake.get completes fake.slot-read-calls) 1)
          228))
      (set!
        failed
        (first-failure
          failed
          (= (fake.get completes fake.slot-calls-while-pending) 0)
          229))
      ;; Polls of 100 ms and 50 ms reach the 1150 deadline; the third poll is the drain.
      (set! failed (first-failure failed (= (io-kind timed-out) 5) 230))
      (set!
        failed
        (first-failure
          failed
          (= (fake.get stopped fake.slot-cancel-pending-calls) 1)
          231))
      (set!
        failed
        (first-failure failed (= (fake.get stopped fake.slot-poll-calls) 3) 232))
      (set!
        failed
        (first-failure failed (= (fake.get stopped fake.slot-read-calls) 1) 233))
      (set! failed (first-failure failed (= (io-done won) 5) 234))
      (set!
        failed
        (first-failure
          failed
          (= (fake.get raced fake.slot-cancel-pending-calls) 1)
          235))
      failed)))

;; An interrupted readiness wait is retried like a not-ready one.
(define (case-wait-interrupted) : i64
  (let
    [context : i64 (fake.new)]
    [_a : unit (fake.push! context fake.queue-data -1)]
    [_b : unit (fake.push! context fake.queue-data -1)]
    [_c : unit (fake.push! context fake.queue-data 4)]
    [_d : unit (fake.push! context fake.queue-wait 2)]
    [_e : unit (fake.push! context fake.queue-wait 0)]
    [result : local_ipc.LocalIpcIoResult
      (read-wait-case context far-deadline 16 false)]
    [failed : i64 0]
    (begin
      (set! failed (first-failure failed (= (io-done result) 4) 236))
      (set!
        failed
        (first-failure failed (= (fake.get context fake.slot-read-calls) 3) 237))
      (set!
        failed
        (first-failure failed (= (fake.get context fake.slot-wait-calls) 2) 238))
      failed)))

(define (case-wait-budget-and-failures) : i64
  (let
    [budget : i64 (fake.new)]
    [_a : unit (fake.push! budget fake.queue-data -1)]
    [exhausted : local_ipc.LocalIpcIoResult
      (read-wait-case budget far-deadline 3 false)]
    [waiting : i64 (fake.new)]
    [_b : unit (fake.push! waiting fake.queue-data -1)]
    [_c : unit (fake.push! waiting fake.queue-wait 103)]
    [wait-failed : local_ipc.LocalIpcIoResult
      (read-wait-case waiting far-deadline 16 false)]
    [closed : i64 (fake.new)]
    [after-close : local_ipc.LocalIpcIoResult
      (read-wait-case closed far-deadline 16 true)]
    [failed : i64 0]
    (begin
      (set! failed (first-failure failed (= (io-kind exhausted) 13) 180))
      (set!
        failed
        (first-failure failed (= (fake.get budget fake.slot-read-calls) 2) 181))
      (set!
        failed
        (first-failure failed (= (fake.get budget fake.slot-wait-calls) 1) 182))
      (set!
        failed
        (first-failure
          failed
          (and (= (io-kind wait-failed) 3) (= (io-host-code wait-failed) 333))
          183))
      (set! failed (first-failure failed (= (io-kind after-close) 11) 184))
      (set!
        failed
        (first-failure failed (= (fake.get closed fake.slot-read-calls) 0) 185))
      failed)))

(define (case-write-all) : i64
  (let
    [context : i64 (fake.new)]
    [_a : unit (fake.push! context fake.queue-data 3)]
    [_b : unit (fake.push! context fake.queue-data -1)]
    [_c : unit (fake.push! context fake.queue-data 4)]
    [_d : unit (fake.push! context fake.queue-data -2)]
    [_e : unit (fake.push! context fake.queue-data 3)]
    [transfer : local_ipc.LocalIpcTransfer
      (write-all-case context far-deadline 32)]
    [failed : i64 0]
    (begin
      (set! failed (first-failure failed (= transfer.count 10) 190))
      (set! failed (first-failure failed (= (kind-of transfer.status) 0) 191))
      (set!
        failed
        (first-failure
          failed
          (= (fake.get context fake.slot-written-sum) 55)
          192))
      (set!
        failed
        (first-failure
          failed
          (= (fake.get context fake.slot-write-calls) 5)
          193))
      (set!
        failed
        (first-failure failed (= (fake.get context fake.slot-wait-calls) 1) 194))
      failed)))

;; Whole-buffer helpers keep the completed count whatever stops them.
(define (case-transfer-stops) : i64
  (let
    [eof : i64 (fake.new)]
    [_a : unit (fake.push! eof fake.queue-data 4)]
    [_b : unit (fake.push! eof fake.queue-data -3)]
    [at-eof : local_ipc.LocalIpcTransfer (write-all-case eof far-deadline 32)]
    [timeout : i64 (fake.new)]
    [_c : unit (fake.push! timeout fake.queue-data 4)]
    [_d : unit (fake.push! timeout fake.queue-data -1)]
    [_e : unit (fake.push! timeout fake.queue-wait 1)]
    [at-timeout : local_ipc.LocalIpcTransfer (write-all-case timeout 1150 64)]
    [budget : i64 (fake.new)]
    [_f : unit (fake.push! budget fake.queue-data 1)]
    [at-budget : local_ipc.LocalIpcTransfer
      (write-all-case budget far-deadline 3)]
    [errored : i64 (fake.new)]
    [_g : unit (fake.push! errored fake.queue-data 2)]
    [_h : unit (fake.push! errored fake.queue-data -108)]
    [at-error : local_ipc.LocalIpcTransfer
      (write-all-case errored far-deadline 32)]
    ;; connect reads the clock once and the first write attempt once more.
    [cancel : i64 (fake.new)]
    [_i : unit (fake.push! cancel fake.queue-data 4)]
    [_j : unit (fake.put! cancel fake.slot-cancel-after-now-calls 2)]
    [at-cancel : local_ipc.LocalIpcTransfer
      (write-all-case cancel far-deadline 32)]
    [failed : i64 0]
    (begin
      (set!
        failed
        (first-failure
          failed
          (and (= at-eof.count 4) (= (kind-of at-eof.status) 7))
          200))
      (set!
        failed
        (first-failure
          failed
          (and (= at-timeout.count 4) (= (kind-of at-timeout.status) 5))
          201))
      (set!
        failed
        (first-failure
          failed
          (and (= at-budget.count 3) (= (kind-of at-budget.status) 13))
          202))
      (set!
        failed
        (first-failure
          failed
          (and (= at-error.count 2) (= (kind-of at-error.status) 8))
          203))
      (set!
        failed
        (first-failure
          failed
          (and (= at-cancel.count 4) (= (kind-of at-cancel.status) 6))
          204))
      failed)))

(define (case-read-exact-and-ranges) : i64
  (let
    [context : i64 (fake.new)]
    [buffer : byte_buf.ByteBuf (zero-buf 8)]
    [_a : unit (fake.push! context fake.queue-data 3)]
    [_b : unit (fake.push! context fake.queue-data 5)]
    [failed : i64 0]
    (with
      ([connection (open context) local_ipc.cleanup-local-ipc-connection])
      (let
        [exact : local_ipc.LocalIpcTransfer
          (local_ipc.read-exact!
            (&mut connection)
            (byte_buf.as-mut-bytes (&mut buffer))
            2
            6
            far-deadline
            local_ipc.never-canceled
            16)]
        [calls : i64 (fake.get context fake.slot-read-calls)]
        [empty : local_ipc.LocalIpcTransfer
          (local_ipc.read-exact!
            (&mut connection)
            (byte_buf.as-mut-bytes (&mut buffer))
            8
            0
            far-deadline
            local_ipc.never-canceled
            16)]
        [invalid : local_ipc.LocalIpcTransfer
          (local_ipc.read-exact!
            (&mut connection)
            (byte_buf.as-mut-bytes (&mut buffer))
            4
            5
            far-deadline
            local_ipc.never-canceled
            16)]
        (begin
          (set!
            failed
            (first-failure
              failed
              (and (= exact.count 6) (= (kind-of exact.status) 0))
              210))
          ;; The second attempt continued at offset 2 + 3 and was clamped to 3 bytes.
          (set!
            failed
            (first-failure
              failed
              (and
                (= (cast (byte_buf.ref (& buffer) 2) : i64) 1)
                (= (cast (byte_buf.ref (& buffer) 4) : i64) 3)
                (= (cast (byte_buf.ref (& buffer) 5) : i64) 1)
                (= (cast (byte_buf.ref (& buffer) 7) : i64) 3))
              211))
          (set! failed (first-failure failed (= calls 2) 212))
          (set!
            failed
            (first-failure
              failed
              (and (= empty.count 0) (= (kind-of empty.status) 0))
              213))
          (set!
            failed
            (first-failure
              failed
              (and (= invalid.count 0) (= (kind-of invalid.status) 12))
              214))
          (set!
            failed
            (first-failure
              failed
              (= (fake.get context fake.slot-read-calls) 2)
              215))
          failed)))))

;; Errors carry a kind and a bounded host code, never text.
(define (case-stable-errors) : i64
  (let
    [kept : local_ipc.LocalIpcError
      (local_ipc.make-error (local_ipc.LocalIpcErrorKind.Busy) 65535)]
    [too-large : local_ipc.LocalIpcError
      (local_ipc.make-error (local_ipc.LocalIpcErrorKind.Busy) 65536)]
    [negative : local_ipc.LocalIpcError
      (local_ipc.make-error (local_ipc.LocalIpcErrorKind.Busy) -1)]
    [code : i64 1]
    [names-ok : bool true]
    [failed : i64 0]
    (begin
      (while (<= code 15)
        (begin
          (set!
            names-ok
            (and
              names-ok
              (= (local_ipc.error-kind-code (fake.kind-from-code code)) code)
              (>
                (string.string-length
                  (local_ipc.error-kind-name (fake.kind-from-code code)))
                3)))
          (set! code (+ code 1))))
      (set! failed (first-failure failed (= kept.host-code 65535) 220))
      (set! failed (first-failure failed (= too-large.host-code 0) 221))
      (set! failed (first-failure failed (= negative.host-code 0) 222))
      (set! failed (first-failure failed names-ok 223))
      (set!
        failed
        (first-failure
          failed
          (string.eq
            (local_ipc.error-kind-name
              (local_ipc.LocalIpcErrorKind.PermissionDenied))
            "permission-denied")
          224))
      failed)))

(define (first-nonzero [current : i64] [next : i64]) : i64
  (if (= current 0)
    next
    current))

(define (main) : i64
  (let
    [failed : i64 0]
    (begin
      (set! failed (first-nonzero failed (case-endpoints)))
      (set! failed (first-nonzero failed (case-invalid-endpoint-no-dispatch)))
      (set! failed (first-nonzero failed (case-connect-and-close)))
      (set! failed (first-nonzero failed (case-close-failure)))
      (set! failed (first-nonzero failed (case-lexical-cleanup)))
      (set! failed (first-nonzero failed (case-windows-family)))
      (set! failed (first-nonzero failed (case-connect-retry)))
      (set! failed (first-nonzero failed (case-connect-timeout)))
      (set!
        failed
        (first-nonzero failed (case-connect-cancel-between-attempts)))
      (set! failed (first-nonzero failed (case-connect-precedence)))
      (set! failed (first-nonzero failed (case-connect-budget)))
      (set! failed (first-nonzero failed (case-connect-rejections)))
      (set! failed (first-nonzero failed (case-primitive-read)))
      (set! failed (first-nonzero failed (case-primitive-write)))
      (set! failed (first-nonzero failed (case-pending)))
      (set! failed (first-nonzero failed (case-pending-never-completes)))
      (set! failed (first-nonzero failed (case-wait-retries)))
      (set! failed (first-nonzero failed (case-wait-timeout-slices)))
      (set! failed (first-nonzero failed (case-wait-precedence)))
      (set! failed (first-nonzero failed (case-wait-pending)))
      (set! failed (first-nonzero failed (case-wait-interrupted)))
      (set! failed (first-nonzero failed (case-wait-budget-and-failures)))
      (set! failed (first-nonzero failed (case-write-all)))
      (set! failed (first-nonzero failed (case-transfer-stops)))
      (set! failed (first-nonzero failed (case-read-exact-and-ranges)))
      (set! failed (first-nonzero failed (case-stable-errors)))
      (if (= failed 0)
        42
        failed))))
;; stdlib.local_ipc_linux under `typelisp test` on both hosts. The pure
;; mapping and ABI tables run everywhere. On Linux the socket cases are
;; hermetic: the listener is this process, bound in a private /tmp directory,
;; and native corruption is scripted through the adapter's test hooks. On
;; Windows the adapter is cfg-excluded and reports UnsupportedTarget.
(import stdlib.byte_buf)
(import stdlib.local_ipc)
(import stdlib.local_ipc_linux as linux)
(cfg (all test (not windows)) (import stdlib.profile))
(cfg (all test (not windows)) (import stdlib.str_cat))
(import stdlib.string)
(import stdlib.test)
(import stdlib.time)

;; Error kind codes (`local_ipc.error-kind-code`).
(define kind-invalid-endpoint : i64
  1)
(define kind-unavailable : i64
  2)
(define kind-permission-denied : i64
  3)
(define kind-timed-out : i64
  5)
(define kind-canceled : i64
  6)
(define kind-peer-closed : i64
  7)
(define kind-resource-exhausted : i64
  8)
(define kind-unsupported-target : i64
  9)
(define kind-adapter-corrupt : i64
  10)
(define kind-closed : i64
  11)
(define kind-invalid-range : i64
  12)
(define kind-work-exhausted : i64
  13)
(define kind-policy-rejected : i64
  14)

(define (now) : i64
  (time.ms-or (time.monotonic-ms) 0))

(define (error-code [kind : i64] [host-code : i64]) : i64
  (+ (* kind 100000) host-code))

(define (failure-code [failure : local_ipc.LocalIpcError]) : i64
  (error-code (local_ipc.error-kind-code failure.kind) failure.host-code))

;; 0 for success, otherwise kind * 100000 + host code.
(define (status-code [status : local_ipc.LocalIpcStatus]) : i64
  (match status
    [(Ok) 0]
    [(Err failure) (failure-code failure)]))

;; Progress n is n; WouldBlock -1, Interrupted -2, PeerClosed -3, Pending -4;
;; a failure is minus its `error-code`.
(define (io-step-code [step : local_ipc.LocalIpcIoStep]) : i64
  (match step
    [(Progress count) count]
    [(WouldBlock) -1]
    [(Interrupted) -2]
    [(PeerClosed) -3]
    [(Pending) -4]
    [(IoFailed failure) (- 0 (failure-code failure))]))

;; Done n is n; WouldBlock -1, Interrupted -2, Eof -3; a failure is minus its
;; `error-code`.
(define (io-result-code [result : local_ipc.LocalIpcIoResult]) : i64
  (match result
    [(Done count) count]
    [(WouldBlock) -1]
    [(Interrupted) -2]
    [(Eof) -3]
    [(Failed failure) (- 0 (failure-code failure))]))

;; Ready 0, NotReady 1, WaitInterrupted 2; a failure is its `error-code`.
(define (wait-code [step : local_ipc.LocalIpcWaitStep]) : i64
  (match step
    [(Ready) 0]
    [(NotReady) 1]
    [(WaitInterrupted) 2]
    [(WaitFailed failure) (failure-code failure)]))

;; Connected 0, RetryConnect 1; a failure is its `error-code`.
(define (connect-code [step : local_ipc.LocalIpcConnectStep]) : i64
  (match step
    [(Connected _) 0]
    [(RetryConnect) 1]
    [(ConnectFailed failure) (failure-code failure)]))

;; A peer's pid, uid and gid packed as pid*2^40 + uid*2^20 + gid for small ids;
;; a failure is minus its `error-code`.
(define (peer-code [step : local_ipc.LocalIpcPeerStep]) : i64
  (match step
    [(PeerKnown peer)
      (if (= peer.session-id -1)
        (+
          (* peer.process-id 1099511627776)
          (+ (* peer.user-id 1048576) peer.group-id))
        -1)]
    [(PeerFailed failure) (- 0 (failure-code failure))]))

(define (connection-code
  [connection : (& connection local_ipc.LocalIpcConnection)]) : i64
  (status-code (local_ipc.connection-result connection)))

(define owner-only : i64
  63)

(define (any-path) : linux.LocalIpcLinuxPathPolicy
  (linux.LocalIpcLinuxPathPolicy -1 -1 0))

(define (check-transfer
  [result : i64]
  [requested : i64]
  [writing : bool]
  [step : i64]
  [poison : i64]
  [message : String]) : unit
  (let
    [outcome : linux.LinuxIoOutcome
      (linux.transfer-outcome result requested writing)]
    (test.assert-i64-eq
      (io-step-code outcome.step)
      step
      (string.copy (& message)))
    (test.assert-i64-eq outcome.poison poison message)))

(define (check-wait
  [result : i64]
  [seen-fd : i64]
  [seen-events : i64]
  [revents : i64]
  [step : i64]
  [poison : i64]
  [message : String]) : unit
  (let
    [outcome : linux.LinuxWaitOutcome
      (linux.wait-outcome result 5 linux.pollin seen-fd seen-events revents)]
    (test.assert-i64-eq (wait-code outcome.step) step (string.copy (& message)))
    (test.assert-i64-eq outcome.poison poison message)))

(define (check-path
  [policy : linux.LocalIpcLinuxPathPolicy]
  [mode : i64]
  [owner : i64]
  [group : i64]
  [expected : i64]
  [message : String]) : unit
  (test.assert-i64-eq
    (status-code (linux.path-facts-check policy mode owner group))
    expected
    message))

;; Bytes `start..start+count` of native storage read back as 1, 2, 3, ...
(unsafe
  (define (counted-bytes? [base : (MutPtr u8)] [count : i64]) : bool
    (let
      [index : i64 0]
      [ok : bool true]
      (while (< index count)
        (set!
          ok
          (and
            ok
            (=
              (cast
                (unsafe
                  (ptr-read (ptr-offset base index)))
                : i64)
              (+ index 1))))
        (set! index (+ index 1)))
      ok)))

;; The x86-64 ABI facts the adapter depends on. Field offsets are read back
;; through the bytes of little-endian values; the real SO_PEERCRED and poll
;; cases check the decode end to end (#8081 keeps imported types out of
;; `size-of` here).
(test
  local-ipc-linux-abi
  (let
    [request : linux.LinuxPollFd
      (linux.LinuxPollFd
        (cast 67305985 : i32)
        (cast 1541 : i16)
        (cast 2055 : i16))]
    [credentials : linux.LinuxUcred
      (linux.LinuxUcred
        (cast 67305985 : i32)
        (cast 134678021 : u32)
        (cast 202050057 : u32))]
    [length : linux.LinuxSockLen (linux.LinuxSockLen (cast 67305985 : u32))]
    (test.assert-true
      (unsafe
        (counted-bytes? (ptr-cast (ptr-addr-of request) : (MutPtr u8)) 8))
      "pollfd fd/events/revents at 0/4/6")
    (test.assert-true
      (unsafe
        (counted-bytes? (ptr-cast (ptr-addr-of credentials) : (MutPtr u8)) 12))
      "ucred pid/uid/gid at 0/4/8")
    (test.assert-true
      (unsafe
        (counted-bytes? (ptr-cast (ptr-addr-of length) : (MutPtr u8)) 4))
      "socklen_t")
    (test.assert-i64-eq linux.syscall-read 0 "read")
    (test.assert-i64-eq linux.syscall-close 3 "close")
    (test.assert-i64-eq linux.syscall-poll 7 "poll")
    (test.assert-i64-eq linux.syscall-socket 41 "socket")
    (test.assert-i64-eq linux.syscall-connect 42 "connect")
    (test.assert-i64-eq linux.syscall-sendto 44 "sendto")
    (test.assert-i64-eq linux.syscall-getsockopt 55 "getsockopt")
    (test.assert-i64-eq linux.syscall-newfstatat 262 "newfstatat")
    (test.assert-i64-eq linux.socket-type (+ 1 (+ 2048 524288)) "socket type")
    (test.assert-i64-eq linux.af-unix 1 "AF_UNIX")
    (test.assert-i64-eq linux.sockaddr-path-offset 2 "sun_path")
    (test.assert-i64-eq linux.so-peercred 17 "SO_PEERCRED")
    (test.assert-i64-eq linux.sol-socket 1 "SOL_SOCKET")
    (test.assert-i64-eq linux.at-fdcwd -100 "AT_FDCWD")
    (test.assert-i64-eq linux.at-symlink-nofollow 256 "AT_SYMLINK_NOFOLLOW")
    (test.assert-i64-eq linux.stat-mode-offset 24 "st_mode")
    (test.assert-i64-eq linux.stat-uid-offset 28 "st_uid")
    (test.assert-i64-eq linux.stat-gid-offset 32 "st_gid")
    (test.assert-i64-eq linux.msg-nosignal 16384 "MSG_NOSIGNAL")
    (test.assert-i64-eq
      (+
        linux.pollin
        (+ linux.pollout (+ linux.pollerr (+ linux.pollhup linux.pollnval))))
      61
      "poll bits")))

;; Every raw result classification, as tables.
(test
  local-ipc-linux-mappings
  (let
    [owned : linux.LocalIpcLinuxPathPolicy
      (linux.LocalIpcLinuxPathPolicy 1000 50 63)]
    (check-transfer 3 8 false 3 0 "read progress")
    (check-transfer 8 8 false 8 0 "read full")
    (check-transfer 0 8 false -3 0 "read EOF")
    (check-transfer -11 8 false -1 0 "read would block")
    (check-transfer -4 8 false -2 0 "read interrupted")
    (check-transfer
      9
      8
      false
      (- 0 (error-code kind-adapter-corrupt 0))
      1
      "read over")
    (check-transfer
      -5000
      8
      false
      (- 0 (error-code kind-adapter-corrupt 0))
      1
      "read impossible")
    (check-transfer
      -104
      8
      false
      (- 0 (error-code kind-peer-closed 104))
      0
      "read reset")
    (check-transfer
      -9
      8
      false
      (- 0 (error-code kind-adapter-corrupt 9))
      2
      "read EBADF")
    (check-transfer -5 8 false (- 0 (error-code 15 5)) 0 "read EIO")
    (check-transfer 5 8 true 5 0 "write progress")
    (check-transfer
      0
      8
      true
      (- 0 (error-code kind-adapter-corrupt 0))
      1
      "write zero")
    (check-transfer
      9
      8
      true
      (- 0 (error-code kind-adapter-corrupt 0))
      1
      "write over")
    (check-transfer
      -32
      8
      true
      (- 0 (error-code kind-peer-closed 32))
      0
      "write EPIPE")
    (check-transfer
      -107
      8
      true
      (- 0 (error-code kind-peer-closed 107))
      0
      "write ENOTCONN")
    (check-transfer
      -105
      8
      true
      (- 0 (error-code kind-resource-exhausted 105))
      0
      "write ENOBUFS")
    (check-wait 0 5 1 0 1 0 "wait not ready")
    (check-wait
      0
      5
      1
      1
      (error-code kind-adapter-corrupt 0)
      1
      "wait count/revents")
    (check-wait 1 5 1 1 0 0 "wait readable")
    (check-wait 1 5 1 16 0 0 "wait hang-up")
    (check-wait 1 5 1 8 0 0 "wait error")
    (check-wait
      1
      5
      1
      0
      (error-code kind-adapter-corrupt 0)
      1
      "wait empty revents")
    (check-wait
      1
      5
      1
      4
      (error-code kind-adapter-corrupt 0)
      1
      "wait unrequested bit")
    (check-wait
      1
      5
      1
      64
      (error-code kind-adapter-corrupt 0)
      1
      "wait unknown bit")
    (check-wait 1 5 1 32 (error-code kind-adapter-corrupt 0) 2 "wait POLLNVAL")
    (check-wait 1 6 1 1 (error-code kind-adapter-corrupt 0) 1 "wait fd changed")
    (check-wait
      1
      5
      4
      1
      (error-code kind-adapter-corrupt 0)
      1
      "wait events changed")
    (check-wait 2 5 1 1 (error-code kind-adapter-corrupt 0) 1 "wait count 2")
    (check-wait -4 5 1 0 2 0 "wait interrupted")
    (check-wait
      -12
      5
      1
      0
      (error-code kind-resource-exhausted 12)
      0
      "wait ENOMEM")
    (check-path owned 49536 1000 50 0 "socket 0600 owned")
    (check-path
      owned
      41471
      1000
      50
      (error-code kind-policy-rejected 40)
      "symlink")
    (check-path
      owned
      33152
      1000
      50
      (error-code kind-policy-rejected 88)
      "regular file")
    (check-path
      owned
      16832
      1000
      50
      (error-code kind-policy-rejected 88)
      "directory")
    (check-path owned 49536 1001 50 (error-code kind-policy-rejected 1) "owner")
    (check-path owned 49536 1000 51 (error-code kind-policy-rejected 1) "group")
    (check-path
      owned
      49584
      1000
      50
      (error-code kind-policy-rejected 13)
      "group write")
    (check-path
      owned
      49153
      1000
      50
      (error-code kind-policy-rejected 13)
      "other exec")
    (check-path (any-path) 53247 7 8 0 "any socket")
    (test.assert-true
      (linux.path-policy-valid?
        (linux.LocalIpcLinuxPathPolicy -1 4294967294 4095))
      "policy max")
    (test.assert-false
      (linux.path-policy-valid? (linux.LocalIpcLinuxPathPolicy -2 0 0))
      "policy owner")
    (test.assert-false
      (linux.path-policy-valid? (linux.LocalIpcLinuxPathPolicy 0 4294967295 0))
      "policy group")
    (test.assert-false
      (linux.path-policy-valid? (linux.LocalIpcLinuxPathPolicy 0 0 4096))
      "policy mode")
    (test.assert-false
      (linux.path-policy-valid? (linux.LocalIpcLinuxPathPolicy 0 0 -1))
      "policy negative mode")
    (test.assert-i64-eq
      (peer-code (linux.peer-step 0 12 7 8 9))
      (+ (* 7 1099511627776) (+ (* 8 1048576) 9))
      "peer facts")
    (test.assert-i64-eq
      (peer-code (linux.peer-step 0 12 0 8 9))
      (+ (* 8 1048576) 9)
      "peer pid 0")
    (test.assert-i64-eq
      (peer-code (linux.peer-step 0 8 7 8 9))
      (- 0 (error-code kind-adapter-corrupt 0))
      "peer short")
    (test.assert-i64-eq
      (peer-code (linux.peer-step 0 12 -1 8 9))
      (- 0 (error-code kind-adapter-corrupt 0))
      "peer pid")
    (test.assert-i64-eq
      (peer-code (linux.peer-step 3 12 7 8 9))
      (- 0 (error-code kind-adapter-corrupt 0))
      "peer count")
    (test.assert-i64-eq
      (peer-code (linux.peer-step -9 12 7 8 9))
      (- 0 (error-code kind-adapter-corrupt 9))
      "peer EBADF")
    (test.assert-i64-eq
      (failure-code (linux.construction-error 2))
      (error-code kind-unavailable 2)
      "ENOENT")
    (test.assert-i64-eq
      (failure-code (linux.construction-error 111))
      (error-code kind-unavailable 111)
      "ECONNREFUSED")
    (test.assert-i64-eq
      (failure-code (linux.construction-error 91))
      (error-code kind-unavailable 91)
      "EPROTOTYPE")
    (test.assert-i64-eq
      (failure-code (linux.construction-error 13))
      (error-code kind-permission-denied 13)
      "EACCES")
    (test.assert-i64-eq
      (failure-code (linux.construction-error 24))
      (error-code kind-resource-exhausted 24)
      "EMFILE")
    (test.assert-i64-eq
      (failure-code (linux.construction-error 40))
      (error-code kind-invalid-endpoint 40)
      "ELOOP")
    (test.assert-i64-eq
      (failure-code (linux.construction-error 38))
      (error-code kind-unsupported-target 38)
      "ENOSYS")
    (test.assert-i64-eq
      (failure-code (linux.construction-error 115))
      (error-code kind-adapter-corrupt 115)
      "EINPROGRESS")
    (test.assert-i64-eq
      (failure-code (linux.construction-error 114))
      (error-code kind-adapter-corrupt 114)
      "EALREADY")
    (test.assert-i64-eq
      (failure-code (linux.construction-error 106))
      (error-code kind-adapter-corrupt 106)
      "EISCONN")
    (test.assert-i64-eq (linux.bounded-slice -3) 1 "slice low")
    (test.assert-i64-eq (linux.bounded-slice 0) 1 "slice zero")
    (test.assert-i64-eq (linux.bounded-slice 57) 57 "slice mid")
    (test.assert-i64-eq (linux.bounded-slice 101) 100 "slice high")))

;; Calls on tokens no publish returned fail without a host call.
(test
  local-ipc-linux-forged-tokens
  (let
    [_reset : unit (linux.test-reset!)]
    [adapter : local_ipc.LocalIpcAdapter (linux.adapter (any-path))]
    [buffer : byte_buf.ByteBuf (byte_buf.from-array (__tl_make-array u8 4))]
    [closed : i64 (error-code kind-closed 0)]
    (test.assert-i64-eq (status-code (adapter.close 0 -1)) closed "close -1")
    (test.assert-i64-eq (status-code (adapter.close 0 0)) closed "close 0")
    (test.assert-i64-eq
      (status-code (adapter.close 0 255))
      closed
      "close generation 0")
    (test.assert-i64-eq
      (status-code (adapter.close 0 9223372036854775807))
      closed
      "close max")
    (test.assert-i64-eq
      (wait-code (adapter.wait-ready 0 256 0 10))
      closed
      "wait")
    (test.assert-i64-eq
      (wait-code (adapter.wait-ready 0 256 2 10))
      (error-code kind-invalid-range 0)
      "wait interest")
    (test.assert-i64-eq (peer-code (adapter.peer 0 257)) (- 0 closed) "peer")
    (let
      [reply : local_ipc.LocalIpcIoReply (adapter.read-once 0 258 buffer)]
      [read-code : i64 (io-step-code reply.step)]
      [reply-again : local_ipc.LocalIpcIoReply
        (adapter.write-once 0 259 reply.buffer)]
      [write-code : i64 (io-step-code reply-again.step)]
      [pending : local_ipc.LocalIpcIoReply
        (adapter.poll-pending 0 259 reply-again.buffer 10)]
      (test.assert-i64-eq read-code (- 0 closed) "read")
      (test.assert-i64-eq write-code (- 0 closed) "write")
      (test.assert-i64-eq
        (io-step-code pending.step)
        (- 0 (error-code kind-adapter-corrupt 0))
        "never pending")
      (test.assert-i64-eq (byte_buf.len (& pending.buffer)) 4 "buffer back"))
    (test.assert-i64-eq
      (linux.test-call-count linux.syscall-close)
      0
      "no close")
    (test.assert-i64-eq (linux.test-call-count linux.syscall-read) 0 "no read")
    (test.assert-i64-eq (linux.test-call-count linux.syscall-poll) 0 "no poll")))

;; A forged ByteBuf whose live length exceeds its storage never reaches a host
;; call, and neither does a zero-length one.
(test
  local-ipc-linux-unsound-buffers
  (let
    [adapter : local_ipc.LocalIpcAdapter (linux.adapter (any-path))]
    [forged : byte_buf.ByteBuf (byte_buf.ByteBuf (__tl_make-array u8 2) 64)]
    [empty : byte_buf.ByteBuf (byte_buf.from-array (__tl_make-array u8 0))]
    [name : byte_buf.ByteBuf (byte_buf.ByteBuf (__tl_make-array u8 2) 90)]
    [long-name : byte_buf.ByteBuf
      (byte_buf.from-array (__tl_make-array u8 300))]
    [range : i64 (- 0 (error-code kind-invalid-range 0))]
    [first : local_ipc.LocalIpcIoReply (adapter.read-once 0 256 forged)]
    [second : local_ipc.LocalIpcIoReply (adapter.write-once 0 256 empty)]
    [third : local_ipc.LocalIpcConnectReply
      (adapter.connect-attempt 0 local_ipc.family-unix-path name)]
    [third-code : i64 (connect-code third.step)]
    [fourth : local_ipc.LocalIpcConnectReply
      (adapter.connect-attempt 0 local_ipc.family-windows-pipe third.name)]
    (test.assert-i64-eq (io-step-code first.step) range "forged length")
    (test.assert-i64-eq (io-step-code second.step) range "empty")
    (test.assert-i64-eq
      third-code
      (error-code kind-invalid-endpoint 0)
      "forged name")
    (test.assert-i64-eq
      (connect-code fourth.step)
      (error-code kind-unsupported-target 0)
      "pipe family")
    (test.assert-i64-eq fourth.name.len 90 "name back")
    (test.assert-i64-eq
      (connect-code
        (linux.attempt (any-path) (byte_buf.as-bytes (& long-name))))
      (error-code kind-invalid-endpoint 0)
      "overlong name never reaches native storage")))

;; Windows: the adapter is cfg-excluded, so every connect is UnsupportedTarget.
(cfg
  windows
  (test
    local-ipc-linux-windows-unsupported
    (let
      [endpoint : local_ipc.LocalIpcEndpoint (UnixPath "/tmp/agent.sock")]
      (with
        ([connection
            (local_ipc.connect
              (linux.adapter (any-path))
              (& endpoint)
              local_ipc.accept-any-peer
              (+ (now) 1000)
              local_ipc.never-canceled
              4)
            local_ipc.cleanup-local-ipc-connection])
        (test.assert-i64-eq
          (connection-code (& connection))
          (error-code kind-unsupported-target 38)
          "unsupported target")))))

;; Linux host helpers: raw syscalls for the in-process listener and the
;; filesystem fixtures, outside the adapter's hooks and counters.
(cfg
  (all test (not windows))
  (unsafe
    (define (sys [number : i64] [a : i64] [b : i64] [c : i64] [d : i64]) : i64
      (unsafe
        (syscall number a b c d 0 0)))))

(cfg
  (all test (not windows))
  (unsafe
    (define (sys5
      [number : i64]
      [a : i64]
      [b : i64]
      [c : i64]
      [d : i64]
      [e : i64]) : i64
      (unsafe
        (syscall number a b c d e 0)))))

(cfg
  (all test (not windows))
  (define (c-string [text : (& text str)]) : (__tl_dyn-array u8)
    (let
      [length : i64 (string.string-length text)]
      [out : (__tl_dyn-array u8) (__tl_make-array u8 (+ length 1))]
      [index : i64 0]
      (while (< index length)
        (set! (array-ref out index) (cast (string.string-ref text index) : u8))
        (set! index (+ index 1)))
      out)))

(cfg
  (all test (not windows))
  (define (array-arg [bytes : (__tl_dyn-array u8)]) : i64
    (unsafe
      (cast (ptr->int (__tl_array-data bytes)) : i64))))

(cfg
  (all test (not windows))
  (define (path-call [number : i64] [path : (& path str)] [b : i64] [c : i64]) : i64
    (let
      [text : (__tl_dyn-array u8) (c-string path)]
      (unsafe
        (sys number (array-arg text) b c 0)))))

(cfg
  (all test (not windows))
  (define (process-id) : i64
    (unsafe
      (sys 39 0 0 0 0))))

(cfg
  (all test (not windows))
  (define (user-id) : i64
    (unsafe
      (sys 102 0 0 0 0))))

(cfg
  (all test (not windows))
  (define (group-id) : i64
    (unsafe
      (sys 104 0 0 0 0))))

;; A fresh private directory for one test.
(cfg
  (all test (not windows))
  (define (scratch [tag : (& tag str)]) : String
    (let
      [dir : String
        (str_cat.str-cat
          "/tmp/tl-local-ipc-"
          (string.int->string (process-id))
          "-"
          (string.copy tag))]
      (test.assert-i64-eq (path-call 83 (& dir) 448 0) 0 "mkdir")
      dir)))

(cfg
  (all test (not windows))
  (define (in-dir [dir : (& dir str)] [name : (& name str)]) : String
    (str_cat.str-cat (string.copy dir) "/" (string.copy name))))

;; `sockaddr_un` storage for `path`.
(cfg
  (all test (not windows))
  (define (socket-address [path : (& path str)]) : (__tl_dyn-array u8)
    (let
      [storage : (__tl_dyn-array u8) (__tl_make-array u8 112)]
      (unsafe
        (linux.address-fill!
          (__tl_array-data storage)
          (byte_buf.str-as-bytes path)))
      storage)))

;; A listening socket at `path` with mode 0600.
(cfg
  (all test (not windows))
  (define (listen-at [path : (& path str)] [backlog : i64]) : i64
    (let
      [storage : (__tl_dyn-array u8) (socket-address path)]
      [address : i64
        (unsafe
          (cast (ptr->int (__tl_array-data storage)) : i64))]
      [fd : i64
        (unsafe
          (sys 41 1 linux.socket-type 0 0))]
      (test.assert-true (>= fd 0) "listener socket")
      (test.assert-i64-eq
        (unsafe
          (sys 49 fd address (+ (string.string-length path) 3) 0))
        0
        "bind")
      (test.assert-i64-eq
        (unsafe
          (sys 50 fd backlog 0 0))
        0
        "listen")
      (test.assert-i64-eq (path-call 90 path 384 0) 0 "chmod")
      fd)))

;; A raw nonblocking client connect to `path`: the fd, and the connect result
;; through `result`.
(cfg
  (all test (not windows))
  (define (raw-connect [path : (& path str)] [result : (&mut result i64)]) : i64
    (let
      [storage : (__tl_dyn-array u8) (socket-address path)]
      [address : i64
        (unsafe
          (cast (ptr->int (__tl_array-data storage)) : i64))]
      [fd : i64
        (unsafe
          (sys 41 1 linux.socket-type 0 0))]
      (set!
        (deref result)
        (unsafe
          (sys 42 fd address (+ (string.string-length path) 3) 0)))
      fd)))

(cfg
  (all test (not windows))
  (define (accept-one [listener : i64]) : i64
    (unsafe
      (sys 288 listener 0 0 (+ 2048 524288)))))

(cfg
  (all test (not windows))
  (define (close-fd [fd : i64]) : unit
    (test.assert-i64-eq
      (unsafe
        (sys 3 fd 0 0 0))
      0
      "close fixture fd")))

;; Write `count` bytes 1, 2, 3, ... from the server side.
(cfg
  (all test (not windows))
  (define (server-send [fd : i64] [count : i64]) : unit
    (let
      [bytes : (__tl_dyn-array u8) (__tl_make-array u8 count)]
      [index : i64 0]
      (while (< index count)
        (set! (array-ref bytes index) (cast (+ index 1) : u8))
        (set! index (+ index 1)))
      (test.assert-i64-eq
        (unsafe
          (sys 1 fd (array-arg bytes) count 0))
        count
        "server send"))))

;; Read what the server has, into a fresh buffer; returns the byte sum.
(cfg
  (all test (not windows))
  (define (server-receive-sum [fd : i64] [count : i64]) : i64
    (let
      [bytes : (__tl_dyn-array u8) (__tl_make-array u8 count)]
      [got : i64
        (unsafe
          (sys 0 fd (cast (ptr->int (__tl_array-data bytes)) : i64) count 0))]
      [index : i64 0]
      [sum : i64 0]
      (test.assert-i64-eq got count "server receive")
      (while (< index count)
        (set! sum (+ sum (cast (array-ref bytes index) : i64)))
        (set! index (+ index 1)))
      sum)))

(cfg
  (all test (not windows))
  (define (remove [path : (& path str)]) : unit
    (test.assert-i64-eq (path-call 87 path 0 0) 0 "unlink")))

(cfg
  (all test (not windows))
  (define (remove-dir [path : (& path str)]) : unit
    (test.assert-i64-eq (path-call 84 path 0 0) 0 "rmdir")))

;; The policy "owned by this user, no group or other bits".
(cfg
  (all test (not windows))
  (define (mine) : linux.LocalIpcLinuxPathPolicy
    (linux.LocalIpcLinuxPathPolicy (user-id) -1 owner-only)))

(cfg
  (all test (not windows))
  (define (peer-is-me [peer : local_ipc.LocalIpcPeer]) : bool
    (and
      (= peer.process-id (process-id))
      (= peer.user-id (user-id))
      (= peer.group-id (group-id))
      (= peer.session-id -1))))

(cfg
  (all test (not windows))
  (define (open-with
    [path : (& path str)]
    [policy : linux.LocalIpcLinuxPathPolicy]
    [peer-policy : (-> local_ipc.LocalIpcPeer bool)]
    [deadline-ms : i64]
    [cancel-check : (-> bool)]) : local_ipc.LocalIpcConnection
    (let
      [endpoint : local_ipc.LocalIpcEndpoint (UnixPath (string.copy path))]
      (local_ipc.connect
        (linux.adapter policy)
        (& endpoint)
        peer-policy
        deadline-ms
        cancel-check
        64))))

(cfg
  (all test (not windows))
  (define (open [path : (& path str)]) : local_ipc.LocalIpcConnection
    (open-with path (mine) peer-is-me (+ (now) 5000) local_ipc.never-canceled)))

;; The construction result code of one connect to `path`; the connection is
;; closed by its scope.
(cfg
  (all test (not windows))
  (define (connect-code-at
    [path : (& path str)]
    [policy : linux.LocalIpcLinuxPathPolicy]
    [peer-policy : (-> local_ipc.LocalIpcPeer bool)]) : i64
    (with
      ([connection
          (open-with
            path
            policy
            peer-policy
            (+ (now) 5000)
            local_ipc.never-canceled)
          local_ipc.cleanup-local-ipc-connection])
      (connection-code (& connection)))))

;; One direct adapter connect attempt: the token, or -1.
(cfg
  (all test (not windows))
  (define (direct-connect
    [adapter : (& adapter local_ipc.LocalIpcAdapter)]
    [path : (& path str)]) : i64
    (let
      [name : (__tl_dyn-array u8) (c-string path)]
      [reply : local_ipc.LocalIpcConnectReply
        (adapter.connect-attempt
          0
          local_ipc.family-unix-path
          (byte_buf.ByteBuf name (string.string-length path)))]
      (match reply.step
        [(Connected token) token]
        [_ -1]))))

;; Adapter socket calls not yet matched by an adapter close.
(cfg
  (all test (not windows))
  (define (open-descriptors) : i64
    (-
      (linux.test-call-count linux.syscall-socket)
      (linux.test-call-count linux.syscall-close))))

;; Descriptor-table slots not free.
(cfg
  (all test (not windows))
  (define (busy-slots) : i64
    (let
      [slot : i64 0]
      [busy : i64 0]
      (while (< slot linux.slot-capacity)
        (if (=
          (%
            (unsafe
              (atomic-load (linux.slot-word slot 0)))
            8)
          linux.state-free)
          unit
          (set! busy (+ busy 1)))
        (set! slot (+ slot 1)))
      busy)))

(cfg
  (all test (not windows))
  (define (zero-buffer [count : i64]) : byte_buf.ByteBuf
    (byte_buf.from-array (__tl_make-array u8 count))))

;; Connect, peer facts, partial progress both ways, would-block, tail bytes
;; before EOF, EPIPE without SIGPIPE, and exact close.
(cfg
  (all test (not windows))
  (test
    local-ipc-linux-connect-and-transfer
    (let
      [_reset : unit (linux.test-reset!)]
      [dir : String (scratch "transfer")]
      [path : String (in-dir (& dir) "agent.sock")]
      [listener : i64 (listen-at (& path) 4)]
      [server : i64 -1]
      [buffer : byte_buf.ByteBuf (zero-buffer 8)]
      [payload : byte_buf.ByteBuf (byte_buf.from-array (__tl_make-array u8 5))]
      (with
        ([connection (open (& path)) local_ipc.cleanup-local-ipc-connection])
        (test.assert-i64-eq (connection-code (& connection)) 0 "connected")
        (test.assert-true
          (peer-is-me (local_ipc.connection-peer (& connection)))
          "peer facts")
        (set! server (accept-one listener))
        (test.assert-true (>= server 0) "accepted")
        (set! payload (byte_buf.set! payload 0 (cast 7 : u8)))
        (set! payload (byte_buf.set! payload 4 (cast 9 : u8)))
        (let
          [sent : local_ipc.LocalIpcTransfer
            (local_ipc.write-all!
              (&mut connection)
              (byte_buf.as-bytes (& payload))
              0
              5
              (+ (now) 1000)
              local_ipc.never-canceled
              8)]
          (test.assert-i64-eq sent.count 5 "write-all count")
          (test.assert-i64-eq (status-code sent.status) 0 "write-all status"))
        (test.assert-i64-eq (server-receive-sum server 5) 16 "server got bytes")
        (test.assert-i64-eq
          (io-result-code
            (local_ipc.read-some!
              (&mut connection)
              (byte_buf.as-mut-bytes (&mut buffer))
              0
              8))
          -1
          "would block")
        (server-send server 3)
        (test.assert-i64-eq
          (io-result-code
            (local_ipc.read-some!
              (&mut connection)
              (byte_buf.as-mut-bytes (&mut buffer))
              2
              6))
          3
          "partial read")
        (test.assert-i64-eq
          (cast (byte_buf.ref (& buffer) 4) : i64)
          3
          "read bytes landed")
        (server-send server 4)
        (close-fd server)
        (let
          [tail : local_ipc.LocalIpcTransfer
            (local_ipc.read-exact!
              (&mut connection)
              (byte_buf.as-mut-bytes (&mut buffer))
              0
              8
              (+ (now) 1000)
              local_ipc.never-canceled
              8)]
          (test.assert-i64-eq tail.count 4 "tail before EOF")
          (test.assert-i64-eq
            (status-code tail.status)
            (error-code kind-peer-closed 0)
            "EOF after tail"))
        (test.assert-i64-eq
          (io-result-code
            (local_ipc.read-some!
              (&mut connection)
              (byte_buf.as-mut-bytes (&mut buffer))
              0
              8))
          -3
          "EOF")
        (test.assert-i64-eq
          (io-result-code
            (local_ipc.write-some!
              (&mut connection)
              (byte_buf.as-bytes (& payload))
              0
              5))
          (- 0 (error-code kind-peer-closed 32))
          "EPIPE, no SIGPIPE")
        (test.assert-i64-eq
          (status-code (local_ipc.close! (&mut connection)))
          0
          "close")
        (test.assert-i64-eq
          (status-code (local_ipc.close! (&mut connection)))
          (error-code kind-closed 0)
          "close twice"))
      (test.assert-i64-eq
        (linux.test-call-count linux.syscall-socket)
        1
        "one socket")
      (test.assert-i64-eq
        (linux.test-call-count linux.syscall-connect)
        1
        "one connect")
      (test.assert-i64-eq
        (linux.test-call-count linux.syscall-getsockopt)
        1
        "one peer query")
      (test.assert-i64-eq (open-descriptors) 0 "closed once")
      (test.assert-i64-eq (busy-slots) 0 "slots free")
      (close-fd listener)
      (remove (& path))
      (remove-dir (& dir)))))

;; Missing, refused, non-socket, symlink, mode, owner, group and invalid
;; policies, and a non-canonical name handed straight to the adapter.
(cfg
  (all test (not windows))
  (test
    local-ipc-linux-path-policy
    (let
      [_reset : unit (linux.test-reset!)]
      [dir : String (scratch "policy")]
      [path : String (in-dir (& dir) "agent.sock")]
      [missing : String (in-dir (& dir) "missing.sock")]
      [plain : String (in-dir (& dir) "plain")]
      [link : String (in-dir (& dir) "link.sock")]
      [stale : String (in-dir (& dir) "stale.sock")]
      [listener : i64 (listen-at (& path) 4)]
      [stale-listener : i64 (listen-at (& stale) 4)]
      [me : i64 (user-id)]
      (close-fd stale-listener)
      (let
        [created : i64 (path-call 2 (& plain) (+ 1 (+ 64 524288)) 384)]
        (test.assert-true (>= created 0) "create plain file")
        (close-fd created))
      (let
        [target : (__tl_dyn-array u8) (c-string (& path))]
        [linked : (__tl_dyn-array u8) (c-string (& link))]
        (test.assert-i64-eq
          (unsafe
            (sys 88 (array-arg target) (array-arg linked) 0 0))
          0
          "symlink"))
      (test.assert-i64-eq
        (connect-code-at (& missing) (mine) local_ipc.accept-any-peer)
        (error-code kind-unavailable 2)
        "missing")
      (test.assert-i64-eq
        (connect-code-at (& plain) (mine) local_ipc.accept-any-peer)
        (error-code kind-policy-rejected 88)
        "regular file")
      (test.assert-i64-eq
        (connect-code-at (& dir) (mine) local_ipc.accept-any-peer)
        (error-code kind-policy-rejected 88)
        "directory")
      (test.assert-i64-eq
        (connect-code-at (& link) (mine) local_ipc.accept-any-peer)
        (error-code kind-policy-rejected 40)
        "symlink")
      (test.assert-i64-eq
        (linux.test-call-count linux.syscall-socket)
        0
        "no socket yet")
      (test.assert-i64-eq
        (connect-code-at
          (& path)
          (linux.LocalIpcLinuxPathPolicy (+ me 1) -1 0)
          local_ipc.accept-any-peer)
        (error-code kind-policy-rejected 1)
        "owner")
      (test.assert-i64-eq
        (connect-code-at
          (& path)
          (linux.LocalIpcLinuxPathPolicy -1 (+ (group-id) 1) 0)
          local_ipc.accept-any-peer)
        (error-code kind-policy-rejected 1)
        "group")
      (test.assert-i64-eq (path-call 90 (& path) 432 0) 0 "chmod 0660")
      (test.assert-i64-eq
        (connect-code-at (& path) (mine) local_ipc.accept-any-peer)
        (error-code kind-policy-rejected 13)
        "group bits")
      (test.assert-i64-eq
        (connect-code-at
          (& path)
          (linux.LocalIpcLinuxPathPolicy me -1 7)
          local_ipc.accept-any-peer)
        0
        "other bits clear")
      (test.assert-i64-eq
        (connect-code-at
          (& path)
          (linux.LocalIpcLinuxPathPolicy me -1 5000)
          local_ipc.accept-any-peer)
        (error-code kind-policy-rejected 22)
        "invalid policy")
      (test.assert-i64-eq
        (linux.test-call-count linux.syscall-socket)
        1
        "one socket")
      (test.assert-i64-eq
        (connect-code-at (& stale) (any-path) local_ipc.accept-any-peer)
        (error-code kind-unavailable 111)
        "refused")
      (test.assert-i64-eq
        (linux.test-call-count linux.syscall-socket)
        2
        "refused socket")
      (let
        [adapter : local_ipc.LocalIpcAdapter (linux.adapter (any-path))]
        [dotted : String (in-dir (& dir) "./agent.sock")]
        [name : byte_buf.ByteBuf (byte_buf.from-array (c-string (& dotted)))]
        [trimmed : byte_buf.ByteBuf
          (byte_buf.ByteBuf name.slots (string.string-length (& dotted)))]
        [stats : i64 (linux.test-call-count linux.syscall-newfstatat)]
        [reply : local_ipc.LocalIpcConnectReply
          (adapter.connect-attempt 0 local_ipc.family-unix-path trimmed)]
        (test.assert-i64-eq
          (connect-code reply.step)
          (error-code kind-invalid-endpoint 0)
          "adapter re-checks names")
        (test.assert-i64-eq
          (linux.test-call-count linux.syscall-newfstatat)
          stats
          "no stat for a bad name"))
      (test.assert-i64-eq (open-descriptors) 0 "closed once")
      (test.assert-i64-eq (busy-slots) 0 "slots free")
      (close-fd listener)
      (remove (& link))
      (remove (& plain))
      (remove (& stale))
      (remove (& path))
      (remove-dir (& dir)))))

(define rejecting-peer-accepts : i64
  0)

(define (reject-every-peer [_peer : local_ipc.LocalIpcPeer]) : bool
  (set! rejecting-peer-accepts (+ rejecting-peer-accepts 1))
  false)

;; Peer policy: the real facts are this process; a rejecting policy closes the
;; connection once (the server then reads EOF); scripted credentials cover a
;; mismatched user and malformed native output.
(cfg
  (all test (not windows))
  (test
    local-ipc-linux-peer-policy
    (let
      [_reset : unit (linux.test-reset!)]
      [dir : String (scratch "peer")]
      [path : String (in-dir (& dir) "agent.sock")]
      [listener : i64 (listen-at (& path) 8)]
      (test.assert-i64-eq
        (connect-code-at (& path) (mine) reject-every-peer)
        (error-code kind-policy-rejected 0)
        "rejected peer")
      (test.assert-i64-eq rejecting-peer-accepts 1 "policy asked once")
      (test.assert-i64-eq (open-descriptors) 0 "rejected connection closed")
      (let
        [server : i64 (accept-one listener)]
        [scratch-byte : (__tl_dyn-array u8) (__tl_make-array u8 1)]
        (test.assert-i64-eq
          (unsafe
            (sys 0 server (array-arg scratch-byte) 1 0))
          0
          "server sees EOF")
        (close-fd server))
      (linux.test-script! linux.syscall-getsockopt 2 0 12 7 4242 4243)
      (test.assert-i64-eq
        (connect-code-at (& path) (mine) peer-is-me)
        (error-code kind-policy-rejected 0)
        "scripted other user")
      (linux.test-script! linux.syscall-getsockopt 3 0 8 -1 -1 -1)
      (test.assert-i64-eq
        (connect-code-at (& path) (mine) local_ipc.accept-any-peer)
        (error-code kind-adapter-corrupt 0)
        "short ucred")
      (linux.test-script! linux.syscall-getsockopt 4 0 12 4294967295 1 1)
      (test.assert-i64-eq
        (connect-code-at (& path) (mine) local_ipc.accept-any-peer)
        (error-code kind-adapter-corrupt 0)
        "negative pid")
      (linux.test-inject! linux.syscall-getsockopt 5 -92)
      (test.assert-i64-eq
        (connect-code-at (& path) (mine) local_ipc.accept-any-peer)
        (error-code 15 92)
        "getsockopt error")
      (test.assert-i64-eq
        (connect-code-at (& path) (mine) peer-is-me)
        0
        "real facts")
      (test.assert-i64-eq
        (linux.test-call-count linux.syscall-socket)
        6
        "six sockets")
      (test.assert-i64-eq (open-descriptors) 0 "each closed once")
      (test.assert-i64-eq (busy-slots) 0 "slots free")
      (close-fd listener)
      (remove (& path))
      (remove-dir (& dir)))))

(define backlog-listener : i64
  -1)
(define backlog-probes : i64
  0)
(define backlog-accepted : i64
  -1)

;; The contract probes cancellation before every attempt and before every
;; pause; the second probe is the pause after the refused first attempt, and
;; accepting there frees the backlog for the second attempt.
(cfg
  (all test (not windows))
  (define (accept-on-second-probe) : bool
    (set! backlog-probes (+ backlog-probes 1))
    (if (= backlog-probes 2)
      (set! backlog-accepted (accept-one backlog-listener))
      unit)
    false))

;; A full backlog: EAGAIN, the unconnected socket polls POLLOUT|POLLHUP with
;; SO_ERROR 0 and ENOTCONN from getpeername, and the adapter closes that
;; attempt, pauses a bounded slice and connects on a fresh descriptor; left
;; full, connect times out after a bounded number of attempts.
(cfg
  (all test (not windows))
  (test
    local-ipc-linux-saturated-backlog
    (let
      [_reset : unit (linux.test-reset!)]
      [dir : String (scratch "backlog")]
      [path : String (in-dir (& dir) "agent.sock")]
      [listener : i64 (listen-at (& path) 0)]
      [first-result : i64 99]
      [first : i64 (raw-connect (& path) (&mut first-result))]
      [probe-result : i64 99]
      [probe : i64 (raw-connect (& path) (&mut probe-result))]
      (test.assert-i64-eq first-result 0 "first client queued")
      (test.assert-i64-eq probe-result -11 "backlog full: EAGAIN")
      (let
        [request : linux.LinuxPollFd
          (linux.LinuxPollFd
            (cast probe : i32)
            (cast linux.pollout : i16)
            (cast 0 : i16))]
        [ready : i64
          (unsafe
            (sys
              7
              (cast
                (ptr->int (ptr-cast (ptr-addr-of request) : (Ptr u8)))
                : i64)
              1
              0
              0))]
        [seen : linux.LinuxPollFd
          (unsafe
            (ptr-read
              (ptr-cast (ptr-addr-of request) : (Ptr linux.LinuxPollFd))))]
        [error : linux.LinuxSockLen (linux.LinuxSockLen (cast 7 : u32))]
        [length : linux.LinuxSockLen (linux.LinuxSockLen (cast 4 : u32))]
        [so-error : i64
          (unsafe
            (sys5
              55
              probe
              1
              4
              (cast (ptr->int (ptr-cast (ptr-addr-of error) : (Ptr u8))) : i64)
              (cast (ptr->int (ptr-cast (ptr-addr-of length) : (Ptr u8))) : i64)))]
        [error-value : linux.LinuxSockLen
          (unsafe
            (ptr-read (ptr-cast (ptr-addr-of error) : (Ptr linux.LinuxSockLen))))]
        [peer-storage : (Array u64 14) (init)]
        [peer-length : linux.LinuxSockLen (linux.LinuxSockLen (cast 112 : u32))]
        [peer-name : i64
          (unsafe
            (sys
              52
              probe
              (cast
                (ptr->int (ptr-cast (ptr-addr-of peer-storage) : (Ptr u8)))
                : i64)
              (cast
                (ptr->int (ptr-cast (ptr-addr-of peer-length) : (Ptr u8)))
                : i64)
              0))]
        (test.assert-i64-eq ready 1 "false readiness")
        (test.assert-i64-eq (cast seen.revents : i64) 20 "POLLOUT|POLLHUP")
        (test.assert-i64-eq peer-name -107 "not connected")
        (test.assert-i64-eq so-error 0 "SO_ERROR readable")
        (test.assert-i64-eq (cast error-value.value : i64) 0 "SO_ERROR zero"))
      (close-fd probe)
      (set! backlog-listener listener)
      (set! backlog-probes 0)
      (with
        ([connection
            (open-with
              (& path)
              (mine)
              peer-is-me
              (+ (now) 5000)
              accept-on-second-probe)
            local_ipc.cleanup-local-ipc-connection])
        (test.assert-i64-eq
          (connection-code (& connection))
          0
          "fresh attempt connects")
        (test.assert-true
          (>= backlog-accepted 0)
          "server accepted during the pause")
        (test.assert-i64-eq
          (linux.test-call-count linux.syscall-socket)
          2
          "two attempts")
        (test.assert-i64-eq
          (linux.test-call-count linux.syscall-connect)
          2
          "two connects")
        (test.assert-i64-eq
          (linux.test-call-count linux.syscall-close)
          1
          "discarded attempt closed")
        (test.assert-i64-eq
          (linux.test-call-count linux.syscall-poll)
          1
          "one pause"))
      (test.assert-i64-eq (open-descriptors) 0 "closed once")
      (linux.test-reset!)
      (let
        [started : i64 (now)]
        (with
          ([connection
              (open-with
                (& path)
                (mine)
                peer-is-me
                (+ started 250)
                local_ipc.never-canceled)
              local_ipc.cleanup-local-ipc-connection])
          (let
            [attempts : i64 (linux.test-call-count linux.syscall-socket)]
            (test.assert-i64-eq
              (connection-code (& connection))
              (error-code kind-timed-out 0)
              "full backlog times out")
            (test.assert-true
              (>= (- (now) started) 250)
              "waited to the deadline")
            (test.assert-true
              (and (>= attempts 2) (<= attempts 5))
              "bounded attempts")
            (test.assert-i64-eq
              (linux.test-call-count linux.syscall-close)
              attempts
              "every attempt closed")
            (test.assert-true
              (<= (linux.test-call-count linux.syscall-poll) attempts)
              "one pause per attempt"))))
      (linux.test-reset!)
      (let
        [target : local_ipc.LocalIpcEndpoint (UnixPath (string.copy (& path)))]
        (with
          ([connection
              (local_ipc.connect
                (linux.adapter (mine))
                (& target)
                peer-is-me
                (+ (now) 5000)
                local_ipc.never-canceled
                2)
              local_ipc.cleanup-local-ipc-connection])
          (test.assert-i64-eq
            (connection-code (& connection))
            (error-code kind-work-exhausted 0)
            "full backlog exhausts work")
          (test.assert-i64-eq
            (linux.test-call-count linux.syscall-socket)
            2
            "one attempt per unit")
          (test.assert-i64-eq (open-descriptors) 0 "attempts closed")))
      (close-fd first)
      (close-fd backlog-accepted)
      (close-fd listener)
      (remove (& path))
      (remove-dir (& dir)))))

(define delayed-server : i64
  -1)
(define delayed-probes : i64
  0)

;; Sends three bytes on the third cancellation probe.
(cfg
  (all test (not windows))
  (define (send-on-third-probe) : bool
    (set! delayed-probes (+ delayed-probes 1))
    (if (= delayed-probes 3)
      (server-send delayed-server 3)
      unit)
    false))

(define cancel-probes : i64
  0)

(define (cancel-on-third-probe) : bool
  (set! cancel-probes (+ cancel-probes 1))
  (>= cancel-probes 3))

;; Delayed readiness, timeout, cancellation, and a write that commits partial
;; progress before its deadline.
(cfg
  (all test (not windows))
  (test
    local-ipc-linux-readiness
    (let
      [_reset : unit (linux.test-reset!)]
      [dir : String (scratch "ready")]
      [path : String (in-dir (& dir) "agent.sock")]
      [listener : i64 (listen-at (& path) 4)]
      [buffer : byte_buf.ByteBuf (zero-buffer 8)]
      [big : byte_buf.ByteBuf (zero-buffer 1048576)]
      (with
        ([connection (open (& path)) local_ipc.cleanup-local-ipc-connection])
        (set! delayed-server (accept-one listener))
        (set! delayed-probes 0)
        (test.assert-i64-eq
          (io-result-code
            (local_ipc.read-wait!
              (&mut connection)
              (byte_buf.as-mut-bytes (&mut buffer))
              0
              8
              (+ (now) 2000)
              send-on-third-probe
              16))
          3
          "delayed readiness")
        (test.assert-true
          (>= (linux.test-call-count linux.syscall-poll) 1)
          "waited for readiness")
        (let
          [started : i64 (now)]
          (test.assert-i64-eq
            (io-result-code
              (local_ipc.read-wait!
                (&mut connection)
                (byte_buf.as-mut-bytes (&mut buffer))
                0
                8
                (+ started 40)
                local_ipc.never-canceled
                1000))
            (- 0 (error-code kind-timed-out 0))
            "read timeout")
          (test.assert-true (>= (- (now) started) 40) "waited to the deadline"))
        (set! cancel-probes 0)
        (test.assert-i64-eq
          (io-result-code
            (local_ipc.read-wait!
              (&mut connection)
              (byte_buf.as-mut-bytes (&mut buffer))
              0
              8
              (+ (now) 5000)
              cancel-on-third-probe
              1000))
          (- 0 (error-code kind-canceled 0))
          "read canceled")
        (test.assert-i64-eq
          (io-result-code
            (local_ipc.read-wait!
              (&mut connection)
              (byte_buf.as-mut-bytes (&mut buffer))
              0
              8
              (+ (now) 5000)
              local_ipc.never-canceled
              3))
          (- 0 (error-code kind-work-exhausted 0))
          "read work exhausted")
        (let
          [sent : local_ipc.LocalIpcTransfer
            (local_ipc.write-all!
              (&mut connection)
              (byte_buf.as-bytes (& big))
              0
              1048576
              (+ (now) 200)
              local_ipc.never-canceled
              100000)]
          (test.assert-true
            (and (> sent.count 0) (< sent.count 1048576))
            "partial write progress kept")
          (test.assert-i64-eq
            (status-code sent.status)
            (error-code kind-timed-out 0)
            "write timeout"))
        (close-fd delayed-server))
      (test.assert-i64-eq (open-descriptors) 0 "closed once")
      (close-fd listener)
      (remove (& path))
      (remove-dir (& dir)))))

;; One adapter-level readiness round on `token`: clock, a one-slice wait and a
;; read attempt that would block. It hands the buffer back.
(cfg
  (all test (not windows))
  (define (adapter-round
    [adapter : (& adapter local_ipc.LocalIpcAdapter)]
    [token : i64]
    [buffer : byte_buf.ByteBuf]) : byte_buf.ByteBuf
    (let
      [_now : i64 (adapter.now-ms 0)]
      [_ready : local_ipc.LocalIpcWaitStep (adapter.wait-ready 0 token 0 1)]
      [reply : local_ipc.LocalIpcIoReply (adapter.read-once 0 token buffer)]
      reply.buffer)))

;; One contract-level wait-capable read that times out.
(cfg
  (all test (not windows))
  (define (contract-round
    [connection : (&mut connection local_ipc.LocalIpcConnection)]
    [buffer : (&mut buffer byte_buf.ByteBuf)]) : unit
    (let
      [_result : local_ipc.LocalIpcIoResult
        (local_ipc.read-wait!
          connection
          (byte_buf.as-mut-bytes buffer)
          0
          8
          (+ (now) 2)
          local_ipc.never-canceled
          100)]
      unit)))

;; A warmed readiness loop allocates nothing in the adapter. Through the
;; contract it allocates only the caller's byte view (#8089).
(cfg
  (all test (not windows))
  (test
    local-ipc-linux-allocation
    (let
      [_reset : unit (linux.test-reset!)]
      [dir : String (scratch "alloc")]
      [path : String (in-dir (& dir) "agent.sock")]
      [listener : i64 (listen-at (& path) 4)]
      [adapter : local_ipc.LocalIpcAdapter (linux.adapter (mine))]
      [token : i64 (direct-connect (& adapter) (& path))]
      [buffer : byte_buf.ByteBuf (zero-buffer 8)]
      (set! buffer (adapter-round (& adapter) token buffer))
      (let
        [before : i64 (profile.alloc-total)]
        [index : i64 0]
        (while (< index 50)
          (set! buffer (adapter-round (& adapter) token buffer))
          (set! index (+ index 1)))
        (test.assert-i64-eq (- (profile.alloc-total) before) 0 "adapter loop"))
      (test.assert-i64-eq (status-code (adapter.close 0 token)) 0 "close")
      (with
        ([connection (open (& path)) local_ipc.cleanup-local-ipc-connection])
        (contract-round (&mut connection) (&mut buffer))
        (let
          [views-before : i64 (profile.alloc-total)]
          [index : i64 0]
          [_views : unit
            (while (< index 50)
              (begin
                (byte_buf.as-mut-bytes (&mut buffer))
                unit)
              (set! index (+ index 1)))]
          [views : i64 (- (profile.alloc-total) views-before)]
          [before : i64 (profile.alloc-total)]
          [rounds : i64 0]
          (while (< rounds 50)
            (contract-round (&mut connection) (&mut buffer))
            (set! rounds (+ rounds 1)))
          (test.assert-i64-eq
            (- (profile.alloc-total) before)
            views
            "contract loop allocates only views")))
      (test.assert-i64-eq (open-descriptors) 0 "closed once")
      (close-fd (accept-one listener))
      (close-fd (accept-one listener))
      (close-fd listener)
      (remove (& path))
      (remove-dir (& dir)))))

;; A stale token after close and reuse of the slot and descriptor number never
;; reaches the new connection; every descriptor closes exactly once.
(cfg
  (all test (not windows))
  (test
    local-ipc-linux-descriptor-reuse
    (let
      [_reset : unit (linux.test-reset!)]
      [dir : String (scratch "reuse")]
      [path : String (in-dir (& dir) "agent.sock")]
      [listener : i64 (listen-at (& path) 4)]
      [adapter : local_ipc.LocalIpcAdapter (linux.adapter (mine))]
      [old : i64 (direct-connect (& adapter) (& path))]
      [_closed : unit
        (test.assert-i64-eq (status-code (adapter.close 0 old)) 0 "close first")]
      [new : i64 (direct-connect (& adapter) (& path))]
      [closed : i64 (error-code kind-closed 0)]
      (test.assert-true (> old 0) "first token")
      (test.assert-true (> new 0) "second token")
      (test.assert-i64-eq
        (linux.token-slot new)
        (linux.token-slot old)
        "slot reused")
      (test.assert-false (= new old) "new generation")
      (let
        [reply : local_ipc.LocalIpcIoReply
          (adapter.write-once
            0
            old
            (byte_buf.from-array (__tl_make-array u8 3)))]
        [peer : local_ipc.LocalIpcPeerStep (adapter.peer 0 old)]
        (test.assert-i64-eq
          (io-step-code reply.step)
          (- 0 closed)
          "stale write")
        (test.assert-i64-eq (peer-code peer) (- 0 closed) "stale peer")
        (test.assert-i64-eq
          (wait-code (adapter.wait-ready 0 old 0 5))
          closed
          "stale wait")
        (test.assert-i64-eq
          (status-code (adapter.close 0 old))
          closed
          "stale close"))
      (let
        [reply : local_ipc.LocalIpcIoReply
          (adapter.write-once
            0
            new
            (byte_buf.from-array (__tl_make-array u8 3)))]
        (test.assert-i64-eq (io-step-code reply.step) 3 "live write"))
      (test.assert-i64-eq
        (linux.test-call-count linux.syscall-sendto)
        1
        "one host write")
      (test.assert-i64-eq (status-code (adapter.close 0 new)) 0 "close second")
      (test.assert-i64-eq
        (status-code (adapter.close 0 new))
        closed
        "close second twice")
      (test.assert-i64-eq (open-descriptors) 0 "closed once each")
      (test.assert-i64-eq (busy-slots) 0 "slots free")
      (close-fd (accept-one listener))
      (close-fd (accept-one listener))
      (close-fd listener)
      (remove (& path))
      (remove-dir (& dir)))))

;; Scripted construction failures: impossible connect results close the
;; attempt and publish nothing, an impossible descriptor is never closed,
;; EINTR retries on a fresh descriptor, a corrupt pause ends the connect, and
;; a full descriptor table fails before any socket.
(cfg
  (all test (not windows))
  (test
    local-ipc-linux-scripted-construction
    (let
      [dir : String (scratch "scripted")]
      [path : String (in-dir (& dir) "agent.sock")]
      [listener : i64 (listen-at (& path) 16)]
      (linux.test-reset!)
      (linux.test-inject! linux.syscall-connect 1 -115)
      (test.assert-i64-eq
        (connect-code-at (& path) (mine) peer-is-me)
        (error-code kind-adapter-corrupt 115)
        "EINPROGRESS")
      (linux.test-inject! linux.syscall-connect 2 -114)
      (test.assert-i64-eq
        (connect-code-at (& path) (mine) peer-is-me)
        (error-code kind-adapter-corrupt 114)
        "EALREADY")
      (linux.test-inject! linux.syscall-connect 3 -106)
      (test.assert-i64-eq
        (connect-code-at (& path) (mine) peer-is-me)
        (error-code kind-adapter-corrupt 106)
        "EISCONN")
      (linux.test-inject! linux.syscall-connect 4 1)
      (test.assert-i64-eq
        (connect-code-at (& path) (mine) peer-is-me)
        (error-code kind-adapter-corrupt 0)
        "positive connect")
      (test.assert-i64-eq
        (linux.test-call-count linux.syscall-close)
        4
        "attempts closed")
      (test.assert-i64-eq (open-descriptors) 0 "nothing published")
      (linux.test-reset!)
      (linux.test-inject! linux.syscall-socket 1 1099511627776)
      (test.assert-i64-eq
        (connect-code-at (& path) (mine) peer-is-me)
        (error-code kind-adapter-corrupt 0)
        "impossible fd")
      (linux.test-inject! linux.syscall-socket 2 -24)
      (test.assert-i64-eq
        (connect-code-at (& path) (mine) peer-is-me)
        (error-code kind-resource-exhausted 24)
        "EMFILE")
      (test.assert-i64-eq
        (linux.test-call-count linux.syscall-close)
        0
        "nothing to close")
      (test.assert-i64-eq
        (linux.test-call-count linux.syscall-connect)
        0
        "no connect")
      (linux.test-reset!)
      (linux.test-inject! linux.syscall-newfstatat 1 -13)
      (test.assert-i64-eq
        (connect-code-at (& path) (mine) peer-is-me)
        (error-code kind-permission-denied 13)
        "stat EACCES")
      (linux.test-inject! linux.syscall-newfstatat 2 5)
      (test.assert-i64-eq
        (connect-code-at (& path) (mine) peer-is-me)
        (error-code kind-adapter-corrupt 0)
        "stat count")
      (linux.test-script! linux.syscall-newfstatat 3 0 33152 (user-id) 0 -1)
      (test.assert-i64-eq
        (connect-code-at (& path) (mine) peer-is-me)
        (error-code kind-policy-rejected 88)
        "scripted type")
      (test.assert-i64-eq
        (linux.test-call-count linux.syscall-socket)
        0
        "no socket")
      (linux.test-reset!)
      (linux.test-inject! linux.syscall-connect 1 -4)
      (test.assert-i64-eq
        (connect-code-at (& path) (mine) peer-is-me)
        0
        "EINTR retried")
      (test.assert-i64-eq
        (linux.test-call-count linux.syscall-socket)
        2
        "fresh descriptor")
      (test.assert-i64-eq
        (linux.test-call-count linux.syscall-newfstatat)
        2
        "path rechecked")
      (test.assert-i64-eq
        (linux.test-call-count linux.syscall-poll)
        1
        "paused once")
      (test.assert-i64-eq (open-descriptors) 0 "closed once")
      (linux.test-reset!)
      (linux.test-inject! linux.syscall-connect 1 -11)
      (linux.test-inject! linux.syscall-poll 1 1)
      (test.assert-i64-eq
        (connect-code-at (& path) (mine) peer-is-me)
        (error-code kind-adapter-corrupt 0)
        "corrupt pause")
      (test.assert-i64-eq
        (linux.test-call-count linux.syscall-socket)
        1
        "no retry")
      (test.assert-i64-eq (open-descriptors) 0 "attempt closed")
      (linux.test-reset!)
      (let
        [held : (__tl_dyn-array i64) (__tl_make-array i64 linux.slot-capacity)]
        [count : i64 0]
        [slot : i64 0]
        (while (>= slot 0)
          (set!
            slot
            (unsafe
              (linux.slot-reserve!)))
          (when
            (>= slot 0)
            (set! (array-ref held count) slot)
            (set! count (+ count 1))))
        (test.assert-i64-eq
          (connect-code-at (& path) (mine) peer-is-me)
          (error-code kind-resource-exhausted 0)
          "table full")
        (test.assert-i64-eq
          (linux.test-call-count linux.syscall-socket)
          0
          "no socket")
        (set! slot 0)
        (while (< slot count)
          (unsafe
            (linux.slot-unreserve! (array-ref held slot)))
          (set! slot (+ slot 1))))
      (test.assert-i64-eq (busy-slots) 0 "slots free")
      (test.assert-i64-eq
        (connect-code-at (& path) (mine) peer-is-me)
        0
        "table usable again")
      (close-fd listener)
      (remove (& path))
      (remove-dir (& dir)))))

;; Scripted data and readiness corruption on a live connection: an oversized
;; count or zero-byte write poisons it (later calls fail without a host call,
;; close still closes once), and POLLNVAL loses the descriptor, which is then
;; never closed by the adapter.
(cfg
  (all test (not windows))
  (test
    local-ipc-linux-scripted-io
    (let
      [dir : String (scratch "scripted-io")]
      [path : String (in-dir (& dir) "agent.sock")]
      [listener : i64 (listen-at (& path) 16)]
      [adapter : local_ipc.LocalIpcAdapter (linux.adapter (mine))]
      [corrupt : i64 (error-code kind-adapter-corrupt 0)]
      [buffer : byte_buf.ByteBuf (zero-buffer 4)]
      (linux.test-reset!)
      (let
        [token : i64 (direct-connect (& adapter) (& path))]
        [_script : unit (linux.test-inject! linux.syscall-read 1 5)]
        [first : local_ipc.LocalIpcIoReply (adapter.read-once 0 token buffer)]
        [second : local_ipc.LocalIpcIoReply
          (adapter.read-once 0 token first.buffer)]
        (set! buffer second.buffer)
        (test.assert-i64-eq
          (io-step-code first.step)
          (- 0 corrupt)
          "oversized read")
        (test.assert-i64-eq (io-step-code second.step) (- 0 corrupt) "poisoned")
        (test.assert-i64-eq
          (wait-code (adapter.wait-ready 0 token 0 5))
          corrupt
          "poisoned wait")
        (test.assert-i64-eq
          (linux.test-call-count linux.syscall-read)
          1
          "no second read")
        (test.assert-i64-eq
          (status-code (adapter.close 0 token))
          0
          "close poisoned")
        (test.assert-i64-eq (open-descriptors) 0 "closed once"))
      (let
        [token : i64 (direct-connect (& adapter) (& path))]
        [_script : unit (linux.test-inject! linux.syscall-sendto 1 0)]
        [reply : local_ipc.LocalIpcIoReply (adapter.write-once 0 token buffer)]
        (set! buffer reply.buffer)
        (test.assert-i64-eq
          (io-step-code reply.step)
          (- 0 corrupt)
          "zero write")
        (test.assert-i64-eq (status-code (adapter.close 0 token)) 0 "close")
        (test.assert-i64-eq (open-descriptors) 0 "closed once"))
      (let
        [token : i64 (direct-connect (& adapter) (& path))]
        [slot : i64 (linux.token-slot token)]
        [fd : i64
          (unsafe
            (atomic-load (linux.slot-word slot 1)))]
        (linux.test-script! linux.syscall-poll 1 1 -1 -1 64 -1)
        (test.assert-i64-eq
          (wait-code (adapter.wait-ready 0 token 0 5))
          corrupt
          "unknown bit")
        (test.assert-i64-eq (status-code (adapter.close 0 token)) 0 "close")
        (let
          [again : i64 (direct-connect (& adapter) (& path))]
          (linux.test-script! linux.syscall-poll 2 1 -1 -1 32 -1)
          (test.assert-i64-eq
            (wait-code (adapter.wait-ready 0 again 0 5))
            corrupt
            "POLLNVAL")
          (let
            [lost-fd : i64
              (unsafe
                (atomic-load (linux.slot-word (linux.token-slot again) 1)))]
            [closes : i64 (linux.test-call-count linux.syscall-close)]
            (test.assert-i64-eq
              (status-code (adapter.close 0 again))
              corrupt
              "lost descriptor")
            (test.assert-i64-eq
              (linux.test-call-count linux.syscall-close)
              closes
              "lost descriptor never closed")
            (close-fd lost-fd)))
        (test.assert-true (>= fd 0) "real descriptor"))
      (let
        [token : i64 (direct-connect (& adapter) (& path))]
        (linux.test-script! linux.syscall-poll 3 1 99999 -1 -1 -1)
        (test.assert-i64-eq
          (wait-code (adapter.wait-ready 0 token 0 5))
          corrupt
          "fd changed")
        (test.assert-i64-eq (status-code (adapter.close 0 token)) 0 "close"))
      (let
        [token : i64 (direct-connect (& adapter) (& path))]
        (linux.test-inject! linux.syscall-poll 4 -4)
        (test.assert-i64-eq
          (wait-code (adapter.wait-ready 0 token 0 5))
          2
          "wait EINTR")
        (test.assert-i64-eq
          (wait-code (adapter.wait-ready 0 token 1 5))
          0
          "not poisoned")
        (test.assert-i64-eq (status-code (adapter.close 0 token)) 0 "close"))
      (test.assert-i64-eq (busy-slots) 0 "slots free")
      (let
        [server : i64 (accept-one listener)]
        (while (>= server 0)
          (close-fd server)
          (set! server (accept-one listener))))
      (close-fd listener)
      (remove (& path))
      (remove-dir (& dir)))))
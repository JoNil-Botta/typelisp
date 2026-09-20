;; A connection is move-only: once moved into a second owner the first cannot
;; be used, so one native handle never has two owners.
(import stdlib.local_ipc)
(import stdlib.local_ipc_fake as fake)

(define agent-socket : local_ipc.LocalIpcEndpoint
  (local_ipc.LocalIpcEndpoint.UnixPath "/run/agent.sock"))

(define (main) : i64
  (with
    ([first
        (local_ipc.connect
          (fake.adapter (fake.new))
          (& agent-socket)
          local_ipc.accept-any-peer
          1000000
          local_ipc.never-canceled
          16)
        local_ipc.cleanup-local-ipc-connection])
    (with
      ([second first local_ipc.cleanup-local-ipc-connection])
      (if (and
        (local_ipc.connection-open? (& first))
        (local_ipc.connection-open? (& second)))
        1
        42))))
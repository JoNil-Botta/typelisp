;; Check-only rejection: the internals of stdlib.local_ipc that take a raw
;; address are unsafe declarations, so safe code cannot hand them an arbitrary
;; address. The public wrappers derive the address from a borrowed view.
(import stdlib.local_ipc)
(import stdlib.local_ipc_fake as fake)

(define agent-socket : local_ipc.LocalIpcEndpoint
  (local_ipc.LocalIpcEndpoint.UnixPath "/run/agent.sock"))

(define (main) : i64
  (let
    [context : i64 (fake.new)]
    (with
      ([connection
          (local_ipc.connect
            (fake.adapter context)
            (& agent-socket)
            local_ipc.accept-any-peer
            1000000
            local_ipc.never-canceled
            16)
          local_ipc.cleanup-local-ipc-connection])
      (begin
        (local_ipc.io-once (&mut connection) false 64 8)
        42))))
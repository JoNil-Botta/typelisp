;; Safe code cannot forge a connection's native identity: outside its module
;; family the sealed owner is constructed only in an unsafe context (#9783).
(import stdlib.local_ipc)

(define (main) : i64
  (with
    ([forged
        (local_ipc.LocalIpcConnection
          (local_ipc.LocalIpcOwner
            (int->ptr
              (cast 4096 : u64)
              : (MutPtr local_ipc.LocalIpcConnectionState))
            0))
        local_ipc.cleanup-local-ipc-connection])
    (if (local_ipc.connection-open? (& forged))
      1
      42)))
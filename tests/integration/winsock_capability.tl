(import stdlib.net_windows_winsock as winsock)

;; lint-allow: unused-import -- consumed by comptime layout query.
(import stdlib.net_windows_winsock.WinsockWsaData)

;; lint-allow: unused-import -- consumed by comptime layout query.
(import stdlib.net_windows_winsock.WinsockProtocolInfoW)

;; lint-allow: unused-import -- consumed by comptime layout query.
(import stdlib.net_windows_winsock.WinsockSockAddr)

;; lint-allow: unused-import -- consumed by comptime layout query.
(import stdlib.net_windows_winsock.WinsockFdSet)

;; lint-allow: unused-import -- consumed by comptime layout query.
(import stdlib.net_windows_winsock.WinsockTimeval)

;; lint-allow: unused-import -- consumed by comptime layout query.
(import stdlib.net_windows_winsock.WinsockTable)

;; lint-allow: unused-import -- consumed by comptime layout query.
(import stdlib.net_windows_winsock.WinsockLease)

;: Pin the layouts and every consumed scalar width on both x86-64 targets.
(define (winsock-layout-ok?) : bool
  (and
    (= (comptime (size-of (type WinsockWsaData))) 408)
    (= (comptime (align-of (type WinsockWsaData))) 8)
    (= (comptime (offset-of (type WinsockWsaData) version)) 0)
    (= (comptime (offset-of (type WinsockWsaData) high-version)) 2)
    (= (comptime (offset-of (type WinsockWsaData) max-sockets)) 4)
    (= (comptime (offset-of (type WinsockWsaData) max-udp-dg)) 6)
    (= (comptime (offset-of (type WinsockWsaData) vendor-info)) 8)
    (= (comptime (offset-of (type WinsockWsaData) description)) 16)
    (= (comptime (offset-of (type WinsockWsaData) status)) 273)
    (= (comptime (size-of (type WinsockProtocolInfoW))) 628)
    (= (comptime (align-of (type WinsockProtocolInfoW))) 4)
    (= (comptime (size-of (type WinsockSockAddr))) 16)
    (= (comptime (align-of (type WinsockSockAddr))) 2)
    (= (comptime (size-of (type WinsockFdSet))) 520)
    (= (comptime (align-of (type WinsockFdSet))) 8)
    (= (comptime (offset-of (type WinsockFdSet) sockets)) 8)
    (= (comptime (size-of (type WinsockTimeval))) 8)
    (= (comptime (align-of (type WinsockTimeval))) 4)
    (= (comptime (size-of (type WinsockTable))) 176)
    (= (comptime (align-of (type WinsockTable))) 8)
    (= (comptime (offset-of (type WinsockTable) duplicate-socket)) 168)
    (= (comptime (size-of (type WinsockLease))) 8)
    (= (comptime (align-of (type WinsockLease))) 8)
    (= (comptime (size-of (type u16))) 2)
    (= (comptime (size-of (type i32))) 4)
    (= (comptime (size-of (type u32))) 4)
    (= (comptime (size-of (type u64))) 8)
    (= winsock.winsock-invalid-socket (bit-not (cast 0 : u64)))))

;: Real Windows smoke covers first load, failed and wrong-version startup,
;: two live leases, immutable table access, and exact-once scoped cleanup.
(cfg
  windows
  (define (winsock-runtime-smoke) : i64
    (match (unsafe
      (winsock.winsock-acquire-with-fault 1))
      [(winsock.WinsockAcquireErr (winsock.WinsockStartupFailed code))
        (when (!= code (cast 10093 : i32)) (return 1))]
      [(winsock.WinsockAcquired lease)
        (with ([owned lease winsock.cleanup-winsock-lease]) (return 2))]
      [_ (return 2)])
    (match (unsafe
      (winsock.winsock-acquire-with-fault 2))
      [(winsock.WinsockAcquireErr (winsock.WinsockVersionMismatch version))
        (when (!= version (cast 257 : u16)) (return 3))]
      [(winsock.WinsockAcquired lease)
        (with ([owned lease winsock.cleanup-winsock-lease]) (return 4))]
      [_ (return 4)])
    (match (winsock.winsock-acquire)
      [(winsock.WinsockAcquireErr _) 5]
      [(winsock.WinsockAcquired first)
        (with
          ([first-lease first winsock.cleanup-winsock-lease])
          (match (winsock.winsock-acquire)
            [(winsock.WinsockAcquireErr _) 6]
            [(winsock.WinsockAcquired second)
              (with
                ([second-lease second winsock.cleanup-winsock-lease])
                (match (unsafe
                  (winsock.winsock-table-for-lease (& first-lease)))
                  [(winsock.WinsockTableErr _) 7]
                  [(winsock.WinsockTableOk first-table)
                    (match (unsafe
                      (winsock.winsock-table-for-lease (& second-lease)))
                      [(winsock.WinsockTableErr _) 8]
                      [(winsock.WinsockTableOk second-table)
                        (if (and
                          (!= first-table.module (cast 0 : u64))
                          (= first-table.module second-table.module))
                          42
                          9)])]))]))])))

(define (main) : i64
  (if (winsock-layout-ok?)
    (cfg
      windows
      (winsock-runtime-smoke)
      (match (winsock.winsock-acquire)
        [(winsock.WinsockAcquireErr (winsock.WinsockUnsupportedTarget)) 42]
        [_ 11]))
    10))
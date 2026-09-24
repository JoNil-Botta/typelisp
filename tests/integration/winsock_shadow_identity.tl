;; lint-allow: unused-import -- the shadow probe is Windows-only.
(import stdlib.net_windows_winsock as winsock)

;: The gate runs this from a directory containing a non-System32 Ws2_32.dll.
;: The preloader may return that DLL or the OS KnownDLL. In either case a
;: successful capability must identify the actual System32 module.
(cfg
  windows
  (define (shadow-path) : (Array u16 13)
    (array
      (cast '.' : u16)
      (cast '\\' : u16)
      (cast 'W' : u16)
      (cast 's' : u16)
      (cast '2' : u16)
      (cast '_' : u16)
      (cast '3' : u16)
      (cast '2' : u16)
      (cast '.' : u16)
      (cast 'd' : u16)
      (cast 'l' : u16)
      (cast 'l' : u16)
      (cast '\0' : u16))))

(cfg
  windows
  (define (shadow-probe) : i64
    (let
      [path : (Array u16 13) (shadow-path)]
      [preloaded : u64
        (winsock.winsock-load-library-ex-w
          (unsafe
            (ptr-cast (__tl_array-data path) : (Ptr u16)))
          (cast 0 : u64)
          (cast 0 : u32))]
      (when (= preloaded (cast 0 : u64)) (return 1))
      (let
        [preloaded-identity : winsock.WinsockIdentityResult
          (winsock.winsock-check-module-identity preloaded)]
        [result : i64
          (match (winsock.winsock-acquire)
            [(winsock.WinsockAcquireErr (winsock.WinsockIdentityMismatch))
              (match preloaded-identity
                [(winsock.WinsockIdentityWrongModule) 42]
                [_ 2])]
            [(winsock.WinsockAcquireErr _) 3]
            [(winsock.WinsockAcquired lease)
              (with
                ([owned lease winsock.cleanup-winsock-lease])
                (match (unsafe
                  (winsock.winsock-table-for-lease (& owned)))
                  [(winsock.WinsockTableErr _) 4]
                  [(winsock.WinsockTableOk table)
                    (match (winsock.winsock-check-module-identity table.module)
                      [(winsock.WinsockIdentityOk) 43]
                      [_ 5])]))])]
        (winsock.winsock-free-library preloaded)
        result))))

(define (main) : i64
  (cfg windows (shadow-probe) 42))
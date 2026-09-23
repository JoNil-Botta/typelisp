;# Private Windows x86-64 Winsock 2.2 capability and startup lease substrate.
;#
;# The module holds one validated System32 Ws2_32.dll reference for process
;# lifetime. Every successful startup is paired with one move-only lease. The
;# socket adapter in #7379 will consume this internal surface.
(import stdlib.ffi)
(cfg test (import stdlib.io))
(cfg test (import stdlib.string))
(cfg test (import stdlib.thread))
(cfg test (import stdlib.time))

;: Exact Windows x64 WSADATA layout (winsock2.h, _WIN64 branch).
(defstruct WinsockWsaData
  (version u16)
  (high-version u16)
  (max-sockets u16)
  (max-udp-dg u16)
  (vendor-info (Ptr u8))
  (description (Array u8 257))
  (status (Array u8 129)))

;: Opaque WSAPROTOCOL_INFOW storage with its native four-byte alignment.
(defstruct WinsockProtocolInfoW
  (words (Array u32 157)))

;: Base sockaddr; the later adapter casts larger IPv4/IPv6 records to it.
(defstruct WinsockSockAddr
  (family u16)
  (data (Array u8 14)))

;: Default Windows fd_set has a 32-bit count and 64 pointer-width sockets.
(defstruct WinsockFdSet
  (count u32)
  (sockets (Array u64 64)))

;: Windows timeval uses two 32-bit long fields.
(defstruct WinsockTimeval
  (seconds i32)
  (microseconds i32))

;: Immutable table after publication. Every C pointer has its exact ABI type.
(defstruct WinsockTable
  (module u64)
  (startup (CFunc unsafe-non-null (-> u16 (MutPtr WinsockWsaData) i32)))
  (cleanup (CFunc unsafe-non-null (-> i32)))
  (last-error (CFunc unsafe-non-null (-> i32)))
  (socket
    (CFunc
      unsafe-non-null
      (-> i32 i32 i32 (MutPtr WinsockProtocolInfoW) u32 u32 u64)))
  (close (CFunc unsafe-non-null (-> u64 i32)))
  (ioctl (CFunc unsafe-non-null (-> u64 i32 (MutPtr u32) i32)))
  (bind (CFunc unsafe-non-null (-> u64 (Ptr WinsockSockAddr) i32 i32)))
  (listen (CFunc unsafe-non-null (-> u64 i32 i32)))
  (accept
    (CFunc unsafe-non-null (-> u64 (MutPtr WinsockSockAddr) (MutPtr i32) u64)))
  (connect (CFunc unsafe-non-null (-> u64 (Ptr WinsockSockAddr) i32 i32)))
  (local-name
    (CFunc unsafe-non-null (-> u64 (MutPtr WinsockSockAddr) (MutPtr i32) i32)))
  (peer-name
    (CFunc unsafe-non-null (-> u64 (MutPtr WinsockSockAddr) (MutPtr i32) i32)))
  (receive (CFunc unsafe-non-null (-> u64 (MutPtr u8) i32 i32 i32)))
  (send (CFunc unsafe-non-null (-> u64 (Ptr u8) i32 i32 i32)))
  (receive-from
    (CFunc
      unsafe-non-null
      (-> u64 (MutPtr u8) i32 i32 (MutPtr WinsockSockAddr) (MutPtr i32) i32)))
  (send-to
    (CFunc
      unsafe-non-null
      (-> u64 (Ptr u8) i32 i32 (Ptr WinsockSockAddr) i32 i32)))
  (shutdown (CFunc unsafe-non-null (-> u64 i32 i32)))
  (get-option
    (CFunc unsafe-non-null (-> u64 i32 i32 (MutPtr u8) (MutPtr i32) i32)))
  (set-option (CFunc unsafe-non-null (-> u64 i32 i32 (Ptr u8) i32 i32)))
  (select
    (CFunc
      unsafe-non-null
      (->
        i32
        (MutPtr WinsockFdSet)
        (MutPtr WinsockFdSet)
        (MutPtr WinsockFdSet)
        (Ptr WinsockTimeval)
        i32)))
  (duplicate-socket
    (CFunc unsafe-non-null (-> u64 u32 (MutPtr WinsockProtocolInfoW) i32))))

;: Candidate and acquisition errors name the rejected schema slot precisely.
(defenum WinsockError
  (WinsockUnsupportedTarget)
  (WinsockLoadUnavailable u32)
  (WinsockIdentityUnavailable)
  (WinsockIdentityMismatch)
  (WinsockAbiLayoutMismatch)
  (WinsockMissingExport String)
  (WinsockStartupFailed i32)
  (WinsockVersionMismatch u16)
  (WinsockLeaseCapacityExceeded)
  (WinsockLeaseInvalid)
  (WinsockSocketCallFailed i32)
  (WinsockDuplicateCallFailed i32))

;: A complete validated table or the first candidate error.
(defenum WinsockTableResult
  (WinsockTableOk WinsockTable)
  (WinsockTableErr WinsockError))

;: Native socket construction returns the pointer-width descriptor or an error.
(defenum WinsockSocketResult
  (WinsockSocketOk u64)
  (WinsockSocketErr WinsockError))

;: Same-process socket duplication reports its native call result.
(defenum WinsockDuplicateResult
  (WinsockDuplicateOk)
  (WinsockDuplicateErr WinsockError))

;: Kernel32 is the only static loader import. The DLL's functions stay dynamic.
(extern (winsock-load-library-ex-w
  [name : (Ptr u16)]
  [file : u64]
  [flags : u32]) : u64 (:symbol "LoadLibraryExW"))

;: Query the path of the exact HMODULE returned by the secure load.
(extern (winsock-get-module-file-name-w
  [module : u64]
  [buffer : (MutPtr u16)]
  [capacity : u32]) : u32 (:symbol "GetModuleFileNameW"))

;: Supply the trusted System32 directory for exact module identity checking.
(extern (winsock-get-system-directory-w
  [buffer : (MutPtr u16)]
  [capacity : u32]) : u32 (:symbol "GetSystemDirectoryW"))

;: Compare the full UTF-16 paths without locale-dependent casing.
(extern (winsock-compare-string-ordinal
  [left : (Ptr u16)]
  [left-length : i32]
  [right : (Ptr u16)]
  [right-length : i32]
  [ignore-case : i32]) : i32 (:symbol "CompareStringOrdinal"))

;: Release only an unpublished candidate module reference.
(extern (winsock-free-library [module : u64]) : i32 (:symbol "FreeLibrary"))

;: Capture the loader's native failure code before another call changes it.
(extern (winsock-get-last-error) : u32 (:symbol "GetLastError"))
(cfg
  test
  (extern (winsock-current-process-id) : u32 (:symbol "GetCurrentProcessId")))

;: Typed GetProcAddress declarations preserve all 21 C ABI signatures.
(extern (winsock-lookup-startup [module : u64] [name : (Ptr u8)]) : (CFunc
  unsafe-nullable
  (-> u16 (MutPtr WinsockWsaData) i32)) (:symbol "GetProcAddress"))

;: Resolve WSACleanup with its no-argument integer return signature.
(extern (winsock-lookup-cleanup [module : u64] [name : (Ptr u8)]) : (CFunc
  unsafe-nullable
  (-> i32)) (:symbol "GetProcAddress"))

;: Resolve WSAGetLastError with its no-argument integer return signature.
(extern (winsock-lookup-last-error [module : u64] [name : (Ptr u8)]) : (CFunc
  unsafe-nullable
  (-> i32)) (:symbol "GetProcAddress"))

;: Resolve WSASocketW with pointer-width SOCKET and typed protocol storage.
(extern (winsock-lookup-socket [module : u64] [name : (Ptr u8)]) : (CFunc
  unsafe-nullable
  (-> i32 i32 i32 (MutPtr WinsockProtocolInfoW) u32 u32 u64)) (:symbol "GetProcAddress"))

;: Resolve closesocket for an unsigned pointer-width SOCKET.
(extern (winsock-lookup-close [module : u64] [name : (Ptr u8)]) : (CFunc
  unsafe-nullable
  (-> u64 i32)) (:symbol "GetProcAddress"))

;: Resolve ioctlsocket with its mutable ULONG argument.
(extern (winsock-lookup-ioctl [module : u64] [name : (Ptr u8)]) : (CFunc
  unsafe-nullable
  (-> u64 i32 (MutPtr u32) i32)) (:symbol "GetProcAddress"))

;: Resolve bind with a typed base sockaddr pointer and integer length.
(extern (winsock-lookup-bind [module : u64] [name : (Ptr u8)]) : (CFunc
  unsafe-nullable
  (-> u64 (Ptr WinsockSockAddr) i32 i32)) (:symbol "GetProcAddress"))

;: Resolve listen with its integer backlog.
(extern (winsock-lookup-listen [module : u64] [name : (Ptr u8)]) : (CFunc
  unsafe-nullable
  (-> u64 i32 i32)) (:symbol "GetProcAddress"))

;: Resolve accept with mutable address and length outputs.
(extern (winsock-lookup-accept [module : u64] [name : (Ptr u8)]) : (CFunc
  unsafe-nullable
  (-> u64 (MutPtr WinsockSockAddr) (MutPtr i32) u64)) (:symbol "GetProcAddress"))

;: Resolve connect with a typed base sockaddr pointer.
(extern (winsock-lookup-connect [module : u64] [name : (Ptr u8)]) : (CFunc
  unsafe-nullable
  (-> u64 (Ptr WinsockSockAddr) i32 i32)) (:symbol "GetProcAddress"))

;: Resolve getsockname with mutable address and length outputs.
(extern (winsock-lookup-local-name [module : u64] [name : (Ptr u8)]) : (CFunc
  unsafe-nullable
  (-> u64 (MutPtr WinsockSockAddr) (MutPtr i32) i32)) (:symbol "GetProcAddress"))

;: Resolve getpeername with mutable address and length outputs.
(extern (winsock-lookup-peer-name [module : u64] [name : (Ptr u8)]) : (CFunc
  unsafe-nullable
  (-> u64 (MutPtr WinsockSockAddr) (MutPtr i32) i32)) (:symbol "GetProcAddress"))

;: Resolve recv with a mutable byte buffer and integer flags.
(extern (winsock-lookup-receive [module : u64] [name : (Ptr u8)]) : (CFunc
  unsafe-nullable
  (-> u64 (MutPtr u8) i32 i32 i32)) (:symbol "GetProcAddress"))

;: Resolve send with a borrowed byte buffer and integer flags.
(extern (winsock-lookup-send [module : u64] [name : (Ptr u8)]) : (CFunc
  unsafe-nullable
  (-> u64 (Ptr u8) i32 i32 i32)) (:symbol "GetProcAddress"))

;: Resolve recvfrom with mutable bytes, address, and address length.
(extern (winsock-lookup-receive-from [module : u64] [name : (Ptr u8)]) : (CFunc
  unsafe-nullable
  (-> u64 (MutPtr u8) i32 i32 (MutPtr WinsockSockAddr) (MutPtr i32) i32)) (:symbol "GetProcAddress"))

;: Resolve sendto with borrowed bytes and a typed destination address.
(extern (winsock-lookup-send-to [module : u64] [name : (Ptr u8)]) : (CFunc
  unsafe-nullable
  (-> u64 (Ptr u8) i32 i32 (Ptr WinsockSockAddr) i32 i32)) (:symbol "GetProcAddress"))

;: Resolve shutdown with its integer direction selector.
(extern (winsock-lookup-shutdown [module : u64] [name : (Ptr u8)]) : (CFunc
  unsafe-nullable
  (-> u64 i32 i32)) (:symbol "GetProcAddress"))

;: Resolve getsockopt with a mutable option buffer and length.
(extern (winsock-lookup-get-option [module : u64] [name : (Ptr u8)]) : (CFunc
  unsafe-nullable
  (-> u64 i32 i32 (MutPtr u8) (MutPtr i32) i32)) (:symbol "GetProcAddress"))

;: Resolve setsockopt with a borrowed option buffer and integer length.
(extern (winsock-lookup-set-option [module : u64] [name : (Ptr u8)]) : (CFunc
  unsafe-nullable
  (-> u64 i32 i32 (Ptr u8) i32 i32)) (:symbol "GetProcAddress"))

;: Resolve select with Windows fd_set and timeval pointer layouts.
(extern (winsock-lookup-select [module : u64] [name : (Ptr u8)]) : (CFunc
  unsafe-nullable
  (->
    i32
    (MutPtr WinsockFdSet)
    (MutPtr WinsockFdSet)
    (MutPtr WinsockFdSet)
    (Ptr WinsockTimeval)
    i32)) (:symbol "GetProcAddress"))

;: Resolve WSADuplicateSocketW with typed protocol-info output.
(extern (winsock-lookup-duplicate-socket [module : u64] [name : (Ptr u8)]) : (CFunc
  unsafe-nullable
  (-> u64 u32 (MutPtr WinsockProtocolInfoW) i32)) (:symbol "GetProcAddress"))

;: LOAD_LIBRARY_SEARCH_SYSTEM32 is the only admitted search mode.
(define winsock-system32-search : u32
  2048)

;: MAKEWORD(2, 2); wVersion must match this exact value.
(define winsock-version-2-2 : u16
  514)

;: SOCKET is an unsigned pointer-width value, including INVALID_SOCKET.
(define winsock-invalid-socket : u64
  (bit-not (cast 0 : u64)))

;: The candidate cannot be published if any consumed x64 ABI layout drifts.
(define (winsock-abi-layout-ok?) : bool
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
    (= (comptime (size-of (type WinsockTimeval))) 8)
    (= (comptime (align-of (type WinsockTimeval))) 4)
    (= (comptime (size-of (type WinsockTable))) 176)
    (= (comptime (align-of (type WinsockTable))) 8)
    (= (comptime (size-of (type u16))) 2)
    (= (comptime (size-of (type i32))) 4)
    (= (comptime (size-of (type u32))) 4)
    (= (comptime (size-of (type u64))) 8)))

;: Native-call counters exist only in inline-test builds.
(cfg
  test
  (define winsock-test-load-count : i64
    0))
(cfg
  test
  (define winsock-test-resolve-count : i64
    0))
(cfg
  test
  (define winsock-test-release-count : i64
    0))
(cfg
  test
  (define winsock-test-startup-count : i64
    0))
(cfg
  test
  (define winsock-test-cleanup-count : i64
    0))

(cfg
  test
  (define (winsock-test-reset-counters!) : unit
    (begin
      (unsafe
        (atomic-store! (ptr-addr-of winsock-test-load-count) 0))
      (unsafe
        (atomic-store! (ptr-addr-of winsock-test-resolve-count) 0))
      (unsafe
        (atomic-store! (ptr-addr-of winsock-test-release-count) 0))
      (unsafe
        (atomic-store! (ptr-addr-of winsock-test-startup-count) 0))
      (unsafe
        (atomic-store! (ptr-addr-of winsock-test-cleanup-count) 0)))))

(cfg
  test
  (define (winsock-test-counters-match?
    [loads : i64]
    [resolves : i64]
    [releases : i64]
    [startups : i64]
    [cleanups : i64]) : bool
    (and
      (=
        (unsafe
          (atomic-load (ptr-addr-of winsock-test-load-count)))
        loads)
      (=
        (unsafe
          (atomic-load (ptr-addr-of winsock-test-resolve-count)))
        resolves)
      (=
        (unsafe
          (atomic-load (ptr-addr-of winsock-test-release-count)))
        releases)
      (=
        (unsafe
          (atomic-load (ptr-addr-of winsock-test-startup-count)))
        startups)
      (=
        (unsafe
          (atomic-load (ptr-addr-of winsock-test-cleanup-count)))
        cleanups))))

;: Record an actual GetProcAddress call, excluding an injected miss.
(define (winsock-resolve-slot? [slot : i64] [missing-at : i64]) : bool
  (if (= slot missing-at)
    false
    (begin
      (cfg
        test
        (unsafe
          (atomic-add! (ptr-addr-of winsock-test-resolve-count) 1))
        unit)
      true)))

;: Test counters observe actual native calls, not merely requested outcomes.
(define (winsock-load-system32 [name : (Ptr u16)]) : u64
  (begin
    (cfg
      test
      (unsafe
        (atomic-add! (ptr-addr-of winsock-test-load-count) 1))
      unit)
    (winsock-load-library-ex-w name (cast 0 : u64) winsock-system32-search)))

;: Balance exactly the reference acquired for a rejected candidate.
(define (winsock-release-candidate [module : u64]) : unit
  (begin
    (cfg
      test
      (unsafe
        (atomic-add! (ptr-addr-of winsock-test-release-count) 1))
      unit)
    (winsock-free-library module)
    unit))

(unsafe
  (define (winsock-call-startup
    [table : WinsockTable]
    [data : (MutPtr WinsockWsaData)]) : i32
    (begin
      (cfg
        test
        (unsafe
          (atomic-add! (ptr-addr-of winsock-test-startup-count) 1))
        unit)
      (unsafe
        (table.startup winsock-version-2-2 data)))))

(unsafe
  (define (winsock-call-cleanup [table : WinsockTable]) : i32
    (begin
      (cfg
        test
        (unsafe
          (atomic-add! (ptr-addr-of winsock-test-cleanup-count) 1))
        unit)
      (unsafe
        (table.cleanup)))))

;: Stack-owned UTF-16 spelling used for the sole DLL load and path comparison.
(define (winsock-dll-wide-name) : (Array u16 11)
  (array
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
    (cast '\0' : u16)))

;: Identity queries fail closed on errors, truncation and non-System32 paths.
(defenum WinsockIdentityResult
  (WinsockIdentityOk)
  (WinsockIdentityQueryFailed)
  (WinsockIdentityWrongModule))

;: Compare a checked returned-module path with the System32 path plus basename.
;: The buffer inputs are copied so the expected path can be constructed locally.
(define (winsock-identity-from-paths
  [module-path : (Array u16 1024)]
  [module-length : i64]
  [system-path : (Array u16 1024)]
  [system-length : i64]) : WinsockIdentityResult
  (let
    [capacity : i64 1024]
    (when
      (or
        (<= module-length 0)
        (>= module-length capacity)
        (<= system-length 0)
        (>= system-length capacity))
      (return (WinsockIdentityQueryFailed)))
    (when
      (or
        (!= (array-ref module-path module-length) (cast 0 : u16))
        (!= (array-ref system-path system-length) (cast 0 : u16)))
      (return (WinsockIdentityQueryFailed)))
    (let
      [last : u16 (array-ref system-path (- system-length 1))]
      [separator : i64
        (if (or (= last (cast '\\' : u16)) (= last (cast '/' : u16)))
          0
          1)]
      [expected-length : i64 (+ system-length separator 10)]
      (when (>= expected-length capacity) (return (WinsockIdentityQueryFailed)))
      (when
        (= separator 1)
        (set! (array-ref system-path system-length) (cast '\\' : u16)))
      (let
        [name : (Array u16 11) (winsock-dll-wide-name)]
        [index : i64 0]
        (while (< index 11)
          (begin
            (set!
              (array-ref system-path (+ system-length separator index))
              (array-ref name index))
            (set! index (+ index 1)))))
      (let
        [comparison : i32
          (winsock-compare-string-ordinal
            (unsafe
              (ptr-cast (__tl_array-data module-path) : (Ptr u16)))
            (cast module-length : i32)
            (unsafe
              (ptr-cast (__tl_array-data system-path) : (Ptr u16)))
            (cast expected-length : i32)
            (cast 1 : i32))]
        (cond
          [(= comparison (cast 2 : i32)) (WinsockIdentityOk)]
          [(= comparison (cast 0 : i32)) (WinsockIdentityQueryFailed)]
          [else (WinsockIdentityWrongModule)])))))

;: Verify the *returned* module, not merely the LoadLibraryExW search flag.
;: A preloaded same-basename DLL can win before any filesystem search. Exact
;: ordinal comparison rejects ambiguous prefixes, alternate path spellings and
;: truncation instead of trying a permissive fallback.
(define (winsock-check-module-identity [module : u64]) : WinsockIdentityResult
  (let
    [capacity : i64 1024]
    [module-path : (Array u16 1024) (init : (Array u16 1024))]
    [system-path : (Array u16 1024) (init : (Array u16 1024))]
    [module-length : i64
      (cast
        (winsock-get-module-file-name-w
          module
          (unsafe
            (__tl_array-data module-path))
          (cast capacity : u32))
        : i64)]
    [system-length : i64
      (cast
        (winsock-get-system-directory-w
          (unsafe
            (__tl_array-data system-path))
          (cast capacity : u32))
        : i64)]
    (winsock-identity-from-paths
      module-path
      module-length
      system-path
      system-length)))

;: Independent schema-name oracle for the injected missing-slot checks.
(cfg
  test
  (define (winsock-test-schema-name [slot : i64]) : String
    (match slot
      [0 "WSAStartup"]
      [1 "WSACleanup"]
      [2 "WSAGetLastError"]
      [3 "WSASocketW"]
      [4 "closesocket"]
      [5 "ioctlsocket"]
      [6 "bind"]
      [7 "listen"]
      [8 "accept"]
      [9 "connect"]
      [10 "getsockname"]
      [11 "getpeername"]
      [12 "recv"]
      [13 "send"]
      [14 "recvfrom"]
      [15 "sendto"]
      [16 "shutdown"]
      [17 "getsockopt"]
      [18 "setsockopt"]
      [19 "select"]
      [20 "WSADuplicateSocketW"]
      [_ ""])))

;: A preloaded same-basename application DLL must fail the exact identity
;: comparison even when the secure-load search flag was requested. These
;: paths are injected into the same comparator used by the native query.
(cfg
  test
  (define (winsock-test-wide [name : (& name str)]) : (Array u16 1024)
    (let
      [out : (Array u16 1024) (init : (Array u16 1024))]
      [index : i64 0]
      (while (< index (string.string-length name))
        (begin
          (set!
            (array-ref out index)
            (cast (string.string-ref name index) : u16))
          (set! index (+ index 1))))
      out)))

(cfg
  test
  (define (winsock-test-shadow-path-rejected?) : bool
    (let
      [system : String "C:\\Windows\\System32"]
      [shadow : String "C:\\app\\Ws2_32.dll"]
      [real : String "c:\\WINDOWS\\system32\\WS2_32.DLL"]
      [system-path : (Array u16 1024) (winsock-test-wide (& system))]
      [shadow-path : (Array u16 1024) (winsock-test-wide (& shadow))]
      [real-path : (Array u16 1024) (winsock-test-wide (& real))]
      (and
        (match (winsock-identity-from-paths
          shadow-path
          (string.string-length (& shadow))
          system-path
          (string.string-length (& system)))
          [(WinsockIdentityWrongModule) true]
          [_ false])
        (match (winsock-identity-from-paths
          real-path
          (string.string-length (& real))
          system-path
          (string.string-length (& system)))
          [(WinsockIdentityOk) true]
          [_ false])
        (match (winsock-identity-from-paths
          real-path
          1024
          system-path
          (string.string-length (& system)))
          [(WinsockIdentityQueryFailed) true]
          [_ false])
        (match (winsock-identity-from-paths
          real-path
          -1
          system-path
          (string.string-length (& system)))
          [(WinsockIdentityQueryFailed) true]
          [_ false])))))

;: Resolve the fixed schema in order. A failed slot stops before the next lookup.
;: The injected index is -1 in production and is used only by bounded tests.
(unsafe
  (define (winsock-resolve-table [module : u64] [missing-at : i64]) : WinsockTableResult
    (let
      [startup : (CFunc unsafe-nullable (-> u16 (MutPtr WinsockWsaData) i32))
        (if (not (winsock-resolve-slot? 0 missing-at))
          (ptr-null
            : (CFunc unsafe-nullable (-> u16 (MutPtr WinsockWsaData) i32)))
          (winsock-lookup-startup module (ffi.cstr "WSAStartup")))]
      (when
        (ptr-null? startup)
        (return (WinsockTableErr (WinsockMissingExport "WSAStartup"))))
      (let
        [cleanup : (CFunc unsafe-nullable (-> i32))
          (if (not (winsock-resolve-slot? 1 missing-at))
            (ptr-null : (CFunc unsafe-nullable (-> i32)))
            (winsock-lookup-cleanup module (ffi.cstr "WSACleanup")))]
        (when
          (ptr-null? cleanup)
          (return (WinsockTableErr (WinsockMissingExport "WSACleanup"))))
        (let
          [last-error : (CFunc unsafe-nullable (-> i32))
            (if (not (winsock-resolve-slot? 2 missing-at))
              (ptr-null : (CFunc unsafe-nullable (-> i32)))
              (winsock-lookup-last-error module (ffi.cstr "WSAGetLastError")))]
          (when
            (ptr-null? last-error)
            (return (WinsockTableErr (WinsockMissingExport "WSAGetLastError"))))
          (let
            [socket : (CFunc
              unsafe-nullable
              (-> i32 i32 i32 (MutPtr WinsockProtocolInfoW) u32 u32 u64))
              (if (not (winsock-resolve-slot? 3 missing-at))
                (ptr-null
                  : (CFunc
                    unsafe-nullable
                    (-> i32 i32 i32 (MutPtr WinsockProtocolInfoW) u32 u32 u64)))
                (winsock-lookup-socket module (ffi.cstr "WSASocketW")))]
            (when
              (ptr-null? socket)
              (return (WinsockTableErr (WinsockMissingExport "WSASocketW"))))
            (let
              [close : (CFunc unsafe-nullable (-> u64 i32))
                (if (not (winsock-resolve-slot? 4 missing-at))
                  (ptr-null : (CFunc unsafe-nullable (-> u64 i32)))
                  (winsock-lookup-close module (ffi.cstr "closesocket")))]
              (when
                (ptr-null? close)
                (return (WinsockTableErr (WinsockMissingExport "closesocket"))))
              (let
                [ioctl : (CFunc unsafe-nullable (-> u64 i32 (MutPtr u32) i32))
                  (if (not (winsock-resolve-slot? 5 missing-at))
                    (ptr-null
                      : (CFunc unsafe-nullable (-> u64 i32 (MutPtr u32) i32)))
                    (winsock-lookup-ioctl module (ffi.cstr "ioctlsocket")))]
                (when
                  (ptr-null? ioctl)
                  (return
                    (WinsockTableErr (WinsockMissingExport "ioctlsocket"))))
                (let
                  [bind : (CFunc
                    unsafe-nullable
                    (-> u64 (Ptr WinsockSockAddr) i32 i32))
                    (if (not (winsock-resolve-slot? 6 missing-at))
                      (ptr-null
                        : (CFunc
                          unsafe-nullable
                          (-> u64 (Ptr WinsockSockAddr) i32 i32)))
                      (winsock-lookup-bind module (ffi.cstr "bind")))]
                  (when
                    (ptr-null? bind)
                    (return (WinsockTableErr (WinsockMissingExport "bind"))))
                  (let
                    [listen : (CFunc unsafe-nullable (-> u64 i32 i32))
                      (if (not (winsock-resolve-slot? 7 missing-at))
                        (ptr-null : (CFunc unsafe-nullable (-> u64 i32 i32)))
                        (winsock-lookup-listen module (ffi.cstr "listen")))]
                    (when
                      (ptr-null? listen)
                      (return (WinsockTableErr (WinsockMissingExport "listen"))))
                    (let
                      [accept : (CFunc
                        unsafe-nullable
                        (-> u64 (MutPtr WinsockSockAddr) (MutPtr i32) u64))
                        (if (not (winsock-resolve-slot? 8 missing-at))
                          (ptr-null
                            : (CFunc
                              unsafe-nullable
                              (-> u64 (MutPtr WinsockSockAddr) (MutPtr i32) u64)))
                          (winsock-lookup-accept module (ffi.cstr "accept")))]
                      (when
                        (ptr-null? accept)
                        (return
                          (WinsockTableErr (WinsockMissingExport "accept"))))
                      (let
                        [connect : (CFunc
                          unsafe-nullable
                          (-> u64 (Ptr WinsockSockAddr) i32 i32))
                          (if (not (winsock-resolve-slot? 9 missing-at))
                            (ptr-null
                              : (CFunc
                                unsafe-nullable
                                (-> u64 (Ptr WinsockSockAddr) i32 i32)))
                            (winsock-lookup-connect module (ffi.cstr "connect")))]
                        (when
                          (ptr-null? connect)
                          (return
                            (WinsockTableErr (WinsockMissingExport "connect"))))
                        (let
                          [local-name : (CFunc
                            unsafe-nullable
                            (-> u64 (MutPtr WinsockSockAddr) (MutPtr i32) i32))
                            (if (not (winsock-resolve-slot? 10 missing-at))
                              (ptr-null
                                : (CFunc
                                  unsafe-nullable
                                  (->
                                    u64
                                    (MutPtr WinsockSockAddr)
                                    (MutPtr i32)
                                    i32)))
                              (winsock-lookup-local-name
                                module
                                (ffi.cstr "getsockname")))]
                          (when
                            (ptr-null? local-name)
                            (return
                              (WinsockTableErr
                                (WinsockMissingExport "getsockname"))))
                          (let
                            [peer-name : (CFunc
                              unsafe-nullable
                              (-> u64 (MutPtr WinsockSockAddr) (MutPtr i32) i32))
                              (if (not (winsock-resolve-slot? 11 missing-at))
                                (ptr-null
                                  : (CFunc
                                    unsafe-nullable
                                    (->
                                      u64
                                      (MutPtr WinsockSockAddr)
                                      (MutPtr i32)
                                      i32)))
                                (winsock-lookup-peer-name
                                  module
                                  (ffi.cstr "getpeername")))]
                            (when
                              (ptr-null? peer-name)
                              (return
                                (WinsockTableErr
                                  (WinsockMissingExport "getpeername"))))
                            (let
                              [receive : (CFunc
                                unsafe-nullable
                                (-> u64 (MutPtr u8) i32 i32 i32))
                                (if (not (winsock-resolve-slot? 12 missing-at))
                                  (ptr-null
                                    : (CFunc
                                      unsafe-nullable
                                      (-> u64 (MutPtr u8) i32 i32 i32)))
                                  (winsock-lookup-receive
                                    module
                                    (ffi.cstr "recv")))]
                              (when
                                (ptr-null? receive)
                                (return
                                  (WinsockTableErr
                                    (WinsockMissingExport "recv"))))
                              (let
                                [send : (CFunc
                                  unsafe-nullable
                                  (-> u64 (Ptr u8) i32 i32 i32))
                                  (if (not
                                    (winsock-resolve-slot? 13 missing-at))
                                    (ptr-null
                                      : (CFunc
                                        unsafe-nullable
                                        (-> u64 (Ptr u8) i32 i32 i32)))
                                    (winsock-lookup-send
                                      module
                                      (ffi.cstr "send")))]
                                (when
                                  (ptr-null? send)
                                  (return
                                    (WinsockTableErr
                                      (WinsockMissingExport "send"))))
                                (let
                                  [receive-from : (CFunc
                                    unsafe-nullable
                                    (->
                                      u64
                                      (MutPtr u8)
                                      i32
                                      i32
                                      (MutPtr WinsockSockAddr)
                                      (MutPtr i32)
                                      i32))
                                    (if (not
                                      (winsock-resolve-slot? 14 missing-at))
                                      (ptr-null
                                        : (CFunc
                                          unsafe-nullable
                                          (->
                                            u64
                                            (MutPtr u8)
                                            i32
                                            i32
                                            (MutPtr WinsockSockAddr)
                                            (MutPtr i32)
                                            i32)))
                                      (winsock-lookup-receive-from
                                        module
                                        (ffi.cstr "recvfrom")))]
                                  (when
                                    (ptr-null? receive-from)
                                    (return
                                      (WinsockTableErr
                                        (WinsockMissingExport "recvfrom"))))
                                  (let
                                    [send-to : (CFunc
                                      unsafe-nullable
                                      (->
                                        u64
                                        (Ptr u8)
                                        i32
                                        i32
                                        (Ptr WinsockSockAddr)
                                        i32
                                        i32))
                                      (if (not
                                        (winsock-resolve-slot? 15 missing-at))
                                        (ptr-null
                                          : (CFunc
                                            unsafe-nullable
                                            (->
                                              u64
                                              (Ptr u8)
                                              i32
                                              i32
                                              (Ptr WinsockSockAddr)
                                              i32
                                              i32)))
                                        (winsock-lookup-send-to
                                          module
                                          (ffi.cstr "sendto")))]
                                    (when
                                      (ptr-null? send-to)
                                      (return
                                        (WinsockTableErr
                                          (WinsockMissingExport "sendto"))))
                                    (let
                                      [shutdown : (CFunc
                                        unsafe-nullable
                                        (-> u64 i32 i32))
                                        (if (not
                                          (winsock-resolve-slot? 16 missing-at))
                                          (ptr-null
                                            : (CFunc
                                              unsafe-nullable
                                              (-> u64 i32 i32)))
                                          (winsock-lookup-shutdown
                                            module
                                            (ffi.cstr "shutdown")))]
                                      (when
                                        (ptr-null? shutdown)
                                        (return
                                          (WinsockTableErr
                                            (WinsockMissingExport "shutdown"))))
                                      (let
                                        [get-option : (CFunc
                                          unsafe-nullable
                                          (->
                                            u64
                                            i32
                                            i32
                                            (MutPtr u8)
                                            (MutPtr i32)
                                            i32))
                                          (if (not
                                            (winsock-resolve-slot?
                                              17
                                              missing-at))
                                            (ptr-null
                                              : (CFunc
                                                unsafe-nullable
                                                (->
                                                  u64
                                                  i32
                                                  i32
                                                  (MutPtr u8)
                                                  (MutPtr i32)
                                                  i32)))
                                            (winsock-lookup-get-option
                                              module
                                              (ffi.cstr "getsockopt")))]
                                        (when
                                          (ptr-null? get-option)
                                          (return
                                            (WinsockTableErr
                                              (WinsockMissingExport
                                                "getsockopt"))))
                                        (let
                                          [set-option : (CFunc
                                            unsafe-nullable
                                            (-> u64 i32 i32 (Ptr u8) i32 i32))
                                            (if (not
                                              (winsock-resolve-slot?
                                                18
                                                missing-at))
                                              (ptr-null
                                                : (CFunc
                                                  unsafe-nullable
                                                  (->
                                                    u64
                                                    i32
                                                    i32
                                                    (Ptr u8)
                                                    i32
                                                    i32)))
                                              (winsock-lookup-set-option
                                                module
                                                (ffi.cstr "setsockopt")))]
                                          (when
                                            (ptr-null? set-option)
                                            (return
                                              (WinsockTableErr
                                                (WinsockMissingExport
                                                  "setsockopt"))))
                                          (let
                                            [select : (CFunc
                                              unsafe-nullable
                                              (->
                                                i32
                                                (MutPtr WinsockFdSet)
                                                (MutPtr WinsockFdSet)
                                                (MutPtr WinsockFdSet)
                                                (Ptr WinsockTimeval)
                                                i32))
                                              (if (not
                                                (winsock-resolve-slot?
                                                  19
                                                  missing-at))
                                                (ptr-null
                                                  : (CFunc
                                                    unsafe-nullable
                                                    (->
                                                      i32
                                                      (MutPtr WinsockFdSet)
                                                      (MutPtr WinsockFdSet)
                                                      (MutPtr WinsockFdSet)
                                                      (Ptr WinsockTimeval)
                                                      i32)))
                                                (winsock-lookup-select
                                                  module
                                                  (ffi.cstr "select")))]
                                            (when
                                              (ptr-null? select)
                                              (return
                                                (WinsockTableErr
                                                  (WinsockMissingExport
                                                    "select"))))
                                            (let
                                              [duplicate-socket : (CFunc
                                                unsafe-nullable
                                                (->
                                                  u64
                                                  u32
                                                  (MutPtr WinsockProtocolInfoW)
                                                  i32))
                                                (if (not
                                                  (winsock-resolve-slot?
                                                    20
                                                    missing-at))
                                                  (ptr-null
                                                    : (CFunc
                                                      unsafe-nullable
                                                      (->
                                                        u64
                                                        u32
                                                        (MutPtr
                                                          WinsockProtocolInfoW)
                                                        i32)))
                                                  (winsock-lookup-duplicate-socket
                                                    module
                                                    (ffi.cstr
                                                      "WSADuplicateSocketW")))]
                                              (when
                                                (ptr-null? duplicate-socket)
                                                (return
                                                  (WinsockTableErr
                                                    (WinsockMissingExport
                                                      "WSADuplicateSocketW"))))
                                              (WinsockTableOk
                                                (WinsockTable
                                                  module
                                                  (c-fn-check startup)
                                                  (c-fn-check cleanup)
                                                  (c-fn-check last-error)
                                                  (c-fn-check socket)
                                                  (c-fn-check close)
                                                  (c-fn-check ioctl)
                                                  (c-fn-check bind)
                                                  (c-fn-check listen)
                                                  (c-fn-check accept)
                                                  (c-fn-check connect)
                                                  (c-fn-check local-name)
                                                  (c-fn-check peer-name)
                                                  (c-fn-check receive)
                                                  (c-fn-check send)
                                                  (c-fn-check receive-from)
                                                  (c-fn-check send-to)
                                                  (c-fn-check shutdown)
                                                  (c-fn-check get-option)
                                                  (c-fn-check set-option)
                                                  (c-fn-check select)
                                                  (c-fn-check duplicate-socket))))))))))))))))))))))))))

;: The table's 22 raw words have process lifetime behind an unsafe pointer.
;: A public fixed-array global would let safe importers overwrite elements;
;: only the checked unsafe accessors below read or write the words. Like every
;: module global, the bindings here stay assignable by an importer's `set!`
;: (SPEC 4.4.2, #7976); this storage guards the words, not the bindings.
(define winsock-table-words : (MutPtr u64)
  (let
    [storage : (__tl_dyn-array u64) (__tl_make-array u64 22)]
    (unsafe
      (__tl_array-data storage))))

;: 0 uninitialized, 1 initializing, 2 ready. The winner writes every word
;: before storing ready. A failed candidate resets to 0 after its sole release.
(define winsock-publication-state : i64
  0)

;: Read a fully published table. Callers must first observe state 2.
(unsafe
  (define (winsock-read-published-table) : WinsockTable
    (unsafe
      (ptr-read (ptr-cast winsock-table-words : (Ptr WinsockTable))))))

;: Write all fields before the ready transition makes them observable.
(unsafe
  (define (winsock-write-published-table! [table : WinsockTable]) : unit
    (unsafe
      (ptr-write! (ptr-cast winsock-table-words : (MutPtr WinsockTable)) table))))

;: Load exactly one DLL through the System32-only search and validate its
;: actual identity before resolving any export. Fault inputs are -1 in normal
;: operation and provide deterministic unpublished-candidate test seams.
(unsafe
  (define (winsock-build-candidate
    [missing-at : i64]
    [identity-fault : i64]
    [load-fault : bool]) : WinsockTableResult
    (when load-fault (return (WinsockTableErr (WinsockLoadUnavailable 1))))
    (let
      [dll-name : (Array u16 11) (winsock-dll-wide-name)]
      [module : u64
        (winsock-load-system32
          (unsafe
            (ptr-cast (__tl_array-data dll-name) : (Ptr u16))))]
      (when
        (= module (cast 0 : u64))
        (return
          (WinsockTableErr (WinsockLoadUnavailable (winsock-get-last-error)))))
      (let
        [identity : WinsockIdentityResult
          (cond
            [(= identity-fault 1) (WinsockIdentityQueryFailed)]
            [(= identity-fault 2) (WinsockIdentityWrongModule)]
            [else (winsock-check-module-identity module)])]
        (match identity
          [(WinsockIdentityQueryFailed)
            (begin
              (winsock-release-candidate module)
              (return (WinsockTableErr (WinsockIdentityUnavailable))))]
          [(WinsockIdentityWrongModule)
            (begin
              (winsock-release-candidate module)
              (return (WinsockTableErr (WinsockIdentityMismatch))))]
          [(WinsockIdentityOk) unit])
        (when
          (or (= identity-fault 3) (not (winsock-abi-layout-ok?)))
          (begin
            (winsock-release-candidate module)
            (return (WinsockTableErr (WinsockAbiLayoutMismatch)))))
        (match (unsafe
          (winsock-resolve-table module missing-at))
          [(WinsockTableErr error)
            (begin
              (winsock-release-candidate module)
              (WinsockTableErr error))]
          [(WinsockTableOk table) (WinsockTableOk table)])))))

;: Serialize first use. Contenders wait for the winner's complete table, or
;: retry after a failed candidate returns the state to uninitialized.
(unsafe
  (define (winsock-ensure-table-with
    [missing-at : i64]
    [identity-fault : i64]
    [load-fault : bool]) : WinsockTableResult
    (while true
      (let
        [state : i64
          (unsafe
            (atomic-load (ptr-addr-of winsock-publication-state)))]
        (cond
          [(= state 2)
            (return
              (WinsockTableOk
                (unsafe
                  (winsock-read-published-table))))]
          [(= state 0)
            (when
              (=
                (unsafe
                  (atomic-cas! (ptr-addr-of winsock-publication-state) 0 1))
                0)
              (match (unsafe
                (winsock-build-candidate missing-at identity-fault load-fault))
                [(WinsockTableErr error)
                  (begin
                    (unsafe
                      (atomic-store! (ptr-addr-of winsock-publication-state) 0))
                    (return (WinsockTableErr error)))]
                [(WinsockTableOk table)
                  (begin
                    (unsafe
                      (winsock-write-published-table! table))
                    (unsafe
                      (atomic-store! (ptr-addr-of winsock-publication-state) 2))
                    (return (WinsockTableOk table)))]))]
          [else unit])))
    (WinsockTableErr (WinsockIdentityUnavailable))))

;: Normal first use never injects a failed slot or host condition.
(unsafe
  (define (winsock-ensure-table) : WinsockTableResult
    (unsafe
      (winsock-ensure-table-with -1 -1 false))))

;: Box address, not its caller-mutable scalar, is the issued lease identity.
;: The cleanup hook revokes the address and balances one successful startup.
(defstruct WinsockLease
  (:cleanup cleanup-winsock-lease)
  (token (Box i64) (:cleanup winsock-token-cleanup)))

;: Acquisition transfers one cleanup-owning lease only after successful startup.
(defenum WinsockAcquireResult
  (:cleanup cleanup-winsock-acquire-result)
  (WinsockAcquired WinsockLease (:owned))
  (WinsockAcquireErr WinsockError))

;: A bounded address registry makes a source-constructed WinsockLease inert.
;: The backing array is process-lifetime runtime storage; unsafe pointer
;: access prevents safe callers from manufacturing an issued address. At most
;: `winsock-lease-capacity` leases are live process-wide; past that,
;: acquisition balances its startup and fails with WinsockLeaseCapacityExceeded.
;: A function rather than a global: it bounds raw registry indices, and a
;: module global stays assignable by importers (#7976).
(define (winsock-lease-capacity) : i64
  4096)

;: Issued Box addresses remain in process-lifetime raw storage.
(define winsock-lease-addresses : (MutPtr u64)
  (let
    [storage : (__tl_dyn-array u64)
      (__tl_make-array u64 (winsock-lease-capacity))]
    (unsafe
      (__tl_array-data storage))))

;: Serialize registry insertion, validation, and revocation.
(define winsock-lease-lock : i64
  0)

;: Next registry probe position for bounded insertion.
(define winsock-lease-next : i64
  0)

(unsafe
  (define (winsock-lease-slot-ref [slot : i64]) : u64
    (unsafe
      (ptr-read
        (ptr-cast (ptr-offset winsock-lease-addresses slot) : (Ptr u64))))))

(unsafe
  (define (winsock-lease-slot-set! [slot : i64] [address : u64]) : unit
    (unsafe
      (ptr-write! (ptr-offset winsock-lease-addresses slot) address))))

(unsafe
  (define (winsock-lock-leases!) : unit
    (while (!=
      (unsafe
        (atomic-cas! (ptr-addr-of winsock-lease-lock) 0 1))
      0)
      unit)))

(unsafe
  (define (winsock-unlock-leases!) : unit
    (unsafe
      (atomic-store! (ptr-addr-of winsock-lease-lock) 0))))

;: The Box value is a one-based slot hint; its backing address is authority.
(defstruct WinsockBoxIdentity
  (box (Box i64))
  (address u64)
  (hint i64))

;: Read the owned Box address and its mutable slot hint together.
(define (winsock-owned-box-identity [box : (Box i64)]) : WinsockBoxIdentity
  (let
    [address : u64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of box) : (Ptr u64))))]
    [hint : i64 (deref box)]
    (WinsockBoxIdentity box address hint)))

;: A borrowed lease's Box address is read without moving the owner.
(define (winsock-lease-address [lease : (& lease WinsockLease)]) : u64
  (let
    [record-address : u64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of lease) : (Ptr u64))))]
    (unsafe
      (ptr-read (int->ptr record-address : (Ptr u64))))))

;: Claim one free slot under the lock. -1 means no startup can be leased.
(unsafe
  (define (winsock-register-lease-address [address : u64]) : i64
    (when (= address (cast 0 : u64)) (return -1))
    (unsafe
      (winsock-lock-leases!))
    (let
      [probe : i64 0]
      [slot : i64 -1]
      ;; The cursor is only a hint, and module globals stay assignable by
      ;; importers (#7976): bound it here so no value becomes a raw index.
      [start : i64
        (if (and
          (>= winsock-lease-next 0)
          (< winsock-lease-next (winsock-lease-capacity)))
          winsock-lease-next
          0)]
      (while (and (< probe (winsock-lease-capacity)) (< slot 0))
        (let
          [index : i64 (% (+ start probe) (winsock-lease-capacity))]
          (if (=
            (unsafe
              (winsock-lease-slot-ref index))
            (cast 0 : u64))
            (set! slot index)
            unit)
          (set! probe (+ probe 1))))
      (when
        (>= slot 0)
        (begin
          (unsafe
            (winsock-lease-slot-set! slot address))
          (set! winsock-lease-next (% (+ slot 1) (winsock-lease-capacity)))))
      (unsafe
        (winsock-unlock-leases!))
      slot)))

;: The borrowed fast path requires both the hint and the issued Box address.
(unsafe
  (define (winsock-live-lease? [lease : (& lease WinsockLease)]) : bool
    (let
      [hint : i64 (deref lease.token)]
      [address : u64 (winsock-lease-address lease)]
      [live : bool false]
      (when
        (or
          (<= hint 0)
          (> hint (winsock-lease-capacity))
          (= address (cast 0 : u64)))
        (return false))
      (unsafe
        (winsock-lock-leases!))
      (set!
        live
        (=
          (unsafe
            (winsock-lease-slot-ref (- hint 1)))
          address))
      (unsafe
        (winsock-unlock-leases!))
      live)))

;: A mutated hint cannot suppress cleanup: scan by issued address if needed.
(unsafe
  (define (winsock-revoke-lease-address [hint : i64] [address : u64]) : bool
    (when (= address (cast 0 : u64)) (return false))
    (unsafe
      (winsock-lock-leases!))
    (let
      [slot : i64 -1]
      (when
        (and (> hint 0) (<= hint (winsock-lease-capacity)))
        (when
          (=
            (unsafe
              (winsock-lease-slot-ref (- hint 1)))
            address)
          (set! slot (- hint 1))))
      (when
        (< slot 0)
        (let
          [index : i64 0]
          (while (and (< index (winsock-lease-capacity)) (< slot 0))
            (begin
              (when
                (=
                  (unsafe
                    (winsock-lease-slot-ref index))
                  address)
                (set! slot index))
              (set! index (+ index 1))))))
      (when
        (>= slot 0)
        (unsafe
          (winsock-lease-slot-set! slot (cast 0 : u64))))
      (unsafe
        (winsock-unlock-leases!))
      (>= slot 0))))

;: Generated cleanup of WinsockLease calls this exactly once for its Box.
(define (winsock-token-cleanup [token-box : (Box i64)]) : unit
  (let
    [identity : WinsockBoxIdentity (winsock-owned-box-identity token-box)]
    [issued : bool
      (unsafe
        (winsock-revoke-lease-address identity.hint identity.address))]
    (when
      issued
      (match (unsafe
        (winsock-ensure-table))
        [(WinsockTableOk table)
          (begin
            (unsafe
              (winsock-call-cleanup table))
            unit)]
        [(WinsockTableErr _) unit]))))

;: Only a checked live lease grants a copy of the immutable function table.
;: Calls through the table still require explicit unsafe at each native edge.
(unsafe
  (define (winsock-table-for-lease [lease : (& lease WinsockLease)]) : WinsockTableResult
    (if (unsafe
      (winsock-live-lease? lease))
      (WinsockTableOk
        (unsafe
          (winsock-read-published-table)))
      (WinsockTableErr (WinsockLeaseInvalid)))))

;: Run one version-checked startup and install its move-only cleanup lease.
;: Fault 1 injects a host failure before the call; fault 2 changes only the
;: returned version after a real successful startup, so cleanup is exercised.
(unsafe
  (define (winsock-acquire-with-fault [fault : i64]) : WinsockAcquireResult
    (match (unsafe
      (winsock-ensure-table))
      [(WinsockTableErr error) (WinsockAcquireErr error)]
      [(WinsockTableOk table)
        (let
          [data : WinsockWsaData
            (WinsockWsaData
              (cast 0 : u16)
              (cast 0 : u16)
              (cast 0 : u16)
              (cast 0 : u16)
              (ptr-null : (Ptr u8))
              (init : (Array u8 257))
              (init : (Array u8 129)))]
          [status : i32
            (if (= fault 1)
              (cast 10093 : i32)
              (unsafe
                (winsock-call-startup
                  table
                  (unsafe
                    (ptr-addr-of data)))))]
          (when
            (!= status (cast 0 : i32))
            (return (WinsockAcquireErr (WinsockStartupFailed status))))
          (when (= fault 2) (set! data.version (cast 257 : u16)))
          (when
            (!= data.version winsock-version-2-2)
            (begin
              (unsafe
                (winsock-call-cleanup table))
              (return (WinsockAcquireErr (WinsockVersionMismatch data.version)))))
          (let
            [token : (Box i64) (box 0)]
            [identity : WinsockBoxIdentity (winsock-owned-box-identity token)]
            [slot : i64
              (unsafe
                (winsock-register-lease-address identity.address))]
            (if (< slot 0)
              (begin
                (unsafe
                  (winsock-call-cleanup table))
                (WinsockAcquireErr (WinsockLeaseCapacityExceeded)))
              (begin
                (set! (deref identity.box) (+ slot 1))
                (WinsockAcquired (WinsockLease identity.box))))))])))

;: Checked construction entry for the later socket adapter. Other targets
;: return a structured unsupported-host error without importing Win32 symbols.
(cfg
  windows
  (define (winsock-acquire) : WinsockAcquireResult
    (unsafe
      (winsock-acquire-with-fault 0))))

(cfg
  (not windows)
  (define (winsock-acquire) : WinsockAcquireResult
    (WinsockAcquireErr (WinsockUnsupportedTarget))))

;: #7379 first acquires one fresh lease for the new owner, then constructs
;: under that live lease. The caller owns the returned raw SOCKET and must
;: close it before releasing the lease. No socket is published here.
(unsafe
  (define (winsock-create-socket-with-lease
    [lease : (& lease WinsockLease)]
    [family : i32]
    [kind : i32]
    [protocol : i32]
    [protocol-info : (MutPtr WinsockProtocolInfoW)]
    [group : u32]
    [flags : u32]) : WinsockSocketResult
    (match (unsafe
      (winsock-table-for-lease lease))
      [(WinsockTableErr error) (WinsockSocketErr error)]
      [(WinsockTableOk table)
        (let
          [socket : u64
            (unsafe
              (table.socket family kind protocol protocol-info group flags))]
          (if (= socket winsock-invalid-socket)
            (WinsockSocketErr
              (WinsockSocketCallFailed
                (unsafe
                  (table.last-error))))
            (WinsockSocketOk socket)))])))

;: Same-process duplication obtains a one-use protocol record while the
;: source is live. #7379 acquires a separate lease for the new owner before
;: calling winsock-create-socket-with-lease with this record.
(unsafe
  (define (winsock-duplicate-protocol-with-lease
    [lease : (& lease WinsockLease)]
    [source : u64]
    [process-id : u32]
    [protocol-info : (MutPtr WinsockProtocolInfoW)]) : WinsockDuplicateResult
    (match (unsafe
      (winsock-table-for-lease lease))
      [(WinsockTableErr error) (WinsockDuplicateErr error)]
      [(WinsockTableOk table)
        (if (=
          (unsafe
            (table.duplicate-socket source process-id protocol-info))
          (cast 0 : i32))
          (WinsockDuplicateOk)
          (WinsockDuplicateErr
            (WinsockDuplicateCallFailed
              (unsafe
                (table.last-error)))))])))

;: Test every failure position before the first publication. Each failed
;: candidate has one load and one release, and its missing slot is last.
(cfg
  test
  (define (winsock-test-unpublished-failures?) : bool
    (when
      (!=
        (unsafe
          (atomic-load (ptr-addr-of winsock-publication-state)))
        0)
      (return false))
    (winsock-test-reset-counters!)
    (match (unsafe
      (winsock-ensure-table-with -1 -1 true))
      [(WinsockTableErr (WinsockLoadUnavailable code))
        (when (!= code (cast 1 : u32)) (return false))]
      [_ (return false)])
    (when (not (winsock-test-counters-match? 0 0 0 0 0)) (return false))
    (winsock-test-reset-counters!)
    (match (unsafe
      (winsock-ensure-table-with -1 1 false))
      [(WinsockTableErr (WinsockIdentityUnavailable)) unit]
      [_ (return false)])
    (when (not (winsock-test-counters-match? 1 0 1 0 0)) (return false))
    (when
      (!=
        (unsafe
          (atomic-load (ptr-addr-of winsock-publication-state)))
        0)
      (return false))
    (winsock-test-reset-counters!)
    (match (unsafe
      (winsock-ensure-table-with -1 2 false))
      [(WinsockTableErr (WinsockIdentityMismatch)) unit]
      [_ (return false)])
    (when (not (winsock-test-counters-match? 1 0 1 0 0)) (return false))
    (winsock-test-reset-counters!)
    (match (unsafe
      (winsock-ensure-table-with -1 3 false))
      [(WinsockTableErr (WinsockAbiLayoutMismatch)) unit]
      [_ (return false)])
    (when (not (winsock-test-counters-match? 1 0 1 0 0)) (return false))
    (let
      [slot : i64 0]
      (while (< slot 21)
        (begin
          (winsock-test-reset-counters!)
          (match (unsafe
            (winsock-ensure-table-with slot -1 false))
            [(WinsockTableErr (WinsockMissingExport name))
              (let
                [expected : String (winsock-test-schema-name slot)]
                (when (not (string.eq (& name) (& expected))) (return false)))]
            [_ (return false)])
          (when
            (not (winsock-test-counters-match? 1 slot 1 0 0))
            (return false))
          (when
            (!=
              (unsafe
                (atomic-load (ptr-addr-of winsock-publication-state)))
              0)
            (return false))
          (set! slot (+ slot 1)))))
    true))

;: Published pointer access rejects a source-constructed Box authority.
(cfg
  test
  (define (winsock-test-forged-lease-rejected?) : bool
    (with
      ([owned (WinsockLease (box 1)) cleanup-winsock-lease])
      (match (unsafe
        (winsock-table-for-lease (& owned)))
        [(WinsockTableErr (WinsockLeaseInvalid)) true]
        [_ false]))))

(cfg
  test
  (define winsock-test-wave-arrived : i64
    0))
(cfg
  test
  (define winsock-test-wave-go : i64
    0))

;: Inspect every published word, not just the module handle, under contention.
(cfg
  test
  (define (winsock-test-table-complete? [table : WinsockTable]) : bool
    (let
      [words : (Ptr u64)
        (unsafe
          (ptr-cast (ptr-addr-of table) : (Ptr u64)))]
      [index : i64 0]
      (while (< index 22)
        (begin
          (when
            (=
              (unsafe
                (ptr-read (ptr-offset words index)))
              (cast 0 : u64))
            (return false))
          (set! index (+ index 1))))
      true)))

;: Hold every worker at a barrier so first publication has real contention.
(cfg
  test
  (define (winsock-test-worker [_context : i64]) : i64
    (unsafe
      (atomic-add! (ptr-addr-of winsock-test-wave-arrived) 1))
    (while (=
      (unsafe
        (atomic-load (ptr-addr-of winsock-test-wave-go)))
      0)
      (begin
        (time.sleep-ms 1)
        unit))
    (match (winsock-acquire)
      [(WinsockAcquireErr _) 0]
      [(WinsockAcquired lease)
        (with
          ([owned lease cleanup-winsock-lease])
          (match (unsafe
            (winsock-table-for-lease (& owned)))
            [(WinsockTableErr _) 0]
            [(WinsockTableOk table)
              (if (winsock-test-table-complete? table)
                1
                0)]))])))

;: The same barrier, but every candidate misses the last schema slot. Each
;: worker must see its own stable tag after exactly one attempt of its own.
(cfg
  test
  (define (winsock-test-failing-worker [_context : i64]) : i64
    (unsafe
      (atomic-add! (ptr-addr-of winsock-test-wave-arrived) 1))
    (while (=
      (unsafe
        (atomic-load (ptr-addr-of winsock-test-wave-go)))
      0)
      (begin
        (time.sleep-ms 1)
        unit))
    (match (unsafe
      (winsock-ensure-table-with 20 -1 false))
      [(WinsockTableErr (WinsockMissingExport name))
        (let
          [expected : String (winsock-test-schema-name 20)]
          (if (string.eq (& name) (& expected))
            1
            0))]
      [_ 0])))

;: Recursive ownership joins every spawned thread on the way back out.
(cfg
  test
  (define (winsock-test-spawn-wave
    [remaining : i64]
    [total : i64]
    [failing : bool]) : bool
    (if (= remaining 0)
      (let
        [attempts : i64 0]
        (while (and
          (< attempts 5000)
          (<
            (unsafe
              (atomic-load (ptr-addr-of winsock-test-wave-arrived)))
            total))
          (begin
            (time.sleep-ms 1)
            (set! attempts (+ attempts 1))))
        (let
          [all-arrived : bool
            (=
              (unsafe
                (atomic-load (ptr-addr-of winsock-test-wave-arrived)))
              total)]
          (begin
            (unsafe
              (atomic-store! (ptr-addr-of winsock-test-wave-go) 1))
            all-arrived)))
      (match (if failing
        (unsafe
          (thread.spawn winsock-test-failing-worker 0))
        (unsafe
          (thread.spawn winsock-test-worker 0)))
        [(thread.ThreadSpawnErr _)
          (begin
            (unsafe
              (atomic-store! (ptr-addr-of winsock-test-wave-go) 1))
            false)]
        [(thread.ThreadSpawnOk worker)
          (let
            [later-ok : bool
              (winsock-test-spawn-wave (- remaining 1) total failing)]
            (match (unsafe
              (thread.join worker))
              [(thread.ThreadJoinErr _) false]
              [(thread.ThreadJoinOk code) (and later-ok (= code 1))]))]))))

(cfg
  test
  (define (winsock-test-run-wave
    [expected-loads : i64]
    [expected-resolves : i64]) : bool
    (winsock-test-reset-counters!)
    (unsafe
      (atomic-store! (ptr-addr-of winsock-test-wave-arrived) 0))
    (unsafe
      (atomic-store! (ptr-addr-of winsock-test-wave-go) 0))
    (let
      [joined-ok : bool (winsock-test-spawn-wave 16 16 false)]
      (and
        joined-ok
        (=
          (unsafe
            (atomic-load (ptr-addr-of winsock-publication-state)))
          2)
        (winsock-test-counters-match? expected-loads expected-resolves 0 16 16)))))

;: A candidate that fails while other threads wait in `initializing` resets
;: to uninitialized; each waiter retries, fails with the same tag, and releases
;: its own candidate once. Nothing is published and no thread stays spinning.
(cfg
  test
  (define (winsock-test-failing-publication-wave?) : bool
    (winsock-test-reset-counters!)
    (unsafe
      (atomic-store! (ptr-addr-of winsock-test-wave-arrived) 0))
    (unsafe
      (atomic-store! (ptr-addr-of winsock-test-wave-go) 0))
    (let
      [joined-ok : bool (winsock-test-spawn-wave 16 16 true)]
      (and
        joined-ok
        (=
          (unsafe
            (atomic-load (ptr-addr-of winsock-publication-state)))
          0)
        (winsock-test-counters-match? 16 (* 16 20) 16 0 0)))))

(cfg
  test
  (define (winsock-test-publication-stress?) : bool
    (and (winsock-test-run-wave 1 21) (winsock-test-run-wave 0 0))))

;: A successful wrong-version startup is balanced before returning an error.
;: Fake authorities and a changed slot hint cannot steal or skip cleanup.
(cfg
  test
  (define (winsock-test-startup-balance?) : bool
    (winsock-test-reset-counters!)
    (match (unsafe
      (winsock-acquire-with-fault 1))
      [(WinsockAcquireErr (WinsockStartupFailed code))
        (when (!= code (cast 10093 : i32)) (return false))]
      [(WinsockAcquired lease)
        (with ([owned lease cleanup-winsock-lease]) (return false))]
      [_ (return false)])
    (when (not (winsock-test-counters-match? 0 0 0 0 0)) (return false))
    (match (unsafe
      (winsock-acquire-with-fault 2))
      [(WinsockAcquireErr (WinsockVersionMismatch version))
        (when (!= version (cast 257 : u16)) (return false))]
      [(WinsockAcquired lease)
        (with ([owned lease cleanup-winsock-lease]) (return false))]
      [_ (return false)])
    (when (not (winsock-test-counters-match? 0 0 0 1 1)) (return false))
    (match (winsock-acquire)
      [(WinsockAcquireErr _) false]
      [(WinsockAcquired lease)
        (begin
          (with
            ([owned lease cleanup-winsock-lease])
            (let
              [hint : i64 (deref owned.token)]
              (with
                ([forged (WinsockLease (box hint)) cleanup-winsock-lease])
                (match (unsafe
                  (winsock-table-for-lease (& forged)))
                  [(WinsockTableErr (WinsockLeaseInvalid)) unit]
                  [_ (return false)]))
              (match (unsafe
                (winsock-table-for-lease (& owned)))
                [(WinsockTableErr _) (return false)]
                [(WinsockTableOk _) unit])
              (set! (deref owned.token) 0)
              (match (unsafe
                (winsock-table-for-lease (& owned)))
                [(WinsockTableErr (WinsockLeaseInvalid)) unit]
                [_ (return false)])))
          (when (not (winsock-test-counters-match? 0 0 0 2 2)) (return false))
          (match (winsock-acquire)
            [(WinsockAcquireErr _) false]
            [(WinsockAcquired second)
              (begin
                (with ([owned second cleanup-winsock-lease]) unit)
                (winsock-test-counters-match? 0 0 0 3 3))]))])))

;: Exercise both construction paths with independent leases and close both
;: raw descriptors before either startup authorization is released.
(cfg
  test
  (define (winsock-test-duplicate-owner?
    [source-owner : (& lease WinsockLease)]
    [source : u64]) : bool
    (let
      [info : WinsockProtocolInfoW
        (WinsockProtocolInfoW (init : (Array u32 157)))]
      (match (unsafe
        (winsock-duplicate-protocol-with-lease
          source-owner
          source
          (winsock-current-process-id)
          (unsafe
            (ptr-addr-of info))))
        [(WinsockDuplicateErr _) false]
        [(WinsockDuplicateOk)
          (match (winsock-acquire)
            [(WinsockAcquireErr _) false]
            [(WinsockAcquired second-lease)
              (with
                ([second-owner second-lease cleanup-winsock-lease])
                (match (unsafe
                  (winsock-table-for-lease (& second-owner)))
                  [(WinsockTableErr _) false]
                  [(WinsockTableOk second-table)
                    (match (unsafe
                      (winsock-create-socket-with-lease
                        (& second-owner)
                        -1
                        -1
                        -1
                        (unsafe
                          (ptr-addr-of info))
                        (cast 0 : u32)
                        (cast 0 : u32)))
                      [(WinsockSocketErr _) false]
                      [(WinsockSocketOk duplicate)
                        (=
                          (unsafe
                            (second-table.close duplicate))
                          0)])]))])]))))

;: WSASocketW's INVALID_SOCKET crosses the native boundary as u64 all-ones:
;: an unsupported address family must take the error path with its code.
(cfg
  test
  (define (winsock-test-invalid-socket-round-trip?) : bool
    (match (winsock-acquire)
      [(WinsockAcquireErr _) false]
      [(WinsockAcquired lease)
        (with
          ([owned lease cleanup-winsock-lease])
          (match (unsafe
            (winsock-create-socket-with-lease
              (& owned)
              12345
              1
              0
              (ptr-null : (MutPtr WinsockProtocolInfoW))
              (cast 0 : u32)
              (cast 0 : u32)))
            [(WinsockSocketErr (WinsockSocketCallFailed code))
              (!= code (cast 0 : i32))]
            [(WinsockSocketErr _) false]
            [(WinsockSocketOk socket)
              (begin
                (match (unsafe
                  (winsock-table-for-lease (& owned)))
                  [(WinsockTableOk table)
                    (begin
                      (unsafe
                        (table.close socket))
                      unit)]
                  [(WinsockTableErr _) unit])
                false)]))])))

(cfg
  test
  (define (winsock-test-construction-helpers?) : bool
    (match (winsock-acquire)
      [(WinsockAcquireErr _) false]
      [(WinsockAcquired source-lease)
        (with
          ([source-owner source-lease cleanup-winsock-lease])
          (match (unsafe
            (winsock-table-for-lease (& source-owner)))
            [(WinsockTableErr _) false]
            [(WinsockTableOk table)
              (match (unsafe
                (winsock-create-socket-with-lease
                  (& source-owner)
                  2
                  1
                  6
                  (ptr-null : (MutPtr WinsockProtocolInfoW))
                  (cast 0 : u32)
                  (cast 0 : u32)))
                [(WinsockSocketErr _) false]
                [(WinsockSocketOk source)
                  (let
                    [duplicated : bool
                      (winsock-test-duplicate-owner? (& source-owner) source)]
                    (and
                      (=
                        (unsafe
                          (table.close source))
                        0)
                      duplicated))])]))])))

;: Windows-only native assertions run in the hosted inline-test gate.
(test
  winsock-capability-state-and-lease
  (cfg
    windows
    (begin
      (when
        (not (winsock-test-unpublished-failures?))
        (io.panic "winsock: unpublished failure cleanup or slot order"))
      (when
        (not (winsock-test-shadow-path-rejected?))
        (io.panic "winsock: preloaded same-basename identity or truncation"))
      (when
        (not (winsock-test-forged-lease-rejected?))
        (io.panic "winsock: forged lease acquired table access"))
      (when
        (not (winsock-test-failing-publication-wave?))
        (io.panic "winsock: failed candidate under contention"))
      (when
        (not (winsock-test-publication-stress?))
        (io.panic "winsock: concurrent publication or lease balance"))
      (when
        (not (winsock-test-startup-balance?))
        (io.panic "winsock: startup/refcount or authority balance"))
      (when
        (not (winsock-test-invalid-socket-round-trip?))
        (io.panic "winsock: INVALID_SOCKET did not take the error path"))
      (when
        (not (winsock-test-construction-helpers?))
        (io.panic "winsock: construction or duplication under separate leases"))
      unit)
    unit))
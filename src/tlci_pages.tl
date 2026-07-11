;; tlci_pages.tl - Host page mapping/protection helpers for the tlci loader.
;;
;; This module is the OS boundary only: it allocates page-backed memory, copies
;; synthetic byte buffers into it, flips code pages from RW to RX, keeps data
;; pages non-executable, and releases the mapping. Container parsing, fixups,
;; callback ABI entry, and real comptime images belong to later tlci slices.
(import stdlib.io)

(defstruct TlciPageRegion
  (addr i64)
  (size i64)
  (code bool)
  (writable bool)
  (executable bool))

(defenum ResultTlciPageRegion
  (Ok TlciPageRegion)
  (Err String))

(defenum ResultTlciPageUnit
  (Ok)
  (Err String))

(define tlci-pages-page-size : i64
  4096)
(define tlci-pages-linux-prot-read : i64
  1)
(define tlci-pages-linux-prot-write : i64
  2)
(define tlci-pages-linux-prot-exec : i64
  4)
(define tlci-pages-linux-map-private : i64
  2)
(define tlci-pages-linux-map-anonymous : i64
  32)
(define tlci-pages-windows-mem-commit-reserve : i32
  (cast 12288 : i32))
(define tlci-pages-windows-mem-release : i32
  (cast 32768 : i32))
(define tlci-pages-windows-page-readwrite : i32
  (cast 4 : i32))
(define tlci-pages-windows-page-readonly : i32
  (cast 2 : i32))
(define tlci-pages-windows-page-execute-read : i32
  (cast 32 : i32))

(cfg
  windows
  (extern (tlci-pages-win-virtual-alloc
    [address : i64]
    [size : i64]
    [allocation-type : i32]
    [protect : i32]) : i64 (:symbol "VirtualAlloc")))
(cfg
  windows
  (extern (tlci-pages-win-virtual-protect
    [address : i64]
    [size : i64]
    [new-protect : i32]
    [old-protect : (MutPtr i32)]) : i32 (:symbol "VirtualProtect")))
(cfg
  windows
  (extern (tlci-pages-win-virtual-free
    [address : i64]
    [size : i64]
    [free-type : i32]) : i32 (:symbol "VirtualFree")))

(define (tlci-pages-round-size [byte-count : i64]) : i64
  (bit-and (+ byte-count (- tlci-pages-page-size 1)) (- 0 tlci-pages-page-size)))

(define (tlci-pages-addr->mut-u8 [addr : i64]) : (MutPtr u8)
  (unsafe
    (int->ptr (cast addr : u64) : (MutPtr u8))))

(define (tlci-pages-addr->ptr-u8 [addr : i64]) : (Ptr u8)
  (unsafe
    (int->ptr (cast addr : u64) : (Ptr u8))))

(define (tlci-pages-array-ptr [bytes : (Array u8)]) : (Ptr u8)
  (unsafe
    (ptr-cast (array-data bytes) : (Ptr u8))))

(define (tlci-pages-copy-bytes!
  [dst : (MutPtr u8)]
  [src : (Ptr u8)]
  [count : i64]) : unit
  (let
    [i : i64 0]
    (while (< i count)
      (begin
        (unsafe
          (ptr-write! (ptr-offset dst i) (ptr-read (ptr-offset src i))))
        (set! i (+ i 1))))))

(cfg
  (not windows)
  (define (tlci-pages-linux-status-ok? [result : i64]) : bool
    (not (and (>= result -4095) (< result 0)))))

(cfg
  (not windows)
  (define (tlci-pages-linux-allocate-rw [size : i64]) : i64
    (unsafe
      (syscall
        9
        0
        size
        (+ tlci-pages-linux-prot-read tlci-pages-linux-prot-write)
        (+ tlci-pages-linux-map-private tlci-pages-linux-map-anonymous)
        -1
        0))))

(cfg
  (not windows)
  (define (tlci-pages-linux-protect [region : TlciPageRegion] [prot : i64]) : bool
    (tlci-pages-linux-status-ok?
      (unsafe
        (syscall 10 (struct-get region addr) (struct-get region size) prot)))))

(cfg
  (not windows)
  (define (tlci-pages-linux-release [region : TlciPageRegion]) : bool
    (tlci-pages-linux-status-ok?
      (unsafe
        (syscall 11 (struct-get region addr) (struct-get region size))))))

(cfg
  windows
  (define (tlci-pages-windows-allocate-rw [size : i64]) : i64
    (tlci-pages-win-virtual-alloc
      0
      size
      tlci-pages-windows-mem-commit-reserve
      tlci-pages-windows-page-readwrite)))

(cfg
  windows
  (define (tlci-pages-windows-protect [region : TlciPageRegion] [protect : i32]) : bool
    (let
      [old : (Array i32) (make-array i32 1)]
      [ok : i32
        (tlci-pages-win-virtual-protect
          (struct-get region addr)
          (struct-get region size)
          protect
          (unsafe
            (ptr-cast (array-data old) : (MutPtr i32))))]
      (not (= ok (cast 0 : i32))))))

(cfg
  windows
  (define (tlci-pages-windows-release [region : TlciPageRegion]) : bool
    (not
      (=
        (tlci-pages-win-virtual-free
          (struct-get region addr)
          0
          tlci-pages-windows-mem-release)
        (cast 0 : i32)))))

(define (tlci-pages-platform-allocate-rw [size : i64]) : i64
  (cfg
    windows
    (tlci-pages-windows-allocate-rw size)
    (tlci-pages-linux-allocate-rw size)))

(define (tlci-pages-platform-protect-code [region : TlciPageRegion]) : bool
  (cfg
    windows
    (tlci-pages-windows-protect region tlci-pages-windows-page-execute-read)
    (tlci-pages-linux-protect
      region
      (+ tlci-pages-linux-prot-read tlci-pages-linux-prot-exec))))

(define (tlci-pages-platform-protect-data-readonly [region : TlciPageRegion]) : bool
  (cfg
    windows
    (tlci-pages-windows-protect region tlci-pages-windows-page-readonly)
    (tlci-pages-linux-protect region tlci-pages-linux-prot-read)))

(define (tlci-pages-platform-release [region : TlciPageRegion]) : bool
  (cfg
    windows
    (tlci-pages-windows-release region)
    (tlci-pages-linux-release region)))

(define (tlci-pages-allocate-rw [byte-count : i64] [code : bool]) : ResultTlciPageRegion
  (if (<= byte-count 0)
    (ResultTlciPageRegion.Err "tlci pages: byte count must be positive")
    (let
      [size : i64 (tlci-pages-round-size byte-count)]
      [addr : i64 (tlci-pages-platform-allocate-rw size)]
      (if (<= addr 0)
        (ResultTlciPageRegion.Err "tlci pages: page allocation failed")
        (ResultTlciPageRegion.Ok (TlciPageRegion addr size code true false))))))

(define (tlci-pages-allocate-code [byte-count : i64]) : ResultTlciPageRegion
  (tlci-pages-allocate-rw byte-count true))

(define (tlci-pages-allocate-data [byte-count : i64]) : ResultTlciPageRegion
  (tlci-pages-allocate-rw byte-count false))

(define (tlci-pages-copy-from-array!
  [region : TlciPageRegion]
  [bytes : (Array u8)]) : ResultTlciPageUnit
  (let
    [count : i64 (array-length bytes)]
    (if (not (struct-get region writable))
      (ResultTlciPageUnit.Err "tlci pages: cannot copy into protected region")
      (if (> count (struct-get region size))
        (ResultTlciPageUnit.Err "tlci pages: byte buffer exceeds mapped region")
        (begin
          (tlci-pages-copy-bytes!
            (tlci-pages-addr->mut-u8 (struct-get region addr))
            (tlci-pages-array-ptr bytes)
            count)
          (ResultTlciPageUnit.Ok))))))

(define (tlci-pages-protect-code-executable [region : TlciPageRegion]) : ResultTlciPageRegion
  (cond
    [(not (struct-get region code))
      (ResultTlciPageRegion.Err "tlci pages: data pages cannot be executable")]
    [(struct-get region executable)
      (ResultTlciPageRegion.Err "tlci pages: code page is already executable")]
    [(tlci-pages-platform-protect-code region)
      (ResultTlciPageRegion.Ok
        (TlciPageRegion
          (struct-get region addr)
          (struct-get region size)
          true
          false
          true))]
    [else (ResultTlciPageRegion.Err "tlci pages: code page protection failed")]))

(define (tlci-pages-protect-data-readonly [region : TlciPageRegion]) : ResultTlciPageRegion
  (if (struct-get region code)
    (ResultTlciPageRegion.Err
      "tlci pages: code pages cannot use data protection")
    (if (tlci-pages-platform-protect-data-readonly region)
      (ResultTlciPageRegion.Ok
        (TlciPageRegion
          (struct-get region addr)
          (struct-get region size)
          false
          false
          false))
      (ResultTlciPageRegion.Err "tlci pages: data page protection failed"))))

(define (tlci-pages-release [region : TlciPageRegion]) : ResultTlciPageUnit
  (if (tlci-pages-platform-release region)
    (ResultTlciPageUnit.Ok)
    (ResultTlciPageUnit.Err "tlci pages: page release failed")))

(define (tlci-pages-map-code [bytes : (Array u8)]) : ResultTlciPageRegion
  (match (tlci-pages-allocate-code (array-length bytes))
    [(ResultTlciPageRegion.Err message) (ResultTlciPageRegion.Err message)]
    [(ResultTlciPageRegion.Ok region)
      (match (tlci-pages-copy-from-array! region bytes)
        [(ResultTlciPageUnit.Err message)
          (begin
            (tlci-pages-release region)
            (ResultTlciPageRegion.Err message))]
        [(ResultTlciPageUnit.Ok) (tlci-pages-protect-code-executable region)])]))

(define (tlci-pages-map-data [bytes : (Array u8)]) : ResultTlciPageRegion
  (match (tlci-pages-allocate-data (array-length bytes))
    [(ResultTlciPageRegion.Err message) (ResultTlciPageRegion.Err message)]
    [(ResultTlciPageRegion.Ok region)
      (match (tlci-pages-copy-from-array! region bytes)
        [(ResultTlciPageUnit.Err message)
          (begin
            (tlci-pages-release region)
            (ResultTlciPageRegion.Err message))]
        [(ResultTlciPageUnit.Ok) (ResultTlciPageRegion.Ok region)])]))

(define (tlci-pages-read-byte [region : TlciPageRegion] [offset : i64]) : u8
  (unsafe
    (ptr-read
      (ptr-offset (tlci-pages-addr->ptr-u8 (struct-get region addr)) offset))))

(define (tlci-pages-test-bytes [a : u8] [b : u8] [c : u8]) : (Array u8)
  (make-array a b c))

(define (tlci-pages-test-release-ok? [region : TlciPageRegion]) : bool
  (match (tlci-pages-release region)
    [(ResultTlciPageUnit.Ok) true]
    [(ResultTlciPageUnit.Err _) false]))

(define (tlci-pages-test-panic-if [failed : bool] [message : String]) : unit
  (if failed
    (io.panic message)
    unit))

(test
  tlci-pages-invalid-size
  (match (tlci-pages-allocate-code 0)
    [(ResultTlciPageRegion.Err _) unit]
    [(ResultTlciPageRegion.Ok region)
      (begin
        (tlci-pages-release region)
        (io.panic "tlci pages: expected invalid size failure"))]))

(test
  tlci-pages-map-data-non-executable
  (let
    [bytes : (Array u8)
      (tlci-pages-test-bytes (cast 17 : u8) (cast 34 : u8) (cast 51 : u8))]
    (match (tlci-pages-map-data bytes)
      [(ResultTlciPageRegion.Err message) (io.panic message)]
      [(ResultTlciPageRegion.Ok region)
        (let
          [content-ok : bool
            (and
              (= (cast (tlci-pages-read-byte region 0) : i64) 17)
              (= (cast (tlci-pages-read-byte region 1) : i64) 34)
              (= (cast (tlci-pages-read-byte region 2) : i64) 51))]
          [flags-ok : bool
            (and
              (not (struct-get region code))
              (struct-get region writable)
              (not (struct-get region executable)))]
          [exec-rejected : bool
            (match (tlci-pages-protect-code-executable region)
              [(ResultTlciPageRegion.Err _) true]
              [(ResultTlciPageRegion.Ok _) false])]
          [release-ok : bool (tlci-pages-test-release-ok? region)]
          (begin
            (tlci-pages-test-panic-if
              (not (and content-ok flags-ok exec-rejected release-ok))
              "tlci pages: data mapping failed")
            unit))])))

(test
  tlci-pages-map-code-rx
  (let
    [bytes : (Array u8)
      (tlci-pages-test-bytes (cast 195 : u8) (cast 144 : u8) (cast 144 : u8))]
    (match (tlci-pages-map-code bytes)
      [(ResultTlciPageRegion.Err message) (io.panic message)]
      [(ResultTlciPageRegion.Ok region)
        (let
          [content-ok : bool
            (and
              (= (cast (tlci-pages-read-byte region 0) : i64) 195)
              (= (cast (tlci-pages-read-byte region 1) : i64) 144)
              (= (cast (tlci-pages-read-byte region 2) : i64) 144))]
          [flags-ok : bool
            (and
              (struct-get region code)
              (not (struct-get region writable))
              (struct-get region executable))]
          [copy-rejected : bool
            (match (tlci-pages-copy-from-array! region bytes)
              [(ResultTlciPageUnit.Err _) true]
              [(ResultTlciPageUnit.Ok) false])]
          [release-ok : bool (tlci-pages-test-release-ok? region)]
          (begin
            (tlci-pages-test-panic-if
              (not (and content-ok flags-ok copy-rejected release-ok))
              "tlci pages: code mapping failed")
            unit))])))
;# stdlib/env.tl - Environment variable helpers for TypeLisp.
;#
;# Provides recoverable environment lookup and mutation plus PATH-style list
;# helpers on top of direct platform bindings:
;#
;# `var-exists?`, `var-value`, `set!`, `unset!`, and `path-separator`. Public
;# list-returning PATH helpers remain for compatibility; vector-returning
;# variants avoid the extra copy for new internal callers.
;#
;# Usage: `(import stdlib.env)`
;#
;# ```typelisp
;# (import stdlib.env)
;# (define fallback : env.EnvMaybeString
;#   (let [name : String "TYPELISP_DOC_TEST_MISSING_ENV"] (env.get (& name))))
;# ```
(import stdlib.str_cat)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as svec)

;: Windows kernel32 `GetEnvironmentStringsA` binding. Returns
;: the process environment block: NUL-separated `NAME=VALUE` entries terminated
;: by an empty entry (a trailing double NUL). Replaces the former backend-emitted
;: `getenv` libc shim on Windows; the Linux side walks the SysV stack-captured
;: environment directly. The block is intentionally not freed: the returned value
;: pointer is copied by the caller before any further allocation, and these CLI
;: tools are short-lived.
(cfg
  windows
  (extern (env-win-get-environment-strings) : (Ptr u8) (:symbol "GetEnvironmentStringsA")))

;: Windows kernel32 environment mutation binding. A null `value` removes the
;: variable; a non-null pointer (including an empty C string) sets it.
(cfg
  windows
  (extern (env-win-set-environment-variable
    [name : (Ptr u8)]
    [value : (Ptr u8)]) : i32 (:symbol "SetEnvironmentVariableA")))

;: Arena hooks used to keep Linux replacement environment entries alive for the
;: rest of the process. Linux has no kernel-owned mutable environment: `envp` is
;: userspace storage supplied at process entry and later passed to `execve`.
(extern (env-arena-make) : i64 (:symbol "tl_arena_make"))

;: Return the current active arena handle for restoration after mutation.
(extern (env-arena-current) : i64 (:symbol "tl_arena_current"))

;: Switch the active arena while persistent Linux environment storage is built.
(unsafe
  (extern (env-arena-set [arena : i64]) : unit (:symbol "tl_arena_set")))

;: Process-lifetime storage for Linux replacement arrays and entries. Windows
;: keeps its environment in kernel32 and does not allocate this arena. It is an
;: ordinary arena, not a concurrent allocation target: only the holder of the
;: mutation lock below ever allocates from it, and nothing is rewound or freed.
(define env-linux-persistent-arena : i64
  (cfg windows 0 (env-arena-make)))

;: Slot of the Linux mutation lock word in the control block: 0 free, 1 held,
;: 2 held with at least one waiter parked on the futex.
(define env-linux-control-lock-slot : i64
  0)

;: Slot holding the address of the published Linux `char**` table, or zero while
;: the initial stack-captured environment remains current.
(define env-linux-control-environ-slot : i64
  1)

;: Slot holding the address of an installed publication gate, or zero. See
;: `linux-publication-gate-set!`.
(define env-linux-control-gate-slot : i64
  2)

;: Allocate the process-lifetime Linux control block inside `arena` and return
;: its address. Runs once, from module initialization, before any worker thread
;: exists. Every slot starts at zero: the lock is free, the initial environment
;: is current, and no gate is installed.
(define (linux-control-create [arena : i64]) : i64
  (let
    [home : i64 (env-arena-current)]
    (begin
      (unsafe
        (env-arena-set arena))
      (let
        [slots : (__tl_dyn-array i64) (__tl_make-array i64 3)]
        [_lock : unit (set! (array-ref slots 0) 0)]
        [_environ : unit (set! (array-ref slots 1) 0)]
        [_gate : unit (set! (array-ref slots 2) 0)]
        [addr : i64
          (unsafe
            (cast
              (ptr->int (ptr-cast (__tl_array-data slots) : (Ptr u8)))
              : i64))]
        (begin
          (unsafe
            (env-arena-set home))
          addr)))))

;: Address of the Linux control block. Threads share the block, never this
;: binding's storage: it is written once during single-threaded initialization
;: and only read afterwards. Every access to a slot is an atomic operation.
(define env-linux-control-addr : i64
  (cfg windows 0 (linux-control-create env-linux-persistent-arena)))

;: Pointer to one slot of the Linux control block.
(unsafe
  (define (linux-control-slot [slot : i64]) : (MutPtr i64)
    (unsafe
      (ptr-offset
        (int->ptr (cast env-linux-control-addr : u64) : (MutPtr i64))
        slot))))

;: Block in the kernel while the 32-bit word at `addr` still equals `expected`.
;: Spurious returns are fine: every caller rechecks its condition.
(unsafe
  (define (linux-futex-wait [addr : i64] [expected : i64]) : unit
    (begin
      (unsafe
        (syscall 202 addr 0 expected 0 0 0))
      unit)))

;: Wake every thread parked on the word at `addr`.
(unsafe
  (define (linux-futex-wake-all [addr : i64]) : unit
    (begin
      (unsafe
        (syscall 202 addr 1 2147483647 0 0 0))
      unit)))

;: Acquire the Linux mutation lock, parking on the lock word under contention.
;: The critical section never blocks, so waiters are released promptly. Lock
;: values stay below 2^31, so the futex's 32-bit comparison sees the whole state
;: in the little-endian low half of the i64 word.
(define (linux-lock!) : unit
  (let
    [word : (MutPtr i64)
      (unsafe
        (linux-control-slot env-linux-control-lock-slot))]
    [seen : i64
      (unsafe
        (atomic-cas! word 0 1))]
    (while (not (= seen 0))
      (begin
        ;; Mark the lock contended before parking so the holder knows to wake.
        (if (or
          (= seen 2)
          (not
            (=
              (unsafe
                (atomic-cas! word 1 2))
              0)))
          (unsafe
            (linux-futex-wait
              (unsafe
                (cast (ptr->int word) : i64))
              2))
          unit)
        (set!
          seen
          (unsafe
            (atomic-cas! word 0 2)))))))

;: Release the Linux mutation lock and wake parked waiters when there are any.
(define (linux-unlock!) : unit
  (let
    [word : (MutPtr i64)
      (unsafe
        (linux-control-slot env-linux-control-lock-slot))]
    (if (=
      (unsafe
        (atomic-fetch-add! word -1))
      1)
      unit
      (begin
        (unsafe
          (atomic-store! word 0))
        (unsafe
          (linux-futex-wake-all
            (unsafe
              (cast (ptr->int word) : i64))))))))

;: Install (`gate-addr` nonzero) or remove (zero) a publication gate: two live
;: `i64` cells that outlive every mutation performed while installed. With a gate
;: installed, a mutator that has built its complete replacement table, and still
;: holds the mutation lock, stores 1 into cell 0, wakes cell 0's waiters, and then
;: parks until cell 1 becomes nonzero before it publishes. This is the
;: deterministic interleaving point for tests that must observe "replacement
;: built, not yet published". It is unsafe because the caller owns the cells'
;: lifetime and must open the gate, or every later mutation blocks forever.
(unsafe
  (define (linux-publication-gate-set! [gate-addr : i64]) : unit
    (unsafe
      (atomic-store! (linux-control-slot env-linux-control-gate-slot) gate-addr))))

;: Park at an installed publication gate until a test opens it.
(define (linux-publication-gate-pass!) : unit
  (let
    [gate-addr : i64
      (unsafe
        (atomic-load (linux-control-slot env-linux-control-gate-slot)))]
    (if (= gate-addr 0)
      unit
      (let
        [reached : (MutPtr i64)
          (unsafe
            (int->ptr (cast gate-addr : u64) : (MutPtr i64)))]
        [open : (MutPtr i64)
          (unsafe
            (ptr-offset reached 1))]
        (begin
          (unsafe
            (atomic-store! reached 1))
          (unsafe
            (linux-futex-wake-all gate-addr))
          (while (=
            (unsafe
              (atomic-load open))
            0)
            (unsafe
              (linux-futex-wait (+ gate-addr 8) 0))))))))

;: Length of the NUL-terminated C string at `ptr` (a freestanding `strlen`).
(unsafe
  (define (c-string-length [ptr : (Ptr u8)]) : i64
    (let
      [n : i64 0]
      (begin
        (while (not
          (=
            (unsafe
              (ptr-read (ptr-offset ptr n)))
            (cast 0 : u8)))
          (set! n (+ n 1)))
        n))))

;: Copy a NUL-terminated C string into an owned TypeLisp String.
(unsafe
  (define (copy-c-string [ptr : (Ptr u8)]) : String
    (let
      [n : i64
        (unsafe
          (c-string-length ptr))]
      [buf : (__tl_dyn-array u8) (__tl_make-array u8 n)]
      [i : i64 0]
      (begin
        (while (< i n)
          (begin
            (set!
              (array-ref buf i)
              (unsafe
                (ptr-read (ptr-offset ptr i))))
            (set! i (+ i 1))))
        (unsafe
          (string-from-bytes (ptr-cast (__tl_array-data buf) : (Ptr u8)) n))))))

;: Lowercase an ASCII byte (A-Z -> a-z); other bytes pass through. Used for the
;: case-insensitive environment-name match on Windows.
(define (ascii-fold [b : u8]) : u8
  (if (and (>= (cast b : i64) 65) (<= (cast b : i64) 90))
    (cast (+ (cast b : i64) 32) : u8)
    b))

;: True when `name` is the variable name of the C env entry `entry` (a
;: `NAME=VALUE` string). When matched, returns a pointer to the value (just past
;: the `=`); otherwise null. `fold` enables case-insensitive comparison (Windows).
(unsafe
  (define (match-entry [name : (& name str)] [entry : (Ptr u8)] [fold : bool]) : (Ptr
      u8)
    (let
      [n : i64 (string-length name)]
      [i : i64 0]
      [ok : bool true]
      (begin
        (while (and ok (< i n))
          (let
            [ec : u8
              (unsafe
                (ptr-read (ptr-offset entry i)))]
            [nc : u8 (cast (string-ref name i) : u8)]
            (if (if fold
              (= (ascii-fold ec) (ascii-fold nc))
              (= ec nc))
              (set! i (+ i 1))
              (set! ok false))))
        (if (not ok)
          (ptr-null : (Ptr u8))
          (let
            [sep : u8
              (unsafe
                (ptr-read (ptr-offset entry n)))]
            (if (= sep (cast '=' : u8))
              (unsafe
                (ptr-offset entry (+ n 1)))
              (ptr-null : (Ptr u8)))))))))

;: Return one admitted Linux environment table. Before the first mutation this
;: is the SysV stack-captured `envp`; afterwards it is the most recently published
;: replacement. A table is complete before its address is published with one
;: atomic store, and tables and entries are immutable and live for the rest of
;: the process, so a caller may keep walking the table it loaded while mutators
;: publish newer ones: its view can be older, never partial and never dangling.
;: Lookups and the `execve` environment built by `stdlib/process_runtime.tl`
;: each load exactly one table through this boundary.
(unsafe
  (define (linux-environ) : (Ptr (Ptr u8))
    (let
      [published : i64
        (unsafe
          (atomic-load (linux-control-slot env-linux-control-environ-slot)))]
      (if (= published 0)
        (unsafe
          (ptr-offset (program-argv) (+ (program-argc) 1)))
        (unsafe
          (int->ptr (cast published : u64) : (Ptr (Ptr u8))))))))

;: Linux `getenv`: walk the current environment. The initial SysV stack lays out
;: argc, argv[0..], a NULL, then envp[0..]; later mutations publish a replacement
;: array. Returns a pointer to the value of `name`, or null when missing.
(unsafe
  (define (getenv-ptr-linux [name : (& name str)]) : (Ptr u8)
    (let
      [envp : (Ptr (Ptr u8))
        (unsafe
          (linux-environ))]
      [idx : i64 0]
      [result : (Ptr u8) (ptr-null : (Ptr u8))]
      [stop : bool false]
      (begin
        (while (not stop)
          (let
            [entry : (Ptr u8)
              (unsafe
                (ptr-read (ptr-offset envp idx)))]
            (if (ptr-null? entry)
              (set! stop true)
              (let
                [value : (Ptr u8)
                  (unsafe
                    (match-entry name entry false))]
                (if (ptr-null? value)
                  (set! idx (+ idx 1))
                  (begin
                    (set! result value)
                    (set! stop true)))))))
        result))))

;: Windows `getenv`: walk the GetEnvironmentStringsA block (case-insensitive,
;: matching the platform's environment semantics). Returns a pointer to the value
;: of `name`, or null when missing.
(cfg
  windows
  (unsafe
    (define (env-getenv-ptr-windows [name : (& name str)]) : (Ptr u8)
      (let
        [p : (Ptr u8)
          (unsafe
            (env-win-get-environment-strings))]
        [result : (Ptr u8) (ptr-null : (Ptr u8))]
        [stop : bool false]
        (begin
          (while (not stop)
            (if (=
              (unsafe
                (ptr-read p))
              (cast 0 : u8))
              (set! stop true)
              (let
                [value : (Ptr u8)
                  (unsafe
                    (match-entry name p true))]
                (if (ptr-null? value)
                  (set!
                    p
                    (unsafe
                      (ptr-offset
                        p
                        (+
                          (unsafe
                            (c-string-length p))
                          1))))
                  (begin
                    (set! result value)
                    (set! stop true))))))
          result)))))

;: Return the value pointer for `name`, or null when missing. `env.tl` is
;: imported by the compiler loader while stdlib roots are being discovered, so
;: this avoids depending on another stdlib module: it uses only builtins, its own
;: helpers, and (on Windows) a direct kernel32 binding.
(unsafe
  (define (getenv-ptr [name : (& name str)]) : (Ptr u8)
    (cfg
      windows
      (unsafe
        (env-getenv-ptr-windows name))
      (unsafe
        (getenv-ptr-linux name)))))

;: Return true when `name` is present in the process environment.
(define (var-exists? [name : (& name str)]) : bool
  (not
    (ptr-null?
      (unsafe
        (getenv-ptr name)))))

;: Return the value of `name`, or an empty string when the variable is missing.
(define (var-value [name : (& name str)]) : String
  (let
    [value : (Ptr u8)
      (unsafe
        (getenv-ptr name))]
    (if (ptr-null? value)
      ""
      (unsafe
        (copy-c-string value)))))

;: Return true when `text` contains `needle`.
(define (contains-char? [text : (& text str)] [needle : char]) : bool
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [found : bool false]
    (begin
      (while (and (< i n) (not found))
        (begin
          (if (= (string-ref text i) needle)
            (set! found true)
            unit)
          (set! i (+ i 1))))
      found)))

;: Return true when an environment name can be represented by both target
;: APIs. Empty names, `=`, and interior NUL bytes are rejected.
(define (valid-name? [name : (& name str)]) : bool
  (and
    (> (string-length name) 0)
    (not (contains-char? name '='))
    (not (contains-char? name '\0'))))

;: Return true when an environment value can be represented as a C string.
(define (valid-value? [value : (& value str)]) : bool
  (not (contains-char? value '\0')))

;: Copy borrowed text into a NUL-terminated active-arena byte array.
(define (c-string-bytes [text : (& text str)]) : (__tl_dyn-array u8)
  (let
    [n : i64 (string-length text)]
    [bytes : (__tl_dyn-array u8) (__tl_make-array u8 (+ n 1))]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! (array-ref bytes i) (cast (string-ref text i) : u8))
          (set! i (+ i 1))))
      (set! (array-ref bytes n) (cast 0 : u8))
      bytes)))

;: Return a read-only byte pointer to an array's backing storage.
(unsafe
  (define (array-u8-ptr [bytes : (__tl_dyn-array u8)]) : (Ptr u8)
    (unsafe
      (ptr-cast (__tl_array-data bytes) : (Ptr u8)))))

;: Return the integer address of an array's backing storage.
(unsafe
  (define (array-u64-addr [slots : (__tl_dyn-array u64)]) : i64
    (unsafe
      (cast (ptr->int (ptr-cast (__tl_array-data slots) : (Ptr u8))) : i64))))

;: Count current Linux environment entries whose names do not match `name`.
(define (linux-nonmatching-count
  [environ : (Ptr (Ptr u8))]
  [name : (& name str)]) : i64
  (let
    [index : i64 0]
    [count : i64 0]
    [done : bool false]
    (begin
      (while (not done)
        (let
          [entry : (Ptr u8)
            (unsafe
              (ptr-read (ptr-offset environ index)))]
          (if (ptr-null? entry)
            (set! done true)
            (begin
              (if (ptr-null?
                (unsafe
                  (match-entry name entry false)))
                (set! count (+ count 1))
                unit)
              (set! index (+ index 1))))))
      count)))

;: Allocate one persistent Linux `NAME=VALUE\0` entry and return its address.
(define (linux-entry-addr [name : (& name str)] [value : (& value str)]) : i64
  (let
    [name-len : i64 (string-length name)]
    [value-len : i64 (string-length value)]
    [bytes : (__tl_dyn-array u8)
      (__tl_make-array u8 (+ (+ name-len value-len) 2))]
    [i : i64 0]
    (begin
      (while (< i name-len)
        (begin
          (set! (array-ref bytes i) (cast (string-ref name i) : u8))
          (set! i (+ i 1))))
      (set! (array-ref bytes name-len) (cast '=' : u8))
      (set! i 0)
      (while (< i value-len)
        (begin
          (set!
            (array-ref bytes (+ (+ name-len 1) i))
            (cast (string-ref value i) : u8))
          (set! i (+ i 1))))
      (set! (array-ref bytes (+ (+ name-len 1) value-len)) (cast 0 : u8))
      (unsafe
        (cast (ptr->int (array-u8-ptr bytes)) : i64)))))

;: Build and publish a Linux replacement environment containing all nonmatching
;: current entries and, when `present` is true, one new value for `name`. The
;: caller holds the mutation lock with the persistent arena active, so the table
;: read here is the newest one and no other thread allocates beside this one.
(define (linux-rebuild!
  [name : (& name str)]
  [value : (& value str)]
  [present : bool]) : unit
  (let
    [environ : (Ptr (Ptr u8))
      (unsafe
        (linux-environ))]
    [kept : i64 (linux-nonmatching-count environ name)]
    [slots : (__tl_dyn-array u64)
      (__tl_make-array
        u64
        (+
          (+
            kept
            (if present
              1
              0))
          1))]
    [read-index : i64 0]
    [write-index : i64 0]
    [done : bool false]
    (begin
      (while (not done)
        (let
          [entry : (Ptr u8)
            (unsafe
              (ptr-read (ptr-offset environ read-index)))]
          (if (ptr-null? entry)
            (set! done true)
            (begin
              (if (ptr-null?
                (unsafe
                  (match-entry name entry false)))
                (begin
                  (set!
                    (array-ref slots write-index)
                    (unsafe
                      (ptr->int entry)))
                  (set! write-index (+ write-index 1)))
                unit)
              (set! read-index (+ read-index 1))))))
      (if present
        (begin
          (set!
            (array-ref slots write-index)
            (cast (linux-entry-addr name value) : u64))
          (set! write-index (+ write-index 1)))
        unit)
      (set! (array-ref slots write-index) (cast 0 : u64))
      (linux-publication-gate-pass!)
      ;; The table and its new entry are fully written; this sequentially
      ;; consistent store is the only point where other threads can see them.
      (unsafe
        (atomic-store!
          (linux-control-slot env-linux-control-environ-slot)
          (unsafe
            (array-u64-addr slots)))))))

;: Set or remove one Linux environment entry while retaining replacement
;: storage for the process lifetime. Mutators are serialized: each one rebuilds
;: from the table its predecessor published, so concurrent updates to different
;: names are never lost. The caller's thread-local active arena is restored
;: before the lock is released; nothing between the two arena switches can fail
;: short of an allocation abort, which ends the process.
(define (linux-mutate!
  [name : (& name str)]
  [value : (& value str)]
  [present : bool]) : bool
  (let
    [home : i64 (env-arena-current)]
    (begin
      (linux-lock!)
      (unsafe
        (env-arena-set env-linux-persistent-arena))
      (linux-rebuild! name value present)
      (unsafe
        (env-arena-set home))
      (linux-unlock!)
      true)))

;: Set one Windows environment entry. Kernel32 copies both C strings before the
;: active-arena buffers expire.
(cfg
  windows
  (define (windows-set! [name : (& name str)] [value : (& value str)]) : bool
    (let
      [name-bytes : (__tl_dyn-array u8) (c-string-bytes name)]
      [value-bytes : (__tl_dyn-array u8) (c-string-bytes value)]
      (not
        (=
          (env-win-set-environment-variable
            (unsafe
              (array-u8-ptr name-bytes))
            (unsafe
              (array-u8-ptr value-bytes)))
          (cast 0 : i32))))))

;: Remove one Windows environment entry. Missing entries are normalized to
;: success to match POSIX `unsetenv` semantics.
(cfg
  windows
  (define (windows-unset! [name : (& name str)]) : bool
    (if (not (var-exists? (string.copy name)))
      true
      (let
        [name-bytes : (__tl_dyn-array u8) (c-string-bytes name)]
        (not
          (=
            (env-win-set-environment-variable
              (unsafe
                (array-u8-ptr name-bytes))
              (ptr-null : (Ptr u8)))
            (cast 0 : i32)))))))

;: Set `name` to `value` in the current process environment. Empty values remain
;: present. Returns false for an empty name, `=` or NUL in the name, NUL in the
;: value, or a Windows host failure.
;:
;: Safe to call from any thread, concurrently with lookups, other mutations and
;: process spawning. On Linux mutations are serialized and each publishes one
;: complete immutable table, so updates to different names are never lost and
;: the last writer of one name wins; a concurrent lookup or spawned child sees
;: either the table before this call or a later one, never a partial one. A
;: read-modify-write spanning several calls (`var-value` then `set!`) is not one
;: transaction. On Windows the environment block is owned and locked by
;: kernel32: `SetEnvironmentVariableA` is atomic per variable and each lookup
;: walks a private `GetEnvironmentStringsA` copy. Only this module's calls are
;: coordinated; foreign code that edits `environ` or the initial stack strings
;: directly is outside the contract.
(define (set! [name : (& name str)] [value : (& value str)]) : bool
  (if (and (valid-name? name) (valid-value? value))
    (cfg windows (windows-set! name value) (linux-mutate! name value true))
    false))

;: Remove `name` from the current process environment. Removing a missing name
;: succeeds. Returns false for an invalid name or a Windows host failure. The
;: threading contract is the one documented on `set!`.
(define (unset! [name : (& name str)]) : bool
  (if (valid-name? name)
    (cfg windows (windows-unset! name) (linux-mutate! name "" false))
    false))

;: Return the target platform PATH-list separator as a one-byte String.
(define (path-separator) : String
  (cfg windows ";" ":"))

;: Optional String result for environment lookups.
(defenum EnvMaybeString
  (EnvNoString)
  (EnvSomeString String))

;: Immutable sequence of strings used for PATH-style environment variables.
;: `slots` holds the `len` live entries in list order. Sequences are shared
;: persistently, so helpers that extend one copy into a right-sized array
;: instead of mutating storage another value still observes.
(defstruct EnvStringList
  (slots (__tl_dyn-array String))
  (len i64))

;: Optional PATH-style list result. Missing variables use `EnvNoStringList`;
;: present empty variables use `EnvSomeStringList` with an empty sequence.
(defenum EnvMaybeStringList
  (EnvNoStringList)
  (EnvSomeStringList EnvStringList))

;: Optional PATH-style vector result. Missing variables use `EnvNoStringVec`;
;: present empty variables use `EnvSomeStringVec` with an empty generated string
;: vector.
(defenum EnvMaybeStringVec
  (EnvNoStringVec)
  (EnvSomeStringVec svec.Vec))

;: Return a present environment string result.
(define (some-string [value : String]) : EnvMaybeString
  (EnvSomeString value))

;: Return a present PATH-style string-list result.
(define (some-string-list [value : EnvStringList]) : EnvMaybeStringList
  (EnvSomeStringList value))

;: Return a present PATH-style string-vector result.
(define (some-string-vec [value : svec.Vec]) : EnvMaybeStringVec
  (EnvSomeStringVec value))

;: Return an empty environment string list.
(define (string-list-empty) : EnvStringList
  (EnvStringList (__tl_make-array String 0) 0))

;: Return the number of entries in `items`.
(define (string-list-count [items : (& items EnvStringList)]) : i64
  items.len)

;: Return the entry at `index`, or the empty string when `index` is out of range.
(define (string-list-ref [items : (& items EnvStringList)] [index : i64]) : String
  (if (and (>= index 0) (< index items.len))
    (string.copy (array-ref items.slots index))
    ""))

;: Prepend an owned string to an environment string list.
(define (string-list-cons [value : String] [rest : EnvStringList]) : EnvStringList
  (let
    [n : i64 rest.len]
    [slots : (__tl_dyn-array String) (__tl_make-array String (+ n 1))]
    [i : i64 0]
    (begin
      (set! (array-ref slots 0) value)
      (while (< i n)
        (begin
          (set! (array-ref slots (+ i 1)) (array-ref rest.slots i))
          (set! i (+ i 1))))
      (EnvStringList slots (+ n 1)))))

;: Build an environment string list from `items`, preserving vector order.
(define (string-list-from-vec [items : svec.Vec]) : EnvStringList
  (let
    [n : i64 (svec.len (& items))]
    [slots : (__tl_dyn-array String) (__tl_make-array String n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! (array-ref slots i) (svec.get (& items) i ""))
          (set! i (+ i 1))))
      (EnvStringList slots n))))

;: Copy `items` into `out`, preserving list order.
(define (string-list-to-vec-into
  [items : (& items EnvStringList)]
  [out : (&mut out svec.Vec)]) : unit
  (let
    [n : i64 items.len]
    [i : i64 0]
    (while (< i n)
      (begin
        (svec.push-ref! out (string.copy (array-ref items.slots i)))
        (set! i (+ i 1))))))

;: Copy `items` into a fresh generated string vector, preserving list order.
(define (string-list-to-vec [items : (& items EnvStringList)]) : svec.Vec
  (let
    [out : svec.Vec (svec.new)]
    (begin
      (string-list-to-vec-into items (&mut out))
      out)))

;: Return the current platform PATH-list separator as a one-byte String.
(define (path-list-separator) : String
  (path-separator))

;: Return the value of `name`, or `EnvNoString` when the variable is missing.
(define (get [name : (& name str)]) : EnvMaybeString
  (let
    [owned-name : String (string.copy name)]
    (if (var-exists? (string.copy owned-name))
      (some-string (var-value owned-name))
      EnvNoString)))

;: Split a PATH-style string using the supplied one-byte separator string.
(define (path-split-with-separator-vec
  [value : (& value str)]
  [separator : (& separator str)]) : svec.Vec
  (let
    [n : i64 (string-length value)]
    (if (= n 0)
      (svec.new)
      (let
        [sep : char (string-ref separator 0)]
        [items : svec.Vec (svec.new)]
        [start : i64 0]
        [i : i64 0]
        (begin
          (while (< i n)
            (if (string.char-eq (string-ref value i) sep)
              (begin
                (svec.push-ref!
                  (&mut items)
                  (string.substring value start (- i start)))
                (set! start (+ i 1))
                (set! i (+ i 1)))
              (set! i (+ i 1))))
          (svec.push-ref!
            (&mut items)
            (string.substring value start (- n start)))
          items)))))

;: Split a PATH-style string using the supplied one-byte separator string.
(define (path-split-with-separator
  [value : (& value str)]
  [separator : (& separator str)]) : EnvStringList
  (string-list-from-vec (path-split-with-separator-vec value separator)))

;: Split a PATH-style string using the current platform separator.
(define (path-split-vec [value : (& value str)]) : svec.Vec
  (let
    [separator : String (path-list-separator)]
    (path-split-with-separator-vec value (& separator))))

;: Split a PATH-style string using the current platform separator.
(define (path-split [value : (& value str)]) : EnvStringList
  (string-list-from-vec (path-split-vec value)))

;: Read `name` and split it as a PATH-style list when present.
(define (path-list-vec [name : (& name str)]) : EnvMaybeStringVec
  (match (get name)
    [(EnvSomeString value) (some-string-vec (path-split-vec (& value)))]
    [(EnvNoString) EnvNoStringVec]))

;: Read `name` and split it as a PATH-style list when present.
(define (path-list [name : (& name str)]) : EnvMaybeStringList
  (match (path-list-vec name)
    [(EnvSomeStringVec value) (some-string-list (string-list-from-vec value))]
    [(EnvNoStringVec) EnvNoStringList]))

;: Append PATH-style `items` to `acc`, allocating joined string segments.
(define (path-join-tail
  [acc : String]
  [items : EnvStringList]
  [separator : (& separator str)]) : String
  (let
    [vec : svec.Vec (string-list-to-vec items)]
    (path-join-vec-tail acc (& vec) 0 separator)))

;: Join PATH-style items using the supplied separator.
(define (path-join-vec-tail
  [acc : String]
  [items : (& items svec.Vec)]
  [index : i64]
  [separator : (& separator str)]) : String
  (if (>= index (svec.len items))
    acc
    (path-join-vec-tail
      (let
        [acc-with-separator : String (str_cat.str-cat acc separator)]
        (str_cat.str-cat acc-with-separator (svec.get items index "")))
      items
      (+ index 1)
      separator)))

;: Join PATH-style items using the supplied separator.
(define (path-join-vec-with-separator
  [items : svec.Vec]
  [separator : (& separator str)]) : String
  (if (<= (svec.len (& items)) 0)
    ""
    (path-join-vec-tail (svec.get (& items) 0 "") (& items) 1 separator)))

;: Join PATH-style items using the current platform separator.
(define (path-join-vec [items : svec.Vec]) : String
  (let
    [separator : String (path-list-separator)]
    (path-join-vec-with-separator items (& separator))))

;: Join PATH-style items using the supplied separator.
(define (path-join-with-separator
  [items : EnvStringList]
  [separator : (& separator str)]) : String
  (path-join-vec-with-separator (string-list-to-vec items) separator))

;: Join PATH-style items using the current platform separator.
(define (path-join [items : EnvStringList]) : String
  (path-join-vec (string-list-to-vec items)))

;: Inline test helper that forces a test failure without importing `io.tl`.
(define (test-fail) : unit
  (begin
    (/ 1 0)
    unit))

;: Inline test assertion for boolean predicates.
(define (test-assert-true [condition : bool] [_message : String]) : unit
  (if condition
    unit
    (test-fail)))

;: Inline test assertion for `i64` equality.
(define (test-assert-i64-eq [actual : i64] [expected : i64] [message : String]) : unit
  (test-assert-true (= actual expected) message))

;: Inline test assertion for owned string equality.
(define (test-assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (test-assert-true (string.eq actual expected) message))

;: Assert that an environment lookup is missing.
(define (test-assert-none [value : EnvMaybeString] [_message : String]) : unit
  (match value
    [(EnvNoString) unit]
    [(EnvSomeString _) (test-fail)]))

;: Assert that an environment lookup is present with `expected`.
(define (test-assert-some
  [value : EnvMaybeString]
  [expected : String]
  [message : String]) : unit
  (match value
    [(EnvSomeString actual)
      (test-assert-owned-string-eq actual expected message)]
    [(EnvNoString) (test-fail)]))

;: Assert that an environment path-list lookup is missing.
(define (test-assert-path-none [value : EnvMaybeStringList] [_message : String]) : unit
  (match value
    [(EnvNoStringList) unit]
    [(EnvSomeStringList _) (test-fail)]))

;: Assert that an environment path-vector lookup is missing.
(define (test-assert-path-vec-none
  [value : EnvMaybeStringVec]
  [_message : String]) : unit
  (match value
    [(EnvNoStringVec) unit]
    [(EnvSomeStringVec _) (test-fail)]))

;: Assert that an environment path-list lookup returns an empty list.
(define (test-assert-path-empty
  [value : EnvMaybeStringList]
  [_message : String]) : unit
  (match value
    [(EnvSomeStringList items)
      (test-assert-true (= (string-list-count items) 0) _message)]
    [(EnvNoStringList) (test-fail)]))

;: Assert that an environment path-vector lookup returns an empty vector.
(define (test-assert-path-vec-empty
  [value : EnvMaybeStringVec]
  [message : String]) : unit
  (match value
    [(EnvSomeStringVec items)
      (test-assert-i64-eq (svec.len (& items)) 0 message)]
    [(EnvNoStringVec) (test-fail)]))

;: Assert that an environment string list contains exactly three strings.
(define (test-assert-list3
  [items : EnvStringList]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (begin
    (test-assert-i64-eq (string-list-count items) 3 (string.copy message))
    (test-assert-owned-string-eq
      (string-list-ref items 0)
      first
      (string.copy message))
    (test-assert-owned-string-eq
      (string-list-ref items 1)
      second
      (string.copy message))
    (test-assert-owned-string-eq (string-list-ref items 2) third message)))

;: Assert that an environment string list contains exactly five strings.
(define (test-assert-list5
  [items : EnvStringList]
  [first : String]
  [second : String]
  [third : String]
  [fourth : String]
  [fifth : String]
  [message : String]) : unit
  (begin
    (test-assert-i64-eq (string-list-count items) 5 (string.copy message))
    (test-assert-owned-string-eq
      (string-list-ref items 0)
      first
      (string.copy message))
    (test-assert-owned-string-eq
      (string-list-ref items 1)
      second
      (string.copy message))
    (test-assert-owned-string-eq
      (string-list-ref items 2)
      third
      (string.copy message))
    (test-assert-owned-string-eq
      (string-list-ref items 3)
      fourth
      (string.copy message))
    (test-assert-owned-string-eq (string-list-ref items 4) fifth message)))

;: Assert that a string vector contains exactly three strings.
(define (test-assert-vec3
  [items : svec.Vec]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (begin
    (test-assert-i64-eq (svec.len (& items)) 3 (string.copy message))
    (test-assert-owned-string-eq
      (svec.get (& items) 0 "missing")
      first
      (string.copy message))
    (test-assert-owned-string-eq
      (svec.get (& items) 1 "missing")
      second
      (string.copy message))
    (test-assert-owned-string-eq (svec.get (& items) 2 "missing") third message)))

;: Assert that a string vector contains exactly five strings.
(define (test-assert-vec5
  [items : svec.Vec]
  [first : String]
  [second : String]
  [third : String]
  [fourth : String]
  [fifth : String]
  [message : String]) : unit
  (begin
    (test-assert-i64-eq (svec.len (& items)) 5 (string.copy message))
    (test-assert-owned-string-eq
      (svec.get (& items) 0 "missing")
      first
      (string.copy message))
    (test-assert-owned-string-eq
      (svec.get (& items) 1 "missing")
      second
      (string.copy message))
    (test-assert-owned-string-eq
      (svec.get (& items) 2 "missing")
      third
      (string.copy message))
    (test-assert-owned-string-eq
      (svec.get (& items) 3 "missing")
      fourth
      (string.copy message))
    (test-assert-owned-string-eq (svec.get (& items) 4 "missing") fifth message)))

;: Assert that a present path-list lookup contains exactly three strings.
(define (test-assert-path3
  [value : EnvMaybeStringList]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (match value
    [(EnvSomeStringList items)
      (test-assert-list3 items first second third message)]
    [(EnvNoStringList) (test-fail)]))

;: Assert that a present path-vector lookup contains exactly three strings.
(define (test-assert-path-vec3
  [value : EnvMaybeStringVec]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (match value
    [(EnvSomeStringVec items)
      (test-assert-vec3 items first second third message)]
    [(EnvNoStringVec) (test-fail)]))
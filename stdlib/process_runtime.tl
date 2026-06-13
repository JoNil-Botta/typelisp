;# stdlib/process_runtime.tl - Process-execution runtime for TypeLisp (#2142).
;#
;# Pure-TypeLisp implementations of the `tl_process_output`, `tl_process_start`,
;# and `tl_process_wait` runtime helpers that the `process.tl` API surface calls.
;# These replace the former hand-written backend assembly
;# (`compiler-backend-runtime-process-output-functions` and
;# `compiler-backend-runtime-windows-process-output-functions`): the bodies below
;# issue the same OS calls directly, selecting per-target behavior with
;# `(cfg windows …)`.
;#
;# Linux uses raw syscalls (memfd-captured stdout/stderr, a pipe2 stdin feed, an
;# `execve` failure-marker pipe, fork/execve, and wait4 exit-status decoding) and
;# fully supports the asynchronous `start`/`wait` pair. Windows uses kernel32
;# (CreateProcessA with temp-file stdout/stderr redirection) for the captured
;# `output` path and reports the asynchronous `start`/`wait` pair as unsupported,
;# matching the previous backend behavior.
;#
;# Usage: imported by `process.tl` (which provides the public wrappers).
(import "core_macros.tl" module stdlib.core_macros as core)

(import "process.tl")

(import "io.tl")

(import "string.tl")

;: Linux inherited environment array (NUL-terminated `char**`). On the freestanding
;: Linux entry the kernel lays out `argc`, `argv[0..]`, a NULL, then `envp[0..]`
;: on the initial stack, so `envp` is `&argv[argc + 1]`. Computed from the
;: `program-argv`/`program-argc` builtins (no new backend symbol — keeps the
;: seed bootstrap working).
(define (process-linux-envp) : (Ptr (Ptr u8))
  (unsafe
    (ptr-offset (program-argv) (+ (program-argc) 1))))

;: Windows kernel32 bindings used by the captured-output path. Referenced only
;: from the Windows branch; the file reuses io.tl's CreateFileA/CloseHandle/
;: GetStdHandle bindings for the remaining handle operations.
(cfg
  windows
  (extern (process-win-get-environment-strings) : (Ptr u8) (:symbol "GetEnvironmentStringsA")))

(cfg
  windows
  (extern (process-win-get-temp-path [arg0 : i32] [arg1 : (MutPtr u8)]) : i32 (:symbol "GetTempPathA")))

(cfg
  windows
  (extern (process-win-get-temp-file-name
    [arg0 : (Ptr u8)]
    [arg1 : (Ptr u8)]
    [arg2 : i32]
    [arg3 : (MutPtr u8)]) : i32 (:symbol "GetTempFileNameA")))

(cfg
  windows
  (extern (process-win-create-process
    [arg0 : i64]
    [arg1 : i64]
    [arg2 : i64]
    [arg3 : i64]
    [arg4 : i32]
    [arg5 : i64]
    [arg6 : i64]
    [arg7 : i64]
    [arg8 : i64]
    [arg9 : i64]) : i32 (:symbol "CreateProcessA")))

(cfg
  windows
  (extern (process-win-wait-single [arg0 : i64] [arg1 : i32]) : i32 (:symbol "WaitForSingleObject")))

(cfg
  windows
  (extern (process-win-get-exit-code [arg0 : i64] [arg1 : (MutPtr i32)]) : i32 (:symbol "GetExitCodeProcess")))

;: Shared spawn-failure result for the captured-output path.
(define (process-spawn-error) : ResultProcessOutput
  (ErrProcessOutput (ProcessSpawnFailed "process: spawn failed")))

;: Shared wait-failure result for the captured-output path.
(define (process-wait-error) : ResultProcessOutput
  (ErrProcessOutput (ProcessWaitFailed "process: wait failed")))

;: Shared spawn-failure result for the asynchronous start path.
(define (process-spawn-error-child) : ResultProcessChild
  (ErrProcessChild (ProcessSpawnFailed "process: spawn failed")))

;: Shared wait-failure result for the asynchronous start path.
(define (process-wait-error-child) : ResultProcessChild
  (ErrProcessChild (ProcessWaitFailed "process: wait failed")))

;: Async-unsupported result for `start` on runtimes without child handles.
(define (process-async-unsupported-child) : ResultProcessChild
  (ErrProcessChild
    (ProcessUnsupported
      "process: async child handles are not supported by this runtime")))

;: Async-unsupported result for `wait` on runtimes without child handles.
(define (process-async-unsupported-output) : ResultProcessOutput
  (ErrProcessOutput
    (ProcessUnsupported
      "process: async child handles are not supported by this runtime")))

;: Return the integer address of an `Array u8` backing buffer.
(define (process-array-u8-addr [buf : (Array u8)]) : i64
  (unsafe
    (cast (ptr->int (ptr-cast (array-data buf) : (Ptr u8))) : i64)))

;: Return the integer address of an `Array u64` backing buffer.
(define (process-array-u64-addr [buf : (Array u64)]) : i64
  (unsafe
    (cast (ptr->int (ptr-cast (array-data buf) : (Ptr u8))) : i64)))

;: Return the integer address of an `Array i32` backing buffer.
(define (process-array-i32-addr [buf : (Array i32)]) : i64
  (unsafe
    (cast (ptr->int (ptr-cast (array-data buf) : (Ptr u8))) : i64)))

;: Read the unsigned byte at `index` of a C string as an i64.
(define (process-byte-at [ptr : (Ptr u8)] [index : i64]) : i64
  (cast
    (unsafe
      (ptr-read (ptr-offset ptr index)))
    : i64))

;: Convert an integer address into a read-only byte pointer.
(define (process-addr->ptr [addr : i64]) : (Ptr u8)
  (unsafe
    (int->ptr (cast addr : u64) : (Ptr u8))))

;: Return true when inherited entry `entry` and override entry `override` (both
;: `NAME=VALUE` C strings) share the same NAME (compared up to the override `=`).
(define (process-cstr-name-matches? [entry : (Ptr u8)] [override : (Ptr u8)]) : bool
  (let
    [i : i64 0]
    [matched : bool false]
    [decided : bool false]
    (begin
      (while (not decided)
        (let
          [oc : i64 (process-byte-at override i)]
          (if (= oc 61)
            (begin
              (set! matched (= (process-byte-at entry i) 61))
              (set! decided true))
            (if (= (process-byte-at entry i) oc)
              (set! i (+ i 1))
              (begin
                (set! matched false)
                (set! decided true))))))
      matched)))

;: Return true when inherited entry `entry` is overridden by any address in `ov`
;: (an array of override `NAME=VALUE` C string addresses).
(define (process-inherited-overridden? [entry : (Ptr u8)] [ov : (Array u64)]) : bool
  (let
    [n : i64 (array-length ov)]
    [i : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< i n))
        (if (process-cstr-name-matches?
          entry
          (process-addr->ptr (cast (array-ref ov i) : i64)))
          (set! found true)
          (set! i (+ i 1))))
      found)))

;: Build a NUL-terminated `NAME=VALUE` C string for an env override.
(define (process-env-cstring [name : String] [value : String]) : (Array u8)
  (let
    [nl : i64 (string-length name)]
    [vl : i64 (string-length value)]
    [buf : (Array u8) (make-array u8 (+ (+ nl vl) 2))]
    [i : i64 0]
    (begin
      (while (< i nl)
        (begin
          (array-set! buf i (cast (string-ref name i) : u8))
          (set! i (+ i 1))))
      (array-set! buf nl (cast 61 : u8))
      (set! i 0)
      (while (< i vl)
        (begin
          (array-set! buf (+ (+ nl 1) i) (cast (string-ref value i) : u8))
          (set! i (+ i 1))))
      (array-set! buf (+ (+ nl 1) vl) (cast 0 : u8))
      buf)))

;: Materialize the override list into an array of `NAME=VALUE` C string
;: addresses. The move-only `env` list is consumed exactly once here so the
;: resulting array can be scanned repeatedly without further moves.
(define (process-build-override-cstrings [env : ProcessEnvList]) : (Array u64)
  (let
    [ov : (Array u64) (make-array u64 0)]
    [cur : ProcessEnvList env]
    [continue : bool true]
    (begin
      (while continue
        (match cur
          [(ProcessEnvNil) (set! continue false)]
          [(ProcessEnvCons name value rest)
            (begin
              (array-push!
                ov
                (unsafe
                  (cast
                    (ptr->int
                      (io-array-const-ptr (process-env-cstring name value)))
                    : u64)))
              (set! cur (box-get rest)))]))
      ov)))

;: Return the integer address of an optional command path C string, or 0.
(define (process-maybe-cstring-addr [value : ProcessMaybeString]) : i64
  (match value
    [(ProcessNoString) 0]
    [(ProcessSomeString text) (process-array-u8-addr (io-c-string text))]))

;: Return true when an optional stdin value provides input.
(define (process-maybe-present? [value : ProcessMaybeString]) : bool
  (match value
    [(ProcessSomeString _) true]
    [(ProcessNoString) false]))

;: Return the integer address of an optional stdin string's byte storage, or 0.
(define (process-maybe-data-addr [value : ProcessMaybeString]) : i64
  (match value
    [(ProcessSomeString text)
      (unsafe
        (cast (ptr->int (string-data text)) : i64))]
    [(ProcessNoString) 0]))

;: Return the byte length of an optional stdin string, or 0.
(define (process-maybe-len [value : ProcessMaybeString]) : i64
  (match value
    [(ProcessSomeString text) (string-length text)]
    [(ProcessNoString) 0]))

;; ---------------------------------------------------------------------------
;; Linux runtime (raw syscalls).
;; ---------------------------------------------------------------------------
;: Captured spawn state assembled before `fork` so the child does no allocation.
(defstruct ProcessLinuxSpawn
  (exec-addr i64)
  (argv-addr i64)
  (envp-addr i64)
  (cwd-addr i64)
  (marker-addr i64)
  (has-stdin bool)
  (stdin-data i64)
  (stdin-len i64)
  (stdin-r i64)
  (stdin-w i64)
  (stdout-fd i64)
  (stderr-fd i64)
  (exec-r i64)
  (exec-w i64)
  (failed bool))

;: Close `fd` with the `close` syscall when it names an open descriptor.
(define (process-linux-close-if [fd : i64]) : unit
  (if (>= fd 0)
    (begin
      (unsafe
        (syscall 3 fd))
      unit)
    unit))

;: Build a NUL-terminated `char**` argv (argv[0] = `exec-addr`) and return its
;: integer address.
(define (process-linux-build-argv [exec-addr : i64] [argv : ProcessStringList]) : i64
  (let
    [argc : i64 (process-args-count argv)]
    [arr : (Array u64) (make-array u64 (+ argc 2))]
    [w : i64 1]
    [cur : ProcessStringList argv]
    [continue : bool true]
    (begin
      (array-set! arr 0 (cast exec-addr : u64))
      (while continue
        (match cur
          [(ProcessStringNil) (set! continue false)]
          [(ProcessStringCons text rest)
            (begin
              (array-set!
                arr
                w
                (unsafe
                  (cast
                    (ptr->int (io-array-const-ptr (io-c-string text)))
                    : u64)))
              (set! w (+ w 1))
              (set! cur (box-get rest)))]))
      (array-set! arr w (cast 0 : u64))
      (process-array-u64-addr arr))))

;: Count inherited environment entries not overridden by `ov`.
(define (process-linux-count-inherited
  [environ : (Ptr (Ptr u8))]
  [ov : (Array u64)]) : i64
  (let
    [i : i64 0]
    [count : i64 0]
    [done : bool false]
    (begin
      (while (not done)
        (let
          [entry : (Ptr u8)
            (unsafe
              (ptr-read (ptr-offset environ i)))]
          (if (ptr-null? entry)
            (set! done true)
            (begin
              (if (not (process-inherited-overridden? entry ov))
                (set! count (+ count 1))
                unit)
              (set! i (+ i 1))))))
      count)))

;: Build the `char**` envp for `env` (inherited minus overrides, plus overrides)
;: and return its integer address; an empty override list reuses the inherited
;: environment array directly.
(define (process-linux-build-envp [env : ProcessEnvList]) : i64
  (let
    [ov : (Array u64) (process-build-override-cstrings env)]
    [ovc : i64 (array-length ov)]
    (if (= ovc 0)
      (unsafe
        (cast (ptr->int (ptr-cast (process-linux-envp) : (Ptr u8))) : i64))
      (let
        [environ : (Ptr (Ptr u8))
          (unsafe
            (ptr-cast (process-linux-envp) : (Ptr (Ptr u8))))]
        [inh : i64 (process-linux-count-inherited environ ov)]
        [arr : (Array u64) (make-array u64 (+ (+ inh ovc) 1))]
        [w : i64 0]
        [i : i64 0]
        [k : i64 0]
        [done : bool false]
        (begin
          (while (not done)
            (let
              [entry : (Ptr u8)
                (unsafe
                  (ptr-read (ptr-offset environ i)))]
              (if (ptr-null? entry)
                (set! done true)
                (begin
                  (if (not (process-inherited-overridden? entry ov))
                    (begin
                      (array-set!
                        arr
                        w
                        (unsafe
                          (cast (ptr->int entry) : u64)))
                      (set! w (+ w 1)))
                    unit)
                  (set! i (+ i 1))))))
          (while (< k ovc)
            (begin
              (array-set! arr w (array-ref ov k))
              (set! w (+ w 1))
              (set! k (+ k 1))))
          (array-set! arr w (cast 0 : u64))
          (process-array-u64-addr arr))))))

;: Decode a `wait4` status word into the process exit status: a terminating
;: signal becomes `128 + signal`, otherwise the low byte of the exit code.
(define (process-decode-status [status : i32]) : i64
  (let
    [value : i64 (cast status : i64)]
    [signal : i64 (bit-and value 0x7f)]
    (if (not (= signal 0))
      (+ 128 signal)
      (bit-and (shr value 8) 0xff))))

;: Write `len` bytes at `data-addr` to `fd`, returning 0 on success, the raw
;: negative `-errno` on a write error, or -1 on a zero-length write.
(define (process-linux-write-all [fd : i64] [data-addr : i64] [len : i64]) : i64
  (let
    [off : i64 0]
    [result : i64 0]
    [done : bool false]
    (begin
      (while (and (not done) (< off len))
        (let
          [written : i64
            (unsafe
              (syscall 1 fd (+ data-addr off) (- len off)))]
          (core/cond
            (< written 0)
            (begin
              (set! result written)
              (set! done true))
            (= written 0)
            (begin
              (set! result -1)
              (set! done true))
            (set! off (+ off written)))))
      result)))

;: Feed `data-addr`/`len` to the child stdin pipe while ignoring SIGPIPE, then
;: restore the old SIGPIPE disposition. Returns 0 when input was delivered (or a
;: broken pipe was tolerated) and 1 on an unexpected write failure.
(define (process-linux-feed-stdin
  [has-stdin : bool]
  [stdin-r : i64]
  [stdin-w : i64]
  [data-addr : i64]
  [len : i64]) : i64
  (if (not has-stdin)
    0
    (begin
      (process-linux-close-if stdin-r)
      (let
        [act : (Array u64) (make-array u64 4)]
        [old : (Array u64) (make-array u64 4)]
        (begin
          (array-set! act 0 (cast 1 : u64))
          (unsafe
            (syscall
              13
              13
              (process-array-u64-addr act)
              (process-array-u64-addr old)
              8))
          (let
            [written : i64 (process-linux-write-all stdin-w data-addr len)]
            (begin
              (process-linux-close-if stdin-w)
              (unsafe
                (syscall 13 13 (process-array-u64-addr old) 0 8))
              (if (>= written 0)
                0
                (if (= written -32)
                  0
                  1)))))))))

;: Assemble argv/envp/cwd/marker C strings and open the capture descriptors
;: (memfd stdout/stderr, an optional stdin pipe, and the exec-failure pipe)
;: before forking. `failed` records a pre-fork OS error.
(define (process-linux-prepare [command : ProcessCommand]) : ProcessLinuxSpawn
  (let
    [exec-addr : i64
      (process-array-u8-addr (io-c-string (process-command-executable command)))]
    [argv-addr : i64
      (process-linux-build-argv exec-addr (process-command-argv command))]
    [envp-addr : i64 (process-linux-build-envp (process-command-env command))]
    [cwd-addr : i64 (process-maybe-cstring-addr (process-command-cwd command))]
    [marker-addr : i64 (process-array-u8-addr (io-c-string "exec"))]
    [has-stdin : bool (process-maybe-present? (process-command-stdin command))]
    [stdin-data : i64 (process-maybe-data-addr (process-command-stdin command))]
    [stdin-len : i64 (process-maybe-len (process-command-stdin command))]
    [stdin-r : i64 -1]
    [stdin-w : i64 -1]
    [stdout-fd : i64 -1]
    [stderr-fd : i64 -1]
    [exec-r : i64 -1]
    [exec-w : i64 -1]
    [failed : bool false]
    [pbuf : (Array i32) (make-array i32 2)]
    [ebuf : (Array i32) (make-array i32 2)]
    (begin
      (if has-stdin
        (if (<
          (unsafe
            (syscall 293 (process-array-i32-addr pbuf) 524288))
          0)
          (set! failed true)
          (begin
            (set! stdin-r (cast (array-ref pbuf 0) : i64))
            (set! stdin-w (cast (array-ref pbuf 1) : i64))))
        unit)
      (if (not failed)
        (let
          [fd : i64
            (unsafe
              (syscall
                319
                (process-array-u8-addr (io-c-string "typelisp-process-stdout"))
                0))]
          (if (< fd 0)
            (set! failed true)
            (set! stdout-fd fd)))
        unit)
      (if (not failed)
        (let
          [fd : i64
            (unsafe
              (syscall
                319
                (process-array-u8-addr (io-c-string "typelisp-process-stderr"))
                0))]
          (if (< fd 0)
            (set! failed true)
            (set! stderr-fd fd)))
        unit)
      (if (not failed)
        (if (<
          (unsafe
            (syscall 293 (process-array-i32-addr ebuf) 524288))
          0)
          (set! failed true)
          (begin
            (set! exec-r (cast (array-ref ebuf 0) : i64))
            (set! exec-w (cast (array-ref ebuf 1) : i64))))
        unit)
      (ProcessLinuxSpawn
        exec-addr
        argv-addr
        envp-addr
        cwd-addr
        marker-addr
        has-stdin
        stdin-data
        stdin-len
        stdin-r
        stdin-w
        stdout-fd
        stderr-fd
        exec-r
        exec-w
        failed))))

;: Close every descriptor recorded in a spawn struct (pre-fork cleanup).
(define (process-linux-cleanup-spawn [spawn : ProcessLinuxSpawn]) : unit
  (begin
    (process-linux-close-if (struct-get spawn stdin-r))
    (process-linux-close-if (struct-get spawn stdin-w))
    (process-linux-close-if (struct-get spawn stdout-fd))
    (process-linux-close-if (struct-get spawn stderr-fd))
    (process-linux-close-if (struct-get spawn exec-r))
    (process-linux-close-if (struct-get spawn exec-w))
    unit))

;: Child failure path: write the `exec` marker through the failure pipe so the
;: parent learns `execve` did not take over, then exit(127). Never returns.
(define (process-linux-child-fail [exec-w : i64] [marker-addr : i64]) : never
  (begin
    (unsafe
      (syscall 1 exec-w marker-addr 4))
    (unsafe
      (syscall 60 127))
    (process-linux-child-fail exec-w marker-addr)))

;: Forked child path (syscalls only, no allocation): wire stdin/stdout/stderr,
;: chdir, then `execve`. Never returns (it execs or exits 127).
(define (process-linux-exec-child [spawn : ProcessLinuxSpawn]) : never
  (begin
    (unsafe
      (syscall 3 (struct-get spawn exec-r)))
    (if (>= (struct-get spawn stdin-w) 0)
      (begin
        (unsafe
          (syscall 3 (struct-get spawn stdin-w)))
        (if (<
          (unsafe
            (syscall 33 (struct-get spawn stdin-r) 0))
          0)
          (process-linux-child-fail
            (struct-get spawn exec-w)
            (struct-get spawn marker-addr))
          (begin
            (unsafe
              (syscall 3 (struct-get spawn stdin-r)))
            unit)))
      unit)
    (unsafe
      (syscall 33 (struct-get spawn stdout-fd) 1))
    (unsafe
      (syscall 33 (struct-get spawn stderr-fd) 2))
    (unsafe
      (syscall 3 (struct-get spawn stdout-fd)))
    (unsafe
      (syscall 3 (struct-get spawn stderr-fd)))
    (if (not (= (struct-get spawn cwd-addr) 0))
      (if (<
        (unsafe
          (syscall 80 (struct-get spawn cwd-addr)))
        0)
        (process-linux-child-fail
          (struct-get spawn exec-w)
          (struct-get spawn marker-addr))
        unit)
      unit)
    (unsafe
      (syscall
        59
        (struct-get spawn exec-addr)
        (struct-get spawn argv-addr)
        (struct-get spawn envp-addr)))
    (process-linux-child-fail
      (struct-get spawn exec-w)
      (struct-get spawn marker-addr))))

;: Return true when the child wrote the `execve`-failure marker.
(define (process-linux-exec-failed? [exec-r : i64]) : bool
  (let
    [buf : (Array u8) (make-array u8 8)]
    [count : i64
      (unsafe
        (syscall 0 exec-r (process-array-u8-addr buf) 8))]
    (begin
      (process-linux-close-if exec-r)
      (> count 0))))

;: Parent path for the captured-output runtime: feed stdin, wait for the child,
;: detect `execve` failure, then read the memfd-captured stdout/stderr.
(define (process-linux-output-parent [spawn : ProcessLinuxSpawn] [pid : i64]) : ResultProcessOutput
  (begin
    (process-linux-close-if (struct-get spawn exec-w))
    (let
      [stdin-status : i64
        (process-linux-feed-stdin
          (struct-get spawn has-stdin)
          (struct-get spawn stdin-r)
          (struct-get spawn stdin-w)
          (struct-get spawn stdin-data)
          (struct-get spawn stdin-len))]
      (if (= stdin-status 1)
        (begin
          (process-linux-close-if (struct-get spawn stdout-fd))
          (process-linux-close-if (struct-get spawn stderr-fd))
          (process-linux-close-if (struct-get spawn exec-r))
          (process-wait-error))
        (let
          [statusbuf : (Array i32) (make-array i32 1)]
          [waited : i64
            (unsafe
              (syscall 61 pid (process-array-i32-addr statusbuf) 0 0))]
          (if (< waited 0)
            (begin
              (process-linux-close-if (struct-get spawn stdout-fd))
              (process-linux-close-if (struct-get spawn stderr-fd))
              (process-linux-close-if (struct-get spawn exec-r))
              (process-wait-error))
            (if (process-linux-exec-failed? (struct-get spawn exec-r))
              (begin
                (process-linux-close-if (struct-get spawn stdout-fd))
                (process-linux-close-if (struct-get spawn stderr-fd))
                (process-spawn-error))
              (let
                [stdout-text : String
                  (io-read-fd-to-string (struct-get spawn stdout-fd))]
                [stderr-text : String
                  (io-read-fd-to-string (struct-get spawn stderr-fd))]
                [status : i64 (process-decode-status (array-ref statusbuf 0))]
                (begin
                  (process-linux-close-if (struct-get spawn stdout-fd))
                  (process-linux-close-if (struct-get spawn stderr-fd))
                  (OkProcessOutput
                    (ProcessOutput status stdout-text stderr-text)))))))))))

;: Parent path for the asynchronous start runtime: feed stdin, detect immediate
;: `execve` failure, otherwise return a child owning the capture descriptors.
(define (process-linux-start-parent [spawn : ProcessLinuxSpawn] [pid : i64]) : ResultProcessChild
  (begin
    (process-linux-close-if (struct-get spawn exec-w))
    (let
      [stdin-status : i64
        (process-linux-feed-stdin
          (struct-get spawn has-stdin)
          (struct-get spawn stdin-r)
          (struct-get spawn stdin-w)
          (struct-get spawn stdin-data)
          (struct-get spawn stdin-len))]
      (if (= stdin-status 1)
        (begin
          (unsafe
            (syscall 61 pid (process-array-i32-addr (make-array i32 1)) 0 0))
          (process-linux-close-if (struct-get spawn stdout-fd))
          (process-linux-close-if (struct-get spawn stderr-fd))
          (process-linux-close-if (struct-get spawn exec-r))
          (process-wait-error-child))
        (if (process-linux-exec-failed? (struct-get spawn exec-r))
          (begin
            (unsafe
              (syscall 61 pid (process-array-i32-addr (make-array i32 1)) 0 0))
            (process-linux-close-if (struct-get spawn stdout-fd))
            (process-linux-close-if (struct-get spawn stderr-fd))
            (process-spawn-error-child))
          (OkProcessChild
            (ProcessChild
              pid
              (struct-get spawn stdout-fd)
              (struct-get spawn stderr-fd))))))))

;: Linux captured-output runtime: prepare, fork, and dispatch parent/child.
(define (process-linux-output [command : ProcessCommand]) : ResultProcessOutput
  (let
    [spawn : ProcessLinuxSpawn (process-linux-prepare command)]
    (if (struct-get spawn failed)
      (begin
        (process-linux-cleanup-spawn spawn)
        (process-spawn-error))
      (let
        [pid : i64
          (unsafe
            (syscall 57))]
        (core/cond
          (< pid 0)
          (begin
            (process-linux-cleanup-spawn spawn)
            (process-spawn-error))
          (= pid 0)
          (process-linux-exec-child spawn)
          (process-linux-output-parent spawn pid))))))

;: Linux asynchronous start runtime: prepare, fork, and dispatch parent/child.
(define (process-linux-start [command : ProcessCommand]) : ResultProcessChild
  (let
    [spawn : ProcessLinuxSpawn (process-linux-prepare command)]
    (if (struct-get spawn failed)
      (begin
        (process-linux-cleanup-spawn spawn)
        (process-spawn-error-child))
      (let
        [pid : i64
          (unsafe
            (syscall 57))]
        (core/cond
          (< pid 0)
          (begin
            (process-linux-cleanup-spawn spawn)
            (process-spawn-error-child))
          (= pid 0)
          (process-linux-exec-child spawn)
          (process-linux-start-parent spawn pid))))))

;: Linux asynchronous wait runtime: reap the child, read the memfd-captured
;: stdout/stderr, release the capture descriptors, and decode the exit status.
(define (process-linux-wait [child : ProcessChild]) : ResultProcessOutput
  (let
    [pid : i64 (struct-get child pid)]
    [stdout-fd : i64 (struct-get child stdout-handle)]
    [stderr-fd : i64 (struct-get child stderr-handle)]
    [statusbuf : (Array i32) (make-array i32 1)]
    [waited : i64
      (unsafe
        (syscall 61 pid (process-array-i32-addr statusbuf) 0 0))]
    (if (< waited 0)
      (begin
        (process-linux-close-if stdout-fd)
        (process-linux-close-if stderr-fd)
        (process-wait-error))
      (let
        [stdout-text : String (io-read-fd-to-string stdout-fd)]
        (begin
          (process-linux-close-if stdout-fd)
          (let
            [stderr-text : String (io-read-fd-to-string stderr-fd)]
            (begin
              (process-linux-close-if stderr-fd)
              (OkProcessOutput
                (ProcessOutput
                  (process-decode-status (array-ref statusbuf 0))
                  stdout-text
                  stderr-text)))))))))

;; ---------------------------------------------------------------------------
;; Windows runtime (kernel32 CreateProcessA with temp-file redirection).
;; ---------------------------------------------------------------------------
;: Return true when `text` contains an ASCII space (argv-quoting trigger).
(define (process-string-has-space? [text : String]) : bool
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< i n))
        (if (= (cast (string-ref text i) : i64) 32)
          (set! found true)
          (set! i (+ i 1))))
      found)))

;: Quote a command-line argument with double quotes when it contains a space.
(define (process-quote-arg [text : String]) : String
  (if (process-string-has-space? text)
    (string-append (string-append "\"" text) "\"")
    text))

;: Join the executable and argv into a single space-separated command line,
;: quoting space-containing entries (the CreateProcessA `lpCommandLine`).
(define (process-windows-cmdline [command : ProcessCommand]) : String
  (let
    [line : String (process-quote-arg (process-command-executable command))]
    [cur : ProcessStringList (process-command-argv command)]
    [continue : bool true]
    (begin
      (while continue
        (match cur
          [(ProcessStringNil) (set! continue false)]
          [(ProcessStringCons text rest)
            (begin
              (set!
                line
                (string-append
                  (string-append line " ")
                  (process-quote-arg text)))
              (set! cur (box-get rest)))]))
      line)))

;: Append the NUL-terminated C string at `addr` (including its NUL) onto a block.
(cfg
  windows
  (define (process-windows-push-cstr [block : (Array u8)] [addr : i64]) : unit
    (let
      [ptr : (Ptr u8) (process-addr->ptr addr)]
      [i : i64 0]
      [done : bool false]
      (begin
        (while (not done)
          (let
            [byte : i64 (process-byte-at ptr i)]
            (begin
              (array-push! block (cast byte : u8))
              (if (= byte 0)
                (set! done true)
                (set! i (+ i 1))))))
        unit))))

;: Build the double-NUL-terminated CreateProcessA environment block from the
;: inherited environment minus overrides plus the override entries; an empty
;: override list returns 0 so the child inherits the environment.
(cfg
  windows
  (define (process-windows-build-env [env : ProcessEnvList]) : i64
    (let
      [ov : (Array u64) (process-build-override-cstrings env)]
      [ovc : i64 (array-length ov)]
      (if (= ovc 0)
        0
        (let
          [block : (Array u8) (make-array u8 0)]
          [base : (Ptr u8) (process-win-get-environment-strings)]
          [i : i64 0]
          [k : i64 0]
          [done : bool false]
          (begin
            (while (not done)
              (if (= (process-byte-at base i) 0)
                (set! done true)
                (let
                  [entry : (Ptr u8)
                    (unsafe
                      (ptr-offset base i))]
                  [j : i64 i]
                  (begin
                    (while (not (= (process-byte-at base j) 0))
                      (set! j (+ j 1)))
                    (if (not (process-inherited-overridden? entry ov))
                      (process-windows-push-cstr
                        block
                        (unsafe
                          (cast (ptr->int entry) : i64)))
                      unit)
                    (set! i (+ j 1))))))
            (while (< k ovc)
              (begin
                (process-windows-push-cstr block (cast (array-ref ov k) : i64))
                (set! k (+ k 1))))
            (array-push! block (cast 0 : u8))
            (process-array-u8-addr block)))))))

;: Close a Windows handle when it is not INVALID_HANDLE_VALUE.
(cfg
  windows
  (define (process-windows-close-if [handle : i64]) : unit
    (if (= handle -1)
      unit
      (begin
        (io-win-close-handle handle)
        unit))))

;: Create an inheritable, delete-on-close temp file and return its HANDLE, or -1.
(cfg
  windows
  (define (process-windows-make-temp-file) : i64
    (let
      [pathbuf : (Array u8) (make-array u8 320)]
      [namebuf : (Array u8) (make-array u8 320)]
      [prefix : (Array u8) (io-c-string "tlp")]
      [path-len : i32
        (process-win-get-temp-path
          (cast 320 : i32)
          (unsafe
            (array-data pathbuf)))]
      (if (= (cast path-len : i64) 0)
        -1
        (let
          [name-result : i32
            (process-win-get-temp-file-name
              (io-array-const-ptr pathbuf)
              (io-array-const-ptr prefix)
              (cast 0 : i32)
              (unsafe
                (array-data namebuf)))]
          (if (= (cast name-result : i64) 0)
            -1
            (let
              [security : (Array u64) (make-array u64 3)]
              (begin
                (array-set! security 0 (cast 24 : u64))
                (array-set! security 1 (cast 0 : u64))
                (array-set! security 2 (cast 1 : u64))
                (let
                  [handle : i64
                    (io-win-create-file
                      (io-array-const-ptr namebuf)
                      0xc0000000
                      0x3
                      (process-array-u64-addr security)
                      2
                      0x4000100
                      0)]
                  (if (= handle -1)
                    -1
                    handle))))))))))

;: Launch the process with stdout/stderr bound to the temp handles, wait for it
;: to exit, and return the exit code (or -1 when CreateProcessA fails).
(cfg
  windows
  (define (process-windows-create-and-wait
    [appname-addr : i64]
    [cmdline-addr : i64]
    [env-addr : i64]
    [cwd-addr : i64]
    [out-handle : i64]
    [err-handle : i64]) : i64
    (let
      [startup : (Array u64) (make-array u64 13)]
      [procinfo : (Array u64) (make-array u64 3)]
      (begin
        (array-set! startup 0 (cast 104 : u64))
        (array-set! startup 7 (shl (cast 0x100 : u64) 32))
        (array-set!
          startup
          10
          (cast (io-win-get-std-handle (cast -10 : i32)) : u64))
        (array-set! startup 11 (cast out-handle : u64))
        (array-set! startup 12 (cast err-handle : u64))
        (let
          [created : i32
            (process-win-create-process
              appname-addr
              cmdline-addr
              0
              0
              (cast 1 : i32)
              0
              env-addr
              cwd-addr
              (process-array-u64-addr startup)
              (process-array-u64-addr procinfo))]
          (if (= created (cast 0 : i32))
            -1
            (let
              [codebuf : (Array i32) (make-array i32 1)]
              [process-handle : i64 (cast (array-ref procinfo 0) : i64)]
              [thread-handle : i64 (cast (array-ref procinfo 1) : i64)]
              (begin
                (process-win-wait-single process-handle (cast -1 : i32))
                (process-win-get-exit-code
                  process-handle
                  (unsafe
                    (ptr-cast (array-data codebuf) : (MutPtr i32))))
                (io-win-close-handle process-handle)
                (io-win-close-handle thread-handle)
                (cast (array-ref codebuf 0) : i64)))))))))

;: Windows captured-output runtime: redirect stdout/stderr to temp files, run
;: the process to completion, and read the captured output back.
(cfg
  windows
  (define (process-windows-output [command : ProcessCommand]) : ResultProcessOutput
    (let
      [appname-addr : i64
        (process-array-u8-addr
          (io-c-string (process-command-executable command)))]
      [cmdline-addr : i64
        (process-array-u8-addr (io-c-string (process-windows-cmdline command)))]
      [env-addr : i64 (process-windows-build-env (process-command-env command))]
      [cwd-addr : i64
        (process-maybe-cstring-addr (process-command-cwd command))]
      [out-handle : i64 (process-windows-make-temp-file)]
      [err-handle : i64 (process-windows-make-temp-file)]
      (if (or (= out-handle -1) (= err-handle -1))
        (begin
          (process-windows-close-if out-handle)
          (process-windows-close-if err-handle)
          (process-wait-error))
        (let
          [status : i64
            (process-windows-create-and-wait
              appname-addr
              cmdline-addr
              env-addr
              cwd-addr
              out-handle
              err-handle)]
          (if (< status 0)
            (begin
              (process-windows-close-if out-handle)
              (process-windows-close-if err-handle)
              (process-spawn-error))
            (let
              [stdout-text : String (io-read-fd-to-string out-handle)]
              [stderr-text : String (io-read-fd-to-string err-handle)]
              (begin
                (process-windows-close-if out-handle)
                (process-windows-close-if err-handle)
                (OkProcessOutput (ProcessOutput status stdout-text stderr-text))))))))))

;; ---------------------------------------------------------------------------
;; Cross-target runtime entry points consumed by process.tl.
;; ---------------------------------------------------------------------------
;: Run a command and capture stdout, stderr, and exit status.
(define (tl_process_output [command : ProcessCommand]) : ResultProcessOutput
  (cfg windows (process-windows-output command) (process-linux-output command)))

;: Start a command without waiting; Windows reports async as unsupported.
(define (tl_process_start [command : ProcessCommand]) : ResultProcessChild
  (cfg windows (process-async-unsupported-child) (process-linux-start command)))

;: Wait for a started child; Windows reports async as unsupported.
(define (tl_process_wait [child : ProcessChild]) : ResultProcessOutput
  (cfg windows (process-async-unsupported-output) (process-linux-wait child)))
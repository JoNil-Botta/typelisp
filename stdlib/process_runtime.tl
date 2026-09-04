;# stdlib/process_runtime.tl - Process-execution runtime for TypeLisp.
;#
;# Pure-TypeLisp implementations of the `tl_process_output`,
;# `tl_process_inherit`, `tl_process_start`, and `tl_process_wait` runtime
;# helpers that the `tl` API surface calls.
;# These replace the former hand-written backend assembly
;# (`compiler-backend-runtime-process-output-functions` and
;# `compiler-backend-runtime-windows-process-output-functions`): the bodies below
;# issue the same OS calls directly, selecting per-target behavior with
;# `(cfg windows …)`.
;#
;# Linux uses raw syscalls (memfd-captured stdout/stderr, a pipe2 stdin feed, an
;# `execve` failure-marker pipe, vfork/execve, and wait4 exit-status decoding) and
;# fully supports the asynchronous `start`/`wait` pair. Windows uses kernel32
;# (CreateProcessA with temp-file stdout/stderr redirection) for the captured
;# `output` path and reports the asynchronous `start`/`wait` pair as unsupported,
;# matching the previous backend behavior.
;# `inherit` leaves a child attached to the caller's stdout/stderr streams while
;# still waiting for and returning its exit status.
;#
;# Usage: imported by `tl` (which provides the public wrappers).
(import stdlib.byte_buf)
(import stdlib.byte_buf_core)
(import stdlib.env)
(import stdlib.comptime)
(import stdlib.io)
(import stdlib.string)

;; Runtime command storage is arena-backed and immutable after construction.
;; Explicit shallow reads preserve those shared buffers across owner accessors.
;: Return a representation-level shared view of a runtime process value place.
(defmacro (process-runtime-place-shared-view [place : Expr]) : Expr
  (let
    [value-ty : comptime.Expr (comptime.expr-type place)]
    [kind : String (type-kind value-ty)]
    (if (if (string.eq kind "dyn-array")
      true
      (string.eq kind "string"))
      `(let
        [shared-ref (& ,place)]
        (__tl-compiler-owned-shared-view-dyn-ref-as shared-ref ,value-ty))
      `(unsafe
        (ptr-read (ptr-addr-of ,place))))))

;: Runtime argv sequence. Its authoritative count is the backing-array length.
;: `stdlib.process` validates and converts the public model before invoking an
;: unsafe OS entry; source-level construction alone grants no execution access.
(defstruct ProcessRuntimeStringList
  (slots (__tl_dyn-array String)))

;: Runtime optional string value.
(defstruct ProcessRuntimeMaybeString
  (present bool)
  (value String))

;: Runtime environment override entry.
(defstruct ProcessRuntimeEnvEntry
  (name String)
  (value String))

;: Runtime environment override sequence with an authoritative array length.
(defstruct ProcessRuntimeEnvList
  (slots (__tl_dyn-array ProcessRuntimeEnvEntry)))

;: Runtime mirror of the public command-storage count cap. Safe builders reject
;: growth before arithmetic or allocation; unsafe OS entry points additionally
;: require their caller to have run public command validation.
(define process-runtime-storage-max-count : i64
  4096)

;: Cap pointer-vector layouts that include inherited environment entries and
;: trailing nulls. This is larger than the public override/argv cap but keeps
;: host-derived count arithmetic bounded.
(define process-runtime-layout-max-count : i64
  16384)

;: Cap one materialized `NAME=VALUE` buffer after public per-field validation.
(define process-runtime-cstring-max-bytes : i64
  8388608)

;: Add runtime storage counts without overflow or cap bypass.
(define (process-runtime-checked-count-add [left : i64] [right : i64]) : i64
  (if (or
    (< left 0)
    (< right 0)
    (> left process-runtime-storage-max-count)
    (> right (- process-runtime-storage-max-count left)))
    (io.panic "process: command storage limit exceeded")
    (+ left right)))

;: Add pointer-vector layout counts without overflow or host-size amplification.
(define (process-runtime-checked-layout-add [left : i64] [right : i64]) : i64
  (if (or
    (< left 0)
    (< right 0)
    (> left process-runtime-layout-max-count)
    (> right (- process-runtime-layout-max-count left)))
    (io.panic "process: runtime pointer layout limit exceeded")
    (+ left right)))

;: Add C-string buffer lengths without overflow or oversized allocation.
(define (process-runtime-checked-byte-add [left : i64] [right : i64]) : i64
  (if (or
    (< left 0)
    (< right 0)
    (> left process-runtime-cstring-max-bytes)
    (> right (- process-runtime-cstring-max-bytes left)))
    (io.panic "process: runtime string layout limit exceeded")
    (+ left right)))

;: Runtime optional string view.
(defstruct ProcessRuntimeMaybeStringInfo
  (value String)
  (present bool))

;: Runtime command data consumed only across the validated unsafe OS boundary.
(defstruct ProcessRuntimeCommand
  (executable String)
  (argv ProcessRuntimeStringList)
  (cwd ProcessRuntimeMaybeString)
  (env ProcessRuntimeEnvList)
  (stdin ProcessRuntimeMaybeString))

;: Private captured output data.
(defstruct ProcessRuntimeOutput
  (status i64)
  (stdout String)
  (stderr String))

;: Private asynchronous process handle data.
(defstruct ProcessRuntimeChild
  (pid i64)
  (stdout-handle i64)
  (stderr-handle i64))

;: Private structured runtime failures.
(defenum ProcessRuntimeError
  (ProcessRuntimeInvalidCommand String)
  (ProcessRuntimeSpawnFailed String)
  (ProcessRuntimeWaitFailed String)
  (ProcessRuntimeUnsupported String))

;: Private runtime captured-output result.
(defenum ResultProcessRuntimeOutput
  (OkProcessRuntimeOutput ProcessRuntimeOutput)
  (ErrProcessRuntimeOutput ProcessRuntimeError))

;: Private runtime async-start result.
(defenum ResultProcessRuntimeChild
  (OkProcessRuntimeChild ProcessRuntimeChild)
  (ErrProcessRuntimeChild ProcessRuntimeError))

;: Single-pass destructured captured-output result for imported callers.
(defstruct ProcessRuntimeOutputInfo
  (ok bool)
  (kind i64)
  (status i64)
  (stdout String)
  (stderr String)
  (message String))

;: Single-pass destructured child result for imported callers.
(defstruct ProcessRuntimeChildInfo
  (ok bool)
  (kind i64)
  (pid i64)
  (stdout-handle i64)
  (stderr-handle i64)
  (message String))

;: Internal wrapper around a borrowed runtime argument list.
(defstruct ProcessRuntimeStringListRef
  (:lifetimes value)
  (value (& value ProcessRuntimeStringList)))

;: Internal wrapper around a borrowed optional runtime string.
(defstruct ProcessRuntimeMaybeStringRef
  (:lifetimes value)
  (value (& value ProcessRuntimeMaybeString)))

;: Internal wrapper around a borrowed runtime environment list.
(defstruct ProcessRuntimeEnvListRef
  (:lifetimes value)
  (value (& value ProcessRuntimeEnvList)))

;: Internal wrapper around a borrowed runtime environment entry.
(defstruct ProcessRuntimeEnvEntryRef
  (:lifetimes value)
  (value (& value ProcessRuntimeEnvEntry)))

;: Return a checked shared view of a runtime string-array element.
(define (process-runtime-string-array-shared-view
  [items : (& items (__tl_dyn-array String))]
  [index : i64]) : String
  (__tl-compiler-owned-shared-view-dyn-ref-as
    (& (array-ref items index))
    String))

;: Re-expose a borrowed runtime environment entry through the compatibility
;: surface.
(define (process-runtime-env-entry-shared-view
  [value : (& value ProcessRuntimeEnvEntry)]) : ProcessRuntimeEnvEntry
  (let
    [cell : (ProcessRuntimeEnvEntryRef value) (ProcessRuntimeEnvEntryRef value)]
    [address : u64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of cell) : (Ptr u64))))]
    (unsafe
      (ptr-read (int->ptr address : (Ptr ProcessRuntimeEnvEntry))))))

;: Return a checked shared view of a runtime environment-entry array element.
(define (process-runtime-env-array-shared-view
  [items : (& items (__tl_dyn-array ProcessRuntimeEnvEntry))]
  [index : i64]) : ProcessRuntimeEnvEntry
  (process-runtime-env-entry-shared-view (& (array-ref items index))))

;: Re-expose a borrowed runtime argument list through the compatibility surface.
(define (process-runtime-string-list-shared-view
  [value : (& value ProcessRuntimeStringList)]) : ProcessRuntimeStringList
  (let
    [cell : (ProcessRuntimeStringListRef value)
      (ProcessRuntimeStringListRef value)]
    [address : u64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of cell) : (Ptr u64))))]
    (unsafe
      (ptr-read (int->ptr address : (Ptr ProcessRuntimeStringList))))))

;: Re-expose a borrowed optional runtime string through the compatibility surface.
(define (process-runtime-maybe-string-shared-view
  [value : (& value ProcessRuntimeMaybeString)]) : ProcessRuntimeMaybeString
  (let
    [cell : (ProcessRuntimeMaybeStringRef value)
      (ProcessRuntimeMaybeStringRef value)]
    [address : u64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of cell) : (Ptr u64))))]
    (unsafe
      (ptr-read (int->ptr address : (Ptr ProcessRuntimeMaybeString))))))

;: Re-expose a borrowed runtime environment through the compatibility surface.
(define (process-runtime-env-list-shared-view
  [value : (& value ProcessRuntimeEnvList)]) : ProcessRuntimeEnvList
  (let
    [cell : (ProcessRuntimeEnvListRef value) (ProcessRuntimeEnvListRef value)]
    [address : u64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of cell) : (Ptr u64))))]
    (unsafe
      (ptr-read (int->ptr address : (Ptr ProcessRuntimeEnvList))))))

;: Return an empty runtime argv list.
(define (args-empty) : ProcessRuntimeStringList
  (ProcessRuntimeStringList (__tl_make-array String 0)))

;: Prepend an owned argv string, copying `rest` into a right-sized array.
(define (args-cons [value : String] [rest : ProcessRuntimeStringList]) : ProcessRuntimeStringList
  (let
    [len : i64 (array-length rest.slots)]
    [next : i64 (process-runtime-checked-count-add len 1)]
    [slots : (__tl_dyn-array String) (__tl_make-array String next)]
    [index : i64 0]
    (begin
      (set! (array-ref slots 0) value)
      (while (< index len)
        (begin
          (set!
            (array-ref slots (+ index 1))
            (process-runtime-string-array-shared-view (& rest.slots) index))
          (set! index (+ index 1))))
      (ProcessRuntimeStringList slots))))

;: Return an empty runtime environment override list.
(define (env-empty) : ProcessRuntimeEnvList
  (ProcessRuntimeEnvList (__tl_make-array ProcessRuntimeEnvEntry 0)))

;: Prepend an owned environment override, copying `rest` into a right-sized
;: array.
(define (env-cons
  [name : String]
  [value : String]
  [rest : ProcessRuntimeEnvList]) : ProcessRuntimeEnvList
  (let
    [len : i64 (array-length rest.slots)]
    [next : i64 (process-runtime-checked-count-add len 1)]
    [slots : (__tl_dyn-array ProcessRuntimeEnvEntry)
      (__tl_make-array ProcessRuntimeEnvEntry next)]
    [index : i64 0]
    (begin
      (set! (array-ref slots 0) (ProcessRuntimeEnvEntry name value))
      (while (< index len)
        (begin
          (set!
            (array-ref slots (+ index 1))
            (process-runtime-env-array-shared-view (& rest.slots) index))
          (set! index (+ index 1))))
      (ProcessRuntimeEnvList slots))))

;: Return a missing runtime optional string.
(define (no-string) : ProcessRuntimeMaybeString
  (ProcessRuntimeMaybeString false ""))

;: Return a present runtime optional string.
(define (some-string [value : String]) : ProcessRuntimeMaybeString
  (ProcessRuntimeMaybeString true value))

;: Construct a private runtime command.
(define (command-full
  [executable : String]
  [argv : ProcessRuntimeStringList]
  [cwd : ProcessRuntimeMaybeString]
  [env : ProcessRuntimeEnvList]
  [stdin : ProcessRuntimeMaybeString]) : ProcessRuntimeCommand
  (ProcessRuntimeCommand executable argv cwd env stdin))

;: Construct a private runtime child handle.
(define (child [pid : i64] [stdout-handle : i64] [stderr-handle : i64]) : ProcessRuntimeChild
  (ProcessRuntimeChild pid stdout-handle stderr-handle))

;: Return the number of runtime argv entries.
(define (args-count [args : (& args ProcessRuntimeStringList)]) : i64
  (array-length args.slots))

;: Return a destructured optional string.
(define (maybe-string-info [value : ProcessRuntimeMaybeString]) : ProcessRuntimeMaybeStringInfo
  (ProcessRuntimeMaybeStringInfo value.value value.present))

;: Return whether a destructured optional string is present.
(define (maybe-string-info-present?
  [info : (& info ProcessRuntimeMaybeStringInfo)]) : bool
  info.present)

;: Return the string from a destructured optional string.
(define (maybe-string-info-value
  [info : (& info ProcessRuntimeMaybeStringInfo)]) : String
  (__tl-compiler-owned-shared-view-dyn-ref-as (& info.value) String))

;: Return the executable path from a runtime command.
(define (command-executable [command : (& command ProcessRuntimeCommand)]) : String
  (__tl-compiler-owned-shared-view-dyn-ref-as (& command.executable) String))

;: Return the argv list from a runtime command.
(define (command-argv [command : (& command ProcessRuntimeCommand)]) : ProcessRuntimeStringList
  (process-runtime-string-list-shared-view (& command.argv)))

;: Return the cwd setting from a runtime command.
(define (command-cwd [command : (& command ProcessRuntimeCommand)]) : ProcessRuntimeMaybeString
  (process-runtime-maybe-string-shared-view (& command.cwd)))

;: Return the environment override list from a runtime command.
(define (command-env [command : (& command ProcessRuntimeCommand)]) : ProcessRuntimeEnvList
  (process-runtime-env-list-shared-view (& command.env)))

;: Return the stdin setting from a runtime command.
(define (command-stdin [command : (& command ProcessRuntimeCommand)]) : ProcessRuntimeMaybeString
  (process-runtime-maybe-string-shared-view (& command.stdin)))

;: Construct a successful captured-output runtime result.
(define (output-ok [status : i64] [stdout : String] [stderr : String]) : ResultProcessRuntimeOutput
  (OkProcessRuntimeOutput (ProcessRuntimeOutput status stdout stderr)))

;: Construct a successful child runtime result.
(define (child-ok [pid : i64] [stdout-handle : i64] [stderr-handle : i64]) : ResultProcessRuntimeChild
  (OkProcessRuntimeChild (ProcessRuntimeChild pid stdout-handle stderr-handle)))

;: Construct a runtime output error result.
(define (output-error [error : ProcessRuntimeError]) : ResultProcessRuntimeOutput
  (ErrProcessRuntimeOutput error))

;: Construct a runtime child error result.
(define (child-error [error : ProcessRuntimeError]) : ResultProcessRuntimeChild
  (ErrProcessRuntimeChild error))

;: Construct a spawn-failure runtime output result.
(define (output-spawn-failed [message : String]) : ResultProcessRuntimeOutput
  (ErrProcessRuntimeOutput (ProcessRuntimeSpawnFailed message)))

;: Construct a wait-failure runtime output result.
(define (output-wait-failed [message : String]) : ResultProcessRuntimeOutput
  (ErrProcessRuntimeOutput (ProcessRuntimeWaitFailed message)))

;: Construct an unsupported runtime output result.
(define (output-unsupported [message : String]) : ResultProcessRuntimeOutput
  (ErrProcessRuntimeOutput (ProcessRuntimeUnsupported message)))

;: Construct a spawn-failure runtime child result.
(define (child-spawn-failed [message : String]) : ResultProcessRuntimeChild
  (ErrProcessRuntimeChild (ProcessRuntimeSpawnFailed message)))

;: Construct a wait-failure runtime child result.
(define (child-wait-failed [message : String]) : ResultProcessRuntimeChild
  (ErrProcessRuntimeChild (ProcessRuntimeWaitFailed message)))

;: Construct an unsupported runtime child result.
(define (child-unsupported [message : String]) : ResultProcessRuntimeChild
  (ErrProcessRuntimeChild (ProcessRuntimeUnsupported message)))

;: Return true when a runtime output result is an `Ok`.
(define (result-output-ok? [result : ResultProcessRuntimeOutput]) : bool
  (match result
    [(OkProcessRuntimeOutput _) true]
    [(ErrProcessRuntimeOutput _) false]))

;: Return captured status, or `fallback` when `result` is an error.
(define (result-status-or
  [result : ResultProcessRuntimeOutput]
  [fallback : i64]) : i64
  (match result
    [(OkProcessRuntimeOutput output) output.status]
    [(ErrProcessRuntimeOutput _) fallback]))

;: Return an error kind code, or `fallback` when `result` is ok.
(define (result-error-kind-or
  [result : ResultProcessRuntimeOutput]
  [fallback : i64]) : i64
  (match result
    [(OkProcessRuntimeOutput _) fallback]
    [(ErrProcessRuntimeOutput error)
      (match error
        [(ProcessRuntimeInvalidCommand _) 0]
        [(ProcessRuntimeSpawnFailed _) 1]
        [(ProcessRuntimeWaitFailed _) 2]
        [(ProcessRuntimeUnsupported _) 3])]))

;: Return an error message, or `fallback` when `result` is ok.
(define (result-error-message-or
  [result : ResultProcessRuntimeOutput]
  [fallback : String]) : String
  (match result
    [(OkProcessRuntimeOutput _) fallback]
    [(ErrProcessRuntimeOutput error)
      (match error
        [(ProcessRuntimeInvalidCommand message) message]
        [(ProcessRuntimeSpawnFailed message) message]
        [(ProcessRuntimeWaitFailed message) message]
        [(ProcessRuntimeUnsupported message) message])]))

;: Destructure a runtime captured-output result in one pass.
(define (result-output-info [result : ResultProcessRuntimeOutput]) : ProcessRuntimeOutputInfo
  (match result
    [(OkProcessRuntimeOutput output)
      (ProcessRuntimeOutputInfo
        true
        0
        output.status
        output.stdout
        output.stderr
        "")]
    [(ErrProcessRuntimeOutput error)
      (match error
        [(ProcessRuntimeInvalidCommand message)
          (ProcessRuntimeOutputInfo false 0 (- 0 1) "" "" message)]
        [(ProcessRuntimeSpawnFailed message)
          (ProcessRuntimeOutputInfo false 1 (- 0 1) "" "" message)]
        [(ProcessRuntimeWaitFailed message)
          (ProcessRuntimeOutputInfo false 2 (- 0 1) "" "" message)]
        [(ProcessRuntimeUnsupported message)
          (ProcessRuntimeOutputInfo false 3 (- 0 1) "" "" message)])]))

;: Return true when a runtime child result is an `Ok`.
(define (result-child-ok? [result : ResultProcessRuntimeChild]) : bool
  (match result
    [(OkProcessRuntimeChild _) true]
    [(ErrProcessRuntimeChild _) false]))

;: Return the child pid, or `fallback` when `result` is an error.
(define (child-result-pid-or
  [result : ResultProcessRuntimeChild]
  [fallback : i64]) : i64
  (match result
    [(OkProcessRuntimeChild child) child.pid]
    [(ErrProcessRuntimeChild _) fallback]))

;: Return a child-result error kind code, or `fallback` when `result` is ok.
(define (child-result-error-kind-or
  [result : ResultProcessRuntimeChild]
  [fallback : i64]) : i64
  (match result
    [(OkProcessRuntimeChild _) fallback]
    [(ErrProcessRuntimeChild error)
      (match error
        [(ProcessRuntimeInvalidCommand _) 0]
        [(ProcessRuntimeSpawnFailed _) 1]
        [(ProcessRuntimeWaitFailed _) 2]
        [(ProcessRuntimeUnsupported _) 3])]))

;: Return a child-result error message, or `fallback` when `result` is ok.
(define (child-result-error-message-or
  [result : ResultProcessRuntimeChild]
  [fallback : String]) : String
  (match result
    [(OkProcessRuntimeChild _) fallback]
    [(ErrProcessRuntimeChild error)
      (match error
        [(ProcessRuntimeInvalidCommand message) message]
        [(ProcessRuntimeSpawnFailed message) message]
        [(ProcessRuntimeWaitFailed message) message]
        [(ProcessRuntimeUnsupported message) message])]))

;: Destructure a runtime child result in one pass.
(define (result-child-info [result : ResultProcessRuntimeChild]) : ProcessRuntimeChildInfo
  (match result
    [(OkProcessRuntimeChild child)
      (ProcessRuntimeChildInfo
        true
        0
        child.pid
        child.stdout-handle
        child.stderr-handle
        "")]
    [(ErrProcessRuntimeChild error)
      (match error
        [(ProcessRuntimeInvalidCommand message)
          (ProcessRuntimeChildInfo false 0 (- 0 1) (- 0 1) (- 0 1) message)]
        [(ProcessRuntimeSpawnFailed message)
          (ProcessRuntimeChildInfo false 1 (- 0 1) (- 0 1) (- 0 1) message)]
        [(ProcessRuntimeWaitFailed message)
          (ProcessRuntimeChildInfo false 2 (- 0 1) (- 0 1) (- 0 1) message)]
        [(ProcessRuntimeUnsupported message)
          (ProcessRuntimeChildInfo false 3 (- 0 1) (- 0 1) (- 0 1) message)])]))

(import stdlib.str_cat)

;; `stdlib.process_borrowed` still resolves legacy unqualified string inspection
;; helpers through this compatibility import.
;; lint-allow: unused-import
(import stdlib.string)
(import stdlib.text_buf)

;: Linux inherited environment array (NUL-terminated `char**`). On the freestanding
;: Linux entry the kernel lays out `argc`, `argv[0..]`, a NULL, then `envp[0..]`
;: on the initial stack, so `envp` is `&argv[argc + 1]`. Computed from the
;: `program-argv`/`program-argc` builtins (no new backend symbol — keeps the
;: seed bootstrap working).
(define (linux-envp) : (Ptr (Ptr u8))
  (unsafe
    (env.linux-environ)))

;: Windows kernel32 bindings used by the captured-output path. Referenced only
;: from the Windows branch.
(cfg
  windows
  (unsafe
    (extern (win-get-environment-strings) : (Ptr u8) (:symbol "GetEnvironmentStringsA"))))

(cfg
  windows
  (unsafe
    (extern (win-get-temp-path [arg0 : i32] [arg1 : (MutPtr u8)]) : i32 (:symbol "GetTempPathA"))))

(cfg
  windows
  (unsafe
    (extern (win-get-temp-file-name
      [arg0 : (Ptr u8)]
      [arg1 : (Ptr u8)]
      [arg2 : i32]
      [arg3 : (MutPtr u8)]) : i32 (:symbol "GetTempFileNameA"))))

(cfg
  windows
  (unsafe
    (extern (win-create-process
      [arg0 : i64]
      [arg1 : i64]
      [arg2 : i64]
      [arg3 : i64]
      [arg4 : i32]
      [arg5 : i64]
      [arg6 : i64]
      [arg7 : i64]
      [arg8 : i64]
      [arg9 : i64]) : i32 (:symbol "CreateProcessA"))))

(cfg
  windows
  (unsafe
    (extern (win-wait-single [arg0 : i64] [arg1 : i32]) : i32 (:symbol "WaitForSingleObject"))))

(cfg
  windows
  (unsafe
    (extern (win-get-exit-code [arg0 : i64] [arg1 : (MutPtr i32)]) : i32 (:symbol "GetExitCodeProcess"))))

(cfg
  windows
  (define (windows-exit-dword->status [code : i32]) : i64
    ;; Conversion policy: GetExitCodeProcess yields an unsigned 32-bit DWORD.
    ;; The public i64 status is its zero-extended value (0..0xFFFFFFFF), so a
    ;; completed child always reports a non-negative status -- including
    ;; high-bit NTSTATUS terminations such as 0xC0000005 -- and the internal
    ;; -1 spawn-failure sentinel never collides with a valid exit code.
    (bit-and (cast code : i64) 4294967295)))

(cfg
  windows
  (unsafe
    (extern (win-create-file
      [arg0 : (Ptr u8)]
      [arg1 : i64]
      [arg2 : i64]
      [arg3 : i64]
      [arg4 : i64]
      [arg5 : i64]
      [arg6 : i64]) : i64 (:symbol "CreateFileA"))))

(cfg
  windows
  (unsafe
    (extern (win-read-file
      [arg0 : i64]
      [arg1 : (MutPtr u8)]
      [arg2 : i32]
      [arg3 : (MutPtr i32)]
      [arg4 : i64]) : i32 (:symbol "ReadFile"))))

(cfg
  windows
  (unsafe
    (extern (win-set-file-pointer-ex
      [arg0 : i64]
      [arg1 : i64]
      [arg2 : (MutPtr i64)]
      [arg3 : i32]) : i32 (:symbol "SetFilePointerEx"))))

(cfg
  windows
  (unsafe
    (extern (win-close-handle [arg0 : i64]) : i32 (:symbol "CloseHandle"))))

(cfg
  windows
  (unsafe
    (extern (win-get-std-handle [arg0 : i32]) : i64 (:symbol "GetStdHandle"))))

(cfg
  windows
  (unsafe
    (extern (win-get-current-process) : i64 (:symbol "GetCurrentProcess"))))

(cfg
  windows
  (unsafe
    (extern (win-duplicate-handle
      [source-process : i64]
      [source-handle : i64]
      [target-process : i64]
      [target-handle : (MutPtr i64)]
      [desired-access : i64]
      [inherit-handle : i32]
      [options : i32]) : i32 (:symbol "DuplicateHandle"))))

;: Shared spawn-failure result for the captured-output path.
(define (spawn-error) : ResultProcessRuntimeOutput
  (stdlib.process_runtime.output-spawn-failed "process: spawn failed"))

;: Shared wait-failure result for the captured-output path.
(define (wait-error) : ResultProcessRuntimeOutput
  (stdlib.process_runtime.output-wait-failed "process: wait failed"))

;: Shared spawn-failure result for the asynchronous start path.
(define (spawn-error-child) : ResultProcessRuntimeChild
  (stdlib.process_runtime.child-spawn-failed "process: spawn failed"))

;: Shared wait-failure result for the asynchronous start path.
(define (wait-error-child) : ResultProcessRuntimeChild
  (stdlib.process_runtime.child-wait-failed "process: wait failed"))

;: Async-unsupported result for `start` on runtimes without child handles.
(define (async-unsupported-child) : ResultProcessRuntimeChild
  (stdlib.process_runtime.child-unsupported
    "process: async child handles are not supported by this runtime"))

;: Async-unsupported result for `wait` on runtimes without child handles.
(define (async-unsupported-output) : ResultProcessRuntimeOutput
  (stdlib.process_runtime.output-unsupported
    "process: async child handles are not supported by this runtime"))

;: Return the integer address of private byte storage.
(define (array-u8-addr [buf : (__tl_dyn-array u8)]) : i64
  (unsafe
    (cast (ptr->int (ptr-cast (__tl_array-data buf) : (Ptr u8))) : i64)))

;: Return the integer address of a byte-builder snapshot backing buffer.
(cfg
  windows
  (define (byte-builder-addr [buf : byte_buf_core.ByteBufBuilder]) : i64
    (let
      [bytes : (__tl_dyn-array u8)
        (byte_buf_core.byte-buf-builder-finish-array (& buf))]
      (stdlib.process_runtime.array-u8-addr bytes))))

;: Return the integer address of private `u64` storage.
(define (array-u64-addr [buf : (__tl_dyn-array u64)]) : i64
  (unsafe
    (cast (ptr->int (ptr-cast (__tl_array-data buf) : (Ptr u8))) : i64)))

;: Return the integer address of private `i32` storage.
(define (array-i32-addr [buf : (__tl_dyn-array i32)]) : i64
  (unsafe
    (cast (ptr->int (ptr-cast (__tl_array-data buf) : (Ptr u8))) : i64)))

;: Read the unsigned byte at `index` of a C string as an i64.
(unsafe
  (define (byte-at [ptr : (Ptr u8)] [index : i64]) : i64
    (cast
      (unsafe
        (ptr-read (ptr-offset ptr index)))
      : i64)))

;: Convert an integer address into a read-only byte pointer.
(define (addr->ptr [addr : i64]) : (Ptr u8)
  (unsafe
    (int->ptr (cast addr : u64) : (Ptr u8))))

;: Return true when inherited entry `entry` and override entry `override` (both
;: `NAME=VALUE` C strings) share the same NAME (compared up to the override `=`).
(unsafe
  (define (cstr-name-matches? [entry : (Ptr u8)] [override : (Ptr u8)]) : bool
    (unsafe
      (let
        [i : i64 0]
        [matched : bool false]
        [decided : bool false]
        (begin
          (while (not decided)
            (let
              [oc : i64 (stdlib.process_runtime.byte-at override i)]
              (if (= oc 61)
                (begin
                  (set! matched (= (stdlib.process_runtime.byte-at entry i) 61))
                  (set! decided true))
                (if (= (stdlib.process_runtime.byte-at entry i) oc)
                  (set! i (+ i 1))
                  (begin
                    (set! matched false)
                    (set! decided true))))))
          matched)))))

;: Return true when inherited entry `entry` is overridden by any address in `ov`
;: (private storage of override `NAME=VALUE` C string addresses).
(unsafe
  (define (inherited-overridden?
    [entry : (Ptr u8)]
    [ov : (& ov (__tl_dyn-array u64))]) : bool
    (let
      [n : i64 (array-length ov)]
      [i : i64 0]
      [found : bool false]
      (begin
        (while (and (not found) (< i n))
          (if (unsafe
            (stdlib.process_runtime.cstr-name-matches?
              entry
              (stdlib.process_runtime.addr->ptr (cast (array-ref ov i) : i64))))
            (set! found true)
            (set! i (+ i 1))))
        found))))

;: Build a NUL-terminated `NAME=VALUE` C string for an env override.
(unsafe
  (define (env-cstring [name : String] [value : String]) : (__tl_dyn-array u8)
    (let
      [nl : i64 (string-length name)]
      [vl : i64 (string-length value)]
      [payload : i64 (process-runtime-checked-byte-add nl vl)]
      [capacity : i64 (process-runtime-checked-byte-add payload 2)]
      [buf : byte_buf_core.ByteBufBuilder
        (byte_buf_core.byte-buf-builder-with-capacity capacity)]
      [i : i64 0]
      (begin
        (while (< i nl)
          (begin
            (byte_buf_core.byte-buf-builder-push
              (&mut buf)
              (cast (string-ref name i) : u8))
            (set! i (+ i 1))))
        (byte_buf_core.byte-buf-builder-push (&mut buf) (cast 61 : u8))
        (set! i 0)
        (while (< i vl)
          (begin
            (byte_buf_core.byte-buf-builder-push
              (&mut buf)
              (cast (string-ref value i) : u8))
            (set! i (+ i 1))))
        (byte_buf_core.byte-buf-builder-push (&mut buf) (cast 0 : u8))
        (byte_buf_core.byte-buf-builder-finish-array (& buf))))))

;: Materialize the override list into an array of `NAME=VALUE` C string
;: addresses. The move-only `env` list is consumed exactly once here so the
;: resulting array can be scanned repeatedly without further moves.
(unsafe
  (define (build-override-cstrings [env : ProcessRuntimeEnvList]) : (__tl_dyn-array
      u64)
    (let
      [count : i64 (array-length env.slots)]
      [ov : (__tl_dyn-array u64) (__tl_make-array u64 count)]
      [index : i64 0]
      (begin
        (while (< index count)
          (let
            [entry : ProcessRuntimeEnvEntry
              (process-runtime-env-array-shared-view (& env.slots) index)]
            (begin
              (set!
                (array-ref ov index)
                (unsafe
                  (cast
                    (ptr->int
                      (io.array-const-ptr
                        (stdlib.process_runtime.env-cstring
                          entry.name
                          entry.value)))
                    : u64)))
              (set! index (+ index 1)))))
        ov))))

;: Return the integer address of an optional command path C string, or 0.
(unsafe
  (define (maybe-cstring-addr [value : ProcessRuntimeMaybeString]) : i64
    (let
      [info : ProcessRuntimeMaybeStringInfo
        (stdlib.process_runtime.maybe-string-info value)]
      (if (stdlib.process_runtime.maybe-string-info-present? info)
        (stdlib.process_runtime.array-u8-addr
          (io.c-string (stdlib.process_runtime.maybe-string-info-value info)))
        0))))

;: Return true when an optional stdin value provides input.
(define (maybe-present? [value : ProcessRuntimeMaybeString]) : bool
  value.present)

;: Return the integer address of an optional stdin string's byte storage, or 0.
(define (maybe-data-addr [value : ProcessRuntimeMaybeString]) : i64
  (let
    [info : ProcessRuntimeMaybeStringInfo
      (stdlib.process_runtime.maybe-string-info value)]
    (if (stdlib.process_runtime.maybe-string-info-present? info)
      (let
        [text : String (stdlib.process_runtime.maybe-string-info-value info)]
        (unsafe
          (cast (ptr->int (string-data text)) : i64)))
      0)))

;: Return the byte length of an optional stdin string, or 0.
(define (maybe-len [value : ProcessRuntimeMaybeString]) : i64
  (let
    [info : ProcessRuntimeMaybeStringInfo
      (stdlib.process_runtime.maybe-string-info value)]
    (if (stdlib.process_runtime.maybe-string-info-present? info)
      (__tl_string_length (stdlib.process_runtime.maybe-string-info-value info))
      0)))

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
  (failed bool)
  (failure-result i64))

;: Spawn state for a child that inherits the caller's stdout and stderr.
;: It omits capture descriptors while retaining the stdin and exec-failure
;: plumbing needed by the regular Linux process path.
(defstruct ProcessLinuxInheritedSpawn
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
  (exec-r i64)
  (exec-w i64)
  (failed bool)
  (failure-result i64))

;: Exact parent-side interpretation of the close-on-exec status channel.
(defenum ProcessLinuxExecStatus
  (ProcessLinuxExecSucceeded)
  (ProcessLinuxExecChildFailed i64)
  (ProcessLinuxExecChannelFailed i64))

;: Exec-channel interpretation plus the independent one-shot close outcome.
(defstruct ProcessLinuxExecOutcome
  (status ProcessLinuxExecStatus)
  (close-result i64))

;: Typed result of reading one seekable captured stream.
(defenum ProcessLinuxCaptureResult
  (ProcessLinuxCaptureOk byte_buf.ByteBuf)
  (ProcessLinuxCaptureFailed i64))

;: First execution failure plus the first later cleanup failure. Raw negative
;: syscall results stay private and no acquired descriptor or child identity is
;: retained in diagnostics.
(defstruct ProcessLinuxFailure
  (primary-operation i64)
  (primary-result i64)
  (secondary-operation i64)
  (secondary-result i64))

;: No Linux process operation has failed.
(define process-linux-operation-none : i64
  0)

;: Pre-spawn descriptor setup or `vfork` failed.
(define process-linux-operation-spawn : i64
  1)

;: A required child-side setup syscall failed before `execve`.
(define process-linux-operation-child-setup : i64
  2)

;: `execve` returned in the child.
(define process-linux-operation-exec : i64
  3)

;: The parent could not prove the exact exec-status protocol.
(define process-linux-operation-exec-channel : i64
  4)

;: Feeding the configured stdin bytes failed.
(define process-linux-operation-stdin : i64
  5)

;: Reaping the child failed.
(define process-linux-operation-wait : i64
  6)

;: Captured stdout could not be read exactly.
(define process-linux-operation-stdout : i64
  7)

;: Captured stderr could not be read exactly.
(define process-linux-operation-stderr : i64
  8)

;: Closing one owned descriptor failed.
(define process-linux-operation-close : i64
  9)

;: Child failure stage for closing the parent's exec-status read descriptor.
(define process-linux-child-stage-close-exec-read : i64
  1)

;: Child failure stage for closing the parent's stdin write descriptor.
(define process-linux-child-stage-close-stdin-write : i64
  2)

;: Child failure stage for duplicating the configured stdin descriptor.
(define process-linux-child-stage-dup-stdin : i64
  3)

;: Child failure stage for closing the child's original stdin descriptor.
(define process-linux-child-stage-close-stdin-read : i64
  4)

;: Child failure stage for duplicating the stdout capture descriptor.
(define process-linux-child-stage-dup-stdout : i64
  5)

;: Child failure stage for duplicating the stderr capture descriptor.
(define process-linux-child-stage-dup-stderr : i64
  6)

;: Child failure stage for closing the original stdout capture descriptor.
(define process-linux-child-stage-close-stdout : i64
  7)

;: Child failure stage for closing the original stderr capture descriptor.
(define process-linux-child-stage-close-stderr : i64
  8)

;: Child failure stage for changing to the configured working directory.
(define process-linux-child-stage-chdir : i64
  9)

;: Child failure stage for executing the configured program.
(define process-linux-child-stage-exec : i64
  10)

;: Fault-hook ID for creating a parent-side pipe.
(define process-linux-syscall-pipe : i64
  1)

;: Fault-hook ID for creating a parent-side memory file.
(define process-linux-syscall-memfd : i64
  2)

;: Fault-hook ID for creating the child with `vfork`.
(define process-linux-syscall-vfork : i64
  3)

;: Fault-hook ID for closing a parent-owned descriptor.
(define process-linux-syscall-close : i64
  4)

;: Fault-hook ID for writing configured stdin bytes.
(define process-linux-syscall-stdin-write : i64
  5)

;: Fault-hook ID for reading the exec-status channel.
(define process-linux-syscall-exec-read : i64
  6)

;: Fault-hook ID for reaping a child.
(define process-linux-syscall-wait : i64
  7)

;: Fault-hook ID for seeking a captured output memory file.
(define process-linux-syscall-capture-seek : i64
  8)

;: Fault-hook ID for reading a captured output memory file.
(define process-linux-syscall-capture-read : i64
  9)

;: Fault-hook ID for changing the parent signal disposition.
(define process-linux-syscall-sigaction : i64
  10)

;: Fault-hook ID for the child closing the exec-status read descriptor.
(define process-linux-child-syscall-close-exec-read : i64
  1)

;: Fault-hook ID for the child closing the stdin write descriptor.
(define process-linux-child-syscall-close-stdin-write : i64
  2)

;: Fault-hook ID for the child duplicating its stdin descriptor.
(define process-linux-child-syscall-dup-stdin : i64
  3)

;: Fault-hook ID for the child closing its original stdin descriptor.
(define process-linux-child-syscall-close-stdin-read : i64
  4)

;: Fault-hook ID for the child duplicating its stdout descriptor.
(define process-linux-child-syscall-dup-stdout : i64
  5)

;: Fault-hook ID for the child duplicating its stderr descriptor.
(define process-linux-child-syscall-dup-stderr : i64
  6)

;: Fault-hook ID for the child closing its original stdout descriptor.
(define process-linux-child-syscall-close-stdout : i64
  7)

;: Fault-hook ID for the child closing its original stderr descriptor.
(define process-linux-child-syscall-close-stderr : i64
  8)

;: Fault-hook ID for the child changing its working directory.
(define process-linux-child-syscall-chdir : i64
  9)

;: Fault-hook ID for the child's `execve` call.
(define process-linux-child-syscall-exec : i64
  10)

;: Sentinel distinct from every Linux syscall result.
(define process-linux-no-injection : i64
  -9223372036854775808)

; Fault injection is compiled only into the dedicated native Linux gate.
(cfg
  process-linux-test-hooks
  (define process-linux-test-counts : (__tl_dyn-array i64)
    (__tl_make-array i64 16)))
(cfg
  process-linux-test-hooks
  (define process-linux-test-fail-kind-a : i64
    0))
(cfg
  process-linux-test-hooks
  (define process-linux-test-fail-call-a : i64
    0))
(cfg
  process-linux-test-hooks
  (define process-linux-test-fail-errno-a : i64
    0))
(cfg
  process-linux-test-hooks
  (define process-linux-test-fail-kind-b : i64
    0))
(cfg
  process-linux-test-hooks
  (define process-linux-test-fail-call-b : i64
    0))
(cfg
  process-linux-test-hooks
  (define process-linux-test-fail-errno-b : i64
    0))
(cfg
  process-linux-test-hooks
  (define process-linux-test-write-max : i64
    0))
(cfg
  process-linux-test-hooks
  (define process-linux-test-read-max : i64
    0))
(cfg
  process-linux-test-hooks
  (define process-linux-test-child-fail-kind : i64
    0))
(cfg
  process-linux-test-hooks
  (define process-linux-test-child-fail-errno : i64
    0))
(cfg
  process-linux-test-hooks
  (define process-linux-test-marker-mode : i64
    0))

;: Reset all Linux process fault hooks and parent-side call counters.
(cfg
  process-linux-test-hooks
  (define (linux-test-reset!) : unit
    (let
      [index : i64 0]
      (begin
        (while (< index (array-length process-linux-test-counts))
          (begin
            (set! (array-ref process-linux-test-counts index) 0)
            (set! index (+ index 1))))
        (set! process-linux-test-fail-kind-a 0)
        (set! process-linux-test-fail-call-a 0)
        (set! process-linux-test-fail-errno-a 0)
        (set! process-linux-test-fail-kind-b 0)
        (set! process-linux-test-fail-call-b 0)
        (set! process-linux-test-fail-errno-b 0)
        (set! process-linux-test-write-max 0)
        (set! process-linux-test-read-max 0)
        (set! process-linux-test-child-fail-kind 0)
        (set! process-linux-test-child-fail-errno 0)
        (set! process-linux-test-marker-mode 0)))))

;: Inject one raw negative errno on a numbered parent-side syscall attempt.
(cfg
  process-linux-test-hooks
  (define (linux-test-fail-on! [kind : i64] [call : i64] [errno-code : i64]) : unit
    (begin
      (set! process-linux-test-fail-kind-a kind)
      (set! process-linux-test-fail-call-a call)
      (set! process-linux-test-fail-errno-a errno-code))))

;: Configure an independent second injected parent-side failure.
(cfg
  process-linux-test-hooks
  (define (linux-test-fail-second-on!
    [kind : i64]
    [call : i64]
    [errno-code : i64]) : unit
    (begin
      (set! process-linux-test-fail-kind-b kind)
      (set! process-linux-test-fail-call-b call)
      (set! process-linux-test-fail-errno-b errno-code))))

;: Inject one child-side setup/exec failure without mutating parent storage.
(cfg
  process-linux-test-hooks
  (define (linux-test-child-fail-on! [kind : i64] [errno-code : i64]) : unit
    (begin
      (set! process-linux-test-child-fail-kind kind)
      (set! process-linux-test-child-fail-errno errno-code))))

;: Bound real stdin writes to force partial-progress coverage.
(cfg
  process-linux-test-hooks
  (define (linux-test-set-write-max! [count : i64]) : unit
    (set! process-linux-test-write-max count)))

;: Bound real exec/capture reads to force partial-progress coverage.
(cfg
  process-linux-test-hooks
  (define (linux-test-set-read-max! [count : i64]) : unit
    (set! process-linux-test-read-max count)))

;: Select malformed child failure-record modes for the exec-channel gate.
(cfg
  process-linux-test-hooks
  (define (linux-test-set-marker-mode! [mode : i64]) : unit
    (set! process-linux-test-marker-mode mode)))

;: Return one parent-side syscall call count.
(cfg
  process-linux-test-hooks
  (define (linux-test-call-count [kind : i64]) : i64
    (if (and (>= kind 0) (< kind (array-length process-linux-test-counts)))
      (array-ref process-linux-test-counts kind)
      0)))

;: Count open descriptors below `limit` without going through an injected
;: process syscall. The native fault gate compares this stable count after each
;: failed operation and its successful follow-up.
(cfg
  process-linux-test-hooks
  (define (linux-test-open-fd-count [limit : i64]) : i64
    (let
      [fd : i64 0]
      [count : i64 0]
      (begin
        (while (< fd limit)
          (begin
            (if (>=
              (unsafe
                (syscall 72 fd 1))
              0)
              (set! count (+ count 1))
              unit)
            (set! fd (+ fd 1))))
        count))))

;: Prove that the caller owns no running or waitable child. A leaked zombie is
;: reaped while returning false so one failed assertion cannot poison the rest
;: of the deterministic gate.
(cfg
  process-linux-test-hooks
  (define (linux-test-no-children?) : bool
    (let
      [status : (__tl_dyn-array i32) (__tl_make-array i32 1)]
      [result : i64 -4]
      (begin
        (while (= result -4)
          (set!
            result
            (unsafe
              (syscall
                61
                -1
                (stdlib.process_runtime.array-i32-addr
                  (process-runtime-place-shared-view status))
                1
                0))))
        (= result -10)))))

;: Record a parent-side syscall and select either configured failure.
(cfg
  process-linux-test-hooks
  (define (linux-test-injected-result [kind : i64]) : i64
    (let
      [call : i64 (+ (array-ref process-linux-test-counts kind) 1)]
      (begin
        (set! (array-ref process-linux-test-counts kind) call)
        (cond
          [(and
              (= kind process-linux-test-fail-kind-a)
              (= call process-linux-test-fail-call-a))
            (- 0 process-linux-test-fail-errno-a)]
          [(and
              (= kind process-linux-test-fail-kind-b)
              (= call process-linux-test-fail-call-b))
            (- 0 process-linux-test-fail-errno-b)]
          [else process-linux-no-injection])))))

;: Production-erased bridge to the optional parent-side injection state.
(define (linux-injected-result [_kind : i64]) : i64
  (cfg
    process-linux-test-hooks
    (linux-test-injected-result _kind)
    process-linux-no-injection))

;: Production-erased bound for deterministic short writes.
(define (linux-write-request-count [count : i64]) : i64
  (cfg
    process-linux-test-hooks
    (if (and
      (> process-linux-test-write-max 0)
      (> count process-linux-test-write-max))
      process-linux-test-write-max
      count)
    count))

;: Production-erased bound for deterministic short reads.
(define (linux-read-request-count [count : i64]) : i64
  (cfg
    process-linux-test-hooks
    (if (and
      (> process-linux-test-read-max 0)
      (> count process-linux-test-read-max))
      process-linux-test-read-max
      count)
    count))

;: Read-only child injection bridge. It performs no test counter mutation.
(define (linux-child-injected-result [_kind : i64]) : i64
  (cfg
    process-linux-test-hooks
    (if (= _kind process-linux-test-child-fail-kind)
      (- 0 process-linux-test-child-fail-errno)
      process-linux-no-injection)
    process-linux-no-injection))

;: Current child failure-record test mode, erased from production artifacts.
(define (linux-marker-mode) : i64
  (cfg process-linux-test-hooks process-linux-test-marker-mode 0))

;: Construct an empty first/secondary Linux failure record.
(define (linux-failure-none) : ProcessLinuxFailure
  (ProcessLinuxFailure
    process-linux-operation-none
    0
    process-linux-operation-none
    0))

;: Record one failure without overwriting the first operation. Only the first
;: later cleanup failure is retained, keeping the result bounded and stable.
(define (linux-failure-add
  [failure : ProcessLinuxFailure]
  [operation : i64]
  [raw-result : i64]) : ProcessLinuxFailure
  (cond
    [(= operation process-linux-operation-none) failure]
    [(= failure.primary-operation process-linux-operation-none)
      (ProcessLinuxFailure
        operation
        raw-result
        failure.secondary-operation
        failure.secondary-result)]
    [(= failure.secondary-operation process-linux-operation-none)
      (ProcessLinuxFailure
        failure.primary-operation
        failure.primary-result
        operation
        raw-result)]
    [else failure]))

;: Record an operation only when no earlier primary failure exists. Later
;: operation observations do not consume the cleanup slot; descriptor, signal
;: restoration, and reaping failures can therefore remain independently exact.
(define (linux-failure-add-primary
  [failure : ProcessLinuxFailure]
  [operation : i64]
  [raw-result : i64]) : ProcessLinuxFailure
  (if (or
    (= operation process-linux-operation-none)
    (not (= failure.primary-operation process-linux-operation-none)))
    failure
    (ProcessLinuxFailure
      operation
      raw-result
      failure.secondary-operation
      failure.secondary-result)))

;: Record cleanup independently even when it is observed before the primary
;: execution failure. A cleanup-only outcome is promoted while rendering the
;: public result; a later execution failure retains this slot as secondary.
(define (linux-failure-add-cleanup
  [failure : ProcessLinuxFailure]
  [operation : i64]
  [raw-result : i64]) : ProcessLinuxFailure
  (if (or
    (= operation process-linux-operation-none)
    (not (= failure.secondary-operation process-linux-operation-none)))
    failure
    (ProcessLinuxFailure
      failure.primary-operation
      failure.primary-result
      operation
      raw-result)))

;: Promote a cleanup-only failure to the primary slot before exposing it.
(define (linux-failure-normalize [failure : ProcessLinuxFailure]) : ProcessLinuxFailure
  (if (and
    (= failure.primary-operation process-linux-operation-none)
    (not (= failure.secondary-operation process-linux-operation-none)))
    (ProcessLinuxFailure
      failure.secondary-operation
      failure.secondary-result
      process-linux-operation-none
      0)
    failure))

;: True when a primary Linux execution/lifecycle failure is recorded.
(define (linux-failure-present? [failure : (& failure ProcessLinuxFailure)]) : bool
  (or
    (not (= failure.primary-operation process-linux-operation-none))
    (not (= failure.secondary-operation process-linux-operation-none))))

;: Stable operation spelling used only when returning a structured error.
(define (linux-operation-name [operation : i64]) : String
  (cond
    [(= operation process-linux-operation-spawn) "spawn"]
    [(= operation process-linux-operation-child-setup) "child setup"]
    [(= operation process-linux-operation-exec) "exec"]
    [(= operation process-linux-operation-exec-channel) "exec status"]
    [(= operation process-linux-operation-stdin) "stdin"]
    [(= operation process-linux-operation-wait) "wait"]
    [(= operation process-linux-operation-stdout) "stdout capture"]
    [(= operation process-linux-operation-stderr) "stderr capture"]
    [(= operation process-linux-operation-close) "close"]
    [else "process"]))

;: Render a bounded diagnostic while keeping raw results in the typed internal
;: record. Existing ordinary spawn/wait messages remain byte-identical.
(define (linux-failure-message [failure : (& failure ProcessLinuxFailure)]) : String
  (let
    [base : String
      (cond
        [(or
            (= failure.primary-operation process-linux-operation-spawn)
            (= failure.primary-operation process-linux-operation-exec))
          "process: spawn failed"]
        [(= failure.primary-operation process-linux-operation-wait)
          "process: wait failed"]
        [else
          (str_cat.str-cat
            "process: "
            (linux-operation-name failure.primary-operation)
            " failed ("
            (string.int->string failure.primary-result)
            ")")])]
    (if (= failure.secondary-operation process-linux-operation-none)
      base
      (str_cat.str-cat
        base
        "; cleanup: "
        (linux-operation-name failure.secondary-operation)
        " failed ("
        (string.int->string failure.secondary-result)
        ")"))))

;: Spawn/setup/protocol failures retain the public spawn category; lifecycle,
;: stream, and close failures retain the public wait category.
(define (linux-failure-is-spawn? [failure : (& failure ProcessLinuxFailure)]) : bool
  (or
    (= failure.primary-operation process-linux-operation-spawn)
    (= failure.primary-operation process-linux-operation-child-setup)
    (= failure.primary-operation process-linux-operation-exec)
    (= failure.primary-operation process-linux-operation-exec-channel)))

;: Convert a typed Linux failure to the existing captured-output result model.
(define (linux-failure-output [failure : ProcessLinuxFailure]) : ResultProcessRuntimeOutput
  (let
    [normalized : ProcessLinuxFailure (linux-failure-normalize failure)]
    [message : String (linux-failure-message (& normalized))]
    (if (linux-failure-is-spawn? (& normalized))
      (stdlib.process_runtime.output-spawn-failed message)
      (stdlib.process_runtime.output-wait-failed message))))

;: Convert a typed Linux failure to the existing async-start result model.
(define (linux-failure-child [failure : ProcessLinuxFailure]) : ResultProcessRuntimeChild
  (let
    [normalized : ProcessLinuxFailure (linux-failure-normalize failure)]
    [message : String (linux-failure-message (& normalized))]
    (if (linux-failure-is-spawn? (& normalized))
      (stdlib.process_runtime.child-spawn-failed message)
      (stdlib.process_runtime.child-wait-failed message))))

;: Raw `pipe2(O_CLOEXEC)`. Pipe creation is atomic and is not retried.
(unsafe
  (define (linux-raw-pipe [address : i64]) : i64
    (let
      [injected : i64 (linux-injected-result process-linux-syscall-pipe)]
      (if (not (= injected process-linux-no-injection))
        injected
        (cfg
          windows
          -38
          (unsafe
            (syscall 293 address 524288)))))))

;: Raw `memfd_create`. Creation failure has no partial descriptor to clean up.
(unsafe
  (define (linux-raw-memfd [name-address : i64]) : i64
    (let
      [injected : i64 (linux-injected-result process-linux-syscall-memfd)]
      (if (not (= injected process-linux-no-injection))
        injected
        (cfg
          windows
          -38
          (unsafe
            (syscall 319 name-address 0)))))))

;: Resolve only the optional `vfork` fault before entering the shared-stack
;: syscall. The actual syscall must remain inline in the owning spawn frame:
;: returning through a helper after `vfork` lets the child overwrite the
;: suspended parent's helper return address.
(define (linux-vfork-injected-result) : i64
  (linux-injected-result process-linux-syscall-vfork))

;: Raw parent-side Linux close. The descriptor is attempted exactly once and
;: never retried after EINTR because Linux releases the descriptor number early.
;: Injected failures perform the real close first so the native gate cannot leak.
(unsafe
  (define (linux-raw-close [fd : i64]) : i64
    (let
      [injected : i64 (linux-injected-result process-linux-syscall-close)]
      (if (not (= injected process-linux-no-injection))
        (begin
          (cfg
            windows
            -38
            (unsafe
              (syscall 3 fd)))
          injected)
        (cfg
          windows
          -38
          (unsafe
            (syscall 3 fd)))))))

;: Close one owned parent descriptor exactly once, returning its raw result.
(unsafe
  (define (linux-close-if [fd : i64]) : i64
    (if (< fd 0)
      0
      (unsafe
        (stdlib.process_runtime.linux-raw-close fd)))))

;: Raw stdin write, optionally bounded by the focused short-write hook.
(unsafe
  (define (linux-raw-stdin-write [fd : i64] [address : i64] [count : i64]) : i64
    (let
      [injected : i64 (linux-injected-result process-linux-syscall-stdin-write)]
      (if (not (= injected process-linux-no-injection))
        injected
        (cfg
          windows
          -38
          (unsafe
            (syscall 1 fd address (linux-write-request-count count))))))))

;: Raw exec-status read, optionally bounded by the focused short-read hook.
(unsafe
  (define (linux-raw-exec-read [fd : i64] [address : i64] [count : i64]) : i64
    (let
      [injected : i64 (linux-injected-result process-linux-syscall-exec-read)]
      (if (not (= injected process-linux-no-injection))
        injected
        (cfg
          windows
          -38
          (unsafe
            (syscall 0 fd address (linux-read-request-count count))))))))

;: Raw wait4. An injected non-EINTR failure still performs the real wait so the
;: failure gate preserves the production postcondition and cannot leave a zombie.
(unsafe
  (define (linux-raw-wait [pid : i64] [status-address : i64]) : i64
    (let
      [injected : i64 (linux-injected-result process-linux-syscall-wait)]
      (if (not (= injected process-linux-no-injection))
        (if (= injected -4)
          injected
          (cfg
            windows
            injected
            (let
              [cleanup-result : i64 -4]
              (begin
                (while (= cleanup-result -4)
                  (set!
                    cleanup-result
                    (unsafe
                      (syscall 61 pid status-address 0 0))))
                injected))))
        (cfg
          windows
          -38
          (unsafe
            (syscall 61 pid status-address 0 0)))))))

;: Raw capture seek used for both end discovery and rewind.
(unsafe
  (define (linux-raw-capture-seek [fd : i64] [offset : i64] [whence : i64]) : i64
    (let
      [injected : i64
        (linux-injected-result process-linux-syscall-capture-seek)]
      (if (not (= injected process-linux-no-injection))
        injected
        (cfg
          windows
          -38
          (unsafe
            (syscall 8 fd offset whence)))))))

;: Raw capture read, optionally bounded by the focused short-read hook.
(unsafe
  (define (linux-raw-capture-read [fd : i64] [address : i64] [count : i64]) : i64
    (let
      [injected : i64
        (linux-injected-result process-linux-syscall-capture-read)]
      (if (not (= injected process-linux-no-injection))
        injected
        (cfg
          windows
          -38
          (unsafe
            (syscall 0 fd address (linux-read-request-count count))))))))

;: Raw `rt_sigaction` used while feeding a pipe with SIGPIPE ignored.
(unsafe
  (define (linux-raw-sigaction [action-address : i64] [old-address : i64]) : i64
    (let
      [injected : i64 (linux-injected-result process-linux-syscall-sigaction)]
      (if (not (= injected process-linux-no-injection))
        injected
        (cfg
          windows
          -38
          (unsafe
            (syscall 13 13 action-address old-address 8)))))))

;: Build a NUL-terminated `char**` argv (argv[0] = `exec-addr`) and return its
;: integer address.
(unsafe
  (define (linux-build-argv [exec-addr : i64] [argv : ProcessRuntimeStringList]) : i64
    (let
      [argc : i64 (stdlib.process_runtime.args-count argv)]
      [layout-count : i64 (process-runtime-checked-layout-add argc 2)]
      [arr : (__tl_dyn-array u64) (__tl_make-array u64 layout-count)]
      [index : i64 0]
      (begin
        (set! (array-ref arr 0) (cast exec-addr : u64))
        (while (< index argc)
          (let
            [text : String
              (process-runtime-string-array-shared-view (& argv.slots) index)]
            (begin
              (set!
                (array-ref arr (+ index 1))
                (unsafe
                  (cast
                    (ptr->int (io.array-const-ptr (io.c-string text)))
                    : u64)))
              (set! index (+ index 1)))))
        (set! (array-ref arr (+ argc 1)) (cast 0 : u64))
        (stdlib.process_runtime.array-u64-addr arr)))))

;: Count inherited environment entries not overridden by `ov`.
(unsafe
  (define (linux-count-inherited
    [environ : (Ptr (Ptr u8))]
    [ov : (& ov (__tl_dyn-array u64))]) : i64
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
                (if (not
                  (unsafe
                    (stdlib.process_runtime.inherited-overridden? entry ov)))
                  (set! count (process-runtime-checked-layout-add count 1))
                  unit)
                (set! i (+ i 1))))))
        count))))

;: Build the `char**` envp for `env` (inherited minus overrides, plus overrides)
;: and return its integer address; an empty override list reuses the inherited
;: environment array directly.
(unsafe
  (define (linux-build-envp [env : ProcessRuntimeEnvList]) : i64
    (unsafe
      (let
        [ov : (__tl_dyn-array u64)
          (unsafe
            (stdlib.process_runtime.build-override-cstrings env))]
        [ovc : i64 (array-length ov)]
        (if (= ovc 0)
          (unsafe
            (cast
              (ptr->int
                (ptr-cast (stdlib.process_runtime.linux-envp) : (Ptr u8)))
              : i64))
          (let
            [environ : (Ptr (Ptr u8))
              (unsafe
                (ptr-cast (stdlib.process_runtime.linux-envp) : (Ptr (Ptr u8))))]
            [inh : i64
              (unsafe
                (stdlib.process_runtime.linux-count-inherited environ ov))]
            [base-count : i64 (process-runtime-checked-layout-add inh ovc)]
            [layout-count : i64
              (process-runtime-checked-layout-add base-count 1)]
            [arr : (__tl_dyn-array u64) (__tl_make-array u64 layout-count)]
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
                      (if (not
                        (stdlib.process_runtime.inherited-overridden? entry ov))
                        (begin
                          (set!
                            (array-ref arr w)
                            (unsafe
                              (cast (ptr->int entry) : u64)))
                          (set! w (+ w 1)))
                        unit)
                      (set! i (+ i 1))))))
              (while (< k ovc)
                (begin
                  (set! (array-ref arr w) (array-ref ov k))
                  (set! w (+ w 1))
                  (set! k (+ k 1))))
              (set! (array-ref arr w) (cast 0 : u64))
              (stdlib.process_runtime.array-u64-addr arr))))))))

;: Decode a `wait4` status word into the process exit status: a terminating
;: signal becomes `128 + signal`, otherwise the low byte of the exit code.
(define (decode-status [status : i32]) : i64
  (let
    [value : i64 (cast status : i64)]
    [signal : i64 (bit-and value 0x7f)]
    (if (not (= signal 0))
      (+ 128 signal)
      (bit-and (shr value 8) 0xff))))

;: Write `len` bytes at `data-addr` to `fd`. EINTR retries without progress and
;: positive partial writes advance exactly; zero/impossible progress fails.
(unsafe
  (define (linux-write-all [fd : i64] [data-addr : i64] [len : i64]) : i64
    (cfg
      windows
      -1
      (let
        [off : i64 0]
        [result : i64 0]
        [done : bool false]
        (begin
          (while (and (not done) (< off len))
            (let
              [written : i64
                (unsafe
                  (stdlib.process_runtime.linux-raw-stdin-write
                    fd
                    (+ data-addr off)
                    (- len off)))]
              (cond
                [(= written -4) unit]
                [(< written 0)
                  (begin
                    (set! result written)
                    (set! done true))]
                [(or (= written 0) (> written (- len off)))
                  (begin
                    (set! result -71)
                    (set! done true))]
                [else (set! off (+ off written))])))
          result)))))

;: Feed `data-addr`/`len` to the child stdin pipe while ignoring SIGPIPE, then
;: restore the old SIGPIPE disposition. Returns 0 when input was delivered (or a
;: broken pipe was tolerated). The returned state preserves the first primary
;: error and any later signal-restoration or descriptor-close failure.
(unsafe
  (define (linux-feed-stdin
    [has-stdin : bool]
    [stdin-r : i64]
    [stdin-w : i64]
    [data-addr : i64]
    [len : i64]
    [failure : ProcessLinuxFailure]) : ProcessLinuxFailure
    (unsafe
      (cfg
        windows
        (linux-failure-add-primary failure process-linux-operation-stdin -38)
        (if (not has-stdin)
          failure
          (begin
            (set!
              failure
              (linux-record-close
                failure
                (stdlib.process_runtime.linux-close-if stdin-r)))
            (let
              [act : (__tl_dyn-array u64) (__tl_make-array u64 4)]
              [old : (__tl_dyn-array u64) (__tl_make-array u64 4)]
              [installed : bool false]
              (begin
                (set! (array-ref act 0) (cast 1 : u64))
                (let
                  [install-result : i64
                    (unsafe
                      (stdlib.process_runtime.linux-raw-sigaction
                        (stdlib.process_runtime.array-u64-addr act)
                        (stdlib.process_runtime.array-u64-addr
                          (process-runtime-place-shared-view old))))]
                  (if (< install-result 0)
                    (set!
                      failure
                      (linux-failure-add-primary
                        failure
                        process-linux-operation-stdin
                        install-result))
                    (set! installed true)))
                (if installed
                  (let
                    [written : i64
                      (stdlib.process_runtime.linux-write-all
                        stdin-w
                        data-addr
                        len)]
                    (if (and (< written 0) (not (= written -32)))
                      (set!
                        failure
                        (linux-failure-add-primary
                          failure
                          process-linux-operation-stdin
                          written))
                      unit))
                  unit)
                (set!
                  failure
                  (linux-record-close
                    failure
                    (stdlib.process_runtime.linux-close-if stdin-w)))
                (if installed
                  (let
                    [restore-result : i64
                      (unsafe
                        (stdlib.process_runtime.linux-raw-sigaction
                          (stdlib.process_runtime.array-u64-addr old)
                          0))]
                    (if (< restore-result 0)
                      (set!
                        failure
                        (linux-failure-add-cleanup
                          failure
                          process-linux-operation-stdin
                          restore-result))
                      unit))
                  unit)
                failure))))))))

;: Assemble argv/envp/cwd/marker C strings and open the capture descriptors
;: (memfd stdout/stderr, an optional stdin pipe, and the exec-failure pipe)
;: before spawning. `failed` records a pre-spawn OS error. The caller must have
;: established the validated-command boundary.
(unsafe
  (define (linux-prepare [command : ProcessRuntimeCommand]) : ProcessLinuxSpawn
    (unsafe
      (cfg
        windows
        (ProcessLinuxSpawn 0 0 0 0 0 false 0 0 -1 -1 -1 -1 -1 -1 true -38)
        (let
          [exec-addr : i64
            (stdlib.process_runtime.array-u8-addr
              (io.c-string (stdlib.process_runtime.command-executable command)))]
          [argv-addr : i64
            (stdlib.process_runtime.linux-build-argv
              exec-addr
              (stdlib.process_runtime.command-argv command))]
          [envp-addr : i64
            (stdlib.process_runtime.linux-build-envp
              (stdlib.process_runtime.command-env command))]
          [cwd-addr : i64
            (unsafe
              (stdlib.process_runtime.maybe-cstring-addr
                (stdlib.process_runtime.command-cwd command)))]
          [marker-addr : i64
            (stdlib.process_runtime.array-u8-addr
              (io.c-string
                "BAD!0000TLX!1000TLX!2000TLX!3000TLX!4000TLX!5000TLX!6000TLX!7000TLX!8000TLX!9000TLX!A000"))]
          [has-stdin : bool
            (stdlib.process_runtime.maybe-present?
              (stdlib.process_runtime.command-stdin command))]
          [stdin-data : i64
            (stdlib.process_runtime.maybe-data-addr
              (stdlib.process_runtime.command-stdin command))]
          [stdin-len : i64
            (stdlib.process_runtime.maybe-len
              (stdlib.process_runtime.command-stdin command))]
          [stdin-r : i64 -1]
          [stdin-w : i64 -1]
          [stdout-fd : i64 -1]
          [stderr-fd : i64 -1]
          [exec-r : i64 -1]
          [exec-w : i64 -1]
          [failed : bool false]
          [failure-result : i64 0]
          [pbuf : (__tl_dyn-array i32) (__tl_make-array i32 2)]
          [ebuf : (__tl_dyn-array i32) (__tl_make-array i32 2)]
          (begin
            (if has-stdin
              (let
                [result : i64
                  (unsafe
                    (stdlib.process_runtime.linux-raw-pipe
                      (stdlib.process_runtime.array-i32-addr
                        (process-runtime-place-shared-view pbuf))))]
                (if (< result 0)
                  (begin
                    (set! failed true)
                    (set! failure-result result))
                  (begin
                    (set! stdin-r (cast (array-ref pbuf 0) : i64))
                    (set! stdin-w (cast (array-ref pbuf 1) : i64)))))
              unit)
            (if (not failed)
              (let
                [fd : i64
                  (unsafe
                    (stdlib.process_runtime.linux-raw-memfd
                      (stdlib.process_runtime.array-u8-addr
                        (io.c-string "typelisp-process-stdout"))))]
                (if (< fd 0)
                  (begin
                    (set! failed true)
                    (set! failure-result fd))
                  (set! stdout-fd fd)))
              unit)
            (if (not failed)
              (let
                [fd : i64
                  (unsafe
                    (stdlib.process_runtime.linux-raw-memfd
                      (stdlib.process_runtime.array-u8-addr
                        (io.c-string "typelisp-process-stderr"))))]
                (if (< fd 0)
                  (begin
                    (set! failed true)
                    (set! failure-result fd))
                  (set! stderr-fd fd)))
              unit)
            (if (not failed)
              (let
                [result : i64
                  (unsafe
                    (stdlib.process_runtime.linux-raw-pipe
                      (stdlib.process_runtime.array-i32-addr
                        (process-runtime-place-shared-view ebuf))))]
                (if (< result 0)
                  (begin
                    (set! failed true)
                    (set! failure-result result))
                  (begin
                    (set! exec-r (cast (array-ref ebuf 0) : i64))
                    (set! exec-w (cast (array-ref ebuf 1) : i64)))))
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
              failed
              failure-result)))))))

;: Assemble the Linux inherited-stream spawn state. This has the same command,
;: cwd, environment, stdin, and exec-failure setup as `linux-prepare`, but
;: deliberately creates no stdout/stderr capture descriptors. The caller must
;: have established the validated-command boundary.
(unsafe
  (define (linux-prepare-inherit [command : ProcessRuntimeCommand]) : ProcessLinuxInheritedSpawn
    (unsafe
      (cfg
        windows
        (ProcessLinuxInheritedSpawn 0 0 0 0 0 false 0 0 -1 -1 -1 -1 true -38)
        (let
          [exec-addr : i64
            (stdlib.process_runtime.array-u8-addr
              (io.c-string (stdlib.process_runtime.command-executable command)))]
          [argv-addr : i64
            (stdlib.process_runtime.linux-build-argv
              exec-addr
              (stdlib.process_runtime.command-argv command))]
          [envp-addr : i64
            (stdlib.process_runtime.linux-build-envp
              (stdlib.process_runtime.command-env command))]
          [cwd-addr : i64
            (unsafe
              (stdlib.process_runtime.maybe-cstring-addr
                (stdlib.process_runtime.command-cwd command)))]
          [marker-addr : i64
            (stdlib.process_runtime.array-u8-addr
              (io.c-string
                "BAD!0000TLX!1000TLX!2000TLX!3000TLX!4000TLX!5000TLX!6000TLX!7000TLX!8000TLX!9000TLX!A000"))]
          [has-stdin : bool
            (stdlib.process_runtime.maybe-present?
              (stdlib.process_runtime.command-stdin command))]
          [stdin-data : i64
            (stdlib.process_runtime.maybe-data-addr
              (stdlib.process_runtime.command-stdin command))]
          [stdin-len : i64
            (stdlib.process_runtime.maybe-len
              (stdlib.process_runtime.command-stdin command))]
          [stdin-r : i64 -1]
          [stdin-w : i64 -1]
          [exec-r : i64 -1]
          [exec-w : i64 -1]
          [failed : bool false]
          [failure-result : i64 0]
          [pbuf : (__tl_dyn-array i32) (__tl_make-array i32 2)]
          [ebuf : (__tl_dyn-array i32) (__tl_make-array i32 2)]
          (begin
            (if has-stdin
              (let
                [result : i64
                  (unsafe
                    (stdlib.process_runtime.linux-raw-pipe
                      (stdlib.process_runtime.array-i32-addr
                        (process-runtime-place-shared-view pbuf))))]
                (if (< result 0)
                  (begin
                    (set! failed true)
                    (set! failure-result result))
                  (begin
                    (set! stdin-r (cast (array-ref pbuf 0) : i64))
                    (set! stdin-w (cast (array-ref pbuf 1) : i64)))))
              unit)
            (if (not failed)
              (let
                [result : i64
                  (unsafe
                    (stdlib.process_runtime.linux-raw-pipe
                      (stdlib.process_runtime.array-i32-addr
                        (process-runtime-place-shared-view ebuf))))]
                (if (< result 0)
                  (begin
                    (set! failed true)
                    (set! failure-result result))
                  (begin
                    (set! exec-r (cast (array-ref ebuf 0) : i64))
                    (set! exec-w (cast (array-ref ebuf 1) : i64)))))
              unit)
            (ProcessLinuxInheritedSpawn
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
              exec-r
              exec-w
              failed
              failure-result)))))))

;: Record a close result as the next failure without retrying the descriptor.
(define (linux-record-close [failure : ProcessLinuxFailure] [result : i64]) : ProcessLinuxFailure
  (if (< result 0)
    (linux-failure-add-cleanup failure process-linux-operation-close result)
    failure))

;: Close every descriptor recorded in a spawn struct exactly once.
(unsafe
  (define (linux-cleanup-spawn
    [spawn : ProcessLinuxSpawn]
    [failure : ProcessLinuxFailure]) : ProcessLinuxFailure
    (unsafe
      (begin
        (set!
          failure
          (linux-record-close
            failure
            (stdlib.process_runtime.linux-close-if spawn.stdin-r)))
        (set!
          failure
          (linux-record-close
            failure
            (stdlib.process_runtime.linux-close-if spawn.stdin-w)))
        (set!
          failure
          (linux-record-close
            failure
            (stdlib.process_runtime.linux-close-if spawn.stdout-fd)))
        (set!
          failure
          (linux-record-close
            failure
            (stdlib.process_runtime.linux-close-if spawn.stderr-fd)))
        (set!
          failure
          (linux-record-close
            failure
            (stdlib.process_runtime.linux-close-if spawn.exec-r)))
        (set!
          failure
          (linux-record-close
            failure
            (stdlib.process_runtime.linux-close-if spawn.exec-w)))
        failure))))

;: Close every descriptor in an inherited-stream spawn state before a failed
;: Linux spawn returns to its caller.
(unsafe
  (define (linux-cleanup-inherited-spawn
    [spawn : ProcessLinuxInheritedSpawn]
    [failure : ProcessLinuxFailure]) : ProcessLinuxFailure
    (unsafe
      (begin
        (set!
          failure
          (linux-record-close
            failure
            (stdlib.process_runtime.linux-close-if spawn.stdin-r)))
        (set!
          failure
          (linux-record-close
            failure
            (stdlib.process_runtime.linux-close-if spawn.stdin-w)))
        (set!
          failure
          (linux-record-close
            failure
            (stdlib.process_runtime.linux-close-if spawn.exec-r)))
        (set!
          failure
          (linux-record-close
            failure
            (stdlib.process_runtime.linux-close-if spawn.exec-w)))
        failure))))

;: Issue one child-side close exactly once. Close is never retried after EINTR.
(unsafe
  (define (linux-child-close [kind : i64] [fd : i64]) : i64
    (let
      [injected : i64 (linux-child-injected-result kind)]
      (if (not (= injected process-linux-no-injection))
        injected
        (cfg
          windows
          -38
          (unsafe
            (syscall 3 fd)))))))

;: Install one child standard descriptor, retrying only on EINTR. When the
;: source already has the destination number, clear its pipe2 `FD_CLOEXEC`
;: flag with `fcntl(F_SETFD)` because `dup2(fd, fd)` would leave the flag set.
;: Injected EINTR is consumed once so the native gate exercises progress
;: without child writes to hook counters.
(unsafe
  (define (linux-child-dup2-retry
    [kind : i64]
    [old-fd : i64]
    [new-fd : i64]
    [allow-injection : bool]) : i64
    (let
      [injected : i64
        (if allow-injection
          (linux-child-injected-result kind)
          process-linux-no-injection)]
      [result : i64
        (if (not (= injected process-linux-no-injection))
          injected
          (cfg
            windows
            -38
            (if (= old-fd new-fd)
              (unsafe
                (syscall 72 old-fd 2 0))
              (unsafe
                (syscall 33 old-fd new-fd)))))]
      (if (= result -4)
        (unsafe
          (linux-child-dup2-retry kind old-fd new-fd false))
        result))))

;: Retry child chdir only on EINTR; the immutable C path remains unchanged.
(unsafe
  (define (linux-child-chdir-retry [path : i64] [allow-injection : bool]) : i64
    (let
      [injected : i64
        (if allow-injection
          (linux-child-injected-result process-linux-child-syscall-chdir)
          process-linux-no-injection)]
      [result : i64
        (if (not (= injected process-linux-no-injection))
          injected
          (cfg
            windows
            -38
            (unsafe
              (syscall 80 path))))]
      (if (= result -4)
        (unsafe
          (linux-child-chdir-retry path false))
        result))))

;: Issue execve once. A returned result is always a child failure.
(unsafe
  (define (linux-child-execve
    [exec-address : i64]
    [argv-address : i64]
    [envp-address : i64]) : i64
    (let
      [injected : i64
        (linux-child-injected-result process-linux-child-syscall-exec)]
      (if (not (= injected process-linux-no-injection))
        injected
        (cfg
          windows
          -38
          (unsafe
            (syscall 59 exec-address argv-address envp-address)))))))

;: Write a small child failure record completely. The only retry is EINTR and
;: every positive partial result advances the record pointer.
(unsafe
  (define (linux-child-write-record
    [fd : i64]
    [address : i64]
    [length : i64]
    [offset : i64]
    [inject-eintr : bool]) : bool
    (if (>= offset length)
      true
      (if inject-eintr
        (unsafe
          (linux-child-write-record fd address length offset false))
        (let
          [remaining : i64 (- length offset)]
          [requested : i64
            (if (and (= (linux-marker-mode) 4) (> remaining 3))
              3
              remaining)]
          [written : i64
            (cfg
              windows
              -38
              (unsafe
                (syscall 1 fd (+ address offset) requested)))]
          (cond
            [(= written -4)
              (unsafe
                (linux-child-write-record fd address length offset false))]
            [(<= written 0) false]
            [(> written remaining) false]
            [else
              (unsafe
                (linux-child-write-record
                  fd
                  address
                  length
                  (+ offset written)
                  false))]))))))

;: Child failure path: write one exact bounded stage record when possible and
;: exit through `_exit(127)`. It never returns to parent/application control.
(unsafe
  (define (linux-child-fail
    [exec-w : i64]
    [record-base-address : i64]
    [stage : i64]) : never
    (unsafe
      (cfg
        windows
        (stdlib.process_runtime.linux-child-fail
          exec-w
          record-base-address
          stage)
        (let
          [mode : i64 (linux-marker-mode)]
          [record-address : i64
            (if (= mode 2)
              record-base-address
              (+ record-base-address (* stage 8)))]
          [record-length : i64 (cond [(= mode 1) 4] [(= mode 3) 9] [else 8])]
          (begin
            (unsafe
              (linux-child-write-record
                exec-w
                record-address
                record-length
                0
                (= mode 5)))
            (unsafe
              (syscall 60 127))
            (stdlib.process_runtime.linux-child-fail
              exec-w
              record-base-address
              stage)))))))

;: Child path after vfork (syscalls only, no allocation or parent-memory writes):
;: wire stdin/stdout/stderr, chdir, then `execve`. Never returns.
(unsafe
  (define (linux-exec-child [spawn : ProcessLinuxSpawn]) : never
    (unsafe
      (cfg
        windows
        (stdlib.process_runtime.linux-exec-child spawn)
        (begin
          (if (<
            (unsafe
              (linux-child-close
                process-linux-child-syscall-close-exec-read
                spawn.exec-r))
            0)
            (stdlib.process_runtime.linux-child-fail
              spawn.exec-w
              spawn.marker-addr
              process-linux-child-stage-close-exec-read)
            unit)
          (if (>= spawn.stdin-w 0)
            (begin
              (if (<
                (unsafe
                  (linux-child-close
                    process-linux-child-syscall-close-stdin-write
                    spawn.stdin-w))
                0)
                (stdlib.process_runtime.linux-child-fail
                  spawn.exec-w
                  spawn.marker-addr
                  process-linux-child-stage-close-stdin-write)
                unit)
              (if (<
                (unsafe
                  (linux-child-dup2-retry
                    process-linux-child-syscall-dup-stdin
                    spawn.stdin-r
                    0
                    true))
                0)
                (stdlib.process_runtime.linux-child-fail
                  spawn.exec-w
                  spawn.marker-addr
                  process-linux-child-stage-dup-stdin)
                (cond
                  [(= spawn.stdin-r 0) unit]
                  [(<
                      (unsafe
                        (linux-child-close
                          process-linux-child-syscall-close-stdin-read
                          spawn.stdin-r))
                      0)
                    (stdlib.process_runtime.linux-child-fail
                      spawn.exec-w
                      spawn.marker-addr
                      process-linux-child-stage-close-stdin-read)]
                  [else unit])))
            unit)
          (let
            ;; When stderr's source is descriptor 1, preserve it in descriptor
            ;; 2 before installing stdout. This occurs when caller standard
            ;; descriptors are closed and the memfds reuse their numbers.
            [stderr-first : bool
              (and (= spawn.stderr-fd 1) (not (= spawn.stdout-fd 1)))]
            (begin
              (if stderr-first
                (if (<
                  (unsafe
                    (linux-child-dup2-retry
                      process-linux-child-syscall-dup-stderr
                      spawn.stderr-fd
                      2
                      true))
                  0)
                  (stdlib.process_runtime.linux-child-fail
                    spawn.exec-w
                    spawn.marker-addr
                    process-linux-child-stage-dup-stderr)
                  unit)
                unit)
              (if (<
                (unsafe
                  (linux-child-dup2-retry
                    process-linux-child-syscall-dup-stdout
                    spawn.stdout-fd
                    1
                    true))
                0)
                (stdlib.process_runtime.linux-child-fail
                  spawn.exec-w
                  spawn.marker-addr
                  process-linux-child-stage-dup-stdout)
                unit)
              (if stderr-first
                unit
                (if (<
                  (unsafe
                    (linux-child-dup2-retry
                      process-linux-child-syscall-dup-stderr
                      spawn.stderr-fd
                      2
                      true))
                  0)
                  (stdlib.process_runtime.linux-child-fail
                    spawn.exec-w
                    spawn.marker-addr
                    process-linux-child-stage-dup-stderr)
                  unit))))
          (if (or (= spawn.stdout-fd 1) (= spawn.stdout-fd 2))
            unit
            (if (<
              (unsafe
                (linux-child-close
                  process-linux-child-syscall-close-stdout
                  spawn.stdout-fd))
              0)
              (stdlib.process_runtime.linux-child-fail
                spawn.exec-w
                spawn.marker-addr
                process-linux-child-stage-close-stdout)
              unit))
          (if (or (= spawn.stderr-fd 1) (= spawn.stderr-fd 2))
            unit
            (if (<
              (unsafe
                (linux-child-close
                  process-linux-child-syscall-close-stderr
                  spawn.stderr-fd))
              0)
              (stdlib.process_runtime.linux-child-fail
                spawn.exec-w
                spawn.marker-addr
                process-linux-child-stage-close-stderr)
              unit))
          (if (not (= spawn.cwd-addr 0))
            (if (<
              (unsafe
                (linux-child-chdir-retry spawn.cwd-addr true))
              0)
              (stdlib.process_runtime.linux-child-fail
                spawn.exec-w
                spawn.marker-addr
                process-linux-child-stage-chdir)
              unit)
            unit)
          (unsafe
            (linux-child-execve spawn.exec-addr spawn.argv-addr spawn.envp-addr))
          (stdlib.process_runtime.linux-child-fail
            spawn.exec-w
            spawn.marker-addr
            process-linux-child-stage-exec))))))

;: Child path after vfork for inherited stdout/stderr: wire only an explicitly
;: supplied stdin pipe, leave descriptors 1 and 2 untouched, then execve.
(unsafe
  (define (linux-exec-child-inherit [spawn : ProcessLinuxInheritedSpawn]) : never
    (unsafe
      (cfg
        windows
        (stdlib.process_runtime.linux-exec-child-inherit spawn)
        (begin
          (if (<
            (unsafe
              (linux-child-close
                process-linux-child-syscall-close-exec-read
                spawn.exec-r))
            0)
            (stdlib.process_runtime.linux-child-fail
              spawn.exec-w
              spawn.marker-addr
              process-linux-child-stage-close-exec-read)
            unit)
          (if (>= spawn.stdin-w 0)
            (begin
              (if (<
                (unsafe
                  (linux-child-close
                    process-linux-child-syscall-close-stdin-write
                    spawn.stdin-w))
                0)
                (stdlib.process_runtime.linux-child-fail
                  spawn.exec-w
                  spawn.marker-addr
                  process-linux-child-stage-close-stdin-write)
                unit)
              (if (<
                (unsafe
                  (linux-child-dup2-retry
                    process-linux-child-syscall-dup-stdin
                    spawn.stdin-r
                    0
                    true))
                0)
                (stdlib.process_runtime.linux-child-fail
                  spawn.exec-w
                  spawn.marker-addr
                  process-linux-child-stage-dup-stdin)
                (cond
                  [(= spawn.stdin-r 0) unit]
                  [(<
                      (unsafe
                        (linux-child-close
                          process-linux-child-syscall-close-stdin-read
                          spawn.stdin-r))
                      0)
                    (stdlib.process_runtime.linux-child-fail
                      spawn.exec-w
                      spawn.marker-addr
                      process-linux-child-stage-close-stdin-read)]
                  [else unit])))
            unit)
          (if (not (= spawn.cwd-addr 0))
            (if (<
              (unsafe
                (linux-child-chdir-retry spawn.cwd-addr true))
              0)
              (stdlib.process_runtime.linux-child-fail
                spawn.exec-w
                spawn.marker-addr
                process-linux-child-stage-chdir)
              unit)
            unit)
          (unsafe
            (linux-child-execve spawn.exec-addr spawn.argv-addr spawn.envp-addr))
          (stdlib.process_runtime.linux-child-fail
            spawn.exec-w
            spawn.marker-addr
            process-linux-child-stage-exec))))))

;: Decode one exact eight-byte child failure record, returning zero when the
;: magic, reserved bytes, or stage byte is malformed.
(define (linux-exec-record-stage [buf : (& buf (__tl_dyn-array u8))]) : i64
  (if (and
    (= (array-length buf) 9)
    (= (cast (array-ref buf 0) : i64) 84)
    (= (cast (array-ref buf 1) : i64) 76)
    (= (cast (array-ref buf 2) : i64) 88)
    (= (cast (array-ref buf 3) : i64) 33)
    (= (cast (array-ref buf 5) : i64) 48)
    (= (cast (array-ref buf 6) : i64) 48)
    (= (cast (array-ref buf 7) : i64) 48))
    (let
      [stage-byte : i64 (cast (array-ref buf 4) : i64)]
      (if (and (>= stage-byte 49) (<= stage-byte 57))
        (- stage-byte 48)
        (if (= stage-byte 65)
          10
          0)))
    0))

;: Read the close-on-exec channel to exact EOF. Clean EOF before any byte proves
;: successful exec; one exact record proves child failure; every read error,
;: partial EOF, malformed record, or trailing byte is protocol failure.
(unsafe
  (define (linux-read-exec-status [exec-r : i64]) : ProcessLinuxExecOutcome
    (unsafe
      (cfg
        windows
        (ProcessLinuxExecOutcome (ProcessLinuxExecChannelFailed -38) 0)
        (let
          [buf : (__tl_dyn-array u8) (__tl_make-array u8 9)]
          [offset : i64 0]
          [done : bool false]
          [failed-result : i64 0]
          [status : ProcessLinuxExecStatus (ProcessLinuxExecSucceeded)]
          (begin
            (while (not done)
              (let
                [requested : i64
                  (if (< offset 8)
                    (- 8 offset)
                    1)]
                [count : i64
                  (unsafe
                    (stdlib.process_runtime.linux-raw-exec-read
                      exec-r
                      (+
                        (stdlib.process_runtime.array-u8-addr
                          (process-runtime-place-shared-view buf))
                        offset)
                      requested))]
                (cond
                  [(= count -4) unit]
                  [(< count 0)
                    (begin
                      (set! failed-result count)
                      (set! done true))]
                  [(= count 0) (set! done true)]
                  [(> count requested)
                    (begin
                      (set! failed-result -71)
                      (set! done true))]
                  [(>= offset 8)
                    (begin
                      (set! offset (+ offset count))
                      (set! failed-result -71)
                      (set! done true))]
                  [else (set! offset (+ offset count))])))
            (set!
              status
              (cond
                [(< failed-result 0)
                  (ProcessLinuxExecChannelFailed failed-result)]
                [(= offset 0) (ProcessLinuxExecSucceeded)]
                [(= offset 8)
                  (let
                    [stage : i64 (linux-exec-record-stage (& buf))]
                    (if (> stage 0)
                      (ProcessLinuxExecChildFailed stage)
                      (ProcessLinuxExecChannelFailed -71)))]
                [else (ProcessLinuxExecChannelFailed -71)]))
            (ProcessLinuxExecOutcome
              status
              (stdlib.process_runtime.linux-close-if exec-r))))))))

;: Wait for exactly `pid`, retrying only EINTR. A different positive pid is an
;: impossible result for this wait4 invocation and is treated as protocol error.
(unsafe
  (define (linux-wait-retry [pid : i64] [status-address : i64]) : i64
    (unsafe
      (cfg
        windows
        -38
        (let
          [result : i64 -4]
          (begin
            (while (= result -4)
              (set!
                result
                (stdlib.process_runtime.linux-raw-wait pid status-address)))
            (if (and (>= result 0) (not (= result pid)))
              -71
              result)))))))

;: Seek one capture descriptor, retrying only EINTR.
(unsafe
  (define (linux-capture-seek-retry [fd : i64] [offset : i64] [whence : i64]) : i64
    (let
      [result : i64 -4]
      (begin
        (while (= result -4)
          (set!
            result
            (unsafe
              (stdlib.process_runtime.linux-raw-capture-seek fd offset whence))))
        result))))

;: Read one seekable capture exactly. Short reads advance, EINTR retries, and
;: early EOF or impossible progress becomes an explicit typed failure.
(unsafe
  (define (linux-read-capture [fd : i64]) : ProcessLinuxCaptureResult
    (unsafe
      (cfg
        windows
        (ProcessLinuxCaptureFailed -38)
        (let
          [end : i64 (stdlib.process_runtime.linux-capture-seek-retry fd 0 2)]
          (if (< end 0)
            (ProcessLinuxCaptureFailed end)
            (let
              [rewound : i64
                (stdlib.process_runtime.linux-capture-seek-retry fd 0 0)]
              (if (< rewound 0)
                (ProcessLinuxCaptureFailed rewound)
                (if (not (= rewound 0))
                  (ProcessLinuxCaptureFailed -71)
                  (let
                    [buf : (__tl_dyn-array u8) (__tl_make-array u8 end)]
                    [offset : i64 0]
                    [failure-result : i64 0]
                    [done : bool false]
                    (begin
                      (while (and (not done) (< offset end))
                        (let
                          [requested : i64 (- end offset)]
                          [count : i64
                            (stdlib.process_runtime.linux-raw-capture-read
                              fd
                              (+
                                (stdlib.process_runtime.array-u8-addr
                                  (process-runtime-place-shared-view buf))
                                offset)
                              requested)]
                          (cond
                            [(= count -4) unit]
                            [(< count 0)
                              (begin
                                (set! failure-result count)
                                (set! done true))]
                            [(or (= count 0) (> count requested))
                              (begin
                                (set! failure-result -71)
                                (set! done true))]
                            [else (set! offset (+ offset count))])))
                      (if (< failure-result 0)
                        (ProcessLinuxCaptureFailed failure-result)
                        (ProcessLinuxCaptureOk
                          (byte_buf.from-array-prefix buf end))))))))))))))

;: Fold an exact exec-channel outcome into the bounded failure state. The
;: returned flag is true only when close-on-exec EOF proved successful exec.
(define (linux-record-exec-outcome
  [outcome : ProcessLinuxExecOutcome]
  [failure : ProcessLinuxFailure]) : ProcessLinuxFailure
  (let
    [close-result : i64 outcome.close-result]
    (begin
      (set!
        failure
        (match outcome.status
          [(ProcessLinuxExecSucceeded) failure]
          [(ProcessLinuxExecChildFailed stage)
            (linux-failure-add-primary
              failure
              (if (= stage process-linux-child-stage-exec)
                process-linux-operation-exec
                process-linux-operation-child-setup)
              (- 0 stage))]
          [(ProcessLinuxExecChannelFailed raw-result)
            (linux-failure-add-primary
              failure
              process-linux-operation-exec-channel
              raw-result)]))
      (linux-record-close failure close-result))))

;: Return true only for the successful close-on-exec outcome.
(define (linux-exec-succeeded? [outcome : (& outcome ProcessLinuxExecOutcome)]) : bool
  (match (& outcome.status)
    [(ProcessLinuxExecSucceeded) true]
    [(ProcessLinuxExecChildFailed _) false]
    [(ProcessLinuxExecChannelFailed _) false]))

;: Parent path for the captured-output runtime: feed stdin, wait for the child,
;: detect `execve` failure, then read the memfd-captured stdout/stderr.
(unsafe
  (define (linux-output-parent [spawn : ProcessLinuxSpawn] [pid : i64]) : ResultProcessRuntimeOutput
    (unsafe
      (cfg
        windows
        (stdlib.process_runtime.wait-error)
        (let
          [failure : ProcessLinuxFailure (linux-failure-none)]
          [statusbuf : (__tl_dyn-array i32) (__tl_make-array i32 1)]
          [waited : i64 -1]
          [exec-succeeded : bool false]
          [stdout-text : String ""]
          [stderr-text : String ""]
          (begin
            (set!
              failure
              (linux-record-close
                failure
                (stdlib.process_runtime.linux-close-if spawn.exec-w)))
            (set!
              failure
              (stdlib.process_runtime.linux-feed-stdin
                spawn.has-stdin
                spawn.stdin-r
                spawn.stdin-w
                spawn.stdin-data
                spawn.stdin-len
                failure))
            (set!
              waited
              (stdlib.process_runtime.linux-wait-retry
                pid
                (stdlib.process_runtime.array-i32-addr
                  (process-runtime-place-shared-view statusbuf))))
            (if (< waited 0)
              (begin
                (set!
                  failure
                  (linux-failure-add
                    failure
                    process-linux-operation-wait
                    waited))
                (set!
                  failure
                  (linux-record-close
                    failure
                    (stdlib.process_runtime.linux-close-if spawn.exec-r))))
              (let
                [exec-outcome : ProcessLinuxExecOutcome
                  (stdlib.process_runtime.linux-read-exec-status spawn.exec-r)]
                (begin
                  (set! exec-succeeded (linux-exec-succeeded? (& exec-outcome)))
                  (set!
                    failure
                    (linux-record-exec-outcome exec-outcome failure)))))
            (if (and (>= waited 0) exec-succeeded)
              (begin
                (match (stdlib.process_runtime.linux-read-capture
                  spawn.stdout-fd)
                  [(ProcessLinuxCaptureOk bytes)
                    (set! stdout-text (byte_buf.to-string bytes))]
                  [(ProcessLinuxCaptureFailed raw-result)
                    (set!
                      failure
                      (linux-failure-add-primary
                        failure
                        process-linux-operation-stdout
                        raw-result))])
                (set!
                  failure
                  (linux-record-close
                    failure
                    (stdlib.process_runtime.linux-close-if spawn.stdout-fd)))
                (match (stdlib.process_runtime.linux-read-capture
                  spawn.stderr-fd)
                  [(ProcessLinuxCaptureOk bytes)
                    (set! stderr-text (byte_buf.to-string bytes))]
                  [(ProcessLinuxCaptureFailed raw-result)
                    (set!
                      failure
                      (linux-failure-add-primary
                        failure
                        process-linux-operation-stderr
                        raw-result))])
                (set!
                  failure
                  (linux-record-close
                    failure
                    (stdlib.process_runtime.linux-close-if spawn.stderr-fd))))
              (begin
                (set!
                  failure
                  (linux-record-close
                    failure
                    (stdlib.process_runtime.linux-close-if spawn.stdout-fd)))
                (set!
                  failure
                  (linux-record-close
                    failure
                    (stdlib.process_runtime.linux-close-if spawn.stderr-fd)))))
            (if (linux-failure-present? (& failure))
              (linux-failure-output failure)
              (stdlib.process_runtime.output-ok
                (stdlib.process_runtime.decode-status (array-ref statusbuf 0))
                stdout-text
                stderr-text))))))))

;: Parent path for the asynchronous start runtime: feed stdin, detect immediate
;: `execve` failure, otherwise return a child owning the capture descriptors.
(unsafe
  (define (linux-start-parent [spawn : ProcessLinuxSpawn] [pid : i64]) : ResultProcessRuntimeChild
    (unsafe
      (cfg
        windows
        (stdlib.process_runtime.wait-error-child)
        (let
          [failure : ProcessLinuxFailure (linux-failure-none)]
          [exec-outcome : ProcessLinuxExecOutcome
            (ProcessLinuxExecOutcome (ProcessLinuxExecChannelFailed -71) 0)]
          [exec-succeeded : bool false]
          (begin
            (set!
              failure
              (linux-record-close
                failure
                (stdlib.process_runtime.linux-close-if spawn.exec-w)))
            (set!
              failure
              (stdlib.process_runtime.linux-feed-stdin
                spawn.has-stdin
                spawn.stdin-r
                spawn.stdin-w
                spawn.stdin-data
                spawn.stdin-len
                failure))
            (set!
              exec-outcome
              (stdlib.process_runtime.linux-read-exec-status spawn.exec-r))
            (set! exec-succeeded (linux-exec-succeeded? (& exec-outcome)))
            (set! failure (linux-record-exec-outcome exec-outcome failure))
            (if (and exec-succeeded (not (linux-failure-present? (& failure))))
              (stdlib.process_runtime.child-ok
                pid
                spawn.stdout-fd
                spawn.stderr-fd)
              (let
                [statusbuf : (__tl_dyn-array i32) (__tl_make-array i32 1)]
                [waited : i64
                  (stdlib.process_runtime.linux-wait-retry
                    pid
                    (stdlib.process_runtime.array-i32-addr
                      (process-runtime-place-shared-view statusbuf)))]
                (begin
                  (if (< waited 0)
                    (set!
                      failure
                      (linux-failure-add
                        failure
                        process-linux-operation-wait
                        waited))
                    unit)
                  (set!
                    failure
                    (linux-record-close
                      failure
                      (stdlib.process_runtime.linux-close-if spawn.stdout-fd)))
                  (set!
                    failure
                    (linux-record-close
                      failure
                      (stdlib.process_runtime.linux-close-if spawn.stderr-fd)))
                  (linux-failure-child failure))))))))))

;: Linux captured-output runtime: prepare, vfork, and dispatch parent/child.
(unsafe
  (define (linux-output [command : ProcessRuntimeCommand]) : ResultProcessRuntimeOutput
    (unsafe
      (cfg
        windows
        (stdlib.process_runtime.spawn-error)
        (let
          [spawn : ProcessLinuxSpawn
            (unsafe
              (stdlib.process_runtime.linux-prepare command))]
          (if spawn.failed
            (linux-failure-output
              (stdlib.process_runtime.linux-cleanup-spawn
                spawn
                (linux-failure-add
                  (linux-failure-none)
                  process-linux-operation-spawn
                  spawn.failure-result)))
            (let
              ;; Use vfork so high-RSS selfhost builds can still exec tiny tools
              ;; on memory-constrained runners without copying page tables.
              [vfork-injected : i64 (linux-vfork-injected-result)]
              [pid : i64
                (if (not (= vfork-injected process-linux-no-injection))
                  vfork-injected
                  (unsafe
                    (syscall 58)))]
              (if (< pid 0)
                (linux-failure-output
                  (stdlib.process_runtime.linux-cleanup-spawn
                    spawn
                    (linux-failure-add
                      (linux-failure-none)
                      process-linux-operation-spawn
                      pid)))
                (if (= pid 0)
                  (stdlib.process_runtime.linux-exec-child spawn)
                  (stdlib.process_runtime.linux-output-parent spawn pid))))))))))

;: Parent path for an inherited-stream child: feed explicit stdin, wait for the
;: child, detect an exec failure, and return only its exit status. Stdout and
;: stderr stay connected to the caller throughout execution.
(unsafe
  (define (linux-inherit-parent
    [spawn : ProcessLinuxInheritedSpawn]
    [pid : i64]) : ResultProcessRuntimeOutput
    (unsafe
      (cfg
        windows
        (stdlib.process_runtime.wait-error)
        (let
          [failure : ProcessLinuxFailure (linux-failure-none)]
          [statusbuf : (__tl_dyn-array i32) (__tl_make-array i32 1)]
          [waited : i64 -1]
          [exec-succeeded : bool false]
          (begin
            (set!
              failure
              (linux-record-close
                failure
                (stdlib.process_runtime.linux-close-if spawn.exec-w)))
            (set!
              failure
              (stdlib.process_runtime.linux-feed-stdin
                spawn.has-stdin
                spawn.stdin-r
                spawn.stdin-w
                spawn.stdin-data
                spawn.stdin-len
                failure))
            (set!
              waited
              (stdlib.process_runtime.linux-wait-retry
                pid
                (stdlib.process_runtime.array-i32-addr
                  (process-runtime-place-shared-view statusbuf))))
            (if (< waited 0)
              (begin
                (set!
                  failure
                  (linux-failure-add
                    failure
                    process-linux-operation-wait
                    waited))
                (set!
                  failure
                  (linux-record-close
                    failure
                    (stdlib.process_runtime.linux-close-if spawn.exec-r))))
              (let
                [exec-outcome : ProcessLinuxExecOutcome
                  (stdlib.process_runtime.linux-read-exec-status spawn.exec-r)]
                (begin
                  (set! exec-succeeded (linux-exec-succeeded? (& exec-outcome)))
                  (set!
                    failure
                    (linux-record-exec-outcome exec-outcome failure)))))
            (if (linux-failure-present? (& failure))
              (linux-failure-output failure)
              (if exec-succeeded
                (stdlib.process_runtime.output-ok
                  (stdlib.process_runtime.decode-status (array-ref statusbuf 0))
                  ""
                  "")
                (linux-failure-output
                  (linux-failure-add
                    failure
                    process-linux-operation-exec-channel
                    -71))))))))))

;: Linux inherited-stream runtime: prepare without output capture, vfork, and
;: keep child stdout/stderr attached to the caller until it exits.
(unsafe
  (define (linux-inherit [command : ProcessRuntimeCommand]) : ResultProcessRuntimeOutput
    (unsafe
      (cfg
        windows
        (stdlib.process_runtime.spawn-error)
        (let
          [spawn : ProcessLinuxInheritedSpawn
            (unsafe
              (stdlib.process_runtime.linux-prepare-inherit command))]
          (if spawn.failed
            (linux-failure-output
              (stdlib.process_runtime.linux-cleanup-inherited-spawn
                spawn
                (linux-failure-add
                  (linux-failure-none)
                  process-linux-operation-spawn
                  spawn.failure-result)))
            (let
              [vfork-injected : i64 (linux-vfork-injected-result)]
              [pid : i64
                (if (not (= vfork-injected process-linux-no-injection))
                  vfork-injected
                  (unsafe
                    (syscall 58)))]
              (if (< pid 0)
                (linux-failure-output
                  (stdlib.process_runtime.linux-cleanup-inherited-spawn
                    spawn
                    (linux-failure-add
                      (linux-failure-none)
                      process-linux-operation-spawn
                      pid)))
                (if (= pid 0)
                  (stdlib.process_runtime.linux-exec-child-inherit spawn)
                  (stdlib.process_runtime.linux-inherit-parent spawn pid))))))))))

;: Linux asynchronous start runtime: prepare, vfork, and dispatch parent/child.
(unsafe
  (define (linux-start [command : ProcessRuntimeCommand]) : ResultProcessRuntimeChild
    (unsafe
      (cfg
        windows
        (stdlib.process_runtime.spawn-error-child)
        (let
          [spawn : ProcessLinuxSpawn
            (unsafe
              (stdlib.process_runtime.linux-prepare command))]
          (if spawn.failed
            (linux-failure-child
              (stdlib.process_runtime.linux-cleanup-spawn
                spawn
                (linux-failure-add
                  (linux-failure-none)
                  process-linux-operation-spawn
                  spawn.failure-result)))
            (let
              ;; Use vfork so high-RSS selfhost builds can still exec tiny tools
              ;; on memory-constrained runners without copying page tables.
              [vfork-injected : i64 (linux-vfork-injected-result)]
              [pid : i64
                (if (not (= vfork-injected process-linux-no-injection))
                  vfork-injected
                  (unsafe
                    (syscall 58)))]
              (if (< pid 0)
                (linux-failure-child
                  (stdlib.process_runtime.linux-cleanup-spawn
                    spawn
                    (linux-failure-add
                      (linux-failure-none)
                      process-linux-operation-spawn
                      pid)))
                (if (= pid 0)
                  (stdlib.process_runtime.linux-exec-child spawn)
                  (stdlib.process_runtime.linux-start-parent spawn pid))))))))))

;: Linux asynchronous wait runtime: reap the child, read the memfd-captured
;: stdout/stderr, release the capture descriptors, and decode the exit status.
(unsafe
  (define (linux-wait [child : ProcessRuntimeChild]) : ResultProcessRuntimeOutput
    (unsafe
      (cfg
        windows
        (stdlib.process_runtime.wait-error)
        (let
          [pid : i64 child.pid]
          [stdout-fd : i64 child.stdout-handle]
          [stderr-fd : i64 child.stderr-handle]
          [statusbuf : (__tl_dyn-array i32) (__tl_make-array i32 1)]
          [failure : ProcessLinuxFailure (linux-failure-none)]
          [stdout-text : String ""]
          [stderr-text : String ""]
          [waited : i64
            (stdlib.process_runtime.linux-wait-retry
              pid
              (stdlib.process_runtime.array-i32-addr
                (process-runtime-place-shared-view statusbuf)))]
          (begin
            (if (< waited 0)
              (set!
                failure
                (linux-failure-add failure process-linux-operation-wait waited))
              (begin
                (match (stdlib.process_runtime.linux-read-capture stdout-fd)
                  [(ProcessLinuxCaptureOk bytes)
                    (set! stdout-text (byte_buf.to-string bytes))]
                  [(ProcessLinuxCaptureFailed raw-result)
                    (set!
                      failure
                      (linux-failure-add-primary
                        failure
                        process-linux-operation-stdout
                        raw-result))])
                (match (stdlib.process_runtime.linux-read-capture stderr-fd)
                  [(ProcessLinuxCaptureOk bytes)
                    (set! stderr-text (byte_buf.to-string bytes))]
                  [(ProcessLinuxCaptureFailed raw-result)
                    (set!
                      failure
                      (linux-failure-add-primary
                        failure
                        process-linux-operation-stderr
                        raw-result))])))
            (set!
              failure
              (linux-record-close
                failure
                (stdlib.process_runtime.linux-close-if stdout-fd)))
            (set!
              failure
              (linux-record-close
                failure
                (stdlib.process_runtime.linux-close-if stderr-fd)))
            (if (linux-failure-present? (& failure))
              (linux-failure-output failure)
              (stdlib.process_runtime.output-ok
                (stdlib.process_runtime.decode-status (array-ref statusbuf 0))
                stdout-text
                stderr-text))))))))

;; ---------------------------------------------------------------------------
;; Windows runtime (kernel32 CreateProcessA with temp-file redirection).
;; ---------------------------------------------------------------------------
;: Return true when `text` contains an ASCII space (argv-quoting trigger).
(define (string-has-space? [text : (& text str)]) : bool
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
(define (quote-arg [text : String]) : String
  (if (stdlib.process_runtime.string-has-space? text)
    (str_cat.str-cat "\"" text "\"")
    text))

;: Join the executable and argv into a single space-separated command line,
;: quoting space-containing entries (the CreateProcessA `lpCommandLine`).
(define (windows-cmdline [command : ProcessRuntimeCommand]) : String
  (let
    [line : text_buf.TextBuf
      (text_buf.append
        (text_buf.empty)
        (stdlib.process_runtime.quote-arg
          (stdlib.process_runtime.command-executable command)))]
    [argv : ProcessRuntimeStringList
      (stdlib.process_runtime.command-argv command)]
    [index : i64 0]
    (begin
      (while (< index (array-length argv.slots))
        (let
          [text : String
            (process-runtime-string-array-shared-view (& argv.slots) index)]
          (begin
            (text_buf.append! line " ")
            (text_buf.append! line (stdlib.process_runtime.quote-arg text))
            (set! index (+ index 1)))))
      (text_buf.render line))))

;: Append the NUL-terminated C string at `addr` (including its NUL) onto a block.
;: Private Windows environment block builder; `CreateProcessA` consumes only the
;: final raw byte block, and no growable byte array escapes this module.
(cfg
  windows
  (unsafe
    (define (windows-push-cstr
      [block : (&mut block byte_buf_core.ByteBufBuilder)]
      [addr : i64]) : unit
      (unsafe
        (let
          [ptr : (Ptr u8) (stdlib.process_runtime.addr->ptr addr)]
          [i : i64 0]
          [done : bool false]
          (begin
            (while (not done)
              (let
                [byte : i64 (stdlib.process_runtime.byte-at ptr i)]
                (begin
                  (byte_buf_core.byte-buf-builder-push block (cast byte : u8))
                  (if (= byte 0)
                    (set! done true)
                    (set! i (+ i 1))))))
            unit))))))

;: Build the double-NUL-terminated CreateProcessA environment block from the
;: inherited environment minus overrides plus the override entries; an empty
;: override list returns 0 so the child inherits the environment.
(cfg
  windows
  (unsafe
    (define (windows-build-env [env : ProcessRuntimeEnvList]) : i64
      (unsafe
        (let
          [ov : (__tl_dyn-array u64)
            (unsafe
              (stdlib.process_runtime.build-override-cstrings env))]
          [ovc : i64 (array-length ov)]
          (if (= ovc 0)
            0
            (let
              [block : byte_buf_core.ByteBufBuilder
                (byte_buf_core.ByteBufBuilder (__tl_make-array u8 0) 0)]
              [base : (Ptr u8)
                (stdlib.process_runtime.win-get-environment-strings)]
              [i : i64 0]
              [k : i64 0]
              [done : bool false]
              (begin
                (while (not done)
                  (if (= (stdlib.process_runtime.byte-at base i) 0)
                    (set! done true)
                    (let
                      [entry : (Ptr u8)
                        (unsafe
                          (ptr-offset base i))]
                      [j : i64 i]
                      (begin
                        (while (not
                          (= (stdlib.process_runtime.byte-at base j) 0))
                          (set! j (+ j 1)))
                        (if (not
                          (stdlib.process_runtime.inherited-overridden?
                            entry
                            ov))
                          (stdlib.process_runtime.windows-push-cstr
                            (&mut block)
                            (unsafe
                              (cast (ptr->int entry) : i64)))
                          unit)
                        (set! i (+ j 1))))))
                (while (< k ovc)
                  (begin
                    (stdlib.process_runtime.windows-push-cstr
                      (&mut block)
                      (cast (array-ref ov k) : i64))
                    (set! k (+ k 1))))
                (byte_buf_core.byte-buf-builder-push (&mut block) (cast 0 : u8))
                (stdlib.process_runtime.byte-builder-addr block)))))))))

;: Close a Windows handle when it is not INVALID_HANDLE_VALUE.
(cfg
  windows
  (unsafe
    (define (windows-close-if [handle : i64]) : unit
      (unsafe
        (if (= handle -1)
          unit
          (begin
            (stdlib.process_runtime.win-close-handle handle)
            unit))))))

;: Duplicate one caller standard handle as an inheritable child handle, or -1
;: when no usable standard handle is available. Keeping the duplication local
;: avoids changing inheritable flags on the caller's own console or pipe.
(cfg
  windows
  (unsafe
    (define (windows-duplicate-standard-handle [which : i32]) : i64
      (unsafe
        (let
          [source : i64 (stdlib.process_runtime.win-get-std-handle which)]
          [current : i64 (stdlib.process_runtime.win-get-current-process)]
          [copy : (__tl_dyn-array i64) (__tl_make-array i64 1)]
          (if (or (= source 0) (= source -1))
            -1
            (if (=
              (stdlib.process_runtime.win-duplicate-handle
                current
                source
                current
                (unsafe
                  (ptr-cast (__tl_array-data copy) : (MutPtr i64)))
                0
                (cast 1 : i32)
                (cast 2 : i32))
              (cast 0 : i32))
              -1
              (array-ref copy 0))))))))

;: Create an inheritable, delete-on-close temp file and return its HANDLE, or -1.
(cfg
  windows
  (unsafe
    (define (windows-make-temp-file) : i64
      (unsafe
        (let
          [pathbuf : (__tl_dyn-array u8) (__tl_make-array u8 320)]
          [namebuf : (__tl_dyn-array u8) (__tl_make-array u8 320)]
          [prefix : (__tl_dyn-array u8) (io.c-string "tlp")]
          [path-len : i32
            (stdlib.process_runtime.win-get-temp-path
              (cast 320 : i32)
              (unsafe
                (__tl_array-data pathbuf)))]
          (if (= (cast path-len : i64) 0)
            -1
            (let
              [name-result : i32
                (stdlib.process_runtime.win-get-temp-file-name
                  (io.array-const-ptr pathbuf)
                  (io.array-const-ptr prefix)
                  (cast 0 : i32)
                  (unsafe
                    (__tl_array-data namebuf)))]
              (if (= (cast name-result : i64) 0)
                -1
                (let
                  [security : (__tl_dyn-array u64) (__tl_make-array u64 3)]
                  (begin
                    (set! (array-ref security 0) (cast 24 : u64))
                    (set! (array-ref security 1) (cast 0 : u64))
                    (set! (array-ref security 2) (cast 1 : u64))
                    (let
                      [handle : i64
                        (stdlib.process_runtime.win-create-file
                          (io.array-const-ptr namebuf)
                          0xc0000000
                          0x3
                          (stdlib.process_runtime.array-u64-addr security)
                          2
                          0x4000100
                          0)]
                      (if (= handle -1)
                        -1
                        handle))))))))))))

;: Launch the process with stdout/stderr bound to the temp handles, wait for it
;: to exit, and return the exit code (or -1 when CreateProcessA fails).
(cfg
  windows
  (unsafe
    (define (windows-create-and-wait
      [appname-addr : i64]
      [cmdline-addr : i64]
      [env-addr : i64]
      [cwd-addr : i64]
      [out-handle : i64]
      [err-handle : i64]) : i64
      (unsafe
        (let
          [startup : (__tl_dyn-array u64) (__tl_make-array u64 13)]
          [procinfo : (__tl_dyn-array u64) (__tl_make-array u64 3)]
          (begin
            (set! (array-ref startup 0) (cast 104 : u64))
            (set! (array-ref startup 7) (shl (cast 0x100 : u64) 32))
            (set!
              (array-ref startup 10)
              (cast
                (stdlib.process_runtime.win-get-std-handle (cast -10 : i32))
                : u64))
            (set! (array-ref startup 11) (cast out-handle : u64))
            (set! (array-ref startup 12) (cast err-handle : u64))
            (let
              [created : i32
                (stdlib.process_runtime.win-create-process
                  appname-addr
                  cmdline-addr
                  0
                  0
                  (cast 1 : i32)
                  0
                  env-addr
                  cwd-addr
                  (stdlib.process_runtime.array-u64-addr startup)
                  (stdlib.process_runtime.array-u64-addr
                    (stdlib.process_runtime.process-runtime-place-shared-view
                      procinfo)))]
              (if (= created (cast 0 : i32))
                -1
                (let
                  [codebuf : (__tl_dyn-array i32) (__tl_make-array i32 1)]
                  [process-handle : i64 (cast (array-ref procinfo 0) : i64)]
                  [worker-handle : i64 (cast (array-ref procinfo 1) : i64)]
                  (begin
                    (stdlib.process_runtime.win-wait-single
                      process-handle
                      (cast -1 : i32))
                    (stdlib.process_runtime.win-get-exit-code
                      process-handle
                      (unsafe
                        (ptr-cast (__tl_array-data codebuf) : (MutPtr i32))))
                    (stdlib.process_runtime.win-close-handle process-handle)
                    (stdlib.process_runtime.win-close-handle worker-handle)
                    (stdlib.process_runtime.windows-exit-dword->status
                      (array-ref codebuf 0))))))))))))

;: Launch a process with duplicated caller standard handles, wait for its exit,
;: and return the exit code. The child writes directly to the caller's stdout
;: and stderr instead of temporary capture files.
(cfg
  windows
  (unsafe
    (define (windows-create-and-wait-inherit
      [appname-addr : i64]
      [cmdline-addr : i64]
      [env-addr : i64]
      [cwd-addr : i64]) : i64
      (unsafe
        (let
          [startup : (__tl_dyn-array u64) (__tl_make-array u64 13)]
          [procinfo : (__tl_dyn-array u64) (__tl_make-array u64 3)]
          [stdin-handle : i64
            (stdlib.process_runtime.windows-duplicate-standard-handle
              (cast -10 : i32))]
          [stdout-handle : i64
            (stdlib.process_runtime.windows-duplicate-standard-handle
              (cast -11 : i32))]
          [stderr-handle : i64
            (stdlib.process_runtime.windows-duplicate-standard-handle
              (cast -12 : i32))]
          (if (or
            (= stdin-handle -1)
            (or (= stdout-handle -1) (= stderr-handle -1)))
            (begin
              (stdlib.process_runtime.windows-close-if stdin-handle)
              (stdlib.process_runtime.windows-close-if stdout-handle)
              (stdlib.process_runtime.windows-close-if stderr-handle)
              -1)
            (begin
              (set! (array-ref startup 0) (cast 104 : u64))
              (set! (array-ref startup 7) (shl (cast 0x100 : u64) 32))
              (set! (array-ref startup 10) (cast stdin-handle : u64))
              (set! (array-ref startup 11) (cast stdout-handle : u64))
              (set! (array-ref startup 12) (cast stderr-handle : u64))
              (let
                [created : i32
                  (stdlib.process_runtime.win-create-process
                    appname-addr
                    cmdline-addr
                    0
                    0
                    (cast 1 : i32)
                    0
                    env-addr
                    cwd-addr
                    (stdlib.process_runtime.array-u64-addr startup)
                    (stdlib.process_runtime.array-u64-addr
                      (stdlib.process_runtime.process-runtime-place-shared-view
                        procinfo)))]
                (begin
                  (stdlib.process_runtime.windows-close-if stdin-handle)
                  (stdlib.process_runtime.windows-close-if stdout-handle)
                  (stdlib.process_runtime.windows-close-if stderr-handle)
                  (if (= created (cast 0 : i32))
                    -1
                    (let
                      [codebuf : (__tl_dyn-array i32) (__tl_make-array i32 1)]
                      [process-handle : i64 (cast (array-ref procinfo 0) : i64)]
                      [worker-handle : i64 (cast (array-ref procinfo 1) : i64)]
                      (begin
                        (stdlib.process_runtime.win-wait-single
                          process-handle
                          (cast -1 : i32))
                        (stdlib.process_runtime.win-get-exit-code
                          process-handle
                          (unsafe
                            (ptr-cast (__tl_array-data codebuf) : (MutPtr i32))))
                        (stdlib.process_runtime.win-close-handle process-handle)
                        (stdlib.process_runtime.win-close-handle worker-handle)
                        (stdlib.process_runtime.windows-exit-dword->status
                          (array-ref codebuf 0))))))))))))))

;: Seek a raw Windows file HANDLE and return the resulting offset.
(cfg
  windows
  (unsafe
    (define (windows-seek-handle [handle : i64] [offset : i64] [whence : i32]) : i64
      (unsafe
        (let
          [pos : (__tl_dyn-array i64) (__tl_make-array i64 1)]
          [ok : i32
            (stdlib.process_runtime.win-set-file-pointer-ex
              handle
              offset
              (unsafe
                (ptr-cast (__tl_array-data pos) : (MutPtr i64)))
              whence)]
          (if (= ok (cast 0 : i32))
            -1
            (array-ref pos 0)))))))

;: Non-Windows stub for the module-qualified helper name.
(cfg
  (not windows)
  (define (windows-seek-handle [_handle : i64] [_offset : i64] [_whence : i32]) : i64
    -1))

;: Read an entire seekable raw Windows file HANDLE into a String.
(cfg
  windows
  (unsafe
    (define (windows-read-handle-to-string [handle : i64]) : String
      (unsafe
        (let
          [end : i64
            (stdlib.process_runtime.windows-seek-handle handle 0 (cast 2 : i32))]
          (if (<= end 0)
            ""
            (if (<
              (stdlib.process_runtime.windows-seek-handle
                handle
                0
                (cast 0 : i32))
              0)
              ""
              (let
                [buf : (__tl_dyn-array u8) (__tl_make-array u8 end)]
                [offset : i64 0]
                [done : bool false]
                (begin
                  (while (if (not done)
                    (< offset end)
                    false)
                    (let
                      [remaining : i64 (- end offset)]
                      [chunk : i32
                        (if (> remaining 1048576)
                          (cast 1048576 : i32)
                          (cast remaining : i32))]
                      [readbuf : (__tl_dyn-array i32) (__tl_make-array i32 1)]
                      [ok : i32
                        (stdlib.process_runtime.win-read-file
                          handle
                          (unsafe
                            (ptr-offset (stdlib.io.array-ptr buf) offset))
                          chunk
                          (unsafe
                            (ptr-cast (__tl_array-data readbuf) : (MutPtr i32)))
                          0)]
                      [read-count : i64 (cast (array-ref readbuf 0) : i64)]
                      (if (= ok (cast 0 : i32))
                        (set! done true)
                        (if (= read-count 0)
                          (set! done true)
                          (set! offset (+ offset read-count))))))
                  (unsafe
                    (string-from-bytes (stdlib.io.array-const-ptr buf) offset)))))))))))

;: Non-Windows stub for the module-qualified helper name.
(cfg
  (not windows)
  (define (windows-read-handle-to-string [_handle : i64]) : String
    ""))

;: Windows captured-output runtime: redirect stdout/stderr to temp files, run
;: the process to completion, and read the captured output back.
(cfg
  windows
  (unsafe
    (define (windows-output [command : ProcessRuntimeCommand]) : ResultProcessRuntimeOutput
      (unsafe
        (let
          [appname-addr : i64
            (stdlib.process_runtime.array-u8-addr
              (io.c-string (stdlib.process_runtime.command-executable command)))]
          [cmdline-addr : i64
            (stdlib.process_runtime.array-u8-addr
              (io.c-string
                (stdlib.process_runtime.windows-cmdline
                  (stdlib.process_runtime.process-runtime-place-shared-view
                    command))))]
          [env-addr : i64 0]
          [cwd-addr : i64
            (unsafe
              (stdlib.process_runtime.maybe-cstring-addr
                (stdlib.process_runtime.command-cwd command)))]
          [out-handle : i64 -1]
          [err-handle : i64 -1]
          (begin
            (set!
              env-addr
              (stdlib.process_runtime.windows-build-env
                (stdlib.process_runtime.command-env command)))
            (set! out-handle (stdlib.process_runtime.windows-make-temp-file))
            (set! err-handle (stdlib.process_runtime.windows-make-temp-file))
            (if (or (= out-handle -1) (= err-handle -1))
              (begin
                (stdlib.process_runtime.windows-close-if out-handle)
                (stdlib.process_runtime.windows-close-if err-handle)
                (stdlib.process_runtime.wait-error))
              (let
                [status : i64 -1]
                (begin
                  (set!
                    status
                    (stdlib.process_runtime.windows-create-and-wait
                      appname-addr
                      cmdline-addr
                      env-addr
                      cwd-addr
                      out-handle
                      err-handle))
                  (if (< status 0)
                    (begin
                      (stdlib.process_runtime.windows-close-if out-handle)
                      (stdlib.process_runtime.windows-close-if err-handle)
                      (stdlib.process_runtime.spawn-error))
                    (let
                      [stdout-text : String
                        (stdlib.process_runtime.windows-read-handle-to-string
                          out-handle)]
                      [stderr-text : String
                        (stdlib.process_runtime.windows-read-handle-to-string
                          err-handle)]
                      (begin
                        (stdlib.process_runtime.windows-close-if out-handle)
                        (stdlib.process_runtime.windows-close-if err-handle)
                        (stdlib.process_runtime.output-ok
                          status
                          stdout-text
                          stderr-text)))))))))))))

;: Windows inherited-stream runtime: launch with duplicated caller standard
;: handles so stdout/stderr remain live, then return the child exit status.
(cfg
  windows
  (unsafe
    (define (windows-inherit [command : ProcessRuntimeCommand]) : ResultProcessRuntimeOutput
      (unsafe
        (let
          [appname-addr : i64
            (stdlib.process_runtime.array-u8-addr
              (io.c-string (stdlib.process_runtime.command-executable command)))]
          [cmdline-addr : i64
            (stdlib.process_runtime.array-u8-addr
              (io.c-string
                (stdlib.process_runtime.windows-cmdline
                  (stdlib.process_runtime.process-runtime-place-shared-view
                    command))))]
          [env-addr : i64
            (stdlib.process_runtime.windows-build-env
              (stdlib.process_runtime.command-env command))]
          [cwd-addr : i64
            (unsafe
              (stdlib.process_runtime.maybe-cstring-addr
                (stdlib.process_runtime.command-cwd command)))]
          [status : i64 -1]
          (begin
            (set!
              status
              (stdlib.process_runtime.windows-create-and-wait-inherit
                appname-addr
                cmdline-addr
                env-addr
                cwd-addr))
            (if (< status 0)
              (stdlib.process_runtime.spawn-error)
              (stdlib.process_runtime.output-ok status "" ""))))))))

;; ---------------------------------------------------------------------------
;; Cross-target runtime entry points consumed by tl.
;; ---------------------------------------------------------------------------
;: Run a command and capture stdout, stderr, and exit status.
;: The caller must have validated command storage, the implementation count
;: cap, and every C-string-bound field through `stdlib.process`.
(unsafe
  ;; lint-allow: function-name-case -- stable runtime ABI symbol
  (define (tl_process_output [command : ProcessRuntimeCommand]) : ResultProcessRuntimeOutput
    (unsafe
      (cfg
        windows
        (stdlib.process_runtime.windows-output command)
        (stdlib.process_runtime.linux-output command)))))

;: Run a command with child stdout/stderr inherited from the caller and return
;: its status with no captured output payload.
;: The same validated-command preconditions as `tl_process_output` apply.
(unsafe
  ;; lint-allow: function-name-case -- stable runtime ABI symbol
  (define (tl_process_inherit [command : ProcessRuntimeCommand]) : ResultProcessRuntimeOutput
    (unsafe
      (cfg
        windows
        (stdlib.process_runtime.windows-inherit command)
        (stdlib.process_runtime.linux-inherit command)))))

;: Start a command without waiting; Windows reports async as unsupported.
;: The same validated-command preconditions as `tl_process_output` apply.
(unsafe
  ;; lint-allow: function-name-case -- stable runtime ABI symbol
  (define (tl_process_start [command : ProcessRuntimeCommand]) : ResultProcessRuntimeChild
    (unsafe
      (cfg
        windows
        (stdlib.process_runtime.async-unsupported-child)
        (stdlib.process_runtime.linux-start command)))))

;: Wait for a started child; Windows reports async as unsupported.
(unsafe
  ;; lint-allow: function-name-case -- stable runtime ABI symbol
  (define (tl_process_wait [child : ProcessRuntimeChild]) : ResultProcessRuntimeOutput
    (unsafe
      (cfg
        windows
        (stdlib.process_runtime.async-unsupported-output)
        (stdlib.process_runtime.linux-wait child)))))
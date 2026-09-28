;# Borrowed process command storage companion surface.
;#
;# `ProcessBorrowedCommand` stores executable, argv, cwd, env, and stdin text as
;# `(& lifetime str)` values without copying at each builder step. Rendering to
;# the runtime-owned `ProcessCommand` copies at the explicit compatibility
;# boundary.
;#
;# This module remains separate from `process.tl` as the explicit borrowed
;# storage companion. Runtime wrappers validate borrowed commands and copy once
;# at the owned `ProcessCommand` boundary before calling `process.tl`.
;#
;# Borrowed argv and env lists are dense arrays of typed references, so safe
;# constructors cannot inject raw reference words. Bytes are not copied before
;# the explicit owned boundary.
(import stdlib.io)

;: Borrowed process argument strings in argv order: `items[0 .. len)`. All
;: entries share one lifetime; use owned conversion to join independently
;: scoped text. Extending a list whose `len` is its backing length appends in
;: place; any other list copies its entries first, so a retained shorter list
;: never observes a later extension. A `len` outside `[0, (array-length
;: items)]` is malformed storage that validation rejects.
(defstruct ProcessBorrowedStringList
  (:lifetimes text)
  (items (__tl_dyn-array (& text str)))
  (len i64))

;: Optional borrowed string value used for cwd and stdin configuration.
(defenum ProcessBorrowedMaybeString
  (:lifetimes text)
  (ProcessBorrowedNoString)
  (ProcessBorrowedSomeString (& text str)))

;: Borrowed environment name/value pair. Both strings share the `text` lifetime.
(defstruct ProcessBorrowedEnvEntry
  (:lifetimes text)
  (name (& text str))
  (value (& text str)))

;: Borrowed environment overrides: `len` name/value pairs in `items`, stored
;: in reverse override order so that prepending an override (`env-cons`,
;: `command-with-env`) extends the backing array the way an argv append does.
;: Override `i` in list order is the pair at `items[2 * (len - 1 - i)]`.
;: Extension and malformed storage follow `ProcessBorrowedStringList`, with
;: two items per entry.
(defstruct ProcessBorrowedEnvList
  (:lifetimes text)
  (items (__tl_dyn-array (& text str)))
  (len i64))

;: Borrowed mirror of the public command-storage count cap.
(define process-borrowed-storage-max-count : i64
  4096)

;: Borrowed mirror of the per-field C-string byte cap.
(define process-borrowed-storage-max-string-bytes : i64
  1048576)

;: Borrowed process command data. The process runtime still receives owned
;: `ProcessCommand` values; borrowed commands copy at that explicit boundary.
(defstruct ProcessBorrowedCommand
  (:lifetimes executable argv cwd env stdin)
  (executable (& executable str))
  (argv (ProcessBorrowedStringList argv))
  (cwd (ProcessBorrowedMaybeString cwd))
  (env (ProcessBorrowedEnvList env))
  (stdin (ProcessBorrowedMaybeString stdin)))

;: Internal wrapper around a borrowed process argument list.
(defstruct ProcessBorrowedStringListRef
  (:lifetimes text value)
  (value (& value (ProcessBorrowedStringList text))))

;: Internal wrapper around a borrowed process environment list.
(defstruct ProcessBorrowedEnvListRef
  (:lifetimes text value)
  (value (& value (ProcessBorrowedEnvList text))))

;: Internal wrapper around a borrowed optional process string.
(defstruct ProcessBorrowedMaybeStringRef
  (:lifetimes text value)
  (value (& value (ProcessBorrowedMaybeString text))))

;: Re-expose a borrowed argument list through the compatibility surface. The
;: copy shares the backing array; its own `len` keeps later extensions of
;: either value invisible to the other.
(define (borrowed-string-list-shared-view
  [value : (& value (ProcessBorrowedStringList text))]) : (ProcessBorrowedStringList
    text)
  (let
    [cell : (ProcessBorrowedStringListRef text value)
      (ProcessBorrowedStringListRef value)]
    [address : u64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of cell) : (Ptr u64))))]
    (unsafe
      (ptr-read (int->ptr address : (Ptr (ProcessBorrowedStringList text)))))))

;: Re-expose a borrowed environment list through the compatibility surface,
;: sharing its backing array as `borrowed-string-list-shared-view` does.
(define (borrowed-env-list-shared-view
  [value : (& value (ProcessBorrowedEnvList text))]) : (ProcessBorrowedEnvList
    text)
  (let
    [cell : (ProcessBorrowedEnvListRef text value)
      (ProcessBorrowedEnvListRef value)]
    [address : u64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of cell) : (Ptr u64))))]
    (unsafe
      (ptr-read (int->ptr address : (Ptr (ProcessBorrowedEnvList text)))))))

;: Re-expose a borrowed optional string through the compatibility surface.
(define (borrowed-maybe-string-shared-view
  [value : (& value (ProcessBorrowedMaybeString text))]) : (ProcessBorrowedMaybeString
    text)
  (let
    [cell : (ProcessBorrowedMaybeStringRef text value)
      (ProcessBorrowedMaybeStringRef value)]
    [address : u64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of cell) : (Ptr u64))))]
    (unsafe
      (ptr-read (int->ptr address : (Ptr (ProcessBorrowedMaybeString text)))))))

;: The entries of a run that may be extended: `items` itself when `len` is
;: its backing length, otherwise fresh storage holding a copy of
;: `items[0 .. len)`. Callers pass a well-formed `len`.
(define (text-run-extendable
  [items : (__tl_dyn-array (& text str))]
  [len : i64]) : (__tl_dyn-array (& text str))
  (if (= (array-length items) len)
    items
    (let
      [fresh : (__tl_dyn-array (& text str))
        (init : (__tl_dyn-array (& text str)))]
      [index : i64 0]
      (begin
        (while (< index len)
          (begin
            (__tl_array-push! fresh (array-ref items index))
            (set! index (+ index 1))))
        fresh))))

;: Return `items[0 .. len)` followed by `extra[0 .. count)`.
(define (text-run-extend
  [items : (__tl_dyn-array (& text str))]
  [len : i64]
  [extra : (__tl_dyn-array (& text str))]
  [count : i64]) : (__tl_dyn-array (& text str))
  (let
    [out : (__tl_dyn-array (& text str)) (text-run-extendable items len)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (__tl_array-push! out (array-ref extra index))
          (set! index (+ index 1))))
      out)))

;: True when `len` entries of `width` items each fit a backing array of
;: `backing` items.
(define (text-run-storage-ok? [backing : i64] [len : i64] [width : i64]) : bool
  (and (>= len 0) (<= len (/ backing width))))

;: Return an empty borrowed argument list tied to `text` without storing it.
(define (args-empty-like [_text : (& text str)]) : (ProcessBorrowedStringList
    text)
  (ProcessBorrowedStringList (init : (__tl_dyn-array (& text str))) 0))

;: True when `args` is well-formed dense storage.
(define (args-storage-ok? [args : (& args (ProcessBorrowedStringList text))]) : bool
  (text-run-storage-ok? (array-length args.items) args.len 1))

;: The entry count of well-formed `args`; malformed storage panics.
(define (args-live-len [args : (& args (ProcessBorrowedStringList text))]) : i64
  (if (args-storage-ok? args)
    args.len
    (io.panic "process: argument storage is malformed")))

;: Return the number of borrowed argv entries in `args`, saturated at one past
;: the implementation cap for oversized or malformed storage.
(define (args-count [args : (& args (ProcessBorrowedStringList text))]) : i64
  (if (and
    (args-storage-ok? args)
    (<= args.len process-borrowed-storage-max-count))
    args.len
    (+ process-borrowed-storage-max-count 1)))

;: Return the borrowed argv entry at a valid `index`. Callers must validate
;: indexes against `args-count`; no owned string is created.
(define (args-ref
  [args : (& args (ProcessBorrowedStringList text))]
  [index : i64]) : (& text str)
  (if (and (>= index 0) (< index (args-live-len args)))
    (array-ref args.items index)
    (io.panic "process: borrowed argument index out of bounds")))

;: Prepend a borrowed argument string to an argv list without copying bytes.
;: This copies the existing entries; build long lists by appending.
(define (args-cons
  [value : (& text str)]
  [rest : (ProcessBorrowedStringList text)]) : (ProcessBorrowedStringList text)
  (args-append (args-single value) rest))

;: Return a one-element borrowed argument list.
(define (args-single [value : (& text str)]) : (ProcessBorrowedStringList text)
  (let
    [items : (__tl_dyn-array (& text str))
      (init : (__tl_dyn-array (& text str)))]
    (begin
      (__tl_array-push! items value)
      (ProcessBorrowedStringList items 1))))

;: Concatenate two borrowed argument lists while preserving argv order.
(define (args-append
  [left : (ProcessBorrowedStringList text)]
  [right : (ProcessBorrowedStringList text)]) : (ProcessBorrowedStringList text)
  (let
    [left-len : i64 (args-live-len (& left))]
    [right-len : i64 (args-live-len (& right))]
    (ProcessBorrowedStringList
      (text-run-extend left.items left-len right.items right-len)
      (+ left-len right-len))))

;: Return an empty borrowed environment override list tied to `text`.
(define (env-empty-like [_text : (& text str)]) : (ProcessBorrowedEnvList text)
  (ProcessBorrowedEnvList (init : (__tl_dyn-array (& text str))) 0))

;: True when `env` is well-formed dense storage.
(define (env-storage-ok? [env : (& env (ProcessBorrowedEnvList text))]) : bool
  (text-run-storage-ok? (array-length env.items) env.len 2))

;: The override count of well-formed `env`; malformed storage panics.
(define (env-live-len [env : (& env (ProcessBorrowedEnvList text))]) : i64
  (if (env-storage-ok? env)
    env.len
    (io.panic "process: environment storage is malformed")))

;: Return the number of borrowed env overrides in `env`, saturated at one past
;: the implementation cap for oversized or malformed storage.
(define (env-count [env : (& env (ProcessBorrowedEnvList text))]) : i64
  (if (and
    (env-storage-ok? env)
    (<= env.len process-borrowed-storage-max-count))
    env.len
    (+ process-borrowed-storage-max-count 1)))

;: Index in `items` of the name of override `index` in list order.
(define (env-item-index
  [env : (& env (ProcessBorrowedEnvList text))]
  [index : i64]) : i64
  (let
    [len : i64 (env-live-len env)]
    (if (and (>= index 0) (< index len))
      (* 2 (- (- len 1) index))
      (io.panic "process: borrowed environment index out of bounds"))))

;: Return a borrowed environment entry at a valid `index`.
(define (env-entry-ref
  [env : (& env (ProcessBorrowedEnvList text))]
  [index : i64]) : (ProcessBorrowedEnvEntry text)
  (let
    [at : i64 (env-item-index env index)]
    (ProcessBorrowedEnvEntry
      (array-ref env.items at)
      (array-ref env.items (+ at 1)))))

;: Return a borrowed environment name at a valid `index`.
(define (env-name-ref
  [env : (& env (ProcessBorrowedEnvList text))]
  [index : i64]) : (& text str)
  (array-ref env.items (env-item-index env index)))

;: Return a borrowed environment value at a valid `index`.
(define (env-value-ref
  [env : (& env (ProcessBorrowedEnvList text))]
  [index : i64]) : (& text str)
  (array-ref env.items (+ (env-item-index env index) 1)))

;: Prepend borrowed environment override strings without copying bytes.
(define (env-cons
  [name : (& text str)]
  [value : (& text str)]
  [rest : (ProcessBorrowedEnvList text)]) : (ProcessBorrowedEnvList text)
  (let
    [len : i64 (env-live-len (& rest))]
    [items : (__tl_dyn-array (& text str))
      (text-run-extendable rest.items (* 2 len))]
    (begin
      (__tl_array-push! items name)
      (__tl_array-push! items value)
      (ProcessBorrowedEnvList items (+ len 1)))))

;: Return a one-element borrowed environment override list.
(define (env-single [name : (& text str)] [value : (& text str)]) : (ProcessBorrowedEnvList
    text)
  (env-cons name value (env-empty-like name)))

;: Concatenate borrowed environment override lists while preserving override
;: order. Duplicate names are preserved in list order.
(define (env-append
  [left : (ProcessBorrowedEnvList text)]
  [right : (ProcessBorrowedEnvList text)]) : (ProcessBorrowedEnvList text)
  (let
    [left-len : i64 (env-live-len (& left))]
    [right-len : i64 (env-live-len (& right))]
    ;; Stored in reverse override order, `left ++ right` is right's items
    ;; followed by left's.
    (ProcessBorrowedEnvList
      (text-run-extend right.items (* 2 right-len) left.items (* 2 left-len))
      (+ left-len right-len))))

;: Return a borrowed stdin/cwd value that stores no string but keeps the target
;: type lifetime anchored to `text`.
(define (no-string-like [_text : (& text str)]) : (ProcessBorrowedMaybeString
    text)
  ProcessBorrowedNoString)

;: Return a borrowed stdin/cwd value without copying bytes.
(define (some-string [value : (& text str)]) : (ProcessBorrowedMaybeString text)
  (ProcessBorrowedSomeString value))

;: Return `args` through an aggregate return path for imported callers.
(define (args-normalize [args : (ProcessBorrowedStringList text)]) : (ProcessBorrowedStringList
    text)
  args)

;: Return `env` through an aggregate return path for imported callers.
(define (env-normalize [env : (ProcessBorrowedEnvList text)]) : (ProcessBorrowedEnvList
    text)
  env)

;: Return `value` through an aggregate return path for imported callers.
(define (maybe-normalize [value : (ProcessBorrowedMaybeString text)]) : (ProcessBorrowedMaybeString
    text)
  value)

;: Return the borrowed executable path from `command`.
(define (command-executable
  [command : (& command (ProcessBorrowedCommand executable argv cwd env stdin))]) : (&
    executable
    str)
  command.executable)

;: Return the borrowed argv list from `command`.
(define (command-argv
  [command : (& command (ProcessBorrowedCommand executable argv cwd env stdin))]) : (ProcessBorrowedStringList
    argv)
  (borrowed-string-list-shared-view command.argv))

;: Return the borrowed cwd setting from `command`.
(define (command-cwd
  [command : (& command (ProcessBorrowedCommand executable argv cwd env stdin))]) : (ProcessBorrowedMaybeString
    cwd)
  (borrowed-maybe-string-shared-view command.cwd))

;: Return the borrowed env override list from `command`.
(define (command-env
  [command : (& command (ProcessBorrowedCommand executable argv cwd env stdin))]) : (ProcessBorrowedEnvList
    env)
  (borrowed-env-list-shared-view command.env))

;: Return the borrowed stdin setting from `command`.
(define (command-stdin
  [command : (& command (ProcessBorrowedCommand executable argv cwd env stdin))]) : (ProcessBorrowedMaybeString
    stdin)
  (borrowed-maybe-string-shared-view command.stdin))

(import stdlib.process)
(import stdlib.string)

;: Copy a borrowed string into active-arena owned storage.
(define (string-owned [value : (& value str)]) : String
  (string.substring value 0 (string-length value)))

;: Copy borrowed argv storage to the owned process argv representation.
(define (args-owned [args : (& args (ProcessBorrowedStringList text))]) : process.ProcessStringList
  (let
    [n : i64 (args-live-len args)]
    (if (> n process-borrowed-storage-max-count)
      (io.panic "process: command storage limit exceeded")
      (let
        [slots : (__tl_dyn-array String) (__tl_make-array String n)]
        [index : i64 0]
        (begin
          (while (< index n)
            (begin
              (set!
                (array-ref slots index)
                (string-owned (array-ref args.items index)))
              (set! index (+ index 1))))
          (process.ProcessStringList slots))))))

;: Copy borrowed env storage to the owned process env representation, in
;: override order.
(define (env-owned [env : (& env (ProcessBorrowedEnvList text))]) : process.ProcessEnvList
  (let
    [n : i64 (env-live-len env)]
    (if (> n process-borrowed-storage-max-count)
      (io.panic "process: command storage limit exceeded")
      (let
        [names : (__tl_dyn-array String) (__tl_make-array String n)]
        [values : (__tl_dyn-array String) (__tl_make-array String n)]
        [index : i64 0]
        (begin
          (while (< index n)
            (let
              [at : i64 (* 2 (- (- n 1) index))]
              (begin
                (set!
                  (array-ref names index)
                  (string-owned (array-ref env.items at)))
                (set!
                  (array-ref values index)
                  (string-owned (array-ref env.items (+ at 1))))
                (set! index (+ index 1)))))
          (process.ProcessEnvList names values))))))

;: Copy a borrowed optional string to the owned process representation.
(define (maybe-owned [value : (ProcessBorrowedMaybeString text)]) : process.ProcessMaybeString
  (match (maybe-normalize value)
    [(ProcessBorrowedNoString) (process.no-stdin)]
    [(ProcessBorrowedSomeString text)
      (process.stdin-string (string-owned text))]))

;: Construct a borrowed command with default cwd, env, and stdin settings.
(define (command
  [executable : (& executable str)]
  [argv : (ProcessBorrowedStringList argv)]) : (ProcessBorrowedCommand
    executable
    argv
    executable
    executable
    executable)
  (ProcessBorrowedCommand
    executable
    argv
    (no-string-like executable)
    (env-empty-like executable)
    (no-string-like executable)))

;: Construct a borrowed command with no argv entries.
(define (command-empty [executable : (& executable str)]) : (ProcessBorrowedCommand
    executable
    executable
    executable
    executable
    executable)
  (command executable (args-empty-like executable)))

;: Return a borrowed command copy with the full argv list replaced.
(define (command-with-argv
  [command : (& command (ProcessBorrowedCommand executable argv cwd env stdin))]
  [args : (ProcessBorrowedStringList next-argv)]) : (ProcessBorrowedCommand
    executable
    next-argv
    cwd
    env
    stdin)
  (ProcessBorrowedCommand
    (command-executable command)
    args
    (command-cwd command)
    (command-env command)
    (command-stdin command)))

;: Return a borrowed command copy with `args` appended after existing argv
;: entries. The appended list must share the command argv lifetime.
(define (command-with-args
  [command : (& command (ProcessBorrowedCommand executable argv cwd env stdin))]
  [args : (ProcessBorrowedStringList argv)]) : (ProcessBorrowedCommand
    executable
    argv
    cwd
    env
    stdin)
  (ProcessBorrowedCommand
    (command-executable command)
    (args-append (command-argv command) args)
    (command-cwd command)
    (command-env command)
    (command-stdin command)))

;: Construct a borrowed process command with every field supplied explicitly.
(define (command-full
  [executable : (& executable str)]
  [argv : (ProcessBorrowedStringList argv)]
  [cwd : (ProcessBorrowedMaybeString cwd)]
  [env : (ProcessBorrowedEnvList env)]
  [stdin : (ProcessBorrowedMaybeString stdin)]) : (ProcessBorrowedCommand
    executable
    argv
    cwd
    env
    stdin)
  (ProcessBorrowedCommand executable argv cwd env stdin))

;: Return a borrowed command copy with cwd set to `cwd`.
(define (command-with-cwd
  [command : (& command (ProcessBorrowedCommand executable argv cwd env stdin))]
  [cwd : (& next-cwd str)]) : (ProcessBorrowedCommand
    executable
    argv
    next-cwd
    env
    stdin)
  (ProcessBorrowedCommand
    (command-executable command)
    (command-argv command)
    (some-string cwd)
    (command-env command)
    (command-stdin command)))

;: Return a borrowed command copy with an additional env override. The new
;: override must share the existing env-list lifetime.
(define (command-with-env
  [command : (& command (ProcessBorrowedCommand executable argv cwd env stdin))]
  [name : (& env str)]
  [value : (& env str)]) : (ProcessBorrowedCommand
    executable
    argv
    cwd
    env
    stdin)
  (ProcessBorrowedCommand
    (command-executable command)
    (command-argv command)
    (command-cwd command)
    (env-cons name value (command-env command))
    (command-stdin command)))

;: Return a borrowed command copy with the full env override list replaced.
(define (command-with-env-list
  [command : (& command (ProcessBorrowedCommand executable argv cwd env stdin))]
  [env : (ProcessBorrowedEnvList next-env)]) : (ProcessBorrowedCommand
    executable
    argv
    cwd
    next-env
    stdin)
  (ProcessBorrowedCommand
    (command-executable command)
    (command-argv command)
    (command-cwd command)
    env
    (command-stdin command)))

;: Return a borrowed command copy with stdin set to `stdin`.
(define (command-with-stdin
  [command : (& command (ProcessBorrowedCommand executable argv cwd env stdin))]
  [stdin-value : (& next-stdin str)]) : (ProcessBorrowedCommand
    executable
    argv
    cwd
    env
    next-stdin)
  (ProcessBorrowedCommand
    (command-executable command)
    (command-argv command)
    (command-cwd command)
    (command-env command)
    (some-string stdin-value)))

;: Copy borrowed command storage to the owned runtime command representation.
(define (command-owned
  [command : (& command (ProcessBorrowedCommand executable argv cwd env stdin))]) : process.ProcessCommand
  (let
    [argv-view : (ProcessBorrowedStringList argv) (command-argv command)]
    [cwd-view : (ProcessBorrowedMaybeString cwd) (command-cwd command)]
    [env-view : (ProcessBorrowedEnvList env) (command-env command)]
    [stdin-view : (ProcessBorrowedMaybeString stdin) (command-stdin command)]
    (process.command-full
      (string-owned (command-executable command))
      (args-owned argv-view)
      (maybe-owned cwd-view)
      (env-owned env-view)
      (maybe-owned stdin-view))))

;: Return the first borrowed argv validation error, including the storage cap
;: and malformed storage, or `ProcessNoString`. Entries are checked in argv
;: order and the cap applies at the first entry past it.
(define (args-validation-error
  [args : (& args (ProcessBorrowedStringList text))]) : process.ProcessMaybeString
  (if (not (args-storage-ok? args))
    (process.stdin-string "process: argument storage is malformed")
    (let
      [index : i64 0]
      [message : String ""]
      [found : bool false]
      (begin
        (while (and (< index args.len) (not found))
          (let
            [value : (& text str) (array-ref args.items index)]
            (begin
              (cond
                [(>= index process-borrowed-storage-max-count)
                  (begin
                    (set! message "process: argument storage limit exceeded")
                    (set! found true))]
                [(>
                    (string-length value)
                    process-borrowed-storage-max-string-bytes)
                  (begin
                    (set! message "process: argument exceeds storage limit")
                    (set! found true))]
                [(process.string-contains-char? value '\0')
                  (begin
                    (set! message "process: argument contains NUL")
                    (set! found true))]
                [else unit])
              (set! index (+ index 1)))))
        (if found
          (process.stdin-string message)
          (process.no-stdin))))))

;: Return the first borrowed environment validation error in override order,
;: including the storage cap and malformed storage, or `ProcessNoString`.
(define (env-validation-error [env : (& env (ProcessBorrowedEnvList text))]) : process.ProcessMaybeString
  (if (not (env-storage-ok? env))
    (process.stdin-string "process: environment storage is malformed")
    (let
      [index : i64 0]
      [message : String ""]
      [found : bool false]
      (begin
        (while (and (< index env.len) (not found))
          (let
            [at : i64 (* 2 (- (- env.len 1) index))]
            [name : (& text str) (array-ref env.items at)]
            [value : (& text str) (array-ref env.items (+ at 1))]
            (begin
              (cond
                [(>= index process-borrowed-storage-max-count)
                  (begin
                    (set! message "process: environment storage limit exceeded")
                    (set! found true))]
                [(= (string-length name) 0)
                  (begin
                    (set! message "process: environment variable name is empty")
                    (set! found true))]
                [(process.string-contains-char? name '=')
                  (begin
                    (set!
                      message
                      "process: environment variable name contains '='")
                    (set! found true))]
                [(>
                    (string-length name)
                    process-borrowed-storage-max-string-bytes)
                  (begin
                    (set!
                      message
                      "process: environment variable name exceeds storage limit")
                    (set! found true))]
                [(>
                    (string-length value)
                    process-borrowed-storage-max-string-bytes)
                  (begin
                    (set!
                      message
                      "process: environment variable value exceeds storage limit")
                    (set! found true))]
                [(process.string-contains-char? name '\0')
                  (begin
                    (set!
                      message
                      "process: environment variable name contains NUL")
                    (set! found true))]
                [(process.string-contains-char? value '\0')
                  (begin
                    (set!
                      message
                      "process: environment variable value contains NUL")
                    (set! found true))]
                [else unit])
              (set! index (+ index 1)))))
        (if found
          (process.stdin-string message)
          (process.no-stdin))))))

;: Return the first borrowed command validation error, or `ProcessNoString`.
(define (command-validation-error
  [command : (& command (ProcessBorrowedCommand executable argv cwd env stdin))]) : process.ProcessMaybeString
  (let
    [argv-view : (ProcessBorrowedStringList argv) (command-argv command)]
    [env-view : (ProcessBorrowedEnvList env) (command-env command)]
    (cond
      [(= (string-length (command-executable command)) 0)
        (process.stdin-string "process: executable path is empty")]
      [(>
          (string-length (command-executable command))
          process-borrowed-storage-max-string-bytes)
        (process.stdin-string "process: executable path exceeds storage limit")]
      [(process.string-contains-char? (command-executable command) '\0')
        (process.stdin-string "process: executable path contains NUL")]
      [else
        (match (args-validation-error argv-view)
          [(process.ProcessSomeString message) (process.stdin-string message)]
          [(process.ProcessNoString)
            (match (maybe-normalize (command-cwd command))
              [(ProcessBorrowedSomeString cwd)
                (cond
                  [(= (string-length cwd) 0)
                    (process.stdin-string "process: cwd path is empty")]
                  [(>
                      (string-length cwd)
                      process-borrowed-storage-max-string-bytes)
                    (process.stdin-string
                      "process: cwd path exceeds storage limit")]
                  [(process.string-contains-char? cwd '\0')
                    (process.stdin-string "process: cwd path contains NUL")]
                  [else (env-validation-error env-view)])]
              [(ProcessBorrowedNoString) (env-validation-error env-view)])])])))

;: Return true when a borrowed command passes stdlib validation.
(define (command-valid?
  [command : (& command (ProcessBorrowedCommand executable argv cwd env stdin))]) : bool
  (let
    [info : process.ProcessMaybeStringInfo
      (process.maybe-string-info (command-validation-error command))]
    (not (process.maybe-string-info-present? info))))

;: Run a borrowed command by validating borrowed storage, copying to an owned
;: command at the runtime boundary, then using `output`.
(define (output
  [command : (& command (ProcessBorrowedCommand executable argv cwd env stdin))]) : process.ResultProcessOutput
  (let
    [info : process.ProcessMaybeStringInfo
      (process.maybe-string-info (command-validation-error command))]
    (if (process.maybe-string-info-present? info)
      (process.ErrProcessOutput
        (process.ProcessInvalidCommand (process.maybe-string-info-value info)))
      (process.output (command-owned command)))))

;: Run a borrowed command using the same captured-output path as
;: `output`.
(define (run
  [command : (& command (ProcessBorrowedCommand executable argv cwd env stdin))]) : process.ResultProcessOutput
  (output command))

;: Start a borrowed command after validation and owned runtime conversion.
(define (start
  [command : (& command (ProcessBorrowedCommand executable argv cwd env stdin))]) : process.ResultProcessChild
  (let
    [info : process.ProcessMaybeStringInfo
      (process.maybe-string-info (command-validation-error command))]
    (if (process.maybe-string-info-present? info)
      (process.ErrProcessChild
        (process.ProcessInvalidCommand (process.maybe-string-info-value info)))
      (process.start (command-owned command)))))

;: Inline test helper that forces a borrowed process test failure.
(define (test-fail) : unit
  (begin
    (/ 1 0)
    unit))

;: Build one owned test string with an embedded NUL byte.
(define (test-string-with-nul) : String
  (let
    [bytes : (__tl_dyn-array u8) (__tl_make-array u8 3)]
    [dst : (MutPtr u8)
      (unsafe
        (__tl_array-data bytes))]
    (begin
      (set! (array-ref bytes 0) (cast 'a' : u8))
      (set! (array-ref bytes 1) (cast 0 : u8))
      (set! (array-ref bytes 2) (cast 'b' : u8))
      (unsafe
        (string-from-bytes (ptr-cast dst : (Ptr u8)) 3)))))

;: Inline test assertion for boolean true.
(define (test-assert-true [condition : bool]) : unit
  (if condition
    unit
    (test-fail)))

;: Inline test assertion for boolean false.
(define (test-assert-false [condition : bool]) : unit
  (test-assert-true (not condition)))

;: Inline test assertion for integer equality.
(define (test-assert-i64-eq [actual : i64] [expected : i64]) : unit
  (test-assert-true (= actual expected)))

;: Inline test assertion for owned process strings.
(define (test-assert-owned-string-eq [actual : String] [expected : String]) : unit
  (test-assert-true (string.eq actual expected)))

;: Inline test assertion for a one-element owned process string list.
(define (test-assert-process-string-list1
  [items : process.ProcessStringList]
  [first : String]) : unit
  (let
    [step : process.ProcessStringStep (process.string-step items)]
    (if (process.string-step-present? step)
      (let
        [rest-step : process.ProcessStringStep
          (process.string-step (process.string-step-rest step))]
        (if (process.string-step-present? rest-step)
          (test-fail)
          (test-assert-owned-string-eq (process.string-step-value step) first)))
      (test-fail))))

;: Inline test assertion for a three-element owned process string list.
(define (test-assert-process-string-list3
  [items : process.ProcessStringList]
  [first : String]
  [second : String]
  [third : String]) : unit
  (let
    [a : process.ProcessStringStep (process.string-step items)]
    (if (not (process.string-step-present? a))
      (test-fail)
      (let
        [b : process.ProcessStringStep
          (process.string-step (process.string-step-rest a))]
        (if (not (process.string-step-present? b))
          (test-fail)
          (let
            [c : process.ProcessStringStep
              (process.string-step (process.string-step-rest b))]
            (if (not (process.string-step-present? c))
              (test-fail)
              (let
                [tail : process.ProcessStringStep
                  (process.string-step (process.string-step-rest c))]
                (if (process.string-step-present? tail)
                  (test-fail)
                  (begin
                    (test-assert-owned-string-eq
                      (process.string-step-value a)
                      first)
                    (test-assert-owned-string-eq
                      (process.string-step-value b)
                      second)
                    (test-assert-owned-string-eq
                      (process.string-step-value c)
                      third)))))))))))

;: Inline test assertion for an owned optional process string.
(define (test-assert-process-some-string
  [value : process.ProcessMaybeString]
  [expected : String]) : unit
  (let
    [info : process.ProcessMaybeStringInfo (process.maybe-string-info value)]
    (if (process.maybe-string-info-present? info)
      (test-assert-owned-string-eq
        (process.maybe-string-info-value info)
        expected)
      (test-fail))))

;: Inline test assertion for a one-element borrowed process string list.
(define (test-assert-borrowed-string-list1
  [items : (& items (ProcessBorrowedStringList text))]
  [expected : String]) : unit
  (begin
    (test-assert-i64-eq (args-count items) 1)
    (test-assert-true (string.eq (args-ref items 0) (& expected)))))

;: Inline test assertion for a borrowed optional process string.
(define (test-assert-borrowed-some-string
  [value : (ProcessBorrowedMaybeString text)]
  [expected : String]) : unit
  (match (maybe-normalize value)
    [(ProcessBorrowedSomeString actual)
      (test-assert-true (string.eq actual (& expected)))]
    [(ProcessBorrowedNoString) (test-fail)]))

;: Inline test assertion for the head of an owned process environment list.
(define (test-assert-process-env-head
  [env : process.ProcessEnvList]
  [expected-name : String]
  [expected-value : String]) : unit
  (let
    [step : process.ProcessEnvStep (process.env-step env)]
    (if (process.env-step-present? step)
      (begin
        (test-assert-owned-string-eq (process.env-step-name step) expected-name)
        (test-assert-owned-string-eq
          (process.env-step-value step)
          expected-value))
      (test-fail))))

;: Inline test assertion for a two-element owned process environment list.
(define (test-assert-process-env-list2
  [env : process.ProcessEnvList]
  [first-name : String]
  [first-value : String]
  [second-name : String]
  [second-value : String]) : unit
  (let
    [first : process.ProcessEnvStep (process.env-step env)]
    (if (not (process.env-step-present? first))
      (test-fail)
      (let
        [second : process.ProcessEnvStep
          (process.env-step (process.env-step-rest first))]
        (if (not (process.env-step-present? second))
          (test-fail)
          (let
            [tail : process.ProcessEnvStep
              (process.env-step (process.env-step-rest second))]
            (if (process.env-step-present? tail)
              (test-fail)
              (begin
                (test-assert-owned-string-eq
                  (process.env-step-name first)
                  first-name)
                (test-assert-owned-string-eq
                  (process.env-step-value first)
                  first-value)
                (test-assert-owned-string-eq
                  (process.env-step-name second)
                  second-name)
                (test-assert-owned-string-eq
                  (process.env-step-value second)
                  second-value)))))))))

;: Inline test assertion for the head of a borrowed process environment list.
(define (test-assert-borrowed-env-head
  [env : (& env (ProcessBorrowedEnvList text))]
  [expected-name : String]
  [expected-value : String]) : unit
  (begin
    (test-assert-true (> (env-count env) 0))
    (test-assert-true (string.eq (env-name-ref env 0) (& expected-name)))
    (test-assert-true (string.eq (env-value-ref env 0) (& expected-value)))))

;: Inline test assertion for invalid borrowed process output results.
(define (test-assert-invalid-output
  [result : process.ResultProcessOutput]
  [message : String]) : unit
  (test-assert-owned-string-eq
    (process.result-error-message-or result "process: expected invalid output")
    message))

;: Inline test assertion for invalid borrowed process child results.
(define (test-assert-invalid-child
  [result : process.ResultProcessChild]
  [message : String]) : unit
  (test-assert-owned-string-eq
    (process.child-result-error-message-or
      result
      "process: expected invalid child")
    message))

;: Inline test body for borrowed process conversion helpers.
(define (test-api-check) : unit
  (let
    [exe : String "echo"]
    [arg : String "hello"]
    [cwd : String "target"]
    [env-pair : String "TL_BORROWED_PROCESS"]
    [stdin : String "stdin"]
    [argv : (ProcessBorrowedStringList arg) (args-single (& arg))]
    [env : (ProcessBorrowedEnvList env-pair)
      (env-cons (& env-pair) (& env-pair) (env-empty-like (& env-pair)))]
    [base : (ProcessBorrowedCommand exe exe exe exe exe)
      (command-empty (& exe))]
    [with-argv : (ProcessBorrowedCommand exe arg exe exe exe)
      (command-with-argv base argv)]
    [with-cwd : (ProcessBorrowedCommand exe arg cwd exe exe)
      (command-with-cwd with-argv (& cwd))]
    [with-env-list : (ProcessBorrowedCommand exe arg cwd env-pair exe)
      (command-with-env-list with-cwd env)]
    [borrowed : (ProcessBorrowedCommand exe arg cwd env-pair stdin)
      (command-with-stdin with-env-list (& stdin))]
    [owned : process.ProcessCommand (command-owned borrowed)]
    [borrowed-argv : (ProcessBorrowedStringList arg) (command-argv borrowed)]
    [borrowed-env : (ProcessBorrowedEnvList env-pair) (command-env borrowed)]
    (begin
      (test-assert-true (string.eq (command-executable borrowed) (& exe)))
      (test-assert-borrowed-string-list1 borrowed-argv "hello")
      (test-assert-i64-eq (args-count borrowed-argv) 1)
      (test-assert-borrowed-some-string (command-cwd borrowed) "target")
      (test-assert-borrowed-some-string (command-stdin borrowed) "stdin")
      (test-assert-borrowed-env-head
        borrowed-env
        "TL_BORROWED_PROCESS"
        "TL_BORROWED_PROCESS")
      (test-assert-i64-eq (env-count borrowed-env) 1)
      (test-assert-owned-string-eq (process.command-executable owned) "echo")
      (test-assert-process-string-list1 (process.command-argv owned) "hello")
      (test-assert-process-some-string (process.command-cwd owned) "target")
      (test-assert-process-some-string (process.command-stdin owned) "stdin")
      (test-assert-process-env-head
        (process.command-env owned)
        "TL_BORROWED_PROCESS"
        "TL_BORROWED_PROCESS")
      (test-assert-true (command-valid? borrowed)))))

(cfg
  test
  (define (process-borrowed-test-ordered-builders-check) : unit
    (let
      [exe : String "echo"]
      [argv-pack : String "firstsecondthird"]
      [env-pack : String "TL_DUPfirstsecond"]
      [first-arg : (& argv-pack str) (string.substring-view (& argv-pack) 0 5)]
      [second-arg : (& argv-pack str) (string.substring-view (& argv-pack) 5 6)]
      [third-arg : (& argv-pack str) (string.substring-view (& argv-pack) 11 5)]
      [empty-args : (ProcessBorrowedStringList argv-pack)
        (args-empty-like first-arg)]
      [single-arg : (ProcessBorrowedStringList argv-pack)
        (args-single first-arg)]
      [env-name : (& env-pack str) (string.substring-view (& env-pack) 0 6)]
      [env-first : (& env-pack str) (string.substring-view (& env-pack) 6 5)]
      [env-second : (& env-pack str) (string.substring-view (& env-pack) 11 6)]
      [empty-env : (ProcessBorrowedEnvList env-pack) (env-empty-like env-name)]
      [single-env : (ProcessBorrowedEnvList env-pack)
        (env-single env-name env-first)]
      [tail-argv : (ProcessBorrowedStringList argv-pack)
        (args-append (args-single second-arg) (args-single third-arg))]
      [env : (ProcessBorrowedEnvList env-pack)
        (env-append
          (env-single env-name env-first)
          (env-single env-name env-second))]
      [first-command : (ProcessBorrowedCommand exe argv-pack exe exe exe)
        (command (& exe) (args-single first-arg))]
      [args-command : (ProcessBorrowedCommand exe argv-pack exe exe exe)
        (command-with-args first-command tail-argv)]
      [cmd : (ProcessBorrowedCommand exe argv-pack exe env-pack exe)
        (command-with-env-list args-command env)]
      [owned : process.ProcessCommand (command-owned cmd)]
      [cmd-argv : (ProcessBorrowedStringList argv-pack) (command-argv cmd)]
      [cmd-env : (ProcessBorrowedEnvList env-pack) (command-env cmd)]
      (begin
        (test-assert-i64-eq (args-count empty-args) 0)
        (test-assert-i64-eq (args-count single-arg) 1)
        (test-assert-true (string.eq (args-ref single-arg 0) first-arg))
        (test-assert-i64-eq (env-count empty-env) 0)
        (test-assert-i64-eq (env-count single-env) 1)
        (test-assert-true (string.eq (env-name-ref single-env 0) env-name))
        (test-assert-true (string.eq (env-value-ref single-env 0) env-first))
        (test-assert-i64-eq (args-count cmd-argv) 3)
        (test-assert-process-string-list3
          (process.command-argv owned)
          "first"
          "second"
          "third")
        (test-assert-i64-eq (env-count cmd-env) 2)
        (test-assert-process-env-list2
          (process.command-env owned)
          "TL_DUP"
          "first"
          "TL_DUP"
          "second")))))

;: Inline test body for borrowed process validation helpers.
(define (test-validation-check) : unit
  (let
    [exe : String "echo"]
    [empty : String ""]
    [bad-env-name : String "BAD=NAME"]
    [with-nul : String (test-string-with-nul)]
    [nul-valid-name : (& with-nul str) (string.substring-view (& with-nul) 0 1)]
    [empty-command : (ProcessBorrowedCommand empty empty empty empty empty)
      (command-empty (& empty))]
    [base : (ProcessBorrowedCommand exe exe exe exe exe)
      (command-empty (& exe))]
    [empty-cwd-command : (ProcessBorrowedCommand exe exe empty exe exe)
      (command-with-cwd base (& empty))]
    [empty-env-command : (ProcessBorrowedCommand exe exe exe empty exe)
      (command-with-env-list
        base
        (env-cons (& empty) (& empty) (env-empty-like (& empty))))]
    [bad-env-command : (ProcessBorrowedCommand exe exe exe bad-env-name exe)
      (command-with-env-list
        base
        (env-cons
          (& bad-env-name)
          (& bad-env-name)
          (env-empty-like (& bad-env-name))))]
    [nul-executable-command : (ProcessBorrowedCommand
      with-nul
      with-nul
      with-nul
      with-nul
      with-nul)
      (command-empty (& with-nul))]
    [nul-argument-command : (ProcessBorrowedCommand exe with-nul exe exe exe)
      (command-with-argv base (args-single (& with-nul)))]
    [nul-cwd-command : (ProcessBorrowedCommand exe exe with-nul exe exe)
      (command-with-cwd base (& with-nul))]
    [nul-env-name-command : (ProcessBorrowedCommand exe exe exe with-nul exe)
      (command-with-env-list
        base
        (env-cons (& with-nul) (& with-nul) (env-empty-like (& with-nul))))]
    [nul-env-value-command : (ProcessBorrowedCommand exe exe exe with-nul exe)
      (command-with-env-list
        base
        (env-cons nul-valid-name (& with-nul) (env-empty-like (& with-nul))))]
    [nul-stdin-command : (ProcessBorrowedCommand exe exe exe exe with-nul)
      (command-with-stdin base (& with-nul))]
    (begin
      (test-assert-invalid-output
        (output empty-command)
        "process: executable path is empty")
      (test-assert-invalid-child
        (start empty-command)
        "process: executable path is empty")
      (test-assert-invalid-output
        (output empty-cwd-command)
        "process: cwd path is empty")
      (test-assert-invalid-output
        (output empty-env-command)
        "process: environment variable name is empty")
      (test-assert-invalid-output
        (output bad-env-command)
        "process: environment variable name contains '='")
      (test-assert-invalid-output
        (output nul-executable-command)
        "process: executable path contains NUL")
      (test-assert-invalid-output
        (output nul-argument-command)
        "process: argument contains NUL")
      (test-assert-invalid-output
        (output nul-cwd-command)
        "process: cwd path contains NUL")
      (test-assert-invalid-output
        (output nul-env-name-command)
        "process: environment variable name contains NUL")
      (test-assert-invalid-output
        (output nul-env-value-command)
        "process: environment variable value contains NUL")
      (test-assert-true (command-valid? nul-stdin-command))
      (test-assert-false (command-valid? empty-command)))))

(test
  process-borrowed-api
  (begin
    (test-api-check)
    (process-borrowed-test-ordered-builders-check)
    (test-validation-check)))
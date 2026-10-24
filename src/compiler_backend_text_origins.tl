;; Operand identity transport for the stack census. Tokens are issued by typed
;; emitting authorities; byte equality never issues or recovers an identity.
(import compiler_ir_types as ir)
(import compiler_stack_traffic as stack_traffic)
(import stdlib.dense_list as dense_list)
(import stdlib.arena)
(import stdlib.string)
(import stdlib.iterator)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as origin_index)
(import stdlib.vector)
(import (vector.vector CompilerBackendTextOriginEntry core) as origin_entries)
(import compiler_owned_view as owned_view)
(import compiler_str_cat as str_cat)
(import stdlib.comptime)

;; The inactive route is the existing compiler concatenator: no parts array or
;; metadata allocation is introduced into ordinary emission. Each argument is
;; evaluated once in the selected route, in its original order.
(defmacro (compiler-backend-text-origins-cat
  [capture : comptime.Expr]
  [args : comptime.Expr ...]) : String
  (let
    [parts : comptime.ExprList (comptime.expr-list-empty)]
    [count : i64 (comptime.expr-list-length args)]
    [index : i64 count]
    (while (> index 0)
      (set! index (- index 1))
      (let
        [arg : comptime.Expr (comptime.expr-list-nth args index)]
        (set!
          parts
          (comptime.expr-list-cons
            (match arg
              [(comptime.Expr.Var _) `(compiler_str_cat.str-cat-name ,arg)]
              [_ arg])
            parts))))
    (let
      [active : comptime.Expr
        (if (< count 2)
          `(compiler_str_cat.str-cat ,@args)
          `(let
            [__tl_origin_parts (array ,@parts)]
            (compiler_backend_text_origins.compiler-backend-text-origins-concat
              __tl_origin_capture
              (& __tl_origin_parts))))]
      `(let
        [__tl_origin_capture ,capture]
        (if (= __tl_origin_capture.storage 0)
          (compiler_str_cat.str-cat ,@args)
          ,active)))))

;; These are emitting authorities, not final CFG block IDs. Function entry
;; and exit traffic cannot inherit whichever IR block was emitted last.
(defenum CompilerBackendStackAccessAnchor
  (SourceBlock i64)
  (AdapterBody)
  (FunctionParameters)
  (FunctionEntry)
  (FunctionExit))

;; Emitter-issued identity, before rendering or slot coloring can conflate
;; distinct values. Operation ordinals belong to the final stream consumer.
(defstruct CompilerBackendStackAccessOrigin
  (function ir.CompilerIrSymbolId)
  (anchor CompilerBackendStackAccessAnchor)
  (home i64)
  (home-bytes i64)
  (owner stack_traffic.CompilerStackTrafficOwner)
  (bank stack_traffic.CompilerStackTrafficBank)
  (access-bytes i64)
  (access stack_traffic.CompilerStackTrafficAccess))

(defstruct CompilerBackendStackAccessOriginList
  (slots (__tl_dyn-array CompilerBackendStackAccessOrigin))
  (len i64))

(dense_list.compiler-dense-list-operations
  CompilerBackendStackAccessOrigin
  CompilerBackendStackAccessOriginList
  compiler-backend-stack-access-origin-list
  caller-provided-fallback
  zero-capacity
  compiler-dense-list-unused-shared-zero-storage
  append-from)

(defenum CompilerBackendDataLocation
  (InlineData)
  (OtherSection))

(defenum CompilerBackendTextOriginKind
  (Access)
  (DataLine CompilerBackendDataLocation)
  (TailExit CompilerBackendStackAccessAnchor)
  (FunctionStart)
  (FunctionEnd))

(defstruct CompilerBackendTextOrigin
  (start i64)
  (end i64)
  (token i64)
  (kind CompilerBackendTextOriginKind)
  (expected String))

(define (compiler-backend-text-origin-shift
  [origin : (& origin CompilerBackendTextOrigin)]
  [offset : i64]) : CompilerBackendTextOrigin
  (CompilerBackendTextOrigin
    (+ origin.start offset)
    (+ origin.end offset)
    origin.token
    (clone origin.kind)
    (owned_view.compiler-owned-string-place-shared-view origin.expected)))

(defstruct CompilerBackendTextOriginList
  (slots (__tl_dyn-array CompilerBackendTextOrigin))
  (len i64))

(dense_list.compiler-dense-list-operations
  CompilerBackendTextOrigin
  CompilerBackendTextOriginList
  compiler-backend-text-origin-list
  caller-provided-fallback
  zero-capacity
  compiler-dense-list-unused-shared-zero-storage
  append-from)

(defstruct CompilerBackendTextOriginEntry
  (text String)
  (origins (__tl_dyn-array CompilerBackendTextOrigin)))

(defstruct CompilerBackendFunctionOriginList
  (slots (__tl_dyn-array i64))
  (len i64))

(dense_list.compiler-dense-list-operations
  i64
  CompilerBackendFunctionOriginList
  compiler-backend-function-origin-list
  caller-provided-fallback
  zero-capacity
  compiler-dense-list-unused-shared-zero-storage
  append-from)

(defstruct CompilerBackendTextOriginData
  (index origin_index.Map)
  (entries origin_entries.Vec)
  (accesses CompilerBackendStackAccessOriginList)
  (functions CompilerBackendFunctionOriginList))

;; The owner retains EVERY indexed allocation, including intermediate text,
;; until consumption ends. A rewound emitter scratch arena therefore cannot
;; reuse an indexed address and accidentally inherit another operand's token.
(defstruct CompilerBackendTextOrigins
  (storage u64)
  (owner i64))

(defstruct CompilerBackendTextOriginBufferData
  (capture CompilerBackendTextOrigins)
  (origins CompilerBackendTextOriginList)
  (len i64)
  (finished bool))

(defstruct CompilerBackendTextOriginBuffer
  (storage u64))

(defenum CompilerBackendOriginCheck
  (Ok)
  (Err String))

(defenum CompilerBackendOriginTextResult
  (Ok String)
  (Err String))

;; A live-owner reference to one immutable text entry. This POD carrier may
;; cross a function-scratch clone; it cannot outlive the capture itself.
(defenum CompilerBackendTextOriginSnapshot
  (None)
  (Saved u64 i64 i64))

(defstruct CompilerBackendOriginCopy
  (text String)
  (snapshot CompilerBackendTextOriginSnapshot))

(define (compiler-backend-text-origins-disabled) : CompilerBackendTextOrigins
  (CompilerBackendTextOrigins 0 0))

(define (compiler-backend-text-origins-accesses
  [capture : CompilerBackendTextOrigins]) : CompilerBackendStackAccessOriginList
  (if (= capture.storage 0)
    (compiler-backend-stack-access-origin-list-new)
    (unsafe
      (let
        [data : CompilerBackendTextOriginData
          (ptr-read
            (int->ptr capture.storage : (Ptr CompilerBackendTextOriginData)))]
        data.accesses))))

;; Shared validation for issuance and final-stream reconciliation. Final users
;; recheck the retained fact instead of trusting a mutable array descriptor.
(define (compiler-backend-stack-access-origin-check
  [access : (& access CompilerBackendStackAccessOrigin)]) : CompilerBackendOriginCheck
  (when
    (or
      (< access.function.value 0)
      (not
        (match (& access.anchor)
          [(SourceBlock block) (>= block 0)]
          [(AdapterBody) true]
          [(FunctionParameters)
            (and
              (match (& access.owner)
                [(CallAbi) true]
                [_ false])
              (match (& access.access)
                [(Read) true]
                [_ false]))]
          [(FunctionEntry)
            (and
              (match (& access.owner)
                [(CallAbi) true]
                [_ false])
              (match (& access.access)
                [(Write) true]
                [_ false]))]
          [(FunctionExit)
            (and
              (match (& access.owner)
                [(CallAbi) true]
                [_ false])
              (match (& access.access)
                [(Read) true]
                [_ false]))]))
      (< access.home 0)
      (<= access.home-bytes 0)
      (> access.access-bytes access.home-bytes)
      (<= access.access-bytes 0))
    (return (Err "stack traffic: invalid emitter access origin")))
  (Ok))

;; Publish the typed snapshot and its protected text as one synchronous step.
;; A failed mark cannot leave an orphan access in the job's token inventory.
(define (compiler-backend-text-origins-record
  [capture : CompilerBackendTextOrigins]
  [access : CompilerBackendStackAccessOrigin]
  [operand : String]) : CompilerBackendOriginTextResult
  (match (compiler-backend-stack-access-origin-check (& access))
    [(Ok) unit]
    [(Err message) (return (Err message))])
  (when (= capture.storage 0) (return (Ok operand)))
  (let
    [token : i64 (compiler-backend-text-origins-accesses capture).len]
    (match (compiler-backend-text-origins-mark capture operand token)
      [(Err message) (Err message)]
      [(Ok text)
        (in-arena
          (arena.Arena capture.owner)
          (unsafe
            (let
              [destination : (MutPtr CompilerBackendTextOriginData)
                (int->ptr
                  capture.storage
                  : (MutPtr CompilerBackendTextOriginData))]
              ;; Mark updated the text index: read the current descriptor now.
              [data : CompilerBackendTextOriginData (ptr-read destination)]
              (compiler-backend-stack-access-origin-list-push
                (&mut data.accesses)
                access)
              (ptr-write! destination data))))
        (Ok text)])))

(define (compiler-backend-text-origins-new) : CompilerBackendTextOrigins
  (let
    [owner : i64 (arena.tl_arena_make_small)]
    (in-arena
      (arena.Arena owner)
      (let
        [cell : (__tl_dyn-array CompilerBackendTextOriginData)
          (__tl_make-array CompilerBackendTextOriginData 1)]
        (set!
          (array-ref cell 0)
          (CompilerBackendTextOriginData
            (origin_index.with-capacity 16)
            (origin_entries.with-capacity 16)
            (compiler-backend-stack-access-origin-list-new)
            (compiler-backend-function-origin-list-new)))
        (CompilerBackendTextOrigins
          (unsafe
            (ptr->int (__tl_array-data cell)))
          owner)))))

(define (compiler-backend-text-origins-release!
  [capture : (&mut capture CompilerBackendTextOrigins)]) : unit
  (let
    [owner : i64 capture.owner]
    (set! capture.storage 0)
    (set! capture.owner 0)
    ;; All indexed String users and borrowed origin arrays must have finished.
    (when
      (> owner 0)
      (unsafe
        (arena.tl_arena_destroy owner)))))

(define (compiler-backend-text-origin-key [text : (& str)]) : i64
  (unsafe
    (cast (ptr->int (string-data text)) : i64)))

(define (compiler-backend-text-origins-entry-index
  [capture : CompilerBackendTextOrigins]
  [text : (& text str)]) : i64
  (when
    (!= capture.storage 0)
    (unsafe
      (let
        [data : CompilerBackendTextOriginData
          (ptr-read
            (int->ptr capture.storage : (Ptr CompilerBackendTextOriginData)))]
        (match (origin_index.get-borrowed
          (& data.index)
          (compiler-backend-text-origin-key text))
          [(LookupMissing) unit]
          [(LookupFound index)
            (let
              [entries : (& data (Slice CompilerBackendTextOriginEntry))
                (origin_entries.view (& data.entries))]
              (when
                (=
                  (string.string-length text)
                  (string.string-length (& (array-ref entries index).text)))
                (return index)))]))))
  -1)

(define (compiler-backend-text-origins-find
  [capture : CompilerBackendTextOrigins]
  [text : (& text str)]) : (__tl_dyn-array CompilerBackendTextOrigin)
  (let
    [index : i64 (compiler-backend-text-origins-entry-index capture text)]
    (if (< index 0)
      (__tl_make-array CompilerBackendTextOrigin 0)
      (unsafe
        (let
          [data : CompilerBackendTextOriginData
            (ptr-read
              (int->ptr capture.storage : (Ptr CompilerBackendTextOriginData)))]
          [entries : (& data (Slice CompilerBackendTextOriginEntry))
            (origin_entries.view (& data.entries))]
          (owned_view.compiler-owned-reference-shared-view
            (& (array-ref entries index).origins)))))))

(define (compiler-backend-text-origins-snapshot
  [capture : CompilerBackendTextOrigins]
  [text : (& text str)]) : CompilerBackendTextOriginSnapshot
  (let
    [index : i64 (compiler-backend-text-origins-entry-index capture text)]
    (if (< index 0)
      (None)
      (Saved capture.storage capture.owner index))))

;; An explicit copy supplies its pre-copy identity. Equality validates the
;; copy; it never recovers an origin from unrelated equal-looking text.
(define (compiler-backend-text-origins-restore-copy
  [capture : CompilerBackendTextOrigins]
  [snapshot : CompilerBackendTextOriginSnapshot]
  [text : String]) : CompilerBackendOriginTextResult
  (match snapshot
    [(None) (Ok text)]
    [(Saved storage owner index)
      (unless
        (and (!= storage 0) (= storage capture.storage) (= owner capture.owner))
        (return (Err "stack traffic: copy snapshot belongs to another capture")))
      (unsafe
        (let
          [data : CompilerBackendTextOriginData
            (ptr-read
              (int->ptr capture.storage : (Ptr CompilerBackendTextOriginData)))]
          [entries : (& data (Slice CompilerBackendTextOriginEntry))
            (origin_entries.view (& data.entries))]
          (when
            (or (< index 0) (>= index (array-length entries)))
            (return (Err "stack traffic: invalid copy snapshot")))
          (unless
            (string.eq (& text) (& (array-ref entries index).text))
            (return
              (Err "stack traffic: copied text differs from its snapshot")))
          (in-arena
            (arena.Arena capture.owner)
            (Ok
              (compiler-backend-text-origins-publish
                capture
                (string.copy (& text))
                (owned_view.compiler-owned-reference-shared-view
                  (& (array-ref entries index).origins)))))))]))

;; Internal: text and origins were allocated in capture.owner and are immutable
;; from here onward. Only that owner can publish an indexed allocation.
(define (compiler-backend-text-origins-publish
  [capture : CompilerBackendTextOrigins]
  [text : String]
  [origins : (__tl_dyn-array CompilerBackendTextOrigin)]) : String
  (unsafe
    (let
      [destination : (MutPtr CompilerBackendTextOriginData)
        (int->ptr capture.storage : (MutPtr CompilerBackendTextOriginData))]
      [data : CompilerBackendTextOriginData (ptr-read destination)]
      [index : i64 (origin_entries.len (& data.entries))]
      [_inserted : bool
        (origin_index.insert-if-absent-ref!
          (&mut data.index)
          (compiler-backend-text-origin-key (& text))
          index)]
      (origin_entries.push-ref!
        (&mut data.entries)
        (CompilerBackendTextOriginEntry
          (owned_view.compiler-owned-shared-view text)
          origins))
      (ptr-write! destination data)
      text)))

(define (compiler-backend-text-origins-mark
  [capture : CompilerBackendTextOrigins]
  [text : String]
  [token : i64]) : CompilerBackendOriginTextResult
  (when
    (or (< token 0) (= (string.string-length (& text)) 0))
    (return (Err "stack traffic: invalid operand origin")))
  (when (= capture.storage 0) (return (Ok text)))
  (when
    (> (array-length (compiler-backend-text-origins-find capture (& text))) 0)
    (return (Err "stack traffic: operand origin is already assigned")))
  (in-arena
    (arena.Arena capture.owner)
    (let
      [copy : String (string.copy (& text))]
      [origins : (__tl_dyn-array CompilerBackendTextOrigin)
        (__tl_make-array CompilerBackendTextOrigin 1)]
      (set!
        (array-ref origins 0)
        (CompilerBackendTextOrigin
          0
          (string.string-length (& copy))
          token
          (Access)
          (owned_view.compiler-owned-shared-view copy)))
      (Ok (compiler-backend-text-origins-publish capture copy origins)))))

(define (compiler-backend-text-origins-concat
  [capture : CompilerBackendTextOrigins]
  [parts : (& parts (Slice String))]) : String
  (let
    [count : i64 0]
    (for [part (iterator.range 0 (array-length parts))]
      (+=
        count
        (array-length
          (compiler-backend-text-origins-find
            capture
            (& (array-ref parts part))))))
    (when (= count 0) (return (string.concat-all parts)))
    (in-arena
      (arena.Arena capture.owner)
      (let
        [text : String (string.concat-all parts)]
        [origins : (__tl_dyn-array CompilerBackendTextOrigin)
          (__tl_make-array CompilerBackendTextOrigin count)]
        [offset : i64 0]
        [next : i64 0]
        (for [part (iterator.range 0 (array-length parts))]
          (let
            [source : (__tl_dyn-array CompilerBackendTextOrigin)
              (compiler-backend-text-origins-find
                capture
                (& (array-ref parts part)))]
            (for [index (iterator.range 0 (array-length source))]
              (let
                [origin : (& source CompilerBackendTextOrigin)
                  (& (array-ref source index))]
                (set!
                  (array-ref origins next)
                  (compiler-backend-text-origin-shift origin offset))
                (+= next 1))))
          (+= offset (string.string-length (& (array-ref parts part)))))
        (compiler-backend-text-origins-publish capture text origins)))))

(define (compiler-backend-text-origins-slice
  [capture : CompilerBackendTextOrigins]
  [text : (& text str)]
  [start : i64]
  [len : i64]) : CompilerBackendOriginTextResult
  (let
    [length : i64 (string.string-length text)]
    [source : (__tl_dyn-array CompilerBackendTextOrigin)
      (compiler-backend-text-origins-find capture text)]
    [count : i64 0]
    (when
      (or (< start 0) (< len 0) (> start length) (> len (- length start)))
      (return (Err "stack traffic: invalid text slice")))
    (when (= len 0) (return (Ok "")))
    (for [index (iterator.range 0 (array-length source))]
      (let
        [origin : (& source CompilerBackendTextOrigin)
          (& (array-ref source index))]
        (when
          (and (< origin.start (+ start len)) (> origin.end start))
          (unless
            (and (>= origin.start start) (<= origin.end (+ start len)))
            (return (Err "stack traffic: rewrite cuts an operand origin")))
          (+= count 1))))
    (when (= count 0) (return (Ok (string.substring text start len))))
    (in-arena
      (arena.Arena capture.owner)
      (let
        [copy : String (string.substring text start len)]
        [origins : (__tl_dyn-array CompilerBackendTextOrigin)
          (__tl_make-array CompilerBackendTextOrigin count)]
        [next : i64 0]
        (for [index (iterator.range 0 (array-length source))]
          (let
            [origin : (& source CompilerBackendTextOrigin)
              (& (array-ref source index))]
            (when
              (and (>= origin.start start) (<= origin.end (+ start len)))
              (set!
                (array-ref origins next)
                (compiler-backend-text-origin-shift origin (- 0 start)))
              (+= next 1))))
        (Ok (compiler-backend-text-origins-publish capture copy origins))))))

;; An address rewrite names the exact old operand and explicitly transfers its
;; token to the replacement. Erasing or partly matching an access is refused.
(define (compiler-backend-text-origins-retarget
  [capture : CompilerBackendTextOrigins]
  [operand : String]
  [replacement : String]) : CompilerBackendOriginTextResult
  (let
    [source : (__tl_dyn-array CompilerBackendTextOrigin)
      (compiler-backend-text-origins-find capture (& operand))]
    (unless
      (= (array-length source) 1)
      (return (Err "stack traffic: address rewrite needs one exact origin")))
    (let
      [origin : (& source CompilerBackendTextOrigin) (& (array-ref source 0))]
      (unless
        (and
          (match (& origin.kind)
            [(Access) true]
            [_ false])
          (= origin.start 0)
          (= origin.end (string.string-length (& operand))))
        (return (Err "stack traffic: address rewrite needs one exact origin")))
      (compiler-backend-text-origins-mark capture replacement origin.token))))

;; A folded memory operand performs the retained read and then the retained
;; write, even when coloring gave different logical homes identical addresses.
;; Overlapping byte spans here are deliberate; tokens remain distinct facts.
(define (compiler-backend-text-origins-merge-accesses
  [capture : CompilerBackendTextOrigins]
  [read : String]
  [write : String]
  [replacement : String]) : CompilerBackendOriginTextResult
  (when (= capture.storage 0) (return (Ok replacement)))
  (when
    (and
      (= (array-length (compiler-backend-text-origins-find capture (& read))) 0)
      (=
        (array-length (compiler-backend-text-origins-find capture (& write)))
        0))
    (return (Ok replacement)))
  (let
    [left : String
      (try
        (compiler-backend-text-origins-retarget
          capture
          read
          (string.copy (& replacement))))]
    [right : String
      (try
        (compiler-backend-text-origins-retarget
          capture
          write
          (string.copy (& replacement))))]
    [reads : (__tl_dyn-array CompilerBackendTextOrigin)
      (compiler-backend-text-origins-find capture (& left))]
    [writes : (__tl_dyn-array CompilerBackendTextOrigin)
      (compiler-backend-text-origins-find capture (& right))]
    (when
      (= (array-ref reads 0).token (array-ref writes 0).token)
      (return
        (Err "stack traffic: folded accesses need distinct source tokens")))
    (let
      [read-token : i64 (array-ref reads 0).token]
      [write-token : i64 (array-ref writes 0).token]
      [accesses : CompilerBackendStackAccessOriginList
        (compiler-backend-text-origins-accesses capture)]
      (when
        (or
          (< read-token 0)
          (>= read-token accesses.len)
          (< write-token 0)
          (>= write-token accesses.len))
        (return (Err "stack traffic: folded token has no typed access")))
      (let
        [left : (& accesses CompilerBackendStackAccessOrigin)
          (& (array-ref accesses.slots read-token))]
        [right : (& accesses CompilerBackendStackAccessOrigin)
          (& (array-ref accesses.slots write-token))]
        (unless
          (and
            (match (& left.access)
              [(Read) true]
              [_ false])
            (match (& right.access)
              [(Write) true]
              [_ false])
            (= left.function.value right.function.value)
            (= left.access-bytes right.access-bytes))
          (return (Err "stack traffic: incompatible folded read/write access")))))
    (in-arena
      (arena.Arena capture.owner)
      (let
        [origins : (__tl_dyn-array CompilerBackendTextOrigin)
          (__tl_make-array CompilerBackendTextOrigin 2)]
        (set!
          (array-ref origins 0)
          (compiler-backend-text-origin-shift (& (array-ref reads 0)) 0))
        (set!
          (array-ref origins 1)
          (compiler-backend-text-origin-shift (& (array-ref writes 0)) 0))
        (Ok
          (compiler-backend-text-origins-publish
            capture
            (string.copy (& replacement))
            origins))))))

;; A synthesized readback reads the STORE's logical home. Reusing the old
;; load's token would silently change that identity across a colored overlap.
(define (compiler-backend-text-origins-readback
  [capture : CompilerBackendTextOrigins]
  [written : (& written str)]
  [replacement : String]) : CompilerBackendOriginTextResult
  (when (= capture.storage 0) (return (Ok replacement)))
  (let
    [spans : (__tl_dyn-array CompilerBackendTextOrigin)
      (compiler-backend-text-origins-find capture written)]
    (when (= (array-length spans) 0) (return (Ok replacement)))
    (unless
      (and
        (= (array-length spans) 1)
        (match (& (array-ref spans 0).kind)
          [(Access) true]
          [_ false])
        (= (array-ref spans 0).start 0)
        (= (array-ref spans 0).end (string.string-length written)))
      (return (Err "stack traffic: readback needs one exact stored operand")))
    (let
      [token : i64 (array-ref spans 0).token]
      [accesses : CompilerBackendStackAccessOriginList
        (compiler-backend-text-origins-accesses capture)]
      (when
        (or (< token 0) (>= token accesses.len))
        (return (Err "stack traffic: readback token has no typed access")))
      (let
        [origin : (& accesses CompilerBackendStackAccessOrigin)
          (& (array-ref accesses.slots token))]
        (unless
          (match (& origin.access)
            [(Write) true]
            [(ReadWrite) true]
            [_ false])
          (return
            (Err "stack traffic: readback source does not write its home")))
        (compiler-backend-text-origins-record
          capture
          (CompilerBackendStackAccessOrigin
            (clone origin.function)
            (clone origin.anchor)
            origin.home
            origin.home-bytes
            (clone origin.owner)
            (clone origin.bank)
            origin.access-bytes
            (Read))
          replacement)))))

;; Match stdlib.string.replace's FIRST-occurrence semantics. Whole removed
;; annotations disappear; newly inserted text supplies its own identities.
;; A partial operand match cannot silently inherit the old annotation.
(define (compiler-backend-text-origins-replace
  [capture : CompilerBackendTextOrigins]
  [text : String]
  [pattern : String]
  [replacement : String]) : CompilerBackendOriginTextResult
  (when
    (= capture.storage 0)
    (return (Ok (string.replace text pattern replacement))))
  (let
    [length : i64 (string.string-length (& text))]
    [size : i64 (string.string-length (& pattern))]
    [position : i64 0]
    (while (and
      (<= position (- length size))
      (not (string.is-string-prefix-at (& text) (& pattern) position)))
      (+= position 1))
    (when (> position (- length size)) (return (Ok text)))
    (match (compiler-backend-text-origins-slice capture (& text) 0 position)
      [(Err message) (Err message)]
      [(Ok before)
        (match (compiler-backend-text-origins-slice
          capture
          (& text)
          (+ position size)
          (- length (+ position size)))
          [(Err message) (Err message)]
          [(Ok after)
            (let
              [parts : (Array String 3) (array before replacement after)]
              (Ok (compiler-backend-text-origins-concat capture (& parts))))])])))

(define (compiler-backend-text-origin-buffer-new
  [capture : CompilerBackendTextOrigins]) : CompilerBackendTextOriginBuffer
  (when (= capture.storage 0) (return (CompilerBackendTextOriginBuffer 0)))
  (in-arena
    (arena.Arena capture.owner)
    (let
      [cell : (__tl_dyn-array CompilerBackendTextOriginBufferData)
        (__tl_make-array CompilerBackendTextOriginBufferData 1)]
      (set!
        (array-ref cell 0)
        (CompilerBackendTextOriginBufferData
          capture
          (compiler-backend-text-origin-list-new)
          0
          false))
      (CompilerBackendTextOriginBuffer
        (unsafe
          (ptr->int (__tl_array-data cell)))))))

;; A producer may append captured operands only to a live buffer belonging
;; to that same capture. Byte equality cannot recover a missing association.
(define (compiler-backend-text-origin-buffer-capture-matches?
  [buffer : CompilerBackendTextOriginBuffer]
  [capture : CompilerBackendTextOrigins]) : bool
  (when (= capture.storage 0) (return (= buffer.storage 0)))
  (when (= buffer.storage 0) (return false))
  (unsafe
    (let
      [data : CompilerBackendTextOriginBufferData
        (ptr-read
          (int->ptr buffer.storage : (Ptr CompilerBackendTextOriginBufferData)))]
      (and
        (not data.finished)
        (= data.capture.storage capture.storage)
        (= data.capture.owner capture.owner)))))

;; Every append accounts for its bytes, including unannotated text. This makes
;; a missed buffer write detectable at finalization rather than shifting facts.
(define (compiler-backend-text-origin-buffer-note!
  [buffer : CompilerBackendTextOriginBuffer]
  [text : (& text str)]
  [offset : i64]) : CompilerBackendOriginCheck
  (when (= buffer.storage 0) (return (Ok)))
  (unsafe
    (let
      [destination : (MutPtr CompilerBackendTextOriginBufferData)
        (int->ptr buffer.storage : (MutPtr CompilerBackendTextOriginBufferData))]
      [data : CompilerBackendTextOriginBufferData (ptr-read destination)]
      [n : i64 (string.string-length text)]
      [source : (__tl_dyn-array CompilerBackendTextOrigin)
        (compiler-backend-text-origins-find data.capture text)]
      (when
        (or
          data.finished
          (!= data.len offset)
          (> n (- 9223372036854775807 data.len)))
        (return (Err "stack traffic: noncontiguous or finished text buffer")))
      (in-arena
        (arena.Arena data.capture.owner)
        (for [index (iterator.range 0 (array-length source))]
          (let
            [origin : (& source CompilerBackendTextOrigin)
              (& (array-ref source index))]
            (compiler-backend-text-origin-list-push
              (&mut data.origins)
              (compiler-backend-text-origin-shift origin offset)))))
      (set! data.len (+ data.len n))
      (ptr-write! destination data)
      (Ok))))

(define (compiler-backend-text-origin-buffer-append!
  [buffer : CompilerBackendTextOriginBuffer]
  [text : (& text str)]) : CompilerBackendOriginCheck
  (when (= buffer.storage 0) (return (Ok)))
  (unsafe
    (let
      [data : CompilerBackendTextOriginBufferData
        (ptr-read
          (int->ptr buffer.storage : (Ptr CompilerBackendTextOriginBufferData)))]
      (compiler-backend-text-origin-buffer-note! buffer text data.len))))

;; The caller names an exact source range, including any retained newline.
;; Slicing validates whole-operand boundaries before metadata is appended.
(define (compiler-backend-text-origin-buffer-append-range!
  [buffer : CompilerBackendTextOriginBuffer]
  [text : (& text str)]
  [start : i64]
  [len : i64]) : CompilerBackendOriginCheck
  (when (= buffer.storage 0) (return (Ok)))
  (unsafe
    (let
      [data : CompilerBackendTextOriginBufferData
        (ptr-read
          (int->ptr buffer.storage : (Ptr CompilerBackendTextOriginBufferData)))]
      (match (compiler-backend-text-origins-slice data.capture text start len)
        [(Err message) (Err message)]
        [(Ok slice)
          (compiler-backend-text-origin-buffer-note! buffer (& slice) data.len)]))))

;; A cold save can be issued after its body but inserted before it. Merge by
;; final byte position; token creation order cannot establish execution order.
(define (compiler-backend-text-origin-buffer-insert!
  [buffer : CompilerBackendTextOriginBuffer]
  [text : (& text str)]
  [at : i64]) : CompilerBackendOriginCheck
  (when (= buffer.storage 0) (return (Ok)))
  (unsafe
    (let
      [destination : (MutPtr CompilerBackendTextOriginBufferData)
        (int->ptr buffer.storage : (MutPtr CompilerBackendTextOriginBufferData))]
      [data : CompilerBackendTextOriginBufferData (ptr-read destination)]
      [n : i64 (string.string-length text)]
      [source : (__tl_dyn-array CompilerBackendTextOrigin)
        (compiler-backend-text-origins-find data.capture text)]
      (when
        (or
          data.finished
          (< at 0)
          (> at data.len)
          (> n (- 9223372036854775807 data.len)))
        (return (Err "stack traffic: invalid text insertion")))
      (when (= n 0) (return (Ok)))
      (for [index (iterator.range 0 data.origins.len)]
        (let
          [origin : (& data CompilerBackendTextOrigin)
            (& (array-ref data.origins.slots index))]
          (when
            (and (< origin.start at) (> origin.end at))
            (return (Err "stack traffic: insertion cuts an operand origin")))))
      (in-arena
        (arena.Arena data.capture.owner)
        (let
          [merged : CompilerBackendTextOriginList
            (compiler-backend-text-origin-list-with-capacity
              (+ data.origins.len (array-length source)))]
          [inserted : bool false]
          (for [index (iterator.range 0 (+ data.origins.len 1))]
            (when
              (and
                (not inserted)
                (or
                  (= index data.origins.len)
                  (>= (array-ref data.origins.slots index).start at)))
              (for [next (iterator.range 0 (array-length source))]
                (let
                  [origin : (& source CompilerBackendTextOrigin)
                    (& (array-ref source next))]
                  (compiler-backend-text-origin-list-push
                    (&mut merged)
                    (compiler-backend-text-origin-shift origin at))))
              (set! inserted true))
            (when
              (< index data.origins.len)
              (let
                [origin : (& data CompilerBackendTextOrigin)
                  (& (array-ref data.origins.slots index))]
                [shift : i64
                  (if (>= origin.start at)
                    n
                    0)]
                (compiler-backend-text-origin-list-push
                  (&mut merged)
                  (compiler-backend-text-origin-shift origin shift)))))
          (set! data.origins merged)))
      (set! data.len (+ data.len n))
      (ptr-write! destination data)
      (Ok))))

(define (compiler-backend-text-origin-buffer-finish
  [buffer : CompilerBackendTextOriginBuffer]
  [text : String]) : CompilerBackendOriginTextResult
  (when (= buffer.storage 0) (return (Ok text)))
  (unsafe
    (let
      [destination : (MutPtr CompilerBackendTextOriginBufferData)
        (int->ptr buffer.storage : (MutPtr CompilerBackendTextOriginBufferData))]
      [data : CompilerBackendTextOriginBufferData (ptr-read destination)]
      (when
        (or data.finished (!= data.len (string.string-length (& text))))
        (return (Err "stack traffic: final text buffer extent mismatch")))
      (for [index (iterator.range 0 data.origins.len)]
        (let
          [origin : (& data CompilerBackendTextOrigin)
            (& (array-ref data.origins.slots index))]
          (unless
            (string.eq
              (string.substring-view
                (& text)
                origin.start
                (- origin.end origin.start))
              (& origin.expected))
            (return
              (Err "stack traffic: buffer changed an operand without transfer")))))
      (set! data.finished true)
      (ptr-write! destination (owned_view.compiler-owned-shared-view data))
      (when (= data.origins.len 0) (return (Ok text)))
      (in-arena
        (arena.Arena data.capture.owner)
        (let
          [copy : String (string.copy (& text))]
          [spans : (__tl_dyn-array CompilerBackendTextOrigin)
            (__tl_make-array CompilerBackendTextOrigin data.origins.len)]
          (for [index (iterator.range 0 data.origins.len)]
            (set!
              (array-ref spans index)
              (compiler-backend-text-origin-shift
                (& (array-ref data.origins.slots index))
                0)))
          (Ok (compiler-backend-text-origins-publish data.capture copy spans)))))))

;; The final machine parser supplies instruction extents and CFG blocks after
;; every rewrite. Byte ranges establish containment only, never an owner or a
;; source region. Directives, labels and deleted instructions have no entry.
(defstruct CompilerBackendFinalOperation
  (start i64)
  (end i64)
  (block i64))

(defstruct CompilerBackendFinalAccess
  (operation i64)
  (access-index i64)
  (block i64)
  (origin CompilerBackendStackAccessOrigin))

(defenum CompilerBackendFinalAccessResult
  (Ok (__tl_dyn-array CompilerBackendFinalAccess))
  (Err String))

;; Repeated tokens at different final positions are real clones. Within one
;; operation reads precede memory writes; an RMW fact contains its own ordered
;; read/write. Equal-range RMW operands retain their typed read and write homes.
;; This reconciles retained facts only: missing-access decoding and source/CFG
;; region qualification remain the final machine producer's responsibility.
(define (compiler-backend-text-origins-final-accesses
  [capture : CompilerBackendTextOrigins]
  [text : (& text str)]
  [function : ir.CompilerIrSymbolId]
  [blocks : i64]
  [operations : (& operations (Slice CompilerBackendFinalOperation))]) : CompilerBackendFinalAccessResult
  (when
    (or (= capture.storage 0) (< function.value 0) (< blocks 0))
    (return
      (Err "stack traffic: final stream needs an active function capture")))
  (let
    [length : i64 (string.string-length text)]
    [spans : (__tl_dyn-array CompilerBackendTextOrigin)
      (compiler-backend-text-origins-access-spans capture text)]
    [accesses : CompilerBackendStackAccessOriginList
      (compiler-backend-text-origins-accesses capture)]
    [result : (__tl_dyn-array CompilerBackendFinalAccess)
      (__tl_make-array CompilerBackendFinalAccess (array-length spans))]
    [previous : i64 0]
    [cursor : i64 0]
    [written : i64 0]
    (for [i (iterator.range 0 (array-length operations))]
      (let
        [op : (& operations CompilerBackendFinalOperation)
          (& (array-ref operations i))]
        (unless
          (and
            (>= op.start previous)
            (> op.end op.start)
            (<= op.end length)
            (>= op.block 0)
            (< op.block blocks))
          (return (Err "stack traffic: invalid final operation partition")))
        (set! previous op.end)))
    (for [i (iterator.range 0 (array-length spans))]
      (let
        [span : (& spans CompilerBackendTextOrigin) (& (array-ref spans i))]
        (unless
          (and
            (>= span.start 0)
            (> span.end span.start)
            (<= span.end length)
            (>= span.token 0)
            (< span.token accesses.len)
            (string.eq
              (& span.expected)
              (string.substring-view text span.start (- span.end span.start))))
          (return
            (Err "stack traffic: final operand has no exact typed witness")))
        (when
          (> i 0)
          (let
            [prior : (& spans CompilerBackendTextOrigin)
              (& (array-ref spans (- i 1)))]
            (unless
              (or
                (>= span.start prior.end)
                (and (= span.start prior.start) (= span.end prior.end)))
              (return
                (Err "stack traffic: final operand ranges overlap ambiguously")))))
        (let
          [origin : (& accesses CompilerBackendStackAccessOrigin)
            (& (array-ref accesses.slots span.token))]
          (match (compiler-backend-stack-access-origin-check origin)
            [(Ok) unit]
            [(Err message) (return (Err message))])
          (unless
            (= origin.function.value function.value)
            (return
              (Err "stack traffic: final operand belongs to another function"))))))
    (for [operation (iterator.range 0 (array-length operations))]
      (let
        [op : (& operations CompilerBackendFinalOperation)
          (& (array-ref operations operation))]
        [begin : i64 cursor]
        [index : i64 0]
        (while (and
          (< cursor (array-length spans))
          (< (array-ref spans cursor).start op.end))
          (let
            [span : (& spans CompilerBackendTextOrigin)
              (& (array-ref spans cursor))]
            (unless
              (and (>= span.start op.start) (<= span.end op.end))
              (return
                (Err
                  "stack traffic: operand crosses or misses a final instruction"))))
          (+= cursor 1))
        (for [phase (iterator.range 0 2)]
          (for [at (iterator.range begin cursor)]
            (let
              [origin : (& accesses CompilerBackendStackAccessOrigin)
                (& (array-ref accesses.slots (array-ref spans at).token))]
              (when
                (=
                  phase
                  (if (stack_traffic.compiler-stack-traffic-read?
                    (& origin.access))
                    0
                    1))
                (set!
                  (array-ref result written)
                  (CompilerBackendFinalAccess
                    operation
                    index
                    op.block
                    (clone
                      (array-ref accesses.slots (array-ref spans at).token))))
                (+= written 1)
                (+= index 1)))))))
    (unless
      (and (= cursor (array-length spans)) (= written (array-length spans)))
      (return (Err "stack traffic: operand has no final instruction")))
    (Ok result)))

;; Access consumers must not reinterpret control-boundary tokens as home IDs.
;; Transport itself keeps every kind, including invisible function boundaries.
(define (compiler-backend-text-origins-access-spans
  [capture : CompilerBackendTextOrigins]
  [text : (& text str)]) : (__tl_dyn-array CompilerBackendTextOrigin)
  (let
    [source : (__tl_dyn-array CompilerBackendTextOrigin)
      (compiler-backend-text-origins-find capture text)]
    [count : i64 0]
    (for [i (iterator.range 0 (array-length source))]
      (when
        (match (& (array-ref source i).kind)
          [(Access) true]
          [_ false])
        (+= count 1)))
    (when (= count (array-length source)) (return source))
    (in-arena
      (arena.Arena capture.owner)
      (let
        [result : (__tl_dyn-array CompilerBackendTextOrigin)
          (__tl_make-array CompilerBackendTextOrigin count)]
        [cursor : i64 0]
        (for [i (iterator.range 0 (array-length source))]
          (when
            (match (& (array-ref source i).kind)
              [(Access) true]
              [_ false])
            (set!
              (array-ref result cursor)
              (compiler-backend-text-origin-shift (& (array-ref source i)) 0))
            (+= cursor 1)))
        result))))

(defstruct CompilerBackendFunctionOriginRequest
  (function ir.CompilerIrSymbolId)
  (symbol String)
  (text String))

;; The actual function emitter supplies identity and its chosen entry symbol.
;; Matching validates that authority's placement; it cannot recover identity
;; for arbitrary equal-looking assembly. End is an existing final newline,
;; never an extra assembly directive or a fabricated memory access.
(define (compiler-backend-text-origins-function
  [capture : CompilerBackendTextOrigins]
  [request : CompilerBackendFunctionOriginRequest]) : CompilerBackendOriginTextResult
  (when (= capture.storage 0) (return (Ok request.text)))
  (let
    [length : i64 (string.string-length request.text)]
    [size : i64 (string.string-length request.symbol)]
    (when (= length 0) (return (Ok request.text)))
    (when
      (or
        (< request.function.value 0)
        (= size 0)
        (!= (string.string-ref (& request.text) (- length 1)) '\n'))
      (return
        (Err
          "stack traffic: function boundary needs a complete emitted function")))
    (for [i (iterator.range 0 size)]
      (let
        [byte : char (string.string-ref (& request.symbol) i)]
        (when
          (or
            (= byte '\n')
            (= byte '\r')
            (= byte '\t')
            (= byte ' ')
            (= byte ':'))
          (return (Err "stack traffic: invalid emitted function symbol")))))
    (let
      [label : String (str_cat.str-cat request.symbol ":")]
      [start : i64 -1]
      [source : (__tl_dyn-array CompilerBackendTextOrigin)
        (compiler-backend-text-origins-find capture (& request.text))]
      (for [at (iterator.range 0 (- length (+ size 1)))]
        (when
          (and
            (or (= at 0) (= (string.string-ref (& request.text) (- at 1)) '\n'))
            (string.is-string-prefix-at (& request.text) (& label) at)
            (= (string.string-ref (& request.text) (+ at (+ size 1))) '\n'))
          (when
            (>= start 0)
            (return (Err "stack traffic: duplicate emitted function entry")))
          (set! start at)))
      (when
        (< start 0)
        (return (Err "stack traffic: emitted function entry is missing")))
      (let
        [functions : CompilerBackendFunctionOriginList
          (compiler-backend-text-origins-functions capture)]
        (for [i (iterator.range 0 functions.len)]
          (when
            (= (array-ref functions.slots i) request.function.value)
            (return
              (Err
                "stack traffic: function was already emitted in this capture")))))
      (for [i (iterator.range 0 (array-length source))]
        (let
          [span : (& source CompilerBackendTextOrigin) (& (array-ref source i))]
          (unless
            (and
              (match (& span.kind)
                [(Access) true]
                [(DataLine _) (= span.token request.function.value)]
                [(TailExit _) (= span.token request.function.value)]
                [_ false])
              (>= span.start (+ start (+ size 1)))
              (<= span.end (- length 1)))
            (return
              (Err
                "stack traffic: function registration crosses existing origins")))))
      (in-arena
        (arena.Arena capture.owner)
        (let
          [copy : String (string.copy (& request.text))]
          [spans : (__tl_dyn-array CompilerBackendTextOrigin)
            (__tl_make-array
              CompilerBackendTextOrigin
              (+ 2 (array-length source)))]
          (set!
            (array-ref spans 0)
            (CompilerBackendTextOrigin
              start
              (+ start (+ size 1))
              request.function.value
              (FunctionStart)
              (string.copy (& label))))
          (for [i (iterator.range 0 (array-length source))]
            (set!
              (array-ref spans (+ i 1))
              (compiler-backend-text-origin-shift (& (array-ref source i)) 0)))
          (set!
            (array-ref spans (+ 1 (array-length source)))
            (CompilerBackendTextOrigin
              (- length 1)
              length
              request.function.value
              (FunctionEnd)
              "\n"))
          (let
            [published : String
              (compiler-backend-text-origins-publish capture copy spans)]
            (unsafe
              (let
                [destination : (MutPtr CompilerBackendTextOriginData)
                  (int->ptr
                    capture.storage
                    : (MutPtr CompilerBackendTextOriginData))]
                [data : CompilerBackendTextOriginData (ptr-read destination)]
                (compiler-backend-function-origin-list-push
                  (&mut data.functions)
                  request.function.value)
                (ptr-write! destination data)))
            (Ok published)))))))

(defstruct CompilerBackendFunctionOriginRange
  (function ir.CompilerIrSymbolId)
  (start i64)
  (end i64))

(defenum CompilerBackendFunctionOriginRangesResult
  (Ok (__tl_dyn-array CompilerBackendFunctionOriginRange))
  (Err String))

;; Boundaries must survive the same final byte transport as their operands.
;; An orphan, nested/repeated function or interleaved owner cannot be a census.
(define (compiler-backend-text-origins-function-ranges
  [capture : CompilerBackendTextOrigins]
  [text : (& text str)]) : CompilerBackendFunctionOriginRangesResult
  (when
    (= capture.storage 0)
    (return (Err "stack traffic: function ranges require an active capture")))
  (let
    [spans : (__tl_dyn-array CompilerBackendTextOrigin)
      (compiler-backend-text-origins-find capture text)]
    [facts : CompilerBackendStackAccessOriginList
      (compiler-backend-text-origins-accesses capture)]
    [functions : CompilerBackendFunctionOriginList
      (compiler-backend-text-origins-functions capture)]
    [count : i64 0]
    [length : i64 (string.string-length text)]
    (for [i (iterator.range 0 (array-length spans))]
      (when
        (match (& (array-ref spans i).kind)
          [(FunctionStart) true]
          [_ false])
        (+= count 1)))
    (unless
      (= count functions.len)
      (return (Err "stack traffic: final function boundary coverage differs")))
    (let
      [result : (__tl_dyn-array CompilerBackendFunctionOriginRange)
        (__tl_make-array CompilerBackendFunctionOriginRange count)]
      [seen : origin_index.Map (origin_index.with-capacity (+ 1 (* 2 count)))]
      [active : i64 -1]
      [begin : i64 -1]
      [cursor : i64 0]
      [previous-start : i64 0]
      (for [i (iterator.range 0 (array-length spans))]
        (let
          [span : (& spans CompilerBackendTextOrigin) (& (array-ref spans i))]
          (unless
            (and
              (>= span.start previous-start)
              (> span.end span.start)
              (<= span.end length)
              (>= span.token 0)
              (string.eq
                (& span.expected)
                (string.substring-view text span.start (- span.end span.start))))
            (return
              (Err "stack traffic: final function boundary witness changed")))
          (set! previous-start span.start)
          (match (& span.kind)
            [(FunctionStart)
              (unless
                (and
                  (< active 0)
                  (=
                    (string.string-ref
                      (& span.expected)
                      (- (string.string-length span.expected) 1))
                    ':'))
                (return
                  (Err "stack traffic: nested or malformed function start")))
              (unless
                (origin_index.insert-if-absent-ref!
                  (&mut seen)
                  span.token
                  cursor)
                (return (Err "stack traffic: repeated final function identity")))
              (set! active span.token)
              (set! begin span.start)]
            [(FunctionEnd)
              (unless
                (and
                  (= active span.token)
                  (>= active 0)
                  (string.eq (& span.expected) "\n"))
                (return
                  (Err "stack traffic: orphan or mismatched final function end")))
              (set!
                (array-ref result cursor)
                (CompilerBackendFunctionOriginRange
                  (ir.CompilerIrSymbolId active)
                  begin
                  span.end))
              (+= cursor 1)
              (set! active -1)]
            [(Access)
              (unless
                (and (>= active 0) (< span.token facts.len))
                (return
                  (Err
                    "stack traffic: stack access has no emitted function boundary")))
              (let
                [fact : (& facts CompilerBackendStackAccessOrigin)
                  (& (array-ref facts.slots span.token))]
                (match (compiler-backend-stack-access-origin-check fact)
                  [(Ok) unit]
                  [(Err message) (return (Err message))])
                (unless
                  (= fact.function.value active)
                  (return
                    (Err
                      "stack traffic: final access crosses function ownership"))))]
            [(DataLine _)
              (unless
                (and (>= active 0) (= span.token active))
                (return
                  (Err "stack traffic: final data crosses function ownership")))]
            [(TailExit anchor)
              (unless
                (and
                  (>= active 0)
                  (= span.token active)
                  (compiler-backend-tail-exit-anchor-valid? anchor))
                (return
                  (Err
                    "stack traffic: final tail exit crosses function ownership")))])))
      (unless
        (and (< active 0) (= cursor count))
        (return (Err "stack traffic: final function end is missing")))
      (for [i (iterator.range 0 functions.len)]
        (match (origin_index.get-borrowed
          (& seen)
          (array-ref functions.slots i))
          [(LookupFound _) unit]
          [(LookupMissing)
            (return
              (Err "stack traffic: final function identity was not emitted"))]))
      (Ok result))))

(define (compiler-backend-text-origins-functions
  [capture : CompilerBackendTextOrigins]) : CompilerBackendFunctionOriginList
  (if (= capture.storage 0)
    (compiler-backend-function-origin-list-new)
    (unsafe
      (let
        [data : CompilerBackendTextOriginData
          (ptr-read
            (int->ptr capture.storage : (Ptr CompilerBackendTextOriginData)))]
        data.functions))))

(defstruct CompilerBackendDataOriginRequest
  (function ir.CompilerIrSymbolId)
  (location CompilerBackendDataLocation)
  (text String)
  (start i64)
  (end i64))

;; Only an actual data emitter supplies this authority. Separate line witnesses
;; survive the existing per-line blits without making data a memory access.
(define (compiler-backend-text-origins-data
  [capture : CompilerBackendTextOrigins]
  [request : CompilerBackendDataOriginRequest]) : CompilerBackendOriginTextResult
  (when (= capture.storage 0) (return (Ok request.text)))
  (let
    [length : i64 (string.string-length request.text)]
    [lines : i64 0]
    [relocated? : bool
      (match (& request.location)
        [(OtherSection) true]
        [_ false])]
    (unless
      (and
        (>= request.function.value 0)
        (>= request.start 0)
        (> request.end request.start)
        (<= request.end length)
        (or
          (= request.start 0)
          (= (string.string-ref (& request.text) (- request.start 1)) '\n'))
        (= (string.string-ref (& request.text) (- request.end 1)) '\n'))
      (return
        (Err "stack traffic: emitted data needs complete lines and a function")))
    (when
      relocated?
      (let
        [header : String "    .pushsection .data.rel.ro,\"aw\",@progbits\n"]
        [footer : String "    .popsection\n"]
        (unless
          (and
            (>=
              (- request.end request.start)
              (+ (string.string-length header) (string.string-length footer)))
            (string.is-string-prefix-at
              (& request.text)
              (& header)
              request.start)
            (string.is-string-prefix-at
              (& request.text)
              (& footer)
              (- request.end (string.string-length footer))))
          (return
            (Err
              "stack traffic: relocated data needs its complete noncode section envelope")))))
    (when
      (>
        (array-length
          (compiler-backend-text-origins-find capture (& request.text)))
        0)
      (return (Err "stack traffic: data cannot replace existing origins")))
    (for [i (iterator.range request.start request.end)]
      (when
        (= (string.string-ref (& request.text) i) ';')
        (return
          (Err
            "stack traffic: data witness cannot contain multiple assembly statements")))
      (when (= (string.string-ref (& request.text) i) '\n') (+= lines 1)))
    (in-arena
      (arena.Arena capture.owner)
      (let
        [copy : String (string.copy (& request.text))]
        [spans : (__tl_dyn-array CompilerBackendTextOrigin)
          (__tl_make-array CompilerBackendTextOrigin lines)]
        [start : i64 request.start]
        [cursor : i64 0]
        (for [i (iterator.range request.start request.end)]
          (when
            (= (string.string-ref (& copy) i) '\n')
            (when
              (= i start)
              (return
                (Err "stack traffic: emitted data contains an empty line")))
            (when
              (and relocated? (!= start request.start) (!= (+ i 1) request.end))
              (unless
                (or
                  (string.is-string-prefix-at (& copy) "    .quad " start)
                  (string.eq
                    (string.substring-view (& copy) start (- i start))
                    "    .balign 8")
                  (= (string.string-ref (& copy) (- i 1)) ':'))
                (return
                  (Err
                    "stack traffic: relocated data contains an unsupported section or instruction line"))))
            (set!
              (array-ref spans cursor)
              (CompilerBackendTextOrigin
                start
                i
                request.function.value
                (DataLine (clone request.location))
                (string.substring (& copy) start (- i start))))
            (set! start (+ i 1))
            (+= cursor 1)))
        (Ok (compiler-backend-text-origins-publish capture copy spans))))))

(defstruct CompilerBackendTailExitRequest
  (function ir.CompilerIrSymbolId)
  (anchor CompilerBackendStackAccessAnchor)
  (text String))

(define (compiler-backend-tail-exit-anchor-valid?
  [anchor : (& anchor CompilerBackendStackAccessAnchor)]) : bool
  (match anchor
    [(SourceBlock block) (>= block 0)]
    [(AdapterBody) true]
    [_ false]))

;; A TailCall emitter, rather than a missing local label, proves this jump
;; leaves the current function. The whole instruction is a protected witness;
;; it carries no invented memory access or target-derived source identity.
(define (compiler-backend-text-origins-tail-exit
  [capture : CompilerBackendTextOrigins]
  [request : CompilerBackendTailExitRequest]) : CompilerBackendOriginTextResult
  (when (= capture.storage 0) (return (Ok request.text)))
  (let
    [length : i64 (string.string-length request.text)]
    (unless
      (and
        (>= request.function.value 0)
        (compiler-backend-tail-exit-anchor-valid? (& request.anchor))
        (or
          (and
            (> length 8)
            (string.is-string-prefix-at (& request.text) "    jmp " 0))
          (and
            (> length 9)
            (string.is-string-prefix-at (& request.text) "    jmpq " 0))))
      (return
        (Err "stack traffic: tail exit needs an emitted jump and source anchor")))
    (for [i (iterator.range 0 length)]
      (let
        [byte : char (string.string-ref (& request.text) i)]
        (when
          (or (= byte '\n') (= byte '\r') (= byte ';'))
          (return
            (Err "stack traffic: tail exit must be one complete instruction")))))
    (when
      (>
        (array-length
          (compiler-backend-text-origins-find capture (& request.text)))
        0)
      (return (Err "stack traffic: tail exit cannot replace existing origins")))
    (in-arena
      (arena.Arena capture.owner)
      (let
        [copy : String (string.copy (& request.text))]
        [spans : (__tl_dyn-array CompilerBackendTextOrigin)
          (__tl_make-array CompilerBackendTextOrigin 1)]
        (set!
          (array-ref spans 0)
          (CompilerBackendTextOrigin
            0
            length
            request.function.value
            (TailExit (clone request.anchor))
            (string.copy (& copy))))
        (Ok (compiler-backend-text-origins-publish capture copy spans))))))
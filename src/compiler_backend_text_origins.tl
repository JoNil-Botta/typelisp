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

;; Emitter-issued identity, before rendering or slot coloring can conflate
;; distinct values. Operation ordinals belong to the final stream consumer.
(defstruct CompilerBackendStackAccessOrigin
  (function ir.CompilerIrSymbolId)
  (block i64)
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

(defstruct CompilerBackendTextOrigin
  (start i64)
  (end i64)
  (token i64)
  (expected String))

(define (compiler-backend-text-origin-shift
  [origin : (& origin CompilerBackendTextOrigin)]
  [offset : i64]) : CompilerBackendTextOrigin
  (CompilerBackendTextOrigin
    (+ origin.start offset)
    (+ origin.end offset)
    origin.token
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

(defstruct CompilerBackendTextOriginData
  (index origin_index.Map)
  (entries origin_entries.Vec)
  (accesses CompilerBackendStackAccessOriginList))

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

;; Publish the typed snapshot and its protected text as one synchronous step.
;; A failed mark cannot leave an orphan access in the job's token inventory.
(define (compiler-backend-text-origins-record
  [capture : CompilerBackendTextOrigins]
  [access : CompilerBackendStackAccessOrigin]
  [operand : String]) : CompilerBackendOriginTextResult
  (when
    (or
      (< access.function.value 0)
      (< access.block 0)
      (< access.home 0)
      (<= access.home-bytes 0)
      (> access.access-bytes access.home-bytes)
      (<= access.access-bytes 0))
    (return (Err "stack traffic: invalid emitter access origin")))
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
            (compiler-backend-stack-access-origin-list-new)))
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
            origin.block
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
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
  (token i64))

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

(defenum CompilerBackendOriginTextResult
  (Ok String)
  (Err String))

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

(define (compiler-backend-text-origins-find
  [capture : CompilerBackendTextOrigins]
  [text : (& text str)]) : (__tl_dyn-array CompilerBackendTextOrigin)
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
                (return
                  (owned_view.compiler-owned-reference-shared-view
                    (& (array-ref entries index).origins)))))]))))
  (__tl_make-array CompilerBackendTextOrigin 0))

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
        (CompilerBackendTextOrigin 0 (string.string-length (& copy)) token))
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
                  (CompilerBackendTextOrigin
                    (+ offset origin.start)
                    (+ offset origin.end)
                    origin.token))
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
                (CompilerBackendTextOrigin
                  (- origin.start start)
                  (- origin.end start)
                  origin.token))
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
(import stdlib.clone as clone_gen)
(import stdlib.iterator)
(cfg compile-profile (import stdlib.io))
(cfg compile-profile (import stdlib.profile))
(cfg compile-profile (import compiler_profile_counters as counters))
(cfg compile-profile-summary (import compiler_profile_summary as cps))
(import compiler_ir_types)
(import compiler_ast_types)
(import compiler_diagnostic)
(import compiler_abi)
(import compiler_regalloc)
(import compiler_liveness)
(import compiler_opt_level as opt_level)
(import compiler_profile_state as profile_state)
(import stdlib.text_buf)
(import stdlib.text_buf_borrowed)
(import compiler_object as cobj)
(import compiler_intern as ci)
(import stdlib.arena)
(import stdlib.hashmap)
(import (hashmap.hashmap String i64) as backend_string_i64_map)
(import (hashmap.hashmap i64 i64) as backend_i64_i64_map)
(import stdlib.string)
(import compiler_str_cat as str_cat)
(import compiler_owned_view as owned_view)

(define compiler-backend-phi-xmm-cycle-register-metric : i64
  147)
(define compiler-backend-rsp-rebase-ok-metric : i64
  149)
(define compiler-backend-rsp-rebase-keep-metric : i64
  150)
(define compiler-backend-rsp-rebase-last-ok-metric : i64
  151)
(define compiler-backend-fpo-metric : i64
  152)
(define compiler-backend-fpo-rbp-plan-metric : i64
  153)
(define compiler-backend-fpo-demote-metric : i64
  154)
(define compiler-backend-fpo-push-metric : i64
  155)
(define compiler-backend-peephole-r10-dead-scan-cap-hits-metric : i64
  156)
(define compiler-backend-sweep-swept-stores-metric : i64
  157)
(define compiler-backend-sweep-swept-funcs-metric : i64
  158)
(define compiler-backend-sweep-dropped-funcs-metric : i64
  159)
(define compiler-backend-sweep-dropped-table-cap-metric : i64
  160)
(define compiler-backend-sweep-dropped-bytes-cap-metric : i64
  161)
(define compiler-backend-peephole-rmw-folded-metric : i64
  162)
(define compiler-backend-peephole-rmw-refused-metric : i64
  163)
(define compiler-backend-census-metric-end : i64
  164)

;; Raw active-arena bytes for the assembly-text builder below -- the same
;; allocator `stdlib.string`'s concat helpers use for every String they build.
(unsafe
  (extern (compiler-backend-asm-buf-alloc [size : i64]) : (MutPtr u8) (:symbol "tl_alloc")))

(cfg
  compile-profile
  (counters.defslots
    compiler-backend-profile-starts
    28
    (compiler-backend-profile-start-ms-metric)
    (compiler-backend-profile-start-total-metric)
    (compiler-backend-profile-start-live-metric)
    (compiler-backend-profile-detail-start-ms-metric)))

(cfg
  compile-profile-summary
  (define (compiler-backend-profile-summary-reset!
    [state : profile_state.CompilerProfileState]) : unit
    ;; Optimizer and backend rows share one job table. The driver performs the
    ;; single reset before either phase begins.
    unit))

(cfg
  compile-profile-summary
  (define (compiler-backend-profile-summary-emit
    [state : profile_state.CompilerProfileState]) : unit
    (cps.compiler-profile-summary-emit
      state
      cps.compiler-profile-summary-backend-function
      "backend"
      "function")
    (cps.compiler-profile-summary-emit
      state
      cps.compiler-profile-summary-backend-module
      "backend"
      "module")))

(cfg
  compile-profile
  (define (compiler-backend-profile-field [value : i64]) : String
    (str_cat.str-cat "|" (string.int->string value))))

(cfg
  compile-profile
  (define (compiler-backend-profile-start
    [state : profile_state.CompilerProfileState]) : unit
    (profile_state.compiler-profile-state-metric-set!
      state
      compiler-backend-profile-start-ms-metric
      (profile.now-ms))
    (profile_state.compiler-profile-state-metric-set!
      state
      compiler-backend-profile-start-total-metric
      (profile.alloc-total))
    (profile_state.compiler-profile-state-metric-set!
      state
      compiler-backend-profile-start-live-metric
      (profile.alloc-live))
    (profile.alloc-reset-peak)))

(cfg
  compile-profile
  (define (compiler-backend-profile-finish
    [state : profile_state.CompilerProfileState]
    [phase : String]) : unit
    (let
      [end-ms : i64 (profile.now-ms)]
      [end-total : i64 (profile.alloc-total)]
      [end-live : i64 (profile.alloc-live)]
      [peak-delta : i64
        (-
          (profile.alloc-peak)
          (profile_state.compiler-profile-state-metric-value
            state
            compiler-backend-profile-start-live-metric))]
      (io.print-error
        (str_cat.str-cat
          "compile-profile|backend."
          phase
          (compiler-backend-profile-field
            (-
              end-ms
              (profile_state.compiler-profile-state-metric-value
                state
                compiler-backend-profile-start-ms-metric)))
          (compiler-backend-profile-field
            (-
              end-total
              (profile_state.compiler-profile-state-metric-value
                state
                compiler-backend-profile-start-total-metric)))
          (compiler-backend-profile-field
            (-
              end-live
              (profile_state.compiler-profile-state-metric-value
                state
                compiler-backend-profile-start-live-metric)))
          (compiler-backend-profile-field peak-delta)
          "\n")))))

(cfg
  compile-profile
  (define (compiler-backend-profile-detail-start
    [state : profile_state.CompilerProfileState]) : unit
    (profile_state.compiler-profile-state-metric-set!
      state
      compiler-backend-profile-detail-start-ms-metric
      (profile.now-ms))))

(cfg
  compile-profile
  (define (compiler-backend-profile-detail-finish
    [state : profile_state.CompilerProfileState]
    [phase : String]
    [name : String]) : unit
    (let
      [elapsed : i64
        (-
          (profile.now-ms)
          (profile_state.compiler-profile-state-metric-value
            state
            compiler-backend-profile-detail-start-ms-metric))]
      (cfg
        compile-profile-summary
        (if (string.eq phase "function")
          (begin
            (cps.compiler-profile-summary-note!
              state
              cps.compiler-profile-summary-backend-function
              (owned_view.compiler-owned-shared-view name)
              elapsed)
            (cps.compiler-profile-summary-note-module!
              state
              cps.compiler-profile-summary-backend-module
              name
              elapsed))
          unit)
        (if (>= elapsed 1)
          (io.print-error
            (str_cat.str-cat
              "compile-profile-detail|backend."
              phase
              "|"
              (string.int->string elapsed)
              "|"
              name
              "\n"))
          unit)))))

(cfg
  compile-profile
  (define (compiler-backend-profile-function-name
    [backend-state : CompilerBackendState]
    [func : compiler_ir_types.CompilerIrFunction]) : String
    (match func
      [(Function name _ _ _ _ _)
        (compiler-backend-symbol-text-state backend-state name)])))

(defenum ResultBackendReg
  (Ok String)
  (Err String))

(defenum ResultBackendRegId
  (Ok i64)
  (Err String))

(define (compiler-backend-result-reg [reg : String] [message : String]) : ResultBackendReg
  (if (string.eq reg "")
    (Err message)
    (Ok reg)))

(defenum ResultBackendValue
  (Ok compiler_ir_types.CompilerIrValue)
  (Err String))

(defenum CompilerBackendVectorMemFold
  (No)
  (Some compiler_ir_types.CompilerIrValue))

;; `CompilerBackendPhiSource.Temp` carries the location its saved value lives in
;; while the cycle is being broken: invalid = the reserved frame temp slot, or a
;; canonical register ID when the outermost cycle break scavenged a free
;; register instead of staging on the stack. The single Temp consumer reads it
;; back from there.
(defenum CompilerBackendPhiSource
  (Value compiler_ir_types.CompilerIrValue)
  (Temp i64))

(defenum CompilerBackendPhiCopy
  (Copy i64 CompilerBackendPhiSource compiler_ast_types.AstType))

(defstruct CompilerBackendPhiCopySeq
  (slots (__tl_dyn-array CompilerBackendPhiCopy))
  (len i64))

(define (compiler-backend-phi-copy-seq-with-capacity [capacity : i64]) : CompilerBackendPhiCopySeq
  (CompilerBackendPhiCopySeq
    (__tl_make-array CompilerBackendPhiCopy capacity)
    0))

(define (compiler-backend-phi-copy-copy-range!
  [dst : (&mut dst (__tl_dyn-array CompilerBackendPhiCopy))]
  [src : (& src (__tl_dyn-array CompilerBackendPhiCopy))]
  [count : i64]) : unit
  (for [index (iterator.range 0 count)]
    (set!
      (array-ref dst index)
      (owned_view.compiler-owned-element-view src index))))

(define (compiler-backend-phi-copy-push!
  [seq : (&mut seq CompilerBackendPhiCopySeq)]
  [phi-copy : CompilerBackendPhiCopy]) : unit
  (if (< seq.len (array-length seq.slots))
    unit
    (let
      [bigger : (__tl_dyn-array CompilerBackendPhiCopy)
        (__tl_make-array
          CompilerBackendPhiCopy
          (compiler-backend-seq-capacity (array-length seq.slots)))]
      (compiler-backend-phi-copy-copy-range!
        (&mut bigger)
        (& seq.slots)
        seq.len)
      (set! seq.slots bigger)))
  (let
    [index : i64 seq.len]
    (set! (array-ref seq.slots index) phi-copy)
    (set! seq.len (+ index 1))))

(defmacro (compiler-backend-global-shared-view [place : Expr]) : Expr
  `(owned_view.compiler-owned-shared-view ,place))

(define (compiler-backend-i64-array-shared-view
  [items : (& items (__tl_dyn-array i64))]) : (__tl_dyn-array i64)
  (unsafe
    (ptr-read
      (ptr-cast (__tl_array-data (array items)) : (Ptr (__tl_dyn-array i64))))))

(define (compiler-backend-string-array-shared-view
  [items : (& items (__tl_dyn-array String))]) : (__tl_dyn-array String)
  (unsafe
    (ptr-read
      (ptr-cast (__tl_array-data (array items)) : (Ptr (__tl_dyn-array String))))))

(define (compiler-backend-string-shared-view [value : (& value str)]) : String
  (unsafe
    (ptr-read (ptr-cast (__tl_array-data (array value)) : (Ptr String)))))

(defmacro (compiler-backend-global-array-element-shared-view
  [items : Expr]
  [index : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-offset (__tl_array-data ,items) ,index))))

(defmacro (compiler-backend-box-field-shared-view [value : Expr] [field : Expr]) : Expr
  `(owned_view.compiler-owned-box-field-shared-view ,value ,field))

;; The object path stages an edge's copies in REVERSE instruction order.
(defmacro (compiler-backend-phi-copy-seq-rev-ref
  [copies : CompilerBackendPhiCopySeq]
  [index : i64]) : CompilerBackendPhiCopy
  `(owned_view.compiler-owned-element-view
    (__tl-project-field-name ,copies "slots")
    (- (- (__tl-project-field-name ,copies "len") 1) ,index)))

(defenum CompilerBackendMaybePhiCopy
  (No)
  (Some CompilerBackendPhiCopy))

(defenum ResultBackendPhiCopies
  (Ok CompilerBackendPhiCopySeq)
  (Err String))

(defenum CompilerBackendPhiReturnMatch
  (No)
  (Some compiler_ir_types.CompilerIrValue))

(defenum ResultBackendPhiReturnMatch
  (Ok CompilerBackendPhiReturnMatch)
  (Err String))

(defenum CompilerBackendMaybeImmediate
  (No)
  (Some String))

(defenum CompilerBackendMaybeAsm
  (No)
  (Some String))

(defenum CompilerBackendMaybeStackOperand
  (No)
  (Some String))

(defenum CompilerBackendVectorUse
  (Use String String))

(defenum ResultBackendVectorUse
  (Ok CompilerBackendVectorUse)
  (Err String))

(defstruct CompilerBackendGatherAdjust
  (first String)
  (second String))

(defenum ResultBackendGatherAdjust
  (Ok CompilerBackendGatherAdjust)
  (Err (Box compiler_diagnostic.CompilerDiagnostic)))

(defenum CompilerBackendMaskUse
  (Use String String))

(defenum ResultBackendMaskUse
  (Ok CompilerBackendMaskUse)
  (Err String))

;; Structured identity for memory locations the peephole owner map may track.
;; 0 is Unknown, positive keys are packed stack-slot identities
;; (%rbp/%rsp + displacement + explicit-displacement bit), and negative keys are
;; interned SYM(%rip) global symbols. Unknown never aliases a real location.
(define compiler-backend-peephole-owner-key-stack-bias : i64
  1073741824)

;; Per-register reload-elision owner map: for each general-purpose register
;; tracked by the register allocator, the parsed stack-slot/global key that the
;; register currently mirrors (loaded from and not yet clobbered), or Unknown if
;; the register's contents are unknown / not a known trackable memory location.
;; Used by the reload-elision peephole to drop redundant `movq <slot>, <reg>`
;; reloads for every register (not just %rax). %rbp and %rsp are intentionally
;; NOT tracked (frame/stack pointers); writing either invalidates the whole map.
(defstruct CompilerBackendPeepholeOwners
  (rax i64)
  (rcx i64)
  (rdx i64)
  (rbx i64)
  (rsi i64)
  (rdi i64)
  (r8 i64)
  (r9 i64)
  (r10 i64)
  (r11 i64)
  (r12 i64)
  (r13 i64)
  (r14 i64)
  (r15 i64))

;; Transient per-line descriptor for the streaming peephole. Every pair-rule
;; transfer copies this struct, and one is built for every assembly line, so it
;; stores only what the rules read and packs the small members into shared
;; words. The derived spellings are the `-desc-` accessors beside `parse-line`.
;;  * `span`      start in the low 32 bits, end in the high 32. Group texts are
;;                orders of magnitude below 2^31 bytes and both halves stay
;;                non-negative, so the shifts never touch the sign bit.
;;  * `mnemonic`  mnemonic start in the low 32 bits, its length in the high 32.
;;  * `flags`     the ten line predicates, one bit each.
;;  * `op-src-start` / `op-src-end` / `op-dst-start` the operand split. Only
;;                movq/zext lines split (the `has-operands` flag); the
;;                destination always runs to the line end, so it needs no field.
;;  * `op-flags`  source operand flags in bits 0..3, destination in bits 4..7.
;;  * `regs`      source / destination / last-operand register indices, biased
;;                by one so the -1 "none" sentinel packs, one byte each.
(defstruct CompilerBackendPeepholeLine
  (src String)
  (data (Ptr u8))
  (span i64)
  (mnemonic i64)
  (flags i64)
  (op-src-start i64)
  (op-src-end i64)
  (op-dst-start i64)
  (op-src-key i64)
  (op-dst-key i64)
  (op-flags i64)
  (regs i64))

;; One emitted line, compacted to 56 bytes for the dense array below. The fat
;; CompilerBackendPeepholeLine stays the TRANSIENT streaming descriptor; this is
;; what survives the emit step, carrying exactly what the three post-push
;; consumers read (sweep driver, sweep region, final render) and nothing else.
;;  * `src`    the owned synthesized text, or the group asm for borrowed lines.
;;             Uniform so `data` is always (string-data src) and never stored.
;;  * `span`   start | end << 32 (a group string is far below 2^31 bytes).
;;  * `meta`   kind / sweep flags / newline / owned / `.globl` / access width /
;;             memory-reference count -- see the accessors beside the builder.
;;  * `cand`     raw `movq SRC, N(%rsp)` offset, or the no-candidate sentinel.
;;  * `epilogue` raw `leaq N(%rsp), %rsp` offset, or the no-candidate sentinel.
;;  * `value`  the tracked rsp `$imm` when the line is a tracked rsp write, else
;;             the first `(%rsp)` displacement. The two are mutually exclusive:
;;             a tracked write has `$` immediately after its mnemonic, so it has
;;             no memory operand at all.
(defstruct CompilerBackendPeepholeLineRecord
  (src String)
  (span i64)
  (meta i64)
  (cand i64)
  (epilogue i64)
  (value i64))

;; Dense arena-backed line-record array produced by the streaming peephole and
;; consumed by the dead-store sweep and the single final render. `live` is the
;; parallel deletion mask (1 = emit, 0 = swept); marking is O(1), the arrays are
;; never rebuilt, and deadness stays OUT of the packed word because array-set!
;; rewrites a whole element.
;; `rmw-cands` holds the RMW-2 candidate spans the walk recognized, as the
;; record index of each window's middle (ALU) line, in emission order. It is
;; empty for a group with no foldable op at all. `abort-cands` and
;; `close-cands` are COLD-1's: the record index of every noreturn abort call
;; and of every line that closes a function (`.size`, `.cfi_endproc`,
;; `.seh_endproc`, `.globl`, the debug and backtrace end labels), in emission
;; order.
(defstruct CompilerBackendPeepholeLineVec
  (lines (__tl_dyn-array CompilerBackendPeepholeLineRecord))
  (live (__tl_dyn-array i64))
  (len i64)
  (rmw-cands (__tl_dyn-array i64))
  (rmw-cand-len i64)
  (abort-cands (__tl_dyn-array i64))
  (abort-cand-len i64)
  (close-cands (__tl_dyn-array i64))
  (close-cand-len i64)
  (probe-cands (__tl_dyn-array i64))
  (probe-cand-len i64)
  ;; Record indices of simple stack LEAs, in emission order.
  (stack-lea-cands (__tl_dyn-array i64))
  (stack-lea-cand-len i64))

;; The physical chunks the streaming peephole parses in place, in emission
;; order, plus their combined byte count. A group chunk is one whole emitted
;; function/adapter text and is newline terminated, so an assembly line never
;; spans two chunks and each record can reference its own chunk as `src`.
;; `chunks-normalize` restores that invariant for any caller that appends a
;; partial line, so the walk itself never has to join across a boundary.
(defstruct CompilerBackendPeepholeChunkArray
  (items (__tl_dyn-array String))
  (count i64)
  (total i64))

;; State carried while sweeping chunked peephole output. Metadata is recorded
;; in function emission order, so the next entry is the only candidate to
;; match in each following assembly group.
(defstruct CompilerBackendPeepholeSweepChunkState
  (out text_buf.TextBuf)
  (group text_buf.TextBuf)
  (sweep-cursor i64))

;; Opt2 argument-entry symbols, indexed by ordinary function slot.
(defstruct CompilerBackendArgEntries
  (symbols backend_string_i64_map.Map)
  (function-count i64))

;; All mutable state that belongs to one assembly emission stream.  The opaque
;; one-word carrier below is passed explicitly through assembly, peephole and
;; sweep helpers; the backing cell is owned by its CompilerBackendState.
(defstruct CompilerBackendStreamStateData
  ;; Assembly stream (12 fields).
  (assembly-active bool)
  (assembly-raw-arena arena.Arena)
  (assembly-raw-mark arena.ArenaMark)
  (assembly-peephole-arena arena.Arena)
  (assembly-peephole-mark arena.ArenaMark)
  (assembly-home-arena arena.Arena)
  (assembly-out text_buf.TextBuf)
  (assembly-sweep-cursor i64)
  (assembly-batch text_buf.TextBuf)
  (assembly-batch-count i64)
  (assembly-raw-ready bool)
  (arg-entries i64)
  ;; Carry-safe label table (4 fields).
  (carry-safe-offsets (__tl_dyn-array i64))
  (carry-safe-lengths (__tl_dyn-array i64))
  (carry-safe-bytes (__tl_dyn-array u8))
  (carry-safe-bytes-count i64)
  ;; Dead-store sweep metadata (12 fields).
  (sweep-sym-off (__tl_dyn-array i64))
  (sweep-sym-len (__tl_dyn-array i64))
  (sweep-lo-arr (__tl_dyn-array i64))
  (sweep-hi-arr (__tl_dyn-array i64))
  (sweep-disp-arr (__tl_dyn-array i64))
  (sweep-win64-arr (__tl_dyn-array i64))
  (sweep-em-lo-arr (__tl_dyn-array i64))
  (sweep-em-hi-arr (__tl_dyn-array i64))
  (sweep-sym-bytes (__tl_dyn-array u8))
  (sweep-sym-bytes-count i64)
  (sweep-count i64)
  (sweep-coverage-bits (__tl_dyn-array i64))
  ;; Peephole owner table (5 fields).
  (owner-global-offsets (__tl_dyn-array i64))
  (owner-global-lengths (__tl_dyn-array i64))
  (owner-global-bytes (__tl_dyn-array u8))
  (owner-global-bytes-count i64)
  (owner-global-generation i64)
  ;; Dense line-record sink (3 fields).
  (records-lines (__tl_dyn-array CompilerBackendPeepholeLineRecord))
  (records-live (__tl_dyn-array i64))
  (records-len i64)
  ;; Address-taken frame objects (7 fields; GAP5 precise leaq poison).
  ;; `sweep-addr-rbp`/`sweep-addr-ext` hold one entry per emitted frame
  ;; address as (rbp-relative slot offset, object extent in bytes) in
  ;; emission order; `sweep-addr-start-arr`/`-len-arr` slice that list per
  ;; sweep-metadata entry; `sweep-poison-bits` is the per-region bitmap the
  ;; sweep marks the resolved poison spans in.
  (sweep-addr-rbp (__tl_dyn-array i64))
  (sweep-addr-ext (__tl_dyn-array i64))
  (sweep-addr-start-arr (__tl_dyn-array i64))
  (sweep-addr-len-arr (__tl_dyn-array i64))
  (sweep-addr-count i64)
  (sweep-addr-flushed i64)
  (sweep-addr-overflow bool)
  (sweep-poison-bits (__tl_dyn-array i64))
  ;; Per-program scratch for the address-extent tables and the poison bitmap:
  ;; a dedicated arena (raw handle + start mark) rewound by `sweep-reset!`, so
  ;; none of it is retained after a program's emission. `sweep-scratch-empty`
  ;; is the shared empty array the cleared fields point at.
  (sweep-addr-arena i64)
  (sweep-addr-mark i64)
  (sweep-scratch-empty (__tl_dyn-array i64)))

(defstruct CompilerBackendStreamState
  (address i64))

(define compiler-backend-assembly-stream-batch-function-limit : i64
  64)

(defenum CompilerBackendMaybeLabel
  (No)
  (Some i64))

(defenum CompilerBackendMaybeSignature
  (No)
  (Some compiler_ast_types.AstTypeList compiler_ast_types.AstType))

(defenum CompilerBackendGlobalTypeTable
  (Empty)
  (Dense backend_i64_i64_map.Map (__tl_dyn-array compiler_ast_types.AstType)))

(defenum ResultCompilerBackend
  (Ok String)
  (Err (Box compiler_diagnostic.CompilerDiagnostic)))

(define (clone-result-compiler-backend
  [value : (& value ResultCompilerBackend)]) : ResultCompilerBackend
  (match value
    [(Ok text) (Ok (string.copy text))]
    [(Err diag)
      (Err
        (box (compiler_diagnostic.clone-compiler-diagnostic (& (deref diag)))))]))

;; Append-only function-body assembly text buffer.
;;
;; The block/instruction spine appends emitted text straight into this growth
;; buffer, rather than materialising a String per assembly line, and finishes
;; ONCE to the body String the rest of the pipeline consumes: rsp-rebase-full,
;; the prologue splice and the peephole/group stage all see those bytes, and
;; the group-chunk invariant holds (one whole newline-terminated function text
;; per chunk).
;;
;; Only the prefix [0, len) is live. `finish` hands the live prefix out as a
;; String that ALIASES this storage, so a finished buffer is never appended to
;; or reused -- emission allocates a fresh one per body it builds.
;;
;; Storage comes straight from the active-arena allocator the String
;; constructors already use (`tl_alloc`, exactly what `concat*` calls),
;; not from `make-array`: an assembly buffer is fully overwritten by the
;; appends, so the element zero-fill `make-array` emits would be pure waste,
;; and the raw allocation lets `finish` publish the live prefix with no copy.
(defstruct CompilerBackendAsmBuf
  (data (MutPtr u8))
  (cap i64)
  (len i64))

(define (compiler-backend-asm-buf-with-capacity [capacity : i64]) : CompilerBackendAsmBuf
  (let
    [cap : i64
      (if (< capacity 16)
        16
        capacity)]
    (CompilerBackendAsmBuf
      (unsafe
        (compiler-backend-asm-buf-alloc cap))
      cap
      0)))

;; Bytes of assembly text budgeted per IR instruction when sizing a function
;; body buffer. Chosen so the overwhelming majority of functions never grow
;; while no function reserves much more than it writes (a fixed default would
;; either re-copy the large bodies or over-reserve for the many tiny ones).
(define compiler-backend-asm-bytes-per-instr : i64
  64)

;; Capacity for a one-line buffer (`    movq -1234(%rbp), %r11\n` and friends)
;; and for a short instruction sequence, so the common case never grows.
(define compiler-backend-asm-line-capacity : i64
  64)
(define compiler-backend-asm-seq-capacity : i64
  256)

(define (compiler-backend-asm-buf-grow!
  [buf : (&mut buf CompilerBackendAsmBuf)]
  [needed : i64]) : unit
  (let
    [doubled : i64 (* buf.cap 2)]
    [capacity : i64
      (if (< doubled needed)
        needed
        doubled)]
    [bigger : (MutPtr u8)
      (unsafe
        (compiler-backend-asm-buf-alloc capacity))]
    ;; The builder owns its initialized prefix and bigger is a fresh
    ;; allocation whose capacity covers that prefix.
    (unsafe
      (string.str-copy-bytes-into
        (ptr-cast buf.data : (Ptr u8))
        bigger
        0
        buf.len))
    (set! buf.data bigger)
    (set! buf.cap capacity)))

(define (compiler-backend-asm-buf-reserve!
  [buf : (&mut buf CompilerBackendAsmBuf)]
  [total : i64]) : unit
  (if (> total buf.cap)
    (compiler-backend-asm-buf-grow! buf total)
    unit))

;; Copy `n` bytes of `src` into `dst` at byte offset `off`, INLINE.
;;
;; This is the whole point of the builder: an operand part must reach the buffer
;; through one move loop, not through two call frames. `stdlib.string`'s
;; `str-copy-owned-bytes-into` does the identical word-then-tail copy, but as an
;; out-of-line call it costs about as much per part as the copy itself -- which
;; is exactly the cost `str-cat` was paying. Every macro argument is used more
;; than once, so callers pass plain locals.
(defmacro (compiler-backend-asm-copy-part!
  [dst : (MutPtr u8)]
  [off : i64]
  [src : String]
  [n : i64]) : unit
  `(let
    [asm-copy-src : (Ptr u8)
      (unsafe
        (string-data (& ,src)))]
    [asm-copy-words : i64 (/ ,n 8)]
    [asm-copy-src64 : (Ptr i64)
      (unsafe
        (ptr-cast asm-copy-src : (Ptr i64)))]
    [asm-copy-dst64 : (MutPtr i64)
      (unsafe
        (ptr-cast (ptr-offset ,dst ,off) : (MutPtr i64)))]
    [asm-copy-w : i64 0]
    [asm-copy-b : i64 (* asm-copy-words 8)]
    (while (< asm-copy-w asm-copy-words)
      (unsafe
        (ptr-write!
          (ptr-offset asm-copy-dst64 asm-copy-w)
          (ptr-read (ptr-offset asm-copy-src64 asm-copy-w))))
      (set! asm-copy-w (+ asm-copy-w 1)))
    (while (< asm-copy-b ,n)
      (unsafe
        (ptr-write!
          (ptr-offset ,dst (+ ,off asm-copy-b))
          (ptr-read (ptr-offset asm-copy-src asm-copy-b))))
      (set! asm-copy-b (+ asm-copy-b 1)))
    unit))

;; Copy `n` bytes of `part` to offset `off`; the caller has already reserved.
;; Out-of-line form for the cold splice path.
(define (compiler-backend-asm-buf-put!
  [buf : (&mut buf CompilerBackendAsmBuf)]
  [off : i64]
  [part : String]
  [n : i64]) : unit
  (if (= n 0)
    unit
    (unsafe
      (string.str-copy-owned-bytes-into part buf.data off n))))

(define (compiler-backend-asm-append
  [buf : (&mut buf CompilerBackendAsmBuf)]
  [part : String]) : unit
  (let
    [n : i64 (string.string-length part)]
    (if (= n 0)
      unit
      (let
        [off : i64 buf.len]
        (compiler-backend-asm-buf-reserve! buf (+ off n))
        (let
          [dst : (MutPtr u8) buf.data]
          (compiler-backend-asm-copy-part! dst off part n))
        (set! buf.len (+ off n))))))

(define (compiler-backend-asm-append2
  [buf : (&mut buf CompilerBackendAsmBuf)]
  [a : String]
  [b : String]) : unit
  (let
    [na : i64 (string.string-length a)]
    [nb : i64 (string.string-length b)]
    [total : i64 (+ na nb)]
    [off : i64 buf.len]
    (compiler-backend-asm-buf-reserve! buf (+ off total))
    (let
      [dst : (MutPtr u8) buf.data]
      [ob : i64 (+ off na)]
      (compiler-backend-asm-copy-part! dst off a na)
      (compiler-backend-asm-copy-part! dst ob b nb))
    (set! buf.len (+ off total))))

(define (compiler-backend-asm-append4
  [buf : (&mut buf CompilerBackendAsmBuf)]
  [a : String]
  [b : String]
  [c : String]
  [d : String]) : unit
  (let
    [na : i64 (string.string-length a)]
    [nb : i64 (string.string-length b)]
    [nc : i64 (string.string-length c)]
    [nd : i64 (string.string-length d)]
    [total : i64 (+ na (+ nb (+ nc nd)))]
    [off : i64 buf.len]
    (compiler-backend-asm-buf-reserve! buf (+ off total))
    (let
      [dst : (MutPtr u8) buf.data]
      [ob : i64 (+ off na)]
      [oc : i64 (+ ob nb)]
      [od : i64 (+ oc nc)]
      (compiler-backend-asm-copy-part! dst off a na)
      (compiler-backend-asm-copy-part! dst ob b nb)
      (compiler-backend-asm-copy-part! dst oc c nc)
      (compiler-backend-asm-copy-part! dst od d nd))
    (set! buf.len (+ off total))))

(define (compiler-backend-asm-append5
  [buf : (&mut buf CompilerBackendAsmBuf)]
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]) : unit
  (let
    [na : i64 (string.string-length a)]
    [nb : i64 (string.string-length b)]
    [nc : i64 (string.string-length c)]
    [nd : i64 (string.string-length d)]
    [ne : i64 (string.string-length e)]
    [total : i64 (+ na (+ nb (+ nc (+ nd ne))))]
    [off : i64 buf.len]
    (compiler-backend-asm-buf-reserve! buf (+ off total))
    (let
      [dst : (MutPtr u8) buf.data]
      [ob : i64 (+ off na)]
      [oc : i64 (+ ob nb)]
      [od : i64 (+ oc nc)]
      [oe : i64 (+ od nd)]
      (compiler-backend-asm-copy-part! dst off a na)
      (compiler-backend-asm-copy-part! dst ob b nb)
      (compiler-backend-asm-copy-part! dst oc c nc)
      (compiler-backend-asm-copy-part! dst od d nd)
      (compiler-backend-asm-copy-part! dst oe e ne))
    (set! buf.len (+ off total))))

;; Append the decimal spelling `string.int->string` gives `value`, written in
;; place instead of through a fresh String.
(define (compiler-backend-asm-append-decimal!
  [buf : (&mut buf CompilerBackendAsmBuf)]
  [value : i64]) : unit
  (let
    [negative : bool (< value 0)]
    [magnitude : i64
      (if negative
        value
        (- 0 value))]
    [digits : i64 (string.int->string-negative-digit-count magnitude)]
    [sign : i64
      (if negative
        1
        0)]
    [off : i64 buf.len]
    [total : i64 (+ sign digits)]
    (compiler-backend-asm-buf-reserve! buf (+ off total))
    (unsafe
      (when negative (string.int->string-write-byte! buf.data off 45))
      (string.int->string-write-negative-digits!
        buf.data
        (+ off sign)
        magnitude
        digits))
    (set! buf.len (+ off total))))

(define (compiler-backend-asm-buf-len [buf : (& buf CompilerBackendAsmBuf)]) : i64
  buf.len)

;; Splice `part` in at offset `at`, shifting the live tail right. Only the rare
;; emergency-spill wrap (a save that has to land in FRONT of text already
;; emitted) needs this; every other write into the body buffer is a pure
;; append.
(define (compiler-backend-asm-buf-insert-at!
  [buf : (&mut buf CompilerBackendAsmBuf)]
  [at : i64]
  [part : String]) : unit
  (let
    [n : i64 (string.string-length part)]
    (if (= n 0)
      unit
      (let
        [len : i64 buf.len]
        [tail : i64 (- len at)]
        (compiler-backend-asm-buf-reserve! buf (+ len n))
        (let
          [dst : (MutPtr u8) buf.data]
          [src : (Ptr u8)
            (unsafe
              (ptr-cast buf.data : (Ptr u8)))]
          [i : i64 (- tail 1)]
          (while (>= i 0)
            (unsafe
              (ptr-write!
                (ptr-offset dst (+ at (+ n i)))
                (ptr-read (ptr-offset src (+ at i)))))
            (-= i 1))
          unit)
        (compiler-backend-asm-buf-put! buf at part n)
        (set! buf.len (+ len n))))))

;; Hand the live prefix out as a String aliasing this buffer's storage. The
;; buffer is dead after this call.
(define (compiler-backend-asm-buf-finish [buf : (& buf CompilerBackendAsmBuf)]) : String
  (let
    [n : i64 buf.len]
    (if (= n 0)
      ""
      (unsafe
        (string-from-bytes (ptr-cast buf.data : (Ptr u8)) n)))))

(defenum ResultCompilerBackendObject
  (Ok cobj.CompilerObjectImage)
  (Err (Box compiler_diagnostic.CompilerDiagnostic)))

;; Serialization support is weaker than semantic support while direct object
;; lowering is incremental. Direct ELF/COFF callers consume this result before
;; choosing an object artifact; internal object-image consumers that do not
;; link the image retain their existing lower-level contract.
(defenum CompilerBackendObjectAbiContext
  (Call)
  (FunctionEntry)
  (FunctionReturn))

;; A closed route vocabulary shared by object emitters and package callers.
;; Context is target/kind enums or a numeric resource bound, never a path or
;; user-controlled symbol.
(defenum CompilerDirectObjectArtifactKind
  (Bin)
  (StaticLib))

(defenum CompilerDirectObjectFallbackReason
  (ArtifactKindUnavailable
    CompilerBackendTarget
    CompilerDirectObjectArtifactKind)
  (DebugMetadata)
  (BackendMode)
  (PrivateSpmdAbi)
  (ResourceBudget i64 i64)
  (UnsupportedSemantics)
  (UnsupportedAbi CompilerBackendTarget CompilerBackendObjectAbiContext)
  (ObjectEncoding)
  (UnsupportedCoffImage)
  (ObjectFixup)
  (ObjectRelocation)
  ;; A Windows object relocation against an external symbol that the runtime
  ;; binding table does not admit to the object route (#8318): the section,
  ;; the relocation's containing label and that label's offset, and the symbol.
  (UndeclaredExternal String String i64 String)
  (MissingEntrySymbol)
  (MissingRuntimeEntry)
  (EmptyTextSection)
  (ForcedAssembly)
  ;; The ELF writer has no initial-exec TLS relocation or `.data.rel.ro`
  ;; section yet, so a shared-object emission takes the assembly route.
  (SharedObjectCodeModel))

(defenum CompilerBackendObjectEligibility
  (Eligible)
  (Unsupported CompilerDirectObjectFallbackReason))

(define (compiler-backend-object-unsupported-semantics-category) : CompilerDirectObjectFallbackReason
  UnsupportedSemantics)

(defenum CompilerBackendSwitchValidation
  (Ok)
  (Err String))

(defstruct CompilerBackendPicOutput
  (asm String)
  (fixups String))

(defstruct CompilerBackendAddressBase
  (asm String)
  (reg i64))

(defenum ResultCompilerBackendAddressBase
  (Ok CompilerBackendAddressBase)
  (Err (Box compiler_diagnostic.CompilerDiagnostic)))

(defstruct CompilerBackendSimdIndexedAddress
  (asm String)
  (addr String))

(defenum ResultCompilerBackendSimdIndexedAddress
  (Ok CompilerBackendSimdIndexedAddress)
  (Err (Box compiler_diagnostic.CompilerDiagnostic)))

(defenum ResultCompilerBackendPic
  (Ok CompilerBackendPicOutput)
  (Err (Box compiler_diagnostic.CompilerDiagnostic)))

(defstruct CompilerBackendRuntimeTailPlan
  (profile bool)
  (tlci-macro-entry bool)
  (arena-debug bool)
  (startup-profile bool))

(defenum CompilerBackendRuntimeHelperOwner
  (Unknown)
  (Core)
  (StdlibFfi)
  (StdlibTypeLisp))

(defenum ResultCompilerBackendBuffer
  (Ok text_buf.TextBuf)
  (Err (Box compiler_diagnostic.CompilerDiagnostic)))

(defenum ResultCompilerBackendSymbolValidation
  (Ok backend_string_i64_map.Map)
  (Err (Box compiler_diagnostic.CompilerDiagnostic)))

(defenum CompilerBackendRuntimePlan
  (Plan bool bool bool bool bool bool bool CompilerBackendRuntimeTailPlan))

(defstruct CompilerBackendRuntimeIndex
  (defines backend_i64_i64_map.Map)
  (externs backend_i64_i64_map.Map)
  (calls backend_i64_i64_map.Map)
  (tlci-macro-entry-call-id i64)
  (startup-profile bool))

(defstruct CompilerBackendRuntimePlanWithIndex
  (plan CompilerBackendRuntimePlan)
  (index CompilerBackendRuntimeIndex))

;; Immutable target/ABI decisions for one prepared backend emission.  The
;; backend owner itself remains reusable: each prepared text/object boundary
;; installs a fresh value before any prefix, function, block, or runtime work.
;; Keeping the canonical ABI and closed platform selections together prevents
;; hot shared emission from repeatedly deriving them from a raw target.
(defenum CompilerBackendTarget
  (Linux)
  (Windows))

(clone_gen.gen-clone CompilerBackendTarget)

(defenum CompilerBackendObjectFormatPolicy
  (Elf)
  (Coff))

(defstruct CompilerBackendTargetPolicy
  (target CompilerBackendTarget)
  (abi compiler_abi.CompilerRegTargetAbi)
  (linux bool)
  (windows bool)
  (seh-unwind bool)
  (stack-probe bool)
  (red-zone bool)
  (linux-syscall bool)
  (object-format CompilerBackendObjectFormatPolicy)
  (gp-arg-register-count i64)
  (float-arg-register-count i64)
  (outgoing-shadow-space i64)
  ;; The Linux shared-object code model (#8257): initial-exec TLS, hidden
  ;; internal symbols, relocated constants in `.data.rel.ro`, no absolute
  ;; switch dispatch and no program entry. False for every executable.
  (shared-object bool))

(define (compiler-backend-target-policy-new [target : CompilerBackendTarget]) : CompilerBackendTargetPolicy
  (let
    [abi : compiler_abi.CompilerRegTargetAbi
      (match target
        [(CompilerBackendTarget.Linux) Linux]
        [(CompilerBackendTarget.Windows) Windows])]
    [linux : bool (compiler_abi.compiler-abi-linux? abi)]
    [windows : bool (compiler_abi.compiler-abi-windows? abi)]
    (CompilerBackendTargetPolicy
      target
      abi
      linux
      windows
      windows
      windows
      linux
      linux
      (if linux
        Elf
        Coff)
      (compiler_abi.compiler-abi-gp-arg-register-count abi (Platform))
      (compiler_abi.compiler-abi-float-arg-register-count abi (Platform))
      (compiler_abi.compiler-abi-outgoing-shadow-space abi (Platform))
      false)))

;; TARGET's policy under the code model SHARED-OBJECT selects. Only an ELF
;; target has a shared-object code model; the prepared boundaries reject the
;; request for any other before using this.
(define (compiler-backend-target-policy-for-code-model
  [target : CompilerBackendTarget]
  [shared-object : bool]) : CompilerBackendTargetPolicy
  (let
    [policy : CompilerBackendTargetPolicy
      (compiler-backend-target-policy-new target)]
    (CompilerBackendTargetPolicy
      policy.target
      policy.abi
      policy.linux
      policy.windows
      policy.seh-unwind
      policy.stack-probe
      policy.red-zone
      policy.linux-syscall
      policy.object-format
      policy.gp-arg-register-count
      policy.float-arg-register-count
      policy.outgoing-shadow-space
      shared-object)))

;; Facts for code that holds only a raw target. Each reads the target's policy,
;; so `compiler-backend-target-policy-new` stays the one place a target is
;; mapped to its ABI, unwind, object format and runtime choices.
;; `scripts/check-codegen-target-dispatch.sh` keeps every other shared scope
;; free of Linux/Windows tests (src/TESTING.md, Cross-Target Codegen Parity).
(define (compiler-backend-target-object-format [target : CompilerBackendTarget]) : CompilerBackendObjectFormatPolicy
  (compiler-backend-target-policy-new target).object-format)

(define (compiler-backend-object-format-elf?
  [format : CompilerBackendObjectFormatPolicy]) : bool
  (match format
    [(Elf) true]
    [(Coff) false]))

(define (compiler-backend-target-elf? [target : CompilerBackendTarget]) : bool
  (compiler-backend-object-format-elf?
    (compiler-backend-target-object-format target)))

(define (compiler-backend-target-coff? [target : CompilerBackendTarget]) : bool
  (not (compiler-backend-target-elf? target)))

(define (compiler-backend-target-seh-unwind? [target : CompilerBackendTarget]) : bool
  (compiler-backend-target-policy-new target).seh-unwind)

(define (compiler-backend-target-stack-probe? [target : CompilerBackendTarget]) : bool
  (compiler-backend-target-policy-new target).stack-probe)

(define (compiler-backend-target-sysv-aggregates?
  [target : CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]) : bool
  (compiler_abi.compiler-abi-aggregate-eightbyte-classes?
    (compiler-backend-target-abi target)
    convention))

;; The target's name as diagnostics and fallback categories spell it.
(define (compiler-backend-target-triple [target : CompilerBackendTarget]) : String
  (match target
    [(CompilerBackendTarget.Linux) "linux-x86_64"]
    [(CompilerBackendTarget.Windows) "windows-x86_64"]))

;; Raw `syscall` instructions are admitted only on Linux; other targets report
;; this. A literal, so the diagnostic owns no allocation.
(define (compiler-backend-raw-syscall-diagnostic) : String
  "backend: syscall is only supported on the linux-x86_64 target")

;; A backend job owns one exact intern capability and the small mutable state
;; that is safe to share across its emission phases.  Keep the public carrier
;; opaque and one machine word; all mutable data lives in the owner arena cell
;; behind `address`, just like TcJobState.
(defenum CompilerBackendEmissionSymbols
  (None)
  (Program CompilerBackendProgramIndex))

(defstruct CompilerBackendStateData
  (intern-state ci.InternCompatState)
  (owner-arena i64)
  ;; Complete backend results retain transient strings in this explicit outer
  ;; emission owner, which may differ from the state owner in batch mode.
  (emission-arena i64)
  ;; Scalar register allocation is a per-job option.  Keep it alongside the
  ;; exact intern capability so concurrent backend jobs never consult a
  ;; process-global opt-level switch.
  (scalar-registers-enabled bool)
  (tail-merging-enabled bool)
  (optimize-for-size bool)
  (user-symbol-cache-keys (__tl_dyn-array i64))
  (user-symbol-cache-values (__tl_dyn-array String))
  (user-symbol-cache-epochs (__tl_dyn-array i64))
  (user-symbol-cache-epoch i64)
  (user-symbol-cache-count i64)
  (user-symbol-cache-generation i64)
  (user-symbol-cache-table-id i64)
  (absolute-switch-ok bool)
  (abort-site-counter i64)
  ;; Lazily allocated on the first emitted function.  Keep only the opaque
  ;; address here so the job owner stays independent of the function-state
  ;; types declared beside CompilerBackendEmissionContext below.
  (function-state-address i64)
  ;; Lazily allocated stream owner.  The backing cell contains every mutable
  ;; assembly/peephole/sweep field and is never selected through global state.
  (stream-state-address i64)
  ;; Retained operand render storage is owned by this state's lazy arena.
  ;; Keep all eight lanes empty until their first relevant use.
  (lazy-table-arena i64)
  (slot-cache-values (__tl_dyn-array String))
  (slot-cache-epochs (__tl_dyn-array i64))
  (slot-cache-epoch i64)
  (frame-offset-cache-values (__tl_dyn-array String))
  (frame-offset-cache-epochs (__tl_dyn-array i64))
  (immediate-cache-values (__tl_dyn-array String))
  (immediate-cache-epochs (__tl_dyn-array i64))
  ;; Append-only state extension: hot backend accessors address earlier lanes
  ;; in place, so new job capabilities must not perturb their established
  ;; offsets. Production drivers install this once immediately after lowering;
  ;; compatibility entrypoints build an equivalent index at their boundary.
  (representations compiler_ir_types.CompilerIrRepresentationIndex)
  (has-representations bool)
  ;; Batch states outlive individual compile entries. Representation facts do
  ;; not: their maps are rebuilt from each entry's lowered program. Keep those
  ;; maps in a dedicated reusable arena so replacing the capability cannot grow
  ;; the persistent backend-state owner once per batch entry.
  (representation-arena i64)
  (representation-mark i64)
  ;; One-word view into the exact CompilerProfileState owned by this job.
  ;; It is installed at the explicit profile/backend emission boundary.
  (metrics profile_state.CompilerProfileMetrics)
  ;; IAG-1: symbol id -> inline byte size for every runtime-initialised memory
  ;; aggregate global this program stores INLINE at its own symbol rather than
  ;; behind an arena box pointer. Empty until the whole-program classification
  ;; below publishes it, so any path that reaches emission without it keeps the
  ;; boxed-cell behaviour.
  (inline-aggregate-globals backend_i64_i64_map.Map)
  ;; Append-only per-emission capability. Prepared entrypoints replace this
  ;; value before use, so a long-lived backend owner may emit another target.
  (emission-target-policy CompilerBackendTargetPolicy)
  ;; Shared with semantic/lowering/optimizer work by the owning driver. The
  ;; diagnostic module gives its payloads an independently resettable arena.
  (advisory-sink compiler_diagnostic.CompilerAdvisorySink)
  ;; The requested code model (#8257): true asks every later emission of this
  ;; owner for a Linux shared object. Prepared boundaries read it into the
  ;; emission policy; the direct object route refuses it.
  (shared-object-code-model bool)
  ;; The type storage `representations` was built from. Its word counts and
  ;; class masks describe that program's types only, so return-storage
  ;; authorization reuses them only while this stamp is valid for the pools of
  ;; the program being authorized; a batch entry never sees another entry's.
  (representation-type-stamp compiler_ast_types.AstMaybeTypePoolStamp)
  ;; The same immutable symbol index ordinary loads use, installed for this
  ;; emission. Operand folds and rematerialization must name the same cell.
  (emission-symbols CompilerBackendEmissionSymbols)
  ;; Copy thunks (see compiler-backend-copy-thunk-applies?): one table per
  ;; emission. `copy-thunks` maps a chunk-run key to its thunk index, so a
  ;; second site of the same shape emits a call instead of another inline
  ;; sequence; `copy-thunk-bodies` holds that index's emitted instruction
  ;; text, allocated on the first registration, and `copy-thunk-count` is the
  ;; number of registered thunks and the next index.
  (copy-thunks backend_string_i64_map.Map)
  (copy-thunk-bodies (__tl_dyn-array String))
  (copy-thunk-count i64)
  ;; Per-program scratch for the registry: a dedicated arena (raw handle +
  ;; start mark) rewound by `compiler-backend-copy-thunks-reset!`, so no thunk
  ;; key, body or table outlives the emission that registered it.
  (copy-thunk-arena i64)
  (copy-thunk-mark i64)
  ;; The caller owns the complete native link and has supplied no foreign
  ;; objects or link options. Assembly and library requests leave this false.
  (closed-executable bool))

(defstruct CompilerBackendState
  (address i64))

;; Opaque per-function owner.  Its typed storage is declared beside the compact
;; sequence carriers below; the one-word handle is available to the mode/ABI
;; helpers and CompilerBackendEmissionContext before then.
(defstruct CompilerBackendFunctionState
  (address i64))

;; One borrowed register-sized argument carries the state and source facts used
;; while parsing a group.  Keeping the hot parser below six machine arguments
;; avoids spilling every line's newline/ownership flags through the stack.
(defstruct CompilerBackendPeepholeParseContext
  (backend-state-address i64)
  (stream-address i64)
  (data (Ptr u8)))

(define (compiler-backend-state-size) : i64
  (comptime (size-of (type CompilerBackendState))))

(define (compiler-backend-state-new-with-metrics
  [intern-state : ci.InternCompatState]
  [metrics : profile_state.CompilerProfileMetrics]) : CompilerBackendState
  (let
    [owner-arena : i64 (arena.tl_arena_current)]
    [cell : (__tl_dyn-array CompilerBackendStateData)
      (__tl_make-array CompilerBackendStateData 1)]
    (set!
      (array-ref cell 0)
      (CompilerBackendStateData
        (compiler-backend-global-shared-view intern-state)
        owner-arena
        0
        false
        false
        false
        ;; User-symbol storage is deliberately lazy.  In particular, a
        ;; generated id near the high end of the intern lane must not force
        ;; an intern-capacity-sized allocation.
        (__tl_make-array i64 0)
        (__tl_make-array String 0)
        (__tl_make-array i64 0)
        1
        0
        (ci.intern-compat-state-generation intern-state)
        (ci.intern-compat-state-table-id intern-state)
        false
        0
        0
        0
        0
        (__tl_make-array String 0)
        (__tl_make-array i64 0)
        1
        (__tl_make-array String 0)
        (__tl_make-array i64 0)
        (__tl_make-array String 0)
        (__tl_make-array i64 0)
        (compiler_ir_types.compiler-ir-representation-index-empty)
        false
        0
        0
        metrics
        (backend_i64_i64_map.with-capacity 1)
        (compiler-backend-target-policy-new CompilerBackendTarget.Linux)
        (compiler_diagnostic.compiler-advisory-sink-new)
        false
        (compiler_ast_types.AstMaybeTypePoolStamp.No)
        CompilerBackendEmissionSymbols.None
        (backend_string_i64_map.with-capacity 1)
        (__tl_make-array String 0)
        0
        0
        0
        false))
    (CompilerBackendState
      (cast
        (unsafe
          (ptr->int
            (ptr-cast (__tl_array-data cell) : (Ptr CompilerBackendStateData))))
        : i64))))

(define (compiler-backend-state-new [intern-state : ci.InternCompatState]) : CompilerBackendState
  (compiler-backend-state-new-with-metrics
    intern-state
    (profile_state.compiler-profile-state-metrics
      (profile_state.compiler-profile-state-new))))

(define (compiler-backend-state-emission-target-policy
  [state : CompilerBackendState]) : CompilerBackendTargetPolicy
  (unsafe
    (deref (compiler-backend-state-view state)).emission-target-policy))

(define (compiler-backend-state-set-emission-target-policy!
  [state : CompilerBackendState]
  [policy : CompilerBackendTargetPolicy]) : unit
  (unsafe
    (set!
      (deref (compiler-backend-state-ptr state)).emission-target-policy
      policy)))

(define (compiler-backend-state-shared-object-code-model?
  [state : CompilerBackendState]) : bool
  (unsafe
    (deref (compiler-backend-state-view state)).shared-object-code-model))

(define (compiler-backend-state-closed-executable?
  [state : CompilerBackendState]) : bool
  (unsafe
    (deref (compiler-backend-state-view state)).closed-executable))

(define (compiler-backend-state-set-closed-executable!
  [state : CompilerBackendState]
  [enabled : bool]) : unit
  (unsafe
    (set! (deref (compiler-backend-state-ptr state)).closed-executable enabled)))

(define (compiler-backend-state-set-shared-object-code-model!
  [state : CompilerBackendState]
  [shared-object : bool]) : unit
  (unsafe
    (set!
      (deref (compiler-backend-state-ptr state)).shared-object-code-model
      shared-object)))

;; Install representations without a type-storage identity: emission may read
;; them, but return-storage authorization never reuses them.
(define (compiler-backend-state-set-representations!
  [state : CompilerBackendState]
  [representations : compiler_ir_types.CompilerIrRepresentationIndex]) : unit
  (let
    [data : (MutPtr CompilerBackendStateData)
      (compiler-backend-state-ptr state)]
    (unsafe
      (set! (deref data).representations representations)
      (set! (deref data).has-representations true)
      (set!
        (deref data).representation-type-stamp
        (compiler_ast_types.AstMaybeTypePoolStamp.No)))))

;; Install representations built from `pools`, recording that type storage.
(define (compiler-backend-state-set-representations-for-pools!
  [state : CompilerBackendState]
  [pools : (& pools compiler_ast_types.AstNodePoolContext)]
  [representations : compiler_ir_types.CompilerIrRepresentationIndex]) : unit
  (let
    [data : CompilerBackendStateData (compiler-backend-state-data state)]
    (set! data.representations representations)
    (set! data.has-representations true)
    (set!
      data.representation-type-stamp
      (compiler_ast_types.ast-node-pool-context-type-stamp pools))
    (compiler-backend-state-data-set! state data)))

;; Whether the installed representations were built from `pools`' live type
;; storage (and so describe the types of the program being emitted).
(define (compiler-backend-state-representations-for-pools?
  [data : (& data CompilerBackendStateData)]
  [pools : (& pools compiler_ast_types.AstNodePoolContext)]) : bool
  (and
    data.has-representations
    (match data.representation-type-stamp
      [(compiler_ast_types.AstMaybeTypePoolStamp.Some stamp)
        (compiler_ast_types.ast-node-pool-context-type-stamp-valid?
          pools
          (& stamp))]
      [(compiler_ast_types.AstMaybeTypePoolStamp.No) false])))

(define (compiler-backend-state-representations
  [state : CompilerBackendState]
  [type-segment-bases : i64]
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [externs : compiler_ir_types.CompilerIrExternSeq]) : compiler_ir_types.CompilerIrRepresentationIndex
  (let
    [data : (Ptr CompilerBackendStateData) (compiler-backend-state-view state)]
    (if (unsafe
      (deref data).has-representations)
      ;; Nominal representation facts survive optimizer rewrites, but a
      ;; return-storage catalog is tied to the current declaration revision.
      ;; Rebuild that catalog at this program boundary rather than retaining
      ;; removed or replaced function declarations from an earlier stage.
      (let
        [retained : compiler_ir_types.CompilerIrRepresentationIndex
          (unsafe
            (deref data).representations)]
        (compiler_ir_types.CompilerIrRepresentationIndex
          retained.word-counts
          retained.class-masks
          retained.stable-word-masks
          (compiler_ir_types.compiler-ir-return-storage-index-reconcile
            type-segment-bases
            (compiler_ir_types.compiler-ir-return-storage-index-claims
              type-segment-bases
              retained.return-storage.type-count
              functions
              externs)
            retained.return-storage)))
      (compiler_ir_types.compiler-ir-representation-index-build
        type-segment-bases
        (&
          (Program
            (compiler_ir_types.compiler-ir-global-seq-empty)
            functions
            externs
            (compiler_ir_types.CompilerIrReturnStorageAuthority.None)))
        (compiler_ir_types.compiler-ir-representation-index-empty)))))

(define (compiler-backend-return-storage-authority-diagnostic
  [problem : String]) : (Box compiler_diagnostic.CompilerDiagnostic)
  (box
    (compiler_diagnostic.compiler-diagnostic-at-start
      ""
      (str_cat.str-cat "backend: " problem))))

(define (compiler-backend-state-ptr [state : CompilerBackendState]) : (MutPtr
    CompilerBackendStateData)
  (unsafe
    (int->ptr (cast state.address : u64) : (MutPtr CompilerBackendStateData))))

(define (compiler-backend-state-view [state : CompilerBackendState]) : (Ptr
    CompilerBackendStateData)
  (unsafe
    (int->ptr (cast state.address : u64) : (Ptr CompilerBackendStateData))))

(define (compiler-backend-state-data [state : CompilerBackendState]) : CompilerBackendStateData
  (unsafe
    (ptr-read
      (int->ptr (cast state.address : u64) : (Ptr CompilerBackendStateData)))))

(define (compiler-backend-state-data-set!
  [state : CompilerBackendState]
  [data : CompilerBackendStateData]) : unit
  (unsafe
    (ptr-write!
      (int->ptr (cast state.address : u64) : (MutPtr CompilerBackendStateData))
      data)))

(define (compiler-backend-state-metrics [state : CompilerBackendState]) : profile_state.CompilerProfileMetrics
  (unsafe
    (deref (compiler-backend-state-view state)).metrics))

(define (compiler-backend-state-advisory-sink [state : CompilerBackendState]) : compiler_diagnostic.CompilerAdvisorySink
  (unsafe
    (deref (compiler-backend-state-view state)).advisory-sink))

(define (compiler-backend-state-set-advisory-sink!
  [state : CompilerBackendState]
  [sink : compiler_diagnostic.CompilerAdvisorySink]) : unit
  (unsafe
    (set! (deref (compiler-backend-state-ptr state)).advisory-sink sink)))

(define (compiler-backend-state-set-metrics!
  [state : CompilerBackendState]
  [metrics : profile_state.CompilerProfileMetrics]) : unit
  (unsafe
    (set! (deref (compiler-backend-state-ptr state)).metrics metrics)))

(define (compiler-backend-state-inline-aggregate-globals
  [state : CompilerBackendState]) : backend_i64_i64_map.Map
  (unsafe
    (deref (compiler-backend-state-view state)).inline-aggregate-globals))

(define (compiler-backend-state-set-inline-aggregate-globals!
  [state : CompilerBackendState]
  [globals : backend_i64_i64_map.Map]) : unit
  (unsafe
    (set!
      (deref (compiler-backend-state-ptr state)).inline-aggregate-globals
      globals)))

;; IAG-1: the inline byte size of `name`'s cell, or 0 when the global keeps the
;; boxed 8-byte pointer cell. This is the ONE predicate every emission site
;; consults; a 0 answer is the pre-IAG behaviour everywhere.
(define (compiler-backend-inline-aggregate-global-size
  [state : CompilerBackendState]
  [name : i64]) : i64
  (let
    [table : backend_i64_i64_map.Map
      (compiler-backend-state-inline-aggregate-globals state)]
    (match (backend_i64_i64_map.get
      (& table)
      (compiler_ir_types.compiler-ir-symbol-id name))
      [(LookupFound size) size]
      [(LookupMissing) 0])))

(define (compiler-backend-inline-aggregate-global?
  [state : CompilerBackendState]
  [name : i64]) : bool
  (> (compiler-backend-inline-aggregate-global-size state name) 0))

;; The rip-relative operand of an inline aggregate global's cell at `disp`.
(define (compiler-backend-inline-aggregate-symbol-operand
  [symbol : (& symbol str)]
  [disp : i64]) : String
  (if (= disp 0)
    (str_cat.str-cat symbol "(%rip)" "" "")
    (str_cat.str-cat symbol "+" (string.int->string disp) "(%rip)")))

(cfg
  test
  (define (compiler-backend-metric-set!
    [state : CompilerBackendState]
    [metric : i64]
    [value : i64]) : unit
    (profile_state.compiler-profile-metrics-set!
      (compiler-backend-state-metrics state)
      metric
      value)))

(cfg
  test
  (define (compiler-backend-metric-add!
    [state : CompilerBackendState]
    [metric : i64]
    [value : i64]) : unit
    (profile_state.compiler-profile-metrics-add!
      (compiler-backend-state-metrics state)
      metric
      value)))

;; Read/write the hottest job-owned scalar without copying the wide opaque
;; StateData value.  Function emitters ask for their owner at nearly every
;; operand-home query; materialising all cache arrays just to read this address
;; would make explicit ownership substantially more expensive.
(define (compiler-backend-state-function-state-address
  [state : CompilerBackendState]) : i64
  (unsafe
    (ptr-read
      (int->ptr
        (cast
          (+
            state.address
            (comptime
              (offset-of (type CompilerBackendStateData) function-state-address)))
          : u64)
        : (Ptr i64)))))

(define (compiler-backend-state-set-function-state-address!
  [state : CompilerBackendState]
  [address : i64]) : unit
  (unsafe
    (ptr-write!
      (int->ptr
        (cast
          (+
            state.address
            (comptime
              (offset-of (type CompilerBackendStateData) function-state-address)))
          : u64)
        : (MutPtr i64))
      address)))

(define (compiler-backend-stream-state-ptr [state : CompilerBackendStreamState]) : (MutPtr
    CompilerBackendStreamStateData)
  (unsafe
    (int->ptr
      (cast state.address : u64)
      : (MutPtr CompilerBackendStreamStateData))))

(define (compiler-backend-stream-state-view
  [state : CompilerBackendStreamState]) : (Ptr CompilerBackendStreamStateData)
  (unsafe
    (int->ptr (cast state.address : u64) : (Ptr CompilerBackendStreamStateData))))

(define (compiler-backend-stream-state-data
  [state : CompilerBackendStreamState]) : CompilerBackendStreamStateData
  (unsafe
    (ptr-read
      (int->ptr
        (cast state.address : u64)
        : (Ptr CompilerBackendStreamStateData)))))

(define (compiler-backend-stream-state-data-set!
  [state : CompilerBackendStreamState]
  [data : CompilerBackendStreamStateData]) : unit
  (unsafe
    (ptr-write!
      (int->ptr
        (cast state.address : u64)
        : (MutPtr CompilerBackendStreamStateData))
      data)))

(define (compiler-backend-stream-state-new) : CompilerBackendStreamState
  (let
    [cell : (__tl_dyn-array CompilerBackendStreamStateData)
      (__tl_make-array CompilerBackendStreamStateData 1)]
    (set!
      (array-ref cell 0)
      (CompilerBackendStreamStateData
        false
        (unsafe
          (arena.Arena 0))
        (arena.ArenaMark 0)
        (unsafe
          (arena.Arena 0))
        (arena.ArenaMark 0)
        (unsafe
          (arena.Arena 0))
        (text_buf.empty)
        0
        (text_buf.empty)
        0
        false
        0
        (__tl_make-array i64 0)
        (__tl_make-array i64 0)
        (__tl_make-array u8 0)
        0
        (__tl_make-array i64 0)
        (__tl_make-array i64 0)
        (__tl_make-array i64 0)
        (__tl_make-array i64 0)
        (__tl_make-array i64 0)
        (__tl_make-array i64 0)
        (__tl_make-array i64 0)
        (__tl_make-array i64 0)
        (__tl_make-array u8 0)
        0
        0
        (__tl_make-array i64 0)
        (__tl_make-array i64 0)
        (__tl_make-array i64 0)
        (__tl_make-array u8 0)
        0
        1
        (__tl_make-array CompilerBackendPeepholeLineRecord 0)
        (__tl_make-array i64 0)
        0
        (__tl_make-array i64 0)
        (__tl_make-array i64 0)
        (__tl_make-array i64 0)
        (__tl_make-array i64 0)
        0
        0
        false
        (__tl_make-array i64 0)
        0
        0
        (__tl_make-array i64 0)))
    (CompilerBackendStreamState
      (cast
        (unsafe
          (ptr->int
            (ptr-cast
              (__tl_array-data cell)
              : (Ptr CompilerBackendStreamStateData))))
        : i64))))

(define (compiler-backend-state-stream-state
  [backend-state : CompilerBackendState]) : CompilerBackendStreamState
  (unsafe
    (let
      [data : (MutPtr CompilerBackendStateData)
        (compiler-backend-state-ptr backend-state)]
      [address : i64 (deref data).stream-state-address]
      (if (= address 0)
        (let
          [owner : arena.Arena
            (unsafe
              (arena.Arena (compiler-backend-state-owner-arena backend-state)))]
          [stream-state : CompilerBackendStreamState
            (in-arena owner (compiler-backend-stream-state-new))]
          (set! (deref data).stream-state-address stream-state.address)
          stream-state)
        (CompilerBackendStreamState address)))))

(define (compiler-backend-assembly-stream-home-arena-handle-value
  [stream : CompilerBackendStreamState]) : i64
  (arena.raw-handle
    (unsafe
      (deref (compiler-backend-stream-state-view stream)).assembly-home-arena)))

(define (compiler-backend-state-intern [state : CompilerBackendState]) : ci.InternCompatState
  (unsafe
    (deref (compiler-backend-state-view state)).intern-state))

(define (compiler-backend-state-exact-intern [state : CompilerBackendState]) : ci.InternCompatState
  (compiler-backend-state-intern state))

(define (compiler-backend-state-owner-arena [state : CompilerBackendState]) : i64
  (unsafe
    (deref (compiler-backend-state-view state)).owner-arena))

(define (compiler-backend-state-emission-arena [state : CompilerBackendState]) : i64
  (unsafe
    (deref (compiler-backend-state-view state)).emission-arena))

(define (compiler-backend-state-set-emission-arena!
  [state : CompilerBackendState]
  [owner : arena.Arena]) : unit
  (unsafe
    (set!
      (deref (compiler-backend-state-ptr state)).emission-arena
      (arena.raw-handle owner))))

(define (compiler-backend-state-ensure-emission-arena!
  [state : CompilerBackendState]) : arena.Arena
  (unsafe
    (let
      [data : (MutPtr CompilerBackendStateData)
        (compiler-backend-state-ptr state)]
      [stored : i64 (deref data).emission-arena]
      (if (= stored 0)
        (let
          [current : arena.Arena (arena.current)]
          (set! (deref data).emission-arena (arena.raw-handle current))
          current)
        (arena.Arena stored)))))

(define (compiler-backend-state-clear-emission-arena!
  [state : CompilerBackendState]) : unit
  (unsafe
    (set!
      (deref (compiler-backend-state-ptr state)).emission-symbols
      CompilerBackendEmissionSymbols.None)
    (set! (deref (compiler-backend-state-ptr state)).emission-arena 0)))

(define (compiler-backend-state-current-emission-arena
  [state : CompilerBackendState]) : arena.Arena
  (let
    [stored : i64 (compiler-backend-state-emission-arena state)]
    (if (= stored 0)
      (arena.current)
      (unsafe
        (arena.Arena stored)))))

;; Whether scalar functions get full register allocation. Register allocation
;; makes the EMITTED binary faster but its planning + register-aware emission
;; cost more compile time than it saves on a single self-compile, so it is
;; reserved for full optimization. Lower opt levels stay on
;; cheap stack-only homing. The option is owned by each CompilerBackendState,
;; so a given job emits deterministically even when another job is active.
;; SIMD (Avx2/Avx512) functions always use register allocation regardless.
(define (compiler-backend-state-scalar-registers-enabled?
  [state : CompilerBackendState]) : bool
  (unsafe
    (deref (compiler-backend-state-view state)).scalar-registers-enabled))

(define (compiler-backend-state-set-scalar-registers-enabled!
  [state : CompilerBackendState]
  [enabled : bool]) : unit
  (unsafe
    (set!
      (deref (compiler-backend-state-ptr state)).scalar-registers-enabled
      enabled)))

(define (compiler-backend-state-tail-merging-enabled?
  [state : CompilerBackendState]) : bool
  (unsafe
    (deref (compiler-backend-state-view state)).tail-merging-enabled))

(define (compiler-backend-state-set-tail-merging-enabled!
  [state : CompilerBackendState]
  [enabled : bool]) : unit
  (unsafe
    (set!
      (deref (compiler-backend-state-ptr state)).tail-merging-enabled
      enabled)))

;; The branch-tail scan is reserved for the high-quality path, along with
;; scalar register allocation.
(define (compiler-backend-state-set-opt-level!
  [state : CompilerBackendState]
  [opt-level : i64]) : unit
  (let
    [high-quality? : bool (opt_level.opt-level-full? opt-level)]
    (compiler-backend-state-set-scalar-registers-enabled! state high-quality?)
    (compiler-backend-state-set-tail-merging-enabled! state high-quality?)))

(define (compiler-backend-state-optimize-for-size?
  [state : CompilerBackendState]) : bool
  (unsafe
    (deref (compiler-backend-state-view state)).optimize-for-size))

(define (compiler-backend-state-set-optimize-for-size!
  [state : CompilerBackendState]
  [enabled : bool]) : unit
  (unsafe
    (set! (deref (compiler-backend-state-ptr state)).optimize-for-size enabled)))

;; Public observations for the retained operand-render storage.  The backing
;; StateData remains opaque; capacities are reported from the actual arrays so
;; a fresh state (and a state that was only reset) is observably allocation-free.
(define (compiler-backend-state-lazy-table-arena [state : CompilerBackendState]) : i64
  (unsafe
    (deref (compiler-backend-state-view state)).lazy-table-arena))

(define (compiler-backend-state-slot-cache-capacity
  [state : CompilerBackendState]) : i64
  (array-length
    (unsafe
      (deref (compiler-backend-state-view state)).slot-cache-values)))

(define (compiler-backend-state-frame-offset-cache-capacity
  [state : CompilerBackendState]) : i64
  (array-length
    (unsafe
      (deref (compiler-backend-state-view state)).frame-offset-cache-values)))

(define (compiler-backend-state-immediate-cache-capacity
  [state : CompilerBackendState]) : i64
  (array-length
    (unsafe
      (deref (compiler-backend-state-view state)).immediate-cache-values)))

(define (compiler-backend-state-operand-cache-retained-bytes
  [state : CompilerBackendState]) : i64
  ;; Each fixed-cache entry retains one eight-byte String handle and one i64
  ;; epoch lane: 16 bytes per slot, frame-offset, or immediate entry.
  (*
    (+
      (compiler-backend-state-slot-cache-capacity state)
      (compiler-backend-state-frame-offset-cache-capacity state)
      (compiler-backend-state-immediate-cache-capacity state))
    16))

(define (compiler-backend-state-intern-generation
  [state : CompilerBackendState]) : i64
  (let
    [intern-state : ci.InternCompatState (compiler-backend-state-intern state)]
    (ci.intern-compat-state-generation intern-state)))

(define (compiler-backend-state-intern-table-id [state : CompilerBackendState]) : i64
  (let
    [intern-state : ci.InternCompatState (compiler-backend-state-intern state)]
    (ci.intern-compat-state-table-id intern-state)))

(define (compiler-backend-state-user-symbol-cache-count
  [state : CompilerBackendState]) : i64
  (unsafe
    (deref (compiler-backend-state-view state)).user-symbol-cache-count))

(define (compiler-backend-state-user-symbol-cache-capacity
  [state : CompilerBackendState]) : i64
  (array-length
    (unsafe
      (deref (compiler-backend-state-view state)).user-symbol-cache-keys)))

(define (compiler-backend-state-user-symbol-cache-retained-bytes
  [state : CompilerBackendState]) : i64
  ;; Three i64 lanes plus one String handle per slot.  This observation is
  ;; intentionally explicit rather than exposing the backing arrays.
  (* (compiler-backend-state-user-symbol-cache-capacity state) 32))

(define (compiler-backend-state-absolute-switch-ok?
  [state : CompilerBackendState]) : bool
  (unsafe
    (deref (compiler-backend-state-view state)).absolute-switch-ok))

(define (compiler-backend-state-set-absolute-switch-ok!
  [state : CompilerBackendState]
  [ok : bool]) : unit
  (unsafe
    (set! (deref (compiler-backend-state-ptr state)).absolute-switch-ok ok)))

;; Only a closed executable linked in the low ELF code model can put a
;; private literal's address in a zero-extending imm32.
(define (compiler-backend-state-absolute-literal-ok?
  [state : CompilerBackendState]) : bool
  (and
    (compiler-backend-state-closed-executable? state)
    (compiler-backend-state-absolute-switch-ok? state)))

(define (compiler-backend-state-abort-site-counter
  [state : CompilerBackendState]) : i64
  (unsafe
    (deref (compiler-backend-state-view state)).abort-site-counter))

(define (compiler-backend-state-set-abort-site-counter!
  [state : CompilerBackendState]
  [value : i64]) : unit
  (unsafe
    (set! (deref (compiler-backend-state-ptr state)).abort-site-counter value)))

(define (compiler-backend-state-next-abort-site-counter!
  [state : CompilerBackendState]) : i64
  (let
    [next : i64 (+ (compiler-backend-state-abort-site-counter state) 1)]
    (compiler-backend-state-set-abort-site-counter! state next)
    next))

(define (compiler-backend-symbol-text-state
  [state : CompilerBackendState]
  [id : i64]) : String
  (if (compiler_ir_types.compiler-ir-symbol-owned? id)
    (compiler_ir_types.compiler-ir-symbol-text id)
    (if (compiler-backend-state-intern-id-valid? state id)
      (ci.intern-compat-state-str (compiler-backend-state-intern state) id)
      "")))

;; The program's function and extern lookup tables, built once per program in
;; the arena that is current when the index is built. `self` holds the
;; table's own address, so a borrow of it is one load (see
;; compiler-backend-program-tables). `representations` is read by offset, so it
;; stays ahead of the hashmap fields, whose comptime layout is not reliable in
;; every compilation root.
(defstruct CompilerBackendProgramTables
  ;; The tables' own address, written by the creator through raw memory: the
  ;; slot is storage, not a field any code reads.
  (self u64)
  ;; Shared pre-optimization nominal representation capability. It positively
  ;; distinguishes one-word handles, register groups, and unresolved forms.
  (representations compiler_ir_types.CompilerIrRepresentationIndex)
  (functions backend_i64_i64_map.Map)
  (function-names (__tl_dyn-array String))
  (function-signatures (__tl_dyn-array CompilerBackendMaybeSignature))
  (extern-signatures backend_i64_i64_map.Map)
  (extern-signature-values (__tl_dyn-array CompilerBackendMaybeSignature))
  ;; Extern call classification, packed by extern slot: bit 0 is C ABI,
  ;; bit 1 has aggregate parameters, and the remaining bits encode the
  ;; C-varargs fixed-parameter count plus one. The reference index maps both
  ;; source names and link symbols to this same slot.
  (extern-call-infos (__tl_dyn-array i64))
  (extern-references backend_i64_i64_map.Map)
  (extern-link-references backend_i64_i64_map.Map)
  (extern-link-symbols (__tl_dyn-array i64))
  (extern-provided (__tl_dyn-array bool)))

;; A program index is a Copy handle: the address of its tables plus the
;; capabilities every emission path reads directly.
(defstruct CompilerBackendProgramIndex
  (tables u64)
  ;; Explicit type-reader handle for this backend job. It is snapshotted from
  ;; the job's pools once and then travels with the already-ubiquitous index.
  (type-segment-bases i64)
  ;; Profile hooks share this job-owned handle instead of selecting a global
  ;; timing/summary table.
  (profile-state profile_state.CompilerProfileState)
  ;; Exact backend job owner.  All emission paths use this capability rather
  ;; than consulting the active compatibility intern table.
  (backend-state CompilerBackendState))

(define (compiler-backend-program-tables
  [index : (& index CompilerBackendProgramIndex)]) : (&
    index
    CompilerBackendProgramTables)
  (unsafe
    (ptr-read
      (int->ptr index.tables : (Ptr (& index CompilerBackendProgramTables))))))

;; By-value shallow view for the helpers that take the representations by value.
(define (compiler-backend-program-index-representations
  [index : CompilerBackendProgramIndex]) : compiler_ir_types.CompilerIrRepresentationIndex
  (unsafe
    (ptr-read
      (int->ptr
        (+
          index.tables
          (cast
            (comptime
              (offset-of (type CompilerBackendProgramTables) representations))
            : u64))
        : (Ptr compiler_ir_types.CompilerIrRepresentationIndex)))))

(define (compiler-backend-symbol-text-index
  [index : CompilerBackendProgramIndex]
  [id : i64]) : String
  (compiler-backend-symbol-text-state index.backend-state id))

(defenum CompilerBackendDebugFileIndex
  (No)
  ;; Sparse path-id -> deterministic one-based file number map, plus paths in
  ;; first-seen order.  This avoids allocating intern-capacity entries when a
  ;; program has only a handful of source files.
  (Files backend_i64_i64_map.Map (__tl_dyn-array i64) i64))

(defstruct CompilerBackendSourceSpanIndex
  (entries backend_i64_i64_map.Map)
  (values (__tl_dyn-array compiler_ir_types.CompilerMaybeSourceSpan))
  (debug-files CompilerBackendDebugFileIndex)
  (instructions CompilerBackendInstrSpanIndex)
  (backend-state CompilerBackendState))

(defenum CompilerBackendInstrSpanIndex
  (None)
  (Links backend_i64_i64_map.Map (__tl_dyn-array i64)))

(defstruct CompilerBackendDebugFileBuildState
  (numbers backend_i64_i64_map.Map)
  (paths (__tl_dyn-array i64))
  (count i64)
  (backend-state CompilerBackendState))

(define (compiler-backend-state-intern-id-valid?
  [state : CompilerBackendState]
  [id : i64]) : bool
  (let
    [intern-state : ci.InternCompatState (compiler-backend-state-intern state)]
    (and
      (>= id 0)
      (or
        (< id (ci.intern-compat-state-pool-len intern-state))
        (ci.intern-compat-state-generated-id-active? intern-state id)))))

(define (compiler-backend-debug-file-add!
  [build : CompilerBackendDebugFileBuildState]
  [path-id : i64]) : CompilerBackendDebugFileBuildState
  (let
    [out : CompilerBackendDebugFileBuildState build]
    (if (or
      (<= path-id 0)
      (not (compiler-backend-state-intern-id-valid? out.backend-state path-id)))
      out
      (let
        [numbers : backend_i64_i64_map.Map
          (compiler-backend-global-shared-view out.numbers)]
        (if (backend_i64_i64_map.contains? (& numbers) path-id)
          out
          (begin
            (backend_i64_i64_map.insert-ref!
              (&mut numbers)
              path-id
              (+ out.count 1))
            (set! (array-ref out.paths out.count) path-id)
            (set! out.numbers numbers)
            (+= out.count 1)
            out))))))

(define (compiler-backend-debug-files-from-function-entries
  [entries : compiler_ir_types.CompilerSourceSpansEntryList]
  [index : i64]
  [build : CompilerBackendDebugFileBuildState]) : CompilerBackendDebugFileBuildState
  (if (>= index entries.len)
    build
    (let
      [span-entry : compiler_ir_types.CompilerSourceSpansEntry
        (array-ref entries.slots index)]
      [next : CompilerBackendDebugFileBuildState
        (compiler-backend-debug-file-add! build span-entry.path-id)]
      (compiler-backend-debug-files-from-function-entries
        entries
        (+ index 1)
        next))))

(define (compiler-backend-debug-files-from-instr-entries
  [entries : compiler_ir_types.CompilerSourceSpansInstrEntryList]
  [index : i64]
  [build : CompilerBackendDebugFileBuildState]) : CompilerBackendDebugFileBuildState
  (if (>= index entries.len)
    build
    (let
      [span-entry : compiler_ir_types.CompilerSourceSpansInstrEntry
        (array-ref entries.slots index)]
      [next : CompilerBackendDebugFileBuildState
        (compiler-backend-debug-file-add! build span-entry.path-id)]
      (compiler-backend-debug-files-from-instr-entries entries (+ index 1) next))))

(define (compiler-backend-debug-file-index-build-with-backend-state
  [backend-state : CompilerBackendState]
  [spans : compiler_ir_types.CompilerSourceSpans]) : CompilerBackendDebugFileIndex
  (if (compiler_ir_types.compiler-debug-info-enabled?)
    (match spans
      [(Spans entries instr-entries _ _)
        (let
          [capacity : i64 (+ entries.len instr-entries.len)]
          [build : CompilerBackendDebugFileBuildState
            (in-arena
              (compiler-backend-state-current-emission-arena backend-state)
              (CompilerBackendDebugFileBuildState
                (backend_i64_i64_map.with-capacity 16)
                (__tl_make-array i64 capacity)
                0
                backend-state))]
          [after-functions : CompilerBackendDebugFileBuildState
            (compiler-backend-debug-files-from-function-entries entries 0 build)]
          [after-instrs : CompilerBackendDebugFileBuildState
            (compiler-backend-debug-files-from-instr-entries
              instr-entries
              0
              after-functions)]
          (Files after-instrs.numbers after-instrs.paths after-instrs.count))])
    (No)))

(define (compiler-backend-debug-file-number
  [index : CompilerBackendSourceSpanIndex]
  [path-id : i64]) : i64
  (match index.debug-files
    [(No) 0]
    [(Files numbers _ _)
      (if (or
        (<= path-id 0)
        (not
          (compiler-backend-state-intern-id-valid? index.backend-state path-id)))
        0
        (match (backend_i64_i64_map.get (& numbers) path-id)
          [(LookupFound number) number]
          [(LookupMissing) 0]))]))

(define (compiler-backend-runtime-tail-profile?
  [tail : CompilerBackendRuntimeTailPlan]) : bool
  tail.profile)

(define (compiler-backend-runtime-tail-tlci-macro-entry?
  [tail : CompilerBackendRuntimeTailPlan]) : bool
  tail.tlci-macro-entry)

(define (compiler-backend-runtime-tail-arena-debug?
  [tail : CompilerBackendRuntimeTailPlan]) : bool
  tail.arena-debug)

(define (compiler-backend-runtime-tail-startup-profile?
  [tail : CompilerBackendRuntimeTailPlan]) : bool
  tail.startup-profile)

(define (compiler-backend-runtime-plan-tail [plan : CompilerBackendRuntimePlan]) : CompilerBackendRuntimeTailPlan
  (match plan
    [(Plan _ _ _ _ _ _ _ tail) tail]))

(define (compiler-backend-target-abi [target : CompilerBackendTarget]) : compiler_abi.CompilerRegTargetAbi
  (match target
    [(CompilerBackendTarget.Linux) Linux]
    [(CompilerBackendTarget.Windows) Windows]))

(defenum CompilerBackendMode
  (Scalar)
  (Avx2)
  (Avx512))

(clone_gen.gen-clone CompilerBackendMode)

(define (compiler-backend-mode-scalar? [mode : CompilerBackendMode]) : bool
  (match mode
    [(Scalar) true]
    [_ false]))

(define (compiler-backend-mode-avx2? [mode : CompilerBackendMode]) : bool
  (match mode
    [(Avx2) true]
    [_ false]))

(define (compiler-backend-set-current-mode!
  [function-state : CompilerBackendFunctionState]
  [mode : CompilerBackendMode]) : unit
  (compiler-backend-function-state-set-current-mode! function-state mode))

(define (compiler-backend-current-mode-avx2?
  [function-state : CompilerBackendFunctionState]) : bool
  (compiler-backend-mode-avx2?
    (compiler-backend-function-state-current-mode function-state)))

(define (compiler-backend-set-current-fn-abi!
  [backend-state : CompilerBackendState]
  [abi : compiler_abi.CompilerRegTargetAbi]) : unit
  (compiler-backend-function-state-set-bool!
    (compiler-backend-state-function-state backend-state)
    compiler-backend-function-bool-current-fn-win64
    (compiler_abi.compiler-abi-windows? abi)))

(define (compiler-backend-current-fn-win64?
  [backend-state : CompilerBackendState]) : bool
  (compiler-backend-function-state-bool?
    (compiler-backend-state-function-state backend-state)
    compiler-backend-function-bool-current-fn-win64))

;; Per-emission user-symbol mangling is sparse and owned by CompilerBackendState.
;; The cache's key/value/epoch lanes live in the state owner and retain their
;; capacity, while each epoch's mangled String payload follows the explicit
;; outer emission owner. There are no no-owner cache adapters: every internal
;; route carries its exact backend state.
(define (compiler-backend-state-user-symbol-cache-reset!
  [state : CompilerBackendState]) : unit
  (let
    [data : (MutPtr CompilerBackendStateData)
      (compiler-backend-state-ptr state)]
    (unsafe
      (set!
        (deref data).user-symbol-cache-epoch
        (+ (deref data).user-symbol-cache-epoch 1))
      (set! (deref data).user-symbol-cache-count 0)
      (set!
        (deref data).user-symbol-cache-generation
        (compiler-backend-state-intern-generation state))
      (set!
        (deref data).user-symbol-cache-table-id
        (compiler-backend-state-intern-table-id state)))))

(define (compiler-backend-state-user-symbol-cache-ensure-current!
  [state : CompilerBackendState]) : unit
  (let
    [data : (Ptr CompilerBackendStateData) (compiler-backend-state-view state)]
    (unsafe
      (if (and
        (=
          (deref data).user-symbol-cache-generation
          (compiler-backend-state-intern-generation state))
        (=
          (deref data).user-symbol-cache-table-id
          (compiler-backend-state-intern-table-id state)))
        unit
        (compiler-backend-state-user-symbol-cache-reset! state)))))

(define (compiler-backend-state-user-symbol-cache-hash
  [id : i64]
  [capacity : i64]) : i64
  (let
    [raw : i64 (% (* id 6364136223846793005) capacity)]
    (if (< raw 0)
      (- 0 raw)
      raw)))

(define (compiler-backend-state-user-symbol-cache-allocate!
  [state : CompilerBackendState]
  [capacity : i64]) : unit
  (unsafe
    (let
      [data : (MutPtr CompilerBackendStateData)
        (compiler-backend-state-ptr state)]
      [owner : arena.Arena
        (unsafe
          (arena.Arena (deref data).owner-arena))]
      [keys : (__tl_dyn-array i64)
        (in-arena owner (__tl_make-array i64 capacity))]
      [values : (__tl_dyn-array String)
        (in-arena owner (__tl_make-array String capacity))]
      [epochs : (__tl_dyn-array i64)
        (in-arena owner (__tl_make-array i64 capacity))]
      (for [i (iterator.range 0 capacity)]
        (set! (array-ref keys i) -1)
        (set! (array-ref epochs i) 0))
      (set! (deref data).user-symbol-cache-keys keys)
      (set! (deref data).user-symbol-cache-values values)
      (set! (deref data).user-symbol-cache-epochs epochs))))

(define (compiler-backend-state-user-symbol-cache-rehash!
  [state : CompilerBackendState]
  [new-capacity : i64]) : unit
  (let
    [data : CompilerBackendStateData (compiler-backend-state-data state)]
    [old-keys : (__tl_dyn-array i64) data.user-symbol-cache-keys]
    [old-values : (__tl_dyn-array String) data.user-symbol-cache-values]
    [old-epochs : (__tl_dyn-array i64) data.user-symbol-cache-epochs]
    [old-capacity : i64 (array-length old-keys)]
    [owner : arena.Arena
      (unsafe
        (arena.Arena data.owner-arena))]
    [keys : (__tl_dyn-array i64)
      (in-arena owner (__tl_make-array i64 new-capacity))]
    [values : (__tl_dyn-array String)
      (in-arena owner (__tl_make-array String new-capacity))]
    [epochs : (__tl_dyn-array i64)
      (in-arena owner (__tl_make-array i64 new-capacity))]
    (for [i (iterator.range 0 new-capacity)]
      (set! (array-ref keys i) -1)
      (set! (array-ref epochs i) 0))
    (for [i (iterator.range 0 old-capacity)]
      (let
        [key : i64 (array-ref old-keys i)]
        (if (and
          (>= key 0)
          (= (array-ref old-epochs i) data.user-symbol-cache-epoch))
          (let
            [slot : i64
              (compiler-backend-state-user-symbol-cache-hash key new-capacity)]
            (while (>= (array-ref keys slot) 0)
              (set! slot (% (+ slot 1) new-capacity)))
            (set! (array-ref keys slot) key)
            (set!
              (array-ref values slot)
              (owned_view.compiler-owned-element-view old-values i))
            (set! (array-ref epochs slot) data.user-symbol-cache-epoch))
          unit)))
    (set! data.user-symbol-cache-keys keys)
    (set! data.user-symbol-cache-values values)
    (set! data.user-symbol-cache-epochs epochs)
    (compiler-backend-state-data-set! state data)))

(define (compiler-backend-state-user-symbol-id
  [state : CompilerBackendState]
  [name-id : i64]) : String
  (compiler-backend-state-user-symbol-cache-ensure-current! state)
  (if (not
    (or
      (compiler_ir_types.compiler-ir-symbol-owned? name-id)
      (compiler-backend-state-intern-id-valid? state name-id)))
    ""
    (let
      [data : CompilerBackendStateData (compiler-backend-state-data state)]
      [capacity : i64 (array-length data.user-symbol-cache-keys)]
      (if (= capacity 0)
        (begin
          (compiler-backend-state-user-symbol-cache-allocate! state 16)
          (compiler-backend-state-user-symbol-id state name-id))
        (let
          [keys : (__tl_dyn-array i64) data.user-symbol-cache-keys]
          [values : (__tl_dyn-array String) data.user-symbol-cache-values]
          [epochs : (__tl_dyn-array i64) data.user-symbol-cache-epochs]
          [epoch : i64 data.user-symbol-cache-epoch]
          [slot : i64
            (compiler-backend-state-user-symbol-cache-hash name-id capacity)]
          [steps : i64 0]
          [found : bool false]
          [insert-slot : i64 -1]
          (while (and (not found) (< steps capacity))
            (let
              [key : i64 (array-ref keys slot)]
              (if (or (< key 0) (not (= (array-ref epochs slot) epoch)))
                (begin
                  (set! insert-slot slot)
                  (set! found true))
                (if (= key name-id)
                  (begin
                    (set! insert-slot slot)
                    (set! found true))
                  (begin
                    (set! slot (% (+ slot 1) capacity))
                    (+= steps 1))))))
          (if (and
            (= insert-slot slot)
            (>= (array-ref keys insert-slot) 0)
            (= (array-ref epochs insert-slot) epoch)
            (= (array-ref keys insert-slot) name-id))
            (owned_view.compiler-owned-element-view values insert-slot)
            (if (> (* (+ data.user-symbol-cache-count 1) 4) (* capacity 3))
              (begin
                (compiler-backend-state-user-symbol-cache-rehash!
                  state
                  (* capacity 2))
                (compiler-backend-state-user-symbol-id state name-id))
              (let
                [mangled : String
                  (in-arena
                    (compiler-backend-state-current-emission-arena state)
                    (compiler-backend-user-symbol-uncached
                      (compiler-backend-symbol-text-state state name-id)))]
                (set! (array-ref keys insert-slot) name-id)
                (set!
                  (array-ref values insert-slot)
                  (compiler-backend-global-shared-view mangled))
                (set! (array-ref epochs insert-slot) epoch)
                (+= data.user-symbol-cache-count 1)
                (compiler-backend-state-data-set!
                  state
                  (compiler-backend-global-shared-view data))
                mangled))))))))

;; Compatibility adapter: capture the active exact intern view for this
;; synchronous operation.  Explicit backend paths call the state-taking twin.
(define (compiler-backend-user-symbol-id [name-id : i64]) : String
  (compiler-backend-state-user-symbol-id
    (compiler-backend-state-new (ci.intern-compat-state-capture-active))
    name-id))

;; Compare->branch fusion state. A comparison result may be fused to `cmp`/`jcc`
;; (never materialized as a boolean) when EVERY use of it is a branch fed by its
;; own adjacent compare. Equivalently: its total use count equals its count of
;; such "free branch" uses. This is strictly more permissive than a global
;; single-use gate: opt2 loop rotation duplicates a guard into an entry check
;; and a latch check that share one var id (two defs, two adjacent-branch uses),
;; which a single-use gate would reject even though each pair is locally fusable.
;;
;; To stay nearly free at compile time, this reuses the use-count array the
;; backend already computes (held by reference, not copied) and only adds a
;; cheap per-instruction scan that tallies free-branch uses.
;; Stable state shared by one block's instruction-emission family. Keep
;; per-call control state (`fallthrough`, remaining instructions, RAX mode,
;; and the output buffer) explicit: those values change as fusion consumes the
;; stream. This context is the family-sized handoff that can become a field of
;; the per-job backend state tracked by #4963.
(defstruct CompilerBackendEmissionContext
  (type-segment-bases i64)
  (target-policy CompilerBackendTargetPolicy)
  (function String)
  (source-function i64)
  (blocks compiler_ir_types.CompilerIrBlockList)
  (current-label i64)
  (assignments compiler_regalloc.CompilerRegAssignmentTable)
  (vars i64)
  (types compiler_regalloc.CompilerRegVarTypes)
  (global-types CompilerBackendGlobalTypeTable)
  (ret-ty compiler_ast_types.AstType)
  (plan CompilerBackendRuntimePlan)
  (functions compiler_ir_types.CompilerIrFunctionSeq)
  (externs compiler_ir_types.CompilerIrExternSeq)
  (program-index CompilerBackendProgramIndex)
  (spans compiler_ir_types.CompilerSourceSpans)
  (span-index CompilerBackendSourceSpanIndex)
  (func-diag compiler_diagnostic.CompilerDiagnostic)
  (use-counts (__tl_dyn-array i64))
  (backend-state CompilerBackendState)
  (function-state CompilerBackendFunctionState))

(defenum CompilerBackendEmitInstrsMode
  (Normal)
  (Rax i64 compiler_ast_types.AstType)
  (CallRax i64 compiler_ast_types.AstType))

(define (compiler-backend-empty-instr-seq) : compiler_ir_types.CompilerIrInstrSeq
  (compiler_ir_types.CompilerIrInstrSeq
    (__tl_make-array compiler_ir_types.CompilerIrInstr 0)
    0))

;; The emit spine walks a block's contiguous CompilerIrInstrSeq with a
;; `(instrs, index)` cursor: `index` is the position of the first instruction
;; not yet emitted, so the remaining instructions are the rows from `index` on
;; and their count is `len - index`. The trampoline carries both halves; the
;; sequence half is invariant for the lifetime of one emit-instrs-loop (every
;; continue target is a suffix of the block the loop was entered with), and is
;; carried anyway so the continuation stays a literal cursor rather than an
;; invariant the reader has to reconstruct.
;; The trampoline carries no buffer across a continue step: the whole block
;; spine appends into ONE body buffer that the loop already holds, so the only
;; loop-carried emission state is the mode and the cursor.
(define (compiler-backend-emit-instrs-set-continue!
  [function-state : CompilerBackendFunctionState]
  [mode : CompilerBackendEmitInstrsMode]
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [index : i64]) : ResultCompilerBackend
  (compiler-backend-function-state-set-bool!
    function-state
    compiler-backend-function-bool-emit-instrs-continue-pending
    true)
  (compiler-backend-function-state-set-next-mode! function-state mode)
  (compiler-backend-function-state-set-next-instrs! function-state instrs)
  (compiler-backend-function-state-set-i64!
    function-state
    compiler-backend-function-i64-emit-instrs-next-index
    index)
  (Ok ""))

(defenum ResultBackendRuntimePlan
  (Ok CompilerBackendRuntimePlan)
  (Err String))

(defenum ResultBackendRuntimePlanWithIndex
  (Ok CompilerBackendRuntimePlanWithIndex)
  (Err String))

(defstruct BackendStringSeq
  (slots (__tl_dyn-array String))
  (len i64))

(defstruct BackendSymbolSeq
  (slots (__tl_dyn-array i64))
  (len i64))

;; Register scavenging, emergency/cycle temporaries, per-instruction
;; reservations, and const-hoist planning form one coupled per-function state.
;; Keep the fields in a nominal substate, grouped by representation like the
;; outer function owner so hot scalar updates touch one compact array element.
;; Every reference lane starts empty and is sized from the function plan when
;; first populated; no process-global scratch context or fixed site cap remains.
(defstruct CompilerBackendScratchState
  (i64s (__tl_dyn-array i64))
  (bools (__tl_dyn-array bool))
  (i64-arrays (__tl_dyn-array (__tl_dyn-array i64)))
  (bool-arrays (__tl_dyn-array (__tl_dyn-array bool)))
  (string-arrays (__tl_dyn-array (__tl_dyn-array String)))
  (assignment-indexes
    (__tl_dyn-array compiler_regalloc.CompilerRegAssignmentTable))
  (empty-i64-array (__tl_dyn-array i64))
  (empty-bool-array (__tl_dyn-array bool))
  (empty-string-array (__tl_dyn-array String))
  (empty-assignment-index compiler_regalloc.CompilerRegAssignmentTable))

(define compiler-backend-scratch-i64-emergency-reg : i64
  0)
(define compiler-backend-scratch-i64-emergency-slot-offset : i64
  1)
(define compiler-backend-scratch-i64-emergency-pending-count : i64
  2)
(define compiler-backend-scratch-i64-emergency-used-count : i64
  3)
(define compiler-backend-scratch-i64-cycle-temp-used-count : i64
  4)
(define compiler-backend-scratch-i64-cycle-temp-base-offset : i64
  5)
(define compiler-backend-scratch-i64-const-hoist-site-count : i64
  6)
(define compiler-backend-scratch-i64-const-hoist-inject-count : i64
  7)
(define compiler-backend-scratch-i64-const-hoist-frame-count : i64
  8)
(define compiler-backend-scratch-i64-scavenge-plan-reg-mask : i64
  9)
(define compiler-backend-scratch-i64-scavenge-vars : i64
  10)
(define compiler-backend-scratch-i64-current-instr-reserved-mask : i64
  11)
(define compiler-backend-scratch-i64-current-source-function : i64
  12)

;; Object emission: the label id of the block emitted next (-1 after a
;; function's last block), and the var and x86 condition code of a compare
;; whose flags are still live (-1 when the previous instruction was not one).
(define compiler-backend-scratch-i64-object-next-label : i64
  13)
(define compiler-backend-scratch-i64-object-flags-var : i64
  14)
(define compiler-backend-scratch-i64-object-flags-cc : i64
  15)

;; The SIMD staging region (#7497): its size, planned before the body from
;; the census of stack-backed SIMD routes; the frame offset of its lowest
;; byte; and the largest request an emitted route made, which must equal the
;; planned size once the body is done.
(define compiler-backend-scratch-i64-simd-scratch-bytes : i64
  16)
(define compiler-backend-scratch-i64-simd-scratch-base-offset : i64
  17)
(define compiler-backend-scratch-i64-simd-scratch-used-bytes : i64
  18)

;; Cross-edge flags carry: the compare a block's tail branch fell through with,
;; still live at the next block's entry. `to` is that successor's label (-1 when
;; there is none) and the other three lanes are the compare's two var operands
;; and the width of its `cmp` operands.
(define compiler-backend-scratch-i64-edge-flags-to : i64
  19)
(define compiler-backend-scratch-i64-edge-flags-lhs : i64
  20)
(define compiler-backend-scratch-i64-edge-flags-rhs : i64
  21)
(define compiler-backend-scratch-i64-edge-flags-width : i64
  22)
(define compiler-backend-scratch-i64-loop-block-count : i64
  23)
(define compiler-backend-scratch-i64-count : i64
  24)
(define compiler-backend-scratch-bool-emergency-pending : i64
  0)
(define compiler-backend-scratch-bool-emergency-used : i64
  1)
(define compiler-backend-scratch-bool-emergency-restore-suppressed : i64
  2)
(define compiler-backend-scratch-bool-divmod-src-emergency-avoid-r10 : i64
  3)
(define compiler-backend-scratch-bool-const-hoist-frame-rbx : i64
  4)

;; R4-B: is the instruction currently being emitted one whose spilled def may
;; stage through a register found free only over the NARROW window? See
;; compiler-backend-instr-staging-narrow-ok?.
(define compiler-backend-scratch-bool-instr-staging-narrow-ok : i64
  5)

;; R4-C: set while one of the load-fusion families that emits SIBLING loads
;; out of def-point order is running (emit-load-from-gep-pair and friends,
;; emit-load-load, emit-gep-load-pair-alu). Only there can a register-homed
;; sibling be written into its home ahead of its interval point, which is the
;; hazard the 16-point staging window guards against; every other staging
;; pick may fall back to the [point, point+2] window before the emergency
;; tier borrows an occupied register (see compiler-backend-scavenge-reg).
(define compiler-backend-scratch-bool-pair-emission : i64
  6)
(define compiler-backend-scratch-bool-count : i64
  7)
(define compiler-backend-scratch-i64-array-emergency-regs : i64
  0)
(define compiler-backend-scratch-i64-array-const-hoist-site-points : i64
  1)
(define compiler-backend-scratch-i64-array-const-hoist-site-regs : i64
  2)
(define compiler-backend-scratch-i64-array-const-hoist-site-values : i64
  3)
(define compiler-backend-scratch-i64-array-const-hoist-inject-labels : i64
  4)
(define compiler-backend-scratch-i64-array-scavenge-starts : i64
  5)
(define compiler-backend-scratch-i64-array-scavenge-ends : i64
  6)
(define compiler-backend-scratch-i64-array-scavenge-occupied-masks : i64
  7)

;; T1-6 (b): where each pending emergency-scavenge save is PARKED, one entry per
;; `-array-emergency-regs` entry. `>= 0` = an XMM register id (a frame-free
;; save); `< 0` = `-(slot-index + 1)`, the classic 64-byte frame slot.
(define compiler-backend-scratch-i64-array-emergency-save-locs : i64
  8)
(define compiler-backend-scratch-i64-array-loop-block-labels : i64
  9)
(define compiler-backend-scratch-i64-array-count : i64
  10)
(define compiler-backend-scratch-bool-array-const-hoist-site-wide : i64
  0)
(define compiler-backend-scratch-bool-array-const-hoist-site-frame : i64
  1)
(define compiler-backend-scratch-bool-array-const-hoist-inject-pres : i64
  2)
(define compiler-backend-scratch-bool-array-count : i64
  3)
(define compiler-backend-scratch-string-array-const-hoist-site-frame-operands : i64
  0)
(define compiler-backend-scratch-string-array-const-hoist-inject-texts : i64
  1)
(define compiler-backend-scratch-string-array-count : i64
  2)

;; Mutable per-function values are grouped by representation.  Each hot update
;; touches one array element instead of copying a wide aggregate through the
;; opaque handle.  Empty reference-bearing sentinels live in the backend job's
;; owner arena and are restored before a function scratch arena is rewound.
(defstruct CompilerBackendFunctionStateData
  (i64s (__tl_dyn-array i64))
  (bools (__tl_dyn-array bool))
  (modes (__tl_dyn-array CompilerBackendMode))
  (strings (__tl_dyn-array String))
  (i64-arrays (__tl_dyn-array (__tl_dyn-array i64)))
  (live-sets (__tl_dyn-array compiler_liveness.CompilerLiveI64Set))
  (emit-modes (__tl_dyn-array CompilerBackendEmitInstrsMode))
  (instr-seqs (__tl_dyn-array compiler_ir_types.CompilerIrInstrSeq))
  (phi-targets (__tl_dyn-array BackendSymbolSeq))
  (abort-targets (__tl_dyn-array CompilerBackendTarget))
  (assignment-indexes
    (__tl_dyn-array compiler_regalloc.CompilerRegAssignmentTable))
  (scratch CompilerBackendScratchState)
  (empty-i64-array (__tl_dyn-array i64))
  (empty-live-set compiler_liveness.CompilerLiveI64Set)
  (empty-instr-seq compiler_ir_types.CompilerIrInstrSeq)
  (empty-symbol-seq BackendSymbolSeq)
  (empty-assignment-index compiler_regalloc.CompilerRegAssignmentTable))

(define compiler-backend-function-i64-current-slot-vars : i64
  0)
(define compiler-backend-function-i64-current-block-label : i64
  1)
(define compiler-backend-function-i64-current-phi-target-count : i64
  2)
(define compiler-backend-function-i64-abort-site-line : i64
  3)
(define compiler-backend-function-i64-abort-site-column : i64
  4)
(define compiler-backend-function-i64-emit-instr-post-base : i64
  5)
(define compiler-backend-function-i64-emit-current-count : i64
  6)
(define compiler-backend-function-i64-emit-current-site : i64
  7)
(define compiler-backend-function-i64-emit-instrs-next-index : i64
  8)
(define compiler-backend-function-i64-rax-override-var : i64
  9)
(define compiler-backend-function-i64-rax-forward-pending-var : i64
  10)
(define compiler-backend-function-i64-home-override0-var : i64
  11)
(define compiler-backend-function-i64-home-override0-reg : i64
  12)
(define compiler-backend-function-i64-home-override1-var : i64
  13)
(define compiler-backend-function-i64-home-override1-reg : i64
  14)
(define compiler-backend-function-i64-use-home-mask-value : i64
  15)
(define compiler-backend-function-i64-emit-plan-reg-mask : i64
  16)
(define compiler-backend-function-i64-current-phi-target-point : i64
  17)
(define compiler-backend-function-i64-current-phi-dst-home-mask : i64
  18)
(define compiler-backend-function-i64-gep-fold-cursor : i64
  19)

;; SysV red zone (see compiler-backend-red-zone-decide!): the number of bytes
;; immediately below the post-prologue %rsp that the body's own tracked stack
;; motion (abort-site argument pushes, c-ABI dip windows, phi cycle-break
;; pushes) may occupy. The local slot region is anchored BELOW this guard, so
;; a transient push can never land on a live red-zone slot. 0 when the body
;; never moves %rsp.
(define compiler-backend-function-i64-red-zone-guard : i64
  20)

;; SW-1: the label of the block this function's prologue is spliced at when the
;; general shrink-wrap placement is applied, or the no-label sentinel. Read by
;; the jump-forward builder, which must never forward a jump past the saving
;; block: doing so would step over the spliced prologue.
(define compiler-backend-function-i64-swb-saving-label : i64
  21)

;; The bound of the shift count of the IR instruction being emitted, plus one:
;; 0 when that instruction is not a shift or its count is not bounded (see
;; compiler-backend-shift-count-bounds). Read by compiler-backend-shift-guard-asm.
(define compiler-backend-function-i64-shift-count-bound : i64
  22)

;; Whether a frame address of the function being emitted may escape
;; (compiler-ir-blocks-frame-may-escape? of its blocks): 0 not yet computed,
;; 1 no, 2 yes. Cleared when emit-blocks starts a function; see
;; compiler-backend-blocks-expose-frame-at?.
(define compiler-backend-function-i64-frame-may-escape : i64
  23)

;; Words the dense group-pair region reserves below the callee-save area: two
;; per group var when the function exposes a group address (both words live in
;; the canonical pair region), one per group var otherwise (only word1 leaves
;; the var region). Zero when the function has no group var.
(define compiler-backend-function-i64-group-pair-reserve : i64
  24)
(define compiler-backend-function-i64-count : i64
  25)
(define compiler-backend-function-bool-current-fn-win64 : i64
  0)
(define compiler-backend-function-bool-addr-of-forwarding-enabled : i64
  1)
(define compiler-backend-function-bool-group-vars-enabled : i64
  2)
(define compiler-backend-function-bool-fuse-need-ready : i64
  3)
(define compiler-backend-function-bool-emit-instrs-loop-active : i64
  4)
(define compiler-backend-function-bool-emit-instrs-continue-pending : i64
  5)
(define compiler-backend-function-bool-identity-tail-forwarder-active : i64
  6)
(define compiler-backend-function-bool-abort-site-active : i64
  7)
(define compiler-backend-function-bool-emit-assignment-index-active : i64
  8)
(define compiler-backend-function-bool-frame-slot-referenced : i64
  9)
(define compiler-backend-function-bool-fpo-bare-frame : i64
  10)
(define compiler-backend-function-bool-use-home-mask-active : i64
  11)
(define compiler-backend-function-bool-emit-plan-reg-mask-active : i64
  12)
(define compiler-backend-function-bool-gep-fold-ready : i64
  13)
(define compiler-backend-function-bool-gep-fold-drift : i64
  14)

;; A frame reference the FPO push prologue does NOT absorb. The callee-save
;; slot region is spelled through compiler-backend-callee-save-slot, and in FPO
;; push mode every line that names it is deleted (the mov save/restore pairs) or
;; rewritten (the pop-run leaq) by the rsp-rebase pass, so a function whose only
;; frame references are those slots ends up with no frame reference at all.
;; This flag is the one the slot region's liveness is decided by; bit 9 stays
;; the "any frame reference at all" fact its own readers were written for.
(define compiler-backend-function-bool-nonsave-frame-slot-referenced : i64
  15)

;; True when the function's FINAL emitted text contains a call that RETURNS to
;; it. Only such a call imposes the x86-64 `%rsp % 16 == 0 at the call` duty on
;; this frame, so only such a call can justify the prologue's 8-byte alignment
;; pad. Three shapes are deliberately NOT returning calls:
;;   * a tail `jmp` -- the epilogue has already restored the entry %rsp, so the
;;     tail target re-enters with the caller's own alignment, unchanged;
;;   * `call tl_oob_abort` / `tl_oob_abort_at` / `tl_div_abort*` /
;;     `tl_shift_abort*` / `tl_panic_at` / `tl_oom_abort` / `tl_region_abort` --
;;     compiler-emitted `never` runtime handlers that print through raw
;;     syscalls and exit. TypeLisp codegen never spills through a 16-byte-
;;     aligned SSE move (every vector store it emits is `vmovdqu*`/`vmovup*`)
;;     and the runtime links no libc, so the abort chain has no alignment duty
;;     to inherit;
;;   * a bare `syscall` -- the kernel imposes no stack alignment.
;; Any other `call`/`callq`, direct or indirect, including every C-ABI call,
;; keeps the pad. The fact is derived from the emitted text rather than from the
;; IR so that runtime helper calls planted by non-Call instructions (allocation,
;; string concat, memory helpers, thread init, `__chkstk`) cannot be missed.
(define compiler-backend-function-bool-call-align-needed : i64
  16)

;; True when this function's frame lives in the System V red zone: the 128
;; bytes below %rsp that the ABI guarantees no signal handler or interrupt
;; frame may clobber. Set by compiler-backend-red-zone-decide! (Linux FPO
;; functions with no RETURNING call and frame + guard <= 128); when set the
;; prologue emits no `subq $N, %rsp`, the epilogue no matching `addq`, and
;; every local slot is addressed at a NEGATIVE displacement from %rsp.
(define compiler-backend-function-bool-red-zone : i64
  17)

;; True when this function's IR contains a RETURNING call (a call plus a
;; syscall; the tail-call and abort families do not return here). Set once from
;; the emitted block list before `compiler-backend-emit-blocks` runs, and read
;; only by `compiler-backend-copy-thunk-applies?`: a copy may become a `call`
;; to a shared thunk only where a returning call already exists. That is
;; exactly the condition `compiler-backend-blocks-have-returning-call?` gives
;; `fpo-bare-frame` and the final-text call census (`call-align-needed`), so a
;; thunk call site can neither lose a red-zone frame (a red-zone frame is only
;; chosen without a returning call) nor sit in a bare frameless leaf (a bare
;; frame needs no returning call either, and frame > 0 pays the alignment pad).
(define compiler-backend-function-bool-has-returning-call : i64
  18)
(define compiler-backend-function-bool-count : i64
  19)
(define compiler-backend-function-string-shrinkwrap-bare-label : i64
  0)
(define compiler-backend-function-string-abort-site-path : i64
  1)
(define compiler-backend-function-string-count : i64
  2)
(define compiler-backend-function-i64-array-addr-of-forwarding-src : i64
  0)
(define compiler-backend-function-i64-array-fuse-use-counts : i64
  1)
(define compiler-backend-function-i64-array-fuse-free-counts : i64
  2)
(define compiler-backend-function-i64-array-gep-fold-disp-table : i64
  3)
(define compiler-backend-function-i64-array-gep-fold-kind-table : i64
  4)
(define compiler-backend-function-i64-array-gep-fold-scale-table : i64
  5)

;; #jump-forward: flat (from-label, to-label) pairs for this function's
;; jump-only blocks. Empty for every function that has none.
(define compiler-backend-function-i64-array-jump-forward : i64
  6)

;; SW-1: label ids of the blocks that return BEFORE the general shrink-wrap
;; placement's prologue. Their `Return` emits a bare `ret` -- no callee-saved
;; pops, no `add rsp` -- and they are excluded from the shared-epilogue census
;; for the same reason form (a)'s bare exits are. Empty for every function whose
;; prologue stays at entry.
(define compiler-backend-function-i64-array-swb-bare-labels : i64
  7)

;; Per var: the bound compiler-backend-shift-count-bounds proved, plus one.
(define compiler-backend-function-i64-array-shift-count-bounds : i64
  8)

;; The per-function edge index over the dense block sequence emit-blocks
;; walks (compiler-backend-edge-index-ensure!): label -> block index, each
;; block's scavenge entry point, and the shared-return count from each block to
;; the end. Cleared at every emit-blocks entry; built on the first edge lookup.
(define compiler-backend-function-i64-array-edge-index : i64
  9)

;; Per var: its dense group-pair index (compiler-backend-group-rank), -1 for an
;; id that carries no group pair. Filled once at group-vars install, so a
;; group-slot lookup is one array read.
(define compiler-backend-function-i64-array-group-ranks : i64
  10)
(define compiler-backend-function-i64-array-count : i64
  11)
(define compiler-backend-function-live-set-group-vars : i64
  0)
(define compiler-backend-function-live-set-addressable-group-vars : i64
  1)
(define compiler-backend-function-live-set-count : i64
  2)

(define (compiler-backend-function-state-data
  [state : CompilerBackendFunctionState]) : CompilerBackendFunctionStateData
  (unsafe
    (ptr-read
      (int->ptr
        (cast state.address : u64)
        : (Ptr CompilerBackendFunctionStateData)))))

;; Representation-lane reads intentionally address the field in place.  A
;; generic field projection from `(ptr-read StateData)` materialises the entire wide state
;; before selecting one array, which turns every hot i64/bool lookup into a
;; large memcpy.  The returned array handles still point at owner storage; only
;; their compact descriptor is copied.
(define (compiler-backend-function-state-i64s
  [state : CompilerBackendFunctionState]) : (__tl_dyn-array i64)
  (unsafe
    (ptr-read
      (int->ptr
        (cast
          (+
            state.address
            (comptime (offset-of (type CompilerBackendFunctionStateData) i64s)))
          : u64)
        : (Ptr (__tl_dyn-array i64))))))

(define (compiler-backend-function-state-bools
  [state : CompilerBackendFunctionState]) : (__tl_dyn-array bool)
  (unsafe
    (ptr-read
      (int->ptr
        (cast
          (+
            state.address
            (comptime (offset-of (type CompilerBackendFunctionStateData) bools)))
          : u64)
        : (Ptr (__tl_dyn-array bool))))))

(define (compiler-backend-function-state-modes
  [state : CompilerBackendFunctionState]) : (__tl_dyn-array CompilerBackendMode)
  (unsafe
    (ptr-read
      (int->ptr
        (cast
          (+
            state.address
            (comptime (offset-of (type CompilerBackendFunctionStateData) modes)))
          : u64)
        : (Ptr (__tl_dyn-array CompilerBackendMode))))))

(define (compiler-backend-function-state-strings
  [state : CompilerBackendFunctionState]) : (__tl_dyn-array String)
  (unsafe
    (ptr-read
      (int->ptr
        (cast
          (+
            state.address
            (comptime
              (offset-of (type CompilerBackendFunctionStateData) strings)))
          : u64)
        : (Ptr (__tl_dyn-array String))))))

(define (compiler-backend-function-state-i64-arrays
  [state : CompilerBackendFunctionState]) : (__tl_dyn-array
    (__tl_dyn-array i64))
  (unsafe
    (ptr-read
      (int->ptr
        (cast
          (+
            state.address
            (comptime
              (offset-of (type CompilerBackendFunctionStateData) i64-arrays)))
          : u64)
        : (Ptr (__tl_dyn-array (__tl_dyn-array i64)))))))

(define (compiler-backend-function-state-assignment-indexes
  [state : CompilerBackendFunctionState]) : (__tl_dyn-array
    compiler_regalloc.CompilerRegAssignmentTable)
  (unsafe
    (ptr-read
      (int->ptr
        (cast
          (+
            state.address
            (comptime
              (offset-of
                (type CompilerBackendFunctionStateData)
                assignment-indexes)))
          : u64)
        : (Ptr (__tl_dyn-array compiler_regalloc.CompilerRegAssignmentTable))))))

(define (compiler-backend-function-scratch-state
  [state : CompilerBackendFunctionState]) : CompilerBackendScratchState
  (unsafe
    (ptr-read
      (int->ptr
        (cast
          (+
            state.address
            (comptime
              (offset-of (type CompilerBackendFunctionStateData) scratch)))
          : u64)
        : (Ptr CompilerBackendScratchState)))))

;; Hot scratch-lane reads address the nested field directly, avoiding a copy of
;; either the wide outer owner or the nominal scratch substate.
(define (compiler-backend-function-scratch-i64s
  [state : CompilerBackendFunctionState]) : (__tl_dyn-array i64)
  (unsafe
    (ptr-read
      (int->ptr
        (cast
          (+
            state.address
            (comptime
              (offset-of (type CompilerBackendFunctionStateData) scratch))
            (comptime (offset-of (type CompilerBackendScratchState) i64s)))
          : u64)
        : (Ptr (__tl_dyn-array i64))))))

(define (compiler-backend-function-scratch-bools
  [state : CompilerBackendFunctionState]) : (__tl_dyn-array bool)
  (unsafe
    (ptr-read
      (int->ptr
        (cast
          (+
            state.address
            (comptime
              (offset-of (type CompilerBackendFunctionStateData) scratch))
            (comptime (offset-of (type CompilerBackendScratchState) bools)))
          : u64)
        : (Ptr (__tl_dyn-array bool))))))

(define (compiler-backend-function-scratch-i64-arrays
  [state : CompilerBackendFunctionState]) : (__tl_dyn-array
    (__tl_dyn-array i64))
  (unsafe
    (ptr-read
      (int->ptr
        (cast
          (+
            state.address
            (comptime
              (offset-of (type CompilerBackendFunctionStateData) scratch))
            (comptime (offset-of (type CompilerBackendScratchState) i64-arrays)))
          : u64)
        : (Ptr (__tl_dyn-array (__tl_dyn-array i64)))))))

(define (compiler-backend-function-scratch-bool-arrays
  [state : CompilerBackendFunctionState]) : (__tl_dyn-array
    (__tl_dyn-array bool))
  (unsafe
    (ptr-read
      (int->ptr
        (cast
          (+
            state.address
            (comptime
              (offset-of (type CompilerBackendFunctionStateData) scratch))
            (comptime
              (offset-of (type CompilerBackendScratchState) bool-arrays)))
          : u64)
        : (Ptr (__tl_dyn-array (__tl_dyn-array bool)))))))

(define (compiler-backend-function-scratch-string-arrays
  [state : CompilerBackendFunctionState]) : (__tl_dyn-array
    (__tl_dyn-array String))
  (unsafe
    (ptr-read
      (int->ptr
        (cast
          (+
            state.address
            (comptime
              (offset-of (type CompilerBackendFunctionStateData) scratch))
            (comptime
              (offset-of (type CompilerBackendScratchState) string-arrays)))
          : u64)
        : (Ptr (__tl_dyn-array (__tl_dyn-array String)))))))

(define (compiler-backend-function-scratch-assignment-indexes
  [state : CompilerBackendFunctionState]) : (__tl_dyn-array
    compiler_regalloc.CompilerRegAssignmentTable)
  (unsafe
    (ptr-read
      (int->ptr
        (cast
          (+
            state.address
            (comptime
              (offset-of (type CompilerBackendFunctionStateData) scratch))
            (comptime
              (offset-of (type CompilerBackendScratchState) assignment-indexes)))
          : u64)
        : (Ptr (__tl_dyn-array compiler_regalloc.CompilerRegAssignmentTable))))))

(define (compiler-backend-function-scratch-i64
  [state : CompilerBackendFunctionState]
  [index : i64]) : i64
  (array-ref (compiler-backend-function-scratch-i64s state) index))

(define (compiler-backend-function-scratch-set-i64!
  [state : CompilerBackendFunctionState]
  [index : i64]
  [value : i64]) : unit
  (set! (array-ref (compiler-backend-function-scratch-i64s state) index) value))

(define (compiler-backend-function-scratch-bool?
  [state : CompilerBackendFunctionState]
  [index : i64]) : bool
  (array-ref (compiler-backend-function-scratch-bools state) index))

(define (compiler-backend-function-scratch-set-bool!
  [state : CompilerBackendFunctionState]
  [index : i64]
  [value : bool]) : unit
  (set! (array-ref (compiler-backend-function-scratch-bools state) index) value))

(define (compiler-backend-function-scratch-i64-array
  [state : CompilerBackendFunctionState]
  [index : i64]) : (__tl_dyn-array i64)
  (owned_view.compiler-owned-element-view
    (compiler-backend-function-scratch-i64-arrays state)
    index))

(define (compiler-backend-function-scratch-set-i64-array!
  [state : CompilerBackendFunctionState]
  [index : i64]
  [value : (__tl_dyn-array i64)]) : unit
  (set!
    (array-ref (compiler-backend-function-scratch-i64-arrays state) index)
    value))

(define (compiler-backend-function-loop-block?
  [state : CompilerBackendFunctionState]
  [label : i64]) : bool
  (let
    [count : i64
      (compiler-backend-function-scratch-i64
        state
        compiler-backend-scratch-i64-loop-block-count)]
    (if (= count 0)
      false
      (let
        [labels : (__tl_dyn-array i64)
          (compiler-backend-function-scratch-i64-array
            state
            compiler-backend-scratch-i64-array-loop-block-labels)]
        (for [i (iterator.range 0 count)]
          (when (= (array-ref labels i) label) (return true)))
        false))))

(define (compiler-backend-function-scratch-bool-array
  [state : CompilerBackendFunctionState]
  [index : i64]) : (__tl_dyn-array bool)
  (owned_view.compiler-owned-element-view
    (compiler-backend-function-scratch-bool-arrays state)
    index))

(define (compiler-backend-function-scratch-set-bool-array!
  [state : CompilerBackendFunctionState]
  [index : i64]
  [value : (__tl_dyn-array bool)]) : unit
  (set!
    (array-ref (compiler-backend-function-scratch-bool-arrays state) index)
    value))

(define (compiler-backend-function-scratch-string-array
  [state : CompilerBackendFunctionState]
  [index : i64]) : (__tl_dyn-array String)
  (owned_view.compiler-owned-element-view
    (compiler-backend-function-scratch-string-arrays state)
    index))

(define (compiler-backend-function-scratch-set-string-array!
  [state : CompilerBackendFunctionState]
  [index : i64]
  [value : (__tl_dyn-array String)]) : unit
  (set!
    (array-ref (compiler-backend-function-scratch-string-arrays state) index)
    value))

(define (compiler-backend-function-scratch-assignment-index
  [state : CompilerBackendFunctionState]) : compiler_regalloc.CompilerRegAssignmentTable
  (array-ref (compiler-backend-function-scratch-assignment-indexes state) 0))

(define (compiler-backend-function-scratch-set-assignment-index!
  [state : CompilerBackendFunctionState]
  [value : compiler_regalloc.CompilerRegAssignmentTable]) : unit
  (set!
    (array-ref (compiler-backend-function-scratch-assignment-indexes state) 0)
    value))

(define (compiler-backend-function-state-live-sets
  [state : CompilerBackendFunctionState]) : (__tl_dyn-array
    compiler_liveness.CompilerLiveI64Set)
  (unsafe
    (ptr-read
      (int->ptr
        (cast
          (+
            state.address
            (comptime
              (offset-of (type CompilerBackendFunctionStateData) live-sets)))
          : u64)
        : (Ptr (__tl_dyn-array compiler_liveness.CompilerLiveI64Set))))))

(define (compiler-backend-function-state-emit-modes
  [state : CompilerBackendFunctionState]) : (__tl_dyn-array
    CompilerBackendEmitInstrsMode)
  (unsafe
    (ptr-read
      (int->ptr
        (cast
          (+
            state.address
            (comptime
              (offset-of (type CompilerBackendFunctionStateData) emit-modes)))
          : u64)
        : (Ptr (__tl_dyn-array CompilerBackendEmitInstrsMode))))))

(define (compiler-backend-function-state-instr-seqs
  [state : CompilerBackendFunctionState]) : (__tl_dyn-array
    compiler_ir_types.CompilerIrInstrSeq)
  (unsafe
    (ptr-read
      (int->ptr
        (cast
          (+
            state.address
            (comptime
              (offset-of (type CompilerBackendFunctionStateData) instr-seqs)))
          : u64)
        : (Ptr (__tl_dyn-array compiler_ir_types.CompilerIrInstrSeq))))))

(define (compiler-backend-function-state-phi-target-seqs
  [state : CompilerBackendFunctionState]) : (__tl_dyn-array BackendSymbolSeq)
  (unsafe
    (ptr-read
      (int->ptr
        (cast
          (+
            state.address
            (comptime
              (offset-of (type CompilerBackendFunctionStateData) phi-targets)))
          : u64)
        : (Ptr (__tl_dyn-array BackendSymbolSeq))))))

(define (compiler-backend-function-state-abort-targets
  [state : CompilerBackendFunctionState]) : (__tl_dyn-array
    CompilerBackendTarget)
  (unsafe
    (ptr-read
      (int->ptr
        (cast
          (+
            state.address
            (comptime
              (offset-of (type CompilerBackendFunctionStateData) abort-targets)))
          : u64)
        : (Ptr (__tl_dyn-array CompilerBackendTarget))))))

(define (compiler-backend-function-state-new) : CompilerBackendFunctionState
  (let
    [empty-i64-array : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [empty-bool-array : (__tl_dyn-array bool) (__tl_make-array bool 0)]
    [empty-string-array : (__tl_dyn-array String) (__tl_make-array String 0)]
    [empty-live-set : compiler_liveness.CompilerLiveI64Set
      (compiler_liveness.compiler-live-set-empty)]
    [empty-instr-seq : compiler_ir_types.CompilerIrInstrSeq
      (compiler-backend-empty-instr-seq)]
    [empty-symbol-seq : BackendSymbolSeq
      (BackendSymbolSeq (compiler-backend-global-shared-view empty-i64-array) 0)]
    [empty-assignment-index : compiler_regalloc.CompilerRegAssignmentTable
      (compiler_regalloc.compiler-reg-assignment-table-with-min-capacity
        (compiler_regalloc.compiler-reg-assignment-table-empty)
        1)]
    [empty-scratch-assignment-index : compiler_regalloc.CompilerRegAssignmentTable
      (compiler_regalloc.compiler-reg-assignment-table-empty)]
    [i64s : (__tl_dyn-array i64)
      (__tl_make-array i64 compiler-backend-function-i64-count)]
    [bools : (__tl_dyn-array bool)
      (__tl_make-array bool compiler-backend-function-bool-count)]
    [modes : (__tl_dyn-array CompilerBackendMode)
      (__tl_make-array CompilerBackendMode 1)]
    [strings : (__tl_dyn-array String)
      (__tl_make-array String compiler-backend-function-string-count)]
    [i64-arrays : (__tl_dyn-array (__tl_dyn-array i64))
      (__tl_make-array
        (__tl_dyn-array i64)
        compiler-backend-function-i64-array-count)]
    [live-sets : (__tl_dyn-array compiler_liveness.CompilerLiveI64Set)
      (__tl_make-array
        compiler_liveness.CompilerLiveI64Set
        compiler-backend-function-live-set-count)]
    [emit-modes : (__tl_dyn-array CompilerBackendEmitInstrsMode)
      (__tl_make-array CompilerBackendEmitInstrsMode 1)]
    [instr-seqs : (__tl_dyn-array compiler_ir_types.CompilerIrInstrSeq)
      (__tl_make-array compiler_ir_types.CompilerIrInstrSeq 1)]
    [phi-targets : (__tl_dyn-array BackendSymbolSeq)
      (__tl_make-array BackendSymbolSeq 1)]
    [abort-targets : (__tl_dyn-array CompilerBackendTarget)
      (__tl_make-array CompilerBackendTarget 1)]
    [assignment-indexes : (__tl_dyn-array
      compiler_regalloc.CompilerRegAssignmentTable)
      (__tl_make-array compiler_regalloc.CompilerRegAssignmentTable 1)]
    [scratch-i64s : (__tl_dyn-array i64)
      (__tl_make-array i64 compiler-backend-scratch-i64-count)]
    [scratch-bools : (__tl_dyn-array bool)
      (__tl_make-array bool compiler-backend-scratch-bool-count)]
    [scratch-i64-arrays : (__tl_dyn-array (__tl_dyn-array i64))
      (__tl_make-array
        (__tl_dyn-array i64)
        compiler-backend-scratch-i64-array-count)]
    [scratch-bool-arrays : (__tl_dyn-array (__tl_dyn-array bool))
      (__tl_make-array
        (__tl_dyn-array bool)
        compiler-backend-scratch-bool-array-count)]
    [scratch-string-arrays : (__tl_dyn-array (__tl_dyn-array String))
      (__tl_make-array
        (__tl_dyn-array String)
        compiler-backend-scratch-string-array-count)]
    [scratch-assignment-indexes : (__tl_dyn-array
      compiler_regalloc.CompilerRegAssignmentTable)
      (__tl_make-array compiler_regalloc.CompilerRegAssignmentTable 1)]
    [scratch : CompilerBackendScratchState
      (CompilerBackendScratchState
        (compiler-backend-global-shared-view scratch-i64s)
        scratch-bools
        (compiler-backend-global-shared-view scratch-i64-arrays)
        (compiler-backend-global-shared-view scratch-bool-arrays)
        (compiler-backend-global-shared-view scratch-string-arrays)
        (compiler-backend-global-shared-view scratch-assignment-indexes)
        (compiler-backend-global-shared-view empty-i64-array)
        (compiler-backend-global-shared-view empty-bool-array)
        (compiler-backend-global-shared-view empty-string-array)
        empty-scratch-assignment-index)]
    [scratch-index : i64 0]
    [cell : (__tl_dyn-array CompilerBackendFunctionStateData)
      (__tl_make-array CompilerBackendFunctionStateData 1)]
    (set!
      (array-ref i64s compiler-backend-function-i64-current-block-label)
      (compiler_ir_types.compiler-ir-label-none))
    (set! (array-ref i64s compiler-backend-function-i64-rax-override-var) -1)
    (set!
      (array-ref i64s compiler-backend-function-i64-rax-forward-pending-var)
      -1)
    (set! (array-ref i64s compiler-backend-function-i64-home-override0-var) -1)
    (set!
      (array-ref i64s compiler-backend-function-i64-home-override0-reg)
      compiler_abi.compiler-reg-id-invalid)
    (set! (array-ref i64s compiler-backend-function-i64-home-override1-var) -1)
    (set!
      (array-ref i64s compiler-backend-function-i64-home-override1-reg)
      compiler_abi.compiler-reg-id-invalid)
    (set!
      (array-ref i64s compiler-backend-function-i64-current-phi-target-point)
      -1)
    (set!
      (array-ref i64s compiler-backend-function-i64-current-phi-dst-home-mask)
      -1)
    (set! (array-ref modes 0) (Scalar))
    (set!
      (array-ref strings compiler-backend-function-string-shrinkwrap-bare-label)
      "")
    (set!
      (array-ref strings compiler-backend-function-string-abort-site-path)
      "")
    (set!
      (array-ref
        i64-arrays
        compiler-backend-function-i64-array-addr-of-forwarding-src)
      (compiler-backend-global-shared-view empty-i64-array))
    (set!
      (array-ref i64-arrays compiler-backend-function-i64-array-fuse-use-counts)
      (compiler-backend-global-shared-view empty-i64-array))
    (set!
      (array-ref
        i64-arrays
        compiler-backend-function-i64-array-fuse-free-counts)
      (compiler-backend-global-shared-view empty-i64-array))
    (set!
      (array-ref
        i64-arrays
        compiler-backend-function-i64-array-gep-fold-disp-table)
      (compiler-backend-global-shared-view empty-i64-array))
    (set!
      (array-ref
        i64-arrays
        compiler-backend-function-i64-array-gep-fold-kind-table)
      (compiler-backend-global-shared-view empty-i64-array))
    (set!
      (array-ref
        i64-arrays
        compiler-backend-function-i64-array-gep-fold-scale-table)
      (compiler-backend-global-shared-view empty-i64-array))
    (set!
      (array-ref i64-arrays compiler-backend-function-i64-array-jump-forward)
      (compiler-backend-global-shared-view empty-i64-array))
    ;; Fresh, not a view of the shared sentinel: the rank table is per function
    ;; and the shared-view ratchet admits no new aliases.
    (set!
      (array-ref i64-arrays compiler-backend-function-i64-array-group-ranks)
      (__tl_make-array i64 0))
    (set!
      (array-ref
        i64-arrays
        compiler-backend-function-i64-array-shift-count-bounds)
      (compiler-backend-global-shared-view empty-i64-array))
    (set!
      (array-ref live-sets compiler-backend-function-live-set-group-vars)
      (compiler-backend-global-shared-view empty-live-set))
    (set!
      (array-ref
        live-sets
        compiler-backend-function-live-set-addressable-group-vars)
      (compiler-backend-global-shared-view empty-live-set))
    (set! (array-ref emit-modes 0) (Normal))
    (set!
      (array-ref instr-seqs 0)
      (compiler-backend-global-shared-view empty-instr-seq))
    (set!
      (array-ref phi-targets 0)
      (compiler-backend-global-shared-view empty-symbol-seq))
    (set! (array-ref abort-targets 0) (CompilerBackendTarget.Linux))
    (set!
      (array-ref assignment-indexes 0)
      (compiler-backend-global-shared-view empty-assignment-index))
    (set!
      (array-ref scratch-i64s compiler-backend-scratch-i64-emergency-reg)
      compiler_abi.compiler-reg-id-invalid)
    (set!
      (array-ref
        scratch-i64s
        compiler-backend-scratch-i64-cycle-temp-base-offset)
      -512)
    (set!
      (array-ref scratch-i64s compiler-backend-scratch-i64-edge-flags-to)
      (compiler_ir_types.compiler-ir-label-none))
    (while (< scratch-index (array-length scratch-i64-arrays))
      (set!
        (array-ref scratch-i64-arrays scratch-index)
        (compiler-backend-global-shared-view empty-i64-array))
      (+= scratch-index 1))
    (set! scratch-index 0)
    (while (< scratch-index (array-length scratch-bool-arrays))
      (set!
        (array-ref scratch-bool-arrays scratch-index)
        (compiler-backend-global-shared-view empty-bool-array))
      (+= scratch-index 1))
    (set! scratch-index 0)
    (while (< scratch-index (array-length scratch-string-arrays))
      (set!
        (array-ref scratch-string-arrays scratch-index)
        (compiler-backend-global-shared-view empty-string-array))
      (+= scratch-index 1))
    (set!
      (array-ref scratch-assignment-indexes 0)
      (compiler-backend-global-shared-view empty-scratch-assignment-index))
    (set!
      (array-ref cell 0)
      (CompilerBackendFunctionStateData
        i64s
        bools
        modes
        strings
        i64-arrays
        live-sets
        emit-modes
        instr-seqs
        phi-targets
        abort-targets
        assignment-indexes
        scratch
        empty-i64-array
        empty-live-set
        empty-instr-seq
        empty-symbol-seq
        empty-assignment-index))
    (CompilerBackendFunctionState
      (cast
        (unsafe
          (ptr->int
            (ptr-cast
              (__tl_array-data cell)
              : (Ptr CompilerBackendFunctionStateData))))
        : i64))))

(define (compiler-backend-state-function-state
  [backend-state : CompilerBackendState]) : CompilerBackendFunctionState
  (let
    [address : i64
      (compiler-backend-state-function-state-address backend-state)]
    (if (= address 0)
      (let
        [owner : arena.Arena
          (unsafe
            (arena.Arena (compiler-backend-state-owner-arena backend-state)))]
        [function-state : CompilerBackendFunctionState
          (in-arena owner (compiler-backend-function-state-new))]
        (compiler-backend-state-set-function-state-address!
          backend-state
          function-state.address)
        function-state)
      (CompilerBackendFunctionState address))))

(define (compiler-backend-state-function-state-active?
  [backend-state : CompilerBackendState]) : bool
  (not (= (compiler-backend-state-function-state-address backend-state) 0)))

;; Install a fresh function owner only for the dynamic extent of one emitted
;; function.  Production wrappers allocate that owner in the function scratch
;; arena and retire the handle before the arena is rewound; the lazy getter
;; above remains only for narrow compatibility/test entrypoints that do not
;; enter the production function wrapper.
(define (compiler-backend-state-install-function-state!
  [backend-state : CompilerBackendState]
  [function-state : CompilerBackendFunctionState]) : unit
  (compiler-backend-state-set-function-state-address!
    backend-state
    function-state.address))

(define (compiler-backend-state-retire-function-state!
  [backend-state : CompilerBackendState]) : unit
  (compiler-backend-state-set-function-state-address! backend-state 0))

(define (compiler-backend-function-state-i64
  [state : CompilerBackendFunctionState]
  [index : i64]) : i64
  (array-ref (compiler-backend-function-state-i64s state) index))

(define (compiler-backend-function-state-set-i64!
  [state : CompilerBackendFunctionState]
  [index : i64]
  [value : i64]) : unit
  (set! (array-ref (compiler-backend-function-state-i64s state) index) value))

(define (compiler-backend-function-state-emit-instr-post-base
  [state : CompilerBackendFunctionState]) : i64
  (compiler-backend-function-state-i64
    state
    compiler-backend-function-i64-emit-instr-post-base))

(define (compiler-backend-function-state-set-emit-instr-post-base!
  [state : CompilerBackendFunctionState]
  [value : i64]) : unit
  (compiler-backend-function-state-set-i64!
    state
    compiler-backend-function-i64-emit-instr-post-base
    value))

(define (compiler-backend-function-state-emit-current-count
  [state : CompilerBackendFunctionState]) : i64
  (compiler-backend-function-state-i64
    state
    compiler-backend-function-i64-emit-current-count))

(define (compiler-backend-function-state-set-emit-current-count!
  [state : CompilerBackendFunctionState]
  [value : i64]) : unit
  (compiler-backend-function-state-set-i64!
    state
    compiler-backend-function-i64-emit-current-count
    value))

(define (compiler-backend-function-state-emit-current-site
  [state : CompilerBackendFunctionState]) : i64
  (compiler-backend-function-state-i64
    state
    compiler-backend-function-i64-emit-current-site))

(define (compiler-backend-function-state-set-emit-current-site!
  [state : CompilerBackendFunctionState]
  [value : i64]) : unit
  (compiler-backend-function-state-set-i64!
    state
    compiler-backend-function-i64-emit-current-site
    value))

(define (compiler-backend-function-state-emission-point
  [state : CompilerBackendFunctionState]) : i64
  (*
    2
    (-
      (compiler-backend-function-state-emit-instr-post-base state)
      (compiler-backend-function-state-emit-current-count state))))

(define (compiler-backend-function-state-bool?
  [state : CompilerBackendFunctionState]
  [index : i64]) : bool
  (array-ref (compiler-backend-function-state-bools state) index))

(define (compiler-backend-function-state-set-bool!
  [state : CompilerBackendFunctionState]
  [index : i64]
  [value : bool]) : unit
  (set! (array-ref (compiler-backend-function-state-bools state) index) value))

(define (compiler-backend-function-state-current-mode
  [state : CompilerBackendFunctionState]) : CompilerBackendMode
  (array-ref (compiler-backend-function-state-modes state) 0))

(define (compiler-backend-function-state-set-current-mode!
  [state : CompilerBackendFunctionState]
  [mode : CompilerBackendMode]) : unit
  (set! (array-ref (compiler-backend-function-state-modes state) 0) mode))

(define (compiler-backend-function-state-string
  [state : CompilerBackendFunctionState]
  [index : i64]) : String
  (owned_view.compiler-owned-element-view
    (compiler-backend-function-state-strings state)
    index))

(define (compiler-backend-function-state-set-string!
  [state : CompilerBackendFunctionState]
  [index : i64]
  [value : String]) : unit
  (set! (array-ref (compiler-backend-function-state-strings state) index) value))

(define (compiler-backend-function-state-i64-array
  [state : CompilerBackendFunctionState]
  [index : i64]) : (__tl_dyn-array i64)
  (owned_view.compiler-owned-element-view
    (compiler-backend-function-state-i64-arrays state)
    index))

(define (compiler-backend-function-state-set-i64-array!
  [state : CompilerBackendFunctionState]
  [index : i64]
  [value : (__tl_dyn-array i64)]) : unit
  (set!
    (array-ref (compiler-backend-function-state-i64-arrays state) index)
    value))

(define (compiler-backend-function-state-assignment-index
  [state : CompilerBackendFunctionState]) : compiler_regalloc.CompilerRegAssignmentTable
  (array-ref (compiler-backend-function-state-assignment-indexes state) 0))

(define (compiler-backend-function-state-set-assignment-index!
  [state : CompilerBackendFunctionState]
  [value : compiler_regalloc.CompilerRegAssignmentTable]) : unit
  (set!
    (array-ref (compiler-backend-function-state-assignment-indexes state) 0)
    value))

(define (compiler-backend-function-state-live-set
  [state : CompilerBackendFunctionState]
  [index : i64]) : compiler_liveness.CompilerLiveI64Set
  (owned_view.compiler-owned-element-view
    (compiler-backend-function-state-live-sets state)
    index))

(define (compiler-backend-function-state-set-live-set!
  [state : CompilerBackendFunctionState]
  [index : i64]
  [value : compiler_liveness.CompilerLiveI64Set]) : unit
  (set!
    (array-ref (compiler-backend-function-state-live-sets state) index)
    value))

(define (compiler-backend-function-state-next-mode
  [state : CompilerBackendFunctionState]) : CompilerBackendEmitInstrsMode
  (owned_view.compiler-owned-element-view
    (compiler-backend-function-state-emit-modes state)
    0))

(define (compiler-backend-function-state-set-next-mode!
  [state : CompilerBackendFunctionState]
  [mode : CompilerBackendEmitInstrsMode]) : unit
  (set! (array-ref (compiler-backend-function-state-emit-modes state) 0) mode))

(define (compiler-backend-function-state-next-instrs
  [state : CompilerBackendFunctionState]) : compiler_ir_types.CompilerIrInstrSeq
  (owned_view.compiler-owned-element-view
    (compiler-backend-function-state-instr-seqs state)
    0))

(define (compiler-backend-function-state-set-next-instrs!
  [state : CompilerBackendFunctionState]
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : unit
  (set! (array-ref (compiler-backend-function-state-instr-seqs state) 0) instrs))

(define (compiler-backend-function-state-phi-targets
  [state : CompilerBackendFunctionState]) : BackendSymbolSeq
  (owned_view.compiler-owned-element-view
    (compiler-backend-function-state-phi-target-seqs state)
    0))

(define (compiler-backend-function-state-set-phi-targets!
  [state : CompilerBackendFunctionState]
  [targets : BackendSymbolSeq]) : unit
  (set!
    (array-ref (compiler-backend-function-state-phi-target-seqs state) 0)
    targets))

(define (compiler-backend-function-state-abort-target
  [state : CompilerBackendFunctionState]) : CompilerBackendTarget
  (array-ref (compiler-backend-function-state-abort-targets state) 0))

(define (compiler-backend-function-state-set-abort-target!
  [state : CompilerBackendFunctionState]
  [target : CompilerBackendTarget]) : unit
  (set!
    (array-ref (compiler-backend-function-state-abort-targets state) 0)
    target))

(define (compiler-backend-function-scratch-reset!
  [state : CompilerBackendFunctionState]) : unit
  (let
    [scratch : CompilerBackendScratchState
      (compiler-backend-function-scratch-state state)]
    [i64s : (__tl_dyn-array i64) (compiler-backend-function-scratch-i64s state)]
    [bools : (__tl_dyn-array bool)
      (compiler-backend-function-scratch-bools state)]
    [i64-arrays : (__tl_dyn-array (__tl_dyn-array i64))
      (compiler-backend-function-scratch-i64-arrays state)]
    [bool-arrays : (__tl_dyn-array (__tl_dyn-array bool))
      (compiler-backend-function-scratch-bool-arrays state)]
    [string-arrays : (__tl_dyn-array (__tl_dyn-array String))
      (compiler-backend-function-scratch-string-arrays state)]
    [index : i64 0]
    (while (< index (array-length i64s))
      (set! (array-ref i64s index) 0)
      (+= index 1))
    (set!
      (array-ref i64s compiler-backend-scratch-i64-emergency-reg)
      compiler_abi.compiler-reg-id-invalid)
    (set!
      (array-ref i64s compiler-backend-scratch-i64-cycle-temp-base-offset)
      -512)
    (set!
      (array-ref i64s compiler-backend-scratch-i64-edge-flags-to)
      (compiler_ir_types.compiler-ir-label-none))
    (set! index 0)
    (while (< index (array-length bools))
      (set! (array-ref bools index) false)
      (+= index 1))
    (set! index 0)
    (while (< index (array-length i64-arrays))
      (set!
        (array-ref i64-arrays index)
        (compiler-backend-global-shared-view scratch.empty-i64-array))
      (+= index 1))
    (set! index 0)
    (while (< index (array-length bool-arrays))
      (set!
        (array-ref bool-arrays index)
        (compiler-backend-global-shared-view scratch.empty-bool-array))
      (+= index 1))
    (set! index 0)
    (while (< index (array-length string-arrays))
      (set!
        (array-ref string-arrays index)
        (compiler-backend-global-shared-view scratch.empty-string-array))
      (+= index 1))
    (compiler-backend-function-scratch-set-assignment-index!
      state
      scratch.empty-assignment-index)))

(define (compiler-backend-function-state-reset!
  [state : CompilerBackendFunctionState]) : unit
  (let
    [data : CompilerBackendFunctionStateData
      (compiler-backend-function-state-data state)]
    [i64s : (__tl_dyn-array i64) data.i64s]
    [bools : (__tl_dyn-array bool) data.bools]
    [index : i64 0]
    (while (< index (array-length i64s))
      (set! (array-ref i64s index) 0)
      (+= index 1))
    (set! index 0)
    (while (< index (array-length bools))
      (set! (array-ref bools index) false)
      (+= index 1))
    (set!
      (array-ref i64s compiler-backend-function-i64-current-block-label)
      (compiler_ir_types.compiler-ir-label-none))
    (set! (array-ref i64s compiler-backend-function-i64-rax-override-var) -1)
    (set!
      (array-ref i64s compiler-backend-function-i64-rax-forward-pending-var)
      -1)
    (set! (array-ref i64s compiler-backend-function-i64-home-override0-var) -1)
    (set!
      (array-ref i64s compiler-backend-function-i64-home-override0-reg)
      compiler_abi.compiler-reg-id-invalid)
    (set! (array-ref i64s compiler-backend-function-i64-home-override1-var) -1)
    (set!
      (array-ref i64s compiler-backend-function-i64-home-override1-reg)
      compiler_abi.compiler-reg-id-invalid)
    (set!
      (array-ref i64s compiler-backend-function-i64-current-phi-target-point)
      -1)
    (set!
      (array-ref i64s compiler-backend-function-i64-current-phi-dst-home-mask)
      -1)
    (set! (array-ref data.modes 0) (Scalar))
    (set!
      (array-ref
        data.strings
        compiler-backend-function-string-shrinkwrap-bare-label)
      "")
    (set!
      (array-ref data.strings compiler-backend-function-string-abort-site-path)
      "")
    (set!
      (array-ref
        data.i64-arrays
        compiler-backend-function-i64-array-addr-of-forwarding-src)
      (compiler-backend-global-shared-view data.empty-i64-array))
    (set!
      (array-ref
        data.i64-arrays
        compiler-backend-function-i64-array-fuse-use-counts)
      (compiler-backend-global-shared-view data.empty-i64-array))
    (set!
      (array-ref
        data.i64-arrays
        compiler-backend-function-i64-array-fuse-free-counts)
      (compiler-backend-global-shared-view data.empty-i64-array))
    (set!
      (array-ref
        data.i64-arrays
        compiler-backend-function-i64-array-gep-fold-disp-table)
      (compiler-backend-global-shared-view data.empty-i64-array))
    (set!
      (array-ref
        data.i64-arrays
        compiler-backend-function-i64-array-gep-fold-kind-table)
      (compiler-backend-global-shared-view data.empty-i64-array))
    (set!
      (array-ref
        data.i64-arrays
        compiler-backend-function-i64-array-gep-fold-scale-table)
      (compiler-backend-global-shared-view data.empty-i64-array))
    (set!
      (array-ref
        data.i64-arrays
        compiler-backend-function-i64-array-jump-forward)
      (compiler-backend-global-shared-view data.empty-i64-array))
    (set!
      (array-ref
        data.i64-arrays
        compiler-backend-function-i64-array-shift-count-bounds)
      (compiler-backend-global-shared-view data.empty-i64-array))
    (set!
      (array-ref data.i64-arrays compiler-backend-function-i64-array-edge-index)
      (compiler-backend-global-shared-view data.empty-i64-array))
    (set!
      (array-ref
        data.i64-arrays
        compiler-backend-function-i64-array-group-ranks)
      (__tl_make-array i64 0))
    (set!
      (array-ref data.assignment-indexes 0)
      (compiler-backend-global-shared-view data.empty-assignment-index))
    (set!
      (array-ref data.live-sets compiler-backend-function-live-set-group-vars)
      (compiler-backend-global-shared-view data.empty-live-set))
    (set!
      (array-ref
        data.live-sets
        compiler-backend-function-live-set-addressable-group-vars)
      (compiler-backend-global-shared-view data.empty-live-set))
    (set! (array-ref data.emit-modes 0) (Normal))
    (set!
      (array-ref data.instr-seqs 0)
      (compiler-backend-global-shared-view data.empty-instr-seq))
    (set!
      (array-ref data.phi-targets 0)
      (compiler-backend-global-shared-view data.empty-symbol-seq))
    (set! (array-ref data.abort-targets 0) (CompilerBackendTarget.Linux))
    (compiler-backend-function-scratch-reset! state)))

(defstruct BackendFloatEntry
  (ty compiler_ast_types.AstType)
  (bits u64))

(defstruct BackendFloatSeq
  (slots (__tl_dyn-array BackendFloatEntry))
  (len i64))

;; Capacity-doubling growth for the array-backed backend sequences (same shape as
;; compiler-ir-instr-builder-*): copy the live prefix into a doubled array.
(define (compiler-backend-seq-capacity [cap : i64]) : i64
  (if (< cap 1)
    4
    (* cap 2)))

(define (compiler-backend-string-copy-range!
  [dst : (&mut dst (__tl_dyn-array String))]
  [src : (& src (__tl_dyn-array String))]
  [count : i64]) : unit
  (for [index (iterator.range 0 count)]
    (set!
      (array-ref dst index)
      (owned_view.compiler-owned-element-view src index))))

(define (compiler-backend-string-push!
  [seq : (&mut seq BackendStringSeq)]
  [head : String]) : unit
  (if (< seq.len (array-length seq.slots))
    unit
    (let
      [bigger : (__tl_dyn-array String)
        (__tl_make-array
          String
          (compiler-backend-seq-capacity (array-length seq.slots)))]
      (compiler-backend-string-copy-range! (&mut bigger) (& seq.slots) seq.len)
      (set! seq.slots bigger)))
  (let
    [index : i64 seq.len]
    (set! (array-ref seq.slots index) head)
    (set! seq.len (+ index 1))))

(define (compiler-backend-symbol-copy-range!
  [dst : (&mut dst (__tl_dyn-array i64))]
  [src : (& src (__tl_dyn-array i64))]
  [count : i64]) : unit
  (for [index (iterator.range 0 count)]
    (set! (array-ref dst index) (array-ref src index))))

(define (compiler-backend-symbol-push!
  [seq : (&mut seq BackendSymbolSeq)]
  [head : i64]) : unit
  (if (< seq.len (array-length seq.slots))
    unit
    (let
      [bigger : (__tl_dyn-array i64)
        (__tl_make-array
          i64
          (compiler-backend-seq-capacity (array-length seq.slots)))]
      (compiler-backend-symbol-copy-range! (&mut bigger) (& seq.slots) seq.len)
      (set! seq.slots bigger)))
  (let
    [index : i64 seq.len]
    (set! (array-ref seq.slots index) head)
    (set! seq.len (+ index 1))))

(define (compiler-backend-float-copy-range!
  [dst : (&mut dst (__tl_dyn-array BackendFloatEntry))]
  [src : (& src (__tl_dyn-array BackendFloatEntry))]
  [count : i64]) : unit
  (for [index (iterator.range 0 count)]
    (set!
      (array-ref dst index)
      (owned_view.compiler-owned-element-view src index))))

(define (compiler-backend-float-push!
  [seq : (&mut seq BackendFloatSeq)]
  [entry : BackendFloatEntry]) : unit
  (if (< seq.len (array-length seq.slots))
    unit
    (let
      [bigger : (__tl_dyn-array BackendFloatEntry)
        (__tl_make-array
          BackendFloatEntry
          (compiler-backend-seq-capacity (array-length seq.slots)))]
      (compiler-backend-float-copy-range! (&mut bigger) (& seq.slots) seq.len)
      (set! seq.slots bigger)))
  (let
    [index : i64 seq.len]
    (set! (array-ref seq.slots index) entry)
    (set! seq.len (+ index 1))))

(define (compiler-backend-empty-label-seq) : BackendSymbolSeq
  (BackendSymbolSeq (__tl_make-array i64 0) 0))

;; Phi targets are block labels, so they are a seq of interned ids rather than
;; of spellings. `compiler-backend-symbol-list-contains-id?` is an
;; i64 membership test -- `compiler-ir-symbol-id` is the identity -- so it serves
;; label ids unchanged.
;; CFG-aware cross-block reload-elision (carry-safe label set).
;; Holds the asm label strings (".L<scope>_<block>") of blocks across which the
;; peephole's reg->slot owner map may be CARRIED (instead of reset). A block
;; label is admitted ONLY when the block is reached exclusively by fall-through
;; from its single, layout-adjacent predecessor (see
;; compiler-backend-peephole-collect-carry-safe!). Populated per-function during
;; emission from the FINAL emitted blocks; reset (epoch bump) at the top of each
;; program emit. Read by the peephole. A label outside the set resets the
;; owner map, so any not-proven-safe label stays sound.
;;
;; The stream owns an open-addressing table of byte offsets/lengths into one
;; flat byte arena.  The storage starts small and grows geometrically in the
;; backend state's retained lazy arena; reaching either conservative ceiling
;; merely drops a carry hint, which can only forgo an optimization.
(define compiler-backend-peephole-carry-safe-initial-capacity : i64
  256)
(define compiler-backend-peephole-carry-safe-capacity : i64
  262144)
(define compiler-backend-peephole-carry-safe-initial-bytes-capacity : i64
  4096)
(define compiler-backend-peephole-carry-safe-bytes-capacity : i64
  16777216)

;; A narrow borrowed lookup view keeps the hot label path independent of the
;; 35-field owning stream aggregate. The arrays remain owned by the stream.
(defstruct CompilerBackendPeepholeCarrySafeView
  (offsets (__tl_dyn-array i64))
  (lengths (__tl_dyn-array i64))
  (bytes (__tl_dyn-array u8)))

;; One count cell packs both counters so the 35-field stream surface needs no
;; extra field: byte positions need 25 bits for the inclusive 16 MiB limit,
;; and the remaining high bits hold the table entry count. The latter drives a
;; 50% load-factor grow policy; letting a table fill completely makes
;; open-addressing probes dominate.
(define compiler-backend-peephole-carry-safe-count-entry-shift : i64
  25)
(define compiler-backend-peephole-carry-safe-count-bytes-mask : i64
  33554431)

(define (compiler-backend-peephole-carry-safe-byte-count [packed : i64]) : i64
  (bit-and packed compiler-backend-peephole-carry-safe-count-bytes-mask))

(define (compiler-backend-peephole-carry-safe-entry-count [packed : i64]) : i64
  (shr packed compiler-backend-peephole-carry-safe-count-entry-shift))

(define (compiler-backend-peephole-carry-safe-counts-pack
  [bytes : i64]
  [entries : i64]) : i64
  (bit-or
    bytes
    (shl entries compiler-backend-peephole-carry-safe-count-entry-shift)))

(define (compiler-backend-peephole-carry-safe-storage-ensure-with-backend-state!
  [backend-state : CompilerBackendState]
  [stream : CompilerBackendStreamState]) : unit
  (let
    [data : (MutPtr CompilerBackendStreamStateData)
      (compiler-backend-stream-state-ptr stream)]
    (if (>
      (array-length
        (unsafe
          (deref data).carry-safe-offsets))
      0)
      unit
      (let
        [owner : arena.Arena
          (compiler-backend-state-lazy-table-arena-ensure! backend-state)]
        (in-arena
          owner
          (let
            [offsets : (__tl_dyn-array i64)
              (__tl_make-array
                i64
                compiler-backend-peephole-carry-safe-initial-capacity)]
            [lengths : (__tl_dyn-array i64)
              (__tl_make-array
                i64
                compiler-backend-peephole-carry-safe-initial-capacity)]
            [bytes : (__tl_dyn-array u8)
              (__tl_make-array
                u8
                compiler-backend-peephole-carry-safe-initial-bytes-capacity)]
            [i : i64 0]
            (while (< i (array-length offsets))
              (set! (array-ref offsets i) -1)
              (+= i 1))
            (unsafe
              (set! (deref data).carry-safe-offsets offsets)
              (set! (deref data).carry-safe-lengths lengths)
              (set! (deref data).carry-safe-bytes bytes)
              (set! (deref data).carry-safe-bytes-count 0))))))))

(define (compiler-backend-peephole-carry-safe-table-grow!
  [backend-state : CompilerBackendState]
  [stream : CompilerBackendStreamState]) : bool
  (let
    [data : (MutPtr CompilerBackendStreamStateData)
      (compiler-backend-stream-state-ptr stream)]
    [old-offsets : (__tl_dyn-array i64)
      (unsafe
        (deref data).carry-safe-offsets)]
    [old-lengths : (__tl_dyn-array i64)
      (unsafe
        (deref data).carry-safe-lengths)]
    [old-cap : i64 (array-length old-offsets)]
    [new-cap : i64
      (if (> (* old-cap 4) compiler-backend-peephole-carry-safe-capacity)
        compiler-backend-peephole-carry-safe-capacity
        (* old-cap 4))]
    (if (<= new-cap old-cap)
      false
      (let
        [owner : arena.Arena
          (compiler-backend-state-lazy-table-arena-ensure! backend-state)]
        (in-arena
          owner
          (let
            [offsets : (__tl_dyn-array i64) (__tl_make-array i64 new-cap)]
            [lengths : (__tl_dyn-array i64) (__tl_make-array i64 new-cap)]
            [bytes : (__tl_dyn-array u8)
              (unsafe
                (deref data).carry-safe-bytes)]
            (for [i (iterator.range 0 new-cap)]
              (set! (array-ref offsets i) -1))
            (for [i (iterator.range 0 old-cap)]
              (let
                [off : i64 (array-ref old-offsets i)]
                (when
                  (>= off 0)
                  (let
                    [len : i64 (array-ref old-lengths i)]
                    [hash : i64
                      (ci.intern-hash-words
                        (unsafe
                          (ptr-cast (__tl_array-data bytes) : (Ptr u8)))
                        off
                        len)]
                    [slot : i64 (bit-and hash (- new-cap 1))]
                    (while (>= (array-ref offsets slot) 0)
                      (set!
                        slot
                        (if (= (+ slot 1) new-cap)
                          0
                          (+ slot 1))))
                    (set! (array-ref offsets slot) off)
                    (set! (array-ref lengths slot) len)))))
            (unsafe
              (set! (deref data).carry-safe-offsets offsets)
              (set! (deref data).carry-safe-lengths lengths))
            true))))))

(define (compiler-backend-peephole-carry-safe-bytes-grow!
  [backend-state : CompilerBackendState]
  [stream : CompilerBackendStreamState]
  [required : i64]) : bool
  (let
    [data : (MutPtr CompilerBackendStreamStateData)
      (compiler-backend-stream-state-ptr stream)]
    [old : (__tl_dyn-array u8)
      (unsafe
        (deref data).carry-safe-bytes)]
    [old-cap : i64 (array-length old)]
    [new-cap : i64 old-cap]
    (while (and
      (< new-cap required)
      (< new-cap compiler-backend-peephole-carry-safe-bytes-capacity))
      (set!
        new-cap
        (if (>
          (* new-cap 4)
          compiler-backend-peephole-carry-safe-bytes-capacity)
          compiler-backend-peephole-carry-safe-bytes-capacity
          (* new-cap 4))))
    (if (< new-cap required)
      false
      (let
        [owner : arena.Arena
          (compiler-backend-state-lazy-table-arena-ensure! backend-state)]
        (in-arena
          owner
          (let
            [bytes : (__tl_dyn-array u8) (__tl_make-array u8 new-cap)]
            (for [i
              (iterator.range
                0
                (compiler-backend-peephole-carry-safe-byte-count
                  (unsafe
                    (deref data).carry-safe-bytes-count)))]
              (set! (array-ref bytes i) (array-ref old i)))
            (unsafe
              (set! (deref data).carry-safe-bytes bytes))
            true))))))

;; Clear the table logically: mark every slot empty and reset the byte cursor.
(define (compiler-backend-peephole-carry-safe-reset-with-backend-state!
  [backend-state : CompilerBackendState]
  [stream : CompilerBackendStreamState]) : unit
  (let
    [_storage : unit
      (compiler-backend-peephole-carry-safe-storage-ensure-with-backend-state!
        backend-state
        stream)]
    [data : CompilerBackendStreamStateData
      (compiler-backend-stream-state-data stream)]
    [offsets : (__tl_dyn-array i64) data.carry-safe-offsets]
    [cap : i64 (array-length offsets)]
    (for [i (iterator.range 0 cap)]
      (set! (array-ref offsets i) -1))
    (set! data.carry-safe-bytes-count 0)
    (compiler-backend-stream-state-data-set!
      stream
      (compiler-backend-global-shared-view data))
    unit))

;; True iff arena bytes [off,off+len) equal `klen` bytes read from `data` at
;; `kstart` (byte-exact key comparison).
(define (compiler-backend-peephole-carry-safe-bytes-eq?
  [bytes : (& bytes (__tl_dyn-array u8))]
  [off : i64]
  [len : i64]
  [key-data : (Ptr u8)]
  [kstart : i64]
  [klen : i64]) : bool
  (if (not (= len klen))
    false
    (let
      [j : i64 0]
      [ok : bool true]
      (while (and ok (< j len))
        (if (=
          (cast (array-ref bytes (+ off j)) : i64)
          (compiler-backend-peephole-byte-at key-data (+ kstart j)))
          unit
          (set! ok false))
        (+= j 1))
      ok)))

;; Insert the key given by `klen` bytes at `data`+`kstart` with byte hash `hash`.
;; Reuses an empty (offset -1) slot; appends the key to the arena. A full table
;; or arena silently drops the key (sound: a missed carry-safe label only forgoes
;; one elision).
(define (compiler-backend-peephole-carry-safe-insert-bytes!
  [backend-state : CompilerBackendState]
  [stream : CompilerBackendStreamState]
  [key-data : (Ptr u8)]
  [kstart : i64]
  [klen : i64]
  [hash : i64]) : unit
  (let
    [data : (Ptr CompilerBackendStreamStateData)
      (compiler-backend-stream-state-view stream)]
    [offsets : (__tl_dyn-array i64)
      (unsafe
        (deref data).carry-safe-offsets)]
    [lengths : (__tl_dyn-array i64)
      (unsafe
        (deref data).carry-safe-lengths)]
    [bytes : (__tl_dyn-array u8)
      (unsafe
        (deref data).carry-safe-bytes)]
    [packed-count : i64
      (unsafe
        (deref data).carry-safe-bytes-count)]
    [entry-count : i64
      (compiler-backend-peephole-carry-safe-entry-count packed-count)]
    [cap : i64 (array-length offsets)]
    [slot : i64 (bit-and hash (- cap 1))]
    (when
      (and
        (< cap compiler-backend-peephole-carry-safe-capacity)
        (>= (* (+ entry-count 1) 2) cap))
      (when
        (compiler-backend-peephole-carry-safe-table-grow! backend-state stream)
        (compiler-backend-peephole-carry-safe-insert-bytes!
          backend-state
          stream
          key-data
          kstart
          klen
          hash)
        (return unit)))
    (for [walked (iterator.range 0 cap)]
      (let
        [off : i64 (array-ref offsets slot)]
        (if (< off 0)
          (let
            [start : i64
              (compiler-backend-peephole-carry-safe-byte-count packed-count)]
            (if (or
              (<= (+ start klen) (array-length bytes))
              (compiler-backend-peephole-carry-safe-bytes-grow!
                backend-state
                stream
                (+ start klen)))
              (let
                [current : CompilerBackendStreamStateData
                  (compiler-backend-stream-state-data stream)]
                [current-bytes : (__tl_dyn-array u8) current.carry-safe-bytes]
                (for [j (iterator.range 0 klen)]
                  (set!
                    (array-ref current-bytes (+ start j))
                    (cast
                      (compiler-backend-peephole-byte-at key-data (+ kstart j))
                      : u8)))
                (set! (array-ref offsets slot) start)
                (set! (array-ref lengths slot) klen)
                (set!
                  current.carry-safe-bytes-count
                  (compiler-backend-peephole-carry-safe-counts-pack
                    (+ start klen)
                    (+ entry-count 1)))
                (compiler-backend-stream-state-data-set!
                  stream
                  (compiler-backend-global-shared-view current))
                (return unit))
              (return unit)))
          (if (compiler-backend-peephole-carry-safe-bytes-eq?
            (& bytes)
            off
            (array-ref lengths slot)
            key-data
            kstart
            klen)
            (return unit)
            (set!
              slot
              (if (>= (+ slot 1) cap)
                0
                (+ slot 1)))))))
    (when
      (compiler-backend-peephole-carry-safe-table-grow! backend-state stream)
      (compiler-backend-peephole-carry-safe-insert-bytes!
        backend-state
        stream
        key-data
        kstart
        klen
        hash))
    unit))

;; Insert a key String (used by the collector, which holds owned label Strings).
(define (compiler-backend-peephole-carry-safe-insert!
  [backend-state : CompilerBackendState]
  [stream : CompilerBackendStreamState]
  [key : String]) : unit
  (compiler-backend-peephole-carry-safe-insert-bytes!
    backend-state
    stream
    (unsafe
      (string-data key))
    0
    (string.string-length key)
    (ci.intern-hash key)))

;; True iff the key given by `klen` bytes at `data`+`kstart` (byte hash `hash`)
;; is in the set (exact byte match; an empty slot terminates the probe).
(define (compiler-backend-peephole-carry-safe-contains-view?
  [view : (& view CompilerBackendPeepholeCarrySafeView)]
  [key-data : (Ptr u8)]
  [kstart : i64]
  [klen : i64]
  [hash : i64]) : bool
  (let
    [offsets : (__tl_dyn-array i64) view.offsets]
    [lengths : (__tl_dyn-array i64) view.lengths]
    [bytes : (__tl_dyn-array u8) view.bytes]
    [cap : i64 (array-length offsets)]
    [slot : i64 (bit-and hash (- cap 1))]
    (for [walked (iterator.range 0 cap)]
      (let
        [off : i64 (array-ref offsets slot)]
        (if (< off 0)
          (return false)
          (if (compiler-backend-peephole-carry-safe-bytes-eq?
            (& bytes)
            off
            (array-ref lengths slot)
            key-data
            kstart
            klen)
            (return true)
            (set!
              slot
              (if (>= (+ slot 1) cap)
                0
                (+ slot 1)))))))
    false))

(define (compiler-backend-symbol-list-contains-id?
  [items : (& items BackendSymbolSeq)]
  [needle-id : i64]) : bool
  (let
    [n : i64 items.len]
    (for [i (iterator.range 0 n)]
      (when
        (=
          (compiler_ir_types.compiler-ir-symbol-id (array-ref items.slots i))
          needle-id)
        (return true)))
    false))

(defstruct BackendStringSet
  (seen backend_string_i64_map.Map)
  (items BackendStringSeq))

(defstruct BackendSymbolSet
  (seen backend_i64_i64_map.Map)
  (items BackendSymbolSeq))

(defstruct BackendFloatSet
  (seen backend_string_i64_map.Map)
  (items BackendFloatSeq))

(defstruct CompilerBackendProgramCollections
  (functions BackendSymbolSet)
  (references BackendSymbolSet)
  (strings BackendStringSet)
  (floats BackendFloatSet)
  (bytes BackendStringSet)
  (uses-avx2-i64-lane-id bool)
  (uses-avx512-i64-lane-id bool)
  (uses-f64-neg bool)
  (uses-f32-neg bool)
  ;; IAG-1 rides this walk. The census is held as a ONE-CELL array, not by
  ;; value: this struct is copied at every operand of every instruction, so an
  ;; inline census would triple the copy the whole walk pays. Every mutable
  ;; row it fills is a dyn-array or a two-cell cursor, so the cell is all the
  ;; identity the hooks need. A census with
  ;; `count` 0 is the disabled form: every note below is then a single compare.
  (iag CompilerBackendIagCensusCell))

(defenum CompilerBackendCollectState
  (Collections CompilerBackendProgramCollections))

(define (compiler-backend-string-set-new [capacity : i64]) : BackendStringSet
  (BackendStringSet
    (backend_string_i64_map.with-capacity capacity)
    (BackendStringSeq (__tl_make-array String 0) 0)))

(define (compiler-backend-symbol-set-new [capacity : i64]) : BackendSymbolSet
  (BackendSymbolSet
    (backend_i64_i64_map.with-capacity capacity)
    (BackendSymbolSeq (__tl_make-array i64 0) 0)))

(define (compiler-backend-float-payload-bits
  [ty : (& ty compiler_ast_types.AstType)]
  [bits : u64]) : u64
  (if (compiler-backend-f64-type? ty)
    bits
    (bit-and bits 0xffffffff)))

(define (compiler-backend-float-to-u64-threshold-bits
  [ty : (& ty compiler_ast_types.AstType)]) : u64
  (match ty
    ;; IEEE-754 encodings of 2^63 in the source precision.
    [(F32) 1593835520]
    [_ 4890909195324358656]))

(define (compiler-backend-float-key
  [ty : (& ty compiler_ast_types.AstType)]
  [bits : u64]) : String
  (str_cat.str-cat
    (match ty
      [(F32) "f32"]
      [_ "f64"])
    ":"
    (string.int->string
      (cast (compiler-backend-float-payload-bits ty bits) : i64))))

(define (compiler-backend-float-set-new [capacity : i64]) : BackendFloatSet
  (BackendFloatSet
    (backend_string_i64_map.with-capacity capacity)
    (BackendFloatSeq (__tl_make-array BackendFloatEntry 0) 0)))

(define (compiler-backend-string-set-add
  [set : BackendStringSet]
  [text : String]) : BackendStringSet
  (let
    [seen : backend_string_i64_map.Map
      (owned_view.compiler-owned-shared-view set.seen)]
    [items : BackendStringSeq (owned_view.compiler-owned-shared-view set.items)]
    (if (backend_string_i64_map.contains?
      (& seen)
      (compiler-backend-global-shared-view text))
      set
      (begin
        (backend_string_i64_map.insert-ref!
          (&mut seen)
          (compiler-backend-global-shared-view text)
          1)
        (compiler-backend-string-push! (&mut items) text)
        (BackendStringSet seen items)))))

(define (compiler-backend-symbol-set-add
  [set : BackendSymbolSet]
  [symbol : i64]) : BackendSymbolSet
  (let
    [seen : backend_i64_i64_map.Map
      (owned_view.compiler-owned-shared-view set.seen)]
    [id : i64 (compiler_ir_types.compiler-ir-symbol-id symbol)]
    [items : BackendSymbolSeq (owned_view.compiler-owned-shared-view set.items)]
    (if (backend_i64_i64_map.contains? (& seen) id)
      set
      (begin
        (backend_i64_i64_map.insert-ref! (&mut seen) id 1)
        (compiler-backend-symbol-push! (&mut items) symbol)
        (BackendSymbolSet seen items)))))

(define (compiler-backend-float-set-add
  [set : BackendFloatSet]
  [ty : compiler_ast_types.AstType]
  [bits : u64]) : BackendFloatSet
  (let
    [payload-bits : u64 (compiler-backend-float-payload-bits ty bits)]
    [key : String (compiler-backend-float-key ty payload-bits)]
    [seen : backend_string_i64_map.Map
      (owned_view.compiler-owned-shared-view set.seen)]
    [items : BackendFloatSeq (owned_view.compiler-owned-shared-view set.items)]
    (if (backend_string_i64_map.contains?
      (& seen)
      (compiler-backend-global-shared-view key))
      set
      (begin
        (backend_string_i64_map.insert-ref! (&mut seen) key 1)
        (compiler-backend-float-push!
          (&mut items)
          (BackendFloatEntry ty payload-bits))
        (BackendFloatSet seen items)))))

(define (compiler-backend-program-collections-new-with-iag
  [iag : CompilerBackendIagCensusCell]) : CompilerBackendProgramCollections
  (CompilerBackendProgramCollections
    (compiler-backend-symbol-set-new 256)
    (compiler-backend-symbol-set-new 256)
    (compiler-backend-string-set-new 256)
    (compiler-backend-float-set-new 256)
    (compiler-backend-string-set-new 64)
    false
    false
    false
    false
    iag))

(define (compiler-backend-program-collections-add-function
  [collections : CompilerBackendProgramCollections]
  [name : i64]) : CompilerBackendProgramCollections
  (CompilerBackendProgramCollections
    (compiler-backend-symbol-set-add collections.functions name)
    (compiler-backend-symbol-set-add collections.references name)
    collections.strings
    collections.floats
    collections.bytes
    collections.uses-avx2-i64-lane-id
    collections.uses-avx512-i64-lane-id
    collections.uses-f64-neg
    collections.uses-f32-neg
    collections.iag))

(define (compiler-backend-program-collections-add-reference
  [collections : CompilerBackendProgramCollections]
  [name : i64]) : CompilerBackendProgramCollections
  (CompilerBackendProgramCollections
    collections.functions
    (compiler-backend-symbol-set-add collections.references name)
    collections.strings
    collections.floats
    collections.bytes
    collections.uses-avx2-i64-lane-id
    collections.uses-avx512-i64-lane-id
    collections.uses-f64-neg
    collections.uses-f32-neg
    collections.iag))

(define (compiler-backend-program-collections-add-string
  [collections : CompilerBackendProgramCollections]
  [text : String]) : CompilerBackendProgramCollections
  (CompilerBackendProgramCollections
    collections.functions
    collections.references
    (compiler-backend-string-set-add collections.strings text)
    collections.floats
    collections.bytes
    collections.uses-avx2-i64-lane-id
    collections.uses-avx512-i64-lane-id
    collections.uses-f64-neg
    collections.uses-f32-neg
    collections.iag))

(define (compiler-backend-program-collections-add-float
  [collections : CompilerBackendProgramCollections]
  [ty : compiler_ast_types.AstType]
  [bits : u64]) : CompilerBackendProgramCollections
  (CompilerBackendProgramCollections
    collections.functions
    collections.references
    collections.strings
    (compiler-backend-float-set-add collections.floats ty bits)
    collections.bytes
    collections.uses-avx2-i64-lane-id
    collections.uses-avx512-i64-lane-id
    collections.uses-f64-neg
    collections.uses-f32-neg
    collections.iag))

(define (compiler-backend-program-collections-add-bytes
  [collections : CompilerBackendProgramCollections]
  [text : String]) : CompilerBackendProgramCollections
  (CompilerBackendProgramCollections
    collections.functions
    collections.references
    collections.strings
    collections.floats
    (compiler-backend-string-set-add collections.bytes text)
    collections.uses-avx2-i64-lane-id
    collections.uses-avx512-i64-lane-id
    collections.uses-f64-neg
    collections.uses-f32-neg
    collections.iag))

(define (compiler-backend-program-collections-mark-avx2-i64-lane-id
  [collections : CompilerBackendProgramCollections]) : CompilerBackendProgramCollections
  (CompilerBackendProgramCollections
    collections.functions
    collections.references
    collections.strings
    collections.floats
    collections.bytes
    true
    collections.uses-avx512-i64-lane-id
    collections.uses-f64-neg
    collections.uses-f32-neg
    collections.iag))

(define (compiler-backend-program-collections-mark-avx512-i64-lane-id
  [collections : CompilerBackendProgramCollections]) : CompilerBackendProgramCollections
  (CompilerBackendProgramCollections
    collections.functions
    collections.references
    collections.strings
    collections.floats
    collections.bytes
    collections.uses-avx2-i64-lane-id
    true
    collections.uses-f64-neg
    collections.uses-f32-neg
    collections.iag))

(define (compiler-backend-program-collections-mark-f64-neg
  [collections : CompilerBackendProgramCollections]) : CompilerBackendProgramCollections
  (set! collections.uses-f64-neg true)
  collections)

(define (compiler-backend-program-collections-mark-f32-neg
  [collections : CompilerBackendProgramCollections]) : CompilerBackendProgramCollections
  (set! collections.uses-f32-neg true)
  collections)

(define (backend-and4 [a : bool] [b : bool] [c : bool] [d : bool]) : bool
  (and a b c d))

(define (backend-or4 [a : bool] [b : bool] [c : bool] [d : bool]) : bool
  (or a b c d))

(define (backend-and8
  [a : bool]
  [b : bool]
  [c : bool]
  [d : bool]
  [e : bool]
  [f : bool]
  [g : bool]
  [h : bool]) : bool
  (and (backend-and4 a b c d) (backend-and4 e f g h)))

(define (backend-or8
  [a : bool]
  [b : bool]
  [c : bool]
  [d : bool]
  [e : bool]
  [f : bool]
  [g : bool]
  [h : bool]) : bool
  (or (backend-or4 a b c d) (backend-or4 e f g h)))

;; Best-available diagnostic for a backend error originating inside `function`.
;;
;; When the lowering provenance side table has a source span for the
;;
;; function, the diagnostic is stamped with that real line/column via
;;
;; `compiler-diagnostic-from-ast-span`; otherwise it falls back to the
;;
;; `path:1:1` location. `function` is the raw IR function name (the key used by
;;
;; the spans table), not the mangled assembly symbol.
(define (compiler-backend-source-span-index-fill
  [values
    : (&mut values (__tl_dyn-array compiler_ir_types.CompilerMaybeSourceSpan))]
  [index : i64]) : unit
  (unless
    (>= index (array-length values))
    (set!
      (array-ref values index)
      (compiler_ir_types.CompilerMaybeSourceSpan.No))
    (compiler-backend-source-span-index-fill values (+ index 1))))

(define (compiler-backend-source-span-index-add
  [entries : compiler_ir_types.CompilerSourceSpansEntryList]
  [map : backend_i64_i64_map.Map]
  [values
    : (&mut values (__tl_dyn-array compiler_ir_types.CompilerMaybeSourceSpan))]) : backend_i64_i64_map.Map
  (compiler-backend-source-span-index-add-array
    entries.slots
    (- entries.len 1)
    map
    values))

(define (compiler-backend-source-span-index-add-array
  [slots : (__tl_dyn-array compiler_ir_types.CompilerSourceSpansEntry)]
  [index : i64]
  [map : backend_i64_i64_map.Map]
  [values
    : (&mut values (__tl_dyn-array compiler_ir_types.CompilerMaybeSourceSpan))]) : backend_i64_i64_map.Map
  (let
    [out : backend_i64_i64_map.Map map]
    (if (< index 0)
      out
      (let
        [span-entry : compiler_ir_types.CompilerSourceSpansEntry
          (array-ref slots index)]
        [name : compiler_ir_types.CompilerIrSymbolId span-entry.name]
        [span : compiler_ast_types.AstSourceSpan span-entry.span]
        (if (backend_i64_i64_map.contains?
          (& out)
          (compiler_ir_types.compiler-ir-symbol-id-value name))
          (compiler-backend-source-span-index-add-array
            slots
            (- index 1)
            out
            values)
          (begin
            (backend_i64_i64_map.insert-ref!
              (&mut out)
              (compiler_ir_types.compiler-ir-symbol-id-value name)
              index)
            (set!
              (array-ref values index)
              (compiler_ir_types.CompilerMaybeSourceSpan.Some span))
            (compiler-backend-source-span-index-add-array
              slots
              (- index 1)
              out
              values)))))))

(define (compiler-backend-source-span-index-build-with-backend-state
  [backend-state : CompilerBackendState]
  [spans : compiler_ir_types.CompilerSourceSpans]) : CompilerBackendSourceSpanIndex
  (match (compiler-backend-global-shared-view spans)
    [(Spans entries _ _ _)
      (let
        [count : i64 (compiler_ir_types.compiler-source-spans-count (& spans))]
        [values : (__tl_dyn-array compiler_ir_types.CompilerMaybeSourceSpan)
          (__tl_make-array compiler_ir_types.CompilerMaybeSourceSpan count)]
        [instructions : CompilerBackendInstrSpanIndex
          (compiler-backend-instr-span-index-build (& spans))]
        (compiler-backend-source-span-index-fill (&mut values) 0)
        (CompilerBackendSourceSpanIndex
          (compiler-backend-source-span-index-add
            entries
            (backend_i64_i64_map.with-capacity (+ (* count 2) 16))
            (&mut values))
          values
          (compiler-backend-debug-file-index-build-with-backend-state
            backend-state
            spans)
          instructions
          backend-state))]))

;; Preserve insertion order, including duplicate keys, while selecting only the
;; current function's instruction locations. Build once in the program arena;
;; pinning, remapping and instruction lookup then visit function-local entries.
;; Non-debug emission retains its existing span path and builds no links.
(define (compiler-backend-instr-span-index-build
  [spans : (& spans compiler_ir_types.CompilerSourceSpans)]) : CompilerBackendInstrSpanIndex
  (if (not (compiler_ir_types.compiler-debug-info-enabled?))
    None
    (match spans
      [(Spans entries instr-entries _ _)
        (let
          [heads : backend_i64_i64_map.Map
            (backend_i64_i64_map.with-capacity (+ (* entries.len 2) 16))]
          [next : (__tl_dyn-array i64) (__tl_make-array i64 instr-entries.len)]
          [index : i64 instr-entries.len]
          (while (> index 0)
            (-= index 1)
            (let
              [entry : (& spans compiler_ir_types.CompilerSourceSpansInstrEntry)
                (& (array-ref instr-entries.slots index))]
              [name : i64 entry.function.value]
              (set!
                (array-ref next index)
                (match (backend_i64_i64_map.get (& heads) name)
                  [(LookupFound slot) slot]
                  [(LookupMissing) -1]))
              (backend_i64_i64_map.insert-ref! (&mut heads) name index)
              unit))
          (Links heads next))])))

(define (compiler-backend-function-source-spans
  [spans : compiler_ir_types.CompilerSourceSpans]
  [index : (& index CompilerBackendSourceSpanIndex)]
  [function : i64]) : compiler_ir_types.CompilerSourceSpans
  (match index.instructions
    [(None) spans]
    [(Links heads next)
      (match spans
        [(Spans entries instr-entries _ spmd)
          (let
            [local : compiler_ir_types.CompilerSourceSpansInstrEntryList
              (compiler_ir_types.compiler-source-spans-instr-entry-list-empty)]
            [slot : i64
              (match (backend_i64_i64_map.get (& heads) function)
                [(LookupFound found) found]
                [(LookupMissing) -1])]
            (while (>= slot 0)
              (set!
                local
                (compiler_ir_types.compiler-source-spans-instr-entry-list-append
                  local
                  (array-ref instr-entries.slots slot)))
              (set! slot (array-ref next slot)))
            (let
              [count : i64 local.len]
              (Spans entries local count spmd)))])]))

(define (compiler-backend-source-span-index-lookup
  [index : (& index CompilerBackendSourceSpanIndex)]
  [name : compiler_ir_types.CompilerIrSymbolId]) : compiler_ir_types.CompilerMaybeSourceSpan
  (match (backend_i64_i64_map.get
    (& index.entries)
    (compiler_ir_types.compiler-ir-symbol-id-value name))
    [(LookupFound slot)
      (if (and (>= slot 0) (< slot (array-length index.values)))
        (array-ref index.values slot)
        (No))]
    [(LookupMissing) (No)]))

(define (compiler-backend-function-diagnostic-index
  [index : (& index CompilerBackendSourceSpanIndex)]
  [function : compiler_ir_types.CompilerIrSymbolId]) : compiler_diagnostic.CompilerDiagnostic
  (match (compiler-backend-source-span-index-lookup index function)
    [(Some span)
      (compiler_diagnostic.compiler-diagnostic-from-ast-span "" span "")]
    [(No) (compiler_diagnostic.compiler-diagnostic-at-start "" "")]))

(define (compiler-backend-instr-diagnostic
  [spans : compiler_ir_types.CompilerSourceSpans]
  [function : i64]
  [instr : compiler_ir_types.CompilerIrInstr]
  [fallback : compiler_diagnostic.CompilerDiagnostic]) : compiler_diagnostic.CompilerDiagnostic
  (match (compiler_ir_types.compiler-source-spans-lookup-instr
    (& spans)
    (compiler_ir_types.compiler-ir-symbol-typed-id function)
    (& instr))
    [(Some span)
      (compiler_diagnostic.compiler-diagnostic-from-ast-span "" span "")]
    ;; The function diagnostic already carries the empty message (see
    ;; compiler-backend-function-diagnostic-index), so it is the answer as it
    ;; stands; restating it with "" would copy it for every instruction.
    [(No) fallback]))

;; Instruction spans use the destination variable as their provenance key.
;; Stack-slot coloring may renumber that variable, so keep every keyed value
;; out of shared slots and rebuild those keys with the resulting bijection.
;; Non-debug optimization retains only runtime-abort value spans. Debug SIMD
;; functions use the same pin/remap path for their instruction locations.
(define (compiler-backend-source-span-pinned-vars
  [spans : compiler_ir_types.CompilerSourceSpans]
  [function : i64]
  [vars : i64]) : compiler_liveness.CompilerLiveI64Set
  (if (<= vars 0)
    (compiler_liveness.compiler-live-set-empty)
    (match spans
      [(Spans _ instr-entries _ _)
        (if (= instr-entries.len 0)
          (compiler_liveness.compiler-live-set-empty)
          (let
            [words : (__tl_dyn-array i64)
              (compiler_liveness.compiler-live-set-builder (- vars 1))]
            [pinned : bool false]
            (for [index (iterator.range 0 instr-entries.len)]
              (let
                [span-entry : compiler_ir_types.CompilerSourceSpansInstrEntry
                  (array-ref instr-entries.slots index)]
                [key : compiler_ir_types.CompilerSourceSpansInstrKey
                  (compiler_ir_types.compiler-source-spans-instr-entry-key
                    (& span-entry))]
                (match key
                  [(Value key-function var)
                    (when
                      (and
                        (=
                          (compiler_ir_types.compiler-ir-symbol-id-value
                            key-function)
                          function)
                        (>= var 0)
                        (< var vars))
                      (compiler_liveness.compiler-live-set-builder-insert!
                        (&mut words)
                        var)
                      (set! pinned true))]
                  [_ unit])))
            (if pinned
              (let
                [count : i64 (array-length words)]
                (compiler_liveness.compiler-live-set-from-words-trimmed
                  words
                  count))
              (compiler_liveness.compiler-live-set-empty))))])))

(define (compiler-backend-remap-source-span-key
  [key : compiler_ir_types.CompilerSourceSpansInstrKey]
  [function : i64]
  [remap : (& (__tl_dyn-array i64))]) : compiler_ir_types.CompilerSourceSpansInstrKey
  (match key
    [(Value key-function var)
      (if (=
        (compiler_ir_types.compiler-ir-symbol-id-value key-function)
        function)
        (Value key-function (compiler_regalloc.compiler-reg-remap-id remap var))
        (Value key-function var))]
    [(Store key-function name) (Store key-function name)]
    [(Bounds key-function label) (Bounds key-function label)]))

(define (compiler-backend-remap-source-spans
  [spans : compiler_ir_types.CompilerSourceSpans]
  [function : i64]
  [remap : (__tl_dyn-array i64)]) : compiler_ir_types.CompilerSourceSpans
  (match spans
    [(Spans entries instr-entries count spmd)
      (let
        [slots : (__tl_dyn-array
          compiler_ir_types.CompilerSourceSpansInstrEntry)
          (__tl_make-array
            compiler_ir_types.CompilerSourceSpansInstrEntry
            instr-entries.len)]
        (for [index (iterator.range 0 instr-entries.len)]
          (let
            [span-entry : compiler_ir_types.CompilerSourceSpansInstrEntry
              (array-ref instr-entries.slots index)]
            [key : compiler_ir_types.CompilerSourceSpansInstrKey
              (compiler_ir_types.compiler-source-spans-instr-entry-key
                (& span-entry))]
            [path-id : i64 span-entry.path-id]
            [span : compiler_ast_types.AstSourceSpan span-entry.span]
            (set!
              (array-ref slots index)
              (compiler_ir_types.compiler-source-spans-instr-entry
                (compiler-backend-remap-source-span-key key function (& remap))
                path-id
                span))))
        (Spans
          entries
          (compiler_ir_types.CompilerSourceSpansInstrEntryList
            slots
            instr-entries.len)
          count
          spmd))]))

;; An emission error reported at the instruction (or function) being emitted.
(define (compiler-backend-instr-error
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [message : String]) : ResultCompilerBackend
  (Err
    (box
      (compiler_diagnostic.compiler-diagnostic-with-message
        (& instr-diag)
        message))))

;; A callee's emission error, restated at the instruction being emitted.
(define (compiler-backend-instr-error-from
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [diag : (Box compiler_diagnostic.CompilerDiagnostic)]) : ResultCompilerBackend
  (let
    [callee : compiler_diagnostic.CompilerDiagnostic (deref diag)]
    (compiler-backend-instr-error
      instr-diag
      (compiler_diagnostic.compiler-diagnostic-message callee))))

(define (compiler-backend-char-code [c : char]) : i64
  (cast c : i64))

;; --------------------------------------------------------------------------
;; Explicit per-job operand-render storage (Packet B1)
;; --------------------------------------------------------------------------
(define (compiler-backend-state-lazy-table-arena-ensure!
  [state : CompilerBackendState]) : arena.Arena
  (let
    [data : (MutPtr CompilerBackendStateData)
      (compiler-backend-state-ptr state)]
    (unsafe
      (if (= (deref data).lazy-table-arena 0)
        (let
          [owner : arena.Arena
            (unsafe
              (arena.Arena (arena.tl_arena_make_small)))]
          (set! (deref data).lazy-table-arena (arena.raw-handle owner))
          owner)
        (unsafe
          (arena.Arena (deref data).lazy-table-arena))))))

(define (compiler-backend-symbol-char
  [text : (& text str)]
  [idx : i64]
  [c : char]) : String
  (cond
    [(or
        (and (>= c 'A') (<= c 'Z'))
        (and (>= c 'a') (<= c 'z'))
        (and (>= c '0') (<= c '9'))
        (= c '_'))
      (string.substring text idx 1)]
    [(= c '-') "_"]
    [(= c '?') "_question"]
    [(= c '!') "_bang"]
    [(= c '+') "_plus"]
    [(= c '*') "_star"]
    [(= c '/') "_slash"]
    [(= c '=') "_eq"]
    [(= c '<') "_lt"]
    [(= c '>') "_gt"]
    [(= c ':') "_colon"]
    [else
      (str_cat.str-cat
        "_u"
        (compiler-backend-hex-byte (compiler-backend-char-code c)))]))

(define (compiler-backend-symbol-safe-char? [c : char]) : bool
  (or
    (and (>= c 'A') (<= c 'Z'))
    (and (>= c 'a') (<= c 'z'))
    (and (>= c '0') (<= c '9'))
    (= c '_')))

(define (compiler-backend-asm-safe-symbol-flush-run
  [name : (& name str)]
  [start : i64]
  [end : i64]
  [buf : (text_buf_borrowed.TextBufBorrowed name)]) : (text_buf_borrowed.TextBufBorrowed
    name)
  (if (> end start)
    (unsafe
      ;; The symbol scan proves 0 <= start < end <= string-length(name).
      (text_buf_borrowed.append-slice-unchecked
        buf
        (& name)
        start
        (- end start)))
    buf))

(define (compiler-backend-user-symbol-separator? [c : char]) : bool
  (or (= c '/') (= c '\\') (= c ':') (= c '.')))

(define (compiler-backend-user-symbol-tl-extension-at?
  [name : (& name str)]
  [idx : i64]) : bool
  (let
    [n : i64 (string.string-length name)]
    [after : i64 (+ idx 3)]
    (and
      (<= after n)
      (= (string.string-ref name idx) '.')
      (= (string.string-ref name (+ idx 1)) 't')
      (= (string.string-ref name (+ idx 2)) 'l')
      (or
        (= after n)
        (compiler-backend-user-symbol-separator? (string.string-ref name after))))))

(define (compiler-backend-user-symbol-body [name : String]) : String
  (let
    [i : i64 0]
    [n : i64 (string.string-length name)]
    [run-start : i64 0]
    [buf : (text_buf_borrowed.TextBufBorrowed name)
      (text_buf_borrowed.empty-like (& name))]
    [emitted : bool false]
    [pending-separator : bool false]
    (while (< i n)
      (if (compiler-backend-user-symbol-tl-extension-at? name i)
        (begin
          (when
            (> i run-start)
            (set!
              buf
              (compiler-backend-asm-safe-symbol-flush-run name run-start i buf))
            (set! emitted true))
          (+= i 3)
          (set! run-start i))
        (let
          [c : char (string.string-ref name i)]
          (if (compiler-backend-user-symbol-separator? c)
            (begin
              (when
                (> i run-start)
                (set!
                  buf
                  (compiler-backend-asm-safe-symbol-flush-run
                    name
                    run-start
                    i
                    buf))
                (set! emitted true))
              (if emitted
                (set! pending-separator true)
                unit)
              (+= i 1)
              (set! run-start i))
            (if (compiler-backend-symbol-safe-char? c)
              (begin
                (when
                  (and pending-separator (= i run-start))
                  (set! buf (text_buf_borrowed.append-owned buf "_"))
                  (set! pending-separator false))
                (+= i 1))
              (begin
                (when
                  (> i run-start)
                  (set!
                    buf
                    (compiler-backend-asm-safe-symbol-flush-run
                      name
                      run-start
                      i
                      buf))
                  (set! emitted true))
                (when
                  pending-separator
                  (set! buf (text_buf_borrowed.append-owned buf "_"))
                  (set! pending-separator false))
                (set!
                  buf
                  (text_buf_borrowed.append-owned
                    buf
                    (compiler-backend-symbol-char name i c)))
                (set! emitted true)
                (+= i 1)
                (set! run-start i)))))))
    (if (> n run-start)
      (set!
        buf
        (compiler-backend-asm-safe-symbol-flush-run name run-start n buf))
      unit)
    (text_buf_borrowed.render buf)))

(define (compiler-backend-user-symbol-uncached [name : String]) : String
  (if (string.eq name "main")
    "main"
    (str_cat.str-cat "_tl_" (compiler-backend-user-symbol-body name))))

(define (compiler-backend-f64-type? [ty : (& ty compiler_ast_types.AstType)]) : bool
  (match ty
    [(F64) true]
    [_ false]))

(define (compiler-backend-hex-digit [n : i64]) : String
  (cond
    [(= n 0) "0"]
    [(= n 1) "1"]
    [(= n 2) "2"]
    [(= n 3) "3"]
    [(= n 4) "4"]
    [(= n 5) "5"]
    [(= n 6) "6"]
    [(= n 7) "7"]
    [(= n 8) "8"]
    [(= n 9) "9"]
    [(= n 10) "a"]
    [(= n 11) "b"]
    [(= n 12) "c"]
    [(= n 13) "d"]
    [(= n 14) "e"]
    [else "f"]))

(define (compiler-backend-hex-byte [n : i64]) : String
  (str_cat.str-cat
    (compiler-backend-hex-digit (/ n 16))
    (compiler-backend-hex-digit (% n 16))))

(defstruct CompilerBackendIagCensus
  ;; Candidate globals, indexed 0..count-1 in `globals` order.
  (count i64)
  (words i64)
  (ids (__tl_dyn-array i64))
  (sizes (__tl_dyn-array i64))
  (reasons (__tl_dyn-array i64))
  (slots backend_i64_i64_map.Map)
  ;; Per-function facts, indexed by program-index function slot. Each of the
  ;; three bitset rows is `words` cells wide.
  (function-count i64)
  (mentions (__tl_dyn-array i64))
  (writes (__tl_dyn-array i64))
  (reach (__tl_dyn-array i64))
  (callee-reach (__tl_dyn-array i64))
  (indirect (__tl_dyn-array bool))
  ;; Union of every writes[] row: the candidates some function rebinds.
  (written (__tl_dyn-array i64))
  ;; Direct call edges, appended in function order by the shared walk. The
  ;; arrays double on demand rather than being pre-sized at one edge per
  ;; instruction: the conservative bound zero-fills tens of megabytes on a
  ;; program the size of the compiler, which costs more than the walk it saves.
  (edge-capacity i64)
  (edge-src (__tl_dyn-array i64))
  (edge-dst (__tl_dyn-array i64))
  ;; [0] the function slot being walked (-1 outside a function body),
  ;; [1] the edge cursor. Shared, so the census travels by value.
  (state (__tl_dyn-array i64))
  ;; Function name -> program-index slot, snapshotted so the shared walk needs
  ;; no program index of its own.
  (functions backend_i64_i64_map.Map))

;; One-word handle on a census. The shared collections struct carries this, not
;; the census itself; `note-*` below reads element 0 as a shared view, so a hook
;; costs a compare rather than a struct copy.
(defstruct CompilerBackendIagCensusCell
  (slots (__tl_dyn-array CompilerBackendIagCensus)))

(define (compiler-backend-peephole-byte-at [data : (Ptr u8)] [index : i64]) : i64
  (cast
    (unsafe
      (ptr-read (ptr-offset data index)))
    : i64))
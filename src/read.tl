;; read.tl - The s-expression reader for TypeLisp's own syntax, as a
;; `main`-less, importable module.
;;
;; It reads the spanned token stream of `lex.tl` into `SpannedSexpr` trees.
;; `spanned-result` reads source forms for the parser; `data-result` reads one
;; plain data form (a lockfile, TLCI metadata) from source text. Consumers that
;; do not need spans walk a tree through `sexpr-view`.
(import stdlib.str_cat_runtime as str_cat)

(module read)

(import stdlib.arena)
(import stdlib.io)
(import stdlib.string)
(import compiler_intern as ci)
(import lex as lexer)
(import token)
(cfg compile-profile (import compiler_allocation_profile as allocation_profile))

;; --------------------------------------------------------------------------
;; Dense s-expression node and child storage.
;; --------------------------------------------------------------------------
;; TypeLisp has only proper parenthesized and bracketed forms. A list therefore
;; stores one contiguous range of child-node ids instead of a boxed head/tail
;; spine. The storage variants are intentionally not a public traversal
;; contract: consumers use `SexprView` / `SpannedSexprView`, whose `List`
;; hands out a list's children as one borrowed slice of rows (see the views
;; below), so a traversal never builds a tail or a recursive pair. `Str`
;; carries the parser-assigned ID of a string literal's unescaped inner text.
;; The reader preserves the lexer's `token.Token.Str` ID, so a quoted string
;; reads as a distinct atom rather than being conflated with a `Sym` of the
;; same characters. `Char` carries a character-literal datum
;; (`'x'`), likewise keeping chars distinct from symbols, ints, and strings.
;; `Int` and `Float` keep their source spelling as an intern id (most integer
;; spellings are empty, see `token.int-text`), so every row is Copy.
;;
;; Lifetime: like `Sym` and `Str`, Int and Float text now lives as long as the
;; active intern table, not as a String owned by the row. The views render it
;; with `sp-text`, a shared view of the interned spelling. A consumer that keeps
;; a spelling past an intern reset copies it out with `sp-text-copy`, as the
;; parser's literal nodes do.
;;
;; `SexprView` is the span-free view: it drops spans and reads a bracket list
;; like a parenthesized one.
(defenum SexprView
  (Int i64 String)
  ;; Symbols retain their mixed renderable/structural syntax identity while
  ;; crossing the traversal surface. Consumers must explicitly preserve the
  ;; identity or reduce it to a renderable source name.
  (Sym ci.InternSyntaxId)
  (List (& program (Slice SpannedSexpr)))
  (Str ci.InternId)
  (Char char)
  (Float String))

(defenum ResultSexpr
  (Ok SpannedSexpr)
  (Err String))

(defenum SpannedSexpr
  (Int i64 ci.InternId token.SourceSpan)
  (Sym ci.InternSyntaxId token.SourceSpan)
  (List i64 i64 token.SourceSpan)
  (Str ci.InternId token.SourceSpan)
  (Char char token.SourceSpan)
  (Float ci.InternId token.SourceSpan)
  (BracketList i64 i64 token.SourceSpan))

(defenum SpannedSexprView
  (Int i64 String token.SourceSpan)
  (Sym ci.InternSyntaxId token.SourceSpan)
  (List (& program (Slice SpannedSexpr)) token.SourceSpan)
  (Str ci.InternId token.SourceSpan)
  (Char char token.SourceSpan)
  (Float String token.SourceSpan)
  (BracketList (& program (Slice SpannedSexpr)) token.SourceSpan))

(defenum ResultSpannedSexpr
  (Ok SpannedSexpr)
  (Err token.SourceError))

;; --- flat SpannedSexpr child-node pool ---
;; List children are contiguous row ids into the pool. Rows live in fixed-size
;; segments that are never moved or freed while the pool is live: growing the
;; pool adds a segment, and only the small segment directory is reallocated.
;; A borrowed slice of a list's children therefore stays valid while the
;; parser and the macro expander keep pushing rows. A list never straddles a
;; segment: one that would cross a boundary starts at the next segment, and
;; the skipped rows hold `sp-node-filler` (an `Int` that no origin scan
;; matches). A list longer than a segment gets a dedicated array, which the
;; directory maps from every slot the list covers. Only a handoff
;; (`sp-node-pool-compact-retained!`) moves rows, and the driver calls it
;; between phases, when no reader traversal is in progress.
;;
;; Plain globals, NOT a struct, avoid the opt2 hot-path-inline miscompile seen
;; on the AstExpr pool. The spanned tree is transient (consumed into AstExpr,
;; spans copied out by value, then dead), so the pool is reset per program
;; parse (see compiler_parse_core.tl). Start empty: small compile commands
;; should not construct a large pool of enum slots before argv dispatch.
;; Dedicated storage keeps the globals valid across transient driver arenas.
;; The pool cannot be retired once a load has finished, because its origin
;; records outlive parsing.
;; Small segments keep a compacted pool close to its live rows: a handoff keeps
;; whole segments, and the lifetime ledger counts what it keeps.
(define sp-node-segment-bits : i64
  10)
(define sp-node-segment-rows : i64
  1024)

;; Slot `s` covers row ids [s * rows, (s + 1) * rows). Per slot: the array that
;; holds the slot's rows, that array's first row id, and the address row 0
;; would have in that array, so a row reads with one directory load.
(define sp-node-pool-segments : (__tl_dyn-array (__tl_dyn-array SpannedSexpr))
  (__tl_make-array (__tl_dyn-array SpannedSexpr) 0))
(define sp-node-pool-segment-starts : (__tl_dyn-array i64)
  (__tl_make-array i64 0))
(define sp-node-pool-segment-bases : (__tl_dyn-array i64)
  (__tl_make-array i64 0))

;; Slots [0, sp-node-pool-slot-count) have storage.
(define sp-node-pool-slot-count : i64
  0)

;; Current head of the dedicated backing arena, or zero before first use.
(define sp-node-pool-base-arena : i64
  0)

;; Only the handoff creates an exclusive row/builder owner. Reset revokes that
;; ownership before a new reader session can place other storage in the arena.
(define sp-node-pool-retained-arena : i64
  0)
(define sp-node-pool-count : i64
  0)
(define sp-node-pool-reset-generation : i64
  0)
(define sp-builder-slots : (__tl_dyn-array SpannedSexpr)
  (__tl_make-array SpannedSexpr 0))
(define sp-builder-count : i64
  0)

;; Permanent zero-length replacements used when a retained-origin compaction
;; finds no live rows. These are allocated by global initialization and
;; therefore remain valid after a reader-owned growth arena is destroyed.
(define sp-builder-released-slots : (__tl_dyn-array SpannedSexpr)
  (__tl_make-array SpannedSexpr 0))
(define sp-node-pool-released-segments : (__tl_dyn-array
    (__tl_dyn-array SpannedSexpr))
  (__tl_make-array (__tl_dyn-array SpannedSexpr) 0))
(define sp-node-pool-released-starts : (__tl_dyn-array i64)
  (__tl_make-array i64 0))
(define sp-node-pool-released-bases : (__tl_dyn-array i64)
  (__tl_make-array i64 0))

;; Set while `data-result` reads: no projection suffixes, and the plain data
;; reader's error texts.
(define sp-reader-data-mode? : bool
  false)

(define (sp-node-pool-base-arena-handle-value) : i64
  sp-node-pool-base-arena)

;; Source symbols remain ids from lexer through reader and parser. Consumers
;; request display text explicitly only when diagnostics or data formats need it.
;: Preserve the lexer-assigned id across the reader/parser boundary.
(define (symbol-id [name-id : ci.InternSyntaxId]) : i64
  (ci.intern-syntax-id-value name-id))

;: Intern a process-stable parser literal once and memoize its String object.
(define (stable-symbol-id [text : String]) : i64
  (ci.intern-source-slice text 0 (ci.intern-private-string-length text)))

(define (stable-syntax-id [text : String]) : ci.InternSyntaxId
  (ci.intern-syntax-id-from-renderable
    (ci.intern-source-slice-id text 0 (ci.intern-private-string-length text))))

(define (symbol-text-for-syntax-id [id : ci.InternSyntaxId]) : String
  (ci.intern-syntax-id-text id))

(define (sp-node-pool-len) : i64
  sp-node-pool-count)

;; Rows the pool can hold without adding a segment.
(define (sp-node-pool-capacity) : i64
  (* sp-node-pool-slot-count sp-node-segment-rows))

(define (sp-node-pool-reset-generation-value) : i64
  sp-node-pool-reset-generation)

(define (sp-node-pool-retained?) : bool
  (and
    (!= sp-node-pool-base-arena 0)
    (= sp-node-pool-retained-arena sp-node-pool-base-arena)))

;; The row a list's skipped tail rows hold.
(define (sp-node-filler) : SpannedSexpr
  (Int 0 (sp-text-id "") (token.SourceSpan 0 0 0 0)))

(define (sp-node-pool-segment [slot : i64]) : (__tl_dyn-array SpannedSexpr)
  (unsafe
    (ptr-read
      (ptr-offset
        (ptr-cast
          (__tl_array-data sp-node-pool-segments)
          : (Ptr (__tl_dyn-array SpannedSexpr)))
        slot))))

;; The address row 0 would have in `segment`, whose first row is `start`.
(define (sp-node-pool-segment-base
  [segment : (__tl_dyn-array SpannedSexpr)]
  [start : i64]) : i64
  (cast
    (unsafe
      (ptr->int
        (ptr-offset
          (ptr-cast (__tl_array-data segment) : (Ptr SpannedSexpr))
          (- 0 start))))
    : i64))

;; Room for `slots` directory entries, in the pool's arena.
(define (sp-node-pool-directory-reserve! [slots : i64]) : unit
  (when
    (< (array-length sp-node-pool-segments) slots)
    (let
      [old-cap : i64 (array-length sp-node-pool-segments)]
      [new-cap : i64
        (if (< (* old-cap 2) slots)
          (if (< slots 64)
            64
            slots)
          (* old-cap 2))]
      [segments : (__tl_dyn-array (__tl_dyn-array SpannedSexpr))
        (__tl_make-array (__tl_dyn-array SpannedSexpr) new-cap)]
      [starts : (__tl_dyn-array i64) (__tl_make-array i64 new-cap)]
      [bases : (__tl_dyn-array i64) (__tl_make-array i64 new-cap)]
      [i : i64 0]
      (while (< i sp-node-pool-slot-count)
        (set! (array-ref segments i) (sp-node-pool-segment i))
        (set! (array-ref starts i) (array-ref sp-node-pool-segment-starts i))
        (set! (array-ref bases i) (array-ref sp-node-pool-segment-bases i))
        (set! i (+ i 1)))
      (set! sp-node-pool-segments segments)
      (set! sp-node-pool-segment-starts starts)
      (set! sp-node-pool-segment-bases bases))))

;; Point slot `slot` at `segment`, whose first row id is `start`.
(define (sp-node-pool-install-slot!
  [slot : i64]
  [segment : (__tl_dyn-array SpannedSexpr)]
  [start : i64]) : unit
  (set!
    (array-ref sp-node-pool-segment-bases slot)
    (sp-node-pool-segment-base
      (unsafe
        (ptr-read (ptr-addr-of segment)))
      start))
  (set! (array-ref sp-node-pool-segment-starts slot) start)
  (set! (array-ref sp-node-pool-segments slot) segment))

;; Allocate storage in the pool's arena (creating it on first use) so a grow
;; from a transient file/test arena cannot leave the globals dangling.
(define (sp-node-pool-storage-root) : i64
  (if (= sp-node-pool-base-arena 0)
    (let
      [root : i64 (arena.tl_arena_make)]
      (set! sp-node-pool-base-arena root)
      root)
    sp-node-pool-base-arena))

;; Add one segment after the last slot with storage. Earlier rows stay where
;; they are.
(define (sp-node-pool-grow!) : unit
  (let
    [slot : i64 sp-node-pool-slot-count]
    (in-arena
      (arena.Arena (sp-node-pool-storage-root))
      (sp-node-pool-directory-reserve! (+ slot 1))
      (sp-node-pool-install-slot!
        slot
        (__tl_make-array SpannedSexpr sp-node-segment-rows)
        (* slot sp-node-segment-rows))
      (set! sp-node-pool-slot-count (+ slot 1)))))

;; Storage for every row id below `end`.
(define (sp-node-pool-ensure! [end : i64]) : unit
  (while (< (sp-node-pool-capacity) end)
    (sp-node-pool-grow!)))

(define (sp-builder-grow!) : unit
  (let
    [old-cap : i64 (array-length sp-builder-slots)]
    [new-cap : i64
      (if (< old-cap 1)
        1024
        (* old-cap 2))]
    (in-arena
      (arena.Arena (sp-node-pool-storage-root))
      (let
        [new-slots : (__tl_dyn-array SpannedSexpr)
          (__tl_make-array SpannedSexpr new-cap)]
        [i : i64 0]
        (while (< i sp-builder-count)
          (set! (array-ref new-slots i) (sp-builder-shared-view i))
          (set! i (+ i 1)))
        (set! sp-builder-slots new-slots)))))

(define (sp-node-push [node : SpannedSexpr]) : i64
  (let
    [id : i64 sp-node-pool-count]
    (when (>= id (sp-node-pool-capacity)) (sp-node-pool-grow!))
    (sp-node-pool-fill! id node)
    (set! sp-node-pool-count (+ id 1))
    id))

;; Reserve one contiguous range for cold parser metadata that already knows its
;; final row count. Callers fill the reserved rows with `sp-node-pool-fill!`;
;; avoiding one capacity check and global count update per row matters for large
;; semantic sidecars while preserving the pool's single growth discipline. The
;; range is read row by row, never as a slice, so it may cross a segment.
(define (sp-node-pool-reserve! [additional : i64]) : i64
  (let
    [start : i64 sp-node-pool-count]
    [required : i64 (+ start additional)]
    (sp-node-pool-ensure! required)
    (set! sp-node-pool-count required)
    start))

;; Write one row that `sp-node-pool-reserve!` already reserved (or an existing
;; row being rewritten in place). Only this module writes the pool globals.
(define (sp-node-pool-fill! [id : i64] [node : SpannedSexpr]) : unit
  (let
    [slot : i64 (shr id sp-node-segment-bits)]
    [segment : (__tl_dyn-array SpannedSexpr) (sp-node-pool-segment slot)]
    (set!
      (array-ref segment (- id (array-ref sp-node-pool-segment-starts slot)))
      node)))

;; The first row of a new list of `length` rows, with room made for all of
;; them in one array: a list that would cross into the next slot starts there
;; (the rows it skips hold the filler), and a list longer than a segment gets
;; a dedicated array.
(define (sp-node-pool-list-start! [length : i64]) : i64
  (let
    [start : i64 sp-node-pool-count]
    [rows : i64 sp-node-segment-rows]
    [slot : i64 (shr start sp-node-segment-bits)]
    [offset : i64 (- start (* slot rows))]
    (cond
      [(<= length 0) start]
      [(<= (+ offset length) rows)
        (sp-node-pool-ensure! (+ start length))
        start]
      [else
        (let
          [boundary : i64
            (if (= offset 0)
              start
              (* (+ slot 1) rows))]
          (sp-node-pool-ensure! boundary)
          (while (< sp-node-pool-count boundary)
            (sp-node-pool-fill! sp-node-pool-count (sp-node-filler))
            (set! sp-node-pool-count (+ sp-node-pool-count 1)))
          (if (<= length rows)
            (sp-node-pool-ensure! (+ boundary length))
            (sp-node-pool-install-long! boundary length))
          boundary)])))

;; One array for a list of `length` rows starting at slot boundary `start`,
;; mapped from every slot it covers. Rows at and above the pool count are dead,
;; so slots that already had storage may be reused or repointed. Search the
;; covered slots for an array spanning the complete range, then restore all
;; its mappings. A prior suffix replacement may have fragmented the directory
;; without changing the backing arrays or the live prefix's addresses.
(define (sp-node-pool-install-long! [start : i64] [length : i64]) : unit
  (let
    [rows : i64 sp-node-segment-rows]
    [first : i64 (shr start sp-node-segment-bits)]
    [slots : i64 (/ (+ length (- rows 1)) rows)]
    [end-slot : i64 (+ first slots)]
    [allocation-slots : i64 1]
    [reuse-slot : i64 -1]
    [candidate : i64 first]
    ;; Geometric array capacity bounds retained allocation when successive
    ;; forms grow beyond the preceding long list's storage.
    (while (< allocation-slots slots)
      (set! allocation-slots (* allocation-slots 2)))
    (while (and
      (= reuse-slot -1)
      (< candidate end-slot)
      (< candidate sp-node-pool-slot-count))
      (let
        [candidate-start : i64
          (array-ref sp-node-pool-segment-starts candidate)]
        [segment : (__tl_dyn-array SpannedSexpr)
          (sp-node-pool-segment candidate)]
        (when
          (and
            (<= candidate-start start)
            (<= (+ (- start candidate-start) length) (array-length segment)))
          (set! reuse-slot candidate)))
      (set! candidate (+ candidate 1)))
    (in-arena
      (arena.Arena (sp-node-pool-storage-root))
      (let
        [long : (__tl_dyn-array SpannedSexpr)
          (if (= reuse-slot -1)
            (__tl_make-array SpannedSexpr (* allocation-slots rows))
            (sp-node-pool-segment reuse-slot))]
        [long-start : i64
          (if (= reuse-slot -1)
            start
            (array-ref sp-node-pool-segment-starts reuse-slot))]
        [slot : i64 first]
        (sp-node-pool-ensure! start)
        (sp-node-pool-directory-reserve! end-slot)
        (while (< slot end-slot)
          (sp-node-pool-install-slot!
            slot
            (unsafe
              (ptr-read (ptr-addr-of long)))
            long-start)
          (set! slot (+ slot 1)))
        (when
          (< sp-node-pool-slot-count end-slot)
          (set! sp-node-pool-slot-count end-slot))))))

;; Reader nodes and builder rows live in the reader's arena-backed pools. These
;; compatibility accessors expose immutable/shared views without transferring
;; ownership out of their global storage.
(define (sp-node-pool-shared-view [id : i64]) : SpannedSexpr
  (unsafe
    (ptr-read
      (ptr-offset
        (int->ptr
          (ptr-read
            (ptr-offset
              (ptr-cast
                (__tl_array-data sp-node-pool-segment-bases)
                : (Ptr i64))
              (shr id sp-node-segment-bits)))
          : (Ptr SpannedSexpr))
        id))))

(define (sp-builder-shared-view [id : i64]) : SpannedSexpr
  (unsafe
    (ptr-read
      (ptr-offset
        (ptr-cast (__tl_array-data sp-builder-slots) : (Ptr SpannedSexpr))
        id))))

(define (sp-node-get [id : i64]) : SpannedSexpr
  (sp-node-pool-shared-view id))

(define (sp-node-pool-truncate! [mark : i64]) : unit
  (set! sp-node-pool-count mark))

(define (sp-node-pool-reset!) : unit
  (sp-node-pool-truncate! 0)
  (set! sp-builder-count 0)
  (set! sp-node-pool-retained-arena 0)
  (set! sp-node-pool-reset-generation (+ sp-node-pool-reset-generation 1)))

;; Row ids and builder ranges name indices, never backing-array addresses.
;; Payloads belong to source/interner owners; neither array owns their strings.
;; A handoff proves only origin records remain. It copies the live rows into an
;; exact owner, keeping every row id and slot, and frees the old storage; it is
;; the only place rows move.
(define (sp-node-pool-rehome! [builder-capacity : i64]) : unit
  (let
    [retire-arena : i64 sp-node-pool-base-arena]
    [rows : i64 sp-node-segment-rows]
    [live-slots : i64 (/ (+ sp-node-pool-count (- rows 1)) rows)]
    [old-segments : (__tl_dyn-array (__tl_dyn-array SpannedSexpr))
      (unsafe
        (ptr-read (ptr-addr-of sp-node-pool-segments)))]
    [old-starts : (__tl_dyn-array i64)
      (unsafe
        (ptr-read (ptr-addr-of sp-node-pool-segment-starts)))]
    [transfer-arena : i64
      (if (or (> live-slots 0) (> builder-capacity 0))
        (arena.tl_arena_make)
        0)]
    [next-builders : (__tl_dyn-array SpannedSexpr)
      (if (= transfer-arena 0)
        (unsafe
          (ptr-read (ptr-addr-of sp-builder-released-slots)))
        (in-arena
          (arena.Arena transfer-arena)
          (__tl_make-array SpannedSexpr builder-capacity)))]
    [index : i64 0]
    (set!
      sp-node-pool-segments
      (unsafe
        (ptr-read (ptr-addr-of sp-node-pool-released-segments))))
    (set!
      sp-node-pool-segment-starts
      (unsafe
        (ptr-read (ptr-addr-of sp-node-pool-released-starts))))
    (set!
      sp-node-pool-segment-bases
      (unsafe
        (ptr-read (ptr-addr-of sp-node-pool-released-bases))))
    (set! sp-node-pool-slot-count 0)
    (when
      (> live-slots 0)
      (in-arena
        (arena.Arena transfer-arena)
        (let
          [slot : i64 0]
          (sp-node-pool-directory-reserve! live-slots)
          (while (< slot live-slots)
            (let
              [old : (__tl_dyn-array SpannedSexpr)
                (unsafe
                  (ptr-read
                    (ptr-offset
                      (ptr-cast
                        (__tl_array-data old-segments)
                        : (Ptr (__tl_dyn-array SpannedSexpr)))
                      slot)))]
              [old-start : i64 (array-ref old-starts slot)]
              [slot-start : i64 (* slot rows)]
              ;; The live part of an array that begins at this slot is copied
              ;; as one (a long list's array covers its later slots too, as
              ;; long as they still map to it); a slot left over from an
              ;; array that began earlier gets its own segment.
              [covered : i64
                (if (= old-start slot-start)
                  (let
                    [limit : i64 (/ (array-length old) rows)]
                    [k : i64 1]
                    (while (and
                      (< k limit)
                      (< (+ slot k) live-slots)
                      (= (array-ref old-starts (+ slot k)) old-start))
                      (set! k (+ k 1)))
                    k)
                  1)]
              [from : i64 (- slot-start old-start)]
              [copy : (__tl_dyn-array SpannedSexpr)
                (__tl_make-array SpannedSexpr (* covered rows))]
              [row : i64 0]
              [mapped : i64 0]
              (while (and
                (< row (* covered rows))
                (< (+ slot-start row) sp-node-pool-count))
                (set!
                  (array-ref copy row)
                  (unsafe
                    (ptr-read
                      (ptr-offset
                        (ptr-cast (__tl_array-data old) : (Ptr SpannedSexpr))
                        (+ from row)))))
                (set! row (+ row 1)))
              (while (< mapped covered)
                (sp-node-pool-install-slot!
                  (+ slot mapped)
                  (unsafe
                    (ptr-read (ptr-addr-of copy)))
                  slot-start)
                (set! mapped (+ mapped 1)))
              (set! slot (+ slot covered))
              (set! sp-node-pool-slot-count slot))))))
    (while (< index sp-builder-count)
      (set! (array-ref next-builders index) (sp-builder-shared-view index))
      (set! index (+ index 1)))
    (set! sp-builder-slots next-builders)
    (set! sp-node-pool-base-arena transfer-arena)
    (set! sp-node-pool-retained-arena transfer-arena)
    ;; Normalize a current segment to its root before comparing owners. Even
    ;; an empty transfer must detach a current retiring arena before destroy.
    (unsafe
      (arena.tl_arena_set (arena.tl_arena_current))
      (if (= (arena.tl_arena_current) retire-arena)
        (arena.tl_arena_set transfer-arena)
        unit)
      (unless (= retire-arena 0) (arena.tl_arena_destroy retire-arena)))))

(cfg
  compile-profile
  (define (sp-node-pool-profile-retained!) : unit
    (when
      (sp-node-pool-retained?)
      (let
        [bytes : i64
          (allocation_profile.compiler-allocation-profile-arena-bump-bytes
            sp-node-pool-base-arena)]
        (with-scratch
          (io.print-error
            (str_cat.str-cat
              "compile-profile|reader.retained.rows|"
              (string.int->string sp-node-pool-count)
              "|0|0|0\n"
              "compile-profile|reader.retained.capacity|"
              (string.int->string (sp-node-pool-capacity))
              "|0|0|0\n"
              "compile-profile|reader.retained.row_bytes|"
              (string.int->string (comptime (size-of (type SpannedSexpr))))
              "|0|0|0\n"
              "compile-profile|reader.retained.arena_bytes|"
              (string.int->string bytes)
              "|0|0|0\n")))))))

;; Re-home the live spanned-node prefix in an exact transfer owner. At a
;; whole-program load handoff, parser compaction has removed every source form
;; and left only declaration/member/semantic-origin marker rows. The segments
;; still cover the largest transient form, however, and otherwise retain that
;; broad read arena through macro expansion.
;;
;; Row ids deliberately remain unchanged: every origin side table names this
;; dense prefix by integer range, never by backing-array address. No builder may
;; be live at the handoff; accepting one would preserve an in-flight reader form
;; whose list ranges are not part of the origin transfer graph. Nothing reads
;; the pool across the handoff either: the driver calls it between phases.
(define (sp-node-pool-compact-retained!) : unit
  (if (= sp-node-pool-base-arena 0)
    unit
    (let
      [rows : i64 sp-node-segment-rows]
      [live-slots : i64 (/ (+ sp-node-pool-count (- rows 1)) rows)]
      [builder-capacity : i64 (array-length sp-builder-slots)]
      (if (!= sp-builder-count 0)
        (io.panic "reader: cannot compact retained origins with a live builder")
        (begin
          (cfg compile-profile (sp-node-pool-profile-retained!) unit)
          (unless
            (and
              (sp-node-pool-retained?)
              (= sp-node-pool-slot-count live-slots)
              (= builder-capacity 0))
            (sp-node-pool-rehome! 0)))))))

(defstruct SpannedSexprBuilder
  (start i64))

(define (spanned-sexpr-builder-new) : SpannedSexprBuilder
  (SpannedSexprBuilder sp-builder-count))

(define (spanned-sexpr-builder-push
  [builder : SpannedSexprBuilder]
  [item : SpannedSexpr]) : SpannedSexprBuilder
  (if (>= sp-builder-count (array-length sp-builder-slots))
    (sp-builder-grow!)
    unit)
  (set! (array-ref sp-builder-slots sp-builder-count) item)
  (set! sp-builder-count (+ sp-builder-count 1))
  builder)

;; The builder's rows become one list, placed so its children share an array.
(define (spanned-sexpr-list-from-builder
  [builder : SpannedSexprBuilder]
  [span : token.SourceSpan]) : SpannedSexpr
  (let
    [builder-start : i64 builder.start]
    [len : i64 (- sp-builder-count builder-start)]
    [start : i64 (sp-node-pool-list-start! len)]
    [i : i64 0]
    (while (< i len)
      (sp-node-pool-fill!
        (+ start i)
        (sp-builder-shared-view (+ builder-start i)))
      (set! i (+ i 1)))
    (set! sp-node-pool-count (+ start len))
    (set! sp-builder-count builder-start)
    (List start len span)))

(define (spanned-sexpr-builder-discard! [builder : SpannedSexprBuilder]) : unit
  (set! sp-builder-count builder.start))

(define (spanned-sexpr-builder-extend
  [builder : SpannedSexprBuilder]
  [items : SpannedSexpr]) : SpannedSexprBuilder
  (match items
    [(List start length _)
      (let
        [out : SpannedSexprBuilder builder]
        [i : i64 0]
        (while (< i length)
          (set! out (spanned-sexpr-builder-push out (sp-node-get (+ start i))))
          (set! i (+ i 1)))
        out)]
    [_ (io.panic "reader: list builder extend requires a proper list")]))

(define (spanned-sexpr-list1 [a : SpannedSexpr] [span : token.SourceSpan]) : SpannedSexpr
  (spanned-sexpr-list-from-builder
    (spanned-sexpr-builder-push (spanned-sexpr-builder-new) a)
    span))

(define (spanned-sexpr-list2
  [a : SpannedSexpr]
  [b : SpannedSexpr]
  [span : token.SourceSpan]) : SpannedSexpr
  (spanned-sexpr-list-from-builder
    (spanned-sexpr-builder-push
      (spanned-sexpr-builder-push (spanned-sexpr-builder-new) a)
      b)
    span))

(define (spanned-sexpr-list3
  [a : SpannedSexpr]
  [b : SpannedSexpr]
  [c : SpannedSexpr]
  [span : token.SourceSpan]) : SpannedSexpr
  (spanned-sexpr-list-from-builder
    (spanned-sexpr-builder-push
      (spanned-sexpr-builder-push
        (spanned-sexpr-builder-push (spanned-sexpr-builder-new) a)
        b)
      c)
    span))

(define (spanned-sexpr-list4
  [a : SpannedSexpr]
  [b : SpannedSexpr]
  [c : SpannedSexpr]
  [d : SpannedSexpr]
  [span : token.SourceSpan]) : SpannedSexpr
  (spanned-sexpr-list-from-builder
    (spanned-sexpr-builder-push
      (spanned-sexpr-builder-push
        (spanned-sexpr-builder-push
          (spanned-sexpr-builder-push (spanned-sexpr-builder-new) a)
          b)
        c)
      d)
    span))

(define (spanned-sexpr-empty [span : token.SourceSpan]) : SpannedSexpr
  (List (sp-node-pool-len) 0 span))

(define (spanned-sexpr-list-prepend
  [head : SpannedSexpr]
  [tail : SpannedSexpr]
  [span : token.SourceSpan]) : SpannedSexpr
  (match tail
    [(List start length _)
      (let
        [builder : SpannedSexprBuilder
          (spanned-sexpr-builder-push (spanned-sexpr-builder-new) head)]
        [i : i64 0]
        (while (< i length)
          (set!
            builder
            (spanned-sexpr-builder-push builder (sp-node-get (+ start i))))
          (set! i (+ i 1)))
        (spanned-sexpr-list-from-builder builder span))]
    [_ (io.panic "reader: list prepend requires a proper list")]))

(define (spanned-sexpr-bracket-list
  [items : SpannedSexpr]
  [span : token.SourceSpan]) : SpannedSexpr
  (match items
    [(List start length _) (BracketList start length span)]
    [_ (io.panic "reader: bracket form requires a proper list")]))

;; The empty spelling's id, cached per intern table like the compiler's builtin
;; ids: a reset or a table switch looks it up again.
(define sp-text-empty-id : i64
  -1)
(define sp-text-empty-generation : i64
  -1)
(define sp-text-empty-table : i64
  -1)

;; The intern id of an Int or Float row's source spelling.
(define (sp-text-id [text : (& text str)]) : ci.InternId
  (let
    [length : i64 (ci.intern-private-string-length text)]
    (if (> length 0)
      (ci.intern-source-slice-id text 0 length)
      (begin
        (unless
          (and
            (= sp-text-empty-generation (ci.intern-generation))
            (= sp-text-empty-table (ci.intern-active-table-id)))
          (set! sp-text-empty-id (ci.intern-source-slice text 0 0))
          (set! sp-text-empty-generation (ci.intern-generation))
          (set! sp-text-empty-table (ci.intern-active-table-id)))
        (ci.intern-id-from-renderable sp-text-empty-id)))))

;; The spelling as a shared view of the intern table's String.
(define (sp-text [id : ci.InternId]) : String
  (ci.intern-id-str id))

;; A spelling that must outlive the intern table. The empty spelling stays the
;; static literal, as `token.int-text` returns it.
(define (sp-text-copy [text : String]) : String
  (if (= (string.string-length text) 0)
    ""
    (string.copy text)))

;; --- views ---
;; A view's `List` holds a list's children as one borrowed slice of pool rows.
;; Rows never move while the pool is live: only a handoff
;; (`sp-node-pool-compact-retained!`) copies them, and the driver runs it
;; between phases, never during a traversal. A view therefore outlives the
;; traversal that holds it, but it must not be kept across a handoff. It is
;; typed `program` because no shorter owner can be named for the global pool.
;; The (data address, length) header that `sp-node-items` reads as a slice. An
;; empty list points at a static empty array.
(define sp-node-items-header : (__tl_dyn-array i64)
  (__tl_make-array i64 2))
(define sp-node-items-empty : (__tl_dyn-array SpannedSexpr)
  (__tl_make-array SpannedSexpr 0))

(define (sp-node-items-header! [start : i64] [length : i64]) : unit
  (if (> length 0)
    (begin
      (set!
        (array-ref sp-node-items-header 0)
        (cast
          (unsafe
            (ptr->int
              (ptr-offset
                (int->ptr
                  (array-ref
                    sp-node-pool-segment-bases
                    (shr start sp-node-segment-bits))
                  : (Ptr SpannedSexpr))
                start)))
          : i64))
      (set! (array-ref sp-node-items-header 1) length))
    (begin
      (set!
        (array-ref sp-node-items-header 0)
        (cast
          (unsafe
            (ptr->int
              (ptr-cast (__tl_array-data sp-node-items-empty) : (Ptr u8))))
          : i64))
      (set! (array-ref sp-node-items-header 1) 0))))

;; The `length` rows from `start` as one slice, read back from the header.
(define (sp-node-items [start : i64] [length : i64]) : (&
    program
    (Slice SpannedSexpr))
  (sp-node-items-header! start length)
  (unsafe
    (ptr-read
      (ptr-cast
        (__tl_array-data sp-node-items-header)
        : (Ptr (& program (Slice SpannedSexpr)))))))

;; A node as consumers match on it: a list is one `List` of its children.
(define (spanned-sexpr-view [s : SpannedSexpr]) : SpannedSexprView
  (match s
    [(Int n text span) (Int n (sp-text text) span)]
    [(Sym name span) (Sym name span)]
    [(List start length span) (List (sp-node-items start length) span)]
    [(Str text span) (Str text span)]
    [(Char c span) (Char c span)]
    [(Float text span) (Float (sp-text text) span)]
    [(BracketList start length span)
      (BracketList (sp-node-items start length) span)]))

;; Like `spanned-sexpr-view` without spans; a bracket list is a `List` too.
(define (sexpr-view [s : SpannedSexpr]) : SexprView
  (match s
    [(Int n text _) (Int n (sp-text text))]
    [(Sym name _) (Sym name)]
    [(List start length _) (List (sp-node-items start length))]
    [(Str text _) (Str text)]
    [(Char c _) (Char c)]
    [(Float text _) (Float (sp-text text))]
    [(BracketList start length _) (List (sp-node-items start length))]))

;; The list after its first `count` children as a node, with the list's span.
;; A slice pattern binds its rest as `& _` and takes the tail here when a helper
;; needs it as a node.
(define (spanned-sexpr-drop [s : SpannedSexpr] [count : i64]) : SpannedSexpr
  (match s
    [(List start length span) (List (+ start count) (- length count) span)]
    [(BracketList start length span)
      (List (+ start count) (- length count) span)]
    [_ (io.panic "reader: spanned-sexpr-drop expects a list")]))

;; A parenthesized list's children, and no items for any other node: what the
;; `List` of `spanned-sexpr-view` carries. A list walker's entry hands a
;; node to its slice walker through this when a non-list behaves like `()`.
(define (spanned-sexpr-items [s : SpannedSexpr]) : (&
    program
    (Slice SpannedSexpr))
  (match s
    [(List start length _) (sp-node-items start length)]
    [_ (sp-node-items 0 0)]))

;; Like `spanned-sexpr-items`, but a bracket list's children count too, as in
;; `sexpr-view`.
(define (sexpr-items [s : SpannedSexpr]) : (& program (Slice SpannedSexpr))
  (match s
    [(List start length _) (sp-node-items start length)]
    [(BracketList start length _) (sp-node-items start length)]
    [_ (sp-node-items 0 0)]))

(define (spanned-sexpr-span [s : SpannedSexpr]) : token.SourceSpan
  (match s
    [(Int _ _ span) span]
    [(Sym _ span) span]
    [(List _ _ span) span]
    [(Str _ span) span]
    [(Char _ span) span]
    [(Float _ span) span]
    [(BracketList _ _ span) span]))

;; --------------------------------------------------------------------------
;; The reader cursor: a single mutable index into the
;; `(__tl_dyn-array token.SpannedToken)`.
;; --------------------------------------------------------------------------
;; A TypeLisp function returns a single value, but the reader must both *return
;; a form* and *advance past the tokens it consumed*. So the position is an
;; out-param: a mutable reference to a single-cell `(__tl_dyn-array i64)`
;; (`cur`) holding the index of the token under the cursor.
;; Current cursor position (index of the token under the cursor).
(define (cur-pos [cur : (& cur (__tl_dyn-array i64))]) : i64
  (array-ref cur 0))

(define (peek-spanned-tag
  [toks : (& toks (__tl_dyn-array token.SpannedToken))]
  [cur : (& cur (__tl_dyn-array i64))]) : i64
  (token.tag-ref
    (token.spanned-token-token-ref (& (array-ref toks (cur-pos cur))))))

;; Consume the current token: advance the cursor by one.
(define (advance [cur : (&mut cur (__tl_dyn-array i64))]) : unit
  (set! (array-ref cur 0) (+ (cur-pos cur) 1)))

(define (prefix-tag? [t : i64]) : bool
  (or
    (= t (token.tag-quote))
    (= t (token.tag-backtick))
    (= t (token.tag-comma))
    (= t (token.tag-comma-at))))

(define (prefix-symbol [t : i64]) : ci.InternSyntaxId
  (cond
    [(= t (token.tag-quote)) (stable-syntax-id "quote")]
    [(= t (token.tag-backtick)) (stable-syntax-id "quasiquote")]
    [(= t (token.tag-comma)) (stable-syntax-id "unquote")]
    [(= t (token.tag-comma-at)) (stable-syntax-id "unquote-splicing")]
    [else (stable-syntax-id "quote")]))

(define (prefix-spanned-form
  [name : ci.InternSyntaxId]
  [prefix-span : token.SourceSpan]
  [form : SpannedSexpr]) : SpannedSexpr
  (let
    [span : token.SourceSpan
      (token.merge-spans
        prefix-span
        (spanned-sexpr-span
          (unsafe
            (ptr-read (ptr-addr-of form)))))]
    (spanned-sexpr-list-from-builder
      (spanned-sexpr-builder-push
        (spanned-sexpr-builder-push
          (spanned-sexpr-builder-new)
          (Sym name prefix-span))
        form)
      span)))

(define (close-delimiter-text [tag : i64]) : String
  (if (= tag (token.tag-rparen))
    ")"
    (if (= tag (token.tag-rbracket))
      "]"
      "?")))

(define (quoted-close-delimiter [tag : i64]) : String
  (str_cat.str-cat "'" (close-delimiter-text tag) "'"))

(define (opposite-close-delimiter? [tag : i64] [expected : i64]) : bool
  (if (= expected (token.tag-rparen))
    (= tag (token.tag-rbracket))
    (if (= expected (token.tag-rbracket))
      (= tag (token.tag-rparen))
      false)))

(define (span-location [span : token.SourceSpan]) : String
  (str_cat.str-cat
    (string.int->string (token.span-start-line span))
    ":"
    (string.int->string (token.span-start-col span))))

(define (unterminated-list-message [expected : i64]) : String
  (if sp-reader-data-mode?
    (str_cat.str-cat
      "reader: unterminated list (missing "
      (quoted-close-delimiter expected)
      ")")
    (str_cat.str-cat
      "reader: unterminated list: reached end of input before "
      (quoted-close-delimiter expected))))

(define (mismatched-close-message
  [expected : i64]
  [actual : i64]
  [actual-span : token.SourceSpan]) : String
  (str_cat.str-cat
    "reader: mismatched delimiter: expected "
    (quoted-close-delimiter expected)
    " but found "
    (quoted-close-delimiter actual)
    " at "
    (span-location actual-span)))

;; --------------------------------------------------------------------------
;; The reader proper: forms and lists, mutually recursive.
;; --------------------------------------------------------------------------
;; form-spanned-result: read exactly one s-expression starting at the cursor
;; and return it, advancing the cursor past the tokens it consumed.
;;   token.Token.Int n text -> SpannedSexpr.Int  an integer atom with source spelling
;;   token.Token.Float s -> SpannedSexpr.Float   a float atom carrying source text
;;   token.Token.Sym s -> SpannedSexpr.Sym       a symbol atom
;;   token.Token.Str s -> SpannedSexpr.Str       a string-literal atom (`"..."`)
;;   token.Token.Char c -> SpannedSexpr.Char     a character-literal atom (`'x'`)
;;   token.Token.LParen -> list-spanned-result   consume '(' then read a list to its ')'
;;   token.Token.RParen -> error                 a stray ')' with no opening '(' is malformed
;;   token.Token.End -> error                    end of stream where a form was expected
;; A grammar violation returns a recoverable `ResultSpannedSexpr.Err`.
(define (form-spanned-result
  [toks : (& toks (__tl_dyn-array token.SpannedToken))]
  [cur : (&mut cur (__tl_dyn-array i64))]) : ResultSpannedSexpr
  (let
    [st : (& toks token.SpannedToken) (& (array-ref toks (cur-pos cur)))]
    [tok : (& toks token.Token) (token.spanned-token-token-ref st)]
    [span : token.SourceSpan (token.spanned-token-span st)]
    [t : i64 (token.tag-ref tok)]
    (cond
      [(= t (token.tag-int))
        (let
          [value : i64 (token.int tok)]
          [text : String (token.int-text tok)]
          (advance cur)
          (Ok (Int value (sp-text-id text) span)))]
      [(= t (token.tag-float))
        (let
          [text : String (token.float tok)]
          (advance cur)
          (Ok (Float (sp-text-id text) span)))]
      [(= t (token.tag-sym))
        (let
          [name-id : ci.InternId (token.sym-id tok)]
          (advance cur)
          (Ok (Sym (ci.intern-syntax-id-from-renderable name-id) span)))]
      [(= t (token.tag-str))
        (let
          [string-id : ci.InternId (token.str-id tok)]
          (advance cur)
          (Ok (Str string-id span)))]
      [(= t (token.tag-char))
        (let
          [value : char (token.char tok)]
          (advance cur)
          (Ok (Char value span)))]
      [(= t (token.tag-lparen))
        (advance cur)
        (form-spanned-compound-result
          toks
          cur
          (list-spanned-result toks cur span))]
      [(= t (token.tag-lbracket))
        (advance cur)
        (form-spanned-compound-result
          toks
          cur
          (bracket-list-spanned-result toks cur span))]
      [(prefix-tag? t)
        (let
          [name : ci.InternSyntaxId (prefix-symbol t)]
          (advance cur)
          (let
            [form (try (form-spanned-result toks cur))]
            (form-spanned-suffix-result
              toks
              cur
              (prefix-spanned-form name span form))))]
      [(= t (token.tag-rparen))
        (Err (token.SourceError "reader: unexpected ')'" span))]
      [(= t (token.tag-rbracket))
        (Err (token.SourceError "reader: unexpected ']'" span))]
      [else (Err (token.SourceError "reader: unexpected end of input" span))])))

(define (spanned-sexpr-adjacent?
  [left : SpannedSexpr]
  [right-span : token.SourceSpan]) : bool
  (let
    [left-span : token.SourceSpan (spanned-sexpr-span left)]
    (and
      (= (token.span-end-line left-span) (token.span-start-line right-span))
      (= (+ (token.span-end-col left-span) 1) (token.span-start-col right-span)))))

(define (projection-suffix-symbol? [text : (& text str)]) : bool
  (and (> (string.string-length text) 0) (= (string.string-ref text 0) '.')))

(define (projection-suffix-next-dot
  [text : (& text str)]
  [index : i64]
  [length : i64]) : i64
  (let
    [end : i64 index]
    (while (and (< end length) (!= (string.string-ref text end) '.'))
      (set! end (+ end 1)))
    end))

(define (projection-suffix-error [message : String] [span : token.SourceSpan]) : ResultSpannedSexpr
  (Err (token.SourceError message span)))

(define (spanned-projection-suffix-at
  [base : SpannedSexpr]
  [text : String]
  [suffix-span : token.SourceSpan]
  [start : i64]) : ResultSpannedSexpr
  (let
    [length : i64 (string.string-length text)]
    [end : i64 (projection-suffix-next-dot text start length)]
    (cond
      [(>= start end)
        (projection-suffix-error
          "reader: malformed dotted field access; field name cannot be empty"
          suffix-span)]
      [(and
          (>= (string.string-ref text start) '0')
          (<= (string.string-ref text start) '9'))
        (projection-suffix-error
          "reader: dotted field access cannot use numeric field segments; use tuple-ref or array-ref"
          suffix-span)]
      [else
        (let
          [span : token.SourceSpan
            (token.merge-spans
              (spanned-sexpr-span
                (unsafe
                  (ptr-read (ptr-addr-of base))))
              suffix-span)]
          [field : ci.InternSyntaxId
            (ci.intern-syntax-id-from-renderable
              (ci.intern-source-slice-id text start (- end start)))]
          [projected : SpannedSexpr
            (spanned-sexpr-list3
              (Sym (stable-syntax-id "__tl_struct-get") suffix-span)
              base
              (Sym field suffix-span)
              span)]
          (if (< end length)
            (spanned-projection-suffix-at projected text suffix-span (+ end 1))
            (Ok projected)))])))

(define (form-spanned-suffix-result
  [toks : (& toks (__tl_dyn-array token.SpannedToken))]
  [cur : (&mut cur (__tl_dyn-array i64))]
  [base : SpannedSexpr]) : ResultSpannedSexpr
  (let
    [st : (& toks token.SpannedToken) (& (array-ref toks (cur-pos cur)))]
    [tok : (& toks token.Token) (token.spanned-token-token-ref st)]
    [span : token.SourceSpan (token.spanned-token-span st)]
    ;; Most forms are followed by whitespace or a delimiter. Reject those
    ;; before materializing the interned symbol text; only lexically adjacent
    ;; symbols can be projection suffixes.
    (if (and
      (= (token.tag-ref tok) (token.tag-sym))
      (spanned-sexpr-adjacent?
        (unsafe
          (ptr-read (ptr-addr-of base)))
        span)
      (not sp-reader-data-mode?))
      (let
        [text : String (ci.intern-id-str (token.sym-id tok))]
        (if (projection-suffix-symbol? text)
          (begin
            (advance cur)
            (let
              [projected (try (spanned-projection-suffix-at base text span 1))]
              (form-spanned-suffix-result toks cur projected)))
          (Ok base)))
      (Ok base))))

(define (form-spanned-compound-result
  [toks : (& toks (__tl_dyn-array token.SpannedToken))]
  [cur : (&mut cur (__tl_dyn-array i64))]
  [result : ResultSpannedSexpr]) : ResultSpannedSexpr
  (let
    [form (try result)]
    (form-spanned-suffix-result toks cur form)))

(define (list-spanned-items-result
  [toks : (& toks (__tl_dyn-array token.SpannedToken))]
  [cur : (&mut cur (__tl_dyn-array i64))]
  [open-span : token.SourceSpan]
  [close-tag : i64]
  [builder : SpannedSexprBuilder]) : ResultSpannedSexpr
  (let
    [st : (& toks token.SpannedToken) (& (array-ref toks (cur-pos cur)))]
    [span : token.SourceSpan (token.spanned-token-span st)]
    [t : i64 (token.tag-ref (token.spanned-token-token-ref st))]
    (cond
      [(= t close-tag)
        (advance cur)
        (Ok
          (spanned-sexpr-list-from-builder
            builder
            (token.merge-spans open-span span)))]
      [(= t (token.tag-end))
        (Err
          (token.SourceError (unterminated-list-message close-tag) open-span))]
      [(and (opposite-close-delimiter? t close-tag) (not sp-reader-data-mode?))
        (Err
          (token.SourceError (mismatched-close-message close-tag t span) span))]
      [else
        (let
          [head (try (form-spanned-result toks cur))]
          (list-spanned-items-result
            toks
            cur
            open-span
            close-tag
            (spanned-sexpr-builder-push builder head)))])))

(define (list-spanned-result
  [toks : (& toks (__tl_dyn-array token.SpannedToken))]
  [cur : (&mut cur (__tl_dyn-array i64))]
  [open-span : token.SourceSpan]) : ResultSpannedSexpr
  (let
    [pool-mark : i64 (sp-node-pool-len)]
    [builder : SpannedSexprBuilder (spanned-sexpr-builder-new)]
    [result : ResultSpannedSexpr
      (list-spanned-items-result toks cur open-span (token.tag-rparen) builder)]
    (match result
      [(Ok form) (Ok form)]
      [(Err err)
        (spanned-sexpr-builder-discard! builder)
        (sp-node-pool-truncate! pool-mark)
        (Err err)])))

(define (bracket-list-spanned-result
  [toks : (& toks (__tl_dyn-array token.SpannedToken))]
  [cur : (&mut cur (__tl_dyn-array i64))]
  [open-span : token.SourceSpan]) : ResultSpannedSexpr
  (let
    [pool-mark : i64 (sp-node-pool-len)]
    [builder : SpannedSexprBuilder (spanned-sexpr-builder-new)]
    [result : ResultSpannedSexpr
      (list-spanned-items-result
        toks
        cur
        open-span
        (token.tag-rbracket)
        builder)]
    (match result
      [(Ok items)
        (let
          [span : token.SourceSpan
            (spanned-sexpr-span
              (unsafe
                (ptr-read (ptr-addr-of items))))]
          (Ok (spanned-sexpr-bracket-list items span)))]
      [(Err err)
        (spanned-sexpr-builder-discard! builder)
        (sp-node-pool-truncate! pool-mark)
        (Err err)])))

(define (spanned-result [toks : (__tl_dyn-array token.SpannedToken)]) : ResultSpannedSexpr
  (let
    [cur : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    (set! sp-builder-count 0)
    (set! (array-ref cur 0) 0)
    (form-spanned-result (& toks) (&mut cur))))

;; Read one plain data form from the front of `src` (a lockfile, TLCI
;; metadata): no projection suffixes, a stray closing delimiter is unexpected
;; rather than mismatched, and errors are message-only. The form's rows stay in
;; the node pool; callers truncate it to their own mark once they have copied
;; out what they need. A lexer error panics.
(define (data-result [src : String]) : ResultSexpr
  (match (lexer.spanned-result (& src))
    [(Err err) (io.panic (token.source-error-message err))]
    [(Ok toks)
      (let
        [cur : (__tl_dyn-array i64) (__tl_make-array i64 1)]
        (set! (array-ref cur 0) 0)
        (set! sp-reader-data-mode? true)
        (let
          [result : ResultSpannedSexpr
            (form-spanned-result (& toks) (&mut cur))]
          (set! sp-reader-data-mode? false)
          (match result
            [(Ok form) (Ok form)]
            [(Err err) (Err (token.source-error-message err))])))]))
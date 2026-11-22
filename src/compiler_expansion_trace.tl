;; compiler_expansion_trace.tl - owning storage for macro-expansion frames.
;;
;; An `OwnershipSource` records where a selected occurrence came from. Its
;; expansion trace used to be a formatted String, built on the hot path even
;; though only diagnostics read it. A trace is now an append-only frame table:
;; a source carries the id of its innermost frame, frames link to the enclosing
;; trace, and text is rendered only when a diagnostic or dump asks for it.
;;
;; Frames live in one arena. `compiler-expansion-trace-reset!` releases it with
;; the intern table, and ids from an earlier generation render as empty rather
;; than reading a reused segment.
(import stdlib.arena)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import compiler_abort as abort)

(defstruct CompilerExpansionFrame
  ;; The enclosing trace, or 0 for the outermost frame.
  (previous i64)
  (invocation-path-id i64)
  (start-line i64)
  (start-column i64)
  (end-line i64)
  (end-column i64)
  (origin-path-id i64)
  (macro-name-id i64)
  ;; The rendered byte count of this frame and its enclosing frames, so
  ;; charges and copies read it in O(1).
  (bytes i64))

(define compiler-expansion-trace-segment-capacity : i64
  128)

;; 40960 segments keep 5 Mi frames addressable. The small first segment keeps
;; the batch live-memory baseline below its 4 MiB drift budget.
(define compiler-expansion-trace-max-segments : i64
  40960)
(define compiler-expansion-trace-segments : (__tl_dyn-array i64)
  (__tl_make-array i64 compiler-expansion-trace-max-segments))
(define compiler-expansion-trace-current : (__tl_dyn-array
    CompilerExpansionFrame)
  (__tl_make-array CompilerExpansionFrame 0))
(define compiler-expansion-trace-arena : i64
  0)
(define compiler-expansion-trace-used : i64
  0)
(define compiler-expansion-trace-count : i64
  0)

;; Old ids stay harmless across a reset: an id from an earlier generation
;; renders as the empty trace instead of reading a reused segment.
(define compiler-expansion-trace-generation : i64
  1)

(define (compiler-expansion-trace-none) : i64
  0)

(define (compiler-expansion-trace-live? [id : i64]) : bool
  (and (> id 0) (= (shr id 32) compiler-expansion-trace-generation)))

(define (compiler-expansion-trace-next-segment!) : unit
  (let
    [segment-index : i64
      (/
        compiler-expansion-trace-count
        compiler-expansion-trace-segment-capacity)]
    (when
      (>= segment-index compiler-expansion-trace-max-segments)
      (abort.compiler-abort "tl: compiler expansion trace capacity exhausted\n"))
    (when
      (= compiler-expansion-trace-arena 0)
      (set! compiler-expansion-trace-arena (arena.tl_arena_make)))
    (let
      [enclosing : i64 (arena.tl_arena_current)]
      [segment : (__tl_dyn-array CompilerExpansionFrame)
        (begin
          (unsafe
            (arena.tl_arena_set compiler-expansion-trace-arena))
          (__tl_make-array
            CompilerExpansionFrame
            compiler-expansion-trace-segment-capacity))]
      (unsafe
        (arena.tl_arena_set enclosing))
      (set!
        (array-ref compiler-expansion-trace-segments segment-index)
        (cast
          (unsafe
            (ptr->int (__tl_array-data segment)))
          : i64))
      (set! compiler-expansion-trace-current segment)
      (set! compiler-expansion-trace-used 0))))

;; Append one frame enclosing `previous` and return its id (never 0).
(define (compiler-expansion-trace-push
  [previous : i64]
  [invocation-path-id : i64]
  [start-line : i64]
  [start-column : i64]
  [end-line : i64]
  [end-column : i64]
  [origin-path-id : i64]
  [macro-name-id : i64]) : i64
  (when
    (or
      (=
        compiler-expansion-trace-used
        compiler-expansion-trace-segment-capacity)
      (= (array-length compiler-expansion-trace-current) 0))
    (compiler-expansion-trace-next-segment!))
  (let
    [index : i64 compiler-expansion-trace-used]
    [frame : CompilerExpansionFrame
      (CompilerExpansionFrame
        previous
        invocation-path-id
        start-line
        start-column
        end-line
        end-column
        origin-path-id
        macro-name-id
        (+
          (compiler-expansion-trace-bytes previous)
          (compiler-expansion-trace-frame-bytes
            invocation-path-id
            start-line
            start-column
            end-line
            end-column
            origin-path-id
            macro-name-id)))]
    (set! (array-ref compiler-expansion-trace-current index) frame)
    (set! compiler-expansion-trace-used (+ index 1))
    (set! compiler-expansion-trace-count (+ compiler-expansion-trace-count 1))
    (bit-or
      (shl compiler-expansion-trace-generation 32)
      compiler-expansion-trace-count)))

(define (compiler-expansion-trace-at [id : i64]) : CompilerExpansionFrame
  (if (not (compiler-expansion-trace-live? id))
    (CompilerExpansionFrame 0 0 0 0 0 0 0 0 0)
    (let
      [index : i64 (- (bit-and id 4294967295) 1)]
      (if (or (< index 0) (>= index compiler-expansion-trace-count))
        (CompilerExpansionFrame 0 0 0 0 0 0 0 0 0)
        (let
          [segment-index : i64
            (/ index compiler-expansion-trace-segment-capacity)]
          [offset : i64 (% index compiler-expansion-trace-segment-capacity)]
          [segment : (Ptr CompilerExpansionFrame)
            (unsafe
              (int->ptr
                (cast
                  (array-ref compiler-expansion-trace-segments segment-index)
                  : u64)
                : (Ptr CompilerExpansionFrame)))]
          (unsafe
            (ptr-read (ptr-offset segment offset))))))))

(define (compiler-expansion-trace-int-bytes [value : i64]) : i64
  (if (< value 0)
    (let
      [remaining : i64 value]
      [digits : i64 2]
      (while (<= remaining -10)
        (set! remaining (/ remaining 10))
        (set! digits (+ digits 1)))
      digits)
    (cond
      [(< value 10) 1]
      [(< value 100) 2]
      [(< value 1000) 3]
      [(< value 10000) 4]
      [(< value 100000) 5]
      [(< value 1000000) 6]
      [(< value 10000000) 7]
      [(< value 100000000) 8]
      [(< value 1000000000) 9]
      [(< value 10000000000) 10]
      [(< value 100000000000) 11]
      [(< value 1000000000000) 12]
      [(< value 10000000000000) 13]
      [(< value 100000000000000) 14]
      [(< value 1000000000000000) 15]
      [(< value 10000000000000000) 16]
      [(< value 100000000000000000) 17]
      [(< value 1000000000000000000) 18]
      [else 19])))

(define (compiler-expansion-trace-frame-bytes
  [invocation-path-id : i64]
  [start-line : i64]
  [start-column : i64]
  [end-line : i64]
  [end-column : i64]
  [origin-path-id : i64]
  [macro-name-id : i64]) : i64
  (+
    7
    (+
      (compiler-expansion-trace-int-bytes invocation-path-id)
      (+
        (compiler-expansion-trace-int-bytes start-line)
        (+
          (compiler-expansion-trace-int-bytes start-column)
          (+
            (compiler-expansion-trace-int-bytes end-line)
            (+
              (compiler-expansion-trace-int-bytes end-column)
              (+
                (compiler-expansion-trace-int-bytes origin-path-id)
                (compiler-expansion-trace-int-bytes macro-name-id)))))))))

(define (compiler-expansion-trace-frame-text
  [frame : (& frame CompilerExpansionFrame)]) : String
  (str_cat.str-cat
    (string.int->string frame.invocation-path-id)
    "|"
    (string.int->string frame.start-line)
    "|"
    (string.int->string frame.start-column)
    "|"
    (string.int->string frame.end-line)
    "|"
    (string.int->string frame.end-column)
    "|"
    (string.int->string frame.origin-path-id)
    "|"
    (string.int->string frame.macro-name-id)
    ";"))

;; The rendered frame list, innermost first, exactly the text the retired
;; eager builder produced.
(define (compiler-expansion-trace-text [id : i64]) : String
  (let
    [out : String ""]
    [cursor : i64 id]
    (while (compiler-expansion-trace-live? cursor)
      (let
        [frame : CompilerExpansionFrame (compiler-expansion-trace-at cursor)]
        (set!
          out
          (str_cat.str-cat out (compiler-expansion-trace-frame-text (& frame))))
        (set! cursor frame.previous)))
    out))

;; The byte count of `id`, without building its text.
(define (compiler-expansion-trace-bytes [id : i64]) : i64
  (if (not (compiler-expansion-trace-live? id))
    0
    (compiler-expansion-trace-at id).bytes))

(define (compiler-expansion-trace-equal? [left : i64] [right : i64]) : bool
  (if (= left right)
    true
    (if (or
      (not (compiler-expansion-trace-live? left))
      (not (compiler-expansion-trace-live? right)))
      false
      (let
        [left-frame : CompilerExpansionFrame (compiler-expansion-trace-at left)]
        [right-frame : CompilerExpansionFrame
          (compiler-expansion-trace-at right)]
        (and
          (= left-frame.bytes right-frame.bytes)
          (= left-frame.invocation-path-id right-frame.invocation-path-id)
          (= left-frame.start-line right-frame.start-line)
          (= left-frame.start-column right-frame.start-column)
          (= left-frame.end-line right-frame.end-line)
          (= left-frame.end-column right-frame.end-column)
          (= left-frame.origin-path-id right-frame.origin-path-id)
          (= left-frame.macro-name-id right-frame.macro-name-id)
          (compiler-expansion-trace-equal?
            left-frame.previous
            right-frame.previous))))))

(define (compiler-expansion-trace-reset!) : unit
  (when
    (!= compiler-expansion-trace-arena 0)
    (unsafe
      (arena.tl_arena_destroy compiler-expansion-trace-arena)))
  (set! compiler-expansion-trace-arena 0)
  (set! compiler-expansion-trace-used 0)
  (set! compiler-expansion-trace-count 0)
  (set!
    compiler-expansion-trace-generation
    (+ compiler-expansion-trace-generation 1))
  ;; Allocate the first segment here, outside the measured macro-capture
  ;; region, rather than on the first expansion push.
  (compiler-expansion-trace-next-segment!))
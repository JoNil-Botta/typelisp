;# benchmarks/asm_render/bench.tl - backend assembly text emission.
;#
;# Equivalent to benchmarks/asm_render/baseline.c. The kernel is the TypeLisp
;# backend's own assembly renderer: operand strings built by the small operand
;# helpers, whole lines concatenated by `str_cat.str-cat` or written straight
;# into the function's `CompilerBackendAsmBuf` by the `-asm-append*` family, the
;# finished function body handed to a `stdlib.text_buf` TextBuf, and the module
;# text rendered once. It runs over the real token stream of a slice of the
;# assembly the stage0 compiler emitted for `src/compiler_load.tl` (see
;# README.md for the corpus and its regeneration command).
;#
;# Mirrored functions:
;#   src/compiler_backend.tl
;#     compiler-backend-asm-buf-with-capacity / -grow! / -reserve! / -finish
;#     compiler-backend-asm-copy-part!   -- the inline word-then-tail part copy
;#     compiler-backend-asm-append / -append2 / -append4 / -append5
;#     compiler-backend-reg-part / -reg-part-by-size
;#     compiler-backend-address-add-byte-offset
;#     compiler-backend-frame-offset-render / -stack-memory-operand
;#     compiler-backend-append-located-instr  (body chunk -> module TextBuf)
;#   stdlib/str_cat_runtime.tl  str-cat / str-cat-scoped / str-cat-pack-new /
;#     str-cat-pack-part! / str-cat-concat-packed -- called, not reimplemented
;#   stdlib/string.tl  concat3/4/5-borrowed, concat-all, int->string and its
;#     digit-count ladder and negative-digit writer
;#   stdlib/text_buf.tl  append / render and the chunk store growth policy
;#
;# Every line of the slice is rendered again from the operand structure the
;# backend held before it printed the line, and the re-rendered text is compared
;# with the original: round 0 folds a 64-bit FNV-1a over all output bytes and
;# aborts unless the fold and the byte count equal the values the exporter
;# recorded for the slice. That equality is the fidelity proof for every operand
;# helper at once.
;#
;# The corpus path and the round count are runtime arguments, so nothing can be
;# constant folded. Each round rotates the starting function chunk by one, so no
;# round repeats an earlier round's accumulator. The checksum is a wrapping
;# 64-bit FNV-1a fold with no division, so the printed decimal matches the C
;# baseline's `%lld` bit for bit.
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.str_cat)
(import stdlib.string)
(import stdlib.text_buf)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(define (asm-zero-vec [n : i64]) : i64vec.Vec
  (i64vec.Vec (__tl_make-array i64 n) n))

(define (asm-vec-ref [items : (& items i64vec.Vec)] [index : i64]) : i64
  (array-ref (i64vec.slots items) index))

(define (asm-vec-set!
  [items : (&mut items i64vec.Vec)]
  [index : i64]
  [value : i64]) : unit
  (set! (array-ref (i64vec.slots-mut items) index) value))

(defmacro (asm-ref [items : Expr] [index : Expr]) : Expr
  `(asm-vec-ref (& ,items) ,index))

(defmacro (asm-set! [items : Expr] [index : Expr] [value : Expr]) : Expr
  `(asm-vec-set! (&mut ,items) ,index ,value))

(define asm-hash-basis : i64
  1469598103934665603)
(define asm-hash-prime : i64
  1099511628211)

;; compiler-backend-asm-bytes-per-instr: the backend budgets this many bytes of
;; text per instruction when it sizes a function body buffer.
(define asm-bytes-per-line : i64
  64)

;; The tape, the per-chunk index, and the name table. Module globals keep the
;; render functions parameterless, matching how the backend threads one
;; CompilerBackendState through emission.
(define asm-tokens : i64vec.Vec
  (asm-zero-vec 1))
(define asm-chunk-off : i64vec.Vec
  (asm-zero-vec 1))
(define asm-chunk-lines : i64vec.Vec
  (asm-zero-vec 1))
(define asm-kind-counts : i64vec.Vec
  (asm-zero-vec 8))
(define asm-names : (__tl_dyn-array String)
  (__tl_make-array String 1))

;; Corpus header: name count, chunk count, line count, and the byte length and
;; FNV-1a fold of the assembly slice the tape was made from.
(define asm-names-count : i64
  0)
(define asm-chunks : i64
  0)
(define asm-lines : i64
  0)
(define asm-slice-bytes : i64
  0)
(define asm-slice-fnv : i64
  0)

;; Read cursor into the tape, advanced by every row and operand read.
(define asm-cursor : i64
  0)

(define (asm-mix [hash : i64] [value : i64]) : i64
  (* (bit-xor hash value) asm-hash-prime))

(define (asm-byte-at [text : (& text str)] [n : i64] [i : i64]) : i64
  (if (< i n)
    (cast (string.string-ref text i) : i64)
    -1))

(define (asm-digit? [byte : i64]) : bool
  (and (>= byte 48) (<= byte 57)))

;; Whitespace-separated decimal integers, with `#` starting a comment that runs
;; to the end of its line.
(define (asm-scan-ints [text : (& text str)] [out : (&mut out i64vec.Vec)]) : i64
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [count : i64 0]
    (begin
      (while (< i n)
        (let
          [byte : i64 (asm-byte-at text n i)]
          (cond
            [(= byte 35)
              (while (and (< i n) (not (= (asm-byte-at text n i) 10)))
                (set! i (+ i 1)))]
            [(or (asm-digit? byte) (= byte 45))
              (let
                [negative : bool (= byte 45)]
                [value : i64 0]
                (begin
                  (when negative (set! i (+ i 1)))
                  (while (asm-digit? (asm-byte-at text n i))
                    (begin
                      (set!
                        value
                        (+ (* value 10) (- (asm-byte-at text n i) 48)))
                      (set! i (+ i 1))))
                  (i64vec.set-ref!
                    out
                    count
                    (if negative
                      (- 0 value)
                      value))
                  (set! count (+ count 1))))]
            [else (set! i (+ i 1))])))
      count)))

(define (asm-tok-next) : i64
  (let
    [value : i64 (asm-ref asm-tokens asm-cursor)]
    (begin
      (set! asm-cursor (+ asm-cursor 1))
      value)))

;; compiler-backend-global-array-element-shared-view / text-buf-store-entry-at:
;; a String element of a module-global table is read as a shared view, not moved
;; out of the global.
(define (asm-name [id : i64]) : String
  (unsafe
    (ptr-read
      (ptr-cast
        (ptr-offset (ptr-cast (__tl_array-data asm-names) : (Ptr String)) id)
        : (Ptr String)))))

;; ---------------------------------------------------------------------------
;; CompilerBackendAsmBuf: the byte buffer every emitted part is copied into.
;; ---------------------------------------------------------------------------
(defstruct AsmBuf
  (data (MutPtr u8))
  (cap i64)
  (len i64))

(define (asm-buf-with-capacity [capacity : i64]) : AsmBuf
  (let
    [cap : i64
      (if (< capacity 16)
        16
        capacity)]
    (AsmBuf (string.string-runtime-alloc cap) cap 0)))

(define (asm-buf-grow! [buf : (&mut buf AsmBuf)] [needed : i64]) : unit
  (let
    [doubled : i64 (* buf.cap 2)]
    [capacity : i64
      (if (< doubled needed)
        needed
        doubled)]
    [bigger : (MutPtr u8) (string.string-runtime-alloc capacity)]
    (begin
      (string.str-copy-bytes-into
        (unsafe
          (ptr-cast buf.data : (Ptr u8)))
        bigger
        0
        buf.len)
      (set! buf.data bigger)
      (set! buf.cap capacity))))

(define (asm-buf-reserve! [buf : (&mut buf AsmBuf)] [total : i64]) : unit
  (if (> total buf.cap)
    (asm-buf-grow! buf total)
    unit))

;; compiler-backend-asm-copy-part!: copy `n` bytes of `src` into `dst` at byte
;; offset `off`, INLINE. The point of the builder is that an operand part
;; reaches the buffer through one move loop, not through two call frames.
(defmacro (asm-copy-part!
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
    (begin
      (while (< asm-copy-w asm-copy-words)
        (begin
          (unsafe
            (ptr-write!
              (ptr-offset asm-copy-dst64 asm-copy-w)
              (ptr-read (ptr-offset asm-copy-src64 asm-copy-w))))
          (set! asm-copy-w (+ asm-copy-w 1))))
      (while (< asm-copy-b ,n)
        (begin
          (unsafe
            (ptr-write!
              (ptr-offset ,dst (+ ,off asm-copy-b))
              (ptr-read (ptr-offset asm-copy-src asm-copy-b))))
          (set! asm-copy-b (+ asm-copy-b 1))))
      unit)))

(define (asm-append [buf : (&mut buf AsmBuf)] [part : String]) : unit
  (let
    [n : i64 (string.string-length part)]
    (if (= n 0)
      unit
      (let
        [off : i64 buf.len]
        (begin
          (asm-buf-reserve! buf (+ off n))
          (let
            [dst : (MutPtr u8) buf.data]
            (asm-copy-part! dst off part n))
          (set! buf.len (+ off n)))))))

(define (asm-append2 [buf : (&mut buf AsmBuf)] [a : String] [b : String]) : unit
  (let
    [na : i64 (string.string-length a)]
    [nb : i64 (string.string-length b)]
    [total : i64 (+ na nb)]
    [off : i64 buf.len]
    (begin
      (asm-buf-reserve! buf (+ off total))
      (let
        [dst : (MutPtr u8) buf.data]
        [ob : i64 (+ off na)]
        (begin
          (asm-copy-part! dst off a na)
          (asm-copy-part! dst ob b nb)))
      (set! buf.len (+ off total)))))

(define (asm-append4
  [buf : (&mut buf AsmBuf)]
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
    (begin
      (asm-buf-reserve! buf (+ off total))
      (let
        [dst : (MutPtr u8) buf.data]
        [ob : i64 (+ off na)]
        [oc : i64 (+ ob nb)]
        [od : i64 (+ oc nc)]
        (begin
          (asm-copy-part! dst off a na)
          (asm-copy-part! dst ob b nb)
          (asm-copy-part! dst oc c nc)
          (asm-copy-part! dst od d nd)))
      (set! buf.len (+ off total)))))

(define (asm-append5
  [buf : (&mut buf AsmBuf)]
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
    (begin
      (asm-buf-reserve! buf (+ off total))
      (let
        [dst : (MutPtr u8) buf.data]
        [ob : i64 (+ off na)]
        [oc : i64 (+ ob nb)]
        [od : i64 (+ oc nc)]
        [oe : i64 (+ od nd)]
        (begin
          (asm-copy-part! dst off a na)
          (asm-copy-part! dst ob b nb)
          (asm-copy-part! dst oc c nc)
          (asm-copy-part! dst od d nd)
          (asm-copy-part! dst oe e ne)))
      (set! buf.len (+ off total)))))

;; Hand the live prefix out as a String aliasing this buffer's storage. The
;; buffer is dead after this call.
(define (asm-buf-finish [buf : (& buf AsmBuf)]) : String
  (let
    [n : i64 buf.len]
    (if (= n 0)
      ""
      (unsafe
        (string-from-bytes (ptr-cast buf.data : (Ptr u8)) n)))))

;; ---------------------------------------------------------------------------
;; Operand rendering.
;; ---------------------------------------------------------------------------
(define (asm-reg-part-by-size
  [reg64 : String]
  [reg32 : String]
  [reg16 : String]
  [reg8 : String]
  [size : i64]) : String
  (cond
    [(= size 8) reg64]
    [(= size 4) reg32]
    [(= size 2) reg16]
    [(= size 1) reg8]
    [else
      (io.panic
        (str_cat.str-cat
          "asm_render: unsupported register part size "
          (string.int->string size)))]))

(define (asm-reg-part [reg : String] [size : i64]) : String
  (cond
    [(string.eq reg "%rax") (asm-reg-part-by-size reg "%eax" "%ax" "%al" size)]
    [(string.eq reg "%rbx") (asm-reg-part-by-size reg "%ebx" "%bx" "%bl" size)]
    [(string.eq reg "%rcx") (asm-reg-part-by-size reg "%ecx" "%cx" "%cl" size)]
    [(string.eq reg "%rdx") (asm-reg-part-by-size reg "%edx" "%dx" "%dl" size)]
    [(string.eq reg "%rdi") (asm-reg-part-by-size reg "%edi" "%di" "%dil" size)]
    [(string.eq reg "%rsi") (asm-reg-part-by-size reg "%esi" "%si" "%sil" size)]
    [(string.eq reg "%r12")
      (asm-reg-part-by-size reg "%r12d" "%r12w" "%r12b" size)]
    [(string.eq reg "%r13")
      (asm-reg-part-by-size reg "%r13d" "%r13w" "%r13b" size)]
    [(string.eq reg "%r14")
      (asm-reg-part-by-size reg "%r14d" "%r14w" "%r14b" size)]
    [(string.eq reg "%r15")
      (asm-reg-part-by-size reg "%r15d" "%r15w" "%r15b" size)]
    [(string.eq reg "%r8") (asm-reg-part-by-size reg "%r8d" "%r8w" "%r8b" size)]
    [(string.eq reg "%r9") (asm-reg-part-by-size reg "%r9d" "%r9w" "%r9b" size)]
    [(string.eq reg "%r10")
      (asm-reg-part-by-size reg "%r10d" "%r10w" "%r10b" size)]
    [(string.eq reg "%r11")
      (asm-reg-part-by-size reg "%r11d" "%r11w" "%r11b" size)]
    [(string.eq reg "%rbp") (asm-reg-part-by-size reg "%ebp" "%bp" "%bpl" size)]
    [else
      (io.panic (str_cat.str-cat "asm_render: unsupported register part " reg))]))

(define (asm-address-add-byte-offset [addr : String] [disp : i64]) : String
  (if (= disp 0)
    addr
    (let
      [disp-text : String (string.int->string disp)]
      (if (and
        (> (string.string-length addr) 0)
        (= (string.string-ref addr 0) '('))
        (str_cat.str-cat disp-text addr)
        (str_cat.str-cat disp-text "+" addr)))))

;; `disp(base)` and `disp(base,index,scale)`. A displacement of exactly zero is
;; still spelled, the way compiler-backend-frame-offset-render spells its slot
;; through `str-cat`; every other displacement goes through
;; compiler-backend-address-add-byte-offset.
(define (asm-mem-operand
  [base : String]
  [index : String]
  [has-index : bool]
  [scale : i64]
  [disp : i64]
  [disp-present : bool]) : String
  (let
    [scale-text : String
      (if has-index
        (string.int->string scale)
        "")]
    [addr : String
      (if has-index
        (str_cat.str-cat "(" base "," index "," scale-text ")")
        (str_cat.str-cat "(" base ")"))]
    (if disp-present
      (if (= disp 0)
        (str_cat.str-cat (string.int->string disp) addr)
        (asm-address-add-byte-offset addr disp))
      addr)))

(define (asm-imm-operand [value : i64]) : String
  (let
    [text : String (string.int->string value)]
    (str_cat.str-cat "$" text)))

(define (asm-rip-operand [symbol : String]) : String
  (str_cat.str-cat symbol "(%rip)"))

(define (asm-next-operand) : String
  (let
    [kind : i64 (asm-tok-next)]
    (cond
      [(= kind 0)
        (let
          [reg : String (asm-name (asm-tok-next))]
          [size : i64 (asm-tok-next)]
          (asm-reg-part reg size))]
      [(= kind 1) (asm-imm-operand (asm-tok-next))]
      [(= kind 2) (string.int->string (asm-tok-next))]
      [(= kind 3)
        (let
          [base-id : i64 (asm-tok-next)]
          [index-id : i64 (asm-tok-next)]
          [scale : i64 (asm-tok-next)]
          [disp : i64 (asm-tok-next)]
          [present : i64 (asm-tok-next)]
          [base : String (asm-name base-id)]
          [index : String
            (if (>= index-id 0)
              (asm-name index-id)
              "")]
          (asm-mem-operand base index (>= index-id 0) scale disp (= present 1)))]
      [(= kind 4) (asm-rip-operand (asm-name (asm-tok-next)))]
      [else (asm-name (asm-tok-next))])))

;; ---------------------------------------------------------------------------
;; Line rendering.
;; ---------------------------------------------------------------------------
;; One line, appended to the function's buffer, returning its kind. Directives
;; and three-operand instructions take the `str-cat` spelling the backend uses
;; when an emitter returns a String; the one- and two-operand instruction lines
;; take the `-asm-append*` spelling the same backend uses when the emitter
;; writes straight into a body buffer.
(define (asm-render-line [buf : (&mut buf AsmBuf)]) : i64
  (let
    [kind : i64 (asm-tok-next)]
    (begin
      (cond
        [(= kind 0) (asm-append buf "\n")]
        [(= kind 1)
          (let
            [text : String (asm-name (asm-tok-next))]
            (asm-append2 buf text "\n"))]
        [(= kind 2)
          (let
            [label : String (asm-name (asm-tok-next))]
            (asm-append2 buf label ":\n"))]
        [(= kind 3)
          (let
            [head : String (asm-name (asm-tok-next))]
            [nops : i64 (asm-tok-next)]
            (cond
              [(= nops 0) (asm-append buf (str_cat.str-cat head "\n" ""))]
              [(= nops 1)
                (let
                  [a : String (asm-next-operand)]
                  (asm-append buf (str_cat.str-cat head a "\n")))]
              [(= nops 2)
                (let
                  [a : String (asm-next-operand)]
                  [b : String (asm-next-operand)]
                  (asm-append buf (str_cat.str-cat head a ", " b "\n")))]
              [else
                (let
                  [a : String (asm-next-operand)]
                  [b : String (asm-next-operand)]
                  [c : String (asm-next-operand)]
                  (asm-append buf (str_cat.str-cat head a ", " b ", " c "\n")))]))]
        [else
          (let
            [head : String (asm-name (asm-tok-next))]
            [nops : i64 (asm-tok-next)]
            (cond
              [(= nops 0) (asm-append2 buf head "\n")]
              [(= nops 1)
                (let
                  [a : String (asm-next-operand)]
                  (asm-append4 buf head a "\n" ""))]
              [(= nops 2)
                (let
                  [a : String (asm-next-operand)]
                  [b : String (asm-next-operand)]
                  (asm-append5 buf head a ", " b "\n"))]
              [else
                (let
                  [a : String (asm-next-operand)]
                  [b : String (asm-next-operand)]
                  [c : String (asm-next-operand)]
                  (asm-append buf (str_cat.str-cat head a ", " b ", " c "\n")))]))])
      kind)))

;; One function chunk: a fresh body buffer sized at the backend's bytes-per-
;; instruction budget, every line appended into it, and the finished body handed
;; to the module text buffer.
(define (asm-render-chunk [chunk : i64] [out : text_buf.TextBuf]) : text_buf.TextBuf
  (let
    [lines : i64 (asm-ref asm-chunk-lines chunk)]
    [buf : AsmBuf (asm-buf-with-capacity (* lines asm-bytes-per-line))]
    [i : i64 0]
    (begin
      (set! asm-cursor (asm-ref asm-chunk-off chunk))
      (while (< i lines)
        (let
          [kind : i64 (asm-render-line (&mut buf))]
          (begin
            (asm-set! asm-kind-counts kind (+ (asm-ref asm-kind-counts kind) 1))
            (set! i (+ i 1)))))
      (text_buf.append out (asm-buf-finish (& buf))))))

(define (asm-fold-text [hash : i64] [text : (& text str)]) : i64
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [h : i64 hash]
    (begin
      (while (< i n)
        (begin
          (set! h (asm-mix h (cast (string.string-ref text i) : i64)))
          (set! i (+ i 1))))
      h)))

;; One pass over every function chunk, starting at `start` and wrapping. The
;; unrotated pass must reproduce the corpus slice byte for byte.
(define (asm-round [start : i64]) : i64
  (let
    [out : text_buf.TextBuf (text_buf.empty)]
    [step : i64 0]
    [index : i64 0]
    [kind : i64 0]
    [hash : i64 asm-hash-basis]
    (begin
      (while (< kind 8)
        (begin
          (asm-set! asm-kind-counts kind 0)
          (set! kind (+ kind 1))))
      (while (< step asm-chunks)
        (begin
          (set! index (+ start step))
          (when (>= index asm-chunks) (set! index (- index asm-chunks)))
          (set! out (asm-render-chunk index out))
          (set! step (+ step 1))))
      (let
        [text : String (text_buf.render out)]
        [n : i64 (string.string-length (& text))]
        (begin
          (set! hash (asm-fold-text hash (& text)))
          (when
            (and
              (= start 0)
              (or (not (= n asm-slice-bytes)) (not (= hash asm-slice-fnv))))
            (io.panic
              "asm_render: re-rendered text differs from the corpus slice"))
          (set! hash (asm-mix hash n))
          (set! kind 0)
          (while (< kind 8)
            (begin
              (set! hash (asm-mix hash (asm-ref asm-kind-counts kind)))
              (set! kind (+ kind 1))))
          hash)))))

;; ---------------------------------------------------------------------------
;; Corpus loading.
;; ---------------------------------------------------------------------------
(define (asm-operand-width [kind : i64]) : i64
  (cond [(= kind 0) 3] [(= kind 3) 6] [else 2]))

(define (asm-row-width [at : i64]) : i64
  (let
    [kind : i64 (asm-ref asm-tokens at)]
    (cond
      [(= kind 0) 1]
      [(or (= kind 1) (= kind 2)) 2]
      [else
        (let
          [nops : i64 (asm-ref asm-tokens (+ at 2))]
          [width : i64 3]
          [k : i64 0]
          (begin
            (while (< k nops)
              (begin
                (set!
                  width
                  (+
                    width
                    (asm-operand-width (asm-ref asm-tokens (+ at width)))))
                (set! k (+ k 1))))
            width))])))

(define (asm-index-chunks) : unit
  (let
    [cursor : i64 5]
    [chunk : i64 0]
    (begin
      (set! asm-chunk-off (asm-zero-vec (+ asm-chunks 1)))
      (set! asm-chunk-lines (asm-zero-vec (+ asm-chunks 1)))
      (while (< chunk asm-chunks)
        (let
          [lines : i64 (asm-ref asm-tokens cursor)]
          [i : i64 0]
          (begin
            (set! cursor (+ cursor 1))
            (asm-set! asm-chunk-off chunk cursor)
            (asm-set! asm-chunk-lines chunk lines)
            (while (< i lines)
              (begin
                (set! cursor (+ cursor (asm-row-width cursor)))
                (set! i (+ i 1))))
            (set! chunk (+ chunk 1)))))
      unit)))

;; The names live beside the tape: same directory, fixed file name.
(define (asm-names-path [path : (& path str)]) : String
  (let
    [n : i64 (string.string-length path)]
    [cut : i64 0]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (when (= (asm-byte-at path n i) 47) (set! cut (+ i 1)))
          (set! i (+ i 1))))
      (let
        [directory : String (string.substring path 0 cut)]
        (str_cat.str-cat directory "asm-names.txt")))))

;; Two header lines, then one name per line in id order.
(define (asm-load-names [text : (& text str)]) : unit
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [line : i64 0]
    [start : i64 0]
    (begin
      (set! asm-names (__tl_make-array String asm-names-count))
      (while (< i n)
        (begin
          (when
            (= (asm-byte-at text n i) 10)
            (begin
              (when
                (and (>= line 2) (< (- line 2) asm-names-count))
                (set!
                  (array-ref asm-names (- line 2))
                  (string.substring text start (- i start))))
              (set! line (+ line 1))
              (set! start (+ i 1))))
          (set! i (+ i 1))))
      unit)))

(define (asm-bench [path : String] [rounds : i64]) : i64
  (let
    [names-path : String (asm-names-path (& path))]
    [text : String (byte_buf.to-string (io.read-file path))]
    [capacity : i64 (+ (/ (string.string-length (& text)) 2) 8)]
    [round : i64 0]
    [start : i64 0]
    [acc : i64 asm-hash-basis]
    (begin
      (set! asm-tokens (asm-zero-vec capacity))
      (set! acc (asm-mix acc (asm-scan-ints (& text) (&mut asm-tokens))))
      (set! asm-names-count (asm-ref asm-tokens 0))
      (set! asm-chunks (asm-ref asm-tokens 1))
      (set! asm-lines (asm-ref asm-tokens 2))
      (set! asm-slice-bytes (asm-ref asm-tokens 3))
      (set! asm-slice-fnv (asm-ref asm-tokens 4))
      (let
        [names-text : String (byte_buf.to-string (io.read-file names-path))]
        (asm-load-names (& names-text)))
      (asm-index-chunks)
      (set! acc (asm-mix acc asm-lines))
      (while (< round rounds)
        (begin
          (set! acc (asm-mix acc round))
          (set! acc (asm-mix acc start))
          (set! acc (asm-mix acc (with-arena round-arena (asm-round start))))
          (set! start (+ start 1))
          (when (>= start asm-chunks) (set! start 0))
          (set! round (+ round 1))))
      acc)))

(define (main) : i64
  (let
    [path : String (io.arg 1)]
    [rounds : i64 (string.>int (io.arg 2))]
    (begin
      (io.println "{}" (asm-bench path rounds))
      0)))
(import compiler_linux_asm_debug as dbg)
(import compiler_linux_asm_layout as asm)
(import compiler_linux_asm_symbols as sym)
(import compiler_linux_asm_directives as dir)
(import compiler_x64_encode as x64)
(import compiler_x64_encode_operands as op)
(import stdlib.arena)
(import stdlib.byte_buf_core as buf)
(import stdlib.string)
(import stdlib.vector)

(defstruct Macro
  (name String)
  (formals String)
  (body String))

(import (vector.vector Macro core) as macros)
(import (vector.vector i64 core) as ints)

(defstruct Reader
  (image asm.Image)
  (definitions macros.Vec)
  (stack ints.Vec)
  (debug dbg.Debug)
  (source-offset i64))

(define (new-reader) : Reader
  (Reader (asm.new-image) (macros.new) (ints.new) (dbg.new) 0))

(define (next-line [source : (& str)] [cursor : (&mut i64)]) : String
  (let
    [start (deref cursor)]
    [end (string.index-of-byte source start 10)]
    (when (< end 0) (set! end (string.string-length source)))
    (set! (deref cursor) (+ end 1))
    (op.range source start (op.delimiter-before source start end '#'))))

(define (macro-block-end
  [source : (& src str)]
  [cursor : (&mut i64)]
  [open : (& str)]
  [close : (& str)]) : i64
  (let
    [depth : i64 1]
    (while (< (deref cursor) (string.string-length source))
      (with-arena
        scan-line
        (let
          [start (deref cursor)]
          [line : String (next-line source cursor)]
          [name : String (op.range (& line) 0 (x64.word-end (& line)))]
          (when (string.eq (& name) open) (+= depth 1))
          (when
            (string.eq (& name) close)
            (-= depth 1)
            (when (= depth 0) (return start))))))
    -1))

(defstruct Argument
  (name String)
  (value String))

(import (vector.vector Argument core) as bindings)

(defenum Text
  (Ok String)
  (Err String))

(define (substitute
  [body : (& str)]
  [start : i64]
  [n : i64]
  [values : (& args bindings.Vec)]) : Text
  (let
    [out (buf.byte-buf-builder-with-capacity (- n start))]
    [i start]
    (while (< i n)
      (let
        [c (string.string-ref body i)]
        (if (= c '\\')
          (let
            [parameter-start (+ i 1)]
            [j : i64 0]
            [found false]
            (set! i parameter-start)
            (while (and
              (< i n)
              (let
                [k (string.string-ref body i)]
                (or
                  (= k '_')
                  (and (>= k 'a') (<= k 'z'))
                  (and (>= k 'A') (<= k 'Z'))
                  (and (>= k '0') (<= k '9')))))
              (+= i 1))
            (when
              (= parameter-start i)
              (return (Err "invalid assembler macro substitution")))
            (let
              [parameter
                (string.substring body parameter-start (- i parameter-start))]
              (while (< j values.len)
                (let
                  [arg : (& args Argument) (& (array-ref values.slots j))]
                  (when
                    (string.eq (& arg.name) (& parameter))
                    (buf.byte-buf-builder-append-string
                      (&mut out)
                      (string.copy (& arg.value)))
                    (set! found true)
                    (set! j values.len)))
                (+= j 1)))
            (unless found (return (Err "unknown assembler macro parameter"))))
          (begin
            (buf.byte-buf-builder-push (&mut out) (cast c : u8))
            (+= i 1)))))
    (Ok (buf.byte-buf-builder-finish-string (& out)))))

(define (expand
  [formals : (& str)]
  [actuals : (& str)]
  [body : (& str)]
  [start : i64]
  [end : i64]) : Text
  (let
    [values (bindings.new)]
    [i : i64 0]
    [j : i64 0]
    (while (< i (string.string-length formals))
      (when
        (> j (string.string-length actuals))
        (return (Err "missing assembler macro argument")))
      (bindings.push-ref!
        (&mut values)
        (Argument
          (dir.argument formals (&mut i))
          (dir.unquoted (dir.argument actuals (&mut j))))))
    (when
      (< j (string.string-length actuals))
      (return (Err "extra assembler macro argument")))
    (substitute body start end (& values))))

(define (defined? [reader : (& Reader)] [name : (& str)]) : bool
  (let
    [id (sym.lookup (& reader.image.table) name)]
    (and
      (>= id 0)
      (or
        (>= (array-ref reader.image.table.entries.slots id).position.section 0)
        (> (array-ref reader.image.table.entries.slots id).common-align 0)))))

(define (read-expansion!
  [reader : (&mut Reader)]
  [expanded : (& Text)]
  [depth : i64]
  [encoder-scratch : arena.Arena]) : asm.Status
  (match expanded
    [(Ok text) (read-source! reader text (+ depth 1) encoder-scratch)]
    [(Err reason) (Err (string.copy reason))]))

(define (read-repeat!
  [reader : (&mut Reader)]
  [args : (& str)]
  [source : (& str)]
  [start : i64]
  [end : i64]
  [depth : i64]
  [encoder-scratch : arena.Arena]) : asm.Status
  (with
    ([scratch (arena.make) arena.destroy-safe!])
    (let
      [i : i64 0]
      [formal (in-arena scratch (dir.argument args (&mut i)))]
      (while (< i (string.string-length args))
        (let
          [phase (arena.phase scratch)]
          [expanded
            (in-arena
              scratch
              (let
                [actual (dir.argument args (&mut i))]
                (expand (& formal) (& actual) source start end)))]
          [status (read-expansion! reader (& expanded) depth encoder-scratch)]
          (arena.rewind-safe! phase)
          (try status)))
      (Ok unit))))

(defstruct SourceState
  (cursor i64)
  (conditions i64)
  (skip i64))

(define (read-line!
  [reader : (&mut Reader)]
  [source : (& str)]
  [state : (&mut SourceState)]
  [depth : i64]
  [scratch : arena.Arena]
  [encoder-scratch : arena.Arena]) : asm.Status
  (let
    [line (in-arena scratch (next-line source (&mut state.cursor)))]
    [n (string.string-length (& line))]
    [at : i64 0]
    (while (< at n)
      (let
        [word-end (x64.word-end-at (& line) at)]
        [colon (op.delimiter-before (& line) at word-end ':')]
        [label? (< colon word-end)]
        [directive? (= (string.string-ref (& line) at) '.')]
        [word : String
          (if directive?
            (in-arena scratch (op.range (& line) at word-end))
            "")]
        [args : String
          (if (and directive? (not label?))
            (in-arena scratch (op.range (& line) word-end n))
            "")]
        (cond
          [(or (string.eq (& word) ".ifdef") (string.eq (& word) ".ifndef"))
            (+= state.conditions 1)
            (when
              (or
                (> state.skip 0)
                (= (string.eq (& word) ".ifndef") (defined? reader (& args))))
              (+= state.skip 1))]
          [(string.eq (& word) ".endif")
            (when (= state.conditions 0) (return (Err "unexpected .endif")))
            (-= state.conditions 1)
            (when (> state.skip 0) (-= state.skip 1))]
          [(or (string.eq (& word) ".macro") (string.eq (& word) ".irp"))
            (let
              [macro? (string.eq (& word) ".macro")]
              [start state.cursor]
              [end
                (in-arena
                  scratch
                  (macro-block-end
                    source
                    (&mut state.cursor)
                    (& word)
                    (if macro?
                      ".endm"
                      ".endr")))]
              (when
                (< end 0)
                (return (Err "unterminated assembler macro or .irp")))
              (when
                (= state.skip 0)
                (if macro?
                  (let
                    [head (x64.word-end (& args))]
                    (macros.push-ref!
                      (&mut reader.definitions)
                      (Macro
                        (op.range (& args) 0 head)
                        (op.range (& args) head (string.string-length (& args)))
                        (string.substring source start (- end start)))))
                  (try
                    (read-repeat!
                      reader
                      (& args)
                      source
                      start
                      end
                      depth
                      encoder-scratch)))))]
          [(> state.skip 0) unit]
          [label?
            (try
              (dir.label!
                (&mut reader.image)
                (& (in-arena scratch (op.range (& line) at colon)))))
            (set! at (op.skip-whitespace (& line) (+ colon 1) n))
            (continue)]
          [(or
              (string.eq (& word) ".loc")
              (string.eq (& word) ".file")
              (and
                (>= (string.string-length (& word)) 5)
                (string.is-string-prefix-at (& word) ".cfi_" 0)))
            (try
              (dbg.record!
                (&mut reader.debug)
                (& reader.image)
                (& word)
                (& args)))]
          [(string.eq (& word) ".pushsection")
            (ints.push-ref! (&mut reader.stack) reader.image.current)
            (try (dir.section! (&mut reader.image) (& args)))]
          [(string.eq (& word) ".popsection")
            (when (= reader.stack.len 0) (return (Err "unmatched .popsection")))
            (-= reader.stack.len 1)
            (set!
              reader.image.current
              (array-ref reader.stack.slots reader.stack.len))]
          [directive?
            (let
              [i : i64 0]
              [found false]
              (while (< i reader.definitions.len)
                (when
                  (string.eq
                    (& (array-ref reader.definitions.slots i).name)
                    (& word))
                  (let
                    [expanded
                      (in-arena
                        scratch
                        (expand
                          (& (array-ref reader.definitions.slots i).formals)
                          (& args)
                          (& (array-ref reader.definitions.slots i).body)
                          0
                          (string.string-length
                            (& (array-ref reader.definitions.slots i).body))))]
                    (try
                      (read-expansion!
                        reader
                        (& expanded)
                        depth
                        encoder-scratch)))
                  (set! found true)
                  (set! i reader.definitions.len))
                (+= i 1))
              (unless
                found
                (try (dir.directive! (&mut reader.image) (& word) (& args)))))]
          [else
            (let
              [tail : String
                (if (= at 0)
                  ""
                  (in-arena scratch (op.range (& line) at n)))]
              (try
                (asm.instruction!
                  (&mut
                    (array-ref reader.image.items.slots reader.image.current))
                  (&mut reader.image.table)
                  (if (= at 0)
                    (& line)
                    (& tail))
                  encoder-scratch)))])
        (break)))
    (Ok unit)))

(define (read-source!
  [reader : (&mut Reader)]
  [source : (& str)]
  [depth : i64]
  [encoder-scratch : arena.Arena]) : asm.Status
  (when
    (> depth 64)
    (return (Err "assembler macro expansion nested too deeply")))
  (with
    ([scratch (arena.make) arena.destroy-safe!])
    (let
      [state (SourceState 0 0 0)]
      (while (< state.cursor (string.string-length source))
        (when (= depth 0) (set! reader.source-offset state.cursor))
        (let
          [phase (arena.phase scratch)]
          [status
            (read-line!
              reader
              source
              (&mut state)
              depth
              scratch
              encoder-scratch)]
          (arena.rewind-safe! phase)
          (try status)))
      (unless
        (= state.conditions 0)
        (return (Err "unclosed assembler conditional")))
      (Ok unit))))
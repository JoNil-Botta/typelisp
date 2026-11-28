(import stdlib.arena)

;; CodeView C13 records for the final .cv_file, .cv_loc and .cv_linetable
;; dialect. Keep locations as fragment anchors until branches are relaxed.
(import compiler_linux_asm_directives as dir)
(import compiler_linux_asm_layout as asm)
(import compiler_linux_asm_symbols as sym)
(import compiler_linux_asm_resolve as resolve)
(import compiler_x64_encode as x64)
(import compiler_x64_encode_operands as op)
(import stdlib.string)
(import stdlib.byte_buf_core as buf)
(import stdlib.byte_le)
(import stdlib.iterator)
(import stdlib.vector)

(defstruct Line
  (at sym.Position)
  (file i64)
  (line i64)
  (column i64))

(import (vector.vector Line core) as lines)

(defstruct Function
  (rows lines.Vec)
  (begin-id i64)
  (end-id i64)
  (columns bool))

(import (vector.vector Function core) as functions)
(import (vector.vector String core) as paths)
(import (vector.vector i64 core) as ids)

(defstruct Debug
  (files paths.Vec)
  (functions functions.Vec)
  (tables ids.Vec)
  (section i64)
  (checksums bool))

(define (new) : Debug
  (Debug (paths.new) (functions.new) (ids.new) -1 false))

(define (number! [args : (& str)] [cursor : (&mut i64)]) : dir.Number
  (let
    [n (string.string-length args)]
    [start (op.skip-whitespace args (deref cursor) n)]
    [end (x64.word-end-at args start)]
    (when (= start end) (return (Err "missing CodeView operand")))
    (set! (deref cursor) end)
    (match (op.integer-literal-range args start end)
      [(Integer value) (Ok value)]
      [_ (Err "invalid CodeView operand")])))

(define (record!
  [debug : (&mut cv Debug)]
  [image : (&mut asm.Image)]
  [word : (& str)]
  [args : (& str)]
  [scratch : arena.Arena]) : asm.Status
  (let
    [i : i64 0]
    [n (string.string-length args)]
    [section image.current]
    (cond
      [(string.eq word ".cv_file")
        (let
          [id (try (number! args (&mut i)))]
          [path (buf.byte-buf-builder-new)]
          (unless
            (= id (+ 1 debug.files.len))
            (return (Err "invalid CodeView file ID")))
          (try (dir.literal! (&mut path) (& (op.range args i n))))
          (paths.push-ref!
            (&mut debug.files)
            (buf.byte-buf-builder-finish-string (& path))))]
      [(string.eq word ".cv_func_id")
        (let
          [id (try (dir.number args))]
          (unless
            (= id debug.functions.len)
            (return (Err "invalid CodeView function ID")))
          (functions.push-ref!
            (&mut debug.functions)
            (Function (lines.new) -1 -1 false)))]
      [(string.eq word ".cv_loc")
        (let
          [id (try (number! args (&mut i)))]
          [file (try (number! args (&mut i)))]
          [line (try (number! args (&mut i)))]
          [col (try (number! args (&mut i)))]
          (unless
            (and
              (= i n)
              (>= id 0)
              (< id debug.functions.len)
              (> file 0)
              (<= file debug.files.len)
              (>= line 0)
              (<= line 0xffffff)
              (>= col 0)
              (<= col 65535))
            (return (Err "invalid CodeView location")))
          (let
            [f : (&mut cv Function) (&mut (array-ref debug.functions.slots id))]
            (when (> col 0) (set! f.columns true))
            (lines.push-ref!
              (&mut f.rows)
              (Line
                (asm.position (& (array-ref image.items.slots section)) section)
                file
                line
                col))))]
      [else
        (unless
          (string.eq (& (array-ref image.items.slots section).name) ".debug$S")
          (return (Err "CodeView subsection outside .debug$S")))
        (cond
          [(string.eq word ".cv_stringtable")
            (unless
              (and (= n 0) (< debug.section 0))
              (return (Err "invalid CodeView string table")))
            (set! debug.section section)
            (when
              (< (array-ref image.items.slots section).alignment 4)
              (set! (array-ref image.items.slots section).alignment 4))]
          [(string.eq word ".cv_filechecksums")
            (unless
              (and (= n 0) (= debug.section section) (not debug.checksums))
              (return (Err "invalid CodeView checksums table")))
            (set! debug.checksums true)]
          [(string.eq word ".cv_linetable")
            (let
              [id
                (try
                  (dir.number
                    (& (in-arena scratch (dir.argument args (&mut i))))))]
              [start
                (sym.named!
                  (&mut image.table)
                  (& (in-arena scratch (dir.argument args (&mut i)))))]
              [end
                (sym.named!
                  (&mut image.table)
                  (& (in-arena scratch (dir.argument args (&mut i)))))]
              (unless
                (and
                  debug.checksums
                  (> i n)
                  (>= id 0)
                  (< id debug.functions.len)
                  (>= start 0)
                  (>= end 0)
                  (< (array-ref debug.functions.slots id).begin-id 0))
                (return (Err "invalid CodeView line table")))
              (set! (array-ref debug.functions.slots id).begin-id start)
              (set! (array-ref debug.functions.slots id).end-id end)
              (ids.push-ref! (&mut debug.tables) id))]
          [else (return (Err "unknown CodeView directive"))])])
    (Ok unit)))

(define (write-lines!
  [debug : (& cv Debug)]
  [image : (&mut img asm.Image)]
  [values : (& vals resolve.Values)]
  [f : (& cv Function)]
  [out : (&mut buf.ByteBufBuilder)]) : asm.Status
  (let
    [start : (& vals resolve.Value) (& (array-ref values.items f.begin-id))]
    [end : (& vals resolve.Value) (& (array-ref values.items f.end-id))]
    [header out.len]
    [i : i64 0]
    (unless
      (and
        (>= start.section 0)
        (= start.section end.section)
        (>= end.offset start.offset))
      (return (Err "invalid CodeView function extent")))
    (byte_le.push-u32! out 0xf2)
    (byte_le.push-u32! out 0)
    (let
      [s : (&mut img asm.Section)
        (&mut (array-ref image.items.slots debug.section))]
      (asm.add-rela! s out.len (Named f.begin-id) 11 0)
      (byte_le.push-u32! out 0)
      (asm.add-rela! s out.len (Named f.begin-id) 10 0)
      (byte_le.push-u16! out 0))
    (byte_le.push-u16!
      out
      (if f.columns
        1
        0))
    (byte_le.push-u32! out (- end.offset start.offset))
    (while (< i f.rows.len)
      (let
        [file (array-ref f.rows.slots i).file]
        [first i]
        (while (and (< i f.rows.len) (= (array-ref f.rows.slots i).file file))
          (+= i 1))
        (byte_le.push-u32! out (* (- file 1) 8))
        (byte_le.push-u32! out (- i first))
        (byte_le.push-u32!
          out
          (+
            12
            (*
              (- i first)
              (if f.columns
                12
                8))))
        (for [j (iterator.range first i)]
          (let
            [line : (& cv Line) (& (array-ref f.rows.slots j))]
            [delta
              (-
                (asm.label-address
                  (& (array-ref image.items.slots line.at.section))
                  (& line.at))
                start.offset)]
            (unless
              (and
                (= line.at.section start.section)
                (>= delta 0)
                (<= delta (- end.offset start.offset)))
              (return (Err "CodeView location outside function")))
            (byte_le.push-u32! out delta)
            (byte_le.push-u32! out line.line)))
        (when
          f.columns
          (for [j (iterator.range first i)]
            (byte_le.push-u32! out (array-ref f.rows.slots j).column)))))
    (byte_le.set-u32! (&mut out.slots) (+ header 4) (- out.len (+ header 8)))
    (Ok unit)))

(define (generate!
  [debug : (& cv Debug)]
  [image : (&mut asm.Image)]
  [values : (& resolve.Values)]
  [raw : (&mut bytes (__tl_dyn-array buf.ByteBufBuilder))]) : asm.Status
  (when (< debug.section 0) (return (Ok unit)))
  (let
    [out : (&mut bytes buf.ByteBufBuilder)
      (&mut (array-ref (deref raw) debug.section))]
    [header out.len]
    [offsets (__tl_make-array i64 debug.files.len)]
    (unless
      (and (= header 4) (= (byte_le.read-u32 (& out.slots) 0) 4))
      (return (Err "invalid CodeView C13 header")))
    (byte_le.push-u32! out 0xf3)
    (byte_le.push-u32! out 0)
    (asm.emit-le! out 0 1)
    (for [i (iterator.range 0 debug.files.len)]
      (set! (array-ref offsets i) (- out.len (+ header 8)))
      (let
        [file : (& cv str) (& (array-ref debug.files.slots i))]
        (for [j (iterator.range 0 (string.string-length file))]
          (asm.emit-le! out (cast (string.string-ref file j) : i64) 1))
        (asm.emit-le! out 0 1)))
    (asm.emit-le! out 0 (% (- 4 (% out.len 4)) 4))
    (byte_le.set-u32! (&mut out.slots) (+ header 4) (- out.len (+ header 8)))
    (when
      debug.checksums
      (byte_le.push-u32! out 0xf4)
      (byte_le.push-u32! out (* debug.files.len 8))
      (for [i (iterator.range 0 debug.files.len)]
        (byte_le.push-u32! out (array-ref offsets i))
        (byte_le.push-u32! out 0)))
    (for [i (iterator.range 0 debug.tables.len)]
      (try
        (write-lines!
          debug
          image
          values
          (& (array-ref debug.functions.slots (array-ref debug.tables.slots i)))
          out)))
    (set! (array-ref image.items.slots debug.section).size out.len)
    (Ok unit)))
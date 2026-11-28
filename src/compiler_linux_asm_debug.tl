;; DWARF and call-frame programs use final fragment offsets. Every address
;; entering a non-allocating debug section retains a relocation to its code.
(import compiler_linux_asm_layout as asm)
(import compiler_linux_asm_directives as dir)
(import compiler_linux_asm_symbols as sym)
(import compiler_linux_asm_resolve as resolve)
(import compiler_x64_encode as x64)
(import compiler_x64_encode_operands as op)
(import stdlib.byte_buf_core as buf)
(import stdlib.byte_le)
(import stdlib.leb128)
(import stdlib.string)
(import stdlib.iterator)
(import stdlib.vector)

(defenum Action
  (Line i64 i64 i64)
  (Start)
  (End)
  (CfaOffset i64)
  (CfaRegister i64)
  (RegisterOffset i64 i64))

(defstruct Event
  (at sym.Position)
  (action Action))

(import (vector.vector Event core) as events)
(import (vector.vector events.Vec core) as lists)
(import (vector.vector String core) as files)

(defstruct Debug
  (paths files.Vec)
  (by-section lists.Vec)
  (lines bool)
  (frames bool))

(define (new) : Debug
  (Debug (files.new) (lists.new) false false))

(define (reg [name : (& str)]) : dir.Number
  (match (string.copy name)
    ["%rax" (Ok 0)]
    ["%rdx" (Ok 1)]
    ["%rcx" (Ok 2)]
    ["%rbx" (Ok 3)]
    ["%rsi" (Ok 4)]
    ["%rdi" (Ok 5)]
    ["%rbp" (Ok 6)]
    ["%rsp" (Ok 7)]
    ["%r8" (Ok 8)]
    ["%r9" (Ok 9)]
    ["%r10" (Ok 10)]
    ["%r11" (Ok 11)]
    ["%r12" (Ok 12)]
    ["%r13" (Ok 13)]
    ["%r14" (Ok 14)]
    ["%r15" (Ok 15)]
    ["%rip" (Ok 16)]
    [_ (Err "unknown .cfi register")]))

(define (record!
  [debug : (&mut Debug)]
  [image : (& asm.Image)]
  [word : (& str)]
  [args : (& src str)]) : asm.Status
  (let
    [n (string.string-length args)]
    [head (x64.word-end args)]
    [first : String (op.range args 0 head)]
    [rest : String (op.range args head n)]
    (when
      (string.eq word ".file")
      (let
        [num (try (dir.number (& first)))]
        [path (buf.byte-buf-builder-new)]
        (unless
          (and (> num 0) (<= num (+ debug.paths.len 1)))
          (return (Err "invalid .file number")))
        (try (dir.literal! (&mut path) (& rest)))
        (let
          [name (buf.byte-buf-builder-finish-string (& path))]
          (if (> num debug.paths.len)
            (files.push-ref! (&mut debug.paths) name)
            (unless
              (string.eq (& (array-ref debug.paths.slots (- num 1))) (& name))
              (return (Err ".file number redefined"))))))
      (return (Ok unit)))
    (unless (string.eq word ".loc") (set! debug.frames true))
    (let
      [act : Action
        (cond
          [(string.eq word ".loc")
            (let
              [file (try (dir.number (& first)))]
              [k (x64.word-end (& rest))]
              [line (try (dir.number (& (op.range (& rest) 0 k))))]
              [column-text : String
                (op.range (& rest) k (string.string-length (& rest)))]
              [col : i64
                (if (= 0 (string.string-length (& column-text)))
                  0
                  (try (dir.number (& column-text))))]
              (unless
                (and
                  (> file 0)
                  (<= file debug.paths.len)
                  (>= line 0)
                  (>= col 0))
                (return (Err "invalid .loc")))
              (set! debug.lines true)
              (Line file line col))]
          [(string.eq word ".cfi_startproc") (Start)]
          [(string.eq word ".cfi_endproc") (End)]
          [(string.eq word ".cfi_def_cfa_offset")
            (CfaOffset (try (dir.number args)))]
          [(string.eq word ".cfi_def_cfa_register")
            (CfaRegister (try (reg args)))]
          [(string.eq word ".cfi_offset")
            (let
              [i : i64 0]
              [r (try (reg (& (dir.argument args (&mut i)))))]
              [offset (try (dir.number (& (dir.argument args (&mut i)))))]
              (unless
                (and (<= offset 0) (= 0 (% offset 8)))
                (return (Err "invalid .cfi_offset")))
              (RegisterOffset r (/ offset -8)))]
          [else (return (Err "unsupported .cfi directive"))])]
      [id image.current]
      [pos (asm.position (& (array-ref image.items.slots id)) id)]
      (while (<= debug.by-section.len id)
        (lists.push-ref! (&mut debug.by-section) (events.new)))
      (events.push-ref!
        (&mut (array-ref debug.by-section.slots id))
        (Event pos act))
      (Ok unit))))

(define (u8! [b : (&mut buf.ByteBufBuilder)] [v : i64]) : unit
  (buf.byte-buf-builder-push b (cast v : u8)))

(define (address!
  [s : (&mut asm.Section)]
  [section : i64]
  [offset : i64]
  [width : i64]
  [ty : i64]) : unit
  (asm.add-rela! s s.raw.len (SectionAddress section) ty offset)
  (asm.emit-le! (&mut s.raw) 0 width))

(define (cstring! [b : (&mut buf.ByteBufBuilder)] [s : (& str)]) : unit
  (buf.byte-buf-builder-append-string b (string.copy s))
  (u8! b 0))

(define (line-header! [b : (&mut buf.ByteBufBuilder)] [debug : (& Debug)]) : unit
  (byte_le.push-u32! b 0)
  (byte_le.push-u16! b 3)
  (byte_le.push-u32! b 0)
  ;; minimum instruction length, default is_stmt, line base, line range,
  ;; opcode base, and the operand counts of standard opcodes 1..12.
  (let
    [header : (Array u8 17) (array 1 1 251 14 13 0 1 1 1 1 0 0 0 1 0 0 1)]
    (for [i (iterator.range 0 17)]
      (buf.byte-buf-builder-push b (array-ref header i))))
  (u8! b 0)
  (for [i (iterator.range 0 debug.paths.len)]
    (cstring! b (& (array-ref debug.paths.slots i)))
    (u8! b 0)
    (u8! b 0)
    (u8! b 0))
  (u8! b 0)
  (byte_le.set-u32! (&mut b.slots) 6 (- b.len 10)))

(define (line-program!
  [s : (&mut asm.Section)]
  [code : (& asm.Section)]
  [id : i64]
  [rows : (& rows events.Vec)]) : bool
  (let
    [pc : i64 0]
    [line : i64 1]
    [file : i64 1]
    [col : i64 0]
    [started false]
    (for [i (iterator.range 0 rows.len)]
      (let
        [row : (& rows Event) (& (array-ref rows.slots i))]
        (match row.action
          [(Line f ln c)
            (let
              [at (asm.label-address code (& row.at))]
              (unless
                started
                (u8! (&mut s.raw) 0)
                (u8! (&mut s.raw) 9)
                (u8! (&mut s.raw) 2)
                (address! s id at 8 1)
                (set! started true)
                (set! pc at))
              (unless
                (= f file)
                (u8! (&mut s.raw) 4)
                (leb128.push-unsigned! (&mut s.raw) f)
                (set! file f))
              (unless
                (= c col)
                (u8! (&mut s.raw) 5)
                (leb128.push-unsigned! (&mut s.raw) c)
                (set! col c))
              (unless
                (= ln line)
                (u8! (&mut s.raw) 3)
                (leb128.push-signed! (&mut s.raw) (- ln line))
                (set! line ln))
              (unless
                (= at pc)
                (u8! (&mut s.raw) 2)
                (leb128.push-unsigned! (&mut s.raw) (- at pc))
                (set! pc at))
              (u8! (&mut s.raw) 1))]
          [_ unit])))
    (when
      started
      (u8! (&mut s.raw) 2)
      (leb128.push-unsigned! (&mut s.raw) (- code.size pc))
      (u8! (&mut s.raw) 0)
      (u8! (&mut s.raw) 1)
      (u8! (&mut s.raw) 1))
    started))

(define (cie! [s : (&mut asm.Section)]) : unit
  (let
    [b : (Array u8 24)
      (array 20 0 0 0 0 0 0 0 1 122 82 0 1 120 16 1 27 12 7 8 144 1 0 0)]
    (for [i (iterator.range 0 24)]
      (buf.byte-buf-builder-push (&mut s.raw) (array-ref b i))))
  (set! s.alignment 8))

(define (advance! [b : (&mut buf.ByteBufBuilder)] [n : i64]) : unit
  (cond
    [(= n 0) unit]
    [(< n 64) (u8! b (+ 64 n))]
    [(< n 256)
      (u8! b 2)
      (u8! b n)]
    [(< n 65536)
      (u8! b 3)
      (byte_le.push-u16! b n)]
    [else
      (u8! b 4)
      (byte_le.push-u32! b n)]))

(define (frame-program!
  [s : (&mut asm.Section)]
  [code : (& asm.Section)]
  [id : i64]
  [rows : (& rows events.Vec)]) : asm.Status
  (let
    [fde : i64 -1]
    [start : i64 0]
    [pc : i64 0]
    (for [i (iterator.range 0 rows.len)]
      (let
        [row : (& rows Event) (& (array-ref rows.slots i))]
        [at (asm.label-address code (& row.at))]
        (match row.action
          [(Line _ _ _) unit]
          [(Start)
            (when (>= fde 0) (return (Err "nested .cfi_startproc")))
            (set! fde s.raw.len)
            (set! start at)
            (set! pc at)
            (byte_le.push-u32! (&mut s.raw) 0)
            (byte_le.push-u32! (&mut s.raw) (+ fde 4))
            (address! s id at 4 2)
            (byte_le.push-u32! (&mut s.raw) 0)
            (u8! (&mut s.raw) 0)]
          [(End)
            (when (< fde 0) (return (Err ".cfi_endproc without start")))
            (while (!= 0 (% s.raw.len 4))
              (u8! (&mut s.raw) 0))
            (byte_le.set-u32! (&mut s.raw.slots) fde (- s.raw.len (+ fde 4)))
            (byte_le.set-u32! (&mut s.raw.slots) (+ fde 12) (- at start))
            (set! fde -1)]
          [_
            (when (< fde 0) (return (Err ".cfi directive outside a procedure")))
            (advance! (&mut s.raw) (- at pc))
            (set! pc at)
            (match row.action
              [(CfaOffset v)
                (u8! (&mut s.raw) 14)
                (leb128.push-unsigned! (&mut s.raw) v)]
              [(CfaRegister r)
                (u8! (&mut s.raw) 13)
                (leb128.push-unsigned! (&mut s.raw) r)]
              [(RegisterOffset r offset)
                (u8! (&mut s.raw) (+ 128 r))
                (leb128.push-unsigned! (&mut s.raw) offset)]
              [_ unit])])))
    (if (< fde 0)
      (Ok unit)
      (Err "unclosed .cfi_startproc"))))

(define (abbreviations! [s : (&mut asm.Section)]) : unit
  ;; A DWARF 4 compilation unit with section ranges, followed by subprogram
  ;; DIEs. high_pc is an unsigned size relative to low_pc.
  (let
    [bytes : (Array u8 29)
      (array
        1
        17
        1
        16
        23
        85
        23
        3
        8
        37
        8
        19
        5
        0
        0
        2
        46
        0
        3
        8
        63
        12
        17
        1
        18
        7
        0
        0
        0)]
    (for [i (iterator.range 0 29)]
      (buf.byte-buf-builder-push (&mut s.raw) (array-ref bytes i)))))

(define (generate!
  [debug : (& d Debug)]
  [image : (&mut img asm.Image)]
  [values : (&mut resolve.Values)]) : asm.Status
  (unless (or debug.lines debug.frames) (return (Ok unit)))
  (let
    [lines (asm.new-section ".debug_line" 1 0 0 -1 "")]
    [ranges (asm.new-section ".debug_ranges" 1 0 0 -1 "")]
    [info (asm.new-section ".debug_info" 1 0 0 -1 "")]
    [abbrev (asm.new-section ".debug_abbrev" 1 0 0 -1 "")]
    [frames (asm.new-section ".eh_frame" 1 2 0 -1 "")]
    [line-id image.items.len]
    [range-id (+ line-id 1)]
    [abbrev-id (+ line-id 2)]
    (when debug.frames (cie! (&mut frames)))
    (when debug.lines (line-header! (&mut lines.raw) debug))
    (for [i (iterator.range 0 debug.by-section.len)]
      (let
        [code : (& img asm.Section) (& (array-ref image.items.slots i))]
        [rows : (& d events.Vec) (& (array-ref debug.by-section.slots i))]
        (when
          (and debug.lines (line-program! (&mut lines) code i rows))
          (address! (&mut ranges) i 0 8 1)
          (address! (&mut ranges) i code.size 8 1))
        (when debug.frames (try (frame-program! (&mut frames) code i rows)))))
    (when
      debug.lines
      (byte_le.set-u32! (&mut lines.raw.slots) 0 (- lines.raw.len 4))
      (byte_le.push-u64! (&mut ranges.raw) 0)
      (byte_le.push-u64! (&mut ranges.raw) 0)
      (abbreviations! (&mut abbrev))
      (byte_le.push-u32! (&mut info.raw) 0)
      (byte_le.push-u16! (&mut info.raw) 4)
      (address! (&mut info) abbrev-id 0 4 10)
      (u8! (&mut info.raw) 8)
      (u8! (&mut info.raw) 1)
      (address! (&mut info) line-id 0 4 10)
      (address! (&mut info) range-id 0 4 10)
      (cstring! (&mut info.raw) (& (array-ref debug.paths.slots 0)))
      (cstring! (&mut info.raw) "TypeLisp")
      (byte_le.push-u16! (&mut info.raw) 0x8001)
      (for [i (iterator.range 0 image.table.entries.len)]
        (let
          [s : (& img sym.Symbol) (& (array-ref image.table.entries.slots i))]
          (when
            (and (= s.kind 2) (>= (array-ref values.items i).section 0))
            (let
              [dot (resolve.at-position image (& s.size-origin))]
              [size (try (resolve.evaluate! image values (& s.size) (& dot)))]
              (u8! (&mut info.raw) 2)
              (cstring! (&mut info.raw) (& s.name))
              (u8!
                (&mut info.raw)
                (if (> s.binding 0)
                  1
                  0))
              (address!
                (&mut info)
                (array-ref values.items i).section
                (array-ref values.items i).offset
                8
                1)
              (byte_le.push-u64! (&mut info.raw) size.offset)))))
      (u8! (&mut info.raw) 0)
      (byte_le.set-u32! (&mut info.raw.slots) 0 (- info.raw.len 4))
      (try (asm.append-generated! image lines))
      (try (asm.append-generated! image ranges))
      (try (asm.append-generated! image abbrev))
      (try (asm.append-generated! image info)))
    (when debug.frames (try (asm.append-generated! image frames)))
    (Ok unit)))
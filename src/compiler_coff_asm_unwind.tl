(import stdlib.arena)

;; Record anchors while parsing. Relaxation fixes their byte offsets before
;; UNWIND_INFO and RUNTIME_FUNCTION rows are appended to their sections.
(import compiler_linux_asm_directives as dir)
(import compiler_linux_asm_layout as asm)
(import compiler_linux_asm_symbols as sym)
(import compiler_x64_encode_operands as op)
(import stdlib.byte_buf_core as buf)
(import stdlib.string)
(import stdlib.iterator)
(import stdlib.vector)

(defstruct Action
  (at sym.Position)
  (opcode i64)
  (operand i64)
  (extra i64))

(import (vector.vector Action core) as actions)

(defstruct Procedure
  (symbol i64)
  (start sym.Position)
  (prologue sym.Position)
  (end sym.Position)
  (frame i64)
  (first i64)
  (count i64)
  (slots i64)
  (xdata i64)
  (pdata i64))

(import (vector.vector Procedure core) as procedures)

(defstruct Unwind
  (procedures procedures.Vec)
  (actions actions.Vec)
  (active bool))

(define (new) : Unwind
  (Unwind (procedures.new) (actions.new) false))

(define (metadata!
  [image : (&mut img asm.Image)]
  [name : (& str)]
  [group : i64]) : asm.Status
  (try
    (asm.select-section!
      image
      name
      1
      0
      (if (< group 0)
        0
        5)
      group
      ""))
  (let
    [section : (&mut img asm.Section)
      (&mut (array-ref image.items.slots image.current))]
    (when (< section.alignment 4) (set! section.alignment 4)))
  (Ok unit))

(define (record!
  [state : (&mut u Unwind)]
  [image : (&mut img asm.Image)]
  [word : (& str)]
  [args : (& str)]
  [scratch : arena.Arena]) : asm.Status
  (let
    [section image.current]
    [at (asm.position (& (array-ref image.items.slots section)) section)]
    (when
      (string.eq word ".seh_proc")
      (when state.active (return (Err "nested .seh_proc")))
      (let
        [id (sym.named! (&mut image.table) args)]
        (when
          (or
            (< id 0)
            (= 0 (bit-and (array-ref image.items.slots section).flags 4)))
          (return (Err "invalid .seh_proc")))
        (procedures.push-ref!
          (&mut state.procedures)
          (Procedure
            id
            at
            (sym.Position -1 0 0)
            at
            0
            state.actions.len
            0
            0
            -1
            -1))
        (set! state.active true))
      (return (Ok unit)))
    (unless state.active (return (Err "unwind directive outside procedure")))
    (let
      [p : (&mut u Procedure)
        (&mut (array-ref state.procedures.slots (- state.procedures.len 1)))]
      (when
        (!= section p.start.section)
        (return (Err "unwind directive in wrong section")))
      (when
        (string.eq word ".seh_endproc")
        (unless
          (string.eq args "")
          (return (Err "unexpected .seh_endproc operand")))
        (let
          [group (array-ref image.items.slots section).group]
          (try (metadata! image ".xdata" group))
          (set! p.xdata image.current)
          (try (metadata! image ".pdata" group))
          (set! p.pdata image.current)
          (set! image.current section))
        (set! p.end at)
        (set! state.active false)
        (return (Ok unit)))
      (when
        (>= p.prologue.section 0)
        (return (Err "unwind action after prologue")))
      (when
        (string.eq word ".seh_endprologue")
        (unless
          (string.eq args "")
          (return (Err "unexpected .seh_endprologue operand")))
        (set! p.prologue at)
        (return (Ok unit)))
      (let
        [i : i64 0]
        [first (in-arena scratch (dir.argument args (&mut i)))]
        [reg (in-arena scratch (op.register (& first)))]
        [opcode : i64 0]
        [operand : i64 0]
        [extra : i64 0]
        (cond
          [(string.eq word ".seh_stackalloc")
            (let
              [n (try (dir.number (& first)))]
              (unless
                (and (> n 0) (= (% n 8) 0) (<= n 0xffffffff))
                (return (Err "invalid SEH allocation")))
              (cond
                [(<= n 128) (set! opcode (+ 2 (shl (- (/ n 8) 1) 4)))]
                [(<= n 524280)
                  (set! opcode 1)
                  (set! extra 1)
                  (set! operand (/ n 8))]
                [else
                  (set! opcode 17)
                  (set! extra 2)
                  (set! operand n)]))]
          [else
            (unless
              (and
                (>= reg.number 0)
                (< reg.number 16)
                (=
                  reg.width
                  (if (string.eq word ".seh_savexmm")
                    16
                    8)))
              (return (Err "invalid unwind register")))
            (if (string.eq word ".seh_pushreg")
              (set! opcode (shl reg.number 4))
              (let
                [n
                  (try
                    (dir.number
                      (& (in-arena scratch (dir.argument args (&mut i))))))]
                (cond
                  [(string.eq word ".seh_setframe")
                    (unless
                      (and
                        (= p.frame 0)
                        (> reg.number 0)
                        (>= n 0)
                        (<= n 240)
                        (= (% n 16) 0))
                      (return (Err "invalid SEH frame")))
                    (set! p.frame (+ n reg.number))
                    (set! opcode 3)]
                  [(or
                      (string.eq word ".seh_savereg")
                      (string.eq word ".seh_savexmm"))
                    (let
                      [scale : i64
                        (if (= reg.width 16)
                          16
                          8)]
                      (unless
                        (and (>= n 0) (<= n 0xffffffff) (= (% n scale) 0))
                        (return (Err "invalid unwind save offset")))
                      (set!
                        opcode
                        (+
                          (shl reg.number 4)
                          (if (= scale 16)
                            8
                            4)))
                      (if (<= (/ n scale) 65535)
                        (begin
                          (set! extra 1)
                          (set! operand (/ n scale)))
                        (begin
                          (+= opcode 1)
                          (set! extra 2)
                          (set! operand n))))]
                  [else (return (Err "unknown SEH action"))])))])
        (when
          (<= i (string.string-length args))
          (return (Err "extra unwind operand")))
        (+= p.slots (+ 1 extra))
        (when (> p.slots 255) (return (Err "too many unwind codes")))
        (actions.push-ref!
          (&mut state.actions)
          (Action at opcode operand extra))
        (+= p.count 1)
        (Ok unit)))))

(define (address [image : (& asm.Image)] [p : (& sym.Position)]) : i64
  (asm.label-address (& (array-ref image.items.slots p.section)) p))

(define (pad4! [out : (&mut buf.ByteBufBuilder)]) : unit
  (asm.emit-le! out 0 (% (- 4 (% out.len 4)) 4)))

(define (rva!
  [s : (&mut asm.Section)]
  [out : (&mut buf.ByteBufBuilder)]
  [target : i64]
  [offset : i64]) : unit
  (asm.add-rela! s out.len (SectionAddress target) 3 offset)
  (asm.emit-le! out 0 4))

(define (generate!
  [state : (& u Unwind)]
  [image : (&mut img asm.Image)]
  [raw : (&mut bytes (__tl_dyn-array buf.ByteBufBuilder))]) : asm.Status
  (for [i (iterator.range 0 state.procedures.len)]
    (let
      [p : (& u Procedure) (& (array-ref state.procedures.slots i))]
      [start (address image (& p.start))]
      [end (address image (& p.end))]
      [decl : (& img sym.Position)
        (& (array-ref image.table.entries.slots p.symbol).position)]
      [size
        (if (< p.prologue.section 0)
          0
          (- (address image (& p.prologue)) start))]
      (unless
        (and
          (= decl.section p.start.section)
          (= (address image decl) start)
          (<= size 255))
        (return (Err "invalid SEH procedure bounds")))
      (pad4! (&mut (array-ref (deref raw) p.xdata)))
      (let
        [record (array-ref (deref raw) p.xdata).len]
        [pdata : (&mut bytes buf.ByteBufBuilder)
          (&mut (array-ref (deref raw) p.pdata))]
        [s : (&mut img asm.Section)
          (&mut (array-ref image.items.slots p.pdata))]
        (pad4! pdata)
        (rva! s pdata p.start.section start)
        (rva! s pdata p.start.section end)
        (rva! s pdata p.xdata record)
        (set! s.size pdata.len))
      (let
        [x : (&mut bytes buf.ByteBufBuilder)
          (&mut (array-ref (deref raw) p.xdata))]
        (asm.emit-le! x 1 1)
        (asm.emit-le! x size 1)
        (asm.emit-le! x p.slots 1)
        (asm.emit-le! x p.frame 1)
        (for [j (iterator.range 0 p.count)]
          (let
            [a : (& u Action)
              (&
                (array-ref state.actions.slots (- (+ p.first p.count) (+ j 1))))]
            [offset (- (address image (& a.at)) start)]
            (when (> offset 255) (return (Err "SEH action offset exceeds 255")))
            (asm.emit-le! x offset 1)
            (asm.emit-le! x a.opcode 1)
            (asm.emit-le! x a.operand (* 2 a.extra))))
        (when (= p.slots 0) (asm.emit-le! x 0 4))
        (pad4! x)
        (set! (array-ref image.items.slots p.xdata).size x.len))))
  (Ok unit))
(import compiler_linux_asm_layout as asm)
(import compiler_linux_asm_symbols as sym)
(import compiler_x64_encode_operands as op)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.byte_buf_core as buf)

(define (argument [text : (& str)] [cursor : (&mut i64)]) : String
  (let
    [start (deref cursor)]
    [n (string.string-length text)]
    (when (> start n) (return ""))
    (let
      [end (op.delimiter text start ',')]
      (set! (deref cursor) (+ end 1))
      (op.range text start end))))

(define (unquoted [s : String]) : String
  (let
    [n (string.string-length (& s))]
    (if (and
      (>= n 2)
      (= (string.string-ref (& s) 0) '"')
      (= (string.string-ref (& s) (- n 1)) '"'))
      (string.substring (& s) 1 (- n 2))
      s)))

(defenum Number
  (Ok i64)
  (Err String))

(define (number [s : (& str)]) : Number
  (when
    (= (string.string-length s) 0)
    (return (Err "missing assembly integer")))
  (match (op.integer-literal s)
    [(Integer n) (Ok n)]
    [_ (Err (str_cat.str-cat "expected assembly integer: " (string.copy s)))]))

(define (section! [image : (&mut asm.Image)] [args : (& src str)]) : asm.Status
  (let
    [i : i64 0]
    [name : String (unquoted (argument args (&mut i)))]
    (when
      (= (string.string-length (& name)) 0)
      (return (Err "missing section name")))
    (when
      (> i (string.string-length args))
      (return (asm.select-section! image (& name) 0 0 0 -1 "")))
    (let
      [flags-text : String (unquoted (argument args (&mut i)))]
      [type-text : String (argument args (&mut i))]
      [ty : i64
        (cond
          [(string.eq (& type-text) "@nobits") 8]
          [(or
              (string.eq (& type-text) "")
              (string.eq (& type-text) "@progbits"))
            1]
          [else (return (Err "unknown section type"))])]
      [j : i64 0]
      [flags : i64 0]
      [ent : i64 0]
      [group : i64 -1]
      (while (< j (string.string-length (& flags-text)))
        (let
          [flag : i64
            (match (string.string-ref (& flags-text) j)
              ['w' 1]
              ['a' 2]
              ['x' 4]
              ['M' 16]
              ['S' 32]
              ['o' 128]
              ['G' 512]
              ['T' 1024]
              [_ (return (Err "unknown ELF section flag"))])]
          (set! flags (bit-or flags flag)))
        (+= j 1))
      (when
        (!= 0 (bit-and flags 16))
        (set! ent (try (number (& (argument args (&mut i)))))))
      (let
        [link : String
          (if (!= 0 (bit-and flags 128))
            (argument args (&mut i))
            "")]
        (when
          (!= 0 (bit-and flags 512))
          (set!
            group
            (sym.intern! (&mut image.table) (& (argument args (&mut i)))))
          (let
            [group-kind (argument args (&mut i))]
            (unless
              (string.eq (& group-kind) "comdat")
              (return (Err "expected comdat group")))))
        (asm.select-section! image (& name) ty flags ent group (& link))))))

(define (label! [image : (&mut asm.Image)] [name : (& str)]) : asm.Status
  (let
    [id : i64
      (cond
        [(sym.digits? name)
          (let
            [key (sym.numeric-name! (&mut image.table) name ':')]
            (sym.intern! (&mut image.table) (& key)))]
        [else (sym.named! (&mut image.table) name)])]
    [pos
      (asm.position
        (& (array-ref image.items.slots image.current))
        image.current)]
    (when (< id 0) (return (Err "invalid assembly label")))
    (when
      (>= (array-ref image.table.entries.slots id).position.section 0)
      (return
        (Err (str_cat.str-cat "duplicate assembly label: " (string.copy name)))))
    (set! (array-ref image.table.entries.slots id).position pos)
    (Ok unit)))

(define (attribute!
  [image : (&mut img asm.Image)]
  [dir : (& str)]
  [args : (& src str)]) : asm.Status
  (let
    [i : i64 0]
    [name : String (argument args (&mut i))]
    [id (sym.named! (&mut image.table) (& name))]
    [at
      (asm.position
        (& (array-ref image.items.slots image.current))
        image.current)]
    (when (< id 0) (return (Err "invalid symbol name")))
    (cond
      [(string.eq dir ".set")
        (let
          [expr
            (try
              (sym.parse-expression!
                (&mut image.table)
                (& (argument args (&mut i)))))]
          (set! (array-ref image.table.entries.slots id).alias expr)
          (set! (array-ref image.table.entries.slots id).position at)
          (set! (array-ref image.table.entries.slots id).is-alias true))]
      [(string.eq dir ".size")
        (let
          [expr
            (try
              (sym.parse-expression!
                (&mut image.table)
                (& (argument args (&mut i)))))]
          (set! (array-ref image.table.entries.slots id).size expr)
          (set! (array-ref image.table.entries.slots id).size-origin at))]
      [(string.eq dir ".comm")
        (let
          [size (try (number (& (argument args (&mut i)))))]
          [align
            (if (> i (string.string-length args))
              (cast 1 : i64)
              (try (number (& (argument args (&mut i))))))]
          (unless
            (and (>= size 0) (> align 0) (= 0 (bit-and align (- align 1))))
            (return (Err "invalid common allocation")))
          (if (= (array-ref image.table.entries.slots id).binding 0)
            (let
              [s : (&mut img asm.Section)
                (&mut (array-ref image.items.slots 3))]
              (try (asm.alignment! s align 0 0))
              (set!
                (array-ref image.table.entries.slots id).position
                (asm.position s 3))
              (asm.end-run! s (Fill size 0) size))
            (set! (array-ref image.table.entries.slots id).common-align align))
          (set! (array-ref image.table.entries.slots id).kind 1)
          (set!
            (array-ref image.table.entries.slots id).size
            (sym.constant size)))]
      [(string.eq dir ".type")
        (let
          [kind : i64
            (match (argument args (&mut i))
              ["@function" 2]
              ["@object" 1]
              ["@tls_object" 6]
              ["@notype" 0]
              [_ (return (Err "unsupported ELF symbol type"))])]
          (set! (array-ref image.table.entries.slots id).kind kind))]
      [(string.eq dir ".hidden")
        (set! (array-ref image.table.entries.slots id).visibility 2)]
      [(string.eq dir ".local")
        (set! (array-ref image.table.entries.slots id).binding 0)]
      [(string.eq dir ".weak")
        (set! (array-ref image.table.entries.slots id).binding 2)]
      [else (set! (array-ref image.table.entries.slots id).binding 1)])
    (Ok unit)))

(define (literal! [out : (&mut buf.ByteBufBuilder)] [text : (& str)]) : asm.Status
  (let
    [n (string.string-length text)]
    [i : i64 1]
    (unless
      (and
        (>= n 2)
        (= (string.string-ref text 0) '"')
        (= (string.string-ref text (- n 1)) '"'))
      (return (Err "expected quoted assembler string")))
    (while (< i (- n 1))
      (let
        [c (string.string-ref text i)]
        [value (cast c : i64)]
        (when
          (= c '\\')
          (+= i 1)
          (when (>= i (- n 1)) (return (Err "unterminated string escape")))
          (let
            [escaped (string.string-ref text i)]
            (set!
              value
              (match escaped
                ['n' 10]
                ['r' 13]
                ['t' 9]
                ['"' 34]
                ['\\' 92]
                [_
                  (let
                    [digits : i64 0]
                    [total : i64 0]
                    (while (and
                      (< digits 3)
                      (< i (- n 1))
                      (>= (string.string-ref text i) '0')
                      (<= (string.string-ref text i) '7'))
                      (set!
                        total
                        (+
                          (* total 8)
                          (- (cast (string.string-ref text i) : i64) 48)))
                      (+= digits 1)
                      (+= i 1))
                    (when (= digits 0) (return (Err "unknown string escape")))
                    (-= i 1)
                    total)]))))
        (buf.byte-buf-builder-push out (cast value : u8)))
      (+= i 1))
    (Ok unit)))

(define (directive!
  [image : (&mut img asm.Image)]
  [dir : (& str)]
  [args : (& src str)]) : asm.Status
  (cond
    [(string.eq dir ".section") (section! image args)]
    [(or
        (string.eq dir ".text")
        (string.eq dir ".data")
        (string.eq dir ".bss")
        (string.eq dir ".rodata"))
      (section! image dir)]
    ;; GNU as ignores .extern; a reference to an undefined name creates the
    ;; corresponding external symbol.
    [(string.eq dir ".extern") (Ok unit)]
    [(or
        (string.eq dir ".globl")
        (string.eq dir ".global")
        (string.eq dir ".local")
        (string.eq dir ".weak")
        (string.eq dir ".hidden")
        (string.eq dir ".type")
        (string.eq dir ".size")
        (string.eq dir ".comm")
        (string.eq dir ".set"))
      (attribute! image dir args)]
    [else
      (let
        [s : (&mut img asm.Section)
          (&mut (array-ref image.items.slots image.current))]
        [i : i64 0]
        [n (string.string-length args)]
        (cond
          [(or
              (string.eq dir ".align")
              (string.eq dir ".balign")
              (string.eq dir ".p2align"))
            (let
              [align (try (number (& (argument args (&mut i)))))]
              [fill-text : String (argument args (&mut i))]
              [fill : i64
                (if (= 0 (string.string-length (& fill-text)))
                  (if (!= 0 (bit-and s.flags 4))
                    -1
                    0)
                  (bit-and 255 (try (number (& fill-text)))))]
              [maximum : i64
                (if (<= i n)
                  (try (number (& (argument args (&mut i)))))
                  0)]
              (when
                (string.eq dir ".p2align")
                (unless
                  (and (>= align 0) (< align 31))
                  (return (Err "invalid alignment exponent")))
                (set! align (shl (cast 1 : i64) align)))
              (asm.alignment! s align fill maximum))]
          [(or (string.eq dir ".zero") (string.eq dir ".space"))
            (let
              [size (try (number (& (argument args (&mut i)))))]
              [fill : i64
                (if (<= i n)
                  (try (number (& (argument args (&mut i)))))
                  0)]
              (when
                (or (< size 0) (and (= s.ty 8) (!= fill 0)))
                (return (Err "invalid section fill")))
              (asm.end-run! s (Fill size (bit-and fill 255)) size)
              (Ok unit))]
          [(or
            (string.eq dir ".ascii")
            (string.eq dir ".asciz")
            (string.eq dir ".string"))
            (when (= s.ty 8) (return (Err "string in NOBITS section")))
            (while (<= i n)
              (try (literal! (&mut s.raw) (& (argument args (&mut i)))))
              (unless
                (string.eq dir ".ascii")
                (buf.byte-buf-builder-push (&mut s.raw) (cast 0 : u8))))
            (Ok unit)]
          [else
            (let
              [width : i64
                (match (string.copy dir)
                  [".byte" 1]
                  [".short" 2]
                  [".word" 2]
                  [".long" 4]
                  [".quad" 8]
                  [_
                    (return
                      (Err
                        (str_cat.str-cat
                          "unsupported assembly directive: "
                          (string.copy dir))))])]
              (while (<= i n)
                (let
                  [end (op.delimiter-before args i n ',')]
                  (try (asm.data-field! s (&mut image.table) args i end width))
                  (set! i (+ end 1))))
              (Ok unit))]))]))
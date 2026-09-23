;; Deterministic AMD64 import-library payloads. This module owns no archive
;; headers or linker index; each result is an ordered, self-contained member.
;; The caller chooses exports and passes the public symbol plus the intended
;; DLL import name (or an ordinal). Named modes encode the public symbol in the
;; short record; the import name is checked against the selected transformation.
(import stdlib.byte_buf_core as bytes)
(import stdlib.string)
(import stdlib.str_cat_runtime as cat)
(cfg test (import stdlib.test))
(cfg test (import stdlib.io))
(cfg test (import stdlib.byte_buf as byte_buf))

;; kind: code=0, data=1, const=2. name-mode: ordinal=0, exact=1,
;; no-prefix=2, undecorate=3. Ordinal mode requires hint=0 and import-name="";
;; named modes require ordinal=0. EXPORTAS=4 is deliberately unsupported.
(defstruct CoffImportPlan
  (public-name String)
  (import-name String)
  (ordinal i64)
  (hint i64)
  (kind i64)
  (name-mode i64))

;; The payload and symbol summary are owned snapshots. Physical archive member
;; names may repeat; array order is the wire order for a later archive writer.
(defstruct CoffImportMember
  (archive-name String)
  (payload String)
  (index-symbols (__tl_dyn-array String)))

(defstruct CoffImportLimits
  (max-exports i64)
  (max-string i64)
  (max-payload i64)
  (max-work i64))

(defenum ResultCoffImportMembers
  (Ok (__tl_dyn-array CoffImportMember))
  (Err String))

;; The limits are below COFF's u32 layout maximum and bound the quadratic
;; duplicate-symbol check. They are part of the encoder's public contract.
(define coff-import-max-name : i64
  4096)
(define coff-import-max-exports : i64
  1024)
(define coff-import-max-payload : i64
  16777216)
(define coff-import-max-work : i64
  4194304)

(defmacro (coff-import-len [s : Expr]) : Expr
  `(__tl_string_length ,s))

(defmacro (coff-import-char [s : Expr] [i : Expr]) : Expr
  `(__tl_string_ref ,s ,i))

(define (coff-import-valid-name? [s : (& s str)] [allow-dot : bool]) : bool
  (let
    [n : i64 (coff-import-len s)]
    [i : i64 0]
    [ok : bool (and (> n 0) (<= n coff-import-max-name))]
    (begin
      (while (and ok (< i n))
        (let
          [c : i64 (cast (coff-import-char s i) : i64)]
          (begin
            (if (or
              (< c 33)
              (> c 126)
              (= c 47)
              (= c 92)
              (and (not allow-dot) (= c 46)))
              (set! ok false)
              unit)
            (set! i (+ i 1)))))
      ok)))

(define (coff-import-valid-dll-part? [s : (& s str)]) : bool
  (and
    (coff-import-valid-name? s true)
    (not (string.contains-char s ':'))
    (not (string.contains-char s '*'))
    (not (string.contains-char s '?'))
    (not (string.contains-char s '"'))
    (not (string.contains-char s '<'))
    (not (string.contains-char s '>'))
    (not (string.contains-char s '|'))))

(define (coff-import-push8! [b : (&mut b bytes.ByteBufBuilder)] [v : i64]) : unit
  (bytes.byte-buf-builder-push b (cast (bit-and v 255) : u8)))

(define (coff-import-push16! [b : (&mut b bytes.ByteBufBuilder)] [v : i64]) : unit
  (begin
    (coff-import-push8! b v)
    (coff-import-push8! b (shr v 8))))

(define (coff-import-push32! [b : (&mut b bytes.ByteBufBuilder)] [v : i64]) : unit
  (begin
    (coff-import-push16! b v)
    (coff-import-push16! b (shr v 16))))

(define (coff-import-zero! [b : (&mut b bytes.ByteBufBuilder)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (coff-import-push8! b 0)
        (set! i (+ i 1))))))

(define (coff-import-text! [b : (&mut b bytes.ByteBufBuilder)] [s : String]) : unit
  (bytes.byte-buf-builder-append-string b s))

(define (coff-import-cstr! [b : (&mut b bytes.ByteBufBuilder)] [s : String]) : unit
  (begin
    (coff-import-text! b s)
    (coff-import-push8! b 0)))

(define (coff-import-null-thunk-name [stem : String]) : String
  (let
    [b : bytes.ByteBufBuilder
      (bytes.byte-buf-builder-with-capacity (+ 17 (coff-import-len stem)))]
    (begin
      (coff-import-push8! (&mut b) 127)
      (coff-import-text! (&mut b) stem)
      (coff-import-text! (&mut b) "_NULL_THUNK_DATA")
      (bytes.byte-buf-builder-to-string (& b)))))

(define (coff-import-stem-matches? [dll : String] [stem : String]) : bool
  (let
    [dll-len : i64 (coff-import-len dll)]
    [stem-len : i64 (coff-import-len stem)]
    (or
      (and
        (string.eq dll stem)
        (= (string.index-of-byte dll 0 (cast '.' : u8)) -1))
      (and
        (> dll-len (+ stem-len 1))
        (= (coff-import-char dll stem-len) '.')
        (= (string.index-of-byte dll (+ stem-len 1) (cast '.' : u8)) -1)
        (string.eq (string.substring dll 0 stem-len) stem)))))

(define (coff-import-header!
  [b : (&mut b bytes.ByteBufBuilder)]
  [sections : i64]
  [symbol-offset : i64]
  [symbols : i64]) : unit
  (begin
    (coff-import-push16! b 0x8664)
    (coff-import-push16! b sections)
    (coff-import-push32! b 0)
    ; TimeDateStamp
    (coff-import-push32! b symbol-offset)
    (coff-import-push32! b symbols)
    (coff-import-push16! b 0)
    ; optional header size
    (coff-import-push16! b 0)))

(define (coff-import-section!
  [b : (&mut b bytes.ByteBufBuilder)]
  [name : String]
  [size : i64]
  [raw : i64]
  [relocs : i64]
  [reloc-count : i64]
  [alignment : i64]) : unit
  (begin
    (coff-import-text! b (clone name))
    (coff-import-zero! b (- 8 (coff-import-len name)))
    (coff-import-push32! b 0)
    (coff-import-push32! b 0)
    (coff-import-push32! b size)
    (coff-import-push32! b raw)
    (coff-import-push32! b relocs)
    (coff-import-push32! b 0)
    (coff-import-push16! b reloc-count)
    (coff-import-push16! b 0)
    (coff-import-push32! b (bit-or 0xc0000040 alignment))))

(define (coff-import-symbol!
  [b : (&mut b bytes.ByteBufBuilder)]
  [short-name : String]
  [long-offset : i64]
  [section : i64]
  [storage : i64]) : unit
  (begin
    (if (= long-offset 0)
      (begin
        (coff-import-text! b (clone short-name))
        (coff-import-zero! b (- 8 (coff-import-len short-name))))
      (begin
        (coff-import-push32! b 0)
        (coff-import-push32! b long-offset)))
    (coff-import-push32! b 0)
    (coff-import-push16! b section)
    (coff-import-push16! b 0)
    (coff-import-push8! b storage)
    (coff-import-push8! b 0)))

(define (coff-import-reloc!
  [b : (&mut b bytes.ByteBufBuilder)]
  [offset : i64]
  [symbol : i64]) : unit
  (begin
    (coff-import-push32! b offset)
    (coff-import-push32! b symbol)
    (coff-import-push16! b 3)))

; IMAGE_REL_AMD64_ADDR32NB
(define (coff-import-descriptor
  [dll : String]
  [descriptor : String]
  [null-thunk : String]) : String
  (let
    [name-size : i64 (+ (coff-import-len dll) 1)]
    [string-size : i64
      (+
        7
        (coff-import-len descriptor)
        (coff-import-len "__NULL_IMPORT_DESCRIPTOR")
        (coff-import-len null-thunk))]
    [b : bytes.ByteBufBuilder
      (bytes.byte-buf-builder-with-capacity (+ 150 name-size 126 string-size))]
    (begin
      (coff-import-header! (&mut b) 2 (+ 150 name-size) 7)
      (coff-import-section! (&mut b) ".idata$2" 20 100 120 3 0x00300000)
      (coff-import-section! (&mut b) ".idata$6" name-size 150 0 0 0x00200000)
      (coff-import-zero! (&mut b) 20)
      (coff-import-reloc! (&mut b) 12 2)
      (coff-import-reloc! (&mut b) 0 3)
      (coff-import-reloc! (&mut b) 16 4)
      (coff-import-cstr! (&mut b) dll)
      (coff-import-symbol! (&mut b) "" 4 1 2)
      (coff-import-symbol! (&mut b) ".idata$2" 0 1 104)
      (coff-import-symbol! (&mut b) ".idata$6" 0 2 3)
      (coff-import-symbol! (&mut b) ".idata$4" 0 0 104)
      (coff-import-symbol! (&mut b) ".idata$5" 0 0 104)
      (coff-import-symbol! (&mut b) "" (+ 5 (coff-import-len descriptor)) 0 2)
      (coff-import-symbol!
        (&mut b)
        ""
        (+
          6
          (coff-import-len descriptor)
          (coff-import-len "__NULL_IMPORT_DESCRIPTOR"))
        0
        2)
      (coff-import-push32! (&mut b) string-size)
      (coff-import-cstr! (&mut b) descriptor)
      (coff-import-cstr! (&mut b) "__NULL_IMPORT_DESCRIPTOR")
      (coff-import-cstr! (&mut b) null-thunk)
      (bytes.byte-buf-builder-to-string (& b)))))

(define (coff-import-null-descriptor) : String
  (let
    [symbol : String "__NULL_IMPORT_DESCRIPTOR"]
    [b : bytes.ByteBufBuilder
      (bytes.byte-buf-builder-with-capacity (+ 102 (coff-import-len symbol)))]
    (begin
      (coff-import-header! (&mut b) 1 80 1)
      (coff-import-section! (&mut b) ".idata$3" 20 60 0 0 0x00300000)
      (coff-import-zero! (&mut b) 20)
      (coff-import-symbol! (&mut b) "" 4 1 2)
      (coff-import-push32! (&mut b) (+ 5 (coff-import-len symbol)))
      (coff-import-cstr! (&mut b) symbol)
      (bytes.byte-buf-builder-to-string (& b)))))

(define (coff-import-null-thunk [symbol : String]) : String
  (let
    [b : bytes.ByteBufBuilder
      (bytes.byte-buf-builder-with-capacity (+ 138 (coff-import-len symbol)))]
    (begin
      (coff-import-header! (&mut b) 2 116 1)
      (coff-import-section! (&mut b) ".idata$5" 8 100 0 0 0x00400000)
      (coff-import-section! (&mut b) ".idata$4" 8 108 0 0 0x00400000)
      (coff-import-zero! (&mut b) 16)
      (coff-import-symbol! (&mut b) "" 4 1 2)
      (coff-import-push32! (&mut b) (+ 5 (coff-import-len symbol)))
      (coff-import-cstr! (&mut b) symbol)
      (bytes.byte-buf-builder-to-string (& b)))))

(define (coff-import-short [dll : String] [plan : CoffImportPlan]) : String
  (let
    [b : bytes.ByteBufBuilder
      (bytes.byte-buf-builder-with-capacity
        (+ 22 (coff-import-len plan.public-name) (coff-import-len dll)))]
    (begin
      (coff-import-push16! (&mut b) 0)
      (coff-import-push16! (&mut b) 0xffff)
      (coff-import-push16! (&mut b) 0)
      (coff-import-push16! (&mut b) 0x8664)
      (coff-import-push32! (&mut b) 0)
      (coff-import-push32!
        (&mut b)
        (+ 2 (coff-import-len plan.public-name) (coff-import-len dll)))
      (coff-import-push16!
        (&mut b)
        (if (= plan.name-mode 0)
          plan.ordinal
          plan.hint))
      (coff-import-push16! (&mut b) (bit-or plan.kind (shl plan.name-mode 2)))
      (coff-import-cstr! (&mut b) (clone plan.public-name))
      (coff-import-cstr! (&mut b) dll)
      (bytes.byte-buf-builder-to-string (& b)))))

(define (coff-import-effective-name [public-name : String] [mode : i64]) : String
  (if (or (= mode 0) (= mode 1))
    public-name
    (let
      [n : i64 (coff-import-len public-name)]
      [first : char (coff-import-char public-name 0)]
      [start : i64
        (if (or (= first '?') (= first '@') (= first '_'))
          1
          0)]
      [at : i64 (string.index-of-byte public-name 1 (cast '@' : u8))]
      (if (= mode 3)
        (string.substring
          public-name
          start
          (-
            (if (>= at 0)
              at
              n)
            start))
        (string.substring public-name start (- n start))))))

(define (coff-import-plan-error [plan : CoffImportPlan]) : String
  (cond
    [(not (coff-import-valid-name? (& plan.public-name) true))
      "invalid public symbol"]
    [(or (< plan.kind 0) (> plan.kind 2)) "invalid import kind"]
    [(= plan.name-mode 4) "unsupported IMPORT_NAME_EXPORTAS"]
    [(or (< plan.name-mode 0) (> plan.name-mode 3)) "invalid import name mode"]
    [(or (< plan.hint 0) (> plan.hint 65535)) "invalid import hint"]
    [(or (< plan.ordinal 0) (> plan.ordinal 65535)) "invalid import ordinal"]
    [(= plan.name-mode 0)
      (if (and
        (> plan.ordinal 0)
        (= plan.hint 0)
        (string.eq plan.import-name ""))
        ""
        "ordinal mode requires only an ordinal")]
    [(not (= plan.ordinal 0)) "named mode cannot carry an ordinal"]
    [(not (coff-import-valid-name? (& plan.import-name) true))
      "invalid import name"]
    [(not
        (string.eq
          plan.import-name
          (coff-import-effective-name (clone plan.public-name) plan.name-mode)))
      "import name does not match name mode"]
    [else ""]))

(define (coff-import-symbol [plan : CoffImportPlan] [which : i64]) : String
  (if (= which 0)
    (clone plan.public-name)
    (cat.str-cat "__imp_" (clone plan.public-name))))

(define (coff-import-member
  [dll : String]
  [payload : String]
  [symbol : String]
  [other : String]) : CoffImportMember
  (let
    [count : i64
      (if (string.eq other "")
        1
        2)]
    [symbols : (__tl_dyn-array String) (__tl_make-array String count)]
    (begin
      (set! (array-ref symbols 0) symbol)
      (if (= count 2)
        (set! (array-ref symbols 1) other)
        unit)
      (CoffImportMember dll payload symbols))))

(define (coff-import-members-validated
  [dll : String]
  [stem : String]
  [plans : (& plans (__tl_dyn-array CoffImportPlan))]
  [limits : CoffImportLimits]) : ResultCoffImportMembers
  (let
    [count : i64 (array-length plans)]
    [descriptor : String (cat.str-cat "__IMPORT_DESCRIPTOR_" (clone stem))]
    [null-thunk : String (coff-import-null-thunk-name (clone stem))]
    [error : String ""]
    [work : i64 0]
    [total : i64 0]
    [i : i64 0]
    (begin
      (set!
        total
        (+
          574
          (coff-import-len dll)
          (coff-import-len descriptor)
          (* 2 (coff-import-len null-thunk))))
      (if (> total limits.max-payload)
        (set! error "import member work/byte limit")
        unit)
      (while (and (string.eq error "") (< i count))
        (let
          [p : CoffImportPlan (clone (array-ref plans i))]
          [j : i64 0]
          (begin
            (set! error (coff-import-plan-error (clone p)))
            (if (or
              (> (coff-import-len p.public-name) limits.max-string)
              (> (coff-import-len p.import-name) limits.max-string)
              (> (+ 6 (coff-import-len p.public-name)) limits.max-string))
              (set! error "import symbol length limit")
              unit)
            (if (and
              (= p.kind 0)
              (or
                (string.eq p.public-name descriptor)
                (string.eq p.public-name "__NULL_IMPORT_DESCRIPTOR")
                (string.eq p.public-name null-thunk)))
              (set! error "duplicate archive-index symbol")
              unit)
            (set!
              total
              (+ total 22 (coff-import-len p.public-name) (coff-import-len dll)))
            (set! work (+ work 1 (* 4 i)))
            (if (or (> total limits.max-payload) (> work limits.max-work))
              (set! error "import member work/byte limit")
              unit)
            (while (and (string.eq error "") (< j i))
              (let
                [prior : CoffImportPlan (clone (array-ref plans j))]
                (begin
                  (if (or
                    (string.eq p.public-name prior.public-name)
                    (and
                      (= p.kind 0)
                      (string.eq
                        p.public-name
                        (cat.str-cat "__imp_" (clone prior.public-name))))
                    (and
                      (= prior.kind 0)
                      (string.eq
                        (cat.str-cat "__imp_" (clone p.public-name))
                        prior.public-name)))
                    (set! error "duplicate archive-index symbol")
                    unit)
                  (set! j (+ j 1)))))
            (set! i (+ i 1)))))
      (if (not (string.eq error ""))
        (ResultCoffImportMembers.Err error)
        (let
          [members : (__tl_dyn-array CoffImportMember)
            (__tl_make-array CoffImportMember (+ count 3))]
          [index : i64 0]
          (begin
            (set!
              (array-ref members 0)
              (coff-import-member
                (clone dll)
                (coff-import-descriptor
                  (clone dll)
                  (clone descriptor)
                  (clone null-thunk))
                (clone descriptor)
                ""))
            (set!
              (array-ref members 1)
              (coff-import-member
                (clone dll)
                (coff-import-null-descriptor)
                "__NULL_IMPORT_DESCRIPTOR"
                ""))
            (set!
              (array-ref members 2)
              (coff-import-member
                (clone dll)
                (coff-import-null-thunk (clone null-thunk))
                (clone null-thunk)
                ""))
            (while (< index count)
              (let
                [p : CoffImportPlan (clone (array-ref plans index))]
                (begin
                  (set!
                    (array-ref members (+ index 3))
                    (coff-import-member
                      (clone dll)
                      (coff-import-short (clone dll) (clone p))
                      (if (= p.kind 0)
                        (clone p.public-name)
                        (coff-import-symbol (clone p) 1))
                      (if (= p.kind 0)
                        (coff-import-symbol (clone p) 1)
                        "")))
                  (set! index (+ index 1)))))
            (ResultCoffImportMembers.Ok members)))))))

(define (coff-import-members-with-limits
  [dll : String]
  [stem : String]
  [plans : (& plans (__tl_dyn-array CoffImportPlan))]
  [limits : CoffImportLimits]) : ResultCoffImportMembers
  (cond
    [(or
        (< limits.max-exports 0)
        (> limits.max-exports coff-import-max-exports)
        (< limits.max-string 1)
        (> limits.max-string coff-import-max-name)
        (< limits.max-payload 1)
        (> limits.max-payload coff-import-max-payload)
        (< limits.max-work 1)
        (> limits.max-work coff-import-max-work))
      (ResultCoffImportMembers.Err "invalid import member limits")]
    [(> (array-length plans) limits.max-exports)
      (ResultCoffImportMembers.Err "import member count limit")]
    [(not (coff-import-valid-dll-part? (& dll)))
      (ResultCoffImportMembers.Err "invalid DLL basename")]
    [(not (coff-import-valid-dll-part? (& stem)))
      (ResultCoffImportMembers.Err "invalid DLL stem")]
    [(or
        (= (coff-import-char dll 0) '.')
        (= (coff-import-char dll (- (coff-import-len dll) 1)) '.'))
      (ResultCoffImportMembers.Err "invalid DLL basename")]
    [(or
        (= (coff-import-char stem 0) '.')
        (= (coff-import-char stem (- (coff-import-len stem) 1)) '.'))
      (ResultCoffImportMembers.Err "invalid DLL stem")]
    [(not (coff-import-stem-matches? (clone dll) (clone stem)))
      (ResultCoffImportMembers.Err "DLL basename/stem mismatch")]
    [(or
        (> (coff-import-len dll) limits.max-string)
        (> (coff-import-len stem) limits.max-string)
        (> (+ 20 (coff-import-len stem)) limits.max-string)
        (> (+ 17 (coff-import-len stem)) limits.max-string)
        (> 24 limits.max-string))
      (ResultCoffImportMembers.Err "support symbol length limit")]
    [else (coff-import-members-validated dll stem plans limits)]))

(define (coff-import-members
  [dll : String]
  [stem : String]
  [plans : (& plans (__tl_dyn-array CoffImportPlan))]) : ResultCoffImportMembers
  (coff-import-members-with-limits
    dll
    stem
    plans
    (CoffImportLimits
      coff-import-max-exports
      coff-import-max-name
      coff-import-max-payload
      coff-import-max-work)))

(cfg
  test
  (define (coff-import-fixture-eq? [payload : String] [index : i64]) : bool
    (string.eq
      payload
      (byte_buf.to-string
        (io.read-file
          (cat.str-cat
            "src/tests/fixtures/coff_import_amd64/example-"
            (cat.str-cat (string.int->string index) ".bin")))))))

(cfg
  test
  (define (coff-import-fixture-difference [payload : String] [index : i64]) : String
    (let
      [expected : String
        (byte_buf.to-string
          (io.read-file
            (cat.str-cat
              "src/tests/fixtures/coff_import_amd64/example-"
              (cat.str-cat (string.int->string index) ".bin"))))]
      [i : i64 0]
      [limit : i64
        (if (< (coff-import-len payload) (coff-import-len expected))
          (coff-import-len payload)
          (coff-import-len expected))]
      (begin
        (while (and
          (< i limit)
          (=
            (cast (coff-import-char payload i) : i64)
            (cast (coff-import-char expected i) : i64)))
          (set! i (+ i 1)))
        (cat.str-cat
          (cat.str-cat " offset " (string.int->string i))
          (cat.str-cat
            (cat.str-cat
              " actual length "
              (string.int->string (coff-import-len payload)))
            (cat.str-cat
              " expected length "
              (string.int->string (coff-import-len expected)))))))))

(cfg
  test
  (define (coff-import-read-u32 [payload : String] [offset : i64]) : i64
    (bit-or
      (cast (coff-import-char payload offset) : i64)
      (bit-or
        (shl (cast (coff-import-char payload (+ offset 1)) : i64) 8)
        (bit-or
          (shl (cast (coff-import-char payload (+ offset 2)) : i64) 16)
          (shl (cast (coff-import-char payload (+ offset 3)) : i64) 24))))))

(cfg
  test
  (define (coff-import-rejects?
    [dll : String]
    [stem : String]
    [plans : (& plans (__tl_dyn-array CoffImportPlan))]
    [expected : String]) : bool
    (match (coff-import-members dll stem plans)
      [(ResultCoffImportMembers.Err message) (string.eq message expected)]
      [(ResultCoffImportMembers.Ok _) false])))

(cfg
  test
  (test
    coff-import-llvm-member-oracles
    (let
      [plans : (__tl_dyn-array CoffImportPlan)
        (__tl_make-array CoffImportPlan 4)]
      (begin
        (set! (array-ref plans 0) (CoffImportPlan "Func" "Func" 0 0 0 1))
        (set! (array-ref plans 1) (CoffImportPlan "Data" "Data" 0 0 1 1))
        (set! (array-ref plans 2) (CoffImportPlan "Const" "Const" 0 0 2 1))
        (set! (array-ref plans 3) (CoffImportPlan "Ord" "" 7 0 0 0))
        (match (coff-import-members "example.dll" "example" (& plans))
          [(ResultCoffImportMembers.Err _)
            (test.assert-true false "oracle plan accepts")]
          [(ResultCoffImportMembers.Ok members)
            (begin
              (test.assert-true
                (= (array-length members) 7)
                "three support members first")
              (let
                [i : i64 0]
                (while (< i 7)
                  (begin
                    (test.assert-true
                      (coff-import-fixture-eq?
                        (clone (array-ref members i).payload)
                        i)
                      (cat.str-cat
                        (cat.str-cat
                          "LLVM member payload bytes at "
                          (string.int->string i))
                        (coff-import-fixture-difference
                          (clone (array-ref members i).payload)
                          i)))
                    (test.assert-true
                      (string.eq
                        (array-ref members i).archive-name
                        "example.dll")
                      "duplicate logical member names remain ordered")
                    (set! i (+ i 1)))))
              (test.assert-true
                (string.eq
                  (array-ref (array-ref members 0).index-symbols 0)
                  "__IMPORT_DESCRIPTOR_example")
                "descriptor index symbol")
              (test.assert-true
                (= (array-length (array-ref members 3).index-symbols) 2)
                "code indexes public and imp")
              (test.assert-true
                (string.eq
                  (array-ref (array-ref members 3).index-symbols 1)
                  "__imp_Func")
                "code imp index symbol")
              (test.assert-true
                (= (array-length (array-ref members 4).index-symbols) 1)
                "data indexes only imp")
              (test.assert-true
                (string.eq
                  (array-ref (array-ref members 5).index-symbols 0)
                  "__imp_Const")
                "const imp index symbol")
              (test.assert-true
                (=
                  (coff-import-read-u32 (clone (array-ref members 0).payload) 8)
                  162)
                "descriptor COFF symbol pointer")
              (test.assert-true
                (=
                  (coff-import-read-u32
                    (clone (array-ref members 0).payload)
                    120)
                  12)
                "descriptor name relocation offset")
              (test.assert-true
                (=
                  (coff-import-read-u32
                    (clone (array-ref members 0).payload)
                    130)
                  0)
                "descriptor lookup relocation offset")
              (test.assert-true
                (=
                  (coff-import-read-u32
                    (clone (array-ref members 0).payload)
                    140)
                  16)
                "descriptor address relocation offset"))])))))

(cfg
  test
  (test
    coff-import-bounds-and-name-modes
    (let
      [none : (__tl_dyn-array CoffImportPlan)
        (__tl_make-array CoffImportPlan 0)]
      [one : (__tl_dyn-array CoffImportPlan) (__tl_make-array CoffImportPlan 1)]
      (begin
        (match (coff-import-members "example.dll" "example" (& none))
          [(ResultCoffImportMembers.Err _)
            (test.assert-true false "empty export set accepts")]
          [(ResultCoffImportMembers.Ok members)
            (begin
              (test.assert-true
                (= (array-length members) 3)
                "empty DLL retains support members")
              (test.assert-true
                (coff-import-fixture-eq?
                  (clone (array-ref members 0).payload)
                  0)
                "empty DLL descriptor oracle")
              (test.assert-true
                (coff-import-fixture-eq?
                  (clone (array-ref members 1).payload)
                  1)
                "empty DLL null descriptor oracle")
              (test.assert-true
                (coff-import-fixture-eq?
                  (clone (array-ref members 2).payload)
                  2)
                "empty DLL null thunk oracle"))])
        (test.assert-true
          (coff-import-rejects?
            "../example.dll"
            "example"
            (& none)
            "invalid DLL basename")
          "path-bearing DLL rejected")
        (test.assert-true
          (coff-import-rejects?
            "C:example.dll"
            "example"
            (& none)
            "invalid DLL basename")
          "drive-relative DLL rejected")
        (match (coff-import-members "example.DLL" "example" (& none))
          [(ResultCoffImportMembers.Ok members)
            (test.assert-true
              (= (array-length members) 3)
              "case-preserved extension accepts")]
          [_ (test.assert-true false "uppercase DLL extension accepts")])
        (test.assert-true
          (coff-import-rejects?
            "example.dll"
            "wrong"
            (& none)
            "DLL basename/stem mismatch")
          "stem mismatch rejected")
        (test.assert-true
          (coff-import-rejects?
            "example.dll"
            "example.dll"
            (& none)
            "DLL basename/stem mismatch")
          "stem cannot retain the DLL extension")
        (match (coff-import-members "example" "example" (& none))
          [(ResultCoffImportMembers.Ok members)
            (test.assert-true
              (= (array-length members) 3)
              "extensionless DLL keeps its complete stem")]
          [_ (test.assert-true false "extensionless DLL accepts")])
        (set! (array-ref one 0) (CoffImportPlan "_Func@8" "Func" 0 9 0 3))
        (match (coff-import-members "example.dll" "example" (& one))
          [(ResultCoffImportMembers.Err _)
            (test.assert-true false "undecorated name accepts")]
          [(ResultCoffImportMembers.Ok members)
            (begin
              (test.assert-true
                (=
                  (coff-import-read-u32
                    (clone (array-ref members 3).payload)
                    12)
                  20)
                "short data size includes two terminators")
              (test.assert-true
                (=
                  (cast
                    (coff-import-char (array-ref members 3).payload 16)
                    : i64)
                  9)
                "named hint encoded")
              (test.assert-true
                (=
                  (cast
                    (coff-import-char (array-ref members 3).payload 18)
                    : i64)
                  12)
                "undecorate mode encoded"))])
        (set! (array-ref one 0) (CoffImportPlan "_Func" "Func" 0 0 0 2))
        (test.assert-true
          (match (coff-import-members "example.dll" "example" (& one))
            [(ResultCoffImportMembers.Ok _) true]
            [_ false])
          "no-prefix mode accepts")
        (set! (array-ref one 0) (CoffImportPlan "Func" "Alias" 0 0 0 1))
        (test.assert-true
          (coff-import-rejects?
            "example.dll"
            "example"
            (& one)
            "import name does not match name mode")
          "mismatched exact alias rejected")
        (set! (array-ref one 0) (CoffImportPlan "Func" "Func" 0 0 0 4))
        (test.assert-true
          (coff-import-rejects?
            "example.dll"
            "example"
            (& one)
            "unsupported IMPORT_NAME_EXPORTAS")
          "undocumented EXPORTAS named diagnostic")
        (set! (array-ref one 0) (CoffImportPlan "Func" "" 0 0 0 0))
        (test.assert-true
          (coff-import-rejects?
            "example.dll"
            "example"
            (& one)
            "ordinal mode requires only an ordinal")
          "ordinal zero rejected")
        (set! (array-ref one 0) (CoffImportPlan "Func" "" 65536 0 0 0))
        (test.assert-true
          (coff-import-rejects?
            "example.dll"
            "example"
            (& one)
            "invalid import ordinal")
          "ordinal overflow rejected")
        (set! (array-ref one 0) (CoffImportPlan "Func" "Func" 0 65536 0 1))
        (test.assert-true
          (coff-import-rejects?
            "example.dll"
            "example"
            (& one)
            "invalid import hint")
          "hint overflow rejected")
        (set! (array-ref one 0) (CoffImportPlan "Func" "Func" 0 0 3 1))
        (test.assert-true
          (coff-import-rejects?
            "example.dll"
            "example"
            (& one)
            "invalid import kind")
          "reserved kind rejected")
        (match (coff-import-members-with-limits
          "example.dll"
          "example"
          (& none)
          (CoffImportLimits 0 4096 1 100))
          [(ResultCoffImportMembers.Err message)
            (test.assert-true
              (string.eq message "import member work/byte limit")
              "whole-set byte budget fails before member allocation")]
          [_ (test.assert-true false "byte cap rejects")])))))

(cfg
  test
  (test
    coff-import-validation-atomicity
    (let
      [plans : (__tl_dyn-array CoffImportPlan)
        (__tl_make-array CoffImportPlan 2)]
      [one : (__tl_dyn-array CoffImportPlan) (__tl_make-array CoffImportPlan 1)]
      (begin
        (set! (array-ref plans 0) (CoffImportPlan "Foo" "Foo" 0 0 0 1))
        (set!
          (array-ref plans 1)
          (CoffImportPlan "__imp_Foo" "__imp_Foo" 0 0 0 1))
        (test.assert-true
          (coff-import-rejects?
            "example.dll"
            "example"
            (& plans)
            "duplicate archive-index symbol")
          "public/imp collision rejects whole member set")
        (set! (array-ref plans 1) (CoffImportPlan "Foo" "Foo" 0 0 1 1))
        (test.assert-true
          (coff-import-rejects?
            "example.dll"
            "example"
            (& plans)
            "duplicate archive-index symbol")
          "code/data imp collision rejected")
        (set! (array-ref plans 1) (CoffImportPlan "Other" "Other" 0 0 1 1))
        (match (coff-import-members-with-limits
          "example.dll"
          "example"
          (& plans)
          (CoffImportLimits 1 4096 16777216 4194304))
          [(ResultCoffImportMembers.Err message)
            (test.assert-true
              (string.eq message "import member count limit")
              "configured member cap rejects atomically")]
          [_ (test.assert-true false "member cap rejects")])
        (match (coff-import-members-with-limits
          "example.dll"
          "example"
          (& plans)
          (CoffImportLimits 2 4096 16777216 1))
          [(ResultCoffImportMembers.Err message)
            (test.assert-true
              (string.eq message "import member work/byte limit")
              "configured work cap rejects atomically")]
          [_ (test.assert-true false "work cap rejects")])
        (set!
          (array-ref one 0)
          (CoffImportPlan
            "VeryLongPublicImportName"
            "VeryLongPublicImportName"
            0
            0
            0
            1))
        (match (coff-import-members-with-limits
          "example.dll"
          "example"
          (& one)
          (CoffImportLimits 1 29 16777216 4194304))
          [(ResultCoffImportMembers.Err message)
            (test.assert-true
              (string.eq message "import symbol length limit")
              "configured symbol cap checks imp name")]
          [_ (test.assert-true false "symbol cap rejects")])
        (set! (array-ref one 0) (CoffImportPlan "Bad/Name" "Bad/Name" 0 0 0 1))
        (test.assert-true
          (coff-import-rejects?
            "example.dll"
            "example"
            (& one)
            "invalid public symbol")
          "path-bearing symbol rejected")
        (let
          [b : bytes.ByteBufBuilder (bytes.byte-buf-builder-new)]
          (begin
            (coff-import-text! (&mut b) "Bad")
            (coff-import-push8! (&mut b) 0)
            (coff-import-text! (&mut b) "Name")
            (let
              [nul-name : String (bytes.byte-buf-builder-to-string (& b))]
              (begin
                (set!
                  (array-ref one 0)
                  (CoffImportPlan (clone nul-name) nul-name 0 0 0 1))
                (test.assert-true
                  (coff-import-rejects?
                    "example.dll"
                    "example"
                    (& one)
                    "invalid public symbol")
                  "NUL symbol rejected")))))
        (set! (array-ref one 0) (CoffImportPlan "_Foo@8" "Foo@8" 0 0 0 3))
        (test.assert-true
          (coff-import-rejects?
            "example.dll"
            "example"
            (& one)
            "import name does not match name mode")
          "malformed undecorate transform rejected")
        (set! (array-ref one 0) (CoffImportPlan "Foo" "Foo" 0 0 0 5))
        (test.assert-true
          (coff-import-rejects?
            "example.dll"
            "example"
            (& one)
            "invalid import name mode")
          "reserved name mode rejected")
        (set! (array-ref one 0) (CoffImportPlan "Foo" "" 3 1 0 0))
        (test.assert-true
          (coff-import-rejects?
            "example.dll"
            "example"
            (& one)
            "ordinal mode requires only an ordinal")
          "ordinal and hint confusion rejected")
        (set! (array-ref one 0) (CoffImportPlan "Foo" "Foo" 3 0 0 1))
        (test.assert-true
          (coff-import-rejects?
            "example.dll"
            "example"
            (& one)
            "named mode cannot carry an ordinal")
          "named ordinal confusion rejected")))))

(cfg
  test
  (define (coff-import-alias-fixture-eq? [payload : String] [index : i64]) : bool
    (string.eq
      payload
      (byte_buf.to-string
        (io.read-file
          (cat.str-cat
            "src/tests/fixtures/coff_import_amd64/aliases-"
            (cat.str-cat (string.int->string index) ".bin")))))))

(cfg
  test
  (test
    coff-import-alias-forwarder-oracles
    (let
      [plans : (__tl_dyn-array CoffImportPlan)
        (__tl_make-array CoffImportPlan 3)]
      (begin
        (set! (array-ref plans 0) (CoffImportPlan "Alias" "Alias" 0 0 0 1))
        (set! (array-ref plans 1) (CoffImportPlan "Forward" "Forward" 0 0 0 1))
        (set!
          (array-ref plans 2)
          (CoffImportPlan "_Decorated@8" "_Decorated@8" 0 0 0 1))
        (match (coff-import-members "example.dll" "example" (& plans))
          [(ResultCoffImportMembers.Err _)
            (test.assert-true false "alias and forwarder plans accept")]
          [(ResultCoffImportMembers.Ok members)
            (let
              [i : i64 0]
              (while (< i 3)
                (begin
                  (test.assert-true
                    (coff-import-alias-fixture-eq?
                      (clone (array-ref members (+ i 3)).payload)
                      (+ i 3))
                    "LLVM alias/forwarder member payload")
                  (set! i (+ i 1)))))])))))
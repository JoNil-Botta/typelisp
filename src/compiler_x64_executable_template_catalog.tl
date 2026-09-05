;; compiler_x64_executable_template_catalog.tl - Reviewed x86-64 template rows.
(import compiler_x64_executable_template as x64)
(import compiler_owned_view as owned_view)
(import stdlib.hash)
(import stdlib.io)
(import stdlib.string)

(defstruct CompilerX64ExecutableTemplateGate
  (id x64.CompilerX64ExecutableTemplateId)
  (target x64.CompilerX64TemplateTarget)
  (render-kind x64.CompilerX64TemplateRenderKind)
  (expected-rendered-size i64)
  (expected-rendered-hash i64))

(include-str compiler-x64-template-catalog-data "compiler_x64_executable_template_catalog.tsv")

(define (compiler-x64-template-catalog-data-shared-view) : String
  (cfg
    stage0-seed-bootstrap
    compiler-x64-template-catalog-data
    (unsafe
      (ptr-read (ptr-addr-of compiler-x64-template-catalog-data)))))

;; SPEC 3.5.1 assigns each nullary enum its 0-based declaration-order tag.
;; Keep the checked-in data in that order and bounds-check the representation.
(define (compiler-x64-template-id-index
  [id : x64.CompilerX64ExecutableTemplateId]) : i64
  ;; Materialize a local before reading the SPEC 3.5.1 nullary-enum tag. Taking
  ;; the address of a by-value parameter directly is not portable to Win64.
  (let
    [index : i64 (x64.compiler-x64-template-enum-tag id)]
    (if (or (< index 0) (>= index 82))
      (io.panic "x64 executable template: id tag is out of range")
      index)))

(define (compiler-x64-template-catalog-row-start
  [data : (& data str)]
  [index : i64]) : i64
  (let
    [line : i64 0]
    [start : i64 0]
    (begin
      ;; Row zero is the checked-in schema header.
      (while (<= line index)
        (let
          [end : i64 (string.index-of-byte data start (cast '\n' : u8))]
          (if (< end 0)
            (io.panic "x64 executable template: catalog row is missing")
            (begin
              (set! start (+ end 1))
              (set! line (+ line 1))))))
      start)))

(define (compiler-x64-template-catalog-row-end
  [data : (& data str)]
  [start : i64]) : i64
  (let
    [end : i64 (string.index-of-byte data start (cast '\n' : u8))]
    (if (< end 0)
      (string.string-length data)
      end)))

(define (compiler-x64-template-catalog-field
  [data : (& data str)]
  [row-start : i64]
  [row-end : i64]
  [field-index : i64]) : String
  (let
    [field : i64 0]
    [start : i64 row-start]
    (begin
      (while (< field field-index)
        (let
          [end : i64 (string.index-of-byte data start (cast '\t' : u8))]
          (if (or (< end 0) (>= end row-end))
            (io.panic "x64 executable template: catalog field is missing")
            (begin
              (set! start (+ end 1))
              (set! field (+ field 1))))))
      (let
        [tab : i64 (string.index-of-byte data start (cast '\t' : u8))]
        [end : i64
          (if (or (< tab 0) (> tab row-end))
            row-end
            tab)]
        (string.substring data start (- end start))))))

;; The checked-in TSV uses only `\n` and `\\` escapes inside fields. Keeping
;; physical rows single-line makes shell CI able to verify the schema and exact
;; row census without a generated-code dependency.
(define (compiler-x64-template-catalog-tag [value : (& value str)]) : i64
  (let
    [separator : i64 (string.index-of-byte value 0 (cast ':' : u8))]
    (if (<= separator 0)
      (io.panic "x64 executable template: malformed catalog enum tag")
      (string.>int (string.substring value 0 separator)))))

(define (compiler-x64-template-target-from-catalog [value : (& value str)]) : x64.CompilerX64TemplateTarget
  (let
    [tag : i64 (compiler-x64-template-catalog-tag value)]
    (if (or (< tag 0) (>= tag 3))
      (io.panic "x64 executable template: unknown catalog target")
      (unsafe
        (ptr-read
          (ptr-cast (ptr-addr-of tag) : (Ptr x64.CompilerX64TemplateTarget)))))))

(define (compiler-x64-template-render-kind-from-catalog [value : (& value str)]) : x64.CompilerX64TemplateRenderKind
  (let
    [tag : i64 (compiler-x64-template-catalog-tag value)]
    (if (or (< tag 0) (>= tag 3))
      (io.panic "x64 executable template: unknown catalog render kind")
      (unsafe
        (ptr-read
          (ptr-cast (ptr-addr-of tag) : (Ptr x64.CompilerX64TemplateRenderKind)))))))

(define (compiler-x64-template-registry-gate
  [id : x64.CompilerX64ExecutableTemplateId]) : CompilerX64ExecutableTemplateGate
  (let
    [data : String (compiler-x64-template-catalog-data-shared-view)]
    [row-start : i64
      (compiler-x64-template-catalog-row-start
        (& data)
        (compiler-x64-template-id-index id))]
    [row-end : i64 (compiler-x64-template-catalog-row-end (& data) row-start)]
    [target : String
      (compiler-x64-template-catalog-field (& data) row-start row-end 3)]
    [render-kind : String
      (compiler-x64-template-catalog-field (& data) row-start row-end 6)]
    [expected-rendered-size : String
      (compiler-x64-template-catalog-field (& data) row-start row-end 14)]
    [expected-rendered-hash : String
      (compiler-x64-template-catalog-field (& data) row-start row-end 15)]
    (CompilerX64ExecutableTemplateGate
      id
      (compiler-x64-template-target-from-catalog (& target))
      (compiler-x64-template-render-kind-from-catalog (& render-kind))
      (string.>int (& expected-rendered-size))
      (string.>int (& expected-rendered-hash)))))

(define (compiler-x64-template-render-kind-matches?
  [expected : x64.CompilerX64TemplateRenderKind]
  [actual : x64.CompilerX64TemplateRenderKind]) : bool
  (=
    (x64.compiler-x64-template-enum-tag expected)
    (x64.compiler-x64-template-enum-tag actual)))

(define (compiler-x64-template-row-valid-for?
  [row : CompilerX64ExecutableTemplateGate]
  [target : x64.CompilerX64TemplateTarget]
  [render-kind : x64.CompilerX64TemplateRenderKind]) : bool
  (and
    (x64.compiler-x64-template-target-matches? row.target target)
    (compiler-x64-template-render-kind-matches? row.render-kind render-kind)))

(define (compiler-x64-template-require-kind!
  [row : CompilerX64ExecutableTemplateGate]
  [target : x64.CompilerX64TemplateTarget]
  [render-kind : x64.CompilerX64TemplateRenderKind]) : unit
  (unless
    (compiler-x64-template-row-valid-for? row target render-kind)
    (io.panic "x64 executable template: target/render mismatch")))

(define (compiler-x64-template-rendered-payload-valid?
  [row : CompilerX64ExecutableTemplateGate]
  [rendered : (& rendered str)]) : bool
  (or
    (< row.expected-rendered-size 0)
    (and
      (= (string.string-length rendered) row.expected-rendered-size)
      (= (hash.string-key rendered) row.expected-rendered-hash))))

(define (compiler-x64-template-require-rendered-payload!
  [row : CompilerX64ExecutableTemplateGate]
  [rendered : (& rendered str)]) : unit
  (unless
    (compiler-x64-template-rendered-payload-valid? row rendered)
    (match row.id
      [(x64.CompilerX64ExecutableTemplateId.WindowsRuntimeArena)
        (if (= (string.string-length rendered) row.expected-rendered-size)
          (io.panic
            "x64 executable template: WindowsRuntimeArena hash mismatch")
          (io.panic
            "x64 executable template: WindowsRuntimeArena size mismatch"))]
      [_
        (if (= (string.string-length rendered) row.expected-rendered-size)
          (io.panic "x64 executable template: non-arena hash mismatch")
          (io.panic "x64 executable template: non-arena size mismatch"))])))

(define (compiler-x64-template-render-assembly
  [id : x64.CompilerX64ExecutableTemplateId]
  [target : x64.CompilerX64TemplateTarget]
  [rendered : String]) : String
  (let
    [row : CompilerX64ExecutableTemplateGate
      (compiler-x64-template-registry-gate id)]
    (begin
      (compiler-x64-template-require-kind!
        (owned_view.compiler-owned-shared-view row)
        target
        (x64.CompilerX64TemplateRenderKind.Assembly))
      (compiler-x64-template-require-rendered-payload! row (& rendered))
      rendered)))

(define (compiler-x64-template-render-bytes
  [id : x64.CompilerX64ExecutableTemplateId]
  [target : x64.CompilerX64TemplateTarget]
  [rendered : String]) : String
  (let
    [row : CompilerX64ExecutableTemplateGate
      (compiler-x64-template-registry-gate id)]
    (begin
      (compiler-x64-template-require-kind!
        (owned_view.compiler-owned-shared-view row)
        target
        (x64.CompilerX64TemplateRenderKind.OpaqueBytes))
      (compiler-x64-template-require-rendered-payload! row (& rendered))
      rendered)))

(define (compiler-x64-template-assert-structured!
  [id : x64.CompilerX64ExecutableTemplateId]
  [target : x64.CompilerX64TemplateTarget]) : unit
  (let
    [row : CompilerX64ExecutableTemplateGate
      (compiler-x64-template-registry-gate id)]
    (compiler-x64-template-require-kind!
      row
      target
      (x64.CompilerX64TemplateRenderKind.StructuredObject))))

(define (compiler-x64-template-select-four
  [plain : x64.CompilerX64ExecutableTemplateId]
  [debug : x64.CompilerX64ExecutableTemplateId]
  [profile : x64.CompilerX64ExecutableTemplateId]
  [profile-debug : x64.CompilerX64ExecutableTemplateId]
  [profile? : bool]
  [debug? : bool]) : x64.CompilerX64ExecutableTemplateId
  (if profile?
    (if debug?
      profile-debug
      profile)
    (if debug?
      debug
      plain)))
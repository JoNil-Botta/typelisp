;; compiler_runtime_bindings.tl - The external runtime bindings each target
;; declares, as one checked table (#8318).
;;
;; A row is one line of six tab-separated fields:
;; - target: `windows-x86_64` or `linux-x86_64`.
;; - name: the external symbol.
;; - kind: `function` or `data`, the object symbol kind it binds.
;; - provider: the import library that resolves it. Windows source builds link
;;   exactly the providers of the Windows rows (build_run_core); a Linux row
;;   would name none, `-`.
;; - feature: `always`; the runtime feature that adds it (`startup-profile`);
;;   or `abi-fixture` for a binding only the object ABI fixtures call.
;; - route: `object` when a direct object may relocate against it, `assembly`
;;   when only assembled runtime text uses it. Declaring a binding does not
;;   admit it to the object route: admission takes its own semantic, ABI and
;;   relocation evidence.
;; A binding never names a compiler-owned runtime definition (`tl_`/`_tl_`):
;; such a symbol is defined in the image, and an external binding cannot stand
;; in for a body the image has not materialized (#8317).
;; The Linux runtime text declares and calls no external symbol, so Linux has
;; no rows.
(import stdlib.iterator)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)

(define compiler-runtime-bindings-text : String
  "windows-x86_64\tConvertThreadToFiber\tfunction\tkernel32.lib\talways\tobject
windows-x86_64\tCreateFiberEx\tfunction\tkernel32.lib\talways\tobject
windows-x86_64\tExitProcess\tfunction\tkernel32.lib\talways\tobject
windows-x86_64\tGetCommandLineA\tfunction\tkernel32.lib\talways\tobject
windows-x86_64\tGetStdHandle\tfunction\tkernel32.lib\talways\tobject
windows-x86_64\tSetThreadStackGuarantee\tfunction\tkernel32.lib\talways\tobject
windows-x86_64\tSetUnhandledExceptionFilter\tfunction\tkernel32.lib\talways\tobject
windows-x86_64\tSwitchToFiber\tfunction\tkernel32.lib\talways\tobject
windows-x86_64\tVirtualAlloc\tfunction\tkernel32.lib\talways\tobject
windows-x86_64\tVirtualFree\tfunction\tkernel32.lib\talways\tobject
windows-x86_64\tWriteFile\tfunction\tkernel32.lib\talways\tobject
windows-x86_64\tGetLastError\tfunction\tkernel32.lib\talways\tassembly
windows-x86_64\tQueryPerformanceCounter\tfunction\tkernel32.lib\tstartup-profile\tassembly
windows-x86_64\tNtCreateFile\tfunction\tntdll.lib\tabi-fixture\tobject
")
(define compiler-runtime-binding-field-count : i64
  6)

;; The end of the line starting at `start`: its `\n`, or the end of `text`.
(define (compiler-runtime-binding-line-end [text : (& text str)] [start : i64]) : i64
  (let
    [end : i64 (string.index-of-byte text start (cast 10 : u8))]
    (if (< end 0)
      (string.string-length text)
      end)))

;; The number of tab-separated fields in `start..end`.
(define (compiler-runtime-binding-fields-in
  [text : (& text str)]
  [start : i64]
  [end : i64]) : i64
  (let
    [count : i64 1]
    (for [index (iterator.range start end)]
      (when (= (string.char-at text index) '\t') (+= count 1)))
    count))

;; Field `field` (0-based) of the row in `start..end`, or "" past the last.
(define (compiler-runtime-binding-field
  [text : (& text str)]
  [start : i64]
  [end : i64]
  [field : i64]) : String
  (let
    [index : i64 start]
    [seen : i64 0]
    [field-start : i64 -1]
    [field-end : i64 -1]
    (when (= field 0) (set! field-start start))
    (while (and (< index end) (< field-end 0))
      (when
        (= (string.char-at text index) '\t')
        (cond
          [(= seen field) (set! field-end index)]
          [(= (+ seen 1) field) (set! field-start (+ index 1))]
          [else unit])
        (+= seen 1))
      (+= index 1))
    (cond
      [(< field-start 0) ""]
      [(< field-end 0) (string.substring text field-start (- end field-start))]
      [else (string.substring text field-start (- field-end field-start))])))

(define (compiler-runtime-binding-target-known? [target : (& target str)]) : bool
  (or (string.eq target "windows-x86_64") (string.eq target "linux-x86_64")))

;; A Windows provider is an import library; a Linux binding names none.
(define (compiler-runtime-binding-provider-valid?
  [target : (& target str)]
  [provider : (& provider str)]) : bool
  (let
    [length : i64 (string.string-length provider)]
    (if (string.eq target "windows-x86_64")
      (and
        (> length 4)
        (string.eq (string.substring provider (- length 4) 4) ".lib"))
      (string.eq provider "-"))))

;: Whether `name` lies in the compiler's own runtime namespace, `tl_` or
;: `_tl_`, which no external binding may name.
(define (compiler-runtime-binding-compiler-owned? [name : (& name str)]) : bool
  (or
    (and
      (>= (string.string-length name) 3)
      (string.eq (string.substring name 0 3) "tl_"))
    (and
      (>= (string.string-length name) 4)
      (string.eq (string.substring name 0 4) "_tl_"))))

(define (compiler-runtime-binding-row-error
  [text : (& text str)]
  [start : i64]
  [end : i64]) : String
  (let
    [target : String (compiler-runtime-binding-field text start end 0)]
    [name : String (compiler-runtime-binding-field text start end 1)]
    [kind : String (compiler-runtime-binding-field text start end 2)]
    [provider : String (compiler-runtime-binding-field text start end 3)]
    [feature : String (compiler-runtime-binding-field text start end 4)]
    [route : String (compiler-runtime-binding-field text start end 5)]
    (cond
      [(not
          (=
            (compiler-runtime-binding-fields-in text start end)
            compiler-runtime-binding-field-count))
        "expected 6 tab-separated fields"]
      [(not (compiler-runtime-binding-target-known? (& target)))
        "unknown target"]
      [(= (string.string-length (& name)) 0) "empty name"]
      [(compiler-runtime-binding-compiler-owned? (& name))
        (str_cat.str-cat "compiler-owned runtime name " name)]
      [(not (or (string.eq kind "function") (string.eq kind "data")))
        "unknown kind"]
      [(not (compiler-runtime-binding-provider-valid? (& target) (& provider)))
        "unknown provider"]
      [(not
          (or
            (string.eq feature "always")
            (string.eq feature "startup-profile")
            (string.eq feature "abi-fixture")))
        "unknown feature"]
      [(not (or (string.eq route "object") (string.eq route "assembly")))
        "unknown route"]
      [else ""])))

;; Whether a row before `limit` binds `name` on `target`.
(define (compiler-runtime-binding-declared-before?
  [text : (& text str)]
  [limit : i64]
  [target : (& target str)]
  [name : (& name str)]) : bool
  (let
    [start : i64 0]
    [found : bool false]
    (while (and (not found) (< start limit))
      (let
        [end : i64 (compiler-runtime-binding-line-end text start)]
        (when
          (and
            (string.eq (compiler-runtime-binding-field text start end 0) target)
            (string.eq (compiler-runtime-binding-field text start end 1) name))
          (set! found true))
        (set! start (+ end 1))))
    found))

;: The first problem in the binding table `text` as "row N: reason", or "" for
;: a valid table. Rows are non-empty lines; a final line break is optional.
(define (compiler-runtime-bindings-error [text : (& text str)]) : String
  (let
    [length : i64 (string.string-length text)]
    [start : i64 0]
    [row : i64 1]
    [error : String ""]
    (while (and (< start length) (= (string.string-length (& error)) 0))
      (let
        [end : i64 (compiler-runtime-binding-line-end text start)]
        [reason : String
          (if (= end start)
            "empty row"
            (compiler-runtime-binding-row-error text start end))]
        [target : String (compiler-runtime-binding-field text start end 0)]
        [name : String (compiler-runtime-binding-field text start end 1)]
        (cond
          [(> (string.string-length (& reason)) 0)
            (set!
              error
              (str_cat.str-cat "row " (string.int->string row) ": " reason))]
          [(compiler-runtime-binding-declared-before?
              text
              start
              (& target)
              (& name))
            (set!
              error
              (str_cat.str-cat
                "row "
                (string.int->string row)
                ": duplicate binding "
                name))]
          [else unit])
        (set! start (+ end 1))
        (+= row 1)))
    error))

;: The route of `target`'s binding of `name` as a `kind` symbol, or "" when the
;: table declares no such binding.
(define (compiler-runtime-binding-route
  [text : (& text str)]
  [target : (& target str)]
  [name : (& name str)]
  [kind : (& kind str)]) : String
  (let
    [length : i64 (string.string-length text)]
    [start : i64 0]
    [route : String ""]
    (while (and (< start length) (= (string.string-length (& route)) 0))
      (let
        [end : i64 (compiler-runtime-binding-line-end text start)]
        (when
          (and
            (string.eq (compiler-runtime-binding-field text start end 0) target)
            (string.eq (compiler-runtime-binding-field text start end 1) name)
            (string.eq (compiler-runtime-binding-field text start end 2) kind))
          (set! route (compiler-runtime-binding-field text start end 5)))
        (set! start (+ end 1))))
    route))

;: Whether a direct object for `target` may relocate against external `name`
;: as a `kind` symbol.
(define (compiler-runtime-binding-object-route?
  [target : (& target str)]
  [name : (& name str)]
  [kind : (& kind str)]) : bool
  (string.eq
    (compiler-runtime-binding-route
      (& compiler-runtime-bindings-text)
      target
      name
      kind)
    "object"))

;; An upper bound on the rows of `text`, and so on its distinct providers:
;; its line breaks plus one.
(define (compiler-runtime-binding-row-bound [text : (& text str)]) : i64
  (let
    [count : i64 1]
    (for [index (iterator.range 0 (string.string-length text))]
      (when (= (string.char-at text index) '\n') (+= count 1)))
    count))

;: `target`'s providers in the table `text`, in first-use order, without
;: repeats.
(define (compiler-runtime-binding-providers-in
  [text : (& text str)]
  [target : (& target str)]) : (__tl_dyn-array String)
  (let
    [length : i64 (string.string-length text)]
    [out : (__tl_dyn-array String)
      (__tl_make-array String (compiler-runtime-binding-row-bound text))]
    [count : i64 0]
    [start : i64 0]
    (while (< start length)
      (let
        [end : i64 (compiler-runtime-binding-line-end text start)]
        [provider : String (compiler-runtime-binding-field text start end 3)]
        [seen : bool false]
        (when
          (string.eq (compiler-runtime-binding-field text start end 0) target)
          (for [index (iterator.range 0 count)]
            (when (string.eq (array-ref out index) provider) (set! seen true)))
          (unless seen (set! (array-ref out count) provider) (+= count 1)))
        (set! start (+ end 1))))
    (let
      [result : (__tl_dyn-array String) (__tl_make-array String count)]
      (for [index (iterator.range 0 count)]
        (set! (array-ref result index) (array-ref out index)))
      result)))

;: `target`'s providers in first-use order, without repeats.
(define (compiler-runtime-binding-providers [target : (& target str)]) : (__tl_dyn-array
    String)
  (compiler-runtime-binding-providers-in
    (& compiler-runtime-bindings-text)
    target))
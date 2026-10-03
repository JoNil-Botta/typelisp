;; compiler_source_overlay_tests.tl - checks against one admitted source overlay
;; generation, and the read ledgers they return (#7455).
(import compiler_check_core as check_core)
(import compiler_diagnostic as cdiag)
(import compiler_load)
(import compiler_load_tests as load_tests)
(import compiler_owned_view as owned_view)
(import compiler_source_overlay as source_overlay)
(import stdlib.fs)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as svec)

(define overlay-test-a : String
  "(import b)
(define (main) : i64 (b.value))")
(define overlay-test-b : String
  "(define (value) : i64 1)")
(define overlay-test-a-renamed : String
  "(import b)
(define (main) : i64 (b.renamed))")
(define overlay-test-b-renamed : String
  "(define (renamed) : i64 2)")
(define overlay-test-b-other : String
  "(define (other) : i64 3)")

(define (overlay-test-cwd) : String
  (let
    [cwd : String (fs.current-dir)]
    (fs.path-normalize (& cwd))))

(define (overlay-test-path [name : String]) : String
  (str_cat.str-cat "target/check_overlay/" name))

(define (overlay-test-canonical [path : String]) : String
  (let
    [cwd : String (overlay-test-cwd)]
    (source_overlay.compiler-source-canonical-path (& cwd) (& path))))

(define (overlay-test-write! [name : String] [text : String]) : unit
  (load_tests.compiler-load-write-file-text (overlay-test-path name) text))

(define (overlay-test-setup!) : unit
  (if (compiler_load.compiler-load-test-mkdir "target/check_overlay")
    unit
    unit)
  (overlay-test-write! "a.tl" (string.copy overlay-test-a))
  (overlay-test-write! "b.tl" (string.copy overlay-test-b))
  (overlay-test-write! "c.tl" "(define (unused) : i64 0)")
  (overlay-test-write! "e.tl" "(define (main) : i64 missing)"))

(define (overlay-test-names-2 [first : String] [second : String]) : svec.Vec
  (let
    [names : svec.Vec (svec.new)]
    (svec.push-ref! (&mut names) first)
    (svec.push-ref! (&mut names) second)
    names))

(define (overlay-test-names-1 [first : String]) : svec.Vec
  (let
    [names : svec.Vec (svec.new)]
    (svec.push-ref! (&mut names) first)
    names))

;; Admit `texts` for the canonical paths of fixture `names` under `limits`.
(define (overlay-test-admit-with
  [generation : i64]
  [paths : svec.Vec]
  [texts : svec.Vec]
  [limits : source_overlay.CompilerSourceOverlayLimits]) : source_overlay.ResultCompilerSourceOverlay
  (let
    [cwd : String (overlay-test-cwd)]
    [root : String
      (source_overlay.compiler-source-canonical-path
        (& cwd)
        "target/check_overlay")]
    [inputs (source_overlay.compiler-source-overlay-inputs)]
    [index : i64 0]
    (while (< index (svec.len (& paths)))
      (source_overlay.compiler-source-overlay-inputs-push!
        (&mut inputs)
        (svec.get (& paths) index "")
        (svec.get (& texts) index "")
        (Any))
      (set! index (+ index 1)))
    (source_overlay.compiler-source-overlay-admit
      generation
      root
      cwd
      inputs
      limits)))

(define (overlay-test-canonical-names [names : svec.Vec]) : svec.Vec
  (let
    [out : svec.Vec (svec.new)]
    [index : i64 0]
    (while (< index (svec.len (& names)))
      (svec.push-ref!
        (&mut out)
        (overlay-test-canonical
          (overlay-test-path (svec.get (& names) index ""))))
      (set! index (+ index 1)))
    out))

(define (overlay-test-admit [names : svec.Vec] [texts : svec.Vec]) : source_overlay.ResultCompilerSourceOverlay
  (overlay-test-admit-with
    1
    (overlay-test-canonical-names names)
    texts
    (source_overlay.compiler-source-overlay-default-limits)))

;; The admission failure code, or 0 when the table was admitted.
(define (overlay-test-admit-code
  [admitted : source_overlay.ResultCompilerSourceOverlay]) : i64
  (match admitted
    [(Ok _) 0]
    [(Err failure) failure.code]))

;; 1 when checking fixture `root` through `overlay` passed, 0 when it reported
;; diagnostics, and the negated reason when the overlay check was rejected.
(define (overlay-test-check-with-roots
  [root : String]
  [admitted : source_overlay.ResultCompilerSourceOverlay]
  [stdlib-roots : svec.Vec]) : i64
  (match admitted
    [(Err failure) (- 0 (* 100 failure.code))]
    [(Ok overlay)
      (match (check_core.compiler-check-file-with-overlay
        (overlay-test-path root)
        stdlib-roots
        (check_core.compiler-check-language-cfgs)
        overlay)
        [(Checked result)
          (match result.check
            [(Ok _ _) 1]
            [(Err _ _) 0])]
        [(Rejected failure) (- 0 failure.code)])]))

(define (overlay-test-check
  [admitted : source_overlay.ResultCompilerSourceOverlay]) : i64
  (overlay-test-check-with-roots "a.tl" admitted (svec.new)))

(define (overlay-test-plain-check-ok? [root : String]) : bool
  (match (check_core.compiler-check-file-with-roots-and-cfg
    (overlay-test-path root)
    (svec.new)
    (check_core.compiler-check-language-cfgs))
    [(Ok _ _) true]
    [(Err _ _) false]))

;; A and its import B change together. Only the whole candidate generation
;; checks; the disk generation, a candidate A over disk B and a different B all
;; behave as their own bytes say, whatever ran before them in this process.
(define (overlay-test-candidate-generation-ok?) : bool
  (let
    [both : svec.Vec (overlay-test-names-2 "a.tl" "b.tl")]
    [both-texts : svec.Vec
      (overlay-test-names-2
        (string.copy overlay-test-a-renamed)
        (string.copy overlay-test-b-renamed))]
    [other-texts : svec.Vec
      (overlay-test-names-2
        (string.copy overlay-test-a-renamed)
        (string.copy overlay-test-b-other))]
    (overlay-test-setup!)
    (and
      (overlay-test-plain-check-ok? "a.tl")
      (=
        (overlay-test-check
          (overlay-test-admit (clone both) (clone both-texts)))
        1)
      (=
        (overlay-test-check
          (overlay-test-admit
            (overlay-test-names-1 "a.tl")
            (overlay-test-names-1 (string.copy overlay-test-a-renamed))))
        0)
      (= (overlay-test-check (overlay-test-admit (clone both) other-texts)) 0)
      (= (overlay-test-check (overlay-test-admit (clone both) both-texts)) 1)
      (overlay-test-plain-check-ok? "a.tl"))))

(define (overlay-test-class-name [class : source_overlay.CompilerSourceClass]) : String
  (match class
    [(Disk) "disk"]
    [(Embedded) "embedded"]
    [(Overlay) "overlay"]))

;; The class of the ledger entry for fixture `name`, or "".
(define (overlay-test-ledger-class
  [ledger : (& ledger source_overlay.CompilerSourceLedger)]
  [name : String]) : String
  (let
    [path : String (overlay-test-canonical (overlay-test-path name))]
    [index : i64 (source_overlay.compiler-source-ledger-find ledger (& path))]
    (if (< index 0)
      ""
      (overlay-test-class-name
        (source_overlay.compiler-source-ledger-get ledger index).class))))

(define (overlay-test-ledger-has-embedded?
  [ledger : (& ledger source_overlay.CompilerSourceLedger)]) : bool
  (let
    [count : i64 (source_overlay.compiler-source-ledger-count ledger)]
    [index : i64 0]
    [found : bool false]
    (while (< index count)
      (match (source_overlay.compiler-source-ledger-get ledger index).class
        [(Embedded) (set! found true)]
        [_ unit])
      (set! index (+ index 1)))
    found))

;; The ledger of a successful overlay check of fixture `root`, or an empty one.
(define (overlay-test-ledger
  [root : String]
  [admitted : source_overlay.ResultCompilerSourceOverlay]) : source_overlay.CompilerSourceLedger
  (match admitted
    [(Err _)
      (source_overlay.compiler-source-ledger-new
        (source_overlay.compiler-source-overlay-default-limits))]
    [(Ok overlay)
      (match (check_core.compiler-check-file-with-overlay
        (overlay-test-path root)
        (svec.new)
        (check_core.compiler-check-language-cfgs)
        overlay)
        [(Checked result) result.ledger]
        [(Rejected _)
          (source_overlay.compiler-source-ledger-new
            (source_overlay.compiler-source-overlay-default-limits))])]))

;; The ledger names A and B once each, from the overlay, never from disk, and
;; records the embedded prelude the check consumed; the root comes first.
(define (overlay-test-ledger-ok?) : bool
  (let
    [ledger : source_overlay.CompilerSourceLedger
      (overlay-test-ledger
        "a.tl"
        (overlay-test-admit
          (overlay-test-names-2 "a.tl" "b.tl")
          (overlay-test-names-2
            (string.copy overlay-test-a-renamed)
            (string.copy overlay-test-b-renamed))))]
    [a-path : String (overlay-test-canonical (overlay-test-path "a.tl"))]
    (and
      (not (source_overlay.compiler-source-ledger-failed? (& ledger)))
      (string.eq (overlay-test-ledger-class (& ledger) "a.tl") "overlay")
      (string.eq (overlay-test-ledger-class (& ledger) "b.tl") "overlay")
      (string.eq (overlay-test-ledger-class (& ledger) "c.tl") "")
      (overlay-test-ledger-has-embedded? (& ledger))
      (= (source_overlay.compiler-source-ledger-find (& ledger) (& a-path)) 0))))

;; An empty overlay reads everything from disk. Revalidating its ledger finds
;; nothing stale until an imported source changes on disk, and then names it.
(define (overlay-test-revalidate-ok?) : bool
  (let
    [ledger : source_overlay.CompilerSourceLedger
      (overlay-test-ledger "a.tl" (overlay-test-admit (svec.new) (svec.new)))]
    [fresh : svec.Vec
      (source_overlay.compiler-source-ledger-stale-paths (& ledger))]
    [_mutate : unit
      (overlay-test-write! "b.tl" (string.copy overlay-test-b-other))]
    [stale : svec.Vec
      (source_overlay.compiler-source-ledger-stale-paths (& ledger))]
    [_restore : unit (overlay-test-write! "b.tl" (string.copy overlay-test-b))]
    [restored : svec.Vec
      (source_overlay.compiler-source-ledger-stale-paths (& ledger))]
    [b-path : String (overlay-test-canonical (overlay-test-path "b.tl"))]
    (and
      (string.eq (overlay-test-ledger-class (& ledger) "a.tl") "disk")
      (string.eq (overlay-test-ledger-class (& ledger) "b.tl") "disk")
      (= (svec.len (& fresh)) 0)
      (= (svec.len (& stale)) 1)
      (string.eq (svec.get (& stale) 0 "") (& b-path))
      (= (svec.len (& restored)) 0))))

(define (overlay-test-diagnostic-text [result : check_core.ResultCompilerCheck]) : String
  (match result
    [(Ok _ _) "ok"]
    [(Err diagnostics-box _)
      (let
        [diagnostics : cdiag.CompilerDiagnosticList
          (cdiag.compiler-diagnostic-list-box-shared-view diagnostics-box)]
        [count : i64 (cdiag.compiler-diagnostic-list-count diagnostics)]
        [index : i64 0]
        [text : String ""]
        (while (< index count)
          (let
            [diag : cdiag.CompilerDiagnostic
              (cdiag.compiler-diagnostic-list-get diagnostics index)]
            (set!
              text
              (str_cat.str-cat
                text
                (string.int->string (cdiag.compiler-diagnostic-line diag))
                ":"
                (cdiag.compiler-diagnostic-message diag)
                "\n"))
            (set! index (+ index 1))))
        text)]))

;; With an empty overlay a failing check reports exactly what it reports
;; without one.
(define (overlay-test-empty-stable-ok?) : bool
  (let
    [plain : String
      (overlay-test-diagnostic-text
        (check_core.compiler-check-file-with-roots-and-cfg
          (overlay-test-path "e.tl")
          (svec.new)
          (check_core.compiler-check-language-cfgs)))]
    [overlaid : String
      (match (overlay-test-admit (svec.new) (svec.new))
        [(Err _) "rejected"]
        [(Ok overlay)
          (match (check_core.compiler-check-file-with-overlay
            (overlay-test-path "e.tl")
            (svec.new)
            (check_core.compiler-check-language-cfgs)
            overlay)
            [(Checked result) (overlay-test-diagnostic-text result.check)]
            [(Rejected _) "rejected"])])]
    (and (not (string.eq (& plain) "ok")) (string.eq (& plain) (& overlaid)))))

(define (overlay-test-limits [entries : i64] [bytes : i64]) : source_overlay.CompilerSourceOverlayLimits
  (source_overlay.CompilerSourceOverlayLimits entries bytes 4096 65536 16777216))

;; Every malformed table is rejected before checking, with its stable reason.
(define (overlay-test-rejects-ok?) : bool
  (let
    [a : String (overlay-test-canonical (overlay-test-path "a.tl"))]
    [b : String (overlay-test-canonical (overlay-test-path "b.tl"))]
    [defaults : source_overlay.CompilerSourceOverlayLimits
      (source_overlay.compiler-source-overlay-default-limits)]
    [expect-other : source_overlay.CompilerSourceOverlayBase
      (Expect (source_overlay.CompilerSourceContent 1 "00"))]
    [stale-inputs (source_overlay.compiler-source-overlay-inputs)]
    [_stale : unit
      (source_overlay.compiler-source-overlay-inputs-push!
        (&mut stale-inputs)
        (string.copy (& a))
        "(define (main) : i64 0)"
        expect-other)]
    [cwd : String (overlay-test-cwd)]
    [root : String
      (source_overlay.compiler-source-canonical-path
        (& cwd)
        "target/check_overlay")]
    (and
      (=
        (overlay-test-admit-code
          (overlay-test-admit-with 0 (svec.new) (svec.new) (clone defaults)))
        source_overlay.compiler-source-overlay-error-generation)
      (=
        (overlay-test-admit-code
          (overlay-test-admit-with
            1
            (overlay-test-names-2 (string.copy (& a)) (string.copy (& a)))
            (overlay-test-names-2 "(define x : i64 1)" "(define x : i64 2)")
            (clone defaults)))
        source_overlay.compiler-source-overlay-error-duplicate)
      (=
        (overlay-test-admit-code
          (overlay-test-admit-with
            1
            (overlay-test-names-1 (overlay-test-path "a.tl"))
            (overlay-test-names-1 "(define x : i64 1)")
            (clone defaults)))
        source_overlay.compiler-source-overlay-error-path)
      (=
        (overlay-test-admit-code
          (overlay-test-admit-with
            1
            (overlay-test-names-1
              (str_cat.str-cat (string.copy (& root)) "/../a.tl"))
            (overlay-test-names-1 "(define x : i64 1)")
            (clone defaults)))
        source_overlay.compiler-source-overlay-error-path)
      (=
        (overlay-test-admit-code
          (overlay-test-admit-with
            1
            (overlay-test-names-1
              (overlay-test-canonical "target/outside_overlay.tl"))
            (overlay-test-names-1 "(define x : i64 1)")
            (clone defaults)))
        source_overlay.compiler-source-overlay-error-path)
      (=
        (overlay-test-admit-code
          (overlay-test-admit-with
            1
            (overlay-test-names-1
              (overlay-test-canonical (overlay-test-path "notes.txt")))
            (overlay-test-names-1 "text")
            (clone defaults)))
        source_overlay.compiler-source-overlay-error-path)
      (=
        (overlay-test-admit-code
          (overlay-test-admit-with
            1
            (overlay-test-names-1
              (overlay-test-canonical (overlay-test-path "missing.tl")))
            (overlay-test-names-1 "(define x : i64 1)")
            (clone defaults)))
        source_overlay.compiler-source-overlay-error-missing)
      (=
        (overlay-test-admit-code
          (source_overlay.compiler-source-overlay-admit
            1
            (string.copy (& root))
            (string.copy (& cwd))
            stale-inputs
            (clone defaults)))
        source_overlay.compiler-source-overlay-error-stale-base)
      (=
        (overlay-test-admit-code
          (overlay-test-admit-with
            1
            (overlay-test-names-2 (string.copy (& a)) (string.copy (& b)))
            (overlay-test-names-2 "(define x : i64 1)" "(define y : i64 1)")
            (overlay-test-limits 1 1024)))
        source_overlay.compiler-source-overlay-error-count)
      (=
        (overlay-test-admit-code
          (overlay-test-admit-with
            1
            (overlay-test-names-1 (string.copy (& a)))
            (overlay-test-names-1 "(define x : i64 1)")
            (overlay-test-limits 8 3)))
        source_overlay.compiler-source-overlay-error-bytes)
      ;; A source below a stdlib root is not editable through an overlay.
      (=
        (overlay-test-check-with-roots
          "a.tl"
          (overlay-test-admit
            (overlay-test-names-1 "a.tl")
            (overlay-test-names-1 (string.copy overlay-test-a)))
          (overlay-test-names-1 "target/check_overlay"))
        (- 0 source_overlay.compiler-source-overlay-error-not-editable))
      ;; An admitted source the check never read proves nothing about it.
      (=
        (overlay-test-check
          (overlay-test-admit
            (overlay-test-names-2 "a.tl" "c.tl")
            (overlay-test-names-2
              (string.copy overlay-test-a)
              "(define (unused) : i64 1)")))
        (- 0 source_overlay.compiler-source-overlay-error-unread))
      ;; A failing check keeps its diagnostics instead.
      (=
        (overlay-test-check-with-roots
          "e.tl"
          (overlay-test-admit
            (overlay-test-names-2 "e.tl" "c.tl")
            (overlay-test-names-2
              "(define (main) : i64 missing)"
              "(define (unused) : i64 1)"))
          (svec.new))
        0))))

;; The ledger fails, rather than silently dropping entries, when a check reads
;; more than its limit or reads one source twice with different bytes.
(define (overlay-test-ledger-failures-ok?) : bool
  (let
    [limited : source_overlay.CompilerSourceLedger
      (source_overlay.compiler-source-ledger-new
        (source_overlay.CompilerSourceOverlayLimits 8 1024 4096 1 16777216))]
    [changed : source_overlay.CompilerSourceLedger
      (source_overlay.compiler-source-ledger-new
        (source_overlay.compiler-source-overlay-default-limits))]
    (source_overlay.compiler-source-ledger-record-text!
      (&mut limited)
      (Disk)
      "/one.tl"
      "one.tl"
      "1")
    (source_overlay.compiler-source-ledger-record-text!
      (&mut limited)
      (Disk)
      "/two.tl"
      "two.tl"
      "2")
    (source_overlay.compiler-source-ledger-record-text!
      (&mut changed)
      (Disk)
      "/one.tl"
      "one.tl"
      "1")
    (source_overlay.compiler-source-ledger-record-text!
      (&mut changed)
      (Disk)
      "/one.tl"
      "one.tl"
      "1")
    (let
      [same : bool
        (and
          (not (source_overlay.compiler-source-ledger-failed? (& changed)))
          (= (source_overlay.compiler-source-ledger-count (& changed)) 1))]
      (source_overlay.compiler-source-ledger-record-text!
        (&mut changed)
        (Disk)
        "/one.tl"
        "one.tl"
        "2")
      (and
        same
        (source_overlay.compiler-source-ledger-failed? (& limited))
        (=
          (source_overlay.compiler-source-ledger-failure (& limited)).code
          source_overlay.compiler-source-overlay-error-ledger-limit)
        (source_overlay.compiler-source-ledger-failed? (& changed))
        (=
          (source_overlay.compiler-source-ledger-failure (& changed)).code
          source_overlay.compiler-source-overlay-error-changed)))))

;; A package entry and a source of its dependency package change together; only
;; the whole candidate generation checks, and the ledger records the dependency
;; manifest resolution read and the dependency's TLCI interface image.
(define (overlay-test-package-ok?) : bool
  (let
    [base : String "target/check_overlay/pkg"]
    [entry : String "target/check_overlay/pkg/app/src/main.tl"]
    [dep : String "target/check_overlay/pkg/math/src/add.tl"]
    [manifest : String "target/check_overlay/pkg/math/typelisp.pkg"]
    [tlci : String "target/check_overlay/pkg/math/target/release/math.tlci"]
    [deps : compiler_load.CompilerPkgDeps
      (compiler_load.compiler-pkg-deps-cons
        "math"
        "../math"
        (compiler_load.compiler-pkg-deps-empty))]
    [entry-candidate : String
      "(import math.src.add)
(define (main) : i64 (add.twice 20))"]
    [dep-candidate : String
      "(define (inc [x : i64]) : i64 (+ x 1))
(define (twice [x : i64]) : i64 (* x 2))"]
    (overlay-test-setup!)
    (if (compiler_load.compiler-load-test-mkdir (string.copy base))
      unit
      unit)
    (if (compiler_load.compiler-load-test-mkdir "target/check_overlay/pkg/app")
      unit
      unit)
    (if (compiler_load.compiler-load-test-mkdir
      "target/check_overlay/pkg/app/src")
      unit
      unit)
    (if (compiler_load.compiler-load-test-mkdir "target/check_overlay/pkg/math")
      unit
      unit)
    (if (compiler_load.compiler-load-test-mkdir
      "target/check_overlay/pkg/math/src")
      unit
      unit)
    (load_tests.compiler-load-write-file-text
      (string.copy manifest)
      "(package (name \"math\") (version \"1\") (kind staticlib) (entry \"src/add.tl\"))")
    (load_tests.compiler-load-write-file-text
      (string.copy dep)
      "(define (inc [x : i64]) : i64 (+ x 1))")
    (load_tests.compiler-load-write-file-text
      (string.copy entry)
      "(import math.src.add)
(define (main) : i64 (add.inc 41))")
    (let
      [both
        (overlay-test-package-check
          (clone deps)
          (overlay-test-admit-with
            1
            (overlay-test-names-2
              (overlay-test-canonical (string.copy entry))
              (overlay-test-canonical (string.copy dep)))
            (overlay-test-names-2
              (string.copy entry-candidate)
              (string.copy dep-candidate))
            (source_overlay.compiler-source-overlay-default-limits)))]
      [entry-only
        (overlay-test-package-check
          (clone deps)
          (overlay-test-admit-with
            1
            (overlay-test-names-1 (overlay-test-canonical (string.copy entry)))
            (overlay-test-names-1 (string.copy entry-candidate))
            (source_overlay.compiler-source-overlay-default-limits)))]
      [_write-tlci : unit
        (begin
          (if (compiler_load.compiler-load-test-mkdir
            "target/check_overlay/pkg/math/target")
            unit
            unit)
          (if (compiler_load.compiler-load-test-mkdir
            "target/check_overlay/pkg/math/target/release")
            unit
            unit)
          (load_tests.compiler-load-write-file-text
            (string.copy tlci)
            "not a tlci image"))]
      [with-tlci
        (overlay-test-package-check
          (clone deps)
          (overlay-test-admit-with
            1
            (overlay-test-names-2
              (overlay-test-canonical (string.copy entry))
              (overlay-test-canonical (string.copy dep)))
            (overlay-test-names-2
              (string.copy entry-candidate)
              (string.copy dep-candidate))
            (source_overlay.compiler-source-overlay-default-limits)))]
      [removed : bool (= (fs.remove-file-status (& tlci)) 0)]
      (and
        (= both.status 1)
        (= entry-only.status 0)
        removed
        (= with-tlci.status 0)
        (string.eq
          (overlay-test-ledger-class-of
            (& with-tlci.ledger)
            (overlay-test-canonical (string.copy tlci)))
          "disk")
        (string.eq
          (overlay-test-ledger-class-of
            (& both.ledger)
            (overlay-test-canonical (string.copy tlci)))
          "")
        (string.eq
          (overlay-test-ledger-class-of
            (& both.ledger)
            (overlay-test-canonical (string.copy manifest)))
          "disk")
        (string.eq
          (overlay-test-ledger-class-of
            (& both.ledger)
            (overlay-test-canonical (string.copy dep)))
          "overlay")))))

(defstruct OverlayTestPackageOutcome
  (status i64)
  (ledger source_overlay.CompilerSourceLedger))

(define (overlay-test-package-check
  [deps : compiler_load.CompilerPkgDeps]
  [admitted : source_overlay.ResultCompilerSourceOverlay]) : OverlayTestPackageOutcome
  (let
    [empty : source_overlay.CompilerSourceLedger
      (source_overlay.compiler-source-ledger-new
        (source_overlay.compiler-source-overlay-default-limits))]
    (match admitted
      [(Err failure)
        (OverlayTestPackageOutcome (- 0 (* 100 failure.code)) empty)]
      [(Ok overlay)
        (match (check_core.compiler-check-package-entry-file-with-overlay
          "target/check_overlay/pkg/app/src/main.tl"
          (svec.new)
          "target/check_overlay/pkg/app"
          deps
          true
          (check_core.compiler-check-language-cfgs)
          overlay)
          [(Checked result)
            (OverlayTestPackageOutcome
              (match result.check
                [(Ok _ _ _) 1]
                [(Err _ _) 0])
              result.ledger)]
          [(Rejected failure)
            (OverlayTestPackageOutcome (- 0 failure.code) empty)])])))

(define (overlay-test-ledger-class-of
  [ledger : (& ledger source_overlay.CompilerSourceLedger)]
  [path : String]) : String
  (let
    [index : i64 (source_overlay.compiler-source-ledger-find ledger (& path))]
    (if (< index 0)
      ""
      (overlay-test-class-name
        (source_overlay.compiler-source-ledger-get ledger index).class))))

(define (overlay-test-content [text : (& text str)]) : source_overlay.CompilerSourceContent
  (match (source_overlay.compiler-source-content-identity "" text)
    [(Ok content) content]
    [(Err _) (source_overlay.CompilerSourceContent -1 "")]))

;; The content identity of ledger entry `index`.
(define (overlay-test-ledger-content
  [ledger : (& ledger source_overlay.CompilerSourceLedger)]
  [index : i64]) : source_overlay.CompilerSourceContent
  (let
    [entry : source_overlay.CompilerSourceLedgerEntry
      (source_overlay.compiler-source-ledger-get ledger index)]
    entry.content))

;; Canonical identities are absolute and `/`-separated on every host, a root
;; contains itself and what lies below it (a drive root included), and only
;; Windows folds ASCII case.
(define (overlay-test-path-identity-ok?) : bool
  (let
    [folds : bool (cfg windows true false)]
    (and
      (source_overlay.compiler-source-path-canonical? "/r/a.tl")
      (source_overlay.compiler-source-path-canonical? "C:/r/a.tl")
      (not (source_overlay.compiler-source-path-canonical? "/r/./a.tl"))
      (not (source_overlay.compiler-source-path-canonical? "C:\\r\\a.tl"))
      (not (source_overlay.compiler-source-path-canonical? "r/a.tl"))
      (string.eq
        (source_overlay.compiler-source-canonical-path "C:/r" "src\\..\\a.tl")
        "C:/r/a.tl")
      (string.eq
        (source_overlay.compiler-source-canonical-path "/r" "/s/./a.tl")
        "/s/a.tl")
      (source_overlay.compiler-source-path-under? "/r" "/r")
      (source_overlay.compiler-source-path-under? "/r" "/r/a.tl")
      (not (source_overlay.compiler-source-path-under? "/r" "/rx/a.tl"))
      (not (source_overlay.compiler-source-path-under? "/r/a" "/r"))
      (source_overlay.compiler-source-path-under? "/" "/a.tl")
      (source_overlay.compiler-source-path-under? "C:/" "C:/a.tl")
      (not (source_overlay.compiler-source-path-under? "C:/" "D:/a.tl"))
      (=
        (source_overlay.compiler-source-path-under? "C:/Work" "c:/work/a.tl")
        folds)
      (=
        (source_overlay.compiler-source-path-eq? "C:/Work/A.tl" "c:/work/a.tl")
        folds)
      ;; A case variant of an admitted source names the same file on Windows
      ;; and a missing one elsewhere.
      (=
        (overlay-test-admit-code
          (overlay-test-admit
            (overlay-test-names-2 "a.tl" "A.tl")
            (overlay-test-names-2 "(define x : i64 1)" "(define x : i64 2)")))
        (if folds
          source_overlay.compiler-source-overlay-error-duplicate
          source_overlay.compiler-source-overlay-error-missing)))))

;; Load sessions are the job boundary. Two sessions holding different overlays
;; of one source each read their own bytes however their reads interleave,
;; record them in their own ledgers, and leave the serial session on disk.
(define (overlay-test-sessions-ok?) : bool
  (let
    [b : String (overlay-test-path "b.tl")]
    [renamed : String (string.copy overlay-test-b-renamed)]
    [other : String (string.copy overlay-test-b-other)]
    [disk : String (string.copy overlay-test-b)]
    [first : compiler_load.CompilerLoadSessionState
      (compiler_load.compiler-load-session-state-new)]
    [second : compiler_load.CompilerLoadSessionState
      (compiler_load.compiler-load-session-state-new)]
    (match (overlay-test-admit
      (overlay-test-names-1 "b.tl")
      (overlay-test-names-1 (string.copy (& renamed))))
      [(Ok first-overlay)
        (match (overlay-test-admit
          (overlay-test-names-1 "b.tl")
          (overlay-test-names-1 (string.copy (& other))))
          [(Ok second-overlay)
            (compiler_load.compiler-load-session-state-source-provider-install!
              (owned_view.compiler-owned-shared-view first)
              first-overlay)
            (compiler_load.compiler-load-session-state-source-provider-install!
              (owned_view.compiler-owned-shared-view second)
              second-overlay)
            (let
              [first-read : String
                (compiler_load.compiler-load-session-state-read-source-text
                  (owned_view.compiler-owned-shared-view first)
                  (& b))]
              [second-read : String
                (compiler_load.compiler-load-session-state-read-source-text
                  (owned_view.compiler-owned-shared-view second)
                  (& b))]
              [serial-read : String
                (compiler_load.compiler-load-session-read-source-text (& b))]
              [first-again : String
                (compiler_load.compiler-load-session-state-read-source-text
                  (owned_view.compiler-owned-shared-view first)
                  (& b))]
              [first-ledger : source_overlay.CompilerSourceLedger
                (compiler_load.compiler-load-session-state-source-provider-finish!
                  (owned_view.compiler-owned-shared-view first))]
              [second-ledger : source_overlay.CompilerSourceLedger
                (compiler_load.compiler-load-session-state-source-provider-finish!
                  (owned_view.compiler-owned-shared-view second))]
              [first-content : source_overlay.CompilerSourceContent
                (overlay-test-ledger-content (& first-ledger) 0)]
              [second-content : source_overlay.CompilerSourceContent
                (overlay-test-ledger-content (& second-ledger) 0)]
              [renamed-content : source_overlay.CompilerSourceContent
                (overlay-test-content (& renamed))]
              [other-content : source_overlay.CompilerSourceContent
                (overlay-test-content (& other))]
              (and
                (string.eq (& first-read) (& renamed))
                (string.eq (& second-read) (& other))
                (string.eq (& serial-read) (& disk))
                (string.eq (& first-again) (& renamed))
                (not
                  (compiler_load.compiler-load-session-state-source-provider-active?
                    (& first)))
                (not
                  (compiler_load.compiler-load-session-state-source-provider-active?
                    (& second)))
                (=
                  (source_overlay.compiler-source-ledger-count (& first-ledger))
                  1)
                (=
                  (source_overlay.compiler-source-ledger-count
                    (& second-ledger))
                  1)
                (not
                  (source_overlay.compiler-source-ledger-failed?
                    (& first-ledger)))
                (not
                  (source_overlay.compiler-source-ledger-failed?
                    (& second-ledger)))
                (string.eq
                  (overlay-test-ledger-class (& first-ledger) "b.tl")
                  "overlay")
                (source_overlay.compiler-source-content-eq?
                  (& first-content)
                  (& renamed-content))
                (source_overlay.compiler-source-content-eq?
                  (& second-content)
                  (& other-content))))]
          [(Err _) false])]
      [(Err _) false])))

;; An overlay check leaves no provider or overlay bytes in the session, whether
;; it passed, reported diagnostics or was rejected, and the ledger it returned
;; stays intact through later checks that retire the loader's pools.
(define (overlay-test-lifetime-ok?) : bool
  (let
    [ledger : source_overlay.CompilerSourceLedger
      (overlay-test-ledger
        "a.tl"
        (overlay-test-admit
          (overlay-test-names-2 "a.tl" "b.tl")
          (overlay-test-names-2
            (string.copy overlay-test-a-renamed)
            (string.copy overlay-test-b-renamed))))]
    [count : i64 (source_overlay.compiler-source-ledger-count (& ledger))]
    [first : source_overlay.CompilerSourceLedgerEntry
      (source_overlay.compiler-source-ledger-get (& ledger) 0)]
    [after-pass : bool
      (not (compiler_load.compiler-load-session-source-provider-active?))]
    [diagnostics : i64
      (overlay-test-check
        (overlay-test-admit
          (overlay-test-names-1 "a.tl")
          (overlay-test-names-1 (string.copy overlay-test-a-renamed))))]
    [after-diagnostics : bool
      (not (compiler_load.compiler-load-session-source-provider-active?))]
    [rejected : i64
      (overlay-test-check
        (overlay-test-admit
          (overlay-test-names-2 "a.tl" "c.tl")
          (overlay-test-names-2
            (string.copy overlay-test-a)
            "(define (unused) : i64 1)")))]
    [after-rejected : bool
      (not (compiler_load.compiler-load-session-source-provider-active?))]
    [plain : bool (overlay-test-plain-check-ok? "a.tl")]
    [again : source_overlay.CompilerSourceLedgerEntry
      (source_overlay.compiler-source-ledger-get (& ledger) 0)]
    [serial : compiler_load.CompilerLoadSessionState
      (compiler_load.compiler-load-serial-test-session-state)]
    [provider : compiler_load.CompilerLoadSourceProvider
      (compiler_load.compiler-load-session-state-source-provider (& serial))]
    (and
      (> count 1)
      after-pass
      (= diagnostics 0)
      after-diagnostics
      (= rejected (- 0 source_overlay.compiler-source-overlay-error-unread))
      after-rejected
      plain
      (= (source_overlay.compiler-source-ledger-count (& ledger)) count)
      (string.eq (& again.path) (& first.path))
      (string.eq (& again.logical-path) (& first.logical-path))
      (source_overlay.compiler-source-content-eq?
        (& again.content)
        (& first.content))
      (=
        (source_overlay.compiler-source-overlay-entry-count
          (& provider.overlay))
        0))))

(define (compiler-source-overlay-tests-ok?) : bool
  (and
    (overlay-test-candidate-generation-ok?)
    (overlay-test-ledger-ok?)
    (overlay-test-revalidate-ok?)
    (overlay-test-empty-stable-ok?)
    (overlay-test-rejects-ok?)
    (overlay-test-ledger-failures-ok?)
    (overlay-test-package-ok?)
    (overlay-test-path-identity-ok?)
    (overlay-test-sessions-ok?)
    (overlay-test-lifetime-ok?)))
;; .cases DSL parser, --list / --list-fixtures emitter, and static barrier analyzer.
;; Matches cc_translate in scripts/verify-codegen-cases.sh 1:1.
(import stdlib.byte_buf_core as bbc)
(import stdlib.str_cat)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import (vector.vector i64) as ivec)
(import util)

;; Row kinds
(define rk-run : i64
  1)
(define rk-exec : i64
  2)
(define rk-sh : i64
  3)
(define rk-cwd : i64
  4)
(define rk-step : i64
  5)
(define rk-file : i64
  6)
(define rk-test : i64
  7)
(define rk-same : i64
  8)
(define rk-in : i64
  9)
(define rk-narrow : i64
  10)
(define rk-exit : i64
  11)
(define rk-contains : i64
  12)
(define rk-is : i64
  13)
(define rk-not-contains : i64
  14)
(define rk-contains-any : i64
  15)
(define rk-order : i64
  16)
(define rk-match : i64
  17)
(define rk-match-i : i64
  18)
(define rk-not-match : i64
  19)
(define rk-not-match-i : i64
  20)
(define rk-count : i64
  21)
(define rk-count-fixed : i64
  22)
(define rk-next-line : i64
  23)
(define rk-empty : i64
  24)
(define rk-not-empty : i64
  25)
(define rk-metric : i64
  26)
(define rk-capture : i64
  27)
(define rk-check : i64
  28)
(define rk-if-fn : i64
  29)
(define rk-if-no-fn : i64
  30)
(define rk-if-mode : i64
  31)
(define rk-if-host : i64
  32)
(define rk-if-isa : i64
  33)
(define rk-else : i64
  34)
(define rk-end-if : i64
  35)

(defstruct FileBlock
  (line i64)
  (path String)
  (flags String)
  (content String))

(defstruct CaseRow
  (kind i64)
  (line i64)
  (a String)
  (b String)
  (c String)
  (n i64))

(import (vector.vector FileBlock core) as fbvec)
(import (vector.vector CaseRow core) as rowvec)

(defstruct CaseDef
  (id String)
  (line i64)
  (do-action String)
  (source String)
  (args String)
  (hosts String)
  (target String)
  (opt String)
  (mode String)
  (each String)
  (assemble bool)
  (repeatable bool)
  (has-exit bool)
  (needs-barrier bool)
  (setups svec.Vec)
  (rows rowvec.Vec))

(import (vector.vector CaseDef core) as casevec)

(defstruct ParsedFile
  (ok bool)
  (error String)
  (file-path String)
  (pre-files fbvec.Vec)
  (cases casevec.Vec)
  (fixtures-output String))

(define (empty-parsed-file) : ParsedFile
  (ParsedFile false "" "" (fbvec.new) (casevec.new) ""))

(define (case-row-copy [r : (& r CaseRow)]) : CaseRow
  (CaseRow
    r.kind
    r.line
    (string.copy (& r.a))
    (string.copy (& r.b))
    (string.copy (& r.c))
    r.n))

(define (file-block-copy [fb : (& fb FileBlock)]) : FileBlock
  (FileBlock
    fb.line
    (string.copy (& fb.path))
    (string.copy (& fb.flags))
    (string.copy (& fb.content))))

(define (case-rows-len [cdef : (& cdef CaseDef)]) : i64
  (rowvec.len (& cdef.rows)))

(define (case-rows-get [cdef : (& cdef CaseDef)] [idx : i64]) : CaseRow
  (if (and (>= idx 0) (< idx (rowvec.len (& cdef.rows))))
    (let
      [view : (& cdef (Slice CaseRow)) (rowvec.view (& cdef.rows))]
      (case-row-copy (& (array-ref view idx))))
    (CaseRow 0 0 "" "" "" 0)))

(define (parsed-pre-files-len [pf : (& pf ParsedFile)]) : i64
  (fbvec.len (& pf.pre-files)))

(define (parsed-pre-files-get [pf : (& pf ParsedFile)] [idx : i64]) : FileBlock
  (if (and (>= idx 0) (< idx (fbvec.len (& pf.pre-files))))
    (let
      [view : (& pf (Slice FileBlock)) (fbvec.view (& pf.pre-files))]
      (file-block-copy (& (array-ref view idx))))
    (FileBlock 0 "" "" "")))

(define (parsed-cases-len [pf : (& pf ParsedFile)]) : i64
  (casevec.len (& pf.cases)))

(define (parsed-cases-get [pf : (& pf ParsedFile)] [idx : i64]) : CaseDef
  (if (and (>= idx 0) (< idx (casevec.len (& pf.cases))))
    (let
      [view : (& pf (Slice CaseDef)) (casevec.view (& pf.cases))]
      [c : (& pf CaseDef) (& (array-ref view idx))]
      (CaseDef
        (string.copy (& c.id))
        c.line
        (string.copy (& c.do-action))
        (string.copy (& c.source))
        (string.copy (& c.args))
        (string.copy (& c.hosts))
        (string.copy (& c.target))
        (string.copy (& c.opt))
        (string.copy (& c.mode))
        (string.copy (& c.each))
        c.assemble
        c.repeatable
        c.has-exit
        c.needs-barrier
        (svec.clone-vec (& c.setups))
        (copy-rowvec (& c.rows))))
    (CaseDef
      ""
      0
      ""
      ""
      ""
      ""
      ""
      ""
      ""
      ""
      false
      false
      false
      false
      (svec.new)
      (rowvec.new))))

(defstruct CaseDefaults
  (target String)
  (opt String)
  (mode String)
  (each String)
  (do-action String)
  (hosts String)
  (args String)
  (source String)
  (assemble bool)
  (repeatable bool)
  (setups svec.Vec))

(define (copy-svec [src : (& src svec.Vec)]) : svec.Vec
  (let
    [out : svec.Vec (svec.new)]
    [n : i64 (svec.len src)]
    [i : i64 0]
    (while (< i n)
      (svec.push-ref! (&mut out) (svec.get src i ""))
      (set! i (+ i 1)))
    out))

(define (copy-rowvec [src : (& src rowvec.Vec)]) : rowvec.Vec
  (let
    [out : rowvec.Vec (rowvec.new)]
    [view : (& src (Slice CaseRow)) (rowvec.view src)]
    [n : i64 (array-length view)]
    [i : i64 0]
    (while (< i n)
      (let
        [r : (& src CaseRow) (& (array-ref view i))]
        (rowvec.push-ref!
          (&mut out)
          (CaseRow
            r.kind
            r.line
            (string.copy (& r.a))
            (string.copy (& r.b))
            (string.copy (& r.c))
            r.n)))
      (set! i (+ i 1)))
    out))

(define (defaults-new) : CaseDefaults
  (CaseDefaults
    "linux-x86_64"
    "2"
    "-"
    "-"
    "compile"
    "all"
    ""
    ""
    false
    false
    (svec.new)))

(define (defaults-copy [d : (& d CaseDefaults)]) : CaseDefaults
  (CaseDefaults
    (string.copy (& d.target))
    (string.copy (& d.opt))
    (string.copy (& d.mode))
    (string.copy (& d.each))
    (string.copy (& d.do-action))
    (string.copy (& d.hosts))
    (string.copy (& d.args))
    (string.copy (& d.source))
    d.assemble
    d.repeatable
    (copy-svec (& d.setups))))

(define (valid-capture-name? [name : (& name str)]) : bool
  (let
    [n : i64 (string.string-length name)]
    (if (= n 0)
      false
      (let
        [b0 : i64 (util.byte-at name 0)]
        (if (not (or (util.is-alpha-byte? b0) (= b0 95)))
          false
          (let
            [i : i64 1]
            [ok : bool true]
            (while (and ok (< i n))
              (let
                [b : i64 (util.byte-at name i)]
                (if (or (util.is-alnum-byte? b) (= b 95))
                  (set! i (+ i 1))
                  (set! ok false))))
            ok))))))

(define (valid-fixture-id? [id : (& id str)]) : bool
  (let
    [n : i64 (string.string-length id)]
    (if (= n 0)
      false
      (let
        [i : i64 0]
        [ok : bool true]
        (while (and ok (< i n))
          (let
            [b : i64 (util.byte-at id i)]
            (if (or (util.is-alnum-byte? b) (= b 95) (= b 45))
              (set! i (+ i 1))
              (set! ok false))))
        ok))))

(define (valid-fixture-source? [s : (& s str)]) : bool
  (let
    [n : i64 (string.string-length s)]
    (if (or
      (not (util.starts-with? s "tests/"))
      (not (util.ends-with? s ".tl"))
      (<= n 9)
      (>= (util.index-of-str-from s "//" 0) 0)
      (>= (util.index-of-str-from s "/./" 0) 0)
      (>= (util.index-of-str-from s "/../" 0) 0))
      false
      (let
        [i : i64 6]
        [ok : bool true]
        (while (and ok (< i (- n 3)))
          (let
            [b : i64 (util.byte-at s i)]
            (if (or (util.is-alnum-byte? b) (= b 95) (= b 46) (= b 47) (= b 45))
              (set! i (+ i 1))
              (set! ok false))))
        ok))))

(define (is-end-file-line? [raw : (& raw str)]) : bool
  (let
    [trimmed : String (util.trim-blanks raw)]
    (string.eq (& trimmed) "end-file")))

;; Parse file directive arguments: `[-nx] PATH` -> flags and path.
(defstruct FileHeader
  (flags String)
  (path String))

(define (parse-file-header [rest : (& rest str)]) : FileHeader
  (let
    [sp : i64 (util.index-of-byte-from rest 0 32)]
    (if (and (> sp 1) (= (util.byte-at rest 0) 45))
      (let
        [i : i64 1]
        [all-nx : bool true]
        (while (and all-nx (< i sp))
          (let
            [b : i64 (util.byte-at rest i)]
            (if (or (= b 110) (= b 120))
              (set! i (+ i 1))
              (set! all-nx false))))
        (if all-nx
          (FileHeader
            (string.substring rest 1 (- sp 1))
            (string.substring
              rest
              (+ sp 1)
              (- (string.string-length rest) (+ sp 1))))
          (FileHeader "-" (string.copy rest))))
      (FileHeader "-" (string.copy rest)))))

(define (svec-has? [v : (& v svec.Vec)] [target : (& target str)]) : bool
  (let
    [n : i64 (svec.len v)]
    [i : i64 0]
    [found : bool false]
    (while (and (not found) (< i n))
      (if (string.eq (svec.get v i "") target)
        (set! found true)
        (set! i (+ i 1))))
    found))

;; Check if a byte can continue a path segment (used to detect prefix boundaries
;; after a pre-file name like `foo.tl` vs `foo.tl.out` or `foo.tl:1:`).
(define (is-path-cont-byte? [b : i64]) : bool
  (or (util.is-alnum-byte? b) (= b 95) (= b 45) (= b 46) (= b 47) (= b 92)))

(define (text-touches-any-work? [text : (& text str)]) : bool
  (or
    (>= (util.index-of-str-from text "{{work}}" 0) 0)
    (>= (util.index-of-str-from text "{{native-work}}" 0) 0)))

(define (text-has-non-prefile-work-token?
  [text : (& text str)]
  [token : (& token str)]
  [pre-files : (& pre-files fbvec.Vec)]) : bool
  (let
    [tlen : i64 (string.string-length text)]
    [toklen : i64 (string.string-length token)]
    [np : i64 (fbvec.len pre-files)]
    [pos : i64 0]
    [needs : bool false]
    [done : bool false]
    (while (and (not needs) (not done))
      (let
        [hit : i64 (util.index-of-str-from text token pos)]
        (if (< hit 0)
          (set! done true)
          (let
            [after-tok : i64 (+ hit toklen)]
            (if (or (>= after-tok tlen) (!= (util.byte-at text after-tok) 47))
              ;; Bare {{work}} / {{native-work}} (not followed by '/')
              (set! needs true)
              (let
                [after : i64 (+ after-tok 1)]
                [matched-pre : bool false]
                [pre-view : (& pre-files (Slice FileBlock))
                  (fbvec.view pre-files)]
                [p : i64 0]
                (while (and (not matched-pre) (< p np))
                  (let
                    [pf : (& pre-files FileBlock) (& (array-ref pre-view p))]
                    [pflen : i64 (string.string-length (& pf.path))]
                    (when
                      (and (> pflen 0) (<= (+ after pflen) tlen))
                      (let
                        [slice-s : String (string.substring text after pflen)]
                        [end-pos : i64 (+ after pflen)]
                        [at-boundary : bool
                          (or
                            (= end-pos tlen)
                            (not
                              (is-path-cont-byte? (util.byte-at text end-pos))))]
                        (when
                          (and at-boundary (string.eq (& slice-s) (& pf.path)))
                          (set! matched-pre true)))))
                  (set! p (+ p 1)))
                (when (not matched-pre) (set! needs true))
                (set! pos after)))))))
    needs))

(define (text-has-non-prefile-work?
  [text : (& text str)]
  [pre-files : (& pre-files fbvec.Vec)]) : bool
  (or
    (text-has-non-prefile-work-token? text "{{work}}" pre-files)
    (text-has-non-prefile-work-token? text "{{native-work}}" pre-files)))

;; Check if a case references {{work}}/ or {{native-work}}/ other than read-only
;; references to the file's pre-case files, or mutates {{work}}/ via setup/file/sh.
;; Any such case needs a serialization barrier so parallel waves never race on
;; shared work paths.
(define (case-needs-barrier?
  [source : (& source str)]
  [args : (& args str)]
  [setups : (& setups svec.Vec)]
  [rows : (& rows rowvec.Vec)]
  [pre-files : (& pre-files fbvec.Vec)]) : bool
  (let
    [needs : bool
      (or
        (text-has-non-prefile-work? source pre-files)
        (text-has-non-prefile-work? args pre-files))]
    ;; Always barrier setup touching {{work}} or {{native-work}} (even on pre-file names)
    (let
      [ns : i64 (svec.len setups)]
      [si : i64 0]
      (while (and (not needs) (< si ns))
        (when
          (text-touches-any-work? (svec.get setups si ""))
          (set! needs true))
        (set! si (+ si 1))))
    ;; Scan ALL row kinds; always barrier file/sh touching {{work}} or {{native-work}}
    ;; even on pre-file names.
    (let
      [row-view : (& rows (Slice CaseRow)) (rowvec.view rows)]
      [nr : i64 (array-length row-view)]
      [i : i64 0]
      (while (and (not needs) (< i nr))
        (let
          [r : (& rows CaseRow) (& (array-ref row-view i))]
          (cond
            [(or (= r.kind rk-file) (= r.kind rk-sh))
              (when
                (or
                  (text-touches-any-work? (& r.a))
                  (text-has-non-prefile-work? (& r.b) pre-files)
                  (text-has-non-prefile-work? (& r.c) pre-files))
                (set! needs true))]
            [else
              (when
                (or
                  (text-has-non-prefile-work? (& r.a) pre-files)
                  (text-has-non-prefile-work? (& r.b) pre-files)
                  (text-has-non-prefile-work? (& r.c) pre-files))
                (set! needs true))]))
        (set! i (+ i 1))))
    needs))

;; Mutable parser state for one .cases file.
(defstruct ParseState
  (file-path String)
  (root String)
  (fixtures bool)
  (ok bool)
  (error String)
  (dflt CaseDefaults)
  (cfg CaseDefaults)
  (pre-files fbvec.Vec)
  (cases casevec.Vec)
  (seen-ids svec.Vec)
  (seen-fixture-sources svec.Vec)
  (fixtures-buf bbc.ByteBufBuilder)
  (ncase i64)
  (case-id String)
  (case-line i64)
  (rows rowvec.Vec)
  (depth i64)
  (has-exit bool)
  (step-open bool)
  (step-exit bool)
  (step-line i64)
  (step-depth i64)
  (pending-after String))

(define (ps-die! [ps : (&mut ps ParseState)] [line : i64] [msg : (& msg str)]) : unit
  (when
    ps.ok
    (set! ps.ok false)
    (set!
      ps.error
      (str_cat.str-cat
        (string.copy (& ps.file-path))
        ":"
        (string.int->string line)
        ": "
        (string.copy msg)))))

(define (ps-close-step! [ps : (&mut ps ParseState)]) : unit
  (when
    (and ps.step-open (not ps.step-exit))
    (rowvec.push-ref! (&mut ps.rows) (CaseRow rk-exit ps.step-line "0" "" "" 0)))
  (set! ps.step-open false))

(define (ps-close-block-step! [ps : (&mut ps ParseState)]) : unit
  (when (and ps.step-open (>= ps.step-depth ps.depth)) (ps-close-step! ps)))

(define (ps-open-step!
  [ps : (&mut ps ParseState)]
  [line : i64]
  [kind : i64]
  [rest : (& rest str)]) : unit
  (ps-close-step! ps)
  (rowvec.push-ref!
    (&mut ps.rows)
    (CaseRow kind line (string.copy rest) "" "" 0))
  (set! ps.step-open true)
  (set! ps.step-exit false)
  (set! ps.step-line line)
  (set! ps.step-depth ps.depth))

(define (ps-finish-case! [ps : (&mut ps ParseState)] [eof-line : i64]) : unit
  (if ps.fixtures
    (begin
      (when
        (not (valid-fixture-id? (& ps.case-id)))
        (ps-die! ps eof-line "invalid fixture label"))
      (when
        (and ps.ok (not (valid-fixture-source? (& ps.cfg.source))))
        (ps-die!
          ps
          eof-line
          (str_cat.str-cat
            "invalid fixture source: "
            (string.copy (& ps.cfg.source)))))
      (when
        (and ps.ok (not (string.eq (& ps.cfg.do-action) "none")))
        (ps-die! ps eof-line "fixture inventory requires do none"))
      (when
        (and ps.ok (svec-has? (& ps.seen-fixture-sources) (& ps.cfg.source)))
        (ps-die!
          ps
          eof-line
          (str_cat.str-cat
            "duplicate fixture source: "
            (string.copy (& ps.cfg.source)))))
      (when
        ps.ok
        (svec.push-ref!
          (&mut ps.seen-fixture-sources)
          (string.copy (& ps.cfg.source)))
        (let
          [full : String
            (str_cat.str-cat
              (string.copy (& ps.root))
              "/"
              (string.copy (& ps.cfg.source)))]
          (if (not (util.file-exists? (& full)))
            (ps-die!
              ps
              eof-line
              (str_cat.str-cat
                "missing fixture source: "
                (string.copy (& ps.cfg.source))))
            (begin
              (bbc.byte-buf-builder-append-string
                (&mut ps.fixtures-buf)
                (string.copy (& ps.case-id)))
              (bbc.byte-buf-builder-push (&mut ps.fixtures-buf) (cast 9 : u8))
              (bbc.byte-buf-builder-append-string
                (&mut ps.fixtures-buf)
                (string.copy (& ps.cfg.source)))
              (bbc.byte-buf-builder-push (&mut ps.fixtures-buf) (cast 10 : u8)))))))
    (begin
      (when
        (> (string.string-length (& ps.pending-after)) 0)
        (ps-die! ps eof-line "after without next-line"))
      (when
        (and ps.ok (!= ps.depth 0))
        (ps-die!
          ps
          eof-line
          (str_cat.str-cat
            "unclosed if-block in case "
            (string.copy (& ps.case-id)))))
      (when
        ps.ok
        (ps-close-step! ps)
        (let
          [barrier : bool
            (case-needs-barrier?
              (& ps.cfg.source)
              (& ps.cfg.args)
              (& ps.cfg.setups)
              (& ps.rows)
              (& ps.pre-files))]
          (casevec.push-ref!
            (&mut ps.cases)
            (CaseDef
              (string.copy (& ps.case-id))
              ps.case-line
              (string.copy (& ps.cfg.do-action))
              (string.copy (& ps.cfg.source))
              (string.copy (& ps.cfg.args))
              (string.copy (& ps.cfg.hosts))
              (string.copy (& ps.cfg.target))
              (string.copy (& ps.cfg.opt))
              (string.copy (& ps.cfg.mode))
              (string.copy (& ps.cfg.each))
              ps.cfg.assemble
              ps.cfg.repeatable
              ps.has-exit
              barrier
              (copy-svec (& ps.cfg.setups))
              (copy-rowvec (& ps.rows))))
          (set! ps.rows (rowvec.new)))))))

(define (ps-start-case!
  [ps : (&mut ps ParseState)]
  [line : i64]
  [id : (& id str)]) : unit
  (when (> ps.ncase 0) (ps-finish-case! ps line))
  (when
    ps.ok
    (if (svec-has? (& ps.seen-ids) id)
      (ps-die! ps line (str_cat.str-cat "duplicate case " (string.copy id)))
      (begin
        (svec.push-ref! (&mut ps.seen-ids) (string.copy id))
        (set! ps.ncase (+ ps.ncase 1))
        (set! ps.cfg (defaults-copy (& ps.dflt)))
        (set! ps.case-id (string.copy id))
        (set! ps.case-line line)
        (set! ps.rows (rowvec.new))
        (set! ps.depth 0)
        (set! ps.has-exit false)
        (set! ps.step-open false)
        (set! ps.step-exit false)
        (set! ps.step-line 0)
        (set! ps.step-depth 0)
        (set! ps.pending-after "")))))

(define (ps-set-config!
  [ps : (&mut ps ParseState)]
  [kw : (& kw str)]
  [val : (& val str)]) : unit
  (if (= ps.ncase 0)
    (cond
      [(string.eq kw "source") (set! ps.dflt.source (string.copy val))]
      [(string.eq kw "target") (set! ps.dflt.target (string.copy val))]
      [(string.eq kw "opt") (set! ps.dflt.opt (string.copy val))]
      [(string.eq kw "mode") (set! ps.dflt.mode (string.copy val))]
      [(string.eq kw "each") (set! ps.dflt.each (string.copy val))]
      [(string.eq kw "args") (set! ps.dflt.args (string.copy val))]
      [(string.eq kw "do") (set! ps.dflt.do-action (string.copy val))]
      [(string.eq kw "hosts") (set! ps.dflt.hosts (string.copy val))]
      [(string.eq kw "assemble") (set! ps.dflt.assemble true)]
      [(string.eq kw "repeatable") (set! ps.dflt.repeatable true)]
      [(string.eq kw "setup")
        (svec.push-ref! (&mut ps.dflt.setups) (string.copy val))]
      [else unit])
    (cond
      [(string.eq kw "source") (set! ps.cfg.source (string.copy val))]
      [(string.eq kw "target") (set! ps.cfg.target (string.copy val))]
      [(string.eq kw "opt") (set! ps.cfg.opt (string.copy val))]
      [(string.eq kw "mode") (set! ps.cfg.mode (string.copy val))]
      [(string.eq kw "each") (set! ps.cfg.each (string.copy val))]
      [(string.eq kw "args") (set! ps.cfg.args (string.copy val))]
      [(string.eq kw "do") (set! ps.cfg.do-action (string.copy val))]
      [(string.eq kw "hosts") (set! ps.cfg.hosts (string.copy val))]
      [(string.eq kw "assemble") (set! ps.cfg.assemble true)]
      [(string.eq kw "repeatable") (set! ps.cfg.repeatable true)]
      [(string.eq kw "setup")
        (svec.push-ref! (&mut ps.cfg.setups) (string.copy val))]
      [else unit])))

(define (ps-parse-row!
  [ps : (&mut ps ParseState)]
  [line : i64]
  [kw : (& kw str)]
  [rest : (& rest str)]) : unit
  (when
    (and
      (> (string.string-length (& ps.pending-after)) 0)
      (not (string.eq kw "next-line")))
    (ps-die! ps line "after must be followed by next-line"))
  (when
    ps.ok
    (cond
      [(string.eq kw "run") (ps-open-step! ps line rk-run rest)]
      [(string.eq kw "exec") (ps-open-step! ps line rk-exec rest)]
      [(string.eq kw "sh")
        (rowvec.push-ref!
          (&mut ps.rows)
          (CaseRow rk-sh line (string.copy rest) "" "" 0))]
      [(string.eq kw "cwd")
        (rowvec.push-ref!
          (&mut ps.rows)
          (CaseRow rk-cwd line (string.copy rest) "" "" 0))]
      [(string.eq kw "step")
        (ps-close-step! ps)
        (rowvec.push-ref!
          (&mut ps.rows)
          (CaseRow rk-step line (string.copy rest) "" "" 0))]
      [(string.eq kw "test")
        (rowvec.push-ref!
          (&mut ps.rows)
          (CaseRow rk-test line (string.copy rest) "" "" 0))]
      [(string.eq kw "same")
        (rowvec.push-ref!
          (&mut ps.rows)
          (CaseRow rk-same line (string.copy rest) "" "" 0))]
      [(and
        (or (string.eq kw "stdout") (string.eq kw "stderr"))
        (> (string.string-length rest) 0))
        (rowvec.push-ref!
          (&mut ps.rows)
          (CaseRow rk-in line (string.copy kw) "" "" 0))
        (let
          [sp : i64 (util.index-of-byte-from rest 0 32)]
          (if (>= sp 0)
            (let
              [sub-kw : String (string.substring rest 0 sp)]
              [sub-rest : String
                (string.substring
                  rest
                  (+ sp 1)
                  (- (string.string-length rest) (+ sp 1)))]
              (ps-parse-row! ps line (& sub-kw) (& sub-rest)))
            (ps-parse-row! ps line rest "")))]
      [(string.eq kw "in")
        (let
          [sp : i64 (util.index-of-byte-from rest 0 32)]
          (if (>= sp 0)
            (rowvec.push-ref!
              (&mut ps.rows)
              (CaseRow
                rk-in
                line
                (string.substring rest 0 sp)
                (string.substring
                  rest
                  (+ sp 1)
                  (- (string.string-length rest) (+ sp 1)))
                ""
                0))
            (rowvec.push-ref!
              (&mut ps.rows)
              (CaseRow rk-in line (string.copy rest) "" "" 0))))]
      [(string.eq kw "narrow")
        (rowvec.push-ref!
          (&mut ps.rows)
          (CaseRow rk-narrow line (string.copy rest) "" "" 0))]
      [(string.eq kw "exit")
        (if ps.step-open
          (set! ps.step-exit true)
          (set! ps.has-exit true))
        (rowvec.push-ref!
          (&mut ps.rows)
          (CaseRow rk-exit line (string.copy rest) "" "" 0))]
      [(string.eq kw "contains")
        (rowvec.push-ref!
          (&mut ps.rows)
          (CaseRow rk-contains line (string.copy rest) "" "" 0))]
      [(string.eq kw "is")
        (rowvec.push-ref!
          (&mut ps.rows)
          (CaseRow rk-is line (string.copy rest) "" "" 0))]
      [(string.eq kw "not-contains")
        (rowvec.push-ref!
          (&mut ps.rows)
          (CaseRow rk-not-contains line (string.copy rest) "" "" 0))]
      [(string.eq kw "contains-any")
        (rowvec.push-ref!
          (&mut ps.rows)
          (CaseRow rk-contains-any line (string.copy rest) "" "" 0))]
      [(string.eq kw "order")
        (rowvec.push-ref!
          (&mut ps.rows)
          (CaseRow rk-order line (string.copy rest) "" "" 0))]
      [(string.eq kw "match")
        (rowvec.push-ref!
          (&mut ps.rows)
          (CaseRow rk-match line (string.copy rest) "" "" 0))]
      [(string.eq kw "match-i")
        (rowvec.push-ref!
          (&mut ps.rows)
          (CaseRow rk-match-i line (string.copy rest) "" "" 0))]
      [(string.eq kw "not-match")
        (rowvec.push-ref!
          (&mut ps.rows)
          (CaseRow rk-not-match line (string.copy rest) "" "" 0))]
      [(string.eq kw "not-match-i")
        (rowvec.push-ref!
          (&mut ps.rows)
          (CaseRow rk-not-match-i line (string.copy rest) "" "" 0))]
      [(or (string.eq kw "count") (string.eq kw "count-fixed"))
        (let
          [sp1 : i64 (util.index-of-byte-from rest 0 32)]
          [sp2 : i64
            (if (>= sp1 0)
              (util.index-of-byte-from rest (+ sp1 1) 32)
              -1)]
          (if (< sp2 0)
            (ps-die!
              ps
              line
              (str_cat.str-cat (string.copy kw) " needs OP N TEXT"))
            (let
              [op : String (string.substring rest 0 sp1)]
              [n-str : String
                (string.substring rest (+ sp1 1) (- sp2 (+ sp1 1)))]
              [np : util.ParsedI64 (util.parse-u64-strict (& n-str))]
              [text : String
                (string.substring
                  rest
                  (+ sp2 1)
                  (- (string.string-length rest) (+ sp2 1)))]
              (cond
                [(and
                    (not (string.eq (& op) "="))
                    (not (string.eq (& op) ">="))
                    (not (string.eq (& op) "<=")))
                  (ps-die! ps line (str_cat.str-cat "bad operator " op))]
                [(not np.ok)
                  (ps-die! ps line (str_cat.str-cat "bad count " n-str))]
                [else
                  (rowvec.push-ref!
                    (&mut ps.rows)
                    (CaseRow
                      (if (string.eq kw "count")
                        rk-count
                        rk-count-fixed)
                      line
                      op
                      text
                      ""
                      np.value))]))))]
      [(string.eq kw "after") (set! ps.pending-after (string.copy rest))]
      [(string.eq kw "next-line")
        (if (= (string.string-length (& ps.pending-after)) 0)
          (ps-die! ps line "next-line without after")
          (begin
            (rowvec.push-ref!
              (&mut ps.rows)
              (CaseRow
                rk-next-line
                line
                (string.copy (& ps.pending-after))
                (string.copy rest)
                ""
                0))
            (set! ps.pending-after "")))]
      [(string.eq kw "empty")
        (rowvec.push-ref! (&mut ps.rows) (CaseRow rk-empty line "" "" "" 0))]
      [(string.eq kw "not-empty")
        (rowvec.push-ref! (&mut ps.rows) (CaseRow rk-not-empty line "" "" "" 0))]
      [(string.eq kw "metric")
        (let
          [sp1 : i64 (util.index-of-byte-from rest 0 32)]
          [sp2 : i64
            (if (>= sp1 0)
              (util.index-of-byte-from rest (+ sp1 1) 32)
              -1)]
          (if (< sp2 0)
            (ps-die! ps line "metric needs NAME OP VALUE")
            (let
              [spec : String (string.substring rest 0 sp1)]
              [op : String (string.substring rest (+ sp1 1) (- sp2 (+ sp1 1)))]
              [want : String
                (string.substring
                  rest
                  (+ sp2 1)
                  (- (string.string-length rest) (+ sp2 1)))]
              (if (and
                (not (string.eq (& op) "="))
                (not (string.eq (& op) ">="))
                (not (string.eq (& op) "<=")))
                (ps-die! ps line (str_cat.str-cat "bad operator " op))
                (rowvec.push-ref!
                  (&mut ps.rows)
                  (CaseRow rk-metric line spec op want 0))))))]
      [(string.eq kw "capture")
        (let
          [sp : i64 (util.index-of-byte-from rest 0 32)]
          (if (< sp 0)
            (ps-die! ps line "capture needs VAR ERE")
            (let
              [var : String (string.substring rest 0 sp)]
              [ere : String
                (string.substring
                  rest
                  (+ sp 1)
                  (- (string.string-length rest) (+ sp 1)))]
              (if (not (valid-capture-name? (& var)))
                (ps-die! ps line (str_cat.str-cat "bad capture name " var))
                (rowvec.push-ref!
                  (&mut ps.rows)
                  (CaseRow rk-capture line var ere "" 0))))))]
      [(string.eq kw "check")
        (rowvec.push-ref!
          (&mut ps.rows)
          (CaseRow rk-check line (string.copy rest) "" "" 0))]
      [(or
        (string.eq kw "if-fn")
        (string.eq kw "if-no-fn")
        (string.eq kw "if-mode")
        (string.eq kw "if-host")
        (string.eq kw "if-isa"))
        (ps-close-step! ps)
        (set! ps.depth (+ ps.depth 1))
        (let
          [kind : i64
            (cond
              [(string.eq kw "if-fn") rk-if-fn]
              [(string.eq kw "if-no-fn") rk-if-no-fn]
              [(string.eq kw "if-mode") rk-if-mode]
              [(string.eq kw "if-host") rk-if-host]
              [else rk-if-isa])]
          (rowvec.push-ref!
            (&mut ps.rows)
            (CaseRow kind line (string.copy rest) "" "" 0)))]
      [(string.eq kw "else")
        (if (= ps.depth 0)
          (ps-die! ps line "else without if")
          (begin
            (ps-close-block-step! ps)
            (rowvec.push-ref! (&mut ps.rows) (CaseRow rk-else line "" "" "" 0))))]
      [(string.eq kw "end-if")
        (if (= ps.depth 0)
          (ps-die! ps line "end-if without if")
          (begin
            (ps-close-block-step! ps)
            (set! ps.depth (- ps.depth 1))
            (rowvec.push-ref!
              (&mut ps.rows)
              (CaseRow rk-end-if line "" "" "" 0))))]
      [else
        (ps-die!
          ps
          line
          (str_cat.str-cat "unknown directive " (string.copy kw)))])))

(define (parse-cases-file
  [file-path : (& file-path str)]
  [root : (& root str)]
  [fixtures : bool]) : ParsedFile
  (let
    [rf : util.ReadFileResult (util.read-file-result file-path)]
    (if (not rf.ok)
      (ParsedFile
        false
        (str_cat.str-cat "missing case file: " (string.copy file-path))
        (string.copy file-path)
        (fbvec.new)
        (casevec.new)
        "")
      (let
        [ps : ParseState
          (ParseState
            (string.copy file-path)
            (string.copy root)
            fixtures
            true
            ""
            (defaults-new)
            (defaults-new)
            (fbvec.new)
            (casevec.new)
            (svec.new)
            (svec.new)
            (bbc.byte-buf-builder-new)
            0
            ""
            0
            (rowvec.new)
            0
            false
            false
            false
            0
            0
            "")]
        [lines : svec.Vec (util.split-lines (& rf.text))]
        [nlines : i64 (svec.len (& lines))]
        [infile : bool false]
        [file-line : i64 0]
        [file-path-arg : String ""]
        [file-flags : String ""]
        [file-buf : bbc.ByteBufBuilder (bbc.byte-buf-builder-new)]
        [idx : i64 0]
        (while (and ps.ok (< idx nlines))
          (let
            [nr : i64 (+ idx 1)]
            [raw : String (util.strip-cr (svec.get (& lines) idx ""))]
            (if infile
              (if (is-end-file-line? (& raw))
                (begin
                  (set! infile false)
                  (let
                    [content : String
                      (bbc.byte-buf-builder-finish-string (& file-buf))]
                    (if (> ps.ncase 0)
                      (rowvec.push-ref!
                        (&mut ps.rows)
                        (CaseRow
                          rk-file
                          file-line
                          (string.copy (& file-path-arg))
                          (string.copy (& file-flags))
                          content
                          0))
                      (fbvec.push-ref!
                        (&mut ps.pre-files)
                        (FileBlock
                          file-line
                          (string.copy (& file-path-arg))
                          (string.copy (& file-flags))
                          content)))))
                (begin
                  (bbc.byte-buf-builder-append-string (&mut file-buf) raw)
                  (bbc.byte-buf-builder-push (&mut file-buf) (cast 10 : u8))))
              (let
                [line : String (util.trim-leading-blanks (& raw))]
                (when
                  (and
                    (> (string.string-length (& line)) 0)
                    (!= (util.byte-at (& line) 0) 35))
                  (let
                    [sp : i64 (util.index-of-byte-from (& line) 0 32)]
                    [kw : String
                      (if (>= sp 0)
                        (string.substring (& line) 0 sp)
                        (string.copy (& line)))]
                    [rest : String
                      (if (>= sp 0)
                        (string.substring
                          (& line)
                          (+ sp 1)
                          (- (string.string-length (& line)) (+ sp 1)))
                        "")]
                    (when
                      (and
                        fixtures
                        (not (string.eq (& kw) "case"))
                        (not (string.eq (& kw) "source"))
                        (not
                          (and
                            (string.eq (& kw) "do")
                            (string.eq (& rest) "none"))))
                      (ps-die!
                        (&mut ps)
                        nr
                        (str_cat.str-cat
                          "unsupported fixture inventory directive: "
                          (string.copy (& kw)))))
                    (when
                      ps.ok
                      (cond
                        [(string.eq (& kw) "file")
                          (let
                            [fh : FileHeader (parse-file-header (& rest))]
                            (set! infile true)
                            (set! file-line nr)
                            (set! file-path-arg fh.path)
                            (set! file-flags fh.flags)
                            (set! file-buf (bbc.byte-buf-builder-new)))]
                        [(string.eq (& kw) "case")
                          (ps-start-case! (&mut ps) nr (& rest))]
                        [(or
                            (string.eq (& kw) "source")
                            (string.eq (& kw) "target")
                            (string.eq (& kw) "opt")
                            (string.eq (& kw) "mode")
                            (string.eq (& kw) "each")
                            (string.eq (& kw) "args")
                            (string.eq (& kw) "do")
                            (string.eq (& kw) "hosts")
                            (string.eq (& kw) "assemble")
                            (string.eq (& kw) "repeatable")
                            (string.eq (& kw) "setup"))
                          (ps-set-config! (&mut ps) (& kw) (& rest))]
                        [(= ps.ncase 0)
                          (ps-die!
                            (&mut ps)
                            nr
                            (str_cat.str-cat
                              "expectation before the first case: "
                              kw))]
                        [else (ps-parse-row! (&mut ps) nr (& kw) (& rest))])))))))
          (set! idx (+ idx 1)))
        (when
          (and ps.ok infile)
          (set! ps.ok false)
          (set!
            ps.error
            (str_cat.str-cat
              (string.copy file-path)
              ": unterminated file block")))
        (when
          (and ps.ok fixtures (= ps.ncase 0))
          (ps-die! (&mut ps) nlines "empty fixture inventory"))
        (when (and ps.ok (> ps.ncase 0)) (ps-finish-case! (&mut ps) nlines))
        (ParsedFile
          ps.ok
          ps.error
          (string.copy file-path)
          ps.pre-files
          ps.cases
          (bbc.byte-buf-builder-finish-string (& ps.fixtures-buf)))))))

;; Render --list lines for one ParsedFile (exact format parity with verify-codegen-cases.sh).
(define (render-list [pf : (& pf ParsedFile)]) : String
  (let
    [out : bbc.ByteBufBuilder (bbc.byte-buf-builder-new)]
    [cases-view : (& pf (Slice CaseDef)) (casevec.view (& pf.cases))]
    [nc : i64 (array-length cases-view)]
    [ci : i64 0]
    (while (< ci nc)
      (let
        [c : (& pf CaseDef) (& (array-ref cases-view ci))]
        [ts : svec.Vec (util.split-words-blank (& c.target))]
        [os : svec.Vec (util.split-words-blank (& c.opt))]
        [ms : svec.Vec (util.split-words-blank (& c.mode))]
        [es : svec.Vec (util.split-words-blank (& c.each))]
        [nt : i64 (svec.len (& ts))]
        [no : i64 (svec.len (& os))]
        [nm : i64 (svec.len (& ms))]
        [ne : i64 (svec.len (& es))]
        [ti : i64 0]
        (while (< ti nt)
          (let
            [t : String (svec.get (& ts) ti "")]
            [oi : i64 0]
            (while (< oi no)
              (let
                [o : String (svec.get (& os) oi "")]
                [mi : i64 0]
                (while (< mi nm)
                  (let
                    [m : String (svec.get (& ms) mi "")]
                    [ei : i64 0]
                    (while (< ei ne)
                      (let
                        [e : String (svec.get (& es) ei "")]
                        (bbc.byte-buf-builder-append-string
                          (&mut out)
                          (string.copy (& pf.file-path)))
                        (bbc.byte-buf-builder-push (&mut out) (cast 32 : u8))
                        (bbc.byte-buf-builder-append-string
                          (&mut out)
                          (string.copy (& c.id)))
                        (bbc.byte-buf-builder-append-string (&mut out) " [")
                        (bbc.byte-buf-builder-append-string
                          (&mut out)
                          (string.copy (& t)))
                        (bbc.byte-buf-builder-push (&mut out) (cast 32 : u8))
                        (bbc.byte-buf-builder-append-string
                          (&mut out)
                          (string.copy (& o)))
                        (bbc.byte-buf-builder-push (&mut out) (cast 32 : u8))
                        (bbc.byte-buf-builder-append-string
                          (&mut out)
                          (string.copy (& m)))
                        (when
                          (not (string.eq (& e) "-"))
                          (bbc.byte-buf-builder-push (&mut out) (cast 32 : u8))
                          (bbc.byte-buf-builder-append-string (&mut out) e))
                        (bbc.byte-buf-builder-append-string (&mut out) "]\n"))
                      (set! ei (+ ei 1))))
                  (set! mi (+ mi 1))))
              (set! oi (+ oi 1))))
          (set! ti (+ ti 1))))
      (set! ci (+ ci 1)))
    (bbc.byte-buf-builder-finish-string (& out))))
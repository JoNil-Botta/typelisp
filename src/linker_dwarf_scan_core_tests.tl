;; Tests for linker_dwarf_scan_core.tl: the GCC, Clang and TypeLisp fixture
;; corpus of tests/fixtures/dwarf (whose summaries match llvm-dwarfdump, see
;; scripts/analyze-dwarf-corpus.sh) and hand-assembled units for every
;; rejection and limit.
(import linker_dwarf_scan_core as dwarf)
(import stdlib.str_cat)
(import stdlib.string)
(cfg test (import stdlib.test))

;; --- fixture corpus ------------------------------------------------------------------
;: Append a copy of `bytes` as the view (`input`, `section`) named `name`.
(define (dwarf-fixture-push!
  [views : (&mut views (__tl_dyn-array dwarf.LinkerDwarfView))]
  [input : i64]
  [section : i64]
  [name : (& name str)]
  [relocatable : bool]
  [bytes : (& bytes (__tl_dyn-array u8))]) : unit
  (let
    [copy : (__tl_dyn-array u8) (__tl_make-array u8 (array-length bytes))]
    [index : i64 0]
    (begin
      (while (< index (array-length bytes))
        (begin
          (set! (array-ref copy index) (array-ref bytes index))
          (set! index (+ index 1))))
      (__tl_array-push!
        views
        (dwarf.LinkerDwarfView
          input
          section
          (dwarf.linker-dwarf-section-kind-from-name name)
          relocatable
          copy)))))

(include-bin
  dwarf-fx-clang-dwarf4-o0-05-debug-abbrev
  "../tests/fixtures/dwarf/clang-dwarf4-O0/05.debug_abbrev.bin")

(include-bin
  dwarf-fx-clang-dwarf4-o0-06-debug-info
  "../tests/fixtures/dwarf/clang-dwarf4-O0/06.debug_info.bin")

(include-bin
  dwarf-fx-clang-dwarf4-o0-08-debug-str
  "../tests/fixtures/dwarf/clang-dwarf4-O0/08.debug_str.bin")

(include-bin
  dwarf-fx-clang-dwarf4-o0-13-debug-line
  "../tests/fixtures/dwarf/clang-dwarf4-O0/13.debug_line.bin")

;: The sections of fixture `clang-dwarf4-O0` as views of input `input`.
(define (dwarf-fixture-clang-dwarf4-o0 [input : i64]) : (__tl_dyn-array
    dwarf.LinkerDwarfView)
  (let
    [views : (__tl_dyn-array dwarf.LinkerDwarfView)
      (__tl_make-array dwarf.LinkerDwarfView 0)]
    (begin
      (dwarf-fixture-push!
        (&mut views)
        input
        5
        ".debug_abbrev"
        true
        (& dwarf-fx-clang-dwarf4-o0-05-debug-abbrev))
      (dwarf-fixture-push!
        (&mut views)
        input
        6
        ".debug_info"
        true
        (& dwarf-fx-clang-dwarf4-o0-06-debug-info))
      (dwarf-fixture-push!
        (&mut views)
        input
        8
        ".debug_str"
        true
        (& dwarf-fx-clang-dwarf4-o0-08-debug-str))
      (dwarf-fixture-push!
        (&mut views)
        input
        13
        ".debug_line"
        true
        (& dwarf-fx-clang-dwarf4-o0-13-debug-line))
      views)))

(include-bin
  dwarf-fx-clang-dwarf4-o2-split-02-debug-abbrev
  "../tests/fixtures/dwarf/clang-dwarf4-O2-split/02.debug_abbrev.bin")

(include-bin
  dwarf-fx-clang-dwarf4-o2-split-03-debug-info
  "../tests/fixtures/dwarf/clang-dwarf4-O2-split/03.debug_info.bin")

(include-bin
  dwarf-fx-clang-dwarf4-o2-split-05-debug-str
  "../tests/fixtures/dwarf/clang-dwarf4-O2-split/05.debug_str.bin")

(include-bin
  dwarf-fx-clang-dwarf4-o2-split-06-debug-addr
  "../tests/fixtures/dwarf/clang-dwarf4-O2-split/06.debug_addr.bin")

(include-bin
  dwarf-fx-clang-dwarf4-o2-split-08-debug-gnu-pubnames
  "../tests/fixtures/dwarf/clang-dwarf4-O2-split/08.debug_gnu_pubnames.bin")

(include-bin
  dwarf-fx-clang-dwarf4-o2-split-10-debug-gnu-pubtypes
  "../tests/fixtures/dwarf/clang-dwarf4-O2-split/10.debug_gnu_pubtypes.bin")

(include-bin
  dwarf-fx-clang-dwarf4-o2-split-16-debug-line
  "../tests/fixtures/dwarf/clang-dwarf4-O2-split/16.debug_line.bin")

;: The sections of fixture `clang-dwarf4-O2-split` as views of input `input`.
(define (dwarf-fixture-clang-dwarf4-o2-split [input : i64]) : (__tl_dyn-array
    dwarf.LinkerDwarfView)
  (let
    [views : (__tl_dyn-array dwarf.LinkerDwarfView)
      (__tl_make-array dwarf.LinkerDwarfView 0)]
    (begin
      (dwarf-fixture-push!
        (&mut views)
        input
        2
        ".debug_abbrev"
        true
        (& dwarf-fx-clang-dwarf4-o2-split-02-debug-abbrev))
      (dwarf-fixture-push!
        (&mut views)
        input
        3
        ".debug_info"
        true
        (& dwarf-fx-clang-dwarf4-o2-split-03-debug-info))
      (dwarf-fixture-push!
        (&mut views)
        input
        5
        ".debug_str"
        true
        (& dwarf-fx-clang-dwarf4-o2-split-05-debug-str))
      (dwarf-fixture-push!
        (&mut views)
        input
        6
        ".debug_addr"
        true
        (& dwarf-fx-clang-dwarf4-o2-split-06-debug-addr))
      (dwarf-fixture-push!
        (&mut views)
        input
        8
        ".debug_gnu_pubnames"
        true
        (& dwarf-fx-clang-dwarf4-o2-split-08-debug-gnu-pubnames))
      (dwarf-fixture-push!
        (&mut views)
        input
        10
        ".debug_gnu_pubtypes"
        true
        (& dwarf-fx-clang-dwarf4-o2-split-10-debug-gnu-pubtypes))
      (dwarf-fixture-push!
        (&mut views)
        input
        16
        ".debug_line"
        true
        (& dwarf-fx-clang-dwarf4-o2-split-16-debug-line))
      views)))

(include-bin
  dwarf-fx-clang-dwarf4-o2-split-dwo-01-debug-loc-dwo
  "../tests/fixtures/dwarf/clang-dwarf4-O2-split-dwo/01.debug_loc.dwo.bin")

(include-bin
  dwarf-fx-clang-dwarf4-o2-split-dwo-02-debug-str-dwo
  "../tests/fixtures/dwarf/clang-dwarf4-O2-split-dwo/02.debug_str.dwo.bin")

(include-bin
  dwarf-fx-clang-dwarf4-o2-split-dwo-03-debug-str-offsets-dwo
  "../tests/fixtures/dwarf/clang-dwarf4-O2-split-dwo/03.debug_str_offsets.dwo.bin")

(include-bin
  dwarf-fx-clang-dwarf4-o2-split-dwo-04-debug-info-dwo
  "../tests/fixtures/dwarf/clang-dwarf4-O2-split-dwo/04.debug_info.dwo.bin")

(include-bin
  dwarf-fx-clang-dwarf4-o2-split-dwo-05-debug-abbrev-dwo
  "../tests/fixtures/dwarf/clang-dwarf4-O2-split-dwo/05.debug_abbrev.dwo.bin")

;: The sections of fixture `clang-dwarf4-O2-split-dwo` as views of input `input`.
(define (dwarf-fixture-clang-dwarf4-o2-split-dwo [input : i64]) : (__tl_dyn-array
    dwarf.LinkerDwarfView)
  (let
    [views : (__tl_dyn-array dwarf.LinkerDwarfView)
      (__tl_make-array dwarf.LinkerDwarfView 0)]
    (begin
      (dwarf-fixture-push!
        (&mut views)
        input
        1
        ".debug_loc.dwo"
        false
        (& dwarf-fx-clang-dwarf4-o2-split-dwo-01-debug-loc-dwo))
      (dwarf-fixture-push!
        (&mut views)
        input
        2
        ".debug_str.dwo"
        false
        (& dwarf-fx-clang-dwarf4-o2-split-dwo-02-debug-str-dwo))
      (dwarf-fixture-push!
        (&mut views)
        input
        3
        ".debug_str_offsets.dwo"
        false
        (& dwarf-fx-clang-dwarf4-o2-split-dwo-03-debug-str-offsets-dwo))
      (dwarf-fixture-push!
        (&mut views)
        input
        4
        ".debug_info.dwo"
        false
        (& dwarf-fx-clang-dwarf4-o2-split-dwo-04-debug-info-dwo))
      (dwarf-fixture-push!
        (&mut views)
        input
        5
        ".debug_abbrev.dwo"
        false
        (& dwarf-fx-clang-dwarf4-o2-split-dwo-05-debug-abbrev-dwo))
      views)))

(include-bin
  dwarf-fx-clang-dwarf5-o0-05-debug-abbrev
  "../tests/fixtures/dwarf/clang-dwarf5-O0/05.debug_abbrev.bin")

(include-bin
  dwarf-fx-clang-dwarf5-o0-06-debug-info
  "../tests/fixtures/dwarf/clang-dwarf5-O0/06.debug_info.bin")

(include-bin
  dwarf-fx-clang-dwarf5-o0-08-debug-str-offsets
  "../tests/fixtures/dwarf/clang-dwarf5-O0/08.debug_str_offsets.bin")

(include-bin
  dwarf-fx-clang-dwarf5-o0-10-debug-str
  "../tests/fixtures/dwarf/clang-dwarf5-O0/10.debug_str.bin")

(include-bin
  dwarf-fx-clang-dwarf5-o0-11-debug-addr
  "../tests/fixtures/dwarf/clang-dwarf5-O0/11.debug_addr.bin")

(include-bin
  dwarf-fx-clang-dwarf5-o0-17-debug-line
  "../tests/fixtures/dwarf/clang-dwarf5-O0/17.debug_line.bin")

(include-bin
  dwarf-fx-clang-dwarf5-o0-19-debug-line-str
  "../tests/fixtures/dwarf/clang-dwarf5-O0/19.debug_line_str.bin")

;: The sections of fixture `clang-dwarf5-O0` as views of input `input`.
(define (dwarf-fixture-clang-dwarf5-o0 [input : i64]) : (__tl_dyn-array
    dwarf.LinkerDwarfView)
  (let
    [views : (__tl_dyn-array dwarf.LinkerDwarfView)
      (__tl_make-array dwarf.LinkerDwarfView 0)]
    (begin
      (dwarf-fixture-push!
        (&mut views)
        input
        5
        ".debug_abbrev"
        true
        (& dwarf-fx-clang-dwarf5-o0-05-debug-abbrev))
      (dwarf-fixture-push!
        (&mut views)
        input
        6
        ".debug_info"
        true
        (& dwarf-fx-clang-dwarf5-o0-06-debug-info))
      (dwarf-fixture-push!
        (&mut views)
        input
        8
        ".debug_str_offsets"
        true
        (& dwarf-fx-clang-dwarf5-o0-08-debug-str-offsets))
      (dwarf-fixture-push!
        (&mut views)
        input
        10
        ".debug_str"
        true
        (& dwarf-fx-clang-dwarf5-o0-10-debug-str))
      (dwarf-fixture-push!
        (&mut views)
        input
        11
        ".debug_addr"
        true
        (& dwarf-fx-clang-dwarf5-o0-11-debug-addr))
      (dwarf-fixture-push!
        (&mut views)
        input
        17
        ".debug_line"
        true
        (& dwarf-fx-clang-dwarf5-o0-17-debug-line))
      (dwarf-fixture-push!
        (&mut views)
        input
        19
        ".debug_line_str"
        true
        (& dwarf-fx-clang-dwarf5-o0-19-debug-line-str))
      views)))

(include-bin
  dwarf-fx-clang-dwarf5-o2-02-debug-loclists
  "../tests/fixtures/dwarf/clang-dwarf5-O2/02.debug_loclists.bin")

(include-bin
  dwarf-fx-clang-dwarf5-o2-03-debug-abbrev
  "../tests/fixtures/dwarf/clang-dwarf5-O2/03.debug_abbrev.bin")

(include-bin
  dwarf-fx-clang-dwarf5-o2-04-debug-info
  "../tests/fixtures/dwarf/clang-dwarf5-O2/04.debug_info.bin")

(include-bin
  dwarf-fx-clang-dwarf5-o2-06-debug-str-offsets
  "../tests/fixtures/dwarf/clang-dwarf5-O2/06.debug_str_offsets.bin")

(include-bin
  dwarf-fx-clang-dwarf5-o2-08-debug-str
  "../tests/fixtures/dwarf/clang-dwarf5-O2/08.debug_str.bin")

(include-bin
  dwarf-fx-clang-dwarf5-o2-09-debug-addr
  "../tests/fixtures/dwarf/clang-dwarf5-O2/09.debug_addr.bin")

(include-bin
  dwarf-fx-clang-dwarf5-o2-15-debug-line
  "../tests/fixtures/dwarf/clang-dwarf5-O2/15.debug_line.bin")

(include-bin
  dwarf-fx-clang-dwarf5-o2-17-debug-line-str
  "../tests/fixtures/dwarf/clang-dwarf5-O2/17.debug_line_str.bin")

;: The sections of fixture `clang-dwarf5-O2` as views of input `input`.
(define (dwarf-fixture-clang-dwarf5-o2 [input : i64]) : (__tl_dyn-array
    dwarf.LinkerDwarfView)
  (let
    [views : (__tl_dyn-array dwarf.LinkerDwarfView)
      (__tl_make-array dwarf.LinkerDwarfView 0)]
    (begin
      (dwarf-fixture-push!
        (&mut views)
        input
        2
        ".debug_loclists"
        true
        (& dwarf-fx-clang-dwarf5-o2-02-debug-loclists))
      (dwarf-fixture-push!
        (&mut views)
        input
        3
        ".debug_abbrev"
        true
        (& dwarf-fx-clang-dwarf5-o2-03-debug-abbrev))
      (dwarf-fixture-push!
        (&mut views)
        input
        4
        ".debug_info"
        true
        (& dwarf-fx-clang-dwarf5-o2-04-debug-info))
      (dwarf-fixture-push!
        (&mut views)
        input
        6
        ".debug_str_offsets"
        true
        (& dwarf-fx-clang-dwarf5-o2-06-debug-str-offsets))
      (dwarf-fixture-push!
        (&mut views)
        input
        8
        ".debug_str"
        true
        (& dwarf-fx-clang-dwarf5-o2-08-debug-str))
      (dwarf-fixture-push!
        (&mut views)
        input
        9
        ".debug_addr"
        true
        (& dwarf-fx-clang-dwarf5-o2-09-debug-addr))
      (dwarf-fixture-push!
        (&mut views)
        input
        15
        ".debug_line"
        true
        (& dwarf-fx-clang-dwarf5-o2-15-debug-line))
      (dwarf-fixture-push!
        (&mut views)
        input
        17
        ".debug_line_str"
        true
        (& dwarf-fx-clang-dwarf5-o2-17-debug-line-str))
      views)))

(include-bin
  dwarf-fx-clang-dwarf5-o2-function-sections-04-debug-loclists
  "../tests/fixtures/dwarf/clang-dwarf5-O2-function-sections/04.debug_loclists.bin")

(include-bin
  dwarf-fx-clang-dwarf5-o2-function-sections-05-debug-abbrev
  "../tests/fixtures/dwarf/clang-dwarf5-O2-function-sections/05.debug_abbrev.bin")

(include-bin
  dwarf-fx-clang-dwarf5-o2-function-sections-06-debug-info
  "../tests/fixtures/dwarf/clang-dwarf5-O2-function-sections/06.debug_info.bin")

(include-bin
  dwarf-fx-clang-dwarf5-o2-function-sections-08-debug-rnglists
  "../tests/fixtures/dwarf/clang-dwarf5-O2-function-sections/08.debug_rnglists.bin")

(include-bin
  dwarf-fx-clang-dwarf5-o2-function-sections-09-debug-str-offsets
  "../tests/fixtures/dwarf/clang-dwarf5-O2-function-sections/09.debug_str_offsets.bin")

(include-bin
  dwarf-fx-clang-dwarf5-o2-function-sections-11-debug-str
  "../tests/fixtures/dwarf/clang-dwarf5-O2-function-sections/11.debug_str.bin")

(include-bin
  dwarf-fx-clang-dwarf5-o2-function-sections-12-debug-addr
  "../tests/fixtures/dwarf/clang-dwarf5-O2-function-sections/12.debug_addr.bin")

(include-bin
  dwarf-fx-clang-dwarf5-o2-function-sections-18-debug-line
  "../tests/fixtures/dwarf/clang-dwarf5-O2-function-sections/18.debug_line.bin")

(include-bin
  dwarf-fx-clang-dwarf5-o2-function-sections-20-debug-line-str
  "../tests/fixtures/dwarf/clang-dwarf5-O2-function-sections/20.debug_line_str.bin")

;: The sections of fixture `clang-dwarf5-O2-function-sections` as views of input `input`.
(define (dwarf-fixture-clang-dwarf5-o2-function-sections [input : i64]) : (__tl_dyn-array
    dwarf.LinkerDwarfView)
  (let
    [views : (__tl_dyn-array dwarf.LinkerDwarfView)
      (__tl_make-array dwarf.LinkerDwarfView 0)]
    (begin
      (dwarf-fixture-push!
        (&mut views)
        input
        4
        ".debug_loclists"
        true
        (& dwarf-fx-clang-dwarf5-o2-function-sections-04-debug-loclists))
      (dwarf-fixture-push!
        (&mut views)
        input
        5
        ".debug_abbrev"
        true
        (& dwarf-fx-clang-dwarf5-o2-function-sections-05-debug-abbrev))
      (dwarf-fixture-push!
        (&mut views)
        input
        6
        ".debug_info"
        true
        (& dwarf-fx-clang-dwarf5-o2-function-sections-06-debug-info))
      (dwarf-fixture-push!
        (&mut views)
        input
        8
        ".debug_rnglists"
        true
        (& dwarf-fx-clang-dwarf5-o2-function-sections-08-debug-rnglists))
      (dwarf-fixture-push!
        (&mut views)
        input
        9
        ".debug_str_offsets"
        true
        (& dwarf-fx-clang-dwarf5-o2-function-sections-09-debug-str-offsets))
      (dwarf-fixture-push!
        (&mut views)
        input
        11
        ".debug_str"
        true
        (& dwarf-fx-clang-dwarf5-o2-function-sections-11-debug-str))
      (dwarf-fixture-push!
        (&mut views)
        input
        12
        ".debug_addr"
        true
        (& dwarf-fx-clang-dwarf5-o2-function-sections-12-debug-addr))
      (dwarf-fixture-push!
        (&mut views)
        input
        18
        ".debug_line"
        true
        (& dwarf-fx-clang-dwarf5-o2-function-sections-18-debug-line))
      (dwarf-fixture-push!
        (&mut views)
        input
        20
        ".debug_line_str"
        true
        (& dwarf-fx-clang-dwarf5-o2-function-sections-20-debug-line-str))
      views)))

(include-bin
  dwarf-fx-clang-dwarf5-o2-split-02-debug-abbrev
  "../tests/fixtures/dwarf/clang-dwarf5-O2-split/02.debug_abbrev.bin")

(include-bin
  dwarf-fx-clang-dwarf5-o2-split-03-debug-info
  "../tests/fixtures/dwarf/clang-dwarf5-O2-split/03.debug_info.bin")

(include-bin
  dwarf-fx-clang-dwarf5-o2-split-05-debug-str-offsets
  "../tests/fixtures/dwarf/clang-dwarf5-O2-split/05.debug_str_offsets.bin")

(include-bin
  dwarf-fx-clang-dwarf5-o2-split-07-debug-str
  "../tests/fixtures/dwarf/clang-dwarf5-O2-split/07.debug_str.bin")

(include-bin
  dwarf-fx-clang-dwarf5-o2-split-08-debug-addr
  "../tests/fixtures/dwarf/clang-dwarf5-O2-split/08.debug_addr.bin")

(include-bin
  dwarf-fx-clang-dwarf5-o2-split-10-debug-gnu-pubnames
  "../tests/fixtures/dwarf/clang-dwarf5-O2-split/10.debug_gnu_pubnames.bin")

(include-bin
  dwarf-fx-clang-dwarf5-o2-split-12-debug-gnu-pubtypes
  "../tests/fixtures/dwarf/clang-dwarf5-O2-split/12.debug_gnu_pubtypes.bin")

(include-bin
  dwarf-fx-clang-dwarf5-o2-split-18-debug-line
  "../tests/fixtures/dwarf/clang-dwarf5-O2-split/18.debug_line.bin")

(include-bin
  dwarf-fx-clang-dwarf5-o2-split-20-debug-line-str
  "../tests/fixtures/dwarf/clang-dwarf5-O2-split/20.debug_line_str.bin")

;: The sections of fixture `clang-dwarf5-O2-split` as views of input `input`.
(define (dwarf-fixture-clang-dwarf5-o2-split [input : i64]) : (__tl_dyn-array
    dwarf.LinkerDwarfView)
  (let
    [views : (__tl_dyn-array dwarf.LinkerDwarfView)
      (__tl_make-array dwarf.LinkerDwarfView 0)]
    (begin
      (dwarf-fixture-push!
        (&mut views)
        input
        2
        ".debug_abbrev"
        true
        (& dwarf-fx-clang-dwarf5-o2-split-02-debug-abbrev))
      (dwarf-fixture-push!
        (&mut views)
        input
        3
        ".debug_info"
        true
        (& dwarf-fx-clang-dwarf5-o2-split-03-debug-info))
      (dwarf-fixture-push!
        (&mut views)
        input
        5
        ".debug_str_offsets"
        true
        (& dwarf-fx-clang-dwarf5-o2-split-05-debug-str-offsets))
      (dwarf-fixture-push!
        (&mut views)
        input
        7
        ".debug_str"
        true
        (& dwarf-fx-clang-dwarf5-o2-split-07-debug-str))
      (dwarf-fixture-push!
        (&mut views)
        input
        8
        ".debug_addr"
        true
        (& dwarf-fx-clang-dwarf5-o2-split-08-debug-addr))
      (dwarf-fixture-push!
        (&mut views)
        input
        10
        ".debug_gnu_pubnames"
        true
        (& dwarf-fx-clang-dwarf5-o2-split-10-debug-gnu-pubnames))
      (dwarf-fixture-push!
        (&mut views)
        input
        12
        ".debug_gnu_pubtypes"
        true
        (& dwarf-fx-clang-dwarf5-o2-split-12-debug-gnu-pubtypes))
      (dwarf-fixture-push!
        (&mut views)
        input
        18
        ".debug_line"
        true
        (& dwarf-fx-clang-dwarf5-o2-split-18-debug-line))
      (dwarf-fixture-push!
        (&mut views)
        input
        20
        ".debug_line_str"
        true
        (& dwarf-fx-clang-dwarf5-o2-split-20-debug-line-str))
      views)))

(include-bin
  dwarf-fx-clang-dwarf5-o2-split-dwo-01-debug-loclists-dwo
  "../tests/fixtures/dwarf/clang-dwarf5-O2-split-dwo/01.debug_loclists.dwo.bin")

(include-bin
  dwarf-fx-clang-dwarf5-o2-split-dwo-02-debug-str-offsets-dwo
  "../tests/fixtures/dwarf/clang-dwarf5-O2-split-dwo/02.debug_str_offsets.dwo.bin")

(include-bin
  dwarf-fx-clang-dwarf5-o2-split-dwo-03-debug-str-dwo
  "../tests/fixtures/dwarf/clang-dwarf5-O2-split-dwo/03.debug_str.dwo.bin")

(include-bin
  dwarf-fx-clang-dwarf5-o2-split-dwo-04-debug-info-dwo
  "../tests/fixtures/dwarf/clang-dwarf5-O2-split-dwo/04.debug_info.dwo.bin")

(include-bin
  dwarf-fx-clang-dwarf5-o2-split-dwo-05-debug-abbrev-dwo
  "../tests/fixtures/dwarf/clang-dwarf5-O2-split-dwo/05.debug_abbrev.dwo.bin")

(include-bin
  dwarf-fx-clang-dwarf5-o2-split-dwo-06-debug-rnglists-dwo
  "../tests/fixtures/dwarf/clang-dwarf5-O2-split-dwo/06.debug_rnglists.dwo.bin")

;: The sections of fixture `clang-dwarf5-O2-split-dwo` as views of input `input`.
(define (dwarf-fixture-clang-dwarf5-o2-split-dwo [input : i64]) : (__tl_dyn-array
    dwarf.LinkerDwarfView)
  (let
    [views : (__tl_dyn-array dwarf.LinkerDwarfView)
      (__tl_make-array dwarf.LinkerDwarfView 0)]
    (begin
      (dwarf-fixture-push!
        (&mut views)
        input
        1
        ".debug_loclists.dwo"
        false
        (& dwarf-fx-clang-dwarf5-o2-split-dwo-01-debug-loclists-dwo))
      (dwarf-fixture-push!
        (&mut views)
        input
        2
        ".debug_str_offsets.dwo"
        false
        (& dwarf-fx-clang-dwarf5-o2-split-dwo-02-debug-str-offsets-dwo))
      (dwarf-fixture-push!
        (&mut views)
        input
        3
        ".debug_str.dwo"
        false
        (& dwarf-fx-clang-dwarf5-o2-split-dwo-03-debug-str-dwo))
      (dwarf-fixture-push!
        (&mut views)
        input
        4
        ".debug_info.dwo"
        false
        (& dwarf-fx-clang-dwarf5-o2-split-dwo-04-debug-info-dwo))
      (dwarf-fixture-push!
        (&mut views)
        input
        5
        ".debug_abbrev.dwo"
        false
        (& dwarf-fx-clang-dwarf5-o2-split-dwo-05-debug-abbrev-dwo))
      (dwarf-fixture-push!
        (&mut views)
        input
        6
        ".debug_rnglists.dwo"
        false
        (& dwarf-fx-clang-dwarf5-o2-split-dwo-06-debug-rnglists-dwo))
      views)))

(include-bin
  dwarf-fx-gcc-dwarf4-o0-05-debug-info
  "../tests/fixtures/dwarf/gcc-dwarf4-O0/05.debug_info.bin")

(include-bin
  dwarf-fx-gcc-dwarf4-o0-07-debug-abbrev
  "../tests/fixtures/dwarf/gcc-dwarf4-O0/07.debug_abbrev.bin")

(include-bin
  dwarf-fx-gcc-dwarf4-o0-08-debug-aranges
  "../tests/fixtures/dwarf/gcc-dwarf4-O0/08.debug_aranges.bin")

(include-bin
  dwarf-fx-gcc-dwarf4-o0-10-debug-line
  "../tests/fixtures/dwarf/gcc-dwarf4-O0/10.debug_line.bin")

(include-bin
  dwarf-fx-gcc-dwarf4-o0-12-debug-str
  "../tests/fixtures/dwarf/gcc-dwarf4-O0/12.debug_str.bin")

;: The sections of fixture `gcc-dwarf4-O0` as views of input `input`.
(define (dwarf-fixture-gcc-dwarf4-o0 [input : i64]) : (__tl_dyn-array
    dwarf.LinkerDwarfView)
  (let
    [views : (__tl_dyn-array dwarf.LinkerDwarfView)
      (__tl_make-array dwarf.LinkerDwarfView 0)]
    (begin
      (dwarf-fixture-push!
        (&mut views)
        input
        5
        ".debug_info"
        true
        (& dwarf-fx-gcc-dwarf4-o0-05-debug-info))
      (dwarf-fixture-push!
        (&mut views)
        input
        7
        ".debug_abbrev"
        true
        (& dwarf-fx-gcc-dwarf4-o0-07-debug-abbrev))
      (dwarf-fixture-push!
        (&mut views)
        input
        8
        ".debug_aranges"
        true
        (& dwarf-fx-gcc-dwarf4-o0-08-debug-aranges))
      (dwarf-fixture-push!
        (&mut views)
        input
        10
        ".debug_line"
        true
        (& dwarf-fx-gcc-dwarf4-o0-10-debug-line))
      (dwarf-fixture-push!
        (&mut views)
        input
        12
        ".debug_str"
        true
        (& dwarf-fx-gcc-dwarf4-o0-12-debug-str))
      views)))

(include-bin
  dwarf-fx-gcc-dwarf4-o0-types-06-debug-types
  "../tests/fixtures/dwarf/gcc-dwarf4-O0-types/06.debug_types.bin")

(include-bin
  dwarf-fx-gcc-dwarf4-o0-types-08-debug-info
  "../tests/fixtures/dwarf/gcc-dwarf4-O0-types/08.debug_info.bin")

(include-bin
  dwarf-fx-gcc-dwarf4-o0-types-10-debug-abbrev
  "../tests/fixtures/dwarf/gcc-dwarf4-O0-types/10.debug_abbrev.bin")

(include-bin
  dwarf-fx-gcc-dwarf4-o0-types-11-debug-aranges
  "../tests/fixtures/dwarf/gcc-dwarf4-O0-types/11.debug_aranges.bin")

(include-bin
  dwarf-fx-gcc-dwarf4-o0-types-13-debug-line
  "../tests/fixtures/dwarf/gcc-dwarf4-O0-types/13.debug_line.bin")

(include-bin
  dwarf-fx-gcc-dwarf4-o0-types-15-debug-str
  "../tests/fixtures/dwarf/gcc-dwarf4-O0-types/15.debug_str.bin")

;: The sections of fixture `gcc-dwarf4-O0-types` as views of input `input`.
(define (dwarf-fixture-gcc-dwarf4-o0-types [input : i64]) : (__tl_dyn-array
    dwarf.LinkerDwarfView)
  (let
    [views : (__tl_dyn-array dwarf.LinkerDwarfView)
      (__tl_make-array dwarf.LinkerDwarfView 0)]
    (begin
      (dwarf-fixture-push!
        (&mut views)
        input
        6
        ".debug_types"
        true
        (& dwarf-fx-gcc-dwarf4-o0-types-06-debug-types))
      (dwarf-fixture-push!
        (&mut views)
        input
        8
        ".debug_info"
        true
        (& dwarf-fx-gcc-dwarf4-o0-types-08-debug-info))
      (dwarf-fixture-push!
        (&mut views)
        input
        10
        ".debug_abbrev"
        true
        (& dwarf-fx-gcc-dwarf4-o0-types-10-debug-abbrev))
      (dwarf-fixture-push!
        (&mut views)
        input
        11
        ".debug_aranges"
        true
        (& dwarf-fx-gcc-dwarf4-o0-types-11-debug-aranges))
      (dwarf-fixture-push!
        (&mut views)
        input
        13
        ".debug_line"
        true
        (& dwarf-fx-gcc-dwarf4-o0-types-13-debug-line))
      (dwarf-fixture-push!
        (&mut views)
        input
        15
        ".debug_str"
        true
        (& dwarf-fx-gcc-dwarf4-o0-types-15-debug-str))
      views)))

(include-bin
  dwarf-fx-gcc-dwarf4-o2-split-05-debug-addr
  "../tests/fixtures/dwarf/gcc-dwarf4-O2-split/05.debug_addr.bin")

(include-bin
  dwarf-fx-gcc-dwarf4-o2-split-07-debug-info
  "../tests/fixtures/dwarf/gcc-dwarf4-O2-split/07.debug_info.bin")

(include-bin
  dwarf-fx-gcc-dwarf4-o2-split-09-debug-abbrev
  "../tests/fixtures/dwarf/gcc-dwarf4-O2-split/09.debug_abbrev.bin")

(include-bin
  dwarf-fx-gcc-dwarf4-o2-split-10-debug-gnu-pubnames
  "../tests/fixtures/dwarf/gcc-dwarf4-O2-split/10.debug_gnu_pubnames.bin")

(include-bin
  dwarf-fx-gcc-dwarf4-o2-split-12-debug-gnu-pubtypes
  "../tests/fixtures/dwarf/gcc-dwarf4-O2-split/12.debug_gnu_pubtypes.bin")

(include-bin
  dwarf-fx-gcc-dwarf4-o2-split-14-debug-aranges
  "../tests/fixtures/dwarf/gcc-dwarf4-O2-split/14.debug_aranges.bin")

(include-bin
  dwarf-fx-gcc-dwarf4-o2-split-16-debug-ranges
  "../tests/fixtures/dwarf/gcc-dwarf4-O2-split/16.debug_ranges.bin")

(include-bin
  dwarf-fx-gcc-dwarf4-o2-split-18-debug-line
  "../tests/fixtures/dwarf/gcc-dwarf4-O2-split/18.debug_line.bin")

(include-bin
  dwarf-fx-gcc-dwarf4-o2-split-20-debug-str
  "../tests/fixtures/dwarf/gcc-dwarf4-O2-split/20.debug_str.bin")

;: The sections of fixture `gcc-dwarf4-O2-split` as views of input `input`.
(define (dwarf-fixture-gcc-dwarf4-o2-split [input : i64]) : (__tl_dyn-array
    dwarf.LinkerDwarfView)
  (let
    [views : (__tl_dyn-array dwarf.LinkerDwarfView)
      (__tl_make-array dwarf.LinkerDwarfView 0)]
    (begin
      (dwarf-fixture-push!
        (&mut views)
        input
        5
        ".debug_addr"
        true
        (& dwarf-fx-gcc-dwarf4-o2-split-05-debug-addr))
      (dwarf-fixture-push!
        (&mut views)
        input
        7
        ".debug_info"
        true
        (& dwarf-fx-gcc-dwarf4-o2-split-07-debug-info))
      (dwarf-fixture-push!
        (&mut views)
        input
        9
        ".debug_abbrev"
        true
        (& dwarf-fx-gcc-dwarf4-o2-split-09-debug-abbrev))
      (dwarf-fixture-push!
        (&mut views)
        input
        10
        ".debug_gnu_pubnames"
        true
        (& dwarf-fx-gcc-dwarf4-o2-split-10-debug-gnu-pubnames))
      (dwarf-fixture-push!
        (&mut views)
        input
        12
        ".debug_gnu_pubtypes"
        true
        (& dwarf-fx-gcc-dwarf4-o2-split-12-debug-gnu-pubtypes))
      (dwarf-fixture-push!
        (&mut views)
        input
        14
        ".debug_aranges"
        true
        (& dwarf-fx-gcc-dwarf4-o2-split-14-debug-aranges))
      (dwarf-fixture-push!
        (&mut views)
        input
        16
        ".debug_ranges"
        true
        (& dwarf-fx-gcc-dwarf4-o2-split-16-debug-ranges))
      (dwarf-fixture-push!
        (&mut views)
        input
        18
        ".debug_line"
        true
        (& dwarf-fx-gcc-dwarf4-o2-split-18-debug-line))
      (dwarf-fixture-push!
        (&mut views)
        input
        20
        ".debug_str"
        true
        (& dwarf-fx-gcc-dwarf4-o2-split-20-debug-str))
      views)))

(include-bin
  dwarf-fx-gcc-dwarf4-o2-split-dwo-01-debug-info-dwo
  "../tests/fixtures/dwarf/gcc-dwarf4-O2-split-dwo/01.debug_info.dwo.bin")

(include-bin
  dwarf-fx-gcc-dwarf4-o2-split-dwo-02-debug-abbrev-dwo
  "../tests/fixtures/dwarf/gcc-dwarf4-O2-split-dwo/02.debug_abbrev.dwo.bin")

(include-bin
  dwarf-fx-gcc-dwarf4-o2-split-dwo-03-debug-loc-dwo
  "../tests/fixtures/dwarf/gcc-dwarf4-O2-split-dwo/03.debug_loc.dwo.bin")

(include-bin
  dwarf-fx-gcc-dwarf4-o2-split-dwo-04-debug-line-dwo
  "../tests/fixtures/dwarf/gcc-dwarf4-O2-split-dwo/04.debug_line.dwo.bin")

(include-bin
  dwarf-fx-gcc-dwarf4-o2-split-dwo-05-debug-str-offsets-dwo
  "../tests/fixtures/dwarf/gcc-dwarf4-O2-split-dwo/05.debug_str_offsets.dwo.bin")

(include-bin
  dwarf-fx-gcc-dwarf4-o2-split-dwo-06-debug-str-dwo
  "../tests/fixtures/dwarf/gcc-dwarf4-O2-split-dwo/06.debug_str.dwo.bin")

;: The sections of fixture `gcc-dwarf4-O2-split-dwo` as views of input `input`.
(define (dwarf-fixture-gcc-dwarf4-o2-split-dwo [input : i64]) : (__tl_dyn-array
    dwarf.LinkerDwarfView)
  (let
    [views : (__tl_dyn-array dwarf.LinkerDwarfView)
      (__tl_make-array dwarf.LinkerDwarfView 0)]
    (begin
      (dwarf-fixture-push!
        (&mut views)
        input
        1
        ".debug_info.dwo"
        false
        (& dwarf-fx-gcc-dwarf4-o2-split-dwo-01-debug-info-dwo))
      (dwarf-fixture-push!
        (&mut views)
        input
        2
        ".debug_abbrev.dwo"
        false
        (& dwarf-fx-gcc-dwarf4-o2-split-dwo-02-debug-abbrev-dwo))
      (dwarf-fixture-push!
        (&mut views)
        input
        3
        ".debug_loc.dwo"
        false
        (& dwarf-fx-gcc-dwarf4-o2-split-dwo-03-debug-loc-dwo))
      (dwarf-fixture-push!
        (&mut views)
        input
        4
        ".debug_line.dwo"
        false
        (& dwarf-fx-gcc-dwarf4-o2-split-dwo-04-debug-line-dwo))
      (dwarf-fixture-push!
        (&mut views)
        input
        5
        ".debug_str_offsets.dwo"
        false
        (& dwarf-fx-gcc-dwarf4-o2-split-dwo-05-debug-str-offsets-dwo))
      (dwarf-fixture-push!
        (&mut views)
        input
        6
        ".debug_str.dwo"
        false
        (& dwarf-fx-gcc-dwarf4-o2-split-dwo-06-debug-str-dwo))
      views)))

(include-bin
  dwarf-fx-gcc-dwarf5-o0-05-debug-info
  "../tests/fixtures/dwarf/gcc-dwarf5-O0/05.debug_info.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o0-07-debug-abbrev
  "../tests/fixtures/dwarf/gcc-dwarf5-O0/07.debug_abbrev.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o0-08-debug-aranges
  "../tests/fixtures/dwarf/gcc-dwarf5-O0/08.debug_aranges.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o0-10-debug-line
  "../tests/fixtures/dwarf/gcc-dwarf5-O0/10.debug_line.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o0-12-debug-str
  "../tests/fixtures/dwarf/gcc-dwarf5-O0/12.debug_str.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o0-13-debug-line-str
  "../tests/fixtures/dwarf/gcc-dwarf5-O0/13.debug_line_str.bin")

;: The sections of fixture `gcc-dwarf5-O0` as views of input `input`.
(define (dwarf-fixture-gcc-dwarf5-o0 [input : i64]) : (__tl_dyn-array
    dwarf.LinkerDwarfView)
  (let
    [views : (__tl_dyn-array dwarf.LinkerDwarfView)
      (__tl_make-array dwarf.LinkerDwarfView 0)]
    (begin
      (dwarf-fixture-push!
        (&mut views)
        input
        5
        ".debug_info"
        true
        (& dwarf-fx-gcc-dwarf5-o0-05-debug-info))
      (dwarf-fixture-push!
        (&mut views)
        input
        7
        ".debug_abbrev"
        true
        (& dwarf-fx-gcc-dwarf5-o0-07-debug-abbrev))
      (dwarf-fixture-push!
        (&mut views)
        input
        8
        ".debug_aranges"
        true
        (& dwarf-fx-gcc-dwarf5-o0-08-debug-aranges))
      (dwarf-fixture-push!
        (&mut views)
        input
        10
        ".debug_line"
        true
        (& dwarf-fx-gcc-dwarf5-o0-10-debug-line))
      (dwarf-fixture-push!
        (&mut views)
        input
        12
        ".debug_str"
        true
        (& dwarf-fx-gcc-dwarf5-o0-12-debug-str))
      (dwarf-fixture-push!
        (&mut views)
        input
        13
        ".debug_line_str"
        true
        (& dwarf-fx-gcc-dwarf5-o0-13-debug-line-str))
      views)))

(include-bin
  dwarf-fx-gcc-dwarf5-o0-types-06-debug-info
  "../tests/fixtures/dwarf/gcc-dwarf5-O0-types/06.debug_info.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o0-types-08-debug-info
  "../tests/fixtures/dwarf/gcc-dwarf5-O0-types/08.debug_info.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o0-types-10-debug-abbrev
  "../tests/fixtures/dwarf/gcc-dwarf5-O0-types/10.debug_abbrev.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o0-types-11-debug-aranges
  "../tests/fixtures/dwarf/gcc-dwarf5-O0-types/11.debug_aranges.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o0-types-13-debug-line
  "../tests/fixtures/dwarf/gcc-dwarf5-O0-types/13.debug_line.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o0-types-15-debug-str
  "../tests/fixtures/dwarf/gcc-dwarf5-O0-types/15.debug_str.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o0-types-16-debug-line-str
  "../tests/fixtures/dwarf/gcc-dwarf5-O0-types/16.debug_line_str.bin")

;: The sections of fixture `gcc-dwarf5-O0-types` as views of input `input`.
(define (dwarf-fixture-gcc-dwarf5-o0-types [input : i64]) : (__tl_dyn-array
    dwarf.LinkerDwarfView)
  (let
    [views : (__tl_dyn-array dwarf.LinkerDwarfView)
      (__tl_make-array dwarf.LinkerDwarfView 0)]
    (begin
      (dwarf-fixture-push!
        (&mut views)
        input
        6
        ".debug_info"
        true
        (& dwarf-fx-gcc-dwarf5-o0-types-06-debug-info))
      (dwarf-fixture-push!
        (&mut views)
        input
        8
        ".debug_info"
        true
        (& dwarf-fx-gcc-dwarf5-o0-types-08-debug-info))
      (dwarf-fixture-push!
        (&mut views)
        input
        10
        ".debug_abbrev"
        true
        (& dwarf-fx-gcc-dwarf5-o0-types-10-debug-abbrev))
      (dwarf-fixture-push!
        (&mut views)
        input
        11
        ".debug_aranges"
        true
        (& dwarf-fx-gcc-dwarf5-o0-types-11-debug-aranges))
      (dwarf-fixture-push!
        (&mut views)
        input
        13
        ".debug_line"
        true
        (& dwarf-fx-gcc-dwarf5-o0-types-13-debug-line))
      (dwarf-fixture-push!
        (&mut views)
        input
        15
        ".debug_str"
        true
        (& dwarf-fx-gcc-dwarf5-o0-types-15-debug-str))
      (dwarf-fixture-push!
        (&mut views)
        input
        16
        ".debug_line_str"
        true
        (& dwarf-fx-gcc-dwarf5-o0-types-16-debug-line-str))
      views)))

(include-bin
  dwarf-fx-gcc-dwarf5-o2-05-debug-info
  "../tests/fixtures/dwarf/gcc-dwarf5-O2/05.debug_info.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o2-07-debug-abbrev
  "../tests/fixtures/dwarf/gcc-dwarf5-O2/07.debug_abbrev.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o2-08-debug-loclists
  "../tests/fixtures/dwarf/gcc-dwarf5-O2/08.debug_loclists.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o2-10-debug-aranges
  "../tests/fixtures/dwarf/gcc-dwarf5-O2/10.debug_aranges.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o2-12-debug-rnglists
  "../tests/fixtures/dwarf/gcc-dwarf5-O2/12.debug_rnglists.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o2-14-debug-line
  "../tests/fixtures/dwarf/gcc-dwarf5-O2/14.debug_line.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o2-16-debug-str
  "../tests/fixtures/dwarf/gcc-dwarf5-O2/16.debug_str.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o2-17-debug-line-str
  "../tests/fixtures/dwarf/gcc-dwarf5-O2/17.debug_line_str.bin")

;: The sections of fixture `gcc-dwarf5-O2` as views of input `input`.
(define (dwarf-fixture-gcc-dwarf5-o2 [input : i64]) : (__tl_dyn-array
    dwarf.LinkerDwarfView)
  (let
    [views : (__tl_dyn-array dwarf.LinkerDwarfView)
      (__tl_make-array dwarf.LinkerDwarfView 0)]
    (begin
      (dwarf-fixture-push!
        (&mut views)
        input
        5
        ".debug_info"
        true
        (& dwarf-fx-gcc-dwarf5-o2-05-debug-info))
      (dwarf-fixture-push!
        (&mut views)
        input
        7
        ".debug_abbrev"
        true
        (& dwarf-fx-gcc-dwarf5-o2-07-debug-abbrev))
      (dwarf-fixture-push!
        (&mut views)
        input
        8
        ".debug_loclists"
        true
        (& dwarf-fx-gcc-dwarf5-o2-08-debug-loclists))
      (dwarf-fixture-push!
        (&mut views)
        input
        10
        ".debug_aranges"
        true
        (& dwarf-fx-gcc-dwarf5-o2-10-debug-aranges))
      (dwarf-fixture-push!
        (&mut views)
        input
        12
        ".debug_rnglists"
        true
        (& dwarf-fx-gcc-dwarf5-o2-12-debug-rnglists))
      (dwarf-fixture-push!
        (&mut views)
        input
        14
        ".debug_line"
        true
        (& dwarf-fx-gcc-dwarf5-o2-14-debug-line))
      (dwarf-fixture-push!
        (&mut views)
        input
        16
        ".debug_str"
        true
        (& dwarf-fx-gcc-dwarf5-o2-16-debug-str))
      (dwarf-fixture-push!
        (&mut views)
        input
        17
        ".debug_line_str"
        true
        (& dwarf-fx-gcc-dwarf5-o2-17-debug-line-str))
      views)))

(include-bin
  dwarf-fx-gcc-dwarf5-o2-function-sections-06-debug-info
  "../tests/fixtures/dwarf/gcc-dwarf5-O2-function-sections/06.debug_info.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o2-function-sections-08-debug-abbrev
  "../tests/fixtures/dwarf/gcc-dwarf5-O2-function-sections/08.debug_abbrev.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o2-function-sections-09-debug-loclists
  "../tests/fixtures/dwarf/gcc-dwarf5-O2-function-sections/09.debug_loclists.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o2-function-sections-11-debug-aranges
  "../tests/fixtures/dwarf/gcc-dwarf5-O2-function-sections/11.debug_aranges.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o2-function-sections-13-debug-rnglists
  "../tests/fixtures/dwarf/gcc-dwarf5-O2-function-sections/13.debug_rnglists.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o2-function-sections-15-debug-line
  "../tests/fixtures/dwarf/gcc-dwarf5-O2-function-sections/15.debug_line.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o2-function-sections-17-debug-str
  "../tests/fixtures/dwarf/gcc-dwarf5-O2-function-sections/17.debug_str.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o2-function-sections-18-debug-line-str
  "../tests/fixtures/dwarf/gcc-dwarf5-O2-function-sections/18.debug_line_str.bin")

;: The sections of fixture `gcc-dwarf5-O2-function-sections` as views of input `input`.
(define (dwarf-fixture-gcc-dwarf5-o2-function-sections [input : i64]) : (__tl_dyn-array
    dwarf.LinkerDwarfView)
  (let
    [views : (__tl_dyn-array dwarf.LinkerDwarfView)
      (__tl_make-array dwarf.LinkerDwarfView 0)]
    (begin
      (dwarf-fixture-push!
        (&mut views)
        input
        6
        ".debug_info"
        true
        (& dwarf-fx-gcc-dwarf5-o2-function-sections-06-debug-info))
      (dwarf-fixture-push!
        (&mut views)
        input
        8
        ".debug_abbrev"
        true
        (& dwarf-fx-gcc-dwarf5-o2-function-sections-08-debug-abbrev))
      (dwarf-fixture-push!
        (&mut views)
        input
        9
        ".debug_loclists"
        true
        (& dwarf-fx-gcc-dwarf5-o2-function-sections-09-debug-loclists))
      (dwarf-fixture-push!
        (&mut views)
        input
        11
        ".debug_aranges"
        true
        (& dwarf-fx-gcc-dwarf5-o2-function-sections-11-debug-aranges))
      (dwarf-fixture-push!
        (&mut views)
        input
        13
        ".debug_rnglists"
        true
        (& dwarf-fx-gcc-dwarf5-o2-function-sections-13-debug-rnglists))
      (dwarf-fixture-push!
        (&mut views)
        input
        15
        ".debug_line"
        true
        (& dwarf-fx-gcc-dwarf5-o2-function-sections-15-debug-line))
      (dwarf-fixture-push!
        (&mut views)
        input
        17
        ".debug_str"
        true
        (& dwarf-fx-gcc-dwarf5-o2-function-sections-17-debug-str))
      (dwarf-fixture-push!
        (&mut views)
        input
        18
        ".debug_line_str"
        true
        (& dwarf-fx-gcc-dwarf5-o2-function-sections-18-debug-line-str))
      views)))

(include-bin
  dwarf-fx-gcc-dwarf5-o2-split-05-debug-addr
  "../tests/fixtures/dwarf/gcc-dwarf5-O2-split/05.debug_addr.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o2-split-07-debug-info
  "../tests/fixtures/dwarf/gcc-dwarf5-O2-split/07.debug_info.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o2-split-09-debug-abbrev
  "../tests/fixtures/dwarf/gcc-dwarf5-O2-split/09.debug_abbrev.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o2-split-10-debug-gnu-pubnames
  "../tests/fixtures/dwarf/gcc-dwarf5-O2-split/10.debug_gnu_pubnames.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o2-split-12-debug-gnu-pubtypes
  "../tests/fixtures/dwarf/gcc-dwarf5-O2-split/12.debug_gnu_pubtypes.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o2-split-14-debug-aranges
  "../tests/fixtures/dwarf/gcc-dwarf5-O2-split/14.debug_aranges.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o2-split-16-debug-rnglists
  "../tests/fixtures/dwarf/gcc-dwarf5-O2-split/16.debug_rnglists.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o2-split-17-debug-line
  "../tests/fixtures/dwarf/gcc-dwarf5-O2-split/17.debug_line.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o2-split-19-debug-str
  "../tests/fixtures/dwarf/gcc-dwarf5-O2-split/19.debug_str.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o2-split-23-debug-line-str
  "../tests/fixtures/dwarf/gcc-dwarf5-O2-split/23.debug_line_str.bin")

;: The sections of fixture `gcc-dwarf5-O2-split` as views of input `input`.
(define (dwarf-fixture-gcc-dwarf5-o2-split [input : i64]) : (__tl_dyn-array
    dwarf.LinkerDwarfView)
  (let
    [views : (__tl_dyn-array dwarf.LinkerDwarfView)
      (__tl_make-array dwarf.LinkerDwarfView 0)]
    (begin
      (dwarf-fixture-push!
        (&mut views)
        input
        5
        ".debug_addr"
        true
        (& dwarf-fx-gcc-dwarf5-o2-split-05-debug-addr))
      (dwarf-fixture-push!
        (&mut views)
        input
        7
        ".debug_info"
        true
        (& dwarf-fx-gcc-dwarf5-o2-split-07-debug-info))
      (dwarf-fixture-push!
        (&mut views)
        input
        9
        ".debug_abbrev"
        true
        (& dwarf-fx-gcc-dwarf5-o2-split-09-debug-abbrev))
      (dwarf-fixture-push!
        (&mut views)
        input
        10
        ".debug_gnu_pubnames"
        true
        (& dwarf-fx-gcc-dwarf5-o2-split-10-debug-gnu-pubnames))
      (dwarf-fixture-push!
        (&mut views)
        input
        12
        ".debug_gnu_pubtypes"
        true
        (& dwarf-fx-gcc-dwarf5-o2-split-12-debug-gnu-pubtypes))
      (dwarf-fixture-push!
        (&mut views)
        input
        14
        ".debug_aranges"
        true
        (& dwarf-fx-gcc-dwarf5-o2-split-14-debug-aranges))
      (dwarf-fixture-push!
        (&mut views)
        input
        16
        ".debug_rnglists"
        true
        (& dwarf-fx-gcc-dwarf5-o2-split-16-debug-rnglists))
      (dwarf-fixture-push!
        (&mut views)
        input
        17
        ".debug_line"
        true
        (& dwarf-fx-gcc-dwarf5-o2-split-17-debug-line))
      (dwarf-fixture-push!
        (&mut views)
        input
        19
        ".debug_str"
        true
        (& dwarf-fx-gcc-dwarf5-o2-split-19-debug-str))
      (dwarf-fixture-push!
        (&mut views)
        input
        23
        ".debug_line_str"
        true
        (& dwarf-fx-gcc-dwarf5-o2-split-23-debug-line-str))
      views)))

(include-bin
  dwarf-fx-gcc-dwarf5-o2-split-dwo-01-debug-info-dwo
  "../tests/fixtures/dwarf/gcc-dwarf5-O2-split-dwo/01.debug_info.dwo.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o2-split-dwo-02-debug-abbrev-dwo
  "../tests/fixtures/dwarf/gcc-dwarf5-O2-split-dwo/02.debug_abbrev.dwo.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o2-split-dwo-03-debug-loclists-dwo
  "../tests/fixtures/dwarf/gcc-dwarf5-O2-split-dwo/03.debug_loclists.dwo.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o2-split-dwo-04-debug-rnglists-dwo
  "../tests/fixtures/dwarf/gcc-dwarf5-O2-split-dwo/04.debug_rnglists.dwo.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o2-split-dwo-05-debug-line-dwo
  "../tests/fixtures/dwarf/gcc-dwarf5-O2-split-dwo/05.debug_line.dwo.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o2-split-dwo-06-debug-str-offsets-dwo
  "../tests/fixtures/dwarf/gcc-dwarf5-O2-split-dwo/06.debug_str_offsets.dwo.bin")

(include-bin
  dwarf-fx-gcc-dwarf5-o2-split-dwo-07-debug-str-dwo
  "../tests/fixtures/dwarf/gcc-dwarf5-O2-split-dwo/07.debug_str.dwo.bin")

;: The sections of fixture `gcc-dwarf5-O2-split-dwo` as views of input `input`.
(define (dwarf-fixture-gcc-dwarf5-o2-split-dwo [input : i64]) : (__tl_dyn-array
    dwarf.LinkerDwarfView)
  (let
    [views : (__tl_dyn-array dwarf.LinkerDwarfView)
      (__tl_make-array dwarf.LinkerDwarfView 0)]
    (begin
      (dwarf-fixture-push!
        (&mut views)
        input
        1
        ".debug_info.dwo"
        false
        (& dwarf-fx-gcc-dwarf5-o2-split-dwo-01-debug-info-dwo))
      (dwarf-fixture-push!
        (&mut views)
        input
        2
        ".debug_abbrev.dwo"
        false
        (& dwarf-fx-gcc-dwarf5-o2-split-dwo-02-debug-abbrev-dwo))
      (dwarf-fixture-push!
        (&mut views)
        input
        3
        ".debug_loclists.dwo"
        false
        (& dwarf-fx-gcc-dwarf5-o2-split-dwo-03-debug-loclists-dwo))
      (dwarf-fixture-push!
        (&mut views)
        input
        4
        ".debug_rnglists.dwo"
        false
        (& dwarf-fx-gcc-dwarf5-o2-split-dwo-04-debug-rnglists-dwo))
      (dwarf-fixture-push!
        (&mut views)
        input
        5
        ".debug_line.dwo"
        false
        (& dwarf-fx-gcc-dwarf5-o2-split-dwo-05-debug-line-dwo))
      (dwarf-fixture-push!
        (&mut views)
        input
        6
        ".debug_str_offsets.dwo"
        false
        (& dwarf-fx-gcc-dwarf5-o2-split-dwo-06-debug-str-offsets-dwo))
      (dwarf-fixture-push!
        (&mut views)
        input
        7
        ".debug_str.dwo"
        false
        (& dwarf-fx-gcc-dwarf5-o2-split-dwo-07-debug-str-dwo))
      views)))

(include-bin
  dwarf-fx-typelisp-debug-14-debug-line
  "../tests/fixtures/dwarf/typelisp-debug/14.debug_line.bin")

(include-bin
  dwarf-fx-typelisp-debug-16-debug-info
  "../tests/fixtures/dwarf/typelisp-debug/16.debug_info.bin")

(include-bin
  dwarf-fx-typelisp-debug-18-debug-abbrev
  "../tests/fixtures/dwarf/typelisp-debug/18.debug_abbrev.bin")

(include-bin
  dwarf-fx-typelisp-debug-19-debug-aranges
  "../tests/fixtures/dwarf/typelisp-debug/19.debug_aranges.bin")

(include-bin
  dwarf-fx-typelisp-debug-21-debug-str
  "../tests/fixtures/dwarf/typelisp-debug/21.debug_str.bin")

;: The sections of fixture `typelisp-debug` as views of input `input`.
(define (dwarf-fixture-typelisp-debug [input : i64]) : (__tl_dyn-array
    dwarf.LinkerDwarfView)
  (let
    [views : (__tl_dyn-array dwarf.LinkerDwarfView)
      (__tl_make-array dwarf.LinkerDwarfView 0)]
    (begin
      (dwarf-fixture-push!
        (&mut views)
        input
        14
        ".debug_line"
        true
        (& dwarf-fx-typelisp-debug-14-debug-line))
      (dwarf-fixture-push!
        (&mut views)
        input
        16
        ".debug_info"
        true
        (& dwarf-fx-typelisp-debug-16-debug-info))
      (dwarf-fixture-push!
        (&mut views)
        input
        18
        ".debug_abbrev"
        true
        (& dwarf-fx-typelisp-debug-18-debug-abbrev))
      (dwarf-fixture-push!
        (&mut views)
        input
        19
        ".debug_aranges"
        true
        (& dwarf-fx-typelisp-debug-19-debug-aranges))
      (dwarf-fixture-push!
        (&mut views)
        input
        21
        ".debug_str"
        true
        (& dwarf-fx-typelisp-debug-21-debug-str))
      views)))

;: `first` followed by every view of `second`.
(define (dwarf-join
  [first : (__tl_dyn-array dwarf.LinkerDwarfView)]
  [second : (__tl_dyn-array dwarf.LinkerDwarfView)]) : (__tl_dyn-array
    dwarf.LinkerDwarfView)
  (let
    [views : (__tl_dyn-array dwarf.LinkerDwarfView) first]
    [index : i64 0]
    (begin
      (while (< index (array-length second))
        (begin
          (__tl_array-push! views (array-ref second index))
          (set! index (+ index 1))))
      views)))

;: The views in reverse order.
(define (dwarf-reversed
  [views : (& views (__tl_dyn-array dwarf.LinkerDwarfView))]) : (__tl_dyn-array
    dwarf.LinkerDwarfView)
  (let
    [out : (__tl_dyn-array dwarf.LinkerDwarfView)
      (__tl_make-array dwarf.LinkerDwarfView 0)]
    [index : i64 (- (array-length views) 1)]
    (begin
      (while (>= index 0)
        (begin
          (__tl_array-push! out (array-ref views index))
          (set! index (- index 1))))
      out)))

;: Scan with the default limits; a failure fails the test.
(define (dwarf-scan-ok
  [views : (__tl_dyn-array dwarf.LinkerDwarfView)]
  [message : String]) : dwarf.LinkerDwarfInventory
  (match (dwarf.linker-dwarf-scan views (dwarf.linker-dwarf-default-limits))
    [(Ok inventory) inventory]
    [(Err error)
      (begin
        (test.assert-i64-eq error.code 0 message)
        (dwarf.LinkerDwarfInventory
          (__tl_make-array dwarf.LinkerDwarfUnit 0)
          (__tl_make-array dwarf.LinkerDwarfAbbrevTable 0)
          (__tl_make-array dwarf.LinkerDwarfReference 0)
          (__tl_make-array dwarf.LinkerDwarfLedgerEntry 0)
          0
          0
          0))]))

;: The number of references of `class`.
(define (dwarf-class-count
  [inventory : (& inventory dwarf.LinkerDwarfInventory)]
  [class : i64]) : i64
  (let
    [count : i64 0]
    [index : i64 0]
    (begin
      (while (< index (array-length inventory.references))
        (begin
          (if (= (array-ref inventory.references index).class class)
            (set! count (+ count 1))
            unit)
          (set! index (+ index 1))))
      count)))

;: `text` followed by ` key=value`.
(define (dwarf-summary-field [text : String] [key : (& key str)] [value : i64]) : String
  (str_cat.str-cat text " " (string.copy key) "=" (string.int->string value)))

;: The counts llvm-dwarfdump also reports: units, DIEs, attributes and the
;: references of each class. A unit header's abbreviation offset counts as
;: one section offset.
(define (dwarf-summary [inventory : (& inventory dwarf.LinkerDwarfInventory)]) : String
  (let
    [text : String
      (str_cat.str-cat
        "units="
        (string.int->string (array-length inventory.units)))]
    [text : String (dwarf-summary-field text "dies" inventory.dies)]
    [text : String (dwarf-summary-field text "attrs" inventory.attributes)]
    [text : String
      (dwarf-summary-field
        text
        "unit"
        (dwarf-class-count inventory dwarf.linker-dwarf-ref-unit))]
    [text : String
      (dwarf-summary-field
        text
        "info"
        (dwarf-class-count inventory dwarf.linker-dwarf-ref-info))]
    [text : String
      (dwarf-summary-field
        text
        "sig"
        (dwarf-class-count inventory dwarf.linker-dwarf-ref-signature))]
    [text : String
      (dwarf-summary-field
        text
        "str"
        (dwarf-class-count inventory dwarf.linker-dwarf-ref-string))]
    [text : String
      (dwarf-summary-field
        text
        "lstr"
        (dwarf-class-count inventory dwarf.linker-dwarf-ref-line-string))]
    [text : String
      (dwarf-summary-field
        text
        "strx"
        (dwarf-class-count inventory dwarf.linker-dwarf-ref-string-index))]
    [text : String
      (dwarf-summary-field
        text
        "addr"
        (dwarf-class-count inventory dwarf.linker-dwarf-ref-address))]
    [text : String
      (dwarf-summary-field
        text
        "addrx"
        (dwarf-class-count inventory dwarf.linker-dwarf-ref-address-index))]
    [text : String
      (dwarf-summary-field
        text
        "secoff"
        (dwarf-class-count inventory dwarf.linker-dwarf-ref-section-offset))]
    [text : String
      (dwarf-summary-field
        text
        "rngx"
        (dwarf-class-count inventory dwarf.linker-dwarf-ref-rnglist-index))]
    (dwarf-summary-field
      text
      "locx"
      (dwarf-class-count inventory dwarf.linker-dwarf-ref-loclist-index))))

(define (dwarf-expect-summary
  [views : (__tl_dyn-array dwarf.LinkerDwarfView)]
  [expected : (& expected str)]
  [message : String]) : unit
  (let
    [inventory : dwarf.LinkerDwarfInventory
      (dwarf-scan-ok views (string.copy (& message)))]
    [actual : String (dwarf-summary (& inventory))]
    (test.assert-true (string.eq (& actual) expected) message)))

;: Whether two inventories are identical, field by field.
(define (dwarf-inventory-equal?
  [a : (& a dwarf.LinkerDwarfInventory)]
  [b : (& b dwarf.LinkerDwarfInventory)]) : bool
  (let
    [same : bool
      (and
        (= (array-length a.units) (array-length b.units))
        (= (array-length a.references) (array-length b.references))
        (= (array-length a.ledger) (array-length b.ledger))
        (= (array-length a.abbrev-tables) (array-length b.abbrev-tables))
        (= a.dies b.dies)
        (= a.attributes b.attributes))]
    [index : i64 0]
    (begin
      (while (and same (< index (array-length a.units)))
        (let
          [x : dwarf.LinkerDwarfUnit (array-ref a.units index)]
          [y : dwarf.LinkerDwarfUnit (array-ref b.units index)]
          (begin
            (set!
              same
              (and
                (= x.input y.input)
                (= x.section y.section)
                (= x.offset y.offset)
                (= x.end y.end)
                (= x.unit-type y.unit-type)
                (= x.die-count y.die-count)
                (= x.first-die y.first-die)
                (= x.signature y.signature)
                (= x.dwo-id y.dwo-id)
                (= x.skeleton y.skeleton)))
            (set! index (+ index 1)))))
      (set! index 0)
      (while (and same (< index (array-length a.references)))
        (let
          [x : dwarf.LinkerDwarfReference (array-ref a.references index)]
          [y : dwarf.LinkerDwarfReference (array-ref b.references index)]
          (begin
            (set!
              same
              (and
                (= x.unit y.unit)
                (= x.offset y.offset)
                (= x.width y.width)
                (= x.attribute y.attribute)
                (= x.form y.form)
                (= x.op y.op)
                (= x.class y.class)
                (= x.target-kind y.target-kind)
                (= x.value y.value)
                (= x.target y.target)))
            (set! index (+ index 1)))))
      (set! index 0)
      (while (and same (< index (array-length a.ledger)))
        (begin
          (set!
            same
            (and
              (=
                (array-ref a.ledger index).input
                (array-ref b.ledger index).input)
              (=
                (array-ref a.ledger index).section
                (array-ref b.ledger index).section)
              (=
                (array-ref a.ledger index).kind
                (array-ref b.ledger index).kind)
              (=
                (array-ref a.ledger index).reason
                (array-ref b.ledger index).reason)))
          (set! index (+ index 1))))
      same)))

(test
  dwarf-fixtures-match-the-oracle
  (begin
    (dwarf-expect-summary
      (dwarf-fixture-clang-dwarf4-o0 1)
      "units=1 dies=18 attrs=87 unit=13 info=0 sig=0 str=17 lstr=0 strx=0 addr=6 addrx=0 secoff=2 rngx=0 locx=0"
      "clang-dwarf4-o0")
    (dwarf-expect-summary
      (dwarf-fixture-clang-dwarf4-o2-split 1)
      "units=1 dies=1 attrs=8 unit=0 info=0 sig=0 str=2 lstr=0 strx=0 addr=1 addrx=0 secoff=3 rngx=0 locx=0"
      "clang-dwarf4-o2-split")
    (dwarf-expect-summary
      (dwarf-fixture-clang-dwarf4-o2-split-dwo 1)
      "units=1 dies=16 attrs=72 unit=11 info=0 sig=0 str=0 lstr=0 strx=15 addr=0 addrx=3 secoff=2 rngx=0 locx=0"
      "clang-dwarf4-o2-split-dwo")
    (dwarf-expect-summary
      (dwarf-fixture-clang-dwarf5-o0 1)
      "units=1 dies=18 attrs=89 unit=13 info=0 sig=0 str=0 lstr=0 strx=17 addr=0 addrx=6 secoff=4 rngx=0 locx=0"
      "clang-dwarf5-o0")
    (dwarf-expect-summary
      (dwarf-fixture-clang-dwarf5-o2 1)
      "units=1 dies=16 attrs=77 unit=11 info=0 sig=0 str=0 lstr=0 strx=15 addr=0 addrx=4 secoff=5 rngx=0 locx=1"
      "clang-dwarf5-o2")
    (dwarf-expect-summary
      (dwarf-fixture-clang-dwarf5-o2-function-sections 1)
      "units=1 dies=16 attrs=78 unit=11 info=0 sig=0 str=0 lstr=0 strx=15 addr=1 addrx=3 secoff=6 rngx=1 locx=1"
      "clang-dwarf5-o2-function-sections")
    (dwarf-expect-summary
      (dwarf-fixture-clang-dwarf5-o2-split 1)
      "units=1 dies=1 attrs=8 unit=0 info=0 sig=0 str=0 lstr=0 strx=2 addr=0 addrx=1 secoff=4 rngx=0 locx=0"
      "clang-dwarf5-o2-split")
    (dwarf-expect-summary
      (dwarf-fixture-clang-dwarf5-o2-split-dwo 1)
      "units=1 dies=16 attrs=69 unit=11 info=0 sig=0 str=0 lstr=0 strx=15 addr=0 addrx=1 secoff=1 rngx=2 locx=1"
      "clang-dwarf5-o2-split-dwo")
    (dwarf-expect-summary
      (dwarf-fixture-gcc-dwarf4-o0 1)
      "units=1 dies=18 attrs=106 unit=16 info=0 sig=0 str=16 lstr=0 strx=0 addr=6 addrx=0 secoff=2 rngx=0 locx=0"
      "gcc-dwarf4-o0")
    (dwarf-expect-summary
      (dwarf-fixture-gcc-dwarf4-o0-types 1)
      "units=2 dies=21 attrs=112 unit=16 info=0 sig=1 str=17 lstr=0 strx=0 addr=6 addrx=0 secoff=4 rngx=0 locx=0"
      "gcc-dwarf4-o0-types")
    (dwarf-expect-summary
      (dwarf-fixture-gcc-dwarf4-o2-split 1)
      "units=1 dies=1 attrs=9 unit=0 info=0 sig=0 str=2 lstr=0 strx=0 addr=1 addrx=0 secoff=5 rngx=0 locx=0"
      "gcc-dwarf4-o2-split")
    (dwarf-expect-summary
      (dwarf-fixture-gcc-dwarf4-o2-split-dwo 1)
      "units=1 dies=23 attrs=108 unit=22 info=0 sig=0 str=0 lstr=0 strx=16 addr=0 addrx=2 secoff=8 rngx=0 locx=0"
      "gcc-dwarf4-o2-split-dwo")
    (dwarf-expect-summary
      (dwarf-fixture-gcc-dwarf5-o0 1)
      "units=1 dies=18 attrs=108 unit=16 info=0 sig=0 str=14 lstr=2 strx=0 addr=6 addrx=0 secoff=2 rngx=0 locx=0"
      "gcc-dwarf5-o0")
    (dwarf-expect-summary
      (dwarf-fixture-gcc-dwarf5-o0-types 1)
      "units=2 dies=21 attrs=116 unit=16 info=0 sig=1 str=15 lstr=2 strx=0 addr=6 addrx=0 secoff=4 rngx=0 locx=0"
      "gcc-dwarf5-o0-types")
    (dwarf-expect-summary
      (dwarf-fixture-gcc-dwarf5-o2 1)
      "units=1 dies=23 attrs=112 unit=22 info=0 sig=0 str=14 lstr=2 strx=0 addr=3 addrx=0 secoff=10 rngx=0 locx=0"
      "gcc-dwarf5-o2")
    (dwarf-expect-summary
      (dwarf-fixture-gcc-dwarf5-o2-function-sections 1)
      "units=1 dies=23 attrs=112 unit=22 info=0 sig=0 str=14 lstr=2 strx=0 addr=3 addrx=0 secoff=10 rngx=0 locx=0"
      "gcc-dwarf5-o2-function-sections")
    (dwarf-expect-summary
      (dwarf-fixture-gcc-dwarf5-o2-split 1)
      "units=1 dies=1 attrs=7 unit=0 info=0 sig=0 str=2 lstr=0 strx=0 addr=1 addrx=0 secoff=4 rngx=0 locx=0"
      "gcc-dwarf5-o2-split")
    (dwarf-expect-summary
      (dwarf-fixture-gcc-dwarf5-o2-split-dwo 1)
      "units=1 dies=23 attrs=109 unit=22 info=0 sig=0 str=0 lstr=0 strx=16 addr=0 addrx=2 secoff=4 rngx=1 locx=3"
      "gcc-dwarf5-o2-split-dwo")
    (dwarf-expect-summary
      (dwarf-fixture-typelisp-debug 1)
      "units=1 dies=58 attrs=287 unit=56 info=0 sig=0 str=59 lstr=0 strx=0 addr=114 addrx=0 secoff=2 rngx=0 locx=0"
      "typelisp-debug")
    unit))

;: The skeleton index of the split unit `split` after scanning `views`.
(define (dwarf-skeleton-of
  [views : (__tl_dyn-array dwarf.LinkerDwarfView)]
  [split : i64]
  [message : String]) : i64
  (let
    [inventory : dwarf.LinkerDwarfInventory (dwarf-scan-ok views message)]
    (if (> (array-length inventory.units) split)
      (array-ref inventory.units split).skeleton
      -2)))

(test
  dwarf-split-units-pair-with-their-skeletons
  (begin
    (test.assert-i64-eq
      (dwarf-skeleton-of
        (dwarf-join
          (dwarf-fixture-gcc-dwarf5-o2-split 1)
          (dwarf-fixture-gcc-dwarf5-o2-split-dwo 2))
        1
        "gcc DWARF 5 split pair")
      0
      "gcc DWARF 5 split unit pairs with its skeleton")
    (test.assert-i64-eq
      (dwarf-skeleton-of
        (dwarf-join
          (dwarf-fixture-gcc-dwarf4-o2-split 1)
          (dwarf-fixture-gcc-dwarf4-o2-split-dwo 2))
        1
        "gcc DWARF 4 split pair")
      0
      "gcc DWARF 4 GNU split unit pairs through DW_AT_GNU_dwo_id")
    (test.assert-i64-eq
      (dwarf-skeleton-of
        (dwarf-join
          (dwarf-fixture-clang-dwarf5-o2-split 1)
          (dwarf-fixture-clang-dwarf5-o2-split-dwo 2))
        1
        "clang DWARF 5 split pair")
      0
      "clang DWARF 5 split unit pairs with its skeleton")
    (test.assert-i64-eq
      (dwarf-skeleton-of
        (dwarf-join
          (dwarf-fixture-clang-dwarf4-o2-split 1)
          (dwarf-fixture-clang-dwarf4-o2-split-dwo 2))
        1
        "clang DWARF 4 split pair")
      0
      "clang DWARF 4 GNU split unit pairs with its skeleton")
    (test.assert-i64-eq
      (dwarf-skeleton-of
        (dwarf-fixture-gcc-dwarf5-o2-split-dwo 2)
        0
        "lone split unit")
      -1
      "a split unit without its skeleton stays unpaired")))

(test
  dwarf-type-signatures-resolve-to-type-units
  (let
    [v4 : dwarf.LinkerDwarfInventory
      (dwarf-scan-ok (dwarf-fixture-gcc-dwarf4-o0-types 1) "v4 types")]
    [v5 : dwarf.LinkerDwarfInventory
      (dwarf-scan-ok (dwarf-fixture-gcc-dwarf5-o0-types 1) "v5 types")]
    [index : i64 0]
    [v4-target : i64 -9]
    [v5-target : i64 -9]
    (begin
      (while (< index (array-length v4.references))
        (begin
          (if (=
            (array-ref v4.references index).class
            dwarf.linker-dwarf-ref-signature)
            (set! v4-target (array-ref v4.references index).target)
            unit)
          (set! index (+ index 1))))
      (set! index 0)
      (while (< index (array-length v5.references))
        (begin
          (if (=
            (array-ref v5.references index).class
            dwarf.linker-dwarf-ref-signature)
            (set! v5-target (array-ref v5.references index).target)
            unit)
          (set! index (+ index 1))))
      (test.assert-i64-eq
        (array-ref v4.units 0).unit-type
        2
        "v4 .debug_types unit")
      (test.assert-i64-eq v4-target 0 "DW_FORM_ref_sig8 names the v4 type unit")
      (test.assert-i64-eq
        (array-ref v5.units 0).unit-type
        2
        "v5 DW_UT_type unit")
      (test.assert-i64-eq v5-target 0 "DW_FORM_ref_sig8 names the v5 type unit"))))

(test
  dwarf-typelisp-dwarf3-pointer-attributes-are-section-offsets
  (let
    [inventory : dwarf.LinkerDwarfInventory
      (dwarf-scan-ok (dwarf-fixture-typelisp-debug 1) "typelisp")]
    [stmt : dwarf.LinkerDwarfReference (array-ref inventory.references 1)]
    (begin
      (test.assert-i64-eq
        (array-ref inventory.units 0).version
        3
        "GNU as writes DWARF 3")
      (test.assert-i64-eq
        stmt.offset
        12
        "DW_AT_stmt_list follows the root's abbreviation code")
      (test.assert-i64-eq stmt.attribute 0x10 "DW_AT_stmt_list")
      (test.assert-i64-eq stmt.form 0x06 "DW_FORM_data4")
      (test.assert-i64-eq
        stmt.class
        dwarf.linker-dwarf-ref-section-offset
        "is a section offset")
      (test.assert-i64-eq
        stmt.target-kind
        dwarf.linker-dwarf-section-line
        "into .debug_line"))))

(test
  dwarf-records-exact-field-locations
  (let
    ;; GCC DWARF 5: the root DIE starts at 0x0c; its producer (strp), name
    ;; and comp_dir (line_strp), low_pc (addr) follow, with language fields
    ;; between.
    [inventory : dwarf.LinkerDwarfInventory
      (dwarf-scan-ok (dwarf-fixture-gcc-dwarf5-o0 1) "gcc v5")]
    (begin
      (test.assert-i64-eq
        (array-ref inventory.references 0).offset
        8
        "header abbreviation offset")
      (test.assert-i64-eq
        (array-ref inventory.references 0).attribute
        -1
        "a header field")
      (test.assert-i64-eq
        (array-ref inventory.references 0).target-kind
        dwarf.linker-dwarf-section-abbrev
        "into .debug_abbrev")
      (test.assert-i64-eq
        (array-ref inventory.references 1).offset
        13
        "producer")
      (test.assert-i64-eq
        (array-ref inventory.references 1).width
        4
        "strp width")
      (test.assert-i64-eq
        (array-ref inventory.references 1).class
        dwarf.linker-dwarf-ref-string
        "strp")
      (test.assert-i64-eq (array-ref inventory.references 2).offset 23 "name")
      (test.assert-i64-eq
        (array-ref inventory.references 2).class
        dwarf.linker-dwarf-ref-line-string
        "line_strp")
      (test.assert-i64-eq
        (array-ref inventory.references 3).offset
        27
        "comp_dir")
      (test.assert-i64-eq (array-ref inventory.references 4).offset 31 "low_pc")
      (test.assert-i64-eq
        (array-ref inventory.references 4).width
        8
        "address width")
      (test.assert-i64-eq
        (array-ref inventory.references 4).class
        dwarf.linker-dwarf-ref-address
        "addr")
      (test.assert-i64-eq
        (array-ref inventory.references 5).offset
        47
        "stmt_list")
      (test.assert-i64-eq
        (array-ref inventory.references 5).target-kind
        dwarf.linker-dwarf-section-line
        "stmt_list into .debug_line"))))

(test
  dwarf-output-is-canonical-under-reordered-views
  (let
    [views : (__tl_dyn-array dwarf.LinkerDwarfView)
      (dwarf-join
        (dwarf-fixture-gcc-dwarf5-o2-split 1)
        (dwarf-fixture-gcc-dwarf5-o2-split-dwo 2))]
    [again : (__tl_dyn-array dwarf.LinkerDwarfView)
      (dwarf-join
        (dwarf-fixture-gcc-dwarf5-o2-split 1)
        (dwarf-fixture-gcc-dwarf5-o2-split-dwo 2))]
    [forward : dwarf.LinkerDwarfInventory (dwarf-scan-ok views "forward")]
    [backward : dwarf.LinkerDwarfInventory
      (dwarf-scan-ok (dwarf-reversed (& again)) "backward")]
    [repeat : dwarf.LinkerDwarfInventory
      (dwarf-scan-ok
        (dwarf-join
          (dwarf-fixture-gcc-dwarf5-o2-split 1)
          (dwarf-fixture-gcc-dwarf5-o2-split-dwo 2))
        "repeat")]
    (begin
      (test.assert-true
        (dwarf-inventory-equal? (& forward) (& backward))
        "reversed views")
      (test.assert-true
        (dwarf-inventory-equal? (& forward) (& repeat))
        "repeated scan"))))

(test
  dwarf-ledger-lists-the-sections-it-does-not-inventory
  (let
    [inventory : dwarf.LinkerDwarfInventory
      (dwarf-scan-ok (dwarf-fixture-gcc-dwarf5-o2 1) "gcc v5 O2")]
    (begin
      ;; .debug_loclists, aranges, rnglists, line, str, line_str; not the
      ;; walked .debug_info or its .debug_abbrev.
      (test.assert-i64-eq
        (array-length inventory.ledger)
        6
        "six ledger entries")
      (test.assert-i64-eq
        (array-ref inventory.ledger 0).kind
        dwarf.linker-dwarf-section-loclists
        "loclists first by section index")
      (test.assert-i64-eq
        (array-ref inventory.ledger 0).reason
        dwarf.linker-dwarf-ledger-opaque
        "location lists are opaque here")
      (test.assert-i64-eq
        (array-ref inventory.ledger 4).kind
        dwarf.linker-dwarf-section-str
        ".debug_str")
      (test.assert-i64-eq
        (array-ref inventory.ledger 4).reason
        dwarf.linker-dwarf-ledger-string-table
        "a checked string table"))))

;; --- hand-assembled units ------------------------------------------------------------------
(define (dwarf-test-nibble [c : i64]) : i64
  (cond
    [(and (>= c 48) (<= c 57)) (- c 48)]
    [(and (>= c 97) (<= c 102)) (- c 87)]
    [else -1]))

;: The bytes of `hex`, ignoring spaces.
(define (dwarf-test-bytes [hex : (& hex str)]) : (__tl_dyn-array u8)
  (let
    [out : (__tl_dyn-array u8) (__tl_make-array u8 0)]
    [index : i64 0]
    [high : i64 -1]
    (begin
      (while (< index (string.string-length hex))
        (let
          [digit : i64
            (dwarf-test-nibble (cast (string.string-ref hex index) : i64))]
          (begin
            (cond
              [(< digit 0) unit]
              [(< high 0) (set! high digit)]
              [else
                (begin
                  (__tl_array-push! out (cast (+ (* high 16) digit) : u8))
                  (set! high -1))])
            (set! index (+ index 1)))))
      out)))

(define (dwarf-test-view!
  [views : (&mut views (__tl_dyn-array dwarf.LinkerDwarfView))]
  [input : i64]
  [section : i64]
  [kind : i64]
  [hex : (& hex str)]) : unit
  (__tl_array-push!
    views
    (dwarf.LinkerDwarfView input section kind false (dwarf-test-bytes hex))))

;; A DWARF 5 compile unit: the root (producer string, name strp, stmt_list
;; sec_offset) with children, a base type at unit offset 0x17, and a variable
;; whose type is ref4 0x17 and whose location is DW_OP_addr 0.
(define dwarf-test-info : String
  "26000000 0500 01 08 00000000 01 7000 00000000 00000000 02 6900 03 17000000 09 03 0000000000000000 00")
(define dwarf-test-abbrev : String
  "011101 2508 030e 1017 0000 022400 0308 0000 033400 4913 0218 0000 00")

;: The unit's views: `.debug_info` and `.debug_abbrev` from `info` and
;: `abbrev`, plus `.debug_str` ("n") and a four-byte `.debug_line`.
(define (dwarf-test-views [info : (& info str)] [abbrev : (& abbrev str)]) : (__tl_dyn-array
    dwarf.LinkerDwarfView)
  (let
    [views : (__tl_dyn-array dwarf.LinkerDwarfView)
      (__tl_make-array dwarf.LinkerDwarfView 0)]
    (begin
      (dwarf-test-view! (&mut views) 1 1 dwarf.linker-dwarf-section-info info)
      (dwarf-test-view!
        (&mut views)
        1
        2
        dwarf.linker-dwarf-section-abbrev
        abbrev)
      (dwarf-test-view! (&mut views) 1 3 dwarf.linker-dwarf-section-str "6e00")
      (dwarf-test-view!
        (&mut views)
        1
        4
        dwarf.linker-dwarf-section-line
        "00000000")
      views)))

;: Scan `views` within `limits` and expect error `code` with `detail` at
;: `offset` (-99 skips a check).
(define (dwarf-expect-error
  [views : (__tl_dyn-array dwarf.LinkerDwarfView)]
  [limits : dwarf.LinkerDwarfLimits]
  [code : i64]
  [detail : i64]
  [offset : i64]
  [message : String]) : unit
  (match (dwarf.linker-dwarf-scan views limits)
    [(Ok _) (test.assert-true false message)]
    [(Err error)
      (begin
        (test.assert-i64-eq error.code code (string.copy (& message)))
        (if (= detail -99)
          unit
          (test.assert-i64-eq error.detail detail (string.copy (& message))))
        (if (= offset -99)
          unit
          (test.assert-i64-eq error.offset offset message)))]))

(define (dwarf-expect-unit-error
  [info : (& info str)]
  [abbrev : (& abbrev str)]
  [code : i64]
  [detail : i64]
  [offset : i64]
  [message : String]) : unit
  (dwarf-expect-error
    (dwarf-test-views info abbrev)
    (dwarf.linker-dwarf-default-limits)
    code
    detail
    offset
    message))

(test
  dwarf-hand-assembled-unit-is-inventoried-exactly
  (let
    [inventory : dwarf.LinkerDwarfInventory
      (dwarf-scan-ok
        (dwarf-test-views (& dwarf-test-info) (& dwarf-test-abbrev))
        "synthetic unit")]
    [refs : (__tl_dyn-array dwarf.LinkerDwarfReference) inventory.references]
    (begin
      (test.assert-i64-eq inventory.dies 3 "three DIEs")
      (test.assert-i64-eq inventory.attributes 6 "six attributes")
      (test.assert-i64-eq
        (array-length refs)
        5
        "header, strp, sec_offset, ref4, DW_OP_addr")
      (test.assert-i64-eq (array-ref refs 1).offset 15 "strp")
      (test.assert-i64-eq (array-ref refs 2).offset 19 "stmt_list")
      (test.assert-i64-eq (array-ref refs 3).offset 27 "ref4")
      (test.assert-i64-eq (array-ref refs 3).value 23 "unit-relative")
      (test.assert-i64-eq (array-ref refs 3).target 0 "resolved to the unit")
      (test.assert-i64-eq (array-ref refs 4).offset 33 "DW_OP_addr operand")
      (test.assert-i64-eq (array-ref refs 4).op 0x03 "operator")
      (test.assert-i64-eq (array-ref refs 4).width 8 "address width")
      (test.assert-i64-eq
        (array-ref refs 4).class
        dwarf.linker-dwarf-ref-address
        "address")
      ;; Codes need not be 1..n in order.
      (test.assert-i64-eq
        (dwarf-scan-ok
          (dwarf-test-views
            "26000000 0500 01 08 00000000 07 7000 00000000 00000000 02 6900 05 17000000 09 03 0000000000000000 00"
            "071101 2508 030e 1017 0000 022400 0308 0000 053400 4913 0218 0000 00")
          "sparse codes").dies
        3
        "a sparse, unordered table decodes the same DIEs"))))

(test
  dwarf-rejects-malformed-and-unadmitted-units
  (let
    [abbrev : String (string.copy (& dwarf-test-abbrev))]
    (begin
      (dwarf-expect-unit-error
        "ffffffff 0500 01 08 00000000 01 7000 00000000 00000000 02 6900 03 17000000 09 03 0000000000000000 00"
        (& abbrev)
        dwarf.linker-dwarf-error-dwarf64
        -99
        0
        "DWARF64 unit length")
      (dwarf-expect-unit-error
        "f0ffffff 0500 01 08 00000000 01 7000 00000000 00000000 02 6900 03 17000000 09 03 0000000000000000 00"
        (& abbrev)
        dwarf.linker-dwarf-error-unit
        0xfffffff0
        0
        "reserved unit length")
      (dwarf-expect-unit-error
        "26000000 0200 01 08 00000000 01 7000 00000000 00000000 02 6900 03 17000000 09 03 0000000000000000 00"
        (& abbrev)
        dwarf.linker-dwarf-error-version
        2
        4
        "DWARF 2")
      (dwarf-expect-unit-error
        "26000000 0600 01 08 00000000 01 7000 00000000 00000000 02 6900 03 17000000 09 03 0000000000000000 00"
        (& abbrev)
        dwarf.linker-dwarf-error-version
        6
        4
        "DWARF 6")
      (dwarf-expect-unit-error
        "26000000 0500 80 08 00000000 01 7000 00000000 00000000 02 6900 03 17000000 09 03 0000000000000000 00"
        (& abbrev)
        dwarf.linker-dwarf-error-unit-type
        128
        6
        "vendor unit type")
      (dwarf-expect-unit-error
        "26000000 0500 05 08 00000000 01 7000 00000000 00000000 02 6900 03 17000000 09 03 0000000000000000 00"
        (& abbrev)
        dwarf.linker-dwarf-error-unit-type
        5
        6
        "split unit type in .debug_info")
      (dwarf-expect-unit-error
        "26000000 0500 01 03 00000000 01 7000 00000000 00000000 02 6900 03 17000000 09 03 0000000000000000 00"
        (& abbrev)
        dwarf.linker-dwarf-error-unit
        3
        0
        "address size 3")
      (dwarf-expect-unit-error
        "27000000 0500 01 08 00000000 01 7000 00000000 00000000 02 6900 03 17000000 09 03 0000000000000000 00"
        (& abbrev)
        dwarf.linker-dwarf-error-truncated
        -99
        0
        "unit longer than its section")
      (dwarf-expect-unit-error
        "26000000 0500 01 08 00010000 01 7000 00000000 00000000 02 6900 03 17000000 09 03 0000000000000000 00"
        (& abbrev)
        dwarf.linker-dwarf-error-abbrev
        -99
        256
        "abbreviation offset outside .debug_abbrev")
      (dwarf-expect-unit-error
        "26000000 0500 01 08 00000000 04 7000 00000000 00000000 02 6900 03 17000000 09 03 0000000000000000 00"
        (& abbrev)
        dwarf.linker-dwarf-error-abbrev-code
        4
        12
        "undefined abbreviation code")
      (dwarf-expect-unit-error
        "26000000 0500 01 08 00000000 01 7000 00000000 00000000 02 6900 03 18000000 09 03 0000000000000000 00"
        (& abbrev)
        dwarf.linker-dwarf-error-reference
        24
        27
        "ref4 into the middle of a DIE")
      (dwarf-expect-unit-error
        "26000000 0500 01 08 00000000 01 7000 10000000 00000000 02 6900 03 17000000 09 03 0000000000000000 00"
        (& abbrev)
        dwarf.linker-dwarf-error-string
        16
        15
        "strp past .debug_str")
      (dwarf-expect-unit-error
        "26000000 0500 01 08 00000000 01 7000 00000000 00010000 02 6900 03 17000000 09 03 0000000000000000 00"
        (& abbrev)
        dwarf.linker-dwarf-error-reference
        256
        19
        "stmt_list past .debug_line")
      (dwarf-expect-unit-error
        "26000000 0500 01 08 00000000 01 7000 00000000 00000000 02 6900 03 17000000 09 ff 0000000000000000 00"
        (& abbrev)
        dwarf.linker-dwarf-error-expression
        0xff
        32
        "unknown expression operator")
      (dwarf-expect-unit-error
        "26000000 0500 01 08 00000000 01 7000 00000000 00000000 02 6900 03 17000000 09 f1 0000000000000000 00"
        (& abbrev)
        dwarf.linker-dwarf-error-expression
        0xf1
        32
        "DW_OP_GNU_encoded_addr")
      (dwarf-expect-unit-error
        "26000000 0500 01 08 00000000 01 7000 00000000 00000000 02 6900 03 17000000 09 2f 0001 969696969696 00"
        (& abbrev)
        dwarf.linker-dwarf-error-expression
        0x2f
        32
        "DW_OP_skip out of its expression")
      (dwarf-expect-unit-error
        "26000000 0500 01 08 00000000 01 7000 00000000 00000000 02 6900 03 17000000 09 a3 07 a3 05 9696969696 00"
        (& abbrev)
        dwarf.linker-dwarf-error-expression
        0xa3
        34
        "nested DW_OP_entry_value")
      (dwarf-expect-unit-error
        "25000000 0500 01 08 00000000 01 7000 00000000 00000000 02 6900 03 17000000 09 03 0000000000000000"
        (& abbrev)
        dwarf.linker-dwarf-error-nesting
        1
        41
        "unit ends inside the root's children")
      (dwarf-expect-unit-error
        "29000000 0500 01 08 00000000 01 7000 00000000 00000000 02 6900 03 17000000 09 03 0000000000000000 00 02 6900"
        (& abbrev)
        dwarf.linker-dwarf-error-nesting
        -99
        42
        "a second root")
      (dwarf-expect-unit-error
        "09000000 0500 01 08 00000000 80"
        (& abbrev)
        dwarf.linker-dwarf-error-leb
        -99
        12
        "truncated abbreviation code"))))

(test
  dwarf-rejects-malformed-abbreviations-and-forms
  (let
    [info : String (string.copy (& dwarf-test-info))]
    (begin
      (dwarf-expect-unit-error
        (& info)
        "011101 2502 030e 1017 0000 022400 0308 0000 033400 4913 0218 0000 00"
        dwarf.linker-dwarf-error-form
        2
        -99
        "unknown form 0x02")
      (dwarf-expect-unit-error
        (& info)
        "011101 251c 030e 1017 0000 022400 0308 0000 033400 4913 0218 0000 00"
        dwarf.linker-dwarf-error-form
        0x1c
        13
        "DW_FORM_ref_sup4")
      (dwarf-expect-unit-error
        (& info)
        "011101 2508 030e 1017 0000 012400 0308 0000 033400 4913 0218 0000 00"
        dwarf.linker-dwarf-error-abbrev
        1
        -99
        "duplicate abbreviation code")
      (dwarf-expect-unit-error
        (& info)
        "031101 2508 030e 1017 0000 022400 0308 0000 033400 4913 0218 0000 00"
        dwarf.linker-dwarf-error-abbrev
        3
        -99
        "a duplicate after a gap in the codes")
      (dwarf-expect-unit-error
        (& info)
        "011102 2508 030e 1017 0000 022400 0308 0000 033400 4913 0218 0000 00"
        dwarf.linker-dwarf-error-abbrev
        -99
        -99
        "DW_CHILDREN 2")
      (dwarf-expect-unit-error
        (& info)
        "011101 2508 0317 1017 0000 022400 0308 0000 033400 4913 0218 0000 00"
        dwarf.linker-dwarf-error-attribute
        3
        15
        "section offset on DW_AT_name")
      (dwarf-expect-unit-error
        "26000000 0500 01 08 00000000 01 16 16 0000000000000000 02 6900 03 17000000 09 03 0000000000000000 00"
        "011101 2516 030e 1017 0000 022400 0308 0000 033400 4913 0218 0000 00"
        dwarf.linker-dwarf-error-form
        0x16
        13
        "DW_FORM_indirect naming DW_FORM_indirect")
      ;; A DWARF 4 unit whose location is a block1 rather than an exprloc.
      (dwarf-expect-unit-error
        "25000000 0400 00000000 08 01 7000 00000000 00000000 02 6900 03 16000000 09 03 0000000000000000 00"
        "011101 2508 030e 1017 0000 022400 0308 0000 033400 4913 020a 0000 00"
        dwarf.linker-dwarf-error-attribute
        2
        31
        "DWARF 4 block on DW_AT_location")
      ;; strx1 in a unit without DW_AT_str_offsets_base.
      (dwarf-expect-unit-error
        "25000000 0500 01 08 00000000 01 00 00000000 00000000 02 6900 03 16000000 09 03 0000000000000000 00"
        "011101 2525 030e 1017 0000 022400 0308 0000 033400 4913 0218 0000 00"
        dwarf.linker-dwarf-error-index
        0
        13
        "string index without a base")
      ;; rnglistx in a unit without DW_AT_rnglists_base.
      (dwarf-expect-unit-error
        "25000000 0500 01 08 00000000 01 00 00000000 00000000 02 6900 03 16000000 09 03 0000000000000000 00"
        "011101 5523 030e 1017 0000 022400 0308 0000 033400 4913 0218 0000 00"
        dwarf.linker-dwarf-error-index
        0
        13
        "range list index without a base"))))

(test
  dwarf-rejects-missing-sections-and-duplicate-views
  (let
    [only-info : (__tl_dyn-array dwarf.LinkerDwarfView)
      (__tl_make-array dwarf.LinkerDwarfView 0)]
    [no-str : (__tl_dyn-array dwarf.LinkerDwarfView)
      (__tl_make-array dwarf.LinkerDwarfView 0)]
    [twice : (__tl_dyn-array dwarf.LinkerDwarfView)
      (dwarf-test-views (& dwarf-test-info) (& dwarf-test-abbrev))]
    (begin
      (dwarf-test-view!
        (&mut only-info)
        1
        1
        dwarf.linker-dwarf-section-info
        (& dwarf-test-info))
      (dwarf-expect-error
        only-info
        (dwarf.linker-dwarf-default-limits)
        dwarf.linker-dwarf-error-missing-section
        dwarf.linker-dwarf-section-abbrev
        8
        "no .debug_abbrev")
      (dwarf-test-view!
        (&mut no-str)
        1
        1
        dwarf.linker-dwarf-section-info
        (& dwarf-test-info))
      (dwarf-test-view!
        (&mut no-str)
        1
        2
        dwarf.linker-dwarf-section-abbrev
        (& dwarf-test-abbrev))
      (dwarf-test-view!
        (&mut no-str)
        1
        4
        dwarf.linker-dwarf-section-line
        "00000000")
      (dwarf-expect-error
        no-str
        (dwarf.linker-dwarf-default-limits)
        dwarf.linker-dwarf-error-missing-section
        dwarf.linker-dwarf-section-str
        15
        "no .debug_str")
      (dwarf-test-view!
        (&mut twice)
        1
        4
        dwarf.linker-dwarf-section-line
        "00000000")
      (dwarf-expect-error
        twice
        (dwarf.linker-dwarf-default-limits)
        dwarf.linker-dwarf-error-duplicate-view
        -99
        -99
        "two views with one provenance"))))

;: The default limits with one field replaced: `field` 0 views, 1 bytes,
;: 2 units, 3 abbreviation entries, 4 attribute specs, 5 DIEs, 6 attributes,
;: 7 depth, 8 block bytes, 9 references, 10 work.
(define (dwarf-limit [field : i64] [value : i64]) : dwarf.LinkerDwarfLimits
  (let
    [d : dwarf.LinkerDwarfLimits (dwarf.linker-dwarf-default-limits)]
    (dwarf.LinkerDwarfLimits
      (if (= field 0)
        value
        d.max-views)
      (if (= field 1)
        value
        d.max-bytes)
      (if (= field 2)
        value
        d.max-units)
      (if (= field 3)
        value
        d.max-abbrev-entries)
      (if (= field 4)
        value
        d.max-attribute-specs)
      (if (= field 5)
        value
        d.max-dies)
      (if (= field 6)
        value
        d.max-attributes)
      (if (= field 7)
        value
        d.max-depth)
      (if (= field 8)
        value
        d.max-block-bytes)
      (if (= field 9)
        value
        d.max-references)
      (if (= field 10)
        value
        d.max-work))))

(define (dwarf-expect-limit
  [field : i64]
  [value : i64]
  [code : i64]
  [message : String]) : unit
  (dwarf-expect-error
    (dwarf-test-views (& dwarf-test-info) (& dwarf-test-abbrev))
    (dwarf-limit field value)
    code
    -99
    -99
    message))

(test
  dwarf-enforces-every-limit
  (begin
    (dwarf-expect-limit
      7
      0
      dwarf.linker-dwarf-error-invalid-limits
      "zero depth is invalid")
    (dwarf-expect-limit 0 3 dwarf.linker-dwarf-error-view-limit "views")
    (dwarf-expect-limit 1 60 dwarf.linker-dwarf-error-byte-limit "bytes")
    (dwarf-expect-limit 2 0 dwarf.linker-dwarf-error-unit-limit "units")
    (dwarf-expect-limit
      3
      2
      dwarf.linker-dwarf-error-abbrev-limit
      "abbreviation entries")
    (dwarf-expect-limit
      4
      3
      dwarf.linker-dwarf-error-abbrev-limit
      "attribute specifications")
    (dwarf-expect-limit 5 2 dwarf.linker-dwarf-error-die-limit "DIEs")
    (dwarf-expect-limit
      6
      3
      dwarf.linker-dwarf-error-attribute-limit
      "attributes")
    (dwarf-expect-limit 8 4 dwarf.linker-dwarf-error-block "expression bytes")
    (dwarf-expect-limit
      9
      2
      dwarf.linker-dwarf-error-reference-limit
      "references")
    (dwarf-expect-limit 10 10 dwarf.linker-dwarf-error-work-limit "work")
    ;; The base type gets children, so the variable sits at depth two.
    (dwarf-expect-error
      (dwarf-test-views
        "27000000 0500 01 08 00000000 01 7000 00000000 00000000 02 6900 00 03 17000000 09 03 0000000000000000 00"
        "011101 2508 030e 1017 0000 022401 0308 0000 033400 4913 0218 0000 00")
      (dwarf-limit 7 1)
      dwarf.linker-dwarf-error-depth-limit
      -99
      23
      "depth")))

;: Whether the synthetic unit scans within `limits`.
(define (dwarf-scans-within? [limits : dwarf.LinkerDwarfLimits]) : bool
  (match (dwarf.linker-dwarf-scan
    (dwarf-test-views (& dwarf-test-info) (& dwarf-test-abbrev))
    limits)
    [(Ok _) true]
    [(Err _) false]))

(test
  dwarf-limits-admit-exactly-their-value
  (let
    ;; The synthetic unit's own measure of each limit field, in dwarf-limit
    ;; order; work comes from an unlimited scan.
    [work : i64
      (dwarf-scan-ok
        (dwarf-test-views (& dwarf-test-info) (& dwarf-test-abbrev))
        "unlimited").work]
    [measures : (__tl_dyn-array i64) (__tl_make-array i64 11)]
    [field : i64 0]
    (begin
      (set! (array-ref measures 0) 4)
      (set! (array-ref measures 1) 76)
      (set! (array-ref measures 2) 1)
      (set! (array-ref measures 3) 3)
      (set! (array-ref measures 4) 6)
      (set! (array-ref measures 5) 3)
      (set! (array-ref measures 6) 6)
      (set! (array-ref measures 7) 1)
      (set! (array-ref measures 8) 9)
      (set! (array-ref measures 9) 5)
      (set! (array-ref measures 10) work)
      (while (< field 11)
        (begin
          (test.assert-true
            (dwarf-scans-within? (dwarf-limit field (array-ref measures field)))
            "a limit equal to the measure admits the unit")
          (test.assert-true
            (not
              (dwarf-scans-within?
                (dwarf-limit field (- (array-ref measures field) 1))))
            "one less rejects it")
          (set! field (+ field 1))))
      ;; A four-byte DW_FORM_block1 constant is held to the same block limit.
      (let
        [info : String
          "21000000 0500 01 08 00000000 01 7000 00000000 00000000 02 6900 03 17000000 04 01020304 00"]
        [abbrev : String
          "011101 2508 030e 1017 0000 022400 0308 0000 033400 4913 1c0a 0000 00"]
        (begin
          (match (dwarf.linker-dwarf-scan
            (dwarf-test-views (& info) (& abbrev))
            (dwarf-limit 8 4))
            [(Ok _) unit]
            [(Err _)
              (test.assert-true
                false
                "a four-byte block within a limit of four")])
          (dwarf-expect-error
            (dwarf-test-views (& info) (& abbrev))
            (dwarf-limit 8 3)
            dwarf.linker-dwarf-error-block
            4
            -99
            "a four-byte block over a limit of three"))))))

;; --- split identities --------------------------------------------------------------------
;; A DWARF 5 skeleton (unit type 4) and split compile unit (5) with dwo id
;; 0x0807060504030201, each a single childless root.
(define (dwarf-skeleton-views [input : i64] [id : (& id str)]) : (__tl_dyn-array
    dwarf.LinkerDwarfView)
  (let
    [views : (__tl_dyn-array dwarf.LinkerDwarfView)
      (__tl_make-array dwarf.LinkerDwarfView 0)]
    (begin
      (let
        [hex : String
          (str_cat.str-cat "11000000 0500 04 08 00000000 " id " 01")]
        (dwarf-test-view!
          (&mut views)
          input
          1
          dwarf.linker-dwarf-section-info
          (& hex)))
      (dwarf-test-view!
        (&mut views)
        input
        2
        dwarf.linker-dwarf-section-abbrev
        "014a00 0000 00")
      views)))

(define (dwarf-split-views [input : i64] [id : (& id str)]) : (__tl_dyn-array
    dwarf.LinkerDwarfView)
  (let
    [views : (__tl_dyn-array dwarf.LinkerDwarfView)
      (__tl_make-array dwarf.LinkerDwarfView 0)]
    (begin
      (let
        [hex : String
          (str_cat.str-cat "11000000 0500 05 08 00000000 " id " 01")]
        (dwarf-test-view!
          (&mut views)
          input
          1
          dwarf.linker-dwarf-section-info-dwo
          (& hex)))
      (dwarf-test-view!
        (&mut views)
        input
        2
        dwarf.linker-dwarf-section-abbrev-dwo
        "011100 0000 00")
      views)))

(test
  dwarf-checks-split-identities
  (begin
    (test.assert-i64-eq
      (dwarf-skeleton-of
        (dwarf-join
          (dwarf-skeleton-views 1 "0102030405060708")
          (dwarf-split-views 2 "0102030405060708"))
        1
        "matching ids")
      0
      "the split unit pairs with the skeleton of its id")
    (test.assert-i64-eq
      (dwarf-skeleton-of
        (dwarf-join
          (dwarf-skeleton-views 1 "0102030405060708")
          (dwarf-split-views 2 "ffffffffffffffff"))
        1
        "different ids")
      -1
      "a split unit with another id stays unpaired")
    (dwarf-expect-error
      (dwarf-join
        (dwarf-skeleton-views 1 "0102030405060708")
        (dwarf-skeleton-views 2 "0102030405060708"))
      (dwarf.linker-dwarf-default-limits)
      dwarf.linker-dwarf-error-split
      -99
      -99
      "two skeletons with one id")
    (dwarf-expect-error
      (dwarf-join
        (dwarf-split-views 1 "0102030405060708")
        (dwarf-split-views 2 "0102030405060708"))
      (dwarf.linker-dwarf-default-limits)
      dwarf.linker-dwarf-error-split
      -99
      -99
      "two split units with one id")
    ;; A skeleton whose root also carries a different DW_AT_GNU_dwo_id.
    (let
      [views : (__tl_dyn-array dwarf.LinkerDwarfView)
        (__tl_make-array dwarf.LinkerDwarfView 0)]
      (begin
        (dwarf-test-view!
          (&mut views)
          1
          1
          dwarf.linker-dwarf-section-info
          "19000000 0500 04 08 00000000 0102030405060708 01 0807060504030201")
        (dwarf-test-view!
          (&mut views)
          1
          2
          dwarf.linker-dwarf-section-abbrev
          "014a00 b142 07 0000 00")
        (dwarf-expect-error
          views
          (dwarf.linker-dwarf-default-limits)
          dwarf.linker-dwarf-error-split
          -99
          -99
          "header and DW_AT_GNU_dwo_id disagree")))))

;; --- relocatable objects -----------------------------------------------------------------
;; A DWARF 5 root with str_offsets_base and addr_base 8, a strx1 name and an
;; addrx low_pc; the offsets and address tables hold one entry each.
(define (dwarf-index-views [relocatable : bool] [indices : (& indices str)]) : (__tl_dyn-array
    dwarf.LinkerDwarfView)
  (let
    [views : (__tl_dyn-array dwarf.LinkerDwarfView)
      (__tl_make-array dwarf.LinkerDwarfView 0)]
    [info : String
      (str_cat.str-cat
        "13000000 0500 01 08 00000000 01 08000000 08000000 "
        indices)]
    (begin
      (__tl_array-push!
        views
        (dwarf.LinkerDwarfView
          1
          1
          dwarf.linker-dwarf-section-info
          relocatable
          (dwarf-test-bytes (& info))))
      (__tl_array-push!
        views
        (dwarf.LinkerDwarfView
          1
          2
          dwarf.linker-dwarf-section-abbrev
          relocatable
          (dwarf-test-bytes "011100 7217 7317 0325 111b 0000 00")))
      (__tl_array-push!
        views
        (dwarf.LinkerDwarfView
          1
          3
          dwarf.linker-dwarf-section-str
          relocatable
          (dwarf-test-bytes "6e00")))
      (__tl_array-push!
        views
        (dwarf.LinkerDwarfView
          1
          4
          dwarf.linker-dwarf-section-str-offsets
          relocatable
          (dwarf-test-bytes "08000000 0500 0000 00000000")))
      (__tl_array-push!
        views
        (dwarf.LinkerDwarfView
          1
          5
          dwarf.linker-dwarf-section-addr
          relocatable
          (dwarf-test-bytes "0c000000 0500 0800 0000000000000000")))
      views)))

(test
  dwarf-relocatable-units-defer-base-dependent-indices
  (let
    [inventory : dwarf.LinkerDwarfInventory
      (dwarf-scan-ok (dwarf-index-views true "05 05") "relocatable")]
    (begin
      (dwarf-scan-ok (dwarf-index-views false "00 00") "linked, in range")
      (dwarf-expect-error
        (dwarf-index-views false "05 00")
        (dwarf.linker-dwarf-default-limits)
        dwarf.linker-dwarf-error-index
        -99
        21
        "a linked string index outside its offsets table")
      (dwarf-expect-error
        (dwarf-index-views false "00 05")
        (dwarf.linker-dwarf-default-limits)
        dwarf.linker-dwarf-error-index
        -99
        22
        "a linked address index outside its address table")
      ;; A relocatable object's bases are relocation placeholders, so its
      ;; indices are recorded and left for the relocated view to check.
      (test.assert-i64-eq
        (array-ref inventory.references 3).class
        dwarf.linker-dwarf-ref-string-index
        "strx1")
      (test.assert-i64-eq (array-ref inventory.references 3).value 5 "index 5")
      (test.assert-i64-eq
        (array-ref inventory.references 4).class
        dwarf.linker-dwarf-ref-address-index
        "addrx")
      (test.assert-i64-eq (array-ref inventory.references 4).offset 22 "at 22"))))

(test
  dwarf-type-offsets-must-name-dies
  (let
    [views : (__tl_dyn-array dwarf.LinkerDwarfView)
      (__tl_make-array dwarf.LinkerDwarfView 0)]
    (begin
      ;; A DWARF 4 .debug_types unit whose type offset 24 is inside its only
      ;; DIE (which starts at 23).
      (dwarf-test-view!
        (&mut views)
        1
        1
        dwarf.linker-dwarf-section-types
        "16000000 0400 00000000 08 0102030405060708 18000000 02 6900")
      (dwarf-test-view!
        (&mut views)
        1
        2
        dwarf.linker-dwarf-section-abbrev
        (& dwarf-test-abbrev))
      (dwarf-expect-error
        views
        (dwarf.linker-dwarf-default-limits)
        dwarf.linker-dwarf-error-reference
        24
        0
        "type offset inside a DIE"))))
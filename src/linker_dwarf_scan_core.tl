;; linker_dwarf_scan_core.tl - bounded DWARF unit, abbreviation, form and
;; reference inventory over caller-supplied debug-section byte views.
;;
;; This is the parse/classify layer the ELF debug-info linker (#7389) builds
;; on. The caller supplies already-delimited section contents with their
;; provenance (input, section, family); the scanner reads no file, runs no
;; tool and parses no object container. It walks every unit of the
;; `.debug_info`/`.debug_types` families, their abbreviation tables and every
;; DIE and attribute, and records each typed reference a relocator or
;; garbage collector must preserve or rewrite: its exact section offset,
;; width, unit, attribute or expression opcode, class and target family. It
;; does not resolve symbols, apply relocations, choose live sections or emit
;; anything.
;;
;; Admitted profile (see tests/fixtures/dwarf/README.md for the matrix):
;; DWARF32 units of version 3, 4 or 5; the v5 unit types compile, type,
;; partial, skeleton, split_compile and split_type; v4 `.debug_types` type
;; units and GNU split units; every DWARF 5 form except the supplementary-file
;; ones, plus DW_FORM_GNU_addr_index and DW_FORM_GNU_str_index; and every
;; DWARF 5 expression operator plus the GNU ones GCC emits. DWARF64,
;; versions 2 and 6+, unknown unit types, forms and operators, the
;; supplementary (`sup`, GNU `alt`) forms, DW_OP_GNU_encoded_addr, and a
;; section offset on an attribute whose target family is unknown fail with a
;; stable code.
;;
;; A view marked `relocatable` holds an object file's contents: its
;; address-, string- and section-offset fields may be relocation placeholders
;; (x86-64 RELA stores zero there), so the scanner records them without
;; checking their values, and does not check indexes against tables whose
;; base is such a placeholder. Unit-local references, signatures and
;; indexes with a known base are always checked. The scanner still needs
;; each unit header's `.debug_abbrev` offset to decode it: a RELA object
;; stores zero there, which is right when the relocation addend is zero (it
;; is in every GCC, Clang and GNU as object of the corpus); otherwise the
;; caller writes the addend into the field before scanning. That field is
;; recorded as a reference too.
;;
;; Every count and the total work are bounded by caller limits checked before
;; the corresponding storage grows. Output order is canonical, by
;; (input, section) and then offset, whatever order the views arrive in.
(import stdlib.iterator)
(import stdlib.byte_le)
(import stdlib.leb128)
(import stdlib.string)
(import stdlib.vector)
(cfg test (import stdlib.test))

;; The scan appends to these as it walks; a vector doubles its storage, where
;; a dynamic-array push reallocates on every append.
(import (vector.vector i64 core) as dwarf_i64_vec)
(import (vector.vector LinkerDwarfUnit core) as dwarf_unit_vec)
(import (vector.vector LinkerDwarfAbbrevTable core) as dwarf_table_vec)
(import (vector.vector LinkerDwarfReference core) as dwarf_reference_vec)
(import (vector.vector LinkerDwarfLedgerEntry core) as dwarf_ledger_vec)

;; --- section families ----------------------------------------------------------
(define linker-dwarf-section-info : i64
  1)
(define linker-dwarf-section-types : i64
  2)
(define linker-dwarf-section-abbrev : i64
  3)
(define linker-dwarf-section-str : i64
  4)
(define linker-dwarf-section-line-str : i64
  5)
(define linker-dwarf-section-str-offsets : i64
  6)
(define linker-dwarf-section-addr : i64
  7)
(define linker-dwarf-section-rnglists : i64
  8)
(define linker-dwarf-section-loclists : i64
  9)
(define linker-dwarf-section-ranges : i64
  10)
(define linker-dwarf-section-loc : i64
  11)
(define linker-dwarf-section-line : i64
  12)
(define linker-dwarf-section-aranges : i64
  13)
(define linker-dwarf-section-macro : i64
  14)
(define linker-dwarf-section-macinfo : i64
  15)
(define linker-dwarf-section-frame : i64
  16)
(define linker-dwarf-section-info-dwo : i64
  17)
(define linker-dwarf-section-types-dwo : i64
  18)
(define linker-dwarf-section-abbrev-dwo : i64
  19)
(define linker-dwarf-section-str-dwo : i64
  20)
(define linker-dwarf-section-str-offsets-dwo : i64
  21)
(define linker-dwarf-section-rnglists-dwo : i64
  22)
(define linker-dwarf-section-loclists-dwo : i64
  23)
(define linker-dwarf-section-loc-dwo : i64
  24)
(define linker-dwarf-section-line-dwo : i64
  25)
(define linker-dwarf-section-macro-dwo : i64
  26)
(define linker-dwarf-section-cu-index : i64
  27)
(define linker-dwarf-section-tu-index : i64
  28)

;; Any other `.debug_*` section: pubnames, pubtypes, names, the GNU pub
;; tables, supplementary and vendor sections.
(define linker-dwarf-section-other : i64
  29)

;: The section family named `name`, or `linker-dwarf-section-other`.
(define (linker-dwarf-section-kind-from-name [name : (& name str)]) : i64
  (cond
    [(string.eq name ".debug_info") linker-dwarf-section-info]
    [(string.eq name ".debug_types") linker-dwarf-section-types]
    [(string.eq name ".debug_abbrev") linker-dwarf-section-abbrev]
    [(string.eq name ".debug_str") linker-dwarf-section-str]
    [(string.eq name ".debug_line_str") linker-dwarf-section-line-str]
    [(string.eq name ".debug_str_offsets") linker-dwarf-section-str-offsets]
    [(string.eq name ".debug_addr") linker-dwarf-section-addr]
    [(string.eq name ".debug_rnglists") linker-dwarf-section-rnglists]
    [(string.eq name ".debug_loclists") linker-dwarf-section-loclists]
    [(string.eq name ".debug_ranges") linker-dwarf-section-ranges]
    [(string.eq name ".debug_loc") linker-dwarf-section-loc]
    [(string.eq name ".debug_line") linker-dwarf-section-line]
    [(string.eq name ".debug_aranges") linker-dwarf-section-aranges]
    [(string.eq name ".debug_macro") linker-dwarf-section-macro]
    [(string.eq name ".debug_macinfo") linker-dwarf-section-macinfo]
    [(string.eq name ".debug_frame") linker-dwarf-section-frame]
    [(string.eq name ".debug_info.dwo") linker-dwarf-section-info-dwo]
    [(string.eq name ".debug_types.dwo") linker-dwarf-section-types-dwo]
    [(string.eq name ".debug_abbrev.dwo") linker-dwarf-section-abbrev-dwo]
    [(string.eq name ".debug_str.dwo") linker-dwarf-section-str-dwo]
    [(string.eq name ".debug_str_offsets.dwo")
      linker-dwarf-section-str-offsets-dwo]
    [(string.eq name ".debug_rnglists.dwo") linker-dwarf-section-rnglists-dwo]
    [(string.eq name ".debug_loclists.dwo") linker-dwarf-section-loclists-dwo]
    [(string.eq name ".debug_loc.dwo") linker-dwarf-section-loc-dwo]
    [(string.eq name ".debug_line.dwo") linker-dwarf-section-line-dwo]
    [(string.eq name ".debug_macro.dwo") linker-dwarf-section-macro-dwo]
    [(string.eq name ".debug_cu_index") linker-dwarf-section-cu-index]
    [(string.eq name ".debug_tu_index") linker-dwarf-section-tu-index]
    [else linker-dwarf-section-other]))

;: Whether sections of `kind` hold units the scanner walks.
(define (linker-dwarf-unit-section? [kind : i64]) : bool
  (or
    (= kind linker-dwarf-section-info)
    (= kind linker-dwarf-section-types)
    (= kind linker-dwarf-section-info-dwo)
    (= kind linker-dwarf-section-types-dwo)))

;: Whether sections of `kind` belong to a split (`.dwo`) file.
(define (linker-dwarf-split-section? [kind : i64]) : bool
  (and
    (>= kind linker-dwarf-section-info-dwo)
    (<= kind linker-dwarf-section-macro-dwo)))

;; --- unsupported-section ledger reasons ----------------------------------------
;; A string table: its offsets are checked, and it holds no references.
(define linker-dwarf-ledger-string-table : i64
  1)

;; An offset or address table (`.debug_str_offsets`, `.debug_addr`): its
;; entries are relocatable and are not inventoried here.
(define linker-dwarf-ledger-offset-table : i64
  2)

;; Contents this layer does not parse: line programs, range and location
;; lists, aranges, macros, frames, indexes and other tables.
(define linker-dwarf-ledger-opaque : i64
  3)

;; --- reference classes -----------------------------------------------------------
;; A unit-relative DIE offset (DW_FORM_ref*, DW_OP_call2/4, base-type operands).
(define linker-dwarf-ref-unit : i64
  1)

;; A `.debug_info`-relative DIE offset (DW_FORM_ref_addr, DW_OP_call_ref,
;; DW_OP_implicit_pointer, DW_OP_GNU_variable_value).
(define linker-dwarf-ref-info : i64
  2)

;; A type-unit signature (DW_FORM_ref_sig8).
(define linker-dwarf-ref-signature : i64
  3)

;; A `.debug_str` offset (DW_FORM_strp).
(define linker-dwarf-ref-string : i64
  4)

;; A `.debug_line_str` offset (DW_FORM_line_strp).
(define linker-dwarf-ref-line-string : i64
  5)

;; A string index (DW_FORM_strx*, DW_FORM_GNU_str_index).
(define linker-dwarf-ref-string-index : i64
  6)

;; A target address (DW_FORM_addr, DW_OP_addr).
(define linker-dwarf-ref-address : i64
  7)

;; An address index (DW_FORM_addrx*, DW_FORM_GNU_addr_index, DW_OP_addrx,
;; DW_OP_constx and their GNU spellings).
(define linker-dwarf-ref-address-index : i64
  8)

;; An offset into the section family in `target-kind` (DW_FORM_sec_offset, a
;; DWARF 3 data4/data8 pointer).
(define linker-dwarf-ref-section-offset : i64
  9)

;; A range-list index (DW_FORM_rnglistx).
(define linker-dwarf-ref-rnglist-index : i64
  10)

;; A location-list index (DW_FORM_loclistx).
(define linker-dwarf-ref-loclist-index : i64
  11)

;; --- error codes -------------------------------------------------------------------
(define linker-dwarf-error-invalid-limits : i64
  1)
(define linker-dwarf-error-view-limit : i64
  2)
(define linker-dwarf-error-byte-limit : i64
  3)
(define linker-dwarf-error-duplicate-view : i64
  4)
(define linker-dwarf-error-truncated : i64
  5)
(define linker-dwarf-error-dwarf64 : i64
  6)
(define linker-dwarf-error-version : i64
  7)
(define linker-dwarf-error-unit-type : i64
  8)
(define linker-dwarf-error-unit : i64
  9)
(define linker-dwarf-error-missing-section : i64
  10)
(define linker-dwarf-error-abbrev : i64
  11)
(define linker-dwarf-error-abbrev-code : i64
  12)
(define linker-dwarf-error-form : i64
  13)
(define linker-dwarf-error-attribute : i64
  14)
(define linker-dwarf-error-leb : i64
  15)
(define linker-dwarf-error-block : i64
  16)
(define linker-dwarf-error-nesting : i64
  17)
(define linker-dwarf-error-expression : i64
  18)
(define linker-dwarf-error-reference : i64
  19)
(define linker-dwarf-error-string : i64
  20)
(define linker-dwarf-error-index : i64
  21)
(define linker-dwarf-error-split : i64
  22)
(define linker-dwarf-error-unit-limit : i64
  23)
(define linker-dwarf-error-abbrev-limit : i64
  24)
(define linker-dwarf-error-die-limit : i64
  25)
(define linker-dwarf-error-attribute-limit : i64
  26)
(define linker-dwarf-error-depth-limit : i64
  27)
(define linker-dwarf-error-reference-limit : i64
  28)
(define linker-dwarf-error-work-limit : i64
  29)

;; --- inputs, limits, results ---------------------------------------------------------
;: One debug section's contents. `input` and `section` are the caller's
;: provenance (for example an object index and an ELF section index); together
;: they identify the view and fix its place in the canonical order.
(defstruct LinkerDwarfView
  (input i64)
  (section i64)
  (kind i64)
  (relocatable bool)
  (bytes (__tl_dyn-array u8)))

;: Caller-owned bounds, each checked before the corresponding work or growth.
(defstruct LinkerDwarfLimits
  (max-views i64)
  (max-bytes i64)
  (max-units i64)
  (max-abbrev-entries i64)
  (max-attribute-specs i64)
  (max-dies i64)
  (max-attributes i64)
  (max-depth i64)
  (max-block-bytes i64)
  (max-references i64)
  (max-work i64))

;: Limits that admit a large linked program's debug information.
(define (linker-dwarf-default-limits) : LinkerDwarfLimits
  (LinkerDwarfLimits
    65536
    1073741824
    1048576
    4194304
    33554432
    67108864
    268435456
    256
    16777216
    268435456
    4294967296))

;: Why the scan stopped: a stable `code`, the view's provenance, the offset of
;: the unit being walked (or -1), the byte offset of the fault and `detail`,
;: the offending value (a form, attribute, operator, version or index) or 0.
(defstruct LinkerDwarfError
  (code i64)
  (input i64)
  (section i64)
  (kind i64)
  (unit i64)
  (offset i64)
  (detail i64)
  (message String))

;: One unit. `offset` is its header's section offset and `end` the offset just
;: past it. `unit-type` is the DWARF 5 code; DWARF 3/4 units report the code
;: their section and root DIE imply. `signature`/`type-offset` belong to type
;: units, `dwo-id` to skeleton and split units (`has-id`). The bases are -1
;: when the root DIE does not give them.
(defstruct LinkerDwarfUnit
  (input i64)
  (section i64)
  (kind i64)
  (relocatable bool)
  (offset i64)
  (end i64)
  (version i64)
  (unit-type i64)
  (address-size i64)
  (abbrev-offset i64)
  (die-offset i64)
  (first-die i64)
  (die-count i64)
  (root-tag i64)
  (signature i64)
  (type-offset i64)
  (dwo-id i64)
  (has-id bool)
  (str-offsets-base i64)
  (addr-base i64)
  (rnglists-base i64)
  (loclists-base i64)
  (ranges-base i64)
  (skeleton i64))

;: One abbreviation table and the number of entries it declares.
(defstruct LinkerDwarfAbbrevTable
  (input i64)
  (section i64)
  (kind i64)
  (offset i64)
  (end i64)
  (entries i64))

;: One stored reference: the field at `offset` (width `width` bytes) of unit
;: `unit`'s section, written by attribute `attribute` in form `form`, or by
;: expression operator `op` (else -1). `value` is the stored value (for a
;: unit reference, unit-relative). `target` is the resolved unit index (unit,
;: info and signature references) or -1.
(defstruct LinkerDwarfReference
  (unit i64)
  (offset i64)
  (width i64)
  (attribute i64)
  (form i64)
  (op i64)
  (class i64)
  (target-kind i64)
  (value i64)
  (target i64))

;: A supplied section this layer did not inventory, and why.
(defstruct LinkerDwarfLedgerEntry
  (input i64)
  (section i64)
  (kind i64)
  (reason i64))

;: The immutable scan result.
(defstruct LinkerDwarfInventory
  (units (__tl_dyn-array LinkerDwarfUnit))
  (abbrev-tables (__tl_dyn-array LinkerDwarfAbbrevTable))
  (references (__tl_dyn-array LinkerDwarfReference))
  (ledger (__tl_dyn-array LinkerDwarfLedgerEntry))
  (dies i64)
  (attributes i64)
  (work i64))

(defenum ResultLinkerDwarfInventory
  (Ok LinkerDwarfInventory)
  (Err LinkerDwarfError))

;; --- scan state ------------------------------------------------------------------------
;; Abbreviation entries live in flat parallel arrays shared by every table;
;; a table owns the contiguous run [first, first + entries). Unit-scoped
;; values that the root DIE supplies are kept in parallel arrays too, so no
;; unit record is rewritten in place.
(defstruct LinkerDwarfScan
  (views (__tl_dyn-array LinkerDwarfView))
  (limits LinkerDwarfLimits)
  (units dwarf_unit_vec.Vec)
  (unit-views dwarf_i64_vec.Vec)
  (tables dwarf_table_vec.Vec)
  (table-views dwarf_i64_vec.Vec)
  (table-first dwarf_i64_vec.Vec)
  (entry-code dwarf_i64_vec.Vec)
  (entry-tag dwarf_i64_vec.Vec)
  (entry-children dwarf_i64_vec.Vec)
  (entry-first-spec dwarf_i64_vec.Vec)
  (entry-specs dwarf_i64_vec.Vec)
  (spec-attribute dwarf_i64_vec.Vec)
  (spec-form dwarf_i64_vec.Vec)
  (spec-const dwarf_i64_vec.Vec)
  (references dwarf_reference_vec.Vec)
  (ledger dwarf_ledger_vec.Vec)
  (die-offsets dwarf_i64_vec.Vec)
  (dies i64)
  (attributes i64)
  (work i64)
  (ok bool)
  (error LinkerDwarfError))

(define (linker-dwarf-scan-new
  [views : (__tl_dyn-array LinkerDwarfView)]
  [limits : LinkerDwarfLimits]) : LinkerDwarfScan
  (LinkerDwarfScan
    views
    limits
    (dwarf_unit_vec.new)
    (dwarf_i64_vec.new)
    (dwarf_table_vec.new)
    (dwarf_i64_vec.new)
    (dwarf_i64_vec.new)
    (dwarf_i64_vec.new)
    (dwarf_i64_vec.new)
    (dwarf_i64_vec.new)
    (dwarf_i64_vec.new)
    (dwarf_i64_vec.new)
    (dwarf_i64_vec.new)
    (dwarf_i64_vec.new)
    (dwarf_i64_vec.new)
    (dwarf_reference_vec.new)
    (dwarf_ledger_vec.new)
    (dwarf_i64_vec.new)
    0
    0
    0
    true
    (LinkerDwarfError 0 -1 -1 0 -1 0 0 "")))

;: Record the first failure: `code` in view `view` (or -1), in the unit at
;: `unit` (or -1), at byte `offset`, with offending value `detail`.
(define (linker-dwarf-fail-detail!
  [scan : (&mut scan LinkerDwarfScan)]
  [code : i64]
  [view : i64]
  [unit-at : i64]
  [offset : i64]
  [detail : i64]
  [message : String]) : unit
  (when
    scan.ok
    (set! scan.ok false)
    (set!
      scan.error
      (if (< view 0)
        (LinkerDwarfError code -1 -1 0 unit-at offset detail message)
        (LinkerDwarfError
          code
          (array-ref scan.views view).input
          (array-ref scan.views view).section
          (array-ref scan.views view).kind
          unit-at
          offset
          detail
          message)))))

;: `linker-dwarf-fail-detail!` without an offending value.
(define (linker-dwarf-fail!
  [scan : (&mut scan LinkerDwarfScan)]
  [code : i64]
  [view : i64]
  [unit-at : i64]
  [offset : i64]
  [message : String]) : unit
  (linker-dwarf-fail-detail! scan code view unit-at offset 0 message))

;: Charge `amount` units of work; false (and a failure) past the limit.
(define (linker-dwarf-charge!
  [scan : (&mut scan LinkerDwarfScan)]
  [amount : i64]
  [view : i64]
  [offset : i64]) : bool
  (if (> amount (- scan.limits.max-work scan.work))
    (begin
      (linker-dwarf-fail!
        scan
        linker-dwarf-error-work-limit
        view
        -1
        offset
        "dwarf: work limit exceeded")
      false)
    (begin
      (+= scan.work amount)
      true)))

;: Whether `count` bytes at `at` lie before `end`; otherwise a truncation
;: failure.
(define (linker-dwarf-need!
  [scan : (&mut scan LinkerDwarfScan)]
  [view : i64]
  [unit-at : i64]
  [at : i64]
  [count : i64]
  [end : i64]) : bool
  (if (and (>= at 0) (>= count 0) (<= count (- end at)))
    true
    (begin
      (linker-dwarf-fail!
        scan
        linker-dwarf-error-truncated
        view
        unit-at
        at
        "dwarf: field runs past the end of its unit or table")
      false)))

;: Decode a LEB128 at `at` before `end`; a failure records a LEB error.
(define (linker-dwarf-leb!
  [scan : (&mut scan LinkerDwarfScan)]
  [view : i64]
  [unit-at : i64]
  [at : i64]
  [end : i64]
  [signed? : bool]) : leb128.Decoded
  (let
    [decoded : leb128.Decoded
      (if signed?
        (leb128.decode-signed (& (array-ref scan.views view).bytes) at end)
        (leb128.decode-unsigned (& (array-ref scan.views view).bytes) at end))]
    (if decoded.ok?
      unit
      (linker-dwarf-fail!
        scan
        linker-dwarf-error-leb
        view
        unit-at
        at
        "dwarf: truncated, overlong or oversized LEB128"))
    decoded))

;: The unsigned integer of `width` (1, 2, 3, 4 or 8) bytes at `at`.
(define (linker-dwarf-read
  [bytes : (& bytes (__tl_dyn-array u8))]
  [at : i64]
  [width : i64]) : i64
  (cond
    [(= width 1) (byte_le.byte-le-at bytes at)]
    [(= width 2) (byte_le.read-u16 bytes at)]
    [(= width 3)
      (bit-or
        (byte_le.read-u16 bytes at)
        (shl (byte_le.byte-le-at bytes (+ at 2)) 16))]
    [(= width 4) (byte_le.read-u32 bytes at)]
    [else (byte_le.read-u64 bytes at)]))

;: The first view of `input` in family `kind`, in canonical order, or -1.
(define (linker-dwarf-find-view
  [scan : (& scan LinkerDwarfScan)]
  [input : i64]
  [kind : i64]) : i64
  (let
    [index : i64 0]
    [found : i64 -1]
    [count : i64 (array-length scan.views)]
    (while (and (< index count) (< found 0))
      (if (and
        (= (array-ref scan.views index).input input)
        (= (array-ref scan.views index).kind kind))
        (set! found index)
        unit)
      (+= index 1))
    found))

;; --- abbreviation tables ---------------------------------------------------------------
;: Whether `form` is a form code this layer decodes.
(define (linker-dwarf-known-form? [form : i64]) : bool
  (or
    (and (>= form 0x01) (<= form 0x2c) (!= form 0x02))
    (= form 0x1f01)
    (= form 0x1f02)
    (= form 0x1f20)
    (= form 0x1f21)))

;: The table index for abbreviations at `offset` of view `view`, parsing and
;: caching the table on first use, or -1 after a failure.
(define (linker-dwarf-abbrev-table!
  [scan : (&mut scan LinkerDwarfScan)]
  [view : i64]
  [offset : i64]
  [unit-at : i64]) : i64
  (let
    [index : i64 0]
    [found : i64 -1]
    [count : i64 scan.tables.len]
    (while (and (< index count) (< found 0))
      (if (and
        (= (array-ref scan.table-views.slots index) view)
        (= (array-ref scan.tables.slots index).offset offset))
        (set! found index)
        unit)
      (+= index 1))
    (if (>= found 0)
      found
      (linker-dwarf-parse-abbrev-table! scan view offset unit-at))))

(define (linker-dwarf-parse-abbrev-table!
  [scan : (&mut scan LinkerDwarfScan)]
  [view : i64]
  [offset : i64]
  [unit-at : i64]) : i64
  (let
    [end : i64 (array-length (array-ref scan.views view).bytes)]
    [first : i64 scan.entry-code.len]
    [at : i64 offset]
    [done : bool false]
    (if (or (< offset 0) (>= offset end))
      (linker-dwarf-fail!
        scan
        linker-dwarf-error-abbrev
        view
        unit-at
        offset
        "dwarf: abbreviation offset lies outside .debug_abbrev")
      unit)
    (while (and scan.ok (not done))
      (let
        [code : leb128.Decoded
          (linker-dwarf-leb! scan view unit-at at end false)]
        (cond
          [(not scan.ok) unit]
          [(= code.value 0)
            (set! at code.next)
            (set! done true)]
          [(>= scan.entry-code.len scan.limits.max-abbrev-entries)
            (linker-dwarf-fail!
              scan
              linker-dwarf-error-abbrev-limit
              view
              unit-at
              at
              "dwarf: abbreviation entry limit exceeded")]
          [else
            (let
              [tag : leb128.Decoded
                (linker-dwarf-leb! scan view unit-at code.next end false)]
              [children-at : i64 tag.next]
              [first-spec : i64 scan.spec-form.len]
              [specs : i64 0]
              (if (and scan.ok (or (<= tag.value 0) (< code.value 0)))
                (linker-dwarf-fail!
                  scan
                  linker-dwarf-error-abbrev
                  view
                  unit-at
                  at
                  "dwarf: abbreviation with a zero or oversized tag or code")
                unit)
              (if (and
                scan.ok
                (linker-dwarf-need! scan view unit-at children-at 1 end))
                (let
                  [children : i64
                    (byte_le.byte-le-at
                      (& (array-ref scan.views view).bytes)
                      children-at)]
                  [spec-at : i64 (+ children-at 1)]
                  [specs-done : bool false]
                  (if (> children 1)
                    (linker-dwarf-fail!
                      scan
                      linker-dwarf-error-abbrev
                      view
                      unit-at
                      children-at
                      "dwarf: DW_CHILDREN is neither 0 nor 1")
                    unit)
                  (while (and scan.ok (not specs-done))
                    (let
                      [name : leb128.Decoded
                        (linker-dwarf-leb! scan view unit-at spec-at end false)]
                      [form : leb128.Decoded
                        (if scan.ok
                          (linker-dwarf-leb!
                            scan
                            view
                            unit-at
                            name.next
                            end
                            false)
                          name)]
                      (cond
                        [(not scan.ok) unit]
                        [(and (= name.value 0) (= form.value 0))
                          (set! spec-at form.next)
                          (set! specs-done true)]
                        [(or (= name.value 0) (= form.value 0))
                          (linker-dwarf-fail!
                            scan
                            linker-dwarf-error-abbrev
                            view
                            unit-at
                            spec-at
                            "dwarf: attribute specification with a zero name or form")]
                        [(not (linker-dwarf-known-form? form.value))
                          (linker-dwarf-fail-detail!
                            scan
                            linker-dwarf-error-form
                            view
                            unit-at
                            name.next
                            form.value
                            "dwarf: unknown attribute form")]
                        [(>= scan.spec-form.len scan.limits.max-attribute-specs)
                          (linker-dwarf-fail!
                            scan
                            linker-dwarf-error-abbrev-limit
                            view
                            unit-at
                            spec-at
                            "dwarf: attribute specification limit exceeded")]
                        [else
                          (let
                            [constant : leb128.Decoded
                              (if (= form.value 0x21)
                                (linker-dwarf-leb!
                                  scan
                                  view
                                  unit-at
                                  form.next
                                  end
                                  true)
                                (leb128.Decoded true 0 form.next))]
                            (dwarf_i64_vec.push-ref!
                              (&mut scan.spec-attribute)
                              name.value)
                            (dwarf_i64_vec.push-ref!
                              (&mut scan.spec-form)
                              form.value)
                            (dwarf_i64_vec.push-ref!
                              (&mut scan.spec-const)
                              constant.value)
                            (+= specs 1)
                            (set! spec-at constant.next))])))
                  (if scan.ok
                    (begin
                      (dwarf_i64_vec.push-ref!
                        (&mut scan.entry-code)
                        code.value)
                      (dwarf_i64_vec.push-ref! (&mut scan.entry-tag) tag.value)
                      (dwarf_i64_vec.push-ref!
                        (&mut scan.entry-children)
                        children)
                      (dwarf_i64_vec.push-ref!
                        (&mut scan.entry-first-spec)
                        first-spec)
                      (dwarf_i64_vec.push-ref! (&mut scan.entry-specs) specs)
                      (set! at spec-at))
                    unit))
                unit))])))
    (if scan.ok
      (linker-dwarf-finish-abbrev-table! scan view offset at first unit-at)
      -1)))

;: Register a parsed table after checking its codes are unique.
(define (linker-dwarf-finish-abbrev-table!
  [scan : (&mut scan LinkerDwarfScan)]
  [view : i64]
  [offset : i64]
  [end : i64]
  [first : i64]
  [unit-at : i64]) : i64
  (let
    [count : i64 (- scan.entry-code.len first)]
    [dense : bool true]
    [index : i64 0]
    ;; Codes are almost always exactly 1..n in order, which cannot repeat;
    ;; any other table is sorted to find a repeat in O(n log n).
    (while (and dense (< index count))
      (if (!= (array-ref scan.entry-code.slots (+ first index)) (+ index 1))
        (set! dense false)
        unit)
      (+= index 1))
    (if (not dense)
      (let
        [codes : (__tl_dyn-array i64) (__tl_make-array i64 count)]
        [zeros : (__tl_dyn-array i64) (__tl_make-array i64 count)]
        (set! index 0)
        (while (< index count)
          (set!
            (array-ref codes index)
            (array-ref scan.entry-code.slots (+ first index)))
          (+= index 1))
        (let
          [order : (__tl_dyn-array i64)
            (linker-dwarf-order (& codes) (& zeros) count)]
          (set! index 1)
          (while (and scan.ok (< index count))
            (if (=
              (array-ref codes (array-ref order index))
              (array-ref codes (array-ref order (- index 1))))
              (linker-dwarf-fail-detail!
                scan
                linker-dwarf-error-abbrev
                view
                unit-at
                offset
                (array-ref codes (array-ref order index))
                "dwarf: duplicate abbreviation code in one table")
              unit)
            (+= index 1))))
      unit)
    (if (and scan.ok (linker-dwarf-charge! scan (- end offset) view offset))
      (let
        [table : i64 scan.tables.len]
        (dwarf_table_vec.push-ref!
          (&mut scan.tables)
          (LinkerDwarfAbbrevTable
            (array-ref scan.views view).input
            (array-ref scan.views view).section
            (array-ref scan.views view).kind
            offset
            end
            count))
        (dwarf_i64_vec.push-ref! (&mut scan.table-views) view)
        (dwarf_i64_vec.push-ref! (&mut scan.table-first) first)
        table)
      -1)))

(define (linker-dwarf-abbrev-entry
  [scan : (& scan LinkerDwarfScan)]
  [table : i64]
  [code : i64]) : i64
  (let
    [first : i64 (array-ref scan.table-first.slots table)]
    [count : i64 (array-ref scan.tables.slots table).entries]
    (if (and
      (>= code 1)
      (<= code count)
      (= (array-ref scan.entry-code.slots (+ first (- code 1))) code))
      (+ first (- code 1))
      (let
        [index : i64 0]
        [found : i64 -1]
        (while (and (< index count) (< found 0))
          (if (= (array-ref scan.entry-code.slots (+ first index)) code)
            (set! found (+ first index))
            unit)
          (+= index 1))
        found))))

;; --- attribute classes -------------------------------------------------------------------
;: Attributes whose section offset names a location list (DWARF 3/4
;: `.debug_loc`, DWARF 5 `.debug_loclists`), including GCC's view lists.
(define (linker-dwarf-loclist-attribute? [attribute : i64]) : bool
  (or
    (= attribute 0x02)
    (= attribute 0x19)
    (= attribute 0x2a)
    (= attribute 0x38)
    (= attribute 0x40)
    (= attribute 0x46)
    (= attribute 0x48)
    (= attribute 0x4a)
    (= attribute 0x4d)
    (= attribute 0x2137)))

;: Attributes whose block value is a DWARF expression: the location-list ones
;: and the DWARF 3 bounds, sizes and data locations.
(define (linker-dwarf-expression-attribute? [attribute : i64]) : bool
  (or
    (and (linker-dwarf-loclist-attribute? attribute) (!= attribute 0x2137))
    (= attribute 0x0b)
    (= attribute 0x0c)
    (= attribute 0x0d)
    (= attribute 0x22)
    (= attribute 0x2e)
    (= attribute 0x2f)
    (= attribute 0x37)
    (= attribute 0x4e)
    (= attribute 0x4f)
    (= attribute 0x50)
    (= attribute 0x51)))

;: The section family a section offset of `attribute` points into, or -1.
(define (linker-dwarf-offset-target
  [attribute : i64]
  [version : i64]
  [split? : bool]) : i64
  (cond
    [(= attribute 0x10)
      (if split?
        linker-dwarf-section-line-dwo
        linker-dwarf-section-line)]
    [(= attribute 0x55)
      (cond
        [(< version 5) linker-dwarf-section-ranges]
        [split? linker-dwarf-section-rnglists-dwo]
        [else linker-dwarf-section-rnglists])]
    [(linker-dwarf-loclist-attribute? attribute)
      (cond
        [(and (< version 5) split?) linker-dwarf-section-loc-dwo]
        [(< version 5) linker-dwarf-section-loc]
        [split? linker-dwarf-section-loclists-dwo]
        [else linker-dwarf-section-loclists])]
    [(= attribute 0x72) linker-dwarf-section-str-offsets]
    [(or (= attribute 0x73) (= attribute 0x2133)) linker-dwarf-section-addr]
    [(= attribute 0x74) linker-dwarf-section-rnglists]
    [(= attribute 0x8c) linker-dwarf-section-loclists]
    [(= attribute 0x2132) linker-dwarf-section-ranges]
    [(= attribute 0x43) linker-dwarf-section-macinfo]
    [(or (= attribute 0x79) (= attribute 0x2119))
      (if split?
        linker-dwarf-section-macro-dwo
        linker-dwarf-section-macro)]
    [else -1]))

;; --- the unit being walked ---------------------------------------------------------------
(defstruct LinkerDwarfUnitContext
  (view i64)
  (unit i64)
  (offset i64)
  (end i64)
  (version i64)
  (address-size i64)
  (kind i64)
  (split? bool))

;: A decoded attribute value: the offset past it (-1 after a failure) and
;: its integer value where it has one.
(defstruct LinkerDwarfField
  (next i64)
  (value i64))

;: Record one reference, within the reference limit.
(define (linker-dwarf-reference!
  [scan : (&mut scan LinkerDwarfScan)]
  [ctx : (& ctx LinkerDwarfUnitContext)]
  [offset : i64]
  [width : i64]
  [attribute : i64]
  [form : i64]
  [op : i64]
  [class : i64]
  [target-kind : i64]
  [value : i64]) : bool
  (if (>= scan.references.len scan.limits.max-references)
    (begin
      (linker-dwarf-fail!
        scan
        linker-dwarf-error-reference-limit
        ctx.view
        ctx.offset
        offset
        "dwarf: reference limit exceeded")
      false)
    (begin
      (dwarf_reference_vec.push-ref!
        (&mut scan.references)
        (LinkerDwarfReference
          ctx.unit
          offset
          width
          attribute
          form
          op
          class
          target-kind
          value
          -1))
      true)))

;; --- DWARF expressions ---------------------------------------------------------------------
;; Operand shapes of the admitted operators. Plain operands are skipped;
;; references are recorded.
(define linker-dwarf-operand-none : i64
  0)
(define linker-dwarf-operand-1 : i64
  1)
(define linker-dwarf-operand-2 : i64
  2)
(define linker-dwarf-operand-4 : i64
  4)
(define linker-dwarf-operand-8 : i64
  8)
(define linker-dwarf-operand-uleb : i64
  10)
(define linker-dwarf-operand-sleb : i64
  11)
(define linker-dwarf-operand-uleb-uleb : i64
  12)
(define linker-dwarf-operand-uleb-sleb : i64
  13)
(define linker-dwarf-operand-address : i64
  14)
(define linker-dwarf-operand-info-ref : i64
  15)
(define linker-dwarf-operand-implicit-pointer : i64
  16)
(define linker-dwarf-operand-block : i64
  17)
(define linker-dwarf-operand-expression : i64
  18)
(define linker-dwarf-operand-unit-ref-2 : i64
  19)
(define linker-dwarf-operand-unit-ref-4 : i64
  20)
(define linker-dwarf-operand-address-index : i64
  21)
(define linker-dwarf-operand-branch : i64
  22)
(define linker-dwarf-operand-const-type : i64
  23)
(define linker-dwarf-operand-regval-type : i64
  24)
(define linker-dwarf-operand-deref-type : i64
  25)
(define linker-dwarf-operand-convert : i64
  26)

;: The operand shape of expression operator `op`, or -1 for an operator
;: this layer does not admit.
(define (linker-dwarf-operand-shape [op : i64]) : i64
  (cond
    [(= op 0x03) linker-dwarf-operand-address]
    [(or (= op 0x08) (= op 0x09) (= op 0x15) (= op 0x94) (= op 0x95))
      linker-dwarf-operand-1]
    [(or (= op 0x0a) (= op 0x0b)) linker-dwarf-operand-2]
    [(or (= op 0x0c) (= op 0x0d)) linker-dwarf-operand-4]
    [(or (= op 0x0e) (= op 0x0f)) linker-dwarf-operand-8]
    [(or (= op 0x10) (= op 0x23) (= op 0x90) (= op 0x93))
      linker-dwarf-operand-uleb]
    [(or (= op 0x11) (= op 0x91) (and (>= op 0x70) (<= op 0x8f)))
      linker-dwarf-operand-sleb]
    [(or (= op 0x28) (= op 0x2f)) linker-dwarf-operand-branch]
    [(= op 0x92) linker-dwarf-operand-uleb-sleb]
    [(= op 0x9d) linker-dwarf-operand-uleb-uleb]
    [(= op 0x98) linker-dwarf-operand-unit-ref-2]
    [(or (= op 0x99) (= op 0xfa)) linker-dwarf-operand-unit-ref-4]
    [(or (= op 0x9a) (= op 0xfd)) linker-dwarf-operand-info-ref]
    [(or (= op 0xa0) (= op 0xf2)) linker-dwarf-operand-implicit-pointer]
    [(= op 0x9e) linker-dwarf-operand-block]
    [(or (= op 0xa3) (= op 0xf3)) linker-dwarf-operand-expression]
    [(or (= op 0xa1) (= op 0xa2) (= op 0xfb) (= op 0xfc))
      linker-dwarf-operand-address-index]
    [(or (= op 0xa4) (= op 0xf4)) linker-dwarf-operand-const-type]
    [(or (= op 0xa5) (= op 0xf5)) linker-dwarf-operand-regval-type]
    [(or (= op 0xa6) (= op 0xa7) (= op 0xf6)) linker-dwarf-operand-deref-type]
    [(or (= op 0xa8) (= op 0xa9) (= op 0xf7) (= op 0xf9))
      linker-dwarf-operand-convert]
    [(or
        (= op 0x06)
        (and (>= op 0x12) (<= op 0x14))
        (and (>= op 0x16) (<= op 0x22))
        (and (>= op 0x24) (<= op 0x27))
        (and (>= op 0x29) (<= op 0x2e))
        (and (>= op 0x30) (<= op 0x6f))
        (= op 0x96)
        (= op 0x97)
        (= op 0x9b)
        (= op 0x9c)
        (= op 0x9f)
        (= op 0xe0)
        (= op 0xf0))
      linker-dwarf-operand-none]
    [else -1]))

;: Walk the expression in `[start, end)`, recording the references its
;: operands hold. `nested` counts enclosing DW_OP_entry_value operators.
(define (linker-dwarf-expression!
  [scan : (&mut scan LinkerDwarfScan)]
  [ctx : (& ctx LinkerDwarfUnitContext)]
  [start : i64]
  [end : i64]
  [attribute : i64]
  [form : i64]
  [nested : i64]) : bool
  (let
    [at : i64 start]
    (while (and scan.ok (< at end))
      (let
        [op : i64
          (byte_le.byte-le-at (& (array-ref scan.views ctx.view).bytes) at)]
        [shape : i64 (linker-dwarf-operand-shape op)]
        [operand : i64 (+ at 1)]
        (cond
          [(< shape 0)
            (linker-dwarf-fail-detail!
              scan
              linker-dwarf-error-expression
              ctx.view
              ctx.offset
              at
              op
              "dwarf: expression operator not admitted")]
          [(= shape linker-dwarf-operand-none) (set! at operand)]
          [(or
              (= shape linker-dwarf-operand-1)
              (= shape linker-dwarf-operand-2)
              (= shape linker-dwarf-operand-4)
              (= shape linker-dwarf-operand-8))
            (if (linker-dwarf-need! scan ctx.view ctx.offset operand shape end)
              (set! at (+ operand shape))
              unit)]
          [(= shape linker-dwarf-operand-branch)
            (if (linker-dwarf-need! scan ctx.view ctx.offset operand 2 end)
              (let
                [raw : i64
                  (byte_le.read-u16
                    (& (array-ref scan.views ctx.view).bytes)
                    operand)]
                [target : i64
                  (+
                    (+ operand 2)
                    (if (>= raw 32768)
                      (- raw 65536)
                      raw))]
                (if (or (< target start) (> target end))
                  (linker-dwarf-fail-detail!
                    scan
                    linker-dwarf-error-expression
                    ctx.view
                    ctx.offset
                    at
                    op
                    "dwarf: expression branch leaves the expression")
                  (set! at (+ operand 2))))
              unit)]
          [(or
              (= shape linker-dwarf-operand-uleb)
              (= shape linker-dwarf-operand-sleb))
            (set!
              at
              (linker-dwarf-leb!
                scan
                ctx.view
                ctx.offset
                operand
                end
                (= shape linker-dwarf-operand-sleb)).next)]
          [(or
              (= shape linker-dwarf-operand-uleb-uleb)
              (= shape linker-dwarf-operand-uleb-sleb))
            (let
              [first : leb128.Decoded
                (linker-dwarf-leb! scan ctx.view ctx.offset operand end false)]
              (if scan.ok
                (set!
                  at
                  (linker-dwarf-leb!
                    scan
                    ctx.view
                    ctx.offset
                    first.next
                    end
                    (= shape linker-dwarf-operand-uleb-sleb)).next)
                unit))]
          [(= shape linker-dwarf-operand-address)
            (if (linker-dwarf-need!
              scan
              ctx.view
              ctx.offset
              operand
              ctx.address-size
              end)
              (if (linker-dwarf-reference!
                scan
                ctx
                operand
                ctx.address-size
                attribute
                form
                op
                linker-dwarf-ref-address
                -1
                (linker-dwarf-read
                  (& (array-ref scan.views ctx.view).bytes)
                  operand
                  ctx.address-size))
                (set! at (+ operand ctx.address-size))
                unit)
              unit)]
          [(or
              (= shape linker-dwarf-operand-info-ref)
              (= shape linker-dwarf-operand-implicit-pointer))
            (if (and
              (linker-dwarf-need! scan ctx.view ctx.offset operand 4 end)
              (linker-dwarf-reference!
                scan
                ctx
                operand
                4
                attribute
                form
                op
                linker-dwarf-ref-info
                ctx.kind
                (byte_le.read-u32
                  (& (array-ref scan.views ctx.view).bytes)
                  operand)))
              (if (= shape linker-dwarf-operand-implicit-pointer)
                (set!
                  at
                  (linker-dwarf-leb!
                    scan
                    ctx.view
                    ctx.offset
                    (+ operand 4)
                    end
                    true).next)
                (set! at (+ operand 4)))
              unit)]
          [(or
              (= shape linker-dwarf-operand-unit-ref-2)
              (= shape linker-dwarf-operand-unit-ref-4))
            (let
              [width : i64
                (if (= shape linker-dwarf-operand-unit-ref-2)
                  2
                  4)]
              (if (and
                (linker-dwarf-need! scan ctx.view ctx.offset operand width end)
                (linker-dwarf-reference!
                  scan
                  ctx
                  operand
                  width
                  attribute
                  form
                  op
                  linker-dwarf-ref-unit
                  ctx.kind
                  (linker-dwarf-read
                    (& (array-ref scan.views ctx.view).bytes)
                    operand
                    width)))
                (set! at (+ operand width))
                unit))]
          [(= shape linker-dwarf-operand-address-index)
            (let
              [index : leb128.Decoded
                (linker-dwarf-leb! scan ctx.view ctx.offset operand end false)]
              (if (and
                scan.ok
                (linker-dwarf-reference!
                  scan
                  ctx
                  operand
                  (- index.next operand)
                  attribute
                  form
                  op
                  linker-dwarf-ref-address-index
                  linker-dwarf-section-addr
                  index.value))
                (set! at index.next)
                unit))]
          [(or
              (= shape linker-dwarf-operand-block)
              (= shape linker-dwarf-operand-expression))
            (let
              [length : leb128.Decoded
                (linker-dwarf-leb! scan ctx.view ctx.offset operand end false)]
              (cond
                [(not scan.ok) unit]
                [(not
                    (linker-dwarf-need!
                      scan
                      ctx.view
                      ctx.offset
                      length.next
                      length.value
                      end))
                  unit]
                [(= shape linker-dwarf-operand-block)
                  (set! at (+ length.next length.value))]
                [(> nested 0)
                  (linker-dwarf-fail-detail!
                    scan
                    linker-dwarf-error-expression
                    ctx.view
                    ctx.offset
                    at
                    op
                    "dwarf: nested DW_OP_entry_value")]
                [(linker-dwarf-expression!
                    scan
                    ctx
                    length.next
                    (+ length.next length.value)
                    attribute
                    form
                    (+ nested 1))
                  (set! at (+ length.next length.value))]
                [else unit]))]
          [else
            ;; Typed-stack operators name a base-type DIE by unit offset.
            (let
              [prefix : i64
                (cond [(= shape linker-dwarf-operand-deref-type) 1] [else 0])]
              [lead : leb128.Decoded
                (if (= shape linker-dwarf-operand-regval-type)
                  (linker-dwarf-leb! scan ctx.view ctx.offset operand end false)
                  (leb128.Decoded true 0 (+ operand prefix)))]
              [type-at : i64 lead.next]
              [type : leb128.Decoded
                (if (and
                  scan.ok
                  (linker-dwarf-need!
                    scan
                    ctx.view
                    ctx.offset
                    operand
                    prefix
                    end))
                  (linker-dwarf-leb! scan ctx.view ctx.offset type-at end false)
                  lead)]
              (if (and
                scan.ok
                (or
                  (= type.value 0)
                  (linker-dwarf-reference!
                    scan
                    ctx
                    type-at
                    (- type.next type-at)
                    attribute
                    form
                    op
                    linker-dwarf-ref-unit
                    ctx.kind
                    type.value)))
                (if (= shape linker-dwarf-operand-const-type)
                  (if (linker-dwarf-need!
                    scan
                    ctx.view
                    ctx.offset
                    type.next
                    1
                    end)
                    (let
                      [size : i64
                        (byte_le.byte-le-at
                          (& (array-ref scan.views ctx.view).bytes)
                          type.next)]
                      (if (linker-dwarf-need!
                        scan
                        ctx.view
                        ctx.offset
                        (+ type.next 1)
                        size
                        end)
                        (set! at (+ (+ type.next 1) size))
                        unit))
                    unit)
                  (set! at type.next))
                unit))])))
    scan.ok))

;; --- attribute values ------------------------------------------------------------------------
(define (linker-dwarf-field-fail) : LinkerDwarfField
  (LinkerDwarfField -1 0))

;: A fixed-width reference field of `width` bytes at `at`.
(define (linker-dwarf-fixed-reference!
  [scan : (&mut scan LinkerDwarfScan)]
  [ctx : (& ctx LinkerDwarfUnitContext)]
  [at : i64]
  [width : i64]
  [attribute : i64]
  [form : i64]
  [class : i64]
  [target-kind : i64]) : LinkerDwarfField
  (if (linker-dwarf-need! scan ctx.view ctx.offset at width ctx.end)
    (let
      [value : i64
        (linker-dwarf-read (& (array-ref scan.views ctx.view).bytes) at width)]
      (if (linker-dwarf-reference!
        scan
        ctx
        at
        width
        attribute
        form
        -1
        class
        target-kind
        value)
        (LinkerDwarfField (+ at width) value)
        (linker-dwarf-field-fail)))
    (linker-dwarf-field-fail)))

;: A LEB128-coded reference field at `at`.
(define (linker-dwarf-leb-reference!
  [scan : (&mut scan LinkerDwarfScan)]
  [ctx : (& ctx LinkerDwarfUnitContext)]
  [at : i64]
  [attribute : i64]
  [form : i64]
  [class : i64]
  [target-kind : i64]) : LinkerDwarfField
  (let
    [decoded : leb128.Decoded
      (linker-dwarf-leb! scan ctx.view ctx.offset at ctx.end false)]
    (if (and
      scan.ok
      (linker-dwarf-reference!
        scan
        ctx
        at
        (- decoded.next at)
        attribute
        form
        -1
        class
        target-kind
        decoded.value))
      (LinkerDwarfField decoded.next decoded.value)
      (linker-dwarf-field-fail))))

;: A plain fixed-width value at `at`.
(define (linker-dwarf-fixed-value!
  [scan : (&mut scan LinkerDwarfScan)]
  [ctx : (& ctx LinkerDwarfUnitContext)]
  [at : i64]
  [width : i64]) : LinkerDwarfField
  (if (linker-dwarf-need! scan ctx.view ctx.offset at width ctx.end)
    (LinkerDwarfField
      (+ at width)
      (if (<= width 8)
        (linker-dwarf-read (& (array-ref scan.views ctx.view).bytes) at width)
        0))
    (linker-dwarf-field-fail)))

;: A block of `length` bytes at `at`: a DWARF expression for a DWARF 3
;: expression attribute, opaque constant data otherwise. A DWARF 4/5 block
;: on an expression attribute is not admitted: its references would go
;: unchecked.
(define (linker-dwarf-block!
  [scan : (&mut scan LinkerDwarfScan)]
  [ctx : (& ctx LinkerDwarfUnitContext)]
  [at : i64]
  [length : i64]
  [attribute : i64]
  [form : i64]) : LinkerDwarfField
  (cond
    [(> length scan.limits.max-block-bytes)
      (linker-dwarf-fail-detail!
        scan
        linker-dwarf-error-block
        ctx.view
        ctx.offset
        at
        length
        "dwarf: block exceeds the block limit")
      (linker-dwarf-field-fail)]
    [(not (linker-dwarf-need! scan ctx.view ctx.offset at length ctx.end))
      (linker-dwarf-field-fail)]
    [(and (linker-dwarf-expression-attribute? attribute) (>= ctx.version 4))
      (linker-dwarf-fail-detail!
        scan
        linker-dwarf-error-attribute
        ctx.view
        ctx.offset
        at
        attribute
        "dwarf: DWARF 4/5 block form on an expression attribute")
      (linker-dwarf-field-fail)]
    [(linker-dwarf-expression-attribute? attribute)
      (if (linker-dwarf-expression! scan ctx at (+ at length) attribute form 0)
        (LinkerDwarfField (+ at length) 0)
        (linker-dwarf-field-fail))]
    [else (LinkerDwarfField (+ at length) 0)]))

;: Decode the value of `attribute` in `form` at `at`, recording the
;: references it holds. `constant` is an implicit_const value; `indirect?`
;: is true under DW_FORM_indirect.
(define (linker-dwarf-form!
  [scan : (&mut scan LinkerDwarfScan)]
  [ctx : (& ctx LinkerDwarfUnitContext)]
  [at : i64]
  [attribute : i64]
  [form : i64]
  [constant : i64]
  [indirect? : bool]) : LinkerDwarfField
  (cond
    [(= form 0x01)
      (linker-dwarf-fixed-reference!
        scan
        ctx
        at
        ctx.address-size
        attribute
        form
        linker-dwarf-ref-address
        -1)]
    [(or (= form 0x0b) (= form 0x05) (= form 0x06) (= form 0x07) (= form 0x1e))
      (let
        [width : i64
          (cond
            [(= form 0x0b) 1]
            [(= form 0x05) 2]
            [(= form 0x06) 4]
            [(= form 0x07) 8]
            [else 16])]
        [target : i64
          (if (and
            (= ctx.version 3)
            (or (= width 4) (= width 8))
            (or
              (= attribute 0x10)
              (= attribute 0x55)
              (= attribute 0x43)
              (linker-dwarf-loclist-attribute? attribute)))
            (linker-dwarf-offset-target attribute ctx.version ctx.split?)
            -1)]
        (if (>= target 0)
          (linker-dwarf-fixed-reference!
            scan
            ctx
            at
            width
            attribute
            form
            linker-dwarf-ref-section-offset
            target)
          (linker-dwarf-fixed-value! scan ctx at width)))]
    [(or (= form 0x0a) (= form 0x03) (= form 0x04) (= form 0x09))
      (let
        [prefix : i64
          (cond [(= form 0x0a) 1] [(= form 0x03) 2] [(= form 0x04) 4] [else 0])]
        [length : leb128.Decoded
          (if (= prefix 0)
            (linker-dwarf-leb! scan ctx.view ctx.offset at ctx.end false)
            (if (linker-dwarf-need! scan ctx.view ctx.offset at prefix ctx.end)
              (leb128.Decoded
                true
                (linker-dwarf-read
                  (& (array-ref scan.views ctx.view).bytes)
                  at
                  prefix)
                (+ at prefix))
              (leb128.Decoded false 0 at)))]
        (if scan.ok
          (linker-dwarf-block! scan ctx length.next length.value attribute form)
          (linker-dwarf-field-fail)))]
    [(= form 0x18)
      (let
        [length : leb128.Decoded
          (linker-dwarf-leb! scan ctx.view ctx.offset at ctx.end false)]
        (cond
          [(not scan.ok) (linker-dwarf-field-fail)]
          [(> length.value scan.limits.max-block-bytes)
            (linker-dwarf-fail-detail!
              scan
              linker-dwarf-error-block
              ctx.view
              ctx.offset
              at
              length.value
              "dwarf: expression exceeds the block limit")
            (linker-dwarf-field-fail)]
          [(not
              (linker-dwarf-need!
                scan
                ctx.view
                ctx.offset
                length.next
                length.value
                ctx.end))
            (linker-dwarf-field-fail)]
          [(linker-dwarf-expression!
              scan
              ctx
              length.next
              (+ length.next length.value)
              attribute
              form
              0)
            (LinkerDwarfField (+ length.next length.value) 0)]
          [else (linker-dwarf-field-fail)]))]
    [(= form 0x08)
      (let
        [end-at : i64 at]
        (while (and
          (< end-at ctx.end)
          (!=
            (byte_le.byte-le-at
              (& (array-ref scan.views ctx.view).bytes)
              end-at)
            0))
          (+= end-at 1))
        (if (< end-at ctx.end)
          (LinkerDwarfField (+ end-at 1) 0)
          (begin
            (linker-dwarf-fail!
              scan
              linker-dwarf-error-string
              ctx.view
              ctx.offset
              at
              "dwarf: inline string is not terminated inside its unit")
            (linker-dwarf-field-fail))))]
    [(= form 0x0c) (linker-dwarf-fixed-value! scan ctx at 1)]
    [(= form 0x19) (LinkerDwarfField at 1)]
    [(or (= form 0x0d) (= form 0x0f))
      (let
        [decoded : leb128.Decoded
          (linker-dwarf-leb! scan ctx.view ctx.offset at ctx.end (= form 0x0d))]
        (if scan.ok
          (LinkerDwarfField decoded.next decoded.value)
          (linker-dwarf-field-fail)))]
    [(= form 0x0e)
      (linker-dwarf-fixed-reference!
        scan
        ctx
        at
        4
        attribute
        form
        linker-dwarf-ref-string
        (if ctx.split?
          linker-dwarf-section-str-dwo
          linker-dwarf-section-str))]
    [(= form 0x1f)
      (linker-dwarf-fixed-reference!
        scan
        ctx
        at
        4
        attribute
        form
        linker-dwarf-ref-line-string
        linker-dwarf-section-line-str)]
    [(= form 0x10)
      (linker-dwarf-fixed-reference!
        scan
        ctx
        at
        4
        attribute
        form
        linker-dwarf-ref-info
        ctx.kind)]
    [(or (= form 0x11) (= form 0x12) (= form 0x13) (= form 0x14))
      (linker-dwarf-fixed-reference!
        scan
        ctx
        at
        (cond [(= form 0x11) 1] [(= form 0x12) 2] [(= form 0x13) 4] [else 8])
        attribute
        form
        linker-dwarf-ref-unit
        ctx.kind)]
    [(= form 0x15)
      (linker-dwarf-leb-reference!
        scan
        ctx
        at
        attribute
        form
        linker-dwarf-ref-unit
        ctx.kind)]
    [(= form 0x20)
      (linker-dwarf-fixed-reference!
        scan
        ctx
        at
        8
        attribute
        form
        linker-dwarf-ref-signature
        -1)]
    [(= form 0x17)
      (let
        [target : i64
          (linker-dwarf-offset-target attribute ctx.version ctx.split?)]
        (if (< target 0)
          (begin
            (linker-dwarf-fail-detail!
              scan
              linker-dwarf-error-attribute
              ctx.view
              ctx.offset
              at
              attribute
              "dwarf: section offset on an attribute with no known target section")
            (linker-dwarf-field-fail))
          (linker-dwarf-fixed-reference!
            scan
            ctx
            at
            4
            attribute
            form
            linker-dwarf-ref-section-offset
            target)))]
    [(or (= form 0x1a) (= form 0x1f02))
      (linker-dwarf-leb-reference!
        scan
        ctx
        at
        attribute
        form
        linker-dwarf-ref-string-index
        (if ctx.split?
          linker-dwarf-section-str-offsets-dwo
          linker-dwarf-section-str-offsets))]
    [(and (>= form 0x25) (<= form 0x28))
      (linker-dwarf-fixed-reference!
        scan
        ctx
        at
        (- form 0x24)
        attribute
        form
        linker-dwarf-ref-string-index
        (if ctx.split?
          linker-dwarf-section-str-offsets-dwo
          linker-dwarf-section-str-offsets))]
    [(or (= form 0x1b) (= form 0x1f01))
      (linker-dwarf-leb-reference!
        scan
        ctx
        at
        attribute
        form
        linker-dwarf-ref-address-index
        linker-dwarf-section-addr)]
    [(and (>= form 0x29) (<= form 0x2c))
      (linker-dwarf-fixed-reference!
        scan
        ctx
        at
        (- form 0x28)
        attribute
        form
        linker-dwarf-ref-address-index
        linker-dwarf-section-addr)]
    [(= form 0x22)
      (linker-dwarf-leb-reference!
        scan
        ctx
        at
        attribute
        form
        linker-dwarf-ref-loclist-index
        (if ctx.split?
          linker-dwarf-section-loclists-dwo
          linker-dwarf-section-loclists))]
    [(= form 0x23)
      (linker-dwarf-leb-reference!
        scan
        ctx
        at
        attribute
        form
        linker-dwarf-ref-rnglist-index
        (if ctx.split?
          linker-dwarf-section-rnglists-dwo
          linker-dwarf-section-rnglists))]
    [(= form 0x21)
      (if indirect?
        (begin
          (linker-dwarf-fail-detail!
            scan
            linker-dwarf-error-form
            ctx.view
            ctx.offset
            at
            form
            "dwarf: DW_FORM_indirect names DW_FORM_implicit_const")
          (linker-dwarf-field-fail))
        (LinkerDwarfField at constant))]
    [(= form 0x16)
      (let
        [actual : leb128.Decoded
          (linker-dwarf-leb! scan ctx.view ctx.offset at ctx.end false)]
        (cond
          [(not scan.ok) (linker-dwarf-field-fail)]
          [(or indirect? (= actual.value 0x16))
            (linker-dwarf-fail-detail!
              scan
              linker-dwarf-error-form
              ctx.view
              ctx.offset
              at
              actual.value
              "dwarf: DW_FORM_indirect names DW_FORM_indirect")
            (linker-dwarf-field-fail)]
          [(not (linker-dwarf-known-form? actual.value))
            (linker-dwarf-fail-detail!
              scan
              linker-dwarf-error-form
              ctx.view
              ctx.offset
              at
              actual.value
              "dwarf: unknown attribute form")
            (linker-dwarf-field-fail)]
          [else
            (linker-dwarf-form!
              scan
              ctx
              actual.next
              attribute
              actual.value
              0
              true)]))]
    [else
      ;; DW_FORM_ref_sup4/8, DW_FORM_strp_sup and the GNU alt forms name a
      ;; supplementary file this layer does not take.
      (linker-dwarf-fail-detail!
        scan
        linker-dwarf-error-form
        ctx.view
        ctx.offset
        at
        form
        "dwarf: supplementary-file form not admitted")
      (linker-dwarf-field-fail)]))

;; --- units ---------------------------------------------------------------------------------
;: Whether unit version `version` is admitted in a section of `kind`.
(define (linker-dwarf-version-admitted? [kind : i64] [version : i64]) : bool
  (cond
    [(= kind linker-dwarf-section-info) (and (>= version 3) (<= version 5))]
    [(= kind linker-dwarf-section-info-dwo) (or (= version 4) (= version 5))]
    [else (= version 4)]))

;: Whether DWARF 5 unit type `unit-type` is admitted in a section of `kind`.
(define (linker-dwarf-unit-type-admitted? [kind : i64] [unit-type : i64]) : bool
  (if (= kind linker-dwarf-section-info)
    (and (>= unit-type 1) (<= unit-type 4))
    (or (= unit-type 5) (= unit-type 6))))

;: The index of the DIE of unit `unit` (whose DIEs start at `first` and
;: number `count`) at section offset `absolute`, or -1.
(define (linker-dwarf-die-index
  [scan : (& scan LinkerDwarfScan)]
  [first : i64]
  [count : i64]
  [absolute : i64]) : i64
  (let
    [low : i64 first]
    [high : i64 (+ first count)]
    (while (< low high)
      (let
        [middle : i64 (+ low (/ (- high low) 2))]
        (if (< (array-ref scan.die-offsets.slots middle) absolute)
          (set! low (+ middle 1))
          (set! high middle))))
    (if (and
      (< low (+ first count))
      (= (array-ref scan.die-offsets.slots low) absolute))
      low
      -1)))

;: Scan the unit at `offset` of unit view `view`: its header, abbreviation
;: table and every DIE. Returns the offset past the unit, or -1.
(define (linker-dwarf-scan-unit!
  [scan : (&mut scan LinkerDwarfScan)]
  [view : i64]
  [offset : i64]) : i64
  (let
    [length : i64 (array-length (array-ref scan.views view).bytes)]
    [input : i64 (array-ref scan.views view).input]
    [kind : i64 (array-ref scan.views view).kind]
    [split? : bool (linker-dwarf-split-section? kind)]
    [types? : bool
      (or
        (= kind linker-dwarf-section-types)
        (= kind linker-dwarf-section-types-dwo))]
    (when
      (>= scan.units.len scan.limits.max-units)
      (linker-dwarf-fail!
        scan
        linker-dwarf-error-unit-limit
        view
        offset
        offset
        "dwarf: unit limit exceeded")
      (return -1))
    (when
      (not (linker-dwarf-need! scan view offset offset 6 length))
      (return -1))
    (let
      [unit-length : i64
        (byte_le.read-u32 (& (array-ref scan.views view).bytes) offset)]
      [version : i64
        (byte_le.read-u16 (& (array-ref scan.views view).bytes) (+ offset 4))]
      [end : i64 (+ (+ offset 4) unit-length)]
      (when
        (>= unit-length 0xfffffff0)
        (linker-dwarf-fail-detail!
          scan
          (if (= unit-length 0xffffffff)
            linker-dwarf-error-dwarf64
            linker-dwarf-error-unit)
          view
          offset
          offset
          unit-length
          "dwarf: DWARF64 or reserved unit length")
        (return -1))
      (when
        (> end length)
        (linker-dwarf-fail-detail!
          scan
          linker-dwarf-error-truncated
          view
          offset
          offset
          unit-length
          "dwarf: unit runs past the end of its section")
        (return -1))
      (when
        (not (linker-dwarf-version-admitted? kind version))
        (linker-dwarf-fail-detail!
          scan
          linker-dwarf-error-version
          view
          offset
          (+ offset 4)
          version
          "dwarf: unit version not admitted for its section")
        (return -1))
      (let
        [v5? : bool (= version 5)]
        [fixed : i64 (cond [v5? 12] [types? 23] [else 11])]
        (when
          (not (linker-dwarf-need! scan view offset offset fixed end))
          (return -1))
        (let
          [unit-type : i64
            (cond
              [v5?
                (byte_le.byte-le-at
                  (& (array-ref scan.views view).bytes)
                  (+ offset 6))]
              [(= kind linker-dwarf-section-types) 2]
              [(= kind linker-dwarf-section-types-dwo) 6]
              [(= kind linker-dwarf-section-info-dwo) 5]
              [else 1])]
          [address-size : i64
            (byte_le.byte-le-at
              (& (array-ref scan.views view).bytes)
              (if v5?
                (+ offset 7)
                (+ offset 10)))]
          [abbrev-offset : i64
            (byte_le.read-u32
              (& (array-ref scan.views view).bytes)
              (if v5?
                (+ offset 8)
                (+ offset 6)))]
          [extra : i64
            (cond
              [(not v5?) 0]
              [(or (= unit-type 4) (= unit-type 5)) 8]
              [(or (= unit-type 2) (= unit-type 6)) 12]
              [else 0])]
          [die-offset : i64 (+ (+ offset fixed) extra)]
          (when
            (and v5? (not (linker-dwarf-unit-type-admitted? kind unit-type)))
            (linker-dwarf-fail-detail!
              scan
              linker-dwarf-error-unit-type
              view
              offset
              (+ offset 6)
              unit-type
              "dwarf: unit type not admitted for its section")
            (return -1))
          (when
            (not (or (= address-size 4) (= address-size 8)))
            (linker-dwarf-fail-detail!
              scan
              linker-dwarf-error-unit
              view
              offset
              offset
              address-size
              "dwarf: address size is neither 4 nor 8")
            (return -1))
          (when
            (not
              (linker-dwarf-need!
                scan
                view
                offset
                offset
                (- die-offset offset)
                end))
            (return -1))
          (let
            ;; Only skeleton, split and type units carry an 8-byte id
            ;; or signature; the header check above covered it.
            [id-at : i64
              (cond
                [(and v5? (> extra 0)) (+ offset 12)]
                [types? (+ offset 11)]
                [else -1])]
            [identity : i64
              (if (>= id-at 0)
                (byte_le.read-u64 (& (array-ref scan.views view).bytes) id-at)
                0)]
            [type-offset : i64
              (cond
                [(and v5? (= extra 12))
                  (byte_le.read-u32
                    (& (array-ref scan.views view).bytes)
                    (+ offset 20))]
                [types?
                  (byte_le.read-u32
                    (& (array-ref scan.views view).bytes)
                    (+ offset 19))]
                [else -1])]
            [abbrev-view : i64
              (linker-dwarf-find-view
                scan
                input
                (if split?
                  linker-dwarf-section-abbrev-dwo
                  linker-dwarf-section-abbrev))]
            (when
              (< abbrev-view 0)
              (linker-dwarf-fail-detail!
                scan
                linker-dwarf-error-missing-section
                view
                offset
                (if v5?
                  (+ offset 8)
                  (+ offset 6))
                (if split?
                  linker-dwarf-section-abbrev-dwo
                  linker-dwarf-section-abbrev)
                "dwarf: unit needs an abbreviation section that was not supplied")
              (return -1))
            (let
              [table : i64
                (linker-dwarf-abbrev-table!
                  scan
                  abbrev-view
                  abbrev-offset
                  offset)]
              [ctx : LinkerDwarfUnitContext
                (LinkerDwarfUnitContext
                  view
                  scan.units.len
                  offset
                  end
                  version
                  address-size
                  kind
                  split?)]
              (if (< table 0)
                -1
                (linker-dwarf-walk-unit!
                  scan
                  (& ctx)
                  table
                  die-offset
                  unit-type
                  abbrev-offset
                  (if (or (= extra 8) (= extra 12))
                    identity
                    0)
                  (= extra 8)
                  (if types?
                    identity
                    (if (= extra 12)
                      identity
                      0))
                  type-offset
                  (if v5?
                    (+ offset 8)
                    (+ offset 6))
                  (array-ref scan.views view).relocatable)))))))))

;: Walk the DIEs of the unit in `ctx` from `die-offset` and register the unit.
(define (linker-dwarf-walk-unit!
  [scan : (&mut scan LinkerDwarfScan)]
  [ctx : (& ctx LinkerDwarfUnitContext)]
  [table : i64]
  [die-offset : i64]
  [header-type : i64]
  [abbrev-offset : i64]
  [header-id : i64]
  [has-header-id : bool]
  [signature : i64]
  [type-offset : i64]
  [abbrev-field : i64]
  [relocatable : bool]) : i64
  (let
    [at : i64 die-offset]
    [depth : i64 0]
    [count : i64 0]
    [first : i64 scan.die-offsets.len]
    [root-tag : i64 0]
    [str-offsets-base : i64 -1]
    [addr-base : i64 -1]
    [rnglists-base : i64 -1]
    [loclists-base : i64 -1]
    [ranges-base : i64 -1]
    [gnu-id : i64 0]
    [has-gnu-id : bool false]
    (when
      (not
        (linker-dwarf-charge! scan (- ctx.end ctx.offset) ctx.view ctx.offset))
      (return -1))
    ;; The header's abbreviation offset is itself a relocatable section
    ;; offset; attribute and form -1 mark a header field.
    (when
      (not
        (linker-dwarf-reference!
          scan
          ctx
          abbrev-field
          4
          -1
          -1
          -1
          linker-dwarf-ref-section-offset
          (if ctx.split?
            linker-dwarf-section-abbrev-dwo
            linker-dwarf-section-abbrev)
          abbrev-offset))
      (return -1))
    (while (and scan.ok (< at ctx.end))
      (let
        [code : leb128.Decoded
          (linker-dwarf-leb! scan ctx.view ctx.offset at ctx.end false)]
        (cond
          [(not scan.ok) unit]
          [(= code.value 0)
            (if (> depth 0)
              (-= depth 1)
              unit)
            (set! at code.next)]
          [(and (> count 0) (= depth 0))
            (linker-dwarf-fail!
              scan
              linker-dwarf-error-nesting
              ctx.view
              ctx.offset
              at
              "dwarf: a second top-level DIE follows the unit's root")]
          [else
            (let
              [entry : i64 (linker-dwarf-abbrev-entry scan table code.value)]
              (cond
                [(< entry 0)
                  (linker-dwarf-fail-detail!
                    scan
                    linker-dwarf-error-abbrev-code
                    ctx.view
                    ctx.offset
                    at
                    code.value
                    "dwarf: DIE names an abbreviation code its table does not define")]
                [(>= scan.dies scan.limits.max-dies)
                  (linker-dwarf-fail!
                    scan
                    linker-dwarf-error-die-limit
                    ctx.view
                    ctx.offset
                    at
                    "dwarf: DIE limit exceeded")]
                [else
                  (let
                    [spec : i64 (array-ref scan.entry-first-spec.slots entry)]
                    [spec-end : i64
                      (+
                        (array-ref scan.entry-first-spec.slots entry)
                        (array-ref scan.entry-specs.slots entry))]
                    [pos : i64 code.next]
                    [root? : bool (= count 0)]
                    (dwarf_i64_vec.push-ref! (&mut scan.die-offsets) at)
                    (+= scan.dies 1)
                    (+= count 1)
                    (if root?
                      (set! root-tag (array-ref scan.entry-tag.slots entry))
                      unit)
                    (while (and scan.ok (< spec spec-end))
                      (if (>= scan.attributes scan.limits.max-attributes)
                        (linker-dwarf-fail!
                          scan
                          linker-dwarf-error-attribute-limit
                          ctx.view
                          ctx.offset
                          pos
                          "dwarf: attribute limit exceeded")
                        (let
                          [attribute : i64
                            (array-ref scan.spec-attribute.slots spec)]
                          [field : LinkerDwarfField
                            (linker-dwarf-form!
                              scan
                              ctx
                              pos
                              attribute
                              (array-ref scan.spec-form.slots spec)
                              (array-ref scan.spec-const.slots spec)
                              false)]
                          (+= scan.attributes 1)
                          (if (and root? (>= field.next 0))
                            (cond
                              [(= attribute 0x72)
                                (set! str-offsets-base field.value)]
                              [(or (= attribute 0x73) (= attribute 0x2133))
                                (set! addr-base field.value)]
                              [(= attribute 0x74)
                                (set! rnglists-base field.value)]
                              [(= attribute 0x8c)
                                (set! loclists-base field.value)]
                              [(= attribute 0x2132)
                                (set! ranges-base field.value)]
                              [(= attribute 0x2131)
                                (set! gnu-id field.value)
                                (set! has-gnu-id true)]
                              [else unit])
                            unit)
                          (set! pos field.next)
                          (+= spec 1))))
                    (if (and
                      scan.ok
                      (= (array-ref scan.entry-children.slots entry) 1))
                      (if (>= depth scan.limits.max-depth)
                        (linker-dwarf-fail!
                          scan
                          linker-dwarf-error-depth-limit
                          ctx.view
                          ctx.offset
                          at
                          "dwarf: DIE nesting limit exceeded")
                        (+= depth 1))
                      unit)
                    (set! at pos))]))])))
    (cond
      [(not scan.ok) -1]
      [(= count 0)
        (linker-dwarf-fail!
          scan
          linker-dwarf-error-unit
          ctx.view
          ctx.offset
          die-offset
          "dwarf: unit has no root DIE")
        -1]
      [(> depth 0)
        (linker-dwarf-fail-detail!
          scan
          linker-dwarf-error-nesting
          ctx.view
          ctx.offset
          ctx.end
          depth
          "dwarf: unit ends inside an open sibling list")
        -1]
      [(and
        (>= type-offset 0)
        (<
          (linker-dwarf-die-index scan first count (+ ctx.offset type-offset))
          0))
        (linker-dwarf-fail-detail!
          scan
          linker-dwarf-error-reference
          ctx.view
          ctx.offset
          ctx.offset
          type-offset
          "dwarf: type unit's type offset is not a DIE of the unit")
        -1]
      [(and has-header-id has-gnu-id (!= header-id gnu-id))
        (linker-dwarf-fail!
          scan
          linker-dwarf-error-split
          ctx.view
          ctx.offset
          ctx.offset
          "dwarf: unit header and DW_AT_GNU_dwo_id disagree")
        -1]
      [else
        (let
          [unit-type : i64
            (cond
              [(and (= header-type 1) (= root-tag 0x3c)) 3]
              [(and (= header-type 1) (= ctx.version 4) has-gnu-id) 4]
              [else header-type])]
          [has-id : bool (or has-header-id has-gnu-id)]
          (dwarf_unit_vec.push-ref!
            (&mut scan.units)
            (LinkerDwarfUnit
              (array-ref scan.views ctx.view).input
              (array-ref scan.views ctx.view).section
              ctx.kind
              relocatable
              ctx.offset
              ctx.end
              ctx.version
              unit-type
              ctx.address-size
              abbrev-offset
              die-offset
              first
              count
              root-tag
              signature
              type-offset
              (if has-header-id
                header-id
                gnu-id)
              has-id
              str-offsets-base
              addr-base
              rnglists-base
              loclists-base
              ranges-base
              -1))
          (dwarf_i64_vec.push-ref! (&mut scan.unit-views) ctx.view)
          ctx.end)])))

;; --- ordering ------------------------------------------------------------------------------
;: Whether position `a` sorts before position `b` by (`primary`, `secondary`,
;: position).
(define (linker-dwarf-before?
  [primary : (& primary (__tl_dyn-array i64))]
  [secondary : (& secondary (__tl_dyn-array i64))]
  [a : i64]
  [b : i64]) : bool
  (cond
    [(!= (array-ref primary a) (array-ref primary b))
      (< (array-ref primary a) (array-ref primary b))]
    [(!= (array-ref secondary a) (array-ref secondary b))
      (< (array-ref secondary a) (array-ref secondary b))]
    [else (< a b)]))

(define (linker-dwarf-sift!
  [primary : (& primary (__tl_dyn-array i64))]
  [secondary : (& secondary (__tl_dyn-array i64))]
  [order : (&mut order (__tl_dyn-array i64))]
  [root : i64]
  [count : i64]) : unit
  (let
    [node : i64 root]
    [done : bool false]
    (while (not done)
      (let
        [child : i64 (+ (* node 2) 1)]
        (if (>= child count)
          (set! done true)
          (let
            [larger : i64
              (if (and
                (< (+ child 1) count)
                (linker-dwarf-before?
                  primary
                  secondary
                  (array-ref order child)
                  (array-ref order (+ child 1))))
                (+ child 1)
                child)]
            (if (linker-dwarf-before?
              primary
              secondary
              (array-ref order node)
              (array-ref order larger))
              (let
                [held : i64 (array-ref order node)]
                (set! (array-ref order node) (array-ref order larger))
                (set! (array-ref order larger) held)
                (set! node larger))
              (set! done true))))))))

;: The positions 0..count-1 ordered by (`primary`, `secondary`, position).
(define (linker-dwarf-order
  [primary : (& primary (__tl_dyn-array i64))]
  [secondary : (& secondary (__tl_dyn-array i64))]
  [count : i64]) : (__tl_dyn-array i64)
  (let
    [order : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [index : i64 0]
    (while (< index count)
      (set! (array-ref order index) index)
      (+= index 1))
    (set! index (- (/ count 2) 1))
    (while (>= index 0)
      (linker-dwarf-sift! primary secondary (&mut order) index count)
      (-= index 1))
    (set! index (- count 1))
    (while (> index 0)
      (let
        [held : i64 (array-ref order 0)]
        (set! (array-ref order 0) (array-ref order index))
        (set! (array-ref order index) held)
        (linker-dwarf-sift! primary secondary (&mut order) 0 index)
        (-= index 1)))
    order))

;; --- split units ----------------------------------------------------------------------------
;: Pair every split compile unit with the one skeleton unit that carries its
;: dwo id. Two skeletons, or two split units, sharing an id fail.
(define (linker-dwarf-pair-skeletons! [scan : (&mut scan LinkerDwarfScan)]) : unit
  (let
    [count : i64 scan.units.len]
    [ids : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [split : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    (for [index (iterator.range 0 count)]
      (set! (array-ref ids index) (array-ref scan.units.slots index).dwo-id)
      (set!
        (array-ref split index)
        (cond
          [(not (array-ref scan.units.slots index).has-id) 2]
          [(= (array-ref scan.units.slots index).unit-type 5) 1]
          [(= (array-ref scan.units.slots index).unit-type 4) 0]
          [else 2])))
    (let
      [order : (__tl_dyn-array i64)
        (linker-dwarf-order (& ids) (& split) count)]
      [run : i64 0]
      (while (and scan.ok (< run count))
        (let
          [id : i64 (array-ref ids (array-ref order run))]
          [end : i64 run]
          [skeleton : i64 -1]
          [unit-index : i64 -1]
          (while (and
            (< end count)
            (= (array-ref ids (array-ref order end)) id))
            (let
              [member : i64 (array-ref order end)]
              (cond
                [(= (array-ref split member) 0)
                  (if (>= skeleton 0)
                    (linker-dwarf-fail!
                      scan
                      linker-dwarf-error-split
                      (array-ref scan.unit-views.slots member)
                      (array-ref scan.units.slots member).offset
                      (array-ref scan.units.slots member).offset
                      "dwarf: two skeleton units carry one dwo id")
                    (set! skeleton member))]
                [(= (array-ref split member) 1)
                  (if (>= unit-index 0)
                    (linker-dwarf-fail!
                      scan
                      linker-dwarf-error-split
                      (array-ref scan.unit-views.slots member)
                      (array-ref scan.units.slots member).offset
                      (array-ref scan.units.slots member).offset
                      "dwarf: two split units carry one dwo id")
                    (set! unit-index member))]
                [else unit])
              (+= end 1)))
          (if (and scan.ok (>= skeleton 0) (>= unit-index 0))
            (linker-dwarf-set-skeleton! scan unit-index skeleton)
            unit)
          (set! run end))))))

;: Rewrite unit `index` with skeleton `skeleton`.
(define (linker-dwarf-set-skeleton!
  [scan : (&mut scan LinkerDwarfScan)]
  [index : i64]
  [skeleton : i64]) : unit
  (let
    [old : LinkerDwarfUnit (array-ref scan.units.slots index)]
    (set!
      (array-ref scan.units.slots index)
      (LinkerDwarfUnit
        old.input
        old.section
        old.kind
        old.relocatable
        old.offset
        old.end
        old.version
        old.unit-type
        old.address-size
        old.abbrev-offset
        old.die-offset
        old.first-die
        old.die-count
        old.root-tag
        old.signature
        old.type-offset
        old.dwo-id
        old.has-id
        old.str-offsets-base
        old.addr-base
        old.rnglists-base
        old.loclists-base
        old.ranges-base
        skeleton))))

;; --- reference checks --------------------------------------------------------------------------
;: The unit of view `view` whose extent holds section offset `absolute`, or -1.
(define (linker-dwarf-unit-at
  [scan : (& scan LinkerDwarfScan)]
  [view : i64]
  [absolute : i64]) : i64
  (let
    [low : i64 0]
    [high : i64 scan.units.len]
    ;; Units are stored in canonical view order and, within a view, by
    ;; offset, so (view, end) increases along the array.
    (while (< low high)
      (let
        [middle : i64 (+ low (/ (- high low) 2))]
        (if (or
          (< (array-ref scan.unit-views.slots middle) view)
          (and
            (= (array-ref scan.unit-views.slots middle) view)
            (<= (array-ref scan.units.slots middle).end absolute)))
          (set! low (+ middle 1))
          (set! high middle))))
    (if (and
      (< low scan.units.len)
      (= (array-ref scan.unit-views.slots low) view)
      (<= (array-ref scan.units.slots low).offset absolute))
      low
      -1)))

;: Whether a NUL-terminated string starts at `offset` of view `view`.
(define (linker-dwarf-string-at?
  [scan : (&mut scan LinkerDwarfScan)]
  [view : i64]
  [offset : i64]) : bool
  (let
    [length : i64 (array-length (array-ref scan.views view).bytes)]
    [at : i64 offset]
    (if (or (< offset 0) (>= offset length))
      false
      (begin
        (while (and
          (< at length)
          (!= (byte_le.byte-le-at (& (array-ref scan.views view).bytes) at) 0))
          (+= at 1))
        (and
          (< at length)
          (linker-dwarf-charge! scan (+ (- at offset) 1) view offset))))))

;: The view of `input` in family `kind`, recording a missing-section failure
;: against reference `reference` of unit `unit` when there is none.
(define (linker-dwarf-target-view!
  [scan : (&mut scan LinkerDwarfScan)]
  [unit-index : i64]
  [reference : i64]
  [input : i64]
  [kind : i64]) : i64
  (let
    [view : i64 (linker-dwarf-find-view scan input kind)]
    (if (< view 0)
      (linker-dwarf-fail-detail!
        scan
        linker-dwarf-error-missing-section
        (array-ref scan.unit-views.slots unit-index)
        (array-ref scan.units.slots unit-index).offset
        (array-ref scan.references.slots reference).offset
        kind
        "dwarf: a reference targets a section that was not supplied")
      unit)
    view))

;: Record a failed check of reference `reference`.
(define (linker-dwarf-reference-fail!
  [scan : (&mut scan LinkerDwarfScan)]
  [reference : i64]
  [code : i64]
  [message : String]) : unit
  (let
    [owner : i64 (array-ref scan.references.slots reference).unit]
    (linker-dwarf-fail-detail!
      scan
      code
      (array-ref scan.unit-views.slots owner)
      (array-ref scan.units.slots owner).offset
      (array-ref scan.references.slots reference).offset
      (array-ref scan.references.slots reference).value
      message)))

;: Resolve a list index against the offset table at `base` of `view`.
(define (linker-dwarf-check-list-index!
  [scan : (&mut scan LinkerDwarfScan)]
  [reference : i64]
  [view : i64]
  [base : i64]) : unit
  (let
    [index : i64 (array-ref scan.references.slots reference).value]
    (if (or
      (< base 4)
      (> base (array-length (array-ref scan.views view).bytes))
      (< index 0)
      (>=
        index
        (byte_le.read-u32 (& (array-ref scan.views view).bytes) (- base 4))))
      (linker-dwarf-reference-fail!
        scan
        reference
        linker-dwarf-error-index
        "dwarf: list index outside its offset table")
      unit)))

;: Check reference `reference` and set its resolved target.
(define (linker-dwarf-check-reference!
  [scan : (&mut scan LinkerDwarfScan)]
  [reference : i64]
  [signatures : (& signatures (__tl_dyn-array i64))]
  [signature-order : (& signature-order (__tl_dyn-array i64))]) : unit
  (let
    [ref : LinkerDwarfReference (array-ref scan.references.slots reference)]
    [record : LinkerDwarfUnit (array-ref scan.units.slots ref.unit)]
    [view : i64 (array-ref scan.unit-views.slots ref.unit)]
    [skeleton : i64 record.skeleton]
    [split? : bool (linker-dwarf-split-section? record.kind)]
    [target : i64 -1]
    (cond
      [(= ref.class linker-dwarf-ref-unit)
        (if (<
          (linker-dwarf-die-index
            scan
            record.first-die
            record.die-count
            (+ record.offset ref.value))
          0)
          (linker-dwarf-reference-fail!
            scan
            reference
            linker-dwarf-error-reference
            "dwarf: unit reference does not name a DIE of its unit")
          (set! target ref.unit))]
      [(= ref.class linker-dwarf-ref-info)
        (if record.relocatable
          unit
          (let
            [holder : i64 (linker-dwarf-unit-at scan view ref.value)]
            (if (or
              (< holder 0)
              (<
                (linker-dwarf-die-index
                  scan
                  (array-ref scan.units.slots holder).first-die
                  (array-ref scan.units.slots holder).die-count
                  ref.value)
                0))
              (linker-dwarf-reference-fail!
                scan
                reference
                linker-dwarf-error-reference
                "dwarf: section reference does not name a DIE")
              (set! target holder))))]
      [(= ref.class linker-dwarf-ref-signature)
        (let
          [low : i64 0]
          [high : i64 (array-length signature-order)]
          (while (< low high)
            (let
              [middle : i64 (+ low (/ (- high low) 2))]
              (if (<
                (array-ref signatures (array-ref signature-order middle))
                ref.value)
                (set! low (+ middle 1))
                (set! high middle))))
          (if (and
            (< low (array-length signature-order))
            (= (array-ref signatures (array-ref signature-order low)) ref.value))
            (set! target (array-ref signature-order low))
            unit))]
      [(or
          (= ref.class linker-dwarf-ref-string)
          (= ref.class linker-dwarf-ref-line-string))
        (let
          [strings : i64
            (linker-dwarf-target-view!
              scan
              ref.unit
              reference
              record.input
              ref.target-kind)]
          (if (and
            (>= strings 0)
            (not record.relocatable)
            (not (linker-dwarf-string-at? scan strings ref.value)))
            (linker-dwarf-reference-fail!
              scan
              reference
              linker-dwarf-error-string
              "dwarf: string offset does not start a terminated string")
            unit))]
      [(= ref.class linker-dwarf-ref-string-index)
        (let
          [base : i64
            (cond
              [(not split?) record.str-offsets-base]
              [(= record.version 5) 8]
              [else 0])]
          [table : i64
            (if (< base 0)
              -1
              (linker-dwarf-target-view!
                scan
                ref.unit
                reference
                record.input
                ref.target-kind))]
          (cond
            [(< base 0)
              (linker-dwarf-reference-fail!
                scan
                reference
                linker-dwarf-error-index
                "dwarf: string index in a unit without DW_AT_str_offsets_base")]
            [(< table 0) unit]
            [(and (not split?) record.relocatable) unit]
            [(or
                (< ref.value 0)
                (>
                  (+ (+ base (* ref.value 4)) 4)
                  (array-length (array-ref scan.views table).bytes)))
              (linker-dwarf-reference-fail!
                scan
                reference
                linker-dwarf-error-index
                "dwarf: string index outside the string offsets table")]
            [(array-ref scan.views table).relocatable unit]
            [else
              (let
                [strings : i64
                  (linker-dwarf-target-view!
                    scan
                    ref.unit
                    reference
                    record.input
                    (if split?
                      linker-dwarf-section-str-dwo
                      linker-dwarf-section-str))]
                (if (and
                  (>= strings 0)
                  (not
                    (linker-dwarf-string-at?
                      scan
                      strings
                      (byte_le.read-u32
                        (& (array-ref scan.views table).bytes)
                        (+ base (* ref.value 4))))))
                  (linker-dwarf-reference-fail!
                    scan
                    reference
                    linker-dwarf-error-string
                    "dwarf: string offsets entry does not start a terminated string")
                  unit))]))]
      [(= ref.class linker-dwarf-ref-address-index)
        (let
          [owner : i64
            (if split?
              skeleton
              ref.unit)]
          (if (< owner 0)
            unit
            (let
              [base : i64 (array-ref scan.units.slots owner).addr-base]
              [table : i64
                (if (< base 0)
                  -1
                  (linker-dwarf-target-view!
                    scan
                    ref.unit
                    reference
                    (array-ref scan.units.slots owner).input
                    linker-dwarf-section-addr))]
              (cond
                [(< base 0)
                  (linker-dwarf-reference-fail!
                    scan
                    reference
                    linker-dwarf-error-index
                    "dwarf: address index in a unit without an address base")]
                [(< table 0) unit]
                [(array-ref scan.units.slots owner).relocatable unit]
                [(or
                    (< ref.value 0)
                    (>
                      (+
                        (+ base (* ref.value record.address-size))
                        record.address-size)
                      (array-length (array-ref scan.views table).bytes)))
                  (linker-dwarf-reference-fail!
                    scan
                    reference
                    linker-dwarf-error-index
                    "dwarf: address index outside the address table")]
                [else unit]))))]
      [(or
          (= ref.class linker-dwarf-ref-rnglist-index)
          (= ref.class linker-dwarf-ref-loclist-index))
        (let
          [base : i64
            (cond
              [split? 12]
              [(= ref.class linker-dwarf-ref-rnglist-index)
                record.rnglists-base]
              [else record.loclists-base])]
          [table : i64
            (if (< base 0)
              -1
              (linker-dwarf-target-view!
                scan
                ref.unit
                reference
                record.input
                ref.target-kind))]
          (cond
            [(< base 0)
              (linker-dwarf-reference-fail!
                scan
                reference
                linker-dwarf-error-index
                "dwarf: list index in a unit without a list base")]
            [(< table 0) unit]
            [(and (not split?) record.relocatable) unit]
            [else (linker-dwarf-check-list-index! scan reference table base)]))]
      [(= ref.class linker-dwarf-ref-section-offset)
        (let
          [owner : i64
            (if (and split? (not (linker-dwarf-split-section? ref.target-kind)))
              skeleton
              ref.unit)]
          (if (< owner 0)
            unit
            (let
              [table : i64
                (linker-dwarf-target-view!
                  scan
                  ref.unit
                  reference
                  (array-ref scan.units.slots owner).input
                  ref.target-kind)]
              [base : i64
                (if (and
                  split?
                  (= ref.target-kind linker-dwarf-section-ranges)
                  (>= (array-ref scan.units.slots owner).ranges-base 0))
                  (array-ref scan.units.slots owner).ranges-base
                  0)]
              (if (and
                (>= table 0)
                (not record.relocatable)
                (not (array-ref scan.views table).relocatable)
                (or
                  (< ref.value 0)
                  (>
                    (+ base ref.value)
                    (array-length (array-ref scan.views table).bytes))))
                (linker-dwarf-reference-fail!
                  scan
                  reference
                  linker-dwarf-error-reference
                  "dwarf: section offset past the end of its target section")
                unit))))]
      [else unit])
    (if (and scan.ok (>= target 0))
      (set!
        (array-ref scan.references.slots reference)
        (LinkerDwarfReference
          ref.unit
          ref.offset
          ref.width
          ref.attribute
          ref.form
          ref.op
          ref.class
          ref.target-kind
          ref.value
          target))
      unit)))

;; --- entry point ---------------------------------------------------------------------------------
;: Whether every limit is usable.
(define (linker-dwarf-limits-valid? [limits : (& limits LinkerDwarfLimits)]) : bool
  (and
    (> limits.max-views 0)
    (>= limits.max-bytes 0)
    (>= limits.max-units 0)
    (>= limits.max-abbrev-entries 0)
    (>= limits.max-attribute-specs 0)
    (>= limits.max-dies 0)
    (>= limits.max-attributes 0)
    (> limits.max-depth 0)
    (>= limits.max-block-bytes 0)
    (>= limits.max-references 0)
    (>= limits.max-work 0)))

;: The ledger reason for a view of `kind` this layer does not inventory.
(define (linker-dwarf-ledger-reason [kind : i64]) : i64
  (cond
    [(or
        (= kind linker-dwarf-section-str)
        (= kind linker-dwarf-section-line-str)
        (= kind linker-dwarf-section-str-dwo))
      linker-dwarf-ledger-string-table]
    [(or
        (= kind linker-dwarf-section-str-offsets)
        (= kind linker-dwarf-section-str-offsets-dwo)
        (= kind linker-dwarf-section-addr))
      linker-dwarf-ledger-offset-table]
    [else linker-dwarf-ledger-opaque]))

;: Inventory `views` within `limits`.
(define (linker-dwarf-scan
  [views : (__tl_dyn-array LinkerDwarfView)]
  [limits : LinkerDwarfLimits]) : ResultLinkerDwarfInventory
  (let
    [count : i64 (array-length views)]
    [inputs : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [sections : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [total : i64 0]
    [index : i64 0]
    (when
      (not (linker-dwarf-limits-valid? (& limits)))
      (return
        (Err
          (LinkerDwarfError
            linker-dwarf-error-invalid-limits
            -1
            -1
            0
            -1
            0
            0
            "dwarf: invalid scan limits"))))
    (when
      (> count limits.max-views)
      (return
        (Err
          (LinkerDwarfError
            linker-dwarf-error-view-limit
            -1
            -1
            0
            -1
            0
            count
            "dwarf: view limit exceeded"))))
    (while (< index count)
      (set! (array-ref inputs index) (array-ref views index).input)
      (set! (array-ref sections index) (array-ref views index).section)
      (+= total (array-length (array-ref views index).bytes))
      (+= index 1))
    (when
      (> total limits.max-bytes)
      (return
        (Err
          (LinkerDwarfError
            linker-dwarf-error-byte-limit
            -1
            -1
            0
            -1
            0
            total
            "dwarf: byte limit exceeded"))))
    (let
      [order : (__tl_dyn-array i64)
        (linker-dwarf-order (& inputs) (& sections) count)]
      [sorted : (__tl_dyn-array LinkerDwarfView)
        (__tl_make-array LinkerDwarfView count)]
      (set! index 0)
      (while (< index count)
        (set!
          (array-ref sorted index)
          (array-ref views (array-ref order index)))
        (+= index 1))
      (let
        [scan : LinkerDwarfScan (linker-dwarf-scan-new sorted limits)]
        (set! index 1)
        (while (and scan.ok (< index count))
          (if (and
            (=
              (array-ref scan.views index).input
              (array-ref scan.views (- index 1)).input)
            (=
              (array-ref scan.views index).section
              (array-ref scan.views (- index 1)).section))
            (linker-dwarf-fail!
              (&mut scan)
              linker-dwarf-error-duplicate-view
              index
              -1
              0
              "dwarf: two views share one input and section")
            unit)
          (+= index 1))
        (set! index 0)
        (while (and scan.ok (< index count))
          (let
            [kind : i64 (array-ref scan.views index).kind]
            (if (linker-dwarf-unit-section? kind)
              (let
                [at : i64 0]
                [end : i64 (array-length (array-ref scan.views index).bytes)]
                (while (and scan.ok (>= at 0) (< at end))
                  (set! at (linker-dwarf-scan-unit! (&mut scan) index at))))
              (if (and
                (!= kind linker-dwarf-section-abbrev)
                (!= kind linker-dwarf-section-abbrev-dwo))
                (dwarf_ledger_vec.push-ref!
                  (&mut scan.ledger)
                  (LinkerDwarfLedgerEntry
                    (array-ref scan.views index).input
                    (array-ref scan.views index).section
                    kind
                    (linker-dwarf-ledger-reason kind)))
                unit))
            (+= index 1)))
        (if scan.ok
          (linker-dwarf-pair-skeletons! (&mut scan))
          unit)
        (if scan.ok
          (linker-dwarf-check-references! (&mut scan))
          unit)
        (if scan.ok
          (let
            [units : (__tl_dyn-array LinkerDwarfUnit)
              (__tl_make-array LinkerDwarfUnit scan.units.len)]
            [tables : (__tl_dyn-array LinkerDwarfAbbrevTable)
              (__tl_make-array LinkerDwarfAbbrevTable scan.tables.len)]
            [references : (__tl_dyn-array LinkerDwarfReference)
              (__tl_make-array LinkerDwarfReference scan.references.len)]
            [ledger : (__tl_dyn-array LinkerDwarfLedgerEntry)
              (__tl_make-array LinkerDwarfLedgerEntry scan.ledger.len)]
            (dwarf_unit_vec.copy-range!
              (&mut units)
              (& scan.units.slots)
              0
              scan.units.len)
            (dwarf_table_vec.copy-range!
              (&mut tables)
              (& scan.tables.slots)
              0
              scan.tables.len)
            (dwarf_reference_vec.copy-range!
              (&mut references)
              (& scan.references.slots)
              0
              scan.references.len)
            (dwarf_ledger_vec.copy-range!
              (&mut ledger)
              (& scan.ledger.slots)
              0
              scan.ledger.len)
            (Ok
              (LinkerDwarfInventory
                units
                tables
                references
                ledger
                scan.dies
                scan.attributes
                scan.work)))
          (Err scan.error))))))

;: Check every reference, resolving signatures through the type units.
(define (linker-dwarf-check-references! [scan : (&mut scan LinkerDwarfScan)]) : unit
  (let
    [count : i64 scan.units.len]
    [signatures : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [type-units : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [typed : i64 0]
    (for [index (iterator.range 0 count)]
      (set!
        (array-ref signatures index)
        (array-ref scan.units.slots index).signature)
      (if (or
        (= (array-ref scan.units.slots index).unit-type 2)
        (= (array-ref scan.units.slots index).unit-type 6))
        (begin
          (set! (array-ref type-units index) 0)
          (+= typed 1))
        (set! (array-ref type-units index) 1)))
    (let
      ;; Order type units first, by signature, then drop the rest.
      [order : (__tl_dyn-array i64)
        (linker-dwarf-order (& type-units) (& signatures) count)]
      [signature-order : (__tl_dyn-array i64) (__tl_make-array i64 typed)]
      [reference : i64 0]
      [total : i64 scan.references.len]
      (for [index (iterator.range 0 typed)]
        (set! (array-ref signature-order index) (array-ref order index)))
      (if (linker-dwarf-charge! scan total -1 0)
        (while (and scan.ok (< reference total))
          (linker-dwarf-check-reference!
            scan
            reference
            (& signatures)
            (& signature-order))
          (+= reference 1))
        unit))))
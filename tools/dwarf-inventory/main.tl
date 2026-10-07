;; dwarf-inventory - scan DWARF section dumps with linker_dwarf_scan_core.
;;
;; usage: dwarf-inventory [--references] DIR...
;;
;; Each DIR holds a `sections.tsv` (tab-separated: section index, name, size,
;; relocatable yes/no, file, sha256) and the listed raw section files, as
;; tests/fixtures/dwarf does. The DIRs are inputs 1, 2, ... of one scan with
;; the default limits. Prints one summary line in the form the tests check,
;; then `work=` and `bytes=`; with --references, one `ref` line per recorded
;; reference. A rejected scan prints `error` fields and exits 1.
;; scripts/analyze-dwarf-corpus.sh compares this output with llvm-dwarfdump
;; and the objects' relocations.
(import linker_dwarf_scan_core as dwarf)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.str_cat)
(import stdlib.string)

;: The unsigned decimal value of `text`, or -1.
(define (inventory-decimal [text : (& text str)]) : i64
  (let
    [value : i64 0]
    [index : i64 0]
    [ok : bool (> (string.string-length text) 0)]
    (while (and ok (< index (string.string-length text)))
      (let
        [c : i64 (cast (string.string-ref text index) : i64)]
        (if (and (>= c 48) (<= c 57))
          (set! value (+ (* value 10) (- c 48)))
          (set! ok false)))
      (set! index (+ index 1)))
    (if ok
      value
      -1)))

;: The `field`th tab-separated field of `line`.
(define (inventory-field [line : (& line str)] [field : i64]) : String
  (let
    [start : i64 0]
    [index : i64 0]
    (while (< index field)
      (let
        [tab : i64 (string.index-of-byte line start (cast 9 : u8))]
        (set!
          start
          (if (< tab 0)
            (string.string-length line)
            (+ tab 1)))
        (set! index (+ index 1))))
    (let
      [tab : i64 (string.index-of-byte line start (cast 9 : u8))]
      [end : i64
        (if (< tab 0)
          (string.string-length line)
          tab)]
      (string.substring line start (- end start)))))

;: Append the views listed in `dir`/sections.tsv as input `input`.
(define (inventory-load!
  [views : (&mut views (__tl_dyn-array dwarf.LinkerDwarfView))]
  [dir : (& dir str)]
  [input : i64]) : i64
  (let
    [table : String
      (byte_buf.to-string (io.read-file (str_cat.str-cat dir "/sections.tsv")))]
    [start : i64 0]
    [loaded : i64 0]
    (while (< start (string.string-length (& table)))
      (let
        [newline : i64 (string.index-of-byte (& table) start (cast 10 : u8))]
        [end : i64
          (if (< newline 0)
            (string.string-length (& table))
            newline)]
        [line : String (string.substring (& table) start (- end start))]
        (if (> (string.string-length (& line)) 0)
          (let
            [section : String (inventory-field (& line) 0)]
            [name : String (inventory-field (& line) 1)]
            [relocatable : String (inventory-field (& line) 3)]
            [file : String (inventory-field (& line) 4)]
            [path : String (str_cat.str-cat dir "/" file)]
            (__tl_array-push!
              views
              (dwarf.LinkerDwarfView
                input
                (inventory-decimal (& section))
                (dwarf.linker-dwarf-section-kind-from-name (& name))
                (string.eq (& relocatable) "yes")
                (byte_buf.to-array (io.read-file path))))
            (set! loaded (+ loaded 1)))
          unit)
        (set! start (+ end 1))))
    loaded))

(define (inventory-count
  [inventory : (& inventory dwarf.LinkerDwarfInventory)]
  [class : i64]) : i64
  (let
    [count : i64 0]
    [index : i64 0]
    (while (< index (array-length inventory.references))
      (if (= (array-ref inventory.references index).class class)
        (set! count (+ count 1))
        unit)
      (set! index (+ index 1)))
    count))

(define (main) : i64
  (let
    [views : (__tl_dyn-array dwarf.LinkerDwarfView)
      (__tl_make-array dwarf.LinkerDwarfView 0)]
    [references? : bool false]
    [argument : i64 1]
    [input : i64 1]
    [bytes : i64 0]
    (while (< argument (io.arg-count))
      (let
        [text : String (io.arg argument)]
        (if (string.eq (& text) "--references")
          (set! references? true)
          (begin
            (inventory-load! (&mut views) (& text) input)
            (set! input (+ input 1))))
        (set! argument (+ argument 1))))
    (when
      (= input 1)
      (io.print-error "usage: dwarf-inventory [--references] DIR...")
      (return 2))
    (set! argument 0)
    (while (< argument (array-length views))
      (set! bytes (+ bytes (array-length (array-ref views argument).bytes)))
      (set! argument (+ argument 1)))
    (match (dwarf.linker-dwarf-scan views (dwarf.linker-dwarf-default-limits))
      [(Err error)
        (io.println
          "error code={} detail={} input={} section={} unit={} offset={}"
          error.code
          error.detail
          error.input
          error.section
          error.unit
          error.offset)
        (io.print-error error.message)
        1]
      [(Ok inventory)
        (let
          [units : i64 (array-length inventory.units)]
          [dies : i64 inventory.dies]
          [attrs : i64 inventory.attributes]
          [unit-refs : i64
            (inventory-count (& inventory) dwarf.linker-dwarf-ref-unit)]
          [info : i64
            (inventory-count (& inventory) dwarf.linker-dwarf-ref-info)]
          [sig : i64
            (inventory-count (& inventory) dwarf.linker-dwarf-ref-signature)]
          [str : i64
            (inventory-count (& inventory) dwarf.linker-dwarf-ref-string)]
          [lstr : i64
            (inventory-count (& inventory) dwarf.linker-dwarf-ref-line-string)]
          [strx : i64
            (inventory-count (& inventory) dwarf.linker-dwarf-ref-string-index)]
          [addr : i64
            (inventory-count (& inventory) dwarf.linker-dwarf-ref-address)]
          [addrx : i64
            (inventory-count (& inventory) dwarf.linker-dwarf-ref-address-index)]
          [secoff : i64
            (inventory-count
              (& inventory)
              dwarf.linker-dwarf-ref-section-offset)]
          [rngx : i64
            (inventory-count (& inventory) dwarf.linker-dwarf-ref-rnglist-index)]
          [locx : i64
            (inventory-count (& inventory) dwarf.linker-dwarf-ref-loclist-index)]
          (io.print
            "units={} dies={} attrs={} unit={} info={} "
            units
            dies
            attrs
            unit-refs
            info)
          (io.print
            "sig={} str={} lstr={} strx={} addr={} "
            sig
            str
            lstr
            strx
            addr)
          (io.println
            "addrx={} secoff={} rngx={} locx={}"
            addrx
            secoff
            rngx
            locx)
          (io.println "work={}" inventory.work)
          (io.println "bytes={}" bytes)
          (when
            references?
            (set! argument 0)
            (while (< argument (array-length inventory.references))
              (let
                [owner : i64 (array-ref inventory.references argument).unit]
                (io.println
                  "ref input={} section={} offset={} width={} class={}"
                  (array-ref inventory.units owner).input
                  (array-ref inventory.units owner).section
                  (array-ref inventory.references argument).offset
                  (array-ref inventory.references argument).width
                  (array-ref inventory.references argument).class)
                (set! argument (+ argument 1)))))
          0)])))
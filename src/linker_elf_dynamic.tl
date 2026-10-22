;; Shared dynamic tags and name hashes for the DSO reader and #8296 codec.
;; Values are ELF64 wire values, independent of host loader or linker state.
(import stdlib.byte_le as le)

(define dt-null : i64
  0)
(define dt-needed : i64
  1)
(define dt-hash : i64
  4)
(define dt-strtab : i64
  5)
(define dt-symtab : i64
  6)
(define dt-strsz : i64
  10)
(define dt-syment : i64
  11)
(define dt-soname : i64
  14)
(define dt-rpath : i64
  15)
(define dt-runpath : i64
  29)
(define dt-flags : i64
  30)
(define dt-gnu-hash : i64
  1879047925)
(define dt-versym : i64
  1879048176)
(define dt-flags-1 : i64
  1879048187)
(define dt-verdef : i64
  1879048188)
(define dt-verdefnum : i64
  1879048189)
(define dt-verneed : i64
  1879048190)
(define dt-verneednum : i64
  1879048191)

(define (gnu-hash [data : (& b (__tl_dyn-array u8))] [start : i64] [end : i64]) : i64
  (let
    [hash : i64 5381]
    [at : i64 start]
    (while (< at end)
      (set! hash (bit-and (+ (* hash 33) (le.byte-le-at data at)) 4294967295))
      (set! at (+ at 1)))
    hash))

(define (string-tag? [tag : i64]) : bool
  (or (= tag dt-needed) (= tag dt-soname) (= tag dt-rpath) (= tag dt-runpath)))

(define (singleton-tag? [tag : i64]) : bool
  (or
    (= tag dt-hash)
    (= tag dt-gnu-hash)
    (= tag dt-strtab)
    (= tag dt-symtab)
    (= tag dt-strsz)
    (= tag dt-syment)
    (= tag dt-soname)
    (= tag dt-rpath)
    (= tag dt-runpath)
    (= tag dt-flags)
    (= tag dt-flags-1)
    (= tag dt-versym)
    (= tag dt-verdef)
    (= tag dt-verdefnum)
    (= tag dt-verneed)
    (= tag dt-verneednum)))

(define (pointer-tag? [tag : i64]) : bool
  (or
    (= tag 3)
    (= tag 4)
    (= tag 5)
    (= tag 6)
    (= tag 7)
    (= tag 12)
    (= tag 13)
    (= tag 17)
    (= tag 23)
    (= tag 25)
    (= tag 26)
    (= tag 32)
    (= tag 36)
    (= tag dt-gnu-hash)
    (= tag dt-versym)
    (= tag dt-verdef)
    (= tag dt-verneed)))

(define (pointer-field [tag : i64]) : String
  (match tag
    [3 "DT_PLTGOT"]
    [4 "DT_HASH"]
    [5 "DT_STRTAB"]
    [6 "DT_SYMTAB"]
    [7 "DT_RELA"]
    [12 "DT_INIT"]
    [13 "DT_FINI"]
    [17 "DT_REL"]
    [23 "DT_JMPREL"]
    [25 "DT_INIT_ARRAY"]
    [26 "DT_FINI_ARRAY"]
    [32 "DT_PREINIT_ARRAY"]
    [36 "DT_RELR"]
    [1879047925 "DT_GNU_HASH"]
    [1879048176 "DT_VERSYM"]
    [1879048188 "DT_VERDEF"]
    [1879048190 "DT_VERNEED"]
    [_ "DT-pointer"]))
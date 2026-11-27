(import stdlib.io)
(import compiler_object as cobj)

(define pdata-id : cobj.CompilerObjectSectionId
  (cobj.CompilerObjectSectionId 4))
(define xdata-id : cobj.CompilerObjectSectionId
  (cobj.CompilerObjectSectionId 5))
(define rsrc-id : cobj.CompilerObjectSectionId
  (cobj.CompilerObjectSectionId 6))

(import compiler_object_layout as layout)

(define (windows-base-section
  [role : cobj.CompilerObjectSectionKind]
  [data : cobj.CompilerObjectDataRecordList]
  [instrs : cobj.CompilerObjectX64InstrList]) : cobj.CompilerObjectSection
  (let
    [name : String
      (match role
        [(Text) ".text"]
        [(Data) ".data"]
        [(Rodata) ".rdata"]
        [(Bss) ".bss"])]
    [format : cobj.CompilerObjectSectionFormat
      (match role
        [(Text) (Coff 0x60000020)]
        [(Data) (Coff 0xc0000040)]
        [(Rodata) (Coff 0x40000040)]
        [(Bss) (Coff 0xc0000080)])]
    (layout.compiler-object-layout-base-section role name format data instrs)))

(define (metadata-section
  [id : cobj.CompilerObjectSectionId]
  [name : String]
  [data : cobj.CompilerObjectDataRecordList]) : cobj.CompilerObjectSection
  (match (layout.compiler-object-checked-section
    (Section
      (cobj.CompilerObjectSectionSpec
        id
        id.value
        name
        8
        (Initialized)
        (Coff 0x40000040))
      data
      (cobj.compiler-object-instr-list-empty))
    true)
    [(Ok section) section]
    [(Err message) (io.panic message)]))
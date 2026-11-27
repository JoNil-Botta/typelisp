(import compiler_object as cobj)
(import compiler_object_layout as layout)

(define (linux-base-section
  [role : cobj.CompilerObjectSectionKind]
  [data : cobj.CompilerObjectDataRecordList]
  [instrs : cobj.CompilerObjectX64InstrList]) : cobj.CompilerObjectSection
  (let
    [name : String
      (match role
        [(Text) ".text"]
        [(Data) ".data"]
        [(Rodata) ".rodata"]
        [(Bss) ".bss"])]
    [format : cobj.CompilerObjectSectionFormat
      (match role
        [(Text) (Elf 1 6)]
        [(Data) (Elf 1 3)]
        [(Rodata) (Elf 1 2)]
        [(Bss) (Elf 8 3)])]
    (layout.compiler-object-layout-base-section role name format data instrs)))
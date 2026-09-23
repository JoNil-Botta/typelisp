# AMD64 import member oracle

`example-0.bin` through `example-6.bin` are the raw archive member payloads,
in order, from LLVM 22.1.8 `llvm-dlltool`:

```text
LIBRARY example.dll
EXPORTS
  Func
  Data DATA
  Const CONSTANT
  Ord @7 NONAME
```

Generated with `llvm-dlltool -m i386:x86-64 -d example.def -l example.lib`.
The archive's two linker-index members were omitted. The seven payloads were
extracted from the remaining archive members without changing their bytes.
The inline test in `src/linker_coff_import_member_writer.tl` compares each
payload exactly; it does not invoke LLVM at test time.

`aliases-3.bin` through `aliases-5.bin` are the short members from a second
LLVM 22.1.8 library made with the same command and this DEF export list:

```text
LIBRARY example.dll
EXPORTS
  Alias=Real
  Forward=kernel32.Sleep
  _Decorated@8
```

The three fixed support objects of that library are identical to
`example-0.bin` through `example-2.bin` and are not duplicated here.

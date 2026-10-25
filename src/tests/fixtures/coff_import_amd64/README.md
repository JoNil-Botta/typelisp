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

`sdk-acquire-exclusive.bin` and `sdk-acquire-shared.bin` are unchanged short
members 4 and 5 named `KERNEL32.dll` from Microsoft's x64 SDK import library.
They retain the publisher's nonzero timestamps and hints 0 and 1. Source:
[Microsoft.Windows.SDK.CPP.x64 10.0.28000.2705](https://www.nuget.org/packages/Microsoft.Windows.SDK.CPP.x64/10.0.28000.2705),
package entry `c/um/x64/kernel32.Lib` (311,908 bytes). Extraction used
`llvm-ar xN 4 kernel32.lib KERNEL32.dll` and instance 5 in separate directories;
file permission bits were made readable without changing payload bytes.

| Artifact | SHA256 |
| --- | --- |
| NuGet package | `bf892c1048059984850a1ed79bb81c0243478c6d7472d637c90565ab5c836013` |
| kernel32.Lib | `8ba8dab9adec752047d4f136852e8136d01836bff39bbb56a20ac5f2d56415d8` |
| sdk-acquire-exclusive.bin | `aa572fef218ddea27ebcaca9cdcd92b815a4514abfda2b8b744c7f7a78b2124b` |
| sdk-acquire-shared.bin | `6326732e6fa00107f5161cb7969107e625963f9e1744b1e76b6dc32cd75c049c` |

The reader's normal tests embed these bytes and the existing LLVM members;
they download nothing and require neither Microsoft nor LLVM tools.

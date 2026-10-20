#!/usr/bin/env python3
"""Independent v1 golden construction; ordinary tests only embed the results."""
from pathlib import Path
from hashlib import sha256
from struct import pack
import json


def enum(tag, *payload):
    return {"tag": tag, "payload": list(payload)}


def encode(value):
    nodes = 1
    if value is None:
        tag, data = 0, b""
    elif isinstance(value, bool):
        tag, data = 1, bytes([value])
    elif isinstance(value, int):
        tag, data = (2, pack("<q", value)) if value < 0 else (3, pack("<Q", value))
    elif isinstance(value, str):
        tag, data = 4, value.encode("utf-8")
    elif isinstance(value, list):
        tag, chunks = 5, [pack("<I", len(value))]
        for item in value:
            encoded, count = encode(item)
            chunks.append(encoded)
            nodes += count
        data = b"".join(chunks)
    elif isinstance(value, dict):
        tag, chunks = 6, [pack("<I", len(value))]
        for key in sorted(value, key=lambda k: k.encode("utf-8")):
            encoded, count = encode(value[key])
            raw_key = key.encode("utf-8")
            chunks.extend([pack("<I", len(raw_key)), raw_key, encoded])
            nodes += count
        data = b"".join(chunks)
    else:
        raise TypeError(value)
    return bytes([tag]) + pack("<Q", len(data)) + data, nodes


def frame(value, kind):
    data, nodes = encode(value)
    return b"TLNATIVELINK" + pack("<HHQQ", 1, kind, len(data), nodes) + data


CAPABILITIES = """ObjectInputs ArchiveInputs SharedInputs ImportLibraryInputs LibrarySearch
Groups WholeArchive StaticDynamicPreference DefaultLibraries Directives Exports DefinitionFiles
VersionMaps Resources Tls Ifunc Constructors Unwind Dwarf CodeView Relocations DelayLoad
ExternalArguments RuntimeHelpers SystemImports OutputRelocatable OutputFreestandingStatic
OutputStatic OutputStaticPie OutputPie OutputArchive OutputElfDso OutputPeDll OutputImportLibrary""".split()
HARDENING = """PositionIndependent AddressRandomization NoExecute NonExecutableStack Relro
ControlFlowGuard Cet EhContinuation StackProtector""".split()
WINDOWS_FUNCTIONS = """ConvertThreadToFiber CreateFiberEx ExitProcess GetCommandLineA GetStdHandle
SetThreadStackGuarantee SetUnhandledExceptionFilter SwitchToFiber WriteFile VirtualAlloc VirtualFree""".split()


def profile(windows):
    selected = {"ObjectInputs", "ArchiveInputs", "Groups", "WholeArchive", "StaticDynamicPreference",
                "Relocations", "RuntimeHelpers", "OutputRelocatable", "OutputFreestandingStatic", "OutputArchive"}
    if windows:
        selected -= {"Groups", "StaticDynamicPreference"}
        selected.add("SystemImports")
    capabilities = []
    for kind in sorted(CAPABILITIES):
        supported = kind in selected
        reason = "Implemented" if supported else (
            "TargetMismatch" if kind in {"Groups", "StaticDynamicPreference", "SystemImports"} else "RequiresTargetConsumer")
        capabilities.append({"kind": enum(kind), "support": enum("Supported" if supported else "Unsupported", enum(reason)),
                             "schema-id": "typelisp.native-link.capability.v1", "helper-id": ("typelisp.windows-system-imports.v1" if kind == "SystemImports" else "typelisp.runtime.v1") if supported else ""})
    image = {"subsystem": enum("ConsoleSubsystem" if windows else "NoWindowsSubsystem"),
             "image-base": 5368709120 if windows else 0, "section-alignment": 4096 if windows else 0,
             "file-alignment": 512 if windows else 0, "stack-reserve": 268435456 if windows else 0,
             "stack-commit": 4096 if windows else 0, "heap-reserve": 1048576 if windows else 0,
             "heap-commit": 4096 if windows else 0}
    imports = [{"symbol": f, "dll": "kernel32.dll"} for f in WINDOWS_FUNCTIONS] if windows else []
    if windows:
        imports.append({"symbol": "NtCreateFile", "dll": "ntdll.dll"})
    return {"schema-version": 1, "extension-version": 0,
            "id": "typelisp-freestanding-" + ("windows" if windows else "linux") + "-x86_64-v1", "version": 1,
            "target": enum("WindowsX86_64" if windows else "LinuxX86_64"),
            "target-triple": "x86_64-pc-windows-msvc" if windows else "x86_64-unknown-linux-gnu",
            "abi": enum("WindowsAMD64" if windows else "SysVAMD64"), "runtime": enum("CompilerFreestanding"),
            "runtime-floor": {"major": 0, "minor": 0, "patch": 0},
            "outputs": [enum(x) for x in sorted(["Relocatable", "StaticArchive", "FreestandingStaticExecutable"])],
            "roots": [], "files": [], "inputs": [],
            "runtime-identities": sorted(["typelisp.compiler-startup.v1", "typelisp.runtime.v1",
                "typelisp.windows-system-imports.v1" if windows else "typelisp.linux-syscalls.v1"]),
            "entry": enum("CompilerEntry", "_tl_start"), "startup": enum("CompilerStartup", "typelisp.compiler-startup.v1"),
            "windows": image, "interpreter": enum("NoInterpreter"), "imports": sorted(imports, key=lambda x: x["symbol"]),
            "debug": {"form": enum("NoDebug"), "build-id": enum("NoBuildId"), "pdb": enum("NoPdb"), "deterministic": True},
            "capabilities": capabilities,
            "hardening": [{"feature": enum(feature), "requirement": enum("Forbidden" if windows and feature == "AddressRandomization" else "Off"),
                           "schema-id": "typelisp.native-link.hardening.v1", "helper-id": ""} for feature in sorted(HARDENING)]}


def manifest(p, profile_bytes, windows):
    controls = [("entry", enum("EntryControl", p["entry"])), ("startup", enum("StartupControl", p["startup"])),
                ("unresolved", enum("UnresolvedControl", enum("RejectUnresolved"))),
                ("section-gc", enum("SectionGcControl", enum("KeepAllSections"))),
                ("exports", enum("ExportsControl", enum("ExplicitExports"))), ("debug", enum("DebugControl", p["debug"])),
                ("windows-image" if windows else "interpreter", enum("WindowsImageControl", p["windows"]) if windows else enum("InterpreterControl", p["interpreter"]))]
    # Profile hardening is a declared set; its insertion into the event stream
    # follows the constructor's feature order, which is semantically ordered.
    rows = {r["feature"]["tag"]: r for r in p["hardening"]}
    controls += [("hardening", enum("HardeningControl", rows[feature])) for feature in HARDENING]
    events = []
    for ordinal, (row, value) in enumerate(controls):
        index = ordinal - 7 if row == "hardening" else 0
        events.append({"ordinal": ordinal, "id": "e" + str(ordinal),
                       "provenance": enum("ProfileRowOrigin", p["id"], row, index), "payload": enum("Control", value)})
    return {"schema-version": 1, "extension-version": 0, "target": p["target"], "target-triple": p["target-triple"],
            "abi": p["abi"], "output": enum("FreestandingStaticExecutable"), "artifact-id": "example.app",
            "profile": {"id": p["id"], "version": 1, "content": {"algorithm-version": 1, "sha256": list(sha256(profile_bytes).digest())}},
            "reproducibility": enum("HermeticInputs"), "roots": [], "events": events}


if __name__ == "__main__":
    root = Path(__file__).resolve().parent
    identities = {}
    for windows, name in [(False, "linux"), (True, "windows")]:
        p = profile(windows)
        profile_bytes = frame(p, 2)
        m = manifest(p, profile_bytes, windows)
        def redact(value):
            if isinstance(value, dict):
                return {k: ("<content identity>" if k == "sha256" else redact(v)) for k, v in value.items()}
            if isinstance(value, list):
                return [redact(v) for v in value]
            return value
        header = "auto-capability: internal-representation-available\ncontent-closure-required: true\nopaque-external-closure: false\n"
        human = header + "native-link-v1 " + json.dumps(redact({"manifest": m, "profile": p}), sort_keys=True, indent=2) + "\n"
        (root / (name + ".expected")).write_text(human)
        for suffix, data in [("profile", profile_bytes), ("manifest", frame(m, 1)), ("input", frame({"manifest": m, "profile": p}, 3))]:
            filename = name + "-" + suffix + ".in"
            (root / filename).write_bytes(data)
            identities[filename] = {"bytes": len(data), "sha256": sha256(data).hexdigest()}
    (root / "identities.json").write_text(json.dumps(identities, indent=2) + "\n")

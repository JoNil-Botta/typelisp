# Lowering expression-family ledger

`lower-expr-with-type` routes checked expressions into family lowering. A family
owns operand evaluation, contextual coercion, source-attributed errors, fresh
IDs and its returned `LowerState`; extracting it must preserve all five. The
caller passes the original expression provenance rather than inventing a span
for a helper call. Short-circuiting remains control flow, and eager operands
consume the state returned by the preceding operand.

This ledger tracks #7770. Its starting inventory on `95be68cf` contains 86
arms, including the fallback. The issue remains open for the residual substantial
bodies below. Grouped names are exact `AstExpr` variants.

| Arms | Authority and status |
| --- | --- |
| `Unary` | `lower-unary-expr`: contextual child lowering followed by one shared result allocation/emission path. |
| `Binary` | `lower-binary-expr`: `And`/`Or` use `lower-if`; eager operands lower left then right; register-group comparisons use `lower-group-equality`. |
| `Set` | Substantial inline assignment body remains. Reconcile it with existing `lower-set-expr` in a separate slice. |
| `Comptime` | Substantial inline CTFE/materialization body remains. Reconcile it with existing `lower-comptime-expr` in a separate slice. |
| `PtrNullCheck`, `PtrAddrOf`, `PtrRead`, `PtrWrite`, `PtrOffset`, `PtrCast`, `PtrToInt`, `IntToPtr` | Inline pointer-family behavior remains alongside existing `lower-ptr-*-expr` helpers. Coordinate #7725/#7844 when consolidating it. |
| `Spanned`, `MacroExpansion` | Small provenance/unwrapping routes back to the dispatcher. |
| `Literal`, `BinaryData`, `SpmdProgramIndex`, `SpmdProgramCount` | Small value selection plus existing `lower-materialize-at-expr`. |
| `Init`, `FixedMakeArray` | Select the expected type and route to `lower-init-expr`. |
| `Var` | Small dotted-field rewrite or `lower-var-or-nullary-variant-id` route. |
| `Ann`, `Cast`, `Borrow` | Small operand-resolution wrappers around existing expected-value, cast and borrow helpers. |
| `Call`, `Lambda`, `Let`, `Begin`, `Unsafe` | Unpack children/bindings and route to `lower-call`, `lower-lambda`, `lower-let-bindings`, or `lower-begin-expected`; unsafe entry changes the type environment. |
| `If`, `While`, `ForOwnedState`, `ForOwnedStep`, `Foreach` | Resolve children or unpack the typed payload, then use the existing control-flow family helper. |
| `SpmdReduce`, `SpmdScan`, `SpmdCompact`, `SpmdBroadcast`, `SpmdShuffle` | Existing SPMD helpers own lowering. The longer dispatcher wrappers unpack payloads and forward resolved child expressions; they do not construct family IR. |
| `Match`, `StringRef`, `StructGet`, `StructSet` | Child-resolution routes to the existing match/string/field helpers. |
| `MakeArray`, `Array`, `DynArray`, `ArrayRef`, `ArraySet`, `ArrayTake`, `FixedArrayTake`, `Replace`, `ArrayPush` | Existing allocation/literal/element/ownership helpers; dispatcher only forwards the selected family and operands. |
| `Tuple`, `TupleRef` | Existing tuple construction/access helpers. |
| `WithRegion`, `WithEscape`, `WithScratch`, `InArena`, `WithResource` | Existing arena/resource helpers own cleanup and lifetime handoffs. |
| `Box`, `BoxGet`, `BoxTake`, `BoxSet` | Existing box helpers; `BoxGet`/`BoxTake` share the established `lower-box-get` route. |
| `Try`, `Return`, `Break`, `Continue` | Existing result/return/loop-control helpers own exit construction. |
| `Quote`, `Quasiquote`, `Unquote`, `UnquoteSplicing`, `TypeLiteral` | Small explicit rejection/materialization-policy arms; preserve their original diagnostic locations. |
| `PtrNull` | Existing `lower-ptr-null-expr` route. |
| `StringData`, `StringFromBytes`, `ArrayData` | Existing storage-view helpers with child-resolution wrappers. |
| `ProgramArgc`, `ProgramArgv`, `ProgramEnvp` | One-call `lower-entry-load` routes. |
| `CpuIdEax`, `CpuIdEbx`, `CpuIdEcx`, `CpuIdEdx`, `Xgetbv`, `Syscall` | Existing target-operation helpers; wrappers select registers or unpack arguments. |
| Fallback | Source-attributed unsupported-expression rejection. |

Small routing arms may remain: splitting a child lookup from its helper call
adds no separate contract. Do not duplicate type queries, add a general visitor,
or treat this ledger as a line-count target. Update the affected row when a
family changes, and remove its superseded implementation in the same slice.

For the operator family, retain contextual numeric/unary tests, short-circuit
branch tests, aggregate equality, nested exits and source-error fixtures from
`compiler_lower_tests.tl` and the lowerer smoke. Review also compares fixed-source
IR/assembly on Linux and Windows and compiler throughput before/after; a source
move is not evidence of unchanged ownership or cost.

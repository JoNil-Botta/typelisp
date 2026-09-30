# Lowering expression-family ledger

`lower-expr-with-type` routes checked expressions into family lowering. A family
owns operand evaluation, contextual coercion, source-attributed errors, fresh
IDs and its returned `LowerState`; extracting it must preserve all five. The
caller passes the original expression provenance rather than inventing a span
for a helper call. Short-circuiting remains control flow, and eager operands
consume the state returned by the preceding operand.

Requested pointer-proof capture runs at the specialized, checked function
boundary before expression dispatch erases pointer semantics. It uses the shared
AST child IDs and existing type and symbol authorities; disabled lowering does
not walk expressions for proof input. Each captured read has its own occurrence
index, while reads and assignments name the original lexical binding. Binding
operands hold their initializers; a let sequence holds its bindings and body.
Other operands retain AST child order: a branch join holds condition, then and
else, and direct calls hold arguments without the callee expression. Function
records bind source parameter ordinals and their result occurrence to the
emitted function symbol.

The analysis handoff requires its exact live, immutable IR and source-span
tables. Captured paths, spans and source type categories belong to the proof
owner and survive source/type/interner retirement. Missing facts and unknown
pointer producers reject the handoff; known opaque producers record their kind
without granting admission. Do not reconstruct erased conversions from machine
types or let a later optimized program substitute for this boundary.

This ledger tracks #7770. Its starting inventory on `95be68cf` contains 86
arms, including the fallback. The issue remains open for the residual substantial
bodies below. Grouped names are exact `AstExpr` variants.

| Arms | Authority and status |
| --- | --- |
| `Unary` | `lower-unary-expr`: contextual child lowering followed by one shared result allocation/emission path. |
| `Binary` | `lower-binary-expr`: `And`/`Or` use `lower-if`; eager operands lower left then right; register-group comparisons use `lower-group-equality`. |
| `Set` | Substantial inline assignment body remains; the dispatcher arm is its only implementation. Extract it into a family helper in a separate slice. |
| `Comptime` | Substantial inline CTFE/materialization body remains; the dispatcher arm is its only implementation. Extract it into a family helper in a separate slice. |
| `PtrNullCheck`, `PtrAddrOf`, `PtrRead`, `PtrWrite`, `PtrOffset`, `PtrCast`, `PtrToInt`, `IntToPtr` | Inline pointer-family behavior remains; the dispatcher arms are its only implementation. Coordinate #7725/#7844 when extracting it. |
| `Spanned`, `MacroExpansion` | Small provenance/unwrapping routes back to the dispatcher. |
| `Literal`, `BinaryData`, `SpmdProgramIndex`, `SpmdProgramCount` | Small value selection plus existing `lower-materialize-at-expr`. |
| `Init`, `FixedMakeArray` | Select the expected type and route to `lower-init-expr`. |
| `Var` | Small dotted-field rewrite or `lower-var-or-nullary-variant-id` route. |
| `Ann`, `Cast`, `Borrow` | Small operand-resolution wrappers around existing expected-value, cast and borrow helpers. |
| `Call`, `Lambda`, `Let`, `Begin`, `Unsafe` | Unpack children/bindings and route to `lower-call`, `lower-lambda`, `lower-let-bindings`, or `lower-begin-expected`; unsafe entry changes the type environment. Direct and indirect calls share one lowering per ABI (`lower-c-abi-call-values`, `lower-internal-call-values`, `lower-call-values`) through a `LowerCallTarget`. |
| `If`, `While`, `ForOwnedState`, `ForOwnedStep`, `Foreach` | Resolve children or unpack the typed payload, then use the existing control-flow family helper. |
| `SpmdReduce`, `SpmdScan`, `SpmdCompact`, `SpmdBroadcast`, `SpmdShuffle` | Existing SPMD helpers own lowering. The longer dispatcher wrappers unpack payloads and forward resolved child expressions; they do not construct family IR. |
| `Match`, `StringRef`, `StructGet`, `StructSet` | Child-resolution routes to the existing match/string/field helpers. Value and tail-position matches share one arm walker (`lower-match-dispatch` and the `lower-match-*` arms) parameterized by a `LowerMatchCont`. |
| `MakeArray`, `Array`, `DynArray`, `ArrayRef`, `ArraySet`, `ArrayTake`, `Replace`, `ArrayPush` | Existing allocation/literal/element/ownership helpers; dispatcher only forwards the selected family and operands. |
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
adds no separate contract. Do not duplicate type queries, add a general visitor
to this dispatcher (shared traversal macros for analysis walkers are fine), or
treat this ledger as a line-count target. Update the affected row when a
family changes, and remove its superseded implementation in the same slice.

The source-known small-helper rewrite inside `foreach` stages argument values
before substituting the body. A read of a mutable variable needs a fresh local
even though the read cannot fault; subsequent arguments can change its value.
The direct-map `Stage` plan preserves binding order and uses the existing
emitter cache for repeated local reads. Every plan consumer must inspect the
staged initializer as well as the body, retaining masks, checks and caller
argument spans even when the body does not read that parameter.

For the operator family, retain contextual numeric/unary tests, short-circuit
branch tests, aggregate equality, nested exits and source-error fixtures from
`compiler_lower_tests.tl` and the lowerer smoke. Review also compares fixed-source
IR/assembly on Linux and Windows and compiler throughput before/after; a source
move is not evidence of unchanged ownership or cost.

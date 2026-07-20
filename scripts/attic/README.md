# Historical experiment harnesses

These scripts preserve reproducible diagnostics from completed investigations.
They are not CI gates, are not called by `ci-verify.sh`, and should not be used
as the starting point for new gate coverage. Their default outputs still live
under `target/`; invoke shell files with `bash`/`sh` and the PowerShell file
with `pwsh` or Windows PowerShell from the repository root.

| Script | Completed investigation |
| --- | --- |
| `analyze-emergency-scavenge.sh` | Emergency-scavenge frequency census, #4354 |
| `analyze-move-traffic.sh` | Redundant regalloc move/spill traffic, #3095 |
| `analyze-regalloc-call-spans.sh` | Caller-saved call-span census, #3183 |
| `measure-intern-counts.sh` | Redundant string interning work, #4427 |
| `measure-static-asm-counts.sh` | Static assembly census used by the completed P0-P9 codegen rollout, PR #4433 |
| `measure-unused-import-cost.sh` | Unused import cost experiment, #3803 / #3857 |
| `measure-vector-instantiation-cost.sh` | One-vs-five compact vector identity attribution, #5295 |
| `windows-allocation-campaign.ps1` | Windows commitment-limit incident campaign, #4897 |

If one of these techniques becomes useful again, prefer creating a current,
focused tool or gate at the top level. Restore an attic script only when it has
a recurring owner, current acceptance criteria, and appropriate verification.

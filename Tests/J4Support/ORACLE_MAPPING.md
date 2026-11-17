# J4 native feedback oracle mapping

Reference Git3b5725be4aa7466590f58b16d21913fc3e1ef077 is the native-primary host after the separately
reviewed publication/receipt/owned-virtual fixes. Exact source blob hashes and verbatim leaf/context
excerpts are in native3b/SOURCE_MAPPING.json and the adjacent .swift.txt files (Tests-only, not compiled).
The executable independent translation is verify_feedback_runtime.py. It does not import production
FeedbackRuntime, Core FeedbackPlanning or a production permission/receipt helper.

| Native reference | Primary Core replacement | Independent Tests calculation |
|---|---|---|
| FeedbackScheduler39–43 plan;66–70 timing resolution | Complete generic Core FeedbackPlan; native resolver still owns requested/batch/default timing | plan(): message/origin/timing/raw map first-match, independent physical/target projection, complete optional native evidence |
| FeedbackScheduler130–132 dispatch | plan.dispatchChoice | Original canCoalesce && coalesced, additionally reconstructing canCoalesce from source/enabled/cached output facts |
| Session1246+ observe stage | Core FeedbackAuthorizationCheck from native observe facts | permission(generation=True), only old observe gate at this stage |
| Session1272+ optional parameter permission | Core stage exact-direction check from native policy facts | permission(): nil/static-local versus explicit source/epoch/mapping/allowsDisplay |
| Session1272+ original sequential gates and final destination | FeedbackProof/FeedbackPreflight with complete plan and fresh native facts | Full independent capture/plan/proof binding checks, original reached destination gate; no actual allowed list seeds expected decision |
| Session1272+ send do/catch and current bookkeeping | FeedbackReceiptFact/FeedbackReceiptEligibility | Real external native boundary event (literal entered true, accepted/throw outcome), independent original primitive scope predicate and full receipt mapping |
| FeedbackReceipt81–85 plus Session889–894 nonempty/all/any | Core fact.successfulSend and FeedbackReceiptSummary | Original deliveries predicates/counts, not monitor retention or new Core summary |

J3's original scope leaf remains independently sourced from36692f1422b0c3952f9048847a0bafd65421bc72;
3b already used J3 Core scopes. This feedback oracle reconstructs the same source/epoch/mapping/endpoint
rule from raw native fields, and the original J3 mandatory oracle continues separately. No J3 deletion
is credited again. Native callback/order/overlay/completionError/device pin and rate/cooldown policies
remain native and are covered by original integration tests; this is not a second Session engine.

Production Debug emits only original-input/actual-result feedback-actual-v1 rows. Their schema is
separate from old plans-v1 native/candidate records; old archives retain the old strict reader.
All new actual results are compared after primary execution; no old decision is compiled into Sources.
Actual IO is independently associated by original capture reference and native boundary outcome;
receipt facts cannot invent attempts or borrow another payload/owner/epoch's successful result.

The mandatory workflow fails absent/empty/reused trace, missing oracle/operation/input/result,
unknown schema/type/op, gaps/duplicates, wrong complete payload/optional values or any result mismatch.
Numbers are finite, bool is distinct, and arrays preserve order. Original input timestamps/identities
are not masked. Six negative replay children change copied actual fields only; the primary transport
input/output is never changed. The old negative ENV is inert in production, with a real Session test.

FeedbackPlanTestCompatibility.swift only preserves unchanged test construction/accessor spelling;
its dispatch forwards the actual Core method and its timing forwards the actual native resolver.
It contains no legacy decision and is not this oracle. Original FeedbackPlanTests assertions remain
byte-identical. Conformance scheduler candidate/cold replay stays separate and retains real policy
alignment differences; the native scheduler has not been cut.

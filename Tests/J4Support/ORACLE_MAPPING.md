# Temporary scheduler baseline (O-4)

The already accepted J-3 runtime oracle and J-4 feedback-plan leaf comparison have been retired.
The six wrong-result children only mutated copies in that deleted comparator; they did not test production gates.
Product feedback, reentrancy, scope, lifecycle and safety assertions remain in their native suites.

`J4SchedulerArchiveReplayTests` and `J4SessionSchedulerArchiveReplayTests` still drive independent scheduler
candidates from complete input archives, with current/cold outputs compared separately. The codec, catalog,
strict schema/causality validation, and archived native3b source provenance remain only for this temporary
scheduler comparison. These are removed in the same round after both scheduler adapters are accepted.
The archived text excerpts are not compiled or called as a production implementation.

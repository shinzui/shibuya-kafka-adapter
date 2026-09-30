# Bundle Update Log

## 2026-09-30
* **Update**: BUG-5 is fixed in 0.9.1.0: the report's live-broker schedule loses offset 3 on 0.9.0.1 and loses nothing on 0.9.1.0.

## 2026-09-25
* **Addition**: BUG-6 records serial, within-assignment offset reversal after a group rebalance, including replay below a sampled committed boundary.
* **Addition**: BUG-5 records a live broker and model reproduction of a later retry replacing the earlier seek barrier.
* **Addition**: BUG-4 records surviving adapter consumers ending normally during group membership changes.
* **Addition**: BUG-3 records two live adapter workers exiting after a broker restart with acknowledged records still unhandled.
* **Addition**: BUG-2 records successor handler effects running before a retried predecessor under serial processing.

## 2026-09-24
* **Addition**: BUG-1 records a buffered retry that leaves acknowledged successors uncommitted on the released adapter.
* **Bootstrap**: Establish the bug-report bundle under the shared `coordination.bugReports` profile.

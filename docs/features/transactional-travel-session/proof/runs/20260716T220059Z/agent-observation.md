# Agent observation

- Context loaded: feature contract, proof contract, current app-state/gateway/store boundaries, and captured red evidence.
- Routing decision: pause before production edits and repair the proof contract.
- Failure pattern: the proof claimed real process death but had no killable proof host or declared source identity for one.
- Repair: add a test-only host using the production coordinator and atomic journal, broaden declared proof inputs, and correct the no-op Start wording.
- Contract status: draft until the strengthened proof is captured red and contract review passes.
- Remaining risk: the proof host must not replace session logic or durable state with test-only behavior.

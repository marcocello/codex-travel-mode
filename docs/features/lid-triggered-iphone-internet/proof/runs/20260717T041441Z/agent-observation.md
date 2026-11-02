# Proof repair observation

The first captured proof exited before feature execution because `proof/run.sh` rejected a missing `PROOF_OUTPUT_DIR`. The documented capture command omitted the temporary-directory setup required by the runner and named `provider-readback.json` outside the runner output directory.

The repaired command now creates and exports a unique temporary output directory and passes that directory's raw provider-readback artifact to `proof_run_capture`. Product code and acceptance criteria are unchanged.

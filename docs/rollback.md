# Rollback

Rollback is intentionally narrow:

1. Stop the named Scheduled Task and unregister only Bonsai 2 27B Server.
2. Stop only processes whose executable path is under the chosen deployment
   root.
3. Restore the user's pre-existing Codex configuration from its own
   ACL-preserving backup, or manually remove only the bonsai_local provider and
   profile.
4. Remove only the deployment-root runtime, model, cache, logs, and run state
   after independently verifying the resolved paths.
5. Leave any unrelated model directory and the user's cloud Claude settings
   untouched.

Use scripts/Unregister-BonsaiTask.ps1 for the named task. Do not use a broad
recursive delete against a drive root, home directory, repository root, or an
unresolved variable. Slot erase removes the selected server slot state and
managed file; it does not delete client conversation history.

The repository publication itself is a normal replacement commit on the
existing branch. It does not rewrite Git history or force-push.


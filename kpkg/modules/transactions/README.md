# Transactions

- `main.nim`: file-operation journals, backups, atomic file replacement, and
  crash recovery for installs and history restoration.
- `history.nim`: persistent package history, undo/rollback planning, and cleanup.
- `barrier.nim`: pending-history ownership checks shared by mutation callers.

`history` depends on `main` and `barrier`. `main` also uses `barrier`; keeping
ownership checks separate avoids a circular dependency.

SQLite connection guards and snapshot validation live in `../sqlite.nim`.
Package mutation locking lives in `../lockfile.nim`.

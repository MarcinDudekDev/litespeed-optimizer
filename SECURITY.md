# Security Policy

## Reporting
Report vulnerabilities to marcin.dudek.dev@gmail.com. Do not open public issues for security problems.

## Design notes
- Input validation: site names and backup timestamps are validated against strict patterns (no path traversal).
- All config writes are transactional with pre-image backups; interrupted runs roll back automatically.
- The tool never stores credentials and never edits LSWS Enterprise XML configs.
- WebAdmin (port 7080) exposure is reported by `analyze` (Phase 4) but never auto-opened.

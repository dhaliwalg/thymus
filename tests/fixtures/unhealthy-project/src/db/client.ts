export const prisma = { user: {} };

// Raw SQL used internally by the db layer — should NOT trigger pattern-no-raw-sql
// because src/db/** is in scope_glob_exclude
const USERS_QUERY = 'SELECT * FROM users WHERE active = 1';
const INSERT_AUDIT = 'INSERT INTO audit_log (action, ts) VALUES (?, ?)';

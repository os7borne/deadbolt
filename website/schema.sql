-- Invite requests for deadbolt.osborne.vc. Apply: npx wrangler@4 d1 execute deadbolt-invites --remote --file=schema.sql
CREATE TABLE IF NOT EXISTS requests (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  email      TEXT    NOT NULL UNIQUE,            -- lower-cased
  platforms  TEXT    NOT NULL,                   -- comma list of iphone,mac,chrome
  note       TEXT,
  status     TEXT    NOT NULL DEFAULT 'pending', -- pending | approved | rejected
  created_at INTEGER NOT NULL,                   -- unix ms
  handled_at INTEGER
);
CREATE INDEX IF NOT EXISTS requests_status_created ON requests (status, created_at);
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);

-- Personal download links for the Mac DMG (kept in Workers KV under the key "Deadbolt.dmg").
-- Only a SHA-256 of the token is stored, so a copy of this database can't be used to download anything.
CREATE TABLE IF NOT EXISTS links (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  request_id    INTEGER,                       -- NULL for standalone links (e.g. for store reviewers)
  label         TEXT,
  token_hash    TEXT    NOT NULL UNIQUE,
  created_at    INTEGER NOT NULL,
  expires_at    INTEGER NOT NULL,
  max_downloads INTEGER NOT NULL,
  downloads     INTEGER NOT NULL DEFAULT 0,
  revoked       INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS links_request ON links (request_id);

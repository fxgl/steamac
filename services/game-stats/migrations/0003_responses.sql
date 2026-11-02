-- The Cache API is a no-op on workers.dev, so the Worker caches public GET answers here: a hit reads
-- one row instead of rescanning every report. Expired rows are deleted whenever a fresh answer is stored.
CREATE TABLE responses (
    key TEXT PRIMARY KEY,
    body TEXT NOT NULL,
    created INTEGER NOT NULL
) STRICT, WITHOUT ROWID;

CREATE INDEX responses_created ON responses(created);

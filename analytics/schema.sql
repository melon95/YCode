-- One row per (install, UTC day). The composite primary key makes repeated
-- launches on the same day idempotent, so COUNT(DISTINCT instance) over a
-- date window is an honest active-user figure.
CREATE TABLE IF NOT EXISTS pings (
  instance  TEXT    NOT NULL,
  day       TEXT    NOT NULL,  -- YYYY-MM-DD (UTC)
  version   TEXT,
  os        TEXT,
  arch      TEXT,
  last_seen INTEGER,           -- epoch ms of the latest ping that day
  PRIMARY KEY (instance, day)
);

CREATE INDEX IF NOT EXISTS idx_pings_day ON pings (day);

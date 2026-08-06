public enum DatabaseSchema {
  public static let migrations: [SQLiteMigration] = [
    SQLiteMigration(
      version: 1,
      name: "durable-core",
      requiresBackup: true,
      statements: [
        """
        CREATE TABLE repositories (
          id TEXT PRIMARY KEY,
          node_id TEXT NOT NULL UNIQUE,
          owner TEXT NOT NULL COLLATE NOCASE,
          name TEXT NOT NULL COLLATE NOCASE,
          default_branch TEXT NOT NULL,
          review_enabled INTEGER NOT NULL DEFAULT 1 CHECK (review_enabled IN (0, 1)),
          triage_enabled INTEGER NOT NULL DEFAULT 1 CHECK (triage_enabled IN (0, 1)),
          implementation_enabled INTEGER NOT NULL DEFAULT 1 CHECK (implementation_enabled IN (0, 1)),
          enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          UNIQUE(owner, name)
        ) STRICT
        """,
        """
        CREATE TABLE model_profiles (
          role TEXT PRIMARY KEY CHECK (role IN ('review', 'triage', 'planning', 'orchestration')),
          provider TEXT NOT NULL,
          model TEXT NOT NULL,
          thinking TEXT NOT NULL,
          updated_at REAL NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE app_settings (
          singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
          max_concurrency INTEGER NOT NULL CHECK (max_concurrency BETWEEN 1 AND 8),
          paused INTEGER NOT NULL DEFAULT 0 CHECK (paused IN (0, 1)),
          updated_at REAL NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE jobs (
          id TEXT PRIMARY KEY,
          repository_id TEXT NOT NULL REFERENCES repositories(id) ON DELETE RESTRICT,
          kind TEXT NOT NULL CHECK (kind IN (
            'prReview', 'issueTriage', 'issueImplementation', 'complexPlan'
          )),
          object_node_id TEXT NOT NULL,
          object_number INTEGER,
          revision_key TEXT NOT NULL,
          contract_version_used TEXT NOT NULL,
          priority INTEGER NOT NULL CHECK (priority BETWEEN 0 AND 4),
          state TEXT NOT NULL CHECK (state IN (
            'discovered', 'queued', 'leased', 'preparing', 'runningPi', 'executing',
            'reconciling', 'retryBackoff', 'waitingHuman', 'awaitingResolution',
            'reconciliationQueued', 'succeeded', 'blocked'
          )),
          current_step INTEGER NOT NULL DEFAULT 0 CHECK (current_step >= 0),
          current_step_kind TEXT,
          attempt INTEGER NOT NULL DEFAULT 0 CHECK (attempt >= 0),
          not_before REAL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          terminal_reason TEXT,
          UNIQUE(repository_id, kind, object_node_id, revision_key)
        ) STRICT
        """,
        """
        CREATE INDEX jobs_dispatch_idx
        ON jobs(state, not_before, priority, created_at)
        """,
        """
        CREATE TABLE job_steps (
          id INTEGER PRIMARY KEY,
          job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE RESTRICT,
          ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
          kind TEXT NOT NULL,
          state TEXT NOT NULL,
          input_digest TEXT,
          output_digest TEXT,
          mutation_id TEXT,
          acceptance_evidence TEXT,
          completed_at REAL NOT NULL,
          UNIQUE(job_id, ordinal)
        ) STRICT
        """,
        """
        CREATE TABLE job_transitions (
          id INTEGER PRIMARY KEY,
          job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE RESTRICT,
          event_key TEXT NOT NULL UNIQUE,
          from_state TEXT NOT NULL,
          to_state TEXT NOT NULL,
          reason TEXT NOT NULL,
          artifact_id TEXT,
          attempt_before INTEGER NOT NULL,
          attempt_after INTEGER NOT NULL,
          step_before INTEGER NOT NULL,
          step_after INTEGER NOT NULL,
          created_at REAL NOT NULL
        ) STRICT
        """,
        """
        CREATE INDEX job_transitions_job_idx
        ON job_transitions(job_id, id)
        """,
        """
        CREATE TABLE object_dispositions (
          repository_id TEXT NOT NULL REFERENCES repositories(id) ON DELETE RESTRICT,
          kind TEXT NOT NULL,
          object_node_id TEXT NOT NULL,
          revision_key TEXT NOT NULL,
          state TEXT NOT NULL CHECK (state IN (
            'inFlight', 'attributed', 'ambiguous', 'humanRetryAuthorized', 'superseded'
          )),
          contract_version_used TEXT NOT NULL,
          last_job_id TEXT REFERENCES jobs(id) ON DELETE RESTRICT,
          last_mutation_id TEXT,
          evidence_digest TEXT,
          mutation_generation INTEGER NOT NULL DEFAULT 0 CHECK (mutation_generation >= 0),
          updated_at REAL NOT NULL,
          PRIMARY KEY(repository_id, kind, object_node_id, revision_key)
        ) STRICT, WITHOUT ROWID
        """,
        """
        CREATE TABLE repository_leases (
          repository_id TEXT PRIMARY KEY REFERENCES repositories(id) ON DELETE RESTRICT,
          job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE RESTRICT,
          generation INTEGER NOT NULL CHECK (generation > 0),
          heartbeat REAL NOT NULL,
          active INTEGER NOT NULL CHECK (active IN (0, 1))
        ) STRICT
        """,
        """
        CREATE INDEX repository_leases_active_idx
        ON repository_leases(active, heartbeat)
        """,
        """
        CREATE TABLE repository_backoff (
          repository_id TEXT PRIMARY KEY REFERENCES repositories(id) ON DELETE RESTRICT,
          failure_count INTEGER NOT NULL CHECK (failure_count > 0),
          not_before REAL NOT NULL,
          reason TEXT NOT NULL,
          updated_at REAL NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE pi_runs (
          id TEXT PRIMARY KEY,
          job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE RESTRICT,
          role TEXT NOT NULL,
          resource_version TEXT NOT NULL,
          resource_hash TEXT NOT NULL,
          model TEXT NOT NULL,
          session_path TEXT NOT NULL,
          accepted INTEGER NOT NULL CHECK (accepted IN (0, 1)),
          settled INTEGER NOT NULL CHECK (settled IN (0, 1)),
          structured_result_digest TEXT,
          outcome TEXT NOT NULL,
          created_at REAL NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE workspaces (
          job_id TEXT PRIMARY KEY REFERENCES jobs(id) ON DELETE RESTRICT,
          relative_path TEXT NOT NULL UNIQUE,
          base_branch TEXT NOT NULL,
          base_sha TEXT NOT NULL,
          local_head_sha TEXT NOT NULL,
          cleanup_state TEXT NOT NULL CHECK (cleanup_state IN ('retained', 'eligible', 'removed')),
          updated_at REAL NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE mutation_intents (
          id TEXT PRIMARY KEY,
          job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE RESTRICT,
          idempotency_key TEXT NOT NULL UNIQUE,
          operation TEXT NOT NULL,
          target TEXT NOT NULL,
          expected_state_digest TEXT NOT NULL,
          request_digest TEXT NOT NULL,
          state TEXT NOT NULL CHECK (state IN (
            'prepared', 'sendStarted', 'reconcileRequired', 'attributed',
            'retryAllowed', 'escalated'
          )),
          send_epoch INTEGER NOT NULL DEFAULT 0 CHECK (send_epoch >= 0),
          read_back_evidence TEXT,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE reviewed_revisions (
          repository_node_id TEXT NOT NULL,
          pr_node_id TEXT NOT NULL,
          head_sha TEXT NOT NULL,
          review_contract_version_used TEXT NOT NULL,
          comment_id TEXT NOT NULL,
          comment_url TEXT NOT NULL,
          comment_digest TEXT NOT NULL,
          created_at REAL NOT NULL,
          PRIMARY KEY(repository_node_id, pr_node_id, head_sha)
        ) STRICT, WITHOUT ROWID
        """,
        """
        CREATE TABLE issue_claims (
          issue_node_id TEXT NOT NULL,
          generation INTEGER NOT NULL CHECK (generation > 0),
          job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE RESTRICT,
          marker TEXT NOT NULL,
          expected_labels TEXT NOT NULL,
          desired_labels TEXT NOT NULL,
          plan_digest TEXT,
          prior_generation INTEGER,
          state TEXT NOT NULL CHECK (state IN ('active', 'inactive', 'consumed', 'stale')),
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          PRIMARY KEY(issue_node_id, generation)
        ) STRICT, WITHOUT ROWID
        """,
        """
        CREATE UNIQUE INDEX issue_claims_one_active_idx
        ON issue_claims(issue_node_id)
        WHERE state = 'active'
        """,
        """
        CREATE TABLE artifacts (
          id TEXT PRIMARY KEY,
          job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE RESTRICT,
          kind TEXT NOT NULL,
          relative_path TEXT NOT NULL UNIQUE,
          sha256 TEXT NOT NULL,
          redaction_classification TEXT NOT NULL CHECK (redaction_classification IN (
            'public', 'synthetic', 'sensitiveMetadata'
          )),
          producer_run_id TEXT,
          created_at REAL NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE reconciliation_events (
          id INTEGER PRIMARY KEY,
          job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE RESTRICT,
          probe TEXT NOT NULL,
          observation TEXT NOT NULL,
          classification TEXT NOT NULL,
          reason TEXT NOT NULL,
          created_at REAL NOT NULL
        ) STRICT
        """,
        appendOnlyTrigger(table: "schema_migrations", operation: "UPDATE"),
        appendOnlyTrigger(table: "schema_migrations", operation: "DELETE"),
        appendOnlyTrigger(table: "job_steps", operation: "UPDATE"),
        appendOnlyTrigger(table: "job_steps", operation: "DELETE"),
        appendOnlyTrigger(table: "job_transitions", operation: "UPDATE"),
        appendOnlyTrigger(table: "job_transitions", operation: "DELETE"),
        appendOnlyTrigger(table: "reconciliation_events", operation: "UPDATE"),
        appendOnlyTrigger(table: "reconciliation_events", operation: "DELETE"),
        """
        INSERT INTO app_settings(singleton, max_concurrency, paused, updated_at)
        VALUES (1, 2, 0, unixepoch('subsec'))
        """,
      ]
    )
  ]

  private static func appendOnlyTrigger(table: String, operation: String) -> String {
    """
    CREATE TRIGGER \(table)_no_\(operation.lowercased())
    BEFORE \(operation) ON \(table)
    BEGIN
      SELECT RAISE(ABORT, '\(table) is append-only');
    END
    """
  }
}

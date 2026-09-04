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
    ),
    SQLiteMigration(
      version: 2,
      name: "application-ui-settings",
      requiresBackup: true,
      statements: [
        """
        ALTER TABLE app_settings
        ADD COLUMN onboarding_complete INTEGER NOT NULL DEFAULT 0
          CHECK (onboarding_complete IN (0, 1))
        """,
        """
        ALTER TABLE app_settings
        ADD COLUMN external_automation_acknowledged INTEGER NOT NULL DEFAULT 0
          CHECK (external_automation_acknowledged IN (0, 1))
        """,
        """
        ALTER TABLE app_settings
        ADD COLUMN provider_disclosure_acknowledged INTEGER NOT NULL DEFAULT 0
          CHECK (provider_disclosure_acknowledged IN (0, 1))
        """,
        """
        ALTER TABLE app_settings ADD COLUMN github_account TEXT
        """,
        """
        ALTER TABLE app_settings ADD COLUMN github_author_id INTEGER
          CHECK (github_author_id IS NULL OR github_author_id > 0)
        """,
        """
        ALTER TABLE app_settings ADD COLUMN pending_github_account TEXT
        """,
        """
        ALTER TABLE app_settings ADD COLUMN pending_github_author_id INTEGER
          CHECK (pending_github_author_id IS NULL OR pending_github_author_id > 0)
        """,
        """
        ALTER TABLE app_settings ADD COLUMN pending_replacement_sha256 TEXT
          CHECK (
            pending_replacement_sha256 IS NULL
            OR (
              length(pending_replacement_sha256) = 64
              AND pending_replacement_sha256 NOT GLOB '*[^0-9a-f]*'
            )
          )
        """,
        """
        ALTER TABLE app_settings ADD COLUMN previous_github_account TEXT
        """,
        """
        ALTER TABLE app_settings
        ADD COLUMN credential_deletion_pending INTEGER NOT NULL DEFAULT 0
          CHECK (credential_deletion_pending IN (0, 1))
        """,
        """
        ALTER TABLE app_settings
        ADD COLUMN login_item_selected INTEGER NOT NULL DEFAULT 0
          CHECK (login_item_selected IN (0, 1))
        """,
        """
        ALTER TABLE app_settings
        ADD COLUMN login_item_status TEXT NOT NULL DEFAULT 'notRegistered'
          CHECK (login_item_status IN ('notRegistered', 'enabled', 'requiresApproval', 'notFound'))
        """,
        """
        CREATE TRIGGER app_settings_credential_identity_consistent
        BEFORE UPDATE ON app_settings
        WHEN ((NEW.github_account IS NULL) != (NEW.github_author_id IS NULL))
          OR ((NEW.pending_github_account IS NULL) != (NEW.pending_github_author_id IS NULL))
          OR ((NEW.pending_github_account IS NULL) != (NEW.pending_replacement_sha256 IS NULL))
          OR (
            NEW.credential_deletion_pending = 1
            AND (
              NEW.github_account IS NULL
              OR NEW.pending_github_account IS NOT NULL
              OR NEW.previous_github_account IS NOT NULL
            )
          )
        BEGIN
          SELECT RAISE(ABORT, 'credential identity is incomplete');
        END
        """,
        """
        INSERT OR IGNORE INTO model_profiles(role, provider, model, thinking, updated_at)
        VALUES
          ('review', 'openai-codex', 'gpt-5.6-sol', 'max', unixepoch('subsec')),
          ('triage', 'openai-codex', 'gpt-5.6-sol', 'max', unixepoch('subsec')),
          ('planning', 'openai-codex', 'gpt-5.6-sol', 'max', unixepoch('subsec')),
          ('orchestration', 'openai-codex', 'gpt-5.6-sol', 'max', unixepoch('subsec'))
        """,
      ]
    ),
    SQLiteMigration(
      version: 3,
      name: "herdr-durable-runtime",
      requiresBackup: true,
      statements: [
        """
        ALTER TABLE pi_runs RENAME TO pi_runs_legacy_v1
        """,
        """
        CREATE TABLE pi_runs (
          id TEXT PRIMARY KEY,
          job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE RESTRICT,
          runtime_kind TEXT NOT NULL CHECK (runtime_kind IN ('rpcLegacy', 'herdr')),
          workflow TEXT CHECK (workflow IS NULL OR workflow IN (
            'pr-review', 'issue-triage', 'planning', 'orchestration'
          )),
          role TEXT NOT NULL,
          round INTEGER CHECK (round IS NULL OR round BETWEEN 1 AND 3),
          job_attempt INTEGER CHECK (job_attempt IS NULL OR job_attempt >= 0),
          topology_generation INTEGER CHECK (
            topology_generation IS NULL OR topology_generation > 0
          ),
          job_step INTEGER CHECK (job_step IS NULL OR job_step >= 0),
          resumes_run_id TEXT REFERENCES pi_runs(id) ON DELETE RESTRICT,
          run_nonce TEXT,
          request_sha256 TEXT,
          resource_version TEXT NOT NULL,
          resource_hash TEXT NOT NULL,
          model TEXT NOT NULL,
          session_path TEXT NOT NULL,
          session_id TEXT,
          session_boundary_sha256 TEXT,
          channel_path TEXT,
          accepted INTEGER NOT NULL CHECK (accepted IN (0, 1)),
          settled INTEGER NOT NULL CHECK (settled IN (0, 1)),
          structured_result_digest TEXT,
          outcome TEXT NOT NULL CHECK (
            runtime_kind = 'rpcLegacy'
            OR outcome IN (
              'prepared', 'running', 'settled', 'released', 'interruptedUnknown', 'failed'
            )
          ),
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          CHECK (
            runtime_kind = 'rpcLegacy'
            OR (
              workflow IS NOT NULL
              AND role IN ('triage', 'writer', 'architecture', 'security', 'test', 'synthesis')
              AND round IS NOT NULL
              AND job_attempt IS NOT NULL
              AND topology_generation IS NOT NULL
              AND job_step IS NOT NULL
              AND length(run_nonce) = 64
              AND run_nonce NOT GLOB '*[^0-9a-f]*'
              AND length(request_sha256) = 64
              AND request_sha256 NOT GLOB '*[^0-9a-f]*'
              AND channel_path IS NOT NULL
            )
          ),
          CHECK (
            session_id IS NULL
            OR (
              length(session_id) = 36
              AND session_id NOT GLOB '*[^0-9a-f-]*'
              AND substr(session_id, 9, 1) = '-'
              AND substr(session_id, 14, 1) = '-'
              AND substr(session_id, 19, 1) = '-'
              AND substr(session_id, 24, 1) = '-'
            )
          ),
          CHECK (
            session_boundary_sha256 IS NULL
            OR (
              length(session_boundary_sha256) = 64
              AND session_boundary_sha256 NOT GLOB '*[^0-9a-f]*'
            )
          ),
          CHECK (
            structured_result_digest IS NULL
            OR (
              length(structured_result_digest) = 64
              AND structured_result_digest NOT GLOB '*[^0-9a-f]*'
            )
          )
        ) STRICT
        """,
        """
        INSERT INTO pi_runs(
          id, job_id, runtime_kind, workflow, role, round, job_attempt,
          topology_generation, job_step, resumes_run_id,
          run_nonce, request_sha256, resource_version, resource_hash, model,
          session_path, session_id, session_boundary_sha256, channel_path,
          accepted, settled, structured_result_digest, outcome, created_at, updated_at
        )
        SELECT
          id, job_id, 'rpcLegacy', NULL, role, NULL, NULL,
          NULL, NULL, NULL,
          NULL, NULL, resource_version, resource_hash, model,
          session_path, NULL, NULL, NULL,
          accepted, settled, structured_result_digest, outcome, created_at, created_at
        FROM pi_runs_legacy_v1
        """,
        """
        DROP TABLE pi_runs_legacy_v1
        """,
        """
        CREATE INDEX pi_runs_job_runtime_idx
        ON pi_runs(job_id, runtime_kind, workflow, role, round, created_at)
        """,
        """
        CREATE UNIQUE INDEX pi_runs_herdr_logical_slot_idx
        ON pi_runs(job_id, topology_generation, job_step, workflow, role, round)
        WHERE runtime_kind = 'herdr'
        """,
        """
        CREATE INDEX pi_runs_resumes_idx ON pi_runs(resumes_run_id)
        """,
        """
        CREATE TABLE herdr_repository_bindings (
          repository_id TEXT PRIMARY KEY REFERENCES repositories(id) ON DELETE RESTRICT,
          workspace_id TEXT NOT NULL,
          identity_root TEXT NOT NULL,
          herdr_version TEXT NOT NULL,
          herdr_protocol INTEGER NOT NULL CHECK (herdr_protocol > 0),
          socket_device INTEGER NOT NULL CHECK (socket_device >= 0),
          socket_inode INTEGER NOT NULL CHECK (socket_inode > 0),
          socket_owner INTEGER NOT NULL CHECK (socket_owner >= 0),
          socket_permissions INTEGER NOT NULL CHECK (socket_permissions BETWEEN 0 AND 511),
          state TEXT NOT NULL CHECK (state IN ('active', 'lost')),
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
        ) STRICT
        """,
        """
        CREATE UNIQUE INDEX herdr_repository_bindings_active_workspace_idx
        ON herdr_repository_bindings(workspace_id) WHERE state = 'active'
        """,
        """
        CREATE TABLE herdr_repository_binding_history (
          id INTEGER PRIMARY KEY,
          repository_id TEXT NOT NULL REFERENCES repositories(id) ON DELETE RESTRICT,
          workspace_id TEXT NOT NULL,
          identity_root TEXT NOT NULL,
          herdr_version TEXT NOT NULL,
          herdr_protocol INTEGER NOT NULL,
          socket_device INTEGER NOT NULL,
          socket_inode INTEGER NOT NULL,
          socket_owner INTEGER NOT NULL,
          socket_permissions INTEGER NOT NULL,
          reason TEXT NOT NULL CHECK (reason = 'SOCKET_CHANGED'),
          invalidated_at REAL NOT NULL
        ) STRICT
        """,
        """
        CREATE INDEX herdr_repository_binding_history_repository_idx
        ON herdr_repository_binding_history(repository_id, invalidated_at)
        """,
        """
        CREATE TABLE herdr_job_bindings (
          job_id TEXT PRIMARY KEY REFERENCES jobs(id) ON DELETE RESTRICT,
          repository_id TEXT NOT NULL REFERENCES repositories(id) ON DELETE RESTRICT,
          generation INTEGER NOT NULL CHECK (generation > 0),
          workspace_id TEXT NOT NULL,
          tab_id TEXT,
          state TEXT NOT NULL CHECK (state IN ('prepared', 'active', 'closed', 'lost')),
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          FOREIGN KEY(repository_id) REFERENCES herdr_repository_bindings(repository_id)
            ON DELETE RESTRICT,
          UNIQUE(job_id, generation),
          CHECK (
            (state = 'prepared' AND tab_id IS NULL)
            OR (state IN ('active', 'closed') AND tab_id IS NOT NULL)
            OR state = 'lost'
          )
        ) STRICT
        """,
        """
        CREATE INDEX herdr_job_bindings_repository_idx
        ON herdr_job_bindings(repository_id, state)
        """,
        """
        CREATE UNIQUE INDEX herdr_job_bindings_active_tab_idx
        ON herdr_job_bindings(tab_id) WHERE state = 'active'
        """,
        """
        CREATE TABLE herdr_role_hosts (
          id TEXT PRIMARY KEY,
          job_id TEXT NOT NULL REFERENCES herdr_job_bindings(job_id) ON DELETE RESTRICT,
          generation INTEGER NOT NULL CHECK (generation > 0),
          role TEXT NOT NULL CHECK (role IN (
            'triage', 'writer', 'architecture', 'security', 'test', 'synthesis'
          )),
          workspace_id TEXT NOT NULL,
          tab_id TEXT,
          pane_id TEXT,
          terminal_id TEXT,
          bootstrap_descriptor_sha256 TEXT NOT NULL CHECK (
            length(bootstrap_descriptor_sha256) = 64
            AND bootstrap_descriptor_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          host_executable_sha256 TEXT NOT NULL CHECK (
            length(host_executable_sha256) = 64
            AND host_executable_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          host_pid INTEGER CHECK (host_pid IS NULL OR host_pid > 0),
          host_start_seconds INTEGER CHECK (host_start_seconds IS NULL OR host_start_seconds >= 0),
          host_start_microseconds INTEGER CHECK (
            host_start_microseconds IS NULL OR host_start_microseconds BETWEEN 0 AND 999999
          ),
          last_queue_sequence INTEGER NOT NULL DEFAULT 0 CHECK (last_queue_sequence >= 0),
          lifecycle_sequence INTEGER NOT NULL DEFAULT 0 CHECK (lifecycle_sequence >= 0),
          state TEXT NOT NULL CHECK (state IN (
            'prepared', 'waiting', 'running', 'stopping', 'stopped', 'lost'
          )),
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          UNIQUE(job_id, generation, role),
          CHECK (
            (pane_id IS NULL AND terminal_id IS NULL AND tab_id IS NULL
              AND host_pid IS NULL AND host_start_seconds IS NULL
              AND host_start_microseconds IS NULL)
            OR (pane_id IS NOT NULL AND terminal_id IS NOT NULL AND tab_id IS NOT NULL
              AND host_pid IS NOT NULL AND host_start_seconds IS NOT NULL
              AND host_start_microseconds IS NOT NULL)
          )
        ) STRICT
        """,
        """
        CREATE UNIQUE INDEX herdr_role_hosts_active_terminal_idx
        ON herdr_role_hosts(terminal_id)
        WHERE state IN ('waiting', 'running', 'stopping')
        """,
        """
        CREATE UNIQUE INDEX herdr_role_hosts_active_pane_idx
        ON herdr_role_hosts(pane_id)
        WHERE state IN ('waiting', 'running', 'stopping')
        """,
        """
        CREATE TABLE pi_run_launches (
          launch_attempt_id TEXT PRIMARY KEY,
          run_id TEXT NOT NULL REFERENCES pi_runs(id) ON DELETE RESTRICT,
          role_host_id TEXT NOT NULL REFERENCES herdr_role_hosts(id) ON DELETE RESTRICT,
          queue_sequence INTEGER NOT NULL CHECK (queue_sequence > 0),
          launch_mode TEXT NOT NULL CHECK (launch_mode IN (
            'fresh', 'sameRunResume', 'crossRunResume'
          )),
          descriptor_sha256 TEXT NOT NULL CHECK (
            length(descriptor_sha256) = 64
            AND descriptor_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          expected_session_id TEXT,
          resume_boundary_sha256 TEXT,
          state TEXT NOT NULL CHECK (state IN (
            'prepared', 'enqueued', 'running', 'resultPrepared', 'settled',
            'released', 'interruptedUnknown', 'failed'
          )),
          failure_code TEXT,
          child_pid INTEGER,
          child_process_group_id INTEGER,
          child_start_seconds INTEGER,
          child_start_microseconds INTEGER,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          UNIQUE(role_host_id, queue_sequence),
          UNIQUE(run_id, launch_attempt_id),
          CHECK (
            (child_pid IS NULL AND child_process_group_id IS NULL
              AND child_start_seconds IS NULL AND child_start_microseconds IS NULL)
            OR (child_pid > 0 AND child_process_group_id = child_pid
              AND child_start_seconds >= 0
              AND child_start_microseconds BETWEEN 0 AND 999999)
          ),
          CHECK (
            expected_session_id IS NULL
            OR (
              length(expected_session_id) = 36
              AND expected_session_id NOT GLOB '*[^0-9a-f-]*'
              AND substr(expected_session_id, 9, 1) = '-'
              AND substr(expected_session_id, 14, 1) = '-'
              AND substr(expected_session_id, 19, 1) = '-'
              AND substr(expected_session_id, 24, 1) = '-'
            )
          ),
          CHECK (
            (launch_mode = 'fresh' AND expected_session_id IS NULL
              AND resume_boundary_sha256 IS NULL)
            OR (launch_mode = 'sameRunResume' AND expected_session_id IS NOT NULL
              AND (resume_boundary_sha256 IS NULL OR (
                length(resume_boundary_sha256) = 64
                AND resume_boundary_sha256 NOT GLOB '*[^0-9a-f]*'
              )))
            OR (launch_mode = 'crossRunResume' AND expected_session_id IS NOT NULL
              AND length(resume_boundary_sha256) = 64
              AND resume_boundary_sha256 NOT GLOB '*[^0-9a-f]*')
          )
        ) STRICT
        """,
        """
        CREATE INDEX pi_run_launches_run_idx
        ON pi_run_launches(run_id, queue_sequence)
        """,
        """
        CREATE UNIQUE INDEX pi_run_launches_one_active_idx
        ON pi_run_launches(run_id)
        WHERE state IN ('prepared', 'enqueued', 'running', 'resultPrepared')
        """,
        """
        CREATE UNIQUE INDEX pi_run_launches_one_active_host_idx
        ON pi_run_launches(role_host_id)
        WHERE state IN ('prepared', 'enqueued', 'running', 'resultPrepared')
        """,
        """
        CREATE TABLE pi_run_session_origins (
          run_id TEXT PRIMARY KEY REFERENCES pi_runs(id) ON DELETE RESTRICT,
          launch_attempt_id TEXT NOT NULL UNIQUE,
          session_id TEXT NOT NULL CHECK (
            length(session_id) = 36
            AND session_id NOT GLOB '*[^0-9a-f-]*'
            AND substr(session_id, 9, 1) = '-'
            AND substr(session_id, 14, 1) = '-'
            AND substr(session_id, 19, 1) = '-'
            AND substr(session_id, 24, 1) = '-'
          ),
          origin_resume_boundary_sha256 TEXT CHECK (
            origin_resume_boundary_sha256 IS NULL
            OR (
              length(origin_resume_boundary_sha256) = 64
              AND origin_resume_boundary_sha256 NOT GLOB '*[^0-9a-f]*'
            )
          ),
          created_at REAL NOT NULL,
          FOREIGN KEY(run_id, launch_attempt_id)
            REFERENCES pi_run_launches(run_id, launch_attempt_id) ON DELETE RESTRICT
        ) STRICT
        """,
        """
        CREATE TABLE pi_run_results (
          run_id TEXT PRIMARY KEY REFERENCES pi_runs(id) ON DELETE RESTRICT,
          launch_attempt_id TEXT NOT NULL,
          envelope BLOB NOT NULL CHECK (length(envelope) BETWEEN 1 AND 4194304),
          result_sha256 TEXT NOT NULL UNIQUE CHECK (
            length(result_sha256) = 64 AND result_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          session_id TEXT NOT NULL CHECK (
            length(session_id) = 36
            AND session_id NOT GLOB '*[^0-9a-f-]*'
            AND substr(session_id, 9, 1) = '-'
            AND substr(session_id, 14, 1) = '-'
            AND substr(session_id, 19, 1) = '-'
            AND substr(session_id, 24, 1) = '-'
          ),
          session_boundary_sha256 TEXT NOT NULL CHECK (
            length(session_boundary_sha256) = 64
            AND session_boundary_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          settlement_sha256 TEXT NOT NULL UNIQUE CHECK (
            length(settlement_sha256) = 64
            AND settlement_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          created_at REAL NOT NULL,
          FOREIGN KEY(run_id, launch_attempt_id)
            REFERENCES pi_run_launches(run_id, launch_attempt_id) ON DELETE RESTRICT
        ) STRICT
        """,
        """
        CREATE INDEX pi_run_results_launch_idx ON pi_run_results(launch_attempt_id)
        """,
        """
        CREATE TABLE pi_run_events (
          id INTEGER PRIMARY KEY,
          run_id TEXT NOT NULL REFERENCES pi_runs(id) ON DELETE RESTRICT,
          launch_attempt_id TEXT,
          sequence INTEGER NOT NULL CHECK (sequence > 0),
          kind TEXT NOT NULL CHECK (kind IN (
            'prepared', 'enqueued', 'running', 'childProcessRecorded', 'rebound',
            'resultPrepared', 'settled', 'acknowledged', 'released',
            'interruptedUnknown', 'failed'
          )),
          record_sha256 TEXT CHECK (
            record_sha256 IS NULL
            OR (length(record_sha256) = 64 AND record_sha256 NOT GLOB '*[^0-9a-f]*')
          ),
          detail_code TEXT,
          created_at REAL NOT NULL,
          UNIQUE(run_id, sequence),
          FOREIGN KEY(run_id, launch_attempt_id)
            REFERENCES pi_run_launches(run_id, launch_attempt_id) ON DELETE RESTRICT
        ) STRICT
        """,
        """
        CREATE INDEX pi_run_events_run_idx ON pi_run_events(run_id, sequence)
        """,
        """
        CREATE INDEX pi_run_events_launch_idx ON pi_run_events(launch_attempt_id)
        """,
        """
        CREATE UNIQUE INDEX pi_run_events_external_signal_idx
        ON pi_run_events(run_id, launch_attempt_id, kind)
        WHERE kind IN ('acknowledged', 'released')
        """,
        """
        CREATE TABLE herdr_topology_intents (
          id TEXT PRIMARY KEY,
          kind TEXT NOT NULL CHECK (kind IN ('createWorkspace', 'applyLayout')),
          repository_id TEXT NOT NULL REFERENCES repositories(id) ON DELETE RESTRICT,
          job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE RESTRICT,
          generation INTEGER NOT NULL CHECK (generation > 0),
          intent_sha256 TEXT NOT NULL CHECK (
            length(intent_sha256) = 64 AND intent_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          payload_sha256 TEXT NOT NULL CHECK (
            length(payload_sha256) = 64 AND payload_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          socket_device INTEGER NOT NULL CHECK (socket_device >= 0),
          socket_inode INTEGER NOT NULL CHECK (socket_inode > 0),
          socket_owner INTEGER NOT NULL CHECK (socket_owner >= 0),
          socket_permissions INTEGER NOT NULL CHECK (socket_permissions BETWEEN 0 AND 511),
          state TEXT NOT NULL CHECK (state IN (
            'prepared', 'sendStarted', 'attributed', 'unknown'
          )),
          attribution_json TEXT,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
        ) STRICT
        """,
        """
        CREATE UNIQUE INDEX herdr_topology_intents_logical_idx
        ON herdr_topology_intents(
          kind, repository_id, job_id, generation, payload_sha256,
          socket_device, socket_inode, socket_owner, socket_permissions
        )
        """,
        """
        CREATE TRIGGER pi_run_launch_identity_immutable
        BEFORE UPDATE ON pi_run_launches
        WHEN NEW.launch_attempt_id IS NOT OLD.launch_attempt_id
          OR NEW.run_id IS NOT OLD.run_id
          OR NEW.role_host_id IS NOT OLD.role_host_id
          OR NEW.queue_sequence IS NOT OLD.queue_sequence
          OR NEW.launch_mode IS NOT OLD.launch_mode
          OR NEW.descriptor_sha256 IS NOT OLD.descriptor_sha256
          OR NEW.expected_session_id IS NOT OLD.expected_session_id
          OR NEW.resume_boundary_sha256 IS NOT OLD.resume_boundary_sha256
          OR NEW.created_at IS NOT OLD.created_at
          OR (OLD.child_pid IS NOT NULL AND (
            NEW.child_pid IS NOT OLD.child_pid
            OR NEW.child_process_group_id IS NOT OLD.child_process_group_id
            OR NEW.child_start_seconds IS NOT OLD.child_start_seconds
            OR NEW.child_start_microseconds IS NOT OLD.child_start_microseconds
          ))
        BEGIN
          SELECT RAISE(ABORT, 'Pi launch identity is immutable');
        END
        """,
        """
        CREATE TRIGGER pi_run_acknowledgement_event_authority
        BEFORE INSERT ON pi_run_events
        WHEN NEW.kind = 'acknowledged' AND NOT EXISTS (
          SELECT 1
          FROM pi_run_results AS result
          JOIN pi_run_launches AS launch
            ON launch.run_id = result.run_id
            AND launch.launch_attempt_id = result.launch_attempt_id
          JOIN pi_runs AS run ON run.id = result.run_id
          WHERE result.run_id = NEW.run_id
            AND result.launch_attempt_id = NEW.launch_attempt_id
            AND result.result_sha256 = NEW.record_sha256
            AND launch.state IN ('settled', 'released')
            AND run.accepted = 1
            AND run.settled = 1
            AND run.outcome IN ('settled', 'released')
        )
        BEGIN
          SELECT RAISE(ABORT, 'Pi acknowledgement lacks exact result authority');
        END
        """,
        """
        CREATE TRIGGER pi_run_release_event_authority
        BEFORE INSERT ON pi_run_events
        WHEN NEW.kind = 'released' AND NOT EXISTS (
          SELECT 1
          FROM pi_run_results AS result
          JOIN pi_run_launches AS launch
            ON launch.run_id = result.run_id
            AND launch.launch_attempt_id = result.launch_attempt_id
          JOIN pi_runs AS run ON run.id = result.run_id
          JOIN pi_run_events AS acknowledgement
            ON acknowledgement.run_id = result.run_id
            AND acknowledgement.launch_attempt_id = result.launch_attempt_id
          WHERE result.run_id = NEW.run_id
            AND result.launch_attempt_id = NEW.launch_attempt_id
            AND result.result_sha256 = NEW.record_sha256
            AND acknowledgement.kind = 'acknowledged'
            AND acknowledgement.record_sha256 = result.result_sha256
            AND launch.state IN ('settled', 'released')
            AND run.accepted = 1
            AND run.settled = 1
            AND run.outcome IN ('settled', 'released')
        )
        BEGIN
          SELECT RAISE(ABORT, 'Pi release lacks exact acknowledgement authority');
        END
        """,
        """
        CREATE TRIGGER pi_run_release_event_applies_state
        AFTER INSERT ON pi_run_events
        WHEN NEW.kind = 'released'
        BEGIN
          UPDATE pi_run_launches
          SET state = 'released', updated_at = NEW.created_at
          WHERE run_id = NEW.run_id AND launch_attempt_id = NEW.launch_attempt_id;
          UPDATE pi_runs
          SET outcome = 'released', updated_at = NEW.created_at
          WHERE id = NEW.run_id AND runtime_kind = 'herdr';
        END
        """,
        """
        CREATE TRIGGER pi_run_result_insert_authority
        BEFORE INSERT ON pi_run_results
        WHEN NOT EXISTS (
          SELECT 1
          FROM pi_runs AS run
          JOIN pi_run_launches AS launch
            ON launch.run_id = run.id
            AND launch.launch_attempt_id = NEW.launch_attempt_id
          WHERE run.id = NEW.run_id
            AND run.runtime_kind = 'herdr'
            AND run.accepted = 0
            AND run.settled = 0
            AND run.outcome IN ('prepared', 'running', 'interruptedUnknown', 'failed')
            AND launch.state IN (
              'enqueued', 'running', 'resultPrepared', 'interruptedUnknown', 'failed'
            )
        )
        BEGIN
          SELECT RAISE(ABORT, 'Pi result lacks unsettled run and launch authority');
        END
        """,
        """
        CREATE TRIGGER pi_run_result_settles_exact_run
        AFTER INSERT ON pi_run_results
        BEGIN
          UPDATE pi_run_launches
          SET state = 'settled', updated_at = NEW.created_at
          WHERE run_id = NEW.run_id AND launch_attempt_id = NEW.launch_attempt_id;
          UPDATE pi_runs
          SET session_id = NEW.session_id,
            session_boundary_sha256 = NEW.session_boundary_sha256,
            accepted = 1,
            settled = 1,
            structured_result_digest = NEW.result_sha256,
            outcome = 'settled',
            updated_at = NEW.created_at
          WHERE id = NEW.run_id AND runtime_kind = 'herdr';
        END
        """,
        """
        CREATE TRIGGER pi_runs_runtime_kind_immutable
        BEFORE UPDATE OF runtime_kind ON pi_runs
        WHEN NEW.runtime_kind IS NOT OLD.runtime_kind
        BEGIN
          SELECT RAISE(ABORT, 'Pi runtime kind is immutable');
        END
        """,
        """
        CREATE TRIGGER pi_run_session_origin_insert_authority
        BEFORE INSERT ON pi_run_session_origins
        WHEN NOT EXISTS (
          SELECT 1
          FROM pi_runs AS run
          JOIN pi_run_launches AS launch
            ON launch.run_id = run.id
            AND launch.launch_attempt_id = NEW.launch_attempt_id
          WHERE run.id = NEW.run_id
            AND run.runtime_kind = 'herdr'
            AND run.settled = 0
            AND launch.state IN ('failed', 'interruptedUnknown')
            AND launch.queue_sequence = (
              SELECT MIN(first_launch.queue_sequence)
              FROM pi_run_launches AS first_launch
              WHERE first_launch.run_id = run.id
            )
            AND (
              launch.expected_session_id IS NULL
              OR launch.expected_session_id = NEW.session_id
            )
            AND launch.resume_boundary_sha256 IS NEW.origin_resume_boundary_sha256
        )
        BEGIN
          SELECT RAISE(ABORT, 'Pi session origin lacks exact first-launch authority');
        END
        """,
        """
        CREATE TRIGGER pi_run_launch_insert_authority
        BEFORE INSERT ON pi_run_launches
        WHEN NOT EXISTS (
          SELECT 1
          FROM pi_runs AS run
          JOIN herdr_role_hosts AS host ON host.id = NEW.role_host_id
          WHERE run.id = NEW.run_id
            AND run.runtime_kind = 'herdr'
            AND run.settled = 0
            AND host.job_id = run.job_id
            AND host.generation = run.topology_generation
            AND host.role = run.role
            AND host.state IN ('waiting', 'running')
            AND (
              (
                NOT EXISTS (
                  SELECT 1 FROM pi_run_launches AS prior_launch
                  WHERE prior_launch.run_id = run.id
                )
                AND (
                  (
                    run.resumes_run_id IS NULL
                    AND NEW.launch_mode = 'fresh'
                    AND NEW.expected_session_id IS NULL
                    AND NEW.resume_boundary_sha256 IS NULL
                  )
                  OR (
                    run.resumes_run_id IS NOT NULL
                    AND NEW.launch_mode = 'crossRunResume'
                    AND EXISTS (
                      SELECT 1 FROM pi_runs AS origin
                      WHERE origin.id = run.resumes_run_id
                        AND origin.accepted = 1
                        AND origin.settled = 1
                        AND origin.session_id = NEW.expected_session_id
                        AND origin.session_boundary_sha256 = NEW.resume_boundary_sha256
                    )
                  )
                )
              )
              OR (
                EXISTS (
                  SELECT 1 FROM pi_run_launches AS prior_launch
                  WHERE prior_launch.run_id = run.id
                )
                AND NEW.launch_mode = 'sameRunResume'
                AND EXISTS (
                  SELECT 1 FROM pi_run_session_origins AS session_origin
                  WHERE session_origin.run_id = run.id
                    AND session_origin.session_id = NEW.expected_session_id
                    AND session_origin.origin_resume_boundary_sha256
                      IS NEW.resume_boundary_sha256
                )
                AND (
                  SELECT last_launch.state
                  FROM pi_run_launches AS last_launch
                  WHERE last_launch.run_id = run.id
                  ORDER BY last_launch.queue_sequence DESC, last_launch.launch_attempt_id DESC
                  LIMIT 1
                ) IN ('failed', 'interruptedUnknown')
              )
            )
        )
        BEGIN
          SELECT RAISE(ABORT, 'Pi launch lacks exact causal authority');
        END
        """,
        """
        CREATE TRIGGER pi_runs_herdr_identity_immutable
        BEFORE UPDATE ON pi_runs
        WHEN OLD.runtime_kind = 'herdr' AND (
          NEW.id IS NOT OLD.id
          OR NEW.job_id IS NOT OLD.job_id
          OR NEW.runtime_kind IS NOT OLD.runtime_kind
          OR NEW.workflow IS NOT OLD.workflow
          OR NEW.role IS NOT OLD.role
          OR NEW.round IS NOT OLD.round
          OR NEW.job_attempt IS NOT OLD.job_attempt
          OR NEW.topology_generation IS NOT OLD.topology_generation
          OR NEW.job_step IS NOT OLD.job_step
          OR NEW.resumes_run_id IS NOT OLD.resumes_run_id
          OR NEW.run_nonce IS NOT OLD.run_nonce
          OR NEW.request_sha256 IS NOT OLD.request_sha256
          OR NEW.resource_version IS NOT OLD.resource_version
          OR NEW.resource_hash IS NOT OLD.resource_hash
          OR NEW.model IS NOT OLD.model
          OR NEW.session_path IS NOT OLD.session_path
          OR NEW.channel_path IS NOT OLD.channel_path
          OR NEW.created_at IS NOT OLD.created_at
        )
        BEGIN
          SELECT RAISE(ABORT, 'Pi run identity is immutable');
        END
        """,
        """
        CREATE TRIGGER pi_runs_herdr_resume_lineage
        BEFORE INSERT ON pi_runs
        WHEN NEW.runtime_kind = 'herdr' AND NEW.resumes_run_id IS NOT NULL
          AND NOT EXISTS (
            SELECT 1 FROM pi_runs AS prior
            WHERE prior.id = NEW.resumes_run_id
              AND prior.runtime_kind = 'herdr'
              AND prior.job_id = NEW.job_id
              AND prior.workflow = NEW.workflow
              AND prior.role = NEW.role
              AND prior.role = 'writer'
              AND prior.job_step = NEW.job_step
              AND prior.round = NEW.round - 1
              AND prior.accepted = 1
              AND prior.settled = 1
              AND prior.session_id IS NOT NULL
              AND prior.session_boundary_sha256 IS NOT NULL
          )
        BEGIN
          SELECT RAISE(ABORT, 'invalid Pi resume lineage');
        END
        """,
        """
        CREATE TRIGGER pi_runs_herdr_outcome_transition
        BEFORE UPDATE OF outcome ON pi_runs
        WHEN OLD.runtime_kind = 'herdr' AND NEW.outcome IS NOT OLD.outcome AND NOT (
          (OLD.outcome = 'prepared' AND NEW.outcome IN (
            'running', 'settled', 'interruptedUnknown', 'failed'
          ))
          OR (OLD.outcome = 'running' AND NEW.outcome IN (
            'settled', 'interruptedUnknown', 'failed'
          ))
          OR (OLD.outcome IN ('interruptedUnknown', 'failed') AND NEW.outcome = 'settled')
          OR (OLD.outcome = 'settled' AND NEW.outcome = 'released')
        )
        BEGIN
          SELECT RAISE(ABORT, 'invalid Pi run outcome transition');
        END
        """,
        """
        CREATE TRIGGER pi_runs_herdr_settlement_consistency_insert
        BEFORE INSERT ON pi_runs
        WHEN NEW.runtime_kind = 'herdr' AND NOT (
          NEW.accepted = 0 AND NEW.settled = 0
          AND NEW.session_id IS NULL
          AND NEW.session_boundary_sha256 IS NULL
          AND NEW.structured_result_digest IS NULL
          AND NEW.outcome IN ('prepared', 'running', 'interruptedUnknown', 'failed')
        )
        BEGIN
          SELECT RAISE(ABORT, 'invalid initial Pi settlement state');
        END
        """,
        """
        CREATE TRIGGER pi_runs_herdr_settlement_consistency_update
        BEFORE UPDATE ON pi_runs
        WHEN NEW.runtime_kind = 'herdr' AND NOT (
          (
            NEW.accepted = 0 AND NEW.settled = 0
            AND NEW.session_id IS NULL
            AND NEW.session_boundary_sha256 IS NULL
            AND NEW.structured_result_digest IS NULL
            AND NEW.outcome IN ('prepared', 'running', 'interruptedUnknown', 'failed')
          )
          OR (
            NEW.accepted = 1 AND NEW.settled = 1
            AND NEW.session_id IS NOT NULL
            AND NEW.session_boundary_sha256 IS NOT NULL
            AND NEW.structured_result_digest IS NOT NULL
            AND NEW.outcome IN ('settled', 'released')
            AND EXISTS (
              SELECT 1
              FROM pi_run_results AS result
              JOIN pi_run_launches AS launch
                ON launch.run_id = result.run_id
                AND launch.launch_attempt_id = result.launch_attempt_id
              WHERE result.run_id = NEW.id
                AND result.result_sha256 = NEW.structured_result_digest
                AND result.session_id = NEW.session_id
                AND result.session_boundary_sha256 = NEW.session_boundary_sha256
                AND launch.state IN ('settled', 'released')
            )
            AND (
              NEW.outcome != 'released'
              OR EXISTS (
                SELECT 1 FROM pi_run_launches AS launch
                WHERE launch.run_id = NEW.id AND launch.state = 'released'
              )
            )
          )
        )
        BEGIN
          SELECT RAISE(ABORT, 'invalid Pi settlement state');
        END
        """,
        """
        CREATE TRIGGER pi_run_launch_state_transition
        BEFORE UPDATE OF state ON pi_run_launches
        WHEN NEW.state IS NOT OLD.state AND NOT (
          (OLD.state = 'prepared' AND NEW.state IN (
            'enqueued', 'interruptedUnknown', 'failed'
          ))
          OR (OLD.state = 'enqueued' AND NEW.state IN (
            'running', 'resultPrepared', 'settled', 'interruptedUnknown', 'failed'
          ))
          OR (OLD.state = 'running' AND NEW.state IN (
            'resultPrepared', 'settled', 'interruptedUnknown', 'failed'
          ))
          OR (OLD.state = 'resultPrepared' AND NEW.state IN (
            'settled', 'interruptedUnknown', 'failed'
          ))
          OR (OLD.state IN ('interruptedUnknown', 'failed') AND NEW.state = 'settled')
          OR (OLD.state = 'settled' AND NEW.state = 'released')
        )
        BEGIN
          SELECT RAISE(ABORT, 'invalid Pi launch state transition');
        END
        """,
        """
        CREATE TRIGGER pi_run_launch_settlement_authority
        BEFORE UPDATE OF state ON pi_run_launches
        WHEN (
          NEW.state = 'settled'
          AND NOT EXISTS (
            SELECT 1 FROM pi_run_results AS result
            WHERE result.run_id = NEW.run_id
              AND result.launch_attempt_id = NEW.launch_attempt_id
          )
        ) OR (
          NEW.state = 'released'
          AND NOT EXISTS (
            SELECT 1
            FROM pi_run_results AS result
            JOIN pi_run_events AS event
              ON event.run_id = result.run_id
              AND event.launch_attempt_id = result.launch_attempt_id
            WHERE result.run_id = NEW.run_id
              AND result.launch_attempt_id = NEW.launch_attempt_id
              AND event.kind = 'released'
              AND event.record_sha256 = result.result_sha256
          )
        )
        BEGIN
          SELECT RAISE(ABORT, 'Pi launch state lacks durable authority');
        END
        """,
        """
        CREATE TRIGGER pi_runs_settled_identity_immutable
        BEFORE UPDATE ON pi_runs
        WHEN OLD.runtime_kind = 'herdr' AND OLD.settled = 1 AND (
          NEW.id IS NOT OLD.id
          OR NEW.job_id IS NOT OLD.job_id
          OR NEW.runtime_kind IS NOT OLD.runtime_kind
          OR NEW.workflow IS NOT OLD.workflow
          OR NEW.role IS NOT OLD.role
          OR NEW.round IS NOT OLD.round
          OR NEW.job_attempt IS NOT OLD.job_attempt
          OR NEW.topology_generation IS NOT OLD.topology_generation
          OR NEW.job_step IS NOT OLD.job_step
          OR NEW.resumes_run_id IS NOT OLD.resumes_run_id
          OR NEW.run_nonce IS NOT OLD.run_nonce
          OR NEW.request_sha256 IS NOT OLD.request_sha256
          OR NEW.resource_version IS NOT OLD.resource_version
          OR NEW.resource_hash IS NOT OLD.resource_hash
          OR NEW.model IS NOT OLD.model
          OR NEW.session_path IS NOT OLD.session_path
          OR NEW.channel_path IS NOT OLD.channel_path
          OR NEW.session_id IS NOT OLD.session_id
          OR NEW.session_boundary_sha256 IS NOT OLD.session_boundary_sha256
          OR NEW.structured_result_digest IS NOT OLD.structured_result_digest
          OR NEW.accepted IS NOT OLD.accepted
          OR NEW.settled IS NOT OLD.settled
          OR NEW.created_at IS NOT OLD.created_at
        )
        BEGIN
          SELECT RAISE(ABORT, 'settled Pi identity is immutable');
        END
        """,
        """
        CREATE TRIGGER herdr_topology_intent_identity_immutable
        BEFORE UPDATE ON herdr_topology_intents
        WHEN NEW.id IS NOT OLD.id
          OR NEW.kind IS NOT OLD.kind
          OR NEW.repository_id IS NOT OLD.repository_id
          OR NEW.job_id IS NOT OLD.job_id
          OR NEW.generation IS NOT OLD.generation
          OR NEW.intent_sha256 IS NOT OLD.intent_sha256
          OR NEW.payload_sha256 IS NOT OLD.payload_sha256
          OR NEW.socket_device IS NOT OLD.socket_device
          OR NEW.socket_inode IS NOT OLD.socket_inode
          OR NEW.socket_owner IS NOT OLD.socket_owner
          OR NEW.socket_permissions IS NOT OLD.socket_permissions
          OR NEW.created_at IS NOT OLD.created_at
        BEGIN
          SELECT RAISE(ABORT, 'Herdr topology intent identity is immutable');
        END
        """,
        appendOnlyTrigger(table: "herdr_repository_binding_history", operation: "UPDATE"),
        appendOnlyTrigger(table: "herdr_repository_binding_history", operation: "DELETE"),
        appendOnlyTrigger(table: "pi_run_session_origins", operation: "UPDATE"),
        appendOnlyTrigger(table: "pi_run_session_origins", operation: "DELETE"),
        appendOnlyTrigger(table: "pi_run_results", operation: "UPDATE"),
        appendOnlyTrigger(table: "pi_run_results", operation: "DELETE"),
        appendOnlyTrigger(table: "pi_run_events", operation: "UPDATE"),
        appendOnlyTrigger(table: "pi_run_events", operation: "DELETE"),
      ]
    ),
    SQLiteMigration(
      version: 4,
      name: "durable-approved-command-runs",
      requiresBackup: true,
      statements: [
        """
        CREATE TABLE approved_command_runs (
          id TEXT PRIMARY KEY,
          job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE RESTRICT,
          job_attempt INTEGER NOT NULL CHECK (job_attempt >= 0),
          job_step INTEGER NOT NULL CHECK (job_step >= 0),
          phase TEXT NOT NULL CHECK (phase IN ('bootstrap', 'orchestration')),
          round INTEGER NOT NULL CHECK (round BETWEEN 1 AND 3),
          command_ordinal INTEGER NOT NULL CHECK (command_ordinal >= 0),
          command_id TEXT NOT NULL CHECK (length(command_id) BETWEEN 1 AND 128),
          plan_sha256 TEXT NOT NULL CHECK (
            length(plan_sha256) = 64 AND plan_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          definition_sha256 TEXT NOT NULL CHECK (
            length(definition_sha256) = 64 AND definition_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          registry_kind TEXT NOT NULL CHECK (registry_kind IN (
            'makeTargets', 'swiftBuildTest', 'xcodebuildBuildTest',
            'repositoryScript', 'gitRead', 'gitStage', 'gitCommit'
          )),
          workspace_path TEXT NOT NULL CHECK (
            length(workspace_path) BETWEEN 2 AND 4096 AND substr(workspace_path, 1, 1) = '/'
          ),
          workspace_device INTEGER NOT NULL CHECK (workspace_device >= 0),
          workspace_inode INTEGER NOT NULL CHECK (workspace_inode > 0),
          state TEXT NOT NULL CHECK (state IN (
            'prepared', 'started', 'resultAccepted', 'unknown', 'superseded'
          )),
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
        ) STRICT
        """,
        """
        CREATE INDEX approved_command_runs_job_idx
        ON approved_command_runs(job_id, job_step, phase, round, command_ordinal)
        """,
        """
        CREATE UNIQUE INDEX approved_command_runs_active_slot_idx
        ON approved_command_runs(job_id, job_step, phase, round, command_ordinal)
        WHERE state != 'superseded'
        """,
        """
        CREATE UNIQUE INDEX approved_command_runs_active_id_idx
        ON approved_command_runs(job_id, job_step, phase, round, command_id)
        WHERE state != 'superseded'
        """,
        """
        CREATE TABLE approved_command_results (
          run_id TEXT PRIMARY KEY REFERENCES approved_command_runs(id) ON DELETE RESTRICT,
          envelope BLOB NOT NULL CHECK (length(envelope) BETWEEN 1 AND 1048576),
          evidence_sha256 TEXT NOT NULL CHECK (
            length(evidence_sha256) = 64 AND evidence_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          repository_state_sha256 TEXT NOT NULL CHECK (
            length(repository_state_sha256) = 64
            AND repository_state_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          succeeded INTEGER NOT NULL CHECK (succeeded IN (0, 1)),
          created_at REAL NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE approved_command_events (
          id INTEGER PRIMARY KEY,
          run_id TEXT NOT NULL REFERENCES approved_command_runs(id) ON DELETE RESTRICT,
          sequence INTEGER NOT NULL CHECK (sequence > 0),
          kind TEXT NOT NULL CHECK (kind IN (
            'prepared', 'started', 'resultAccepted', 'unknown', 'superseded'
          )),
          record_sha256 TEXT CHECK (
            record_sha256 IS NULL
            OR (length(record_sha256) = 64 AND record_sha256 NOT GLOB '*[^0-9a-f]*')
          ),
          detail_code TEXT,
          created_at REAL NOT NULL,
          UNIQUE(run_id, sequence)
        ) STRICT
        """,
        """
        CREATE INDEX approved_command_events_run_idx
        ON approved_command_events(run_id, sequence)
        """,
        """
        CREATE TRIGGER approved_command_run_identity_immutable
        BEFORE UPDATE ON approved_command_runs
        WHEN NEW.id IS NOT OLD.id
          OR NEW.job_id IS NOT OLD.job_id
          OR NEW.job_attempt IS NOT OLD.job_attempt
          OR NEW.job_step IS NOT OLD.job_step
          OR NEW.phase IS NOT OLD.phase
          OR NEW.round IS NOT OLD.round
          OR NEW.command_ordinal IS NOT OLD.command_ordinal
          OR NEW.command_id IS NOT OLD.command_id
          OR NEW.plan_sha256 IS NOT OLD.plan_sha256
          OR NEW.definition_sha256 IS NOT OLD.definition_sha256
          OR NEW.registry_kind IS NOT OLD.registry_kind
          OR NEW.workspace_path IS NOT OLD.workspace_path
          OR NEW.workspace_device IS NOT OLD.workspace_device
          OR NEW.workspace_inode IS NOT OLD.workspace_inode
          OR NEW.created_at IS NOT OLD.created_at
        BEGIN
          SELECT RAISE(ABORT, 'approved command identity is immutable');
        END
        """,
        """
        CREATE TRIGGER approved_command_run_state_transition
        BEFORE UPDATE OF state ON approved_command_runs
        WHEN NEW.state IS NOT OLD.state AND NOT (
          (OLD.state = 'prepared' AND NEW.state IN ('started', 'superseded'))
          OR (OLD.state = 'started' AND NEW.state IN ('resultAccepted', 'unknown'))
        )
        BEGIN
          SELECT RAISE(ABORT, 'invalid approved command transition');
        END
        """,
        """
        CREATE TRIGGER approved_command_start_authority
        BEFORE UPDATE OF state ON approved_command_runs
        WHEN NEW.state = 'started' AND (
          NOT EXISTS (
            SELECT 1 FROM jobs
            WHERE id = NEW.job_id
              AND state = 'runningPi'
              AND attempt = NEW.job_attempt
              AND current_step = NEW.job_step
          )
          OR NOT EXISTS (
            SELECT 1 FROM app_settings WHERE singleton = 1 AND paused = 0
          )
        )
        BEGIN
          SELECT RAISE(ABORT, 'approved command start lacks current authority');
        END
        """,
        """
        CREATE TRIGGER approved_command_result_requires_started
        BEFORE INSERT ON approved_command_results
        WHEN NOT EXISTS (
          SELECT 1 FROM approved_command_runs
          WHERE id = NEW.run_id AND state = 'started'
        )
        BEGIN
          SELECT RAISE(ABORT, 'approved command result requires started state');
        END
        """,
        """
        CREATE TRIGGER approved_command_acceptance_requires_result
        BEFORE UPDATE OF state ON approved_command_runs
        WHEN NEW.state = 'resultAccepted' AND NOT EXISTS (
          SELECT 1 FROM approved_command_results WHERE run_id = OLD.id
        )
        BEGIN
          SELECT RAISE(ABORT, 'approved command acceptance requires result');
        END
        """,
        appendOnlyTrigger(table: "approved_command_results", operation: "UPDATE"),
        appendOnlyTrigger(table: "approved_command_results", operation: "DELETE"),
        appendOnlyTrigger(table: "approved_command_events", operation: "UPDATE"),
        appendOnlyTrigger(table: "approved_command_events", operation: "DELETE"),
      ]
    ),
    SQLiteMigration(
      version: 5,
      name: "authorized-pre-session-pi-retry",
      requiresBackup: true,
      statements: [
        "DROP TRIGGER pi_run_launch_insert_authority",
        """
        CREATE TRIGGER pi_run_launch_insert_authority
        BEFORE INSERT ON pi_run_launches
        WHEN NOT EXISTS (
          SELECT 1
          FROM pi_runs AS run
          JOIN herdr_role_hosts AS host ON host.id = NEW.role_host_id
          WHERE run.id = NEW.run_id
            AND run.runtime_kind = 'herdr'
            AND run.settled = 0
            AND host.job_id = run.job_id
            AND host.generation = run.topology_generation
            AND host.role = run.role
            AND host.state IN ('waiting', 'running')
            AND (
              (
                NOT EXISTS (
                  SELECT 1 FROM pi_run_launches AS prior_launch
                  WHERE prior_launch.run_id = run.id
                )
                AND (
                  (
                    run.resumes_run_id IS NULL
                    AND NEW.launch_mode = 'fresh'
                    AND NEW.expected_session_id IS NULL
                    AND NEW.resume_boundary_sha256 IS NULL
                  )
                  OR (
                    run.resumes_run_id IS NOT NULL
                    AND NEW.launch_mode = 'crossRunResume'
                    AND EXISTS (
                      SELECT 1 FROM pi_runs AS origin
                      WHERE origin.id = run.resumes_run_id
                        AND origin.accepted = 1
                        AND origin.settled = 1
                        AND origin.session_id = NEW.expected_session_id
                        AND origin.session_boundary_sha256 = NEW.resume_boundary_sha256
                    )
                  )
                )
              )
              OR (
                EXISTS (
                  SELECT 1 FROM pi_run_launches AS prior_launch
                  WHERE prior_launch.run_id = run.id
                )
                AND NEW.launch_mode = 'sameRunResume'
                AND EXISTS (
                  SELECT 1 FROM pi_run_session_origins AS session_origin
                  WHERE session_origin.run_id = run.id
                    AND session_origin.session_id = NEW.expected_session_id
                    AND session_origin.origin_resume_boundary_sha256
                      IS NEW.resume_boundary_sha256
                )
                AND (
                  SELECT last_launch.state
                  FROM pi_run_launches AS last_launch
                  WHERE last_launch.run_id = run.id
                  ORDER BY last_launch.queue_sequence DESC, last_launch.launch_attempt_id DESC
                  LIMIT 1
                ) IN ('failed', 'interruptedUnknown')
              )
              OR (
                NEW.launch_mode = 'fresh'
                AND NEW.expected_session_id IS NULL
                AND NEW.resume_boundary_sha256 IS NULL
                AND (
                  SELECT COUNT(*) FROM pi_run_launches AS prior_launch
                  WHERE prior_launch.run_id = run.id
                ) = 1
                AND EXISTS (
                  SELECT 1 FROM pi_run_launches AS prior_launch
                  WHERE prior_launch.run_id = run.id
                    AND prior_launch.launch_mode = 'fresh'
                    AND prior_launch.queue_sequence = 1
                    AND prior_launch.state = 'failed'
                    AND prior_launch.failure_code = 'RUNTIME_TIMEOUT'
                    AND prior_launch.child_pid IS NOT NULL
                )
                AND NOT EXISTS (
                  SELECT 1 FROM pi_run_session_origins AS session_origin
                  WHERE session_origin.run_id = run.id
                )
                AND NOT EXISTS (
                  SELECT 1 FROM pi_run_results AS result
                  WHERE result.run_id = run.id
                )
                AND (
                  SELECT COUNT(*) FROM job_transitions AS authorization
                  WHERE authorization.job_id = run.job_id
                    AND authorization.from_state = 'runningPi'
                    AND authorization.to_state = 'runningPi'
                    AND authorization.event_key GLOB (
                      'canary:*:pi-fresh-retry:' || run.id || ':' ||
                      (
                        SELECT prior_launch.launch_attempt_id
                        FROM pi_run_launches AS prior_launch
                        WHERE prior_launch.run_id = run.id
                        LIMIT 1
                      ) || ':*'
                    )
                ) = 1
              )
            )
        )
        BEGIN
          SELECT RAISE(ABORT, 'Pi launch lacks exact causal authority');
        END
        """,
      ]
    ),
    SQLiteMigration(
      version: 6,
      name: "authorized-pre-child-herdr-transaction-retry",
      requiresBackup: true,
      statements: [
        "DROP TRIGGER pi_run_launch_insert_authority",
        piRunLaunchInsertAuthorityV6,
      ]
    ),
    SQLiteMigration(
      version: 7,
      name: "authorized-legacy-agent-prime-retry",
      requiresBackup: true,
      statements: [
        "DROP TRIGGER herdr_topology_intent_identity_immutable",
        "DROP INDEX herdr_topology_intents_logical_idx",
        "ALTER TABLE herdr_topology_intents RENAME TO herdr_topology_intents_v6",
        herdrTopologyIntentsTableV7,
        """
        INSERT INTO herdr_topology_intents
        SELECT * FROM herdr_topology_intents_v6
        """,
        "DROP TABLE herdr_topology_intents_v6",
        herdrTopologyIntentsLogicalIndex,
        herdrTopologyIntentIdentityImmutable,
        herdrTopologyIntentStateTransitionV7,
        herdrPrimeIntentDeleteDeniedV7,
        herdrPrimeRetryCandidatesViewV7,
        herdrPrimeIntentInsertAuthorityV7,
        herdrPrimeIntentSendAuthorityV7,
        "DROP TRIGGER pi_run_launch_insert_authority",
        piRunLaunchInsertAuthorityV7,
      ]
    ),
    SQLiteMigration(
      version: 8,
      name: "authorized-pane-agent-authority-reset",
      requiresBackup: true,
      statements: [
        "DROP TRIGGER herdr_topology_intent_identity_immutable",
        "DROP TRIGGER herdr_topology_intent_state_transition",
        "DROP TRIGGER herdr_prime_intent_delete_denied",
        "DROP TRIGGER herdr_prime_intent_insert_authority",
        "DROP TRIGGER herdr_prime_intent_send_authority",
        "DROP TRIGGER pi_run_launch_insert_authority",
        "DROP VIEW herdr_prime_retry_candidates",
        "DROP INDEX herdr_topology_intents_logical_idx",
        "ALTER TABLE herdr_topology_intents RENAME TO herdr_topology_intents_v7",
        herdrTopologyIntentsTableV8,
        """
        INSERT INTO herdr_topology_intents
        SELECT * FROM herdr_topology_intents_v7
        """,
        "DROP TABLE herdr_topology_intents_v7",
        herdrTopologyIntentsLogicalIndex,
        herdrTopologyIntentIdentityImmutable,
        herdrTopologyIntentStateTransitionV7,
        herdrPrimeIntentDeleteDeniedV8,
        herdrPrimeRetryCandidatesViewV7,
        herdrAgentResetCandidatesViewV8,
        herdrQ4AuthorityCandidatesViewV8,
        herdrPrimeIntentInsertAuthorityV8,
        herdrPrimeIntentSendAuthorityV8,
        herdrResetIntentInsertAuthorityV8,
        herdrResetIntentSendAuthorityV8,
        piRunLaunchInsertAuthorityV8,
      ]
    ),
    SQLiteMigration(
      version: 9,
      name: "authorized-architecture-role-host-replacement-and-generation-rollover",
      requiresBackup: true,
      statements: [
        "DROP TRIGGER herdr_topology_intent_identity_immutable",
        "DROP TRIGGER herdr_topology_intent_state_transition",
        "DROP TRIGGER herdr_prime_intent_delete_denied",
        "DROP TRIGGER herdr_prime_intent_insert_authority",
        "DROP TRIGGER herdr_prime_intent_send_authority",
        "DROP TRIGGER herdr_reset_intent_insert_authority",
        "DROP TRIGGER herdr_reset_intent_send_authority",
        "DROP TRIGGER pi_run_launch_insert_authority",
        "DROP TRIGGER pi_run_launch_identity_immutable",
        "DROP VIEW herdr_q4_authority_candidates",
        "DROP VIEW herdr_agent_reset_candidates",
        "DROP VIEW herdr_prime_retry_candidates",
        "DROP INDEX herdr_topology_intents_logical_idx",
        "ALTER TABLE herdr_topology_intents RENAME TO herdr_topology_intents_v8",
        herdrTopologyIntentsTableV9,
        """
        INSERT INTO herdr_topology_intents(
          id, kind, repository_id, job_id, generation, intent_sha256, payload_sha256,
          socket_device, socket_inode, socket_owner, socket_permissions,
          state, attribution_json, created_at, updated_at
        )
        SELECT id, kind, repository_id, job_id, generation, intent_sha256, payload_sha256,
          socket_device, socket_inode, socket_owner, socket_permissions,
          state, attribution_json, created_at, updated_at
        FROM herdr_topology_intents_v8
        """,
        "DROP TABLE herdr_topology_intents_v8",
        herdrTopologyIntentsLogicalIndex,
        herdrTopologyIntentIdentityImmutableV9,
        herdrTopologyIntentStateTransitionV9,
        herdrPrimeIntentDeleteDeniedV9,
        herdrPrimeRetryCandidatesViewV7,
        herdrAgentResetCandidatesViewV8,
        herdrQ4AuthorityCandidatesViewV8,
        herdrRoleHostReplacementCandidatesViewV9,
        herdrRoleHostReplacementAuthorizationsTableV9,
        herdrRoleHostReplacementAuthorizationInsertAuthorityV9,
        herdrRoleHostReplacementAuthorizationUpdateDeniedV9,
        herdrRoleHostReplacementAuthorizationDeleteDeniedV9,
        herdrPrimeIntentInsertAuthorityV8,
        herdrPrimeIntentSendAuthorityV8,
        herdrResetIntentInsertAuthorityV8,
        herdrResetIntentSendAuthorityV8,
        herdrReplacementIntentInsertAuthorityV9,
        herdrReplacementIntentSendAuthorityV9,
        herdrReplacementIntentAttributionAuthorityV9,
        herdrReplacementRoleHostsTableV9,
        herdrReplacementRoleHostsActiveTerminalIndexV9,
        herdrReplacementRoleHostsActivePaneIndexV9,
        herdrReplacementRoleHostsActiveProcessIndexV9,
        herdrOrdinaryRoleHostReplacementInsertCollisionDeniedV9,
        herdrOrdinaryRoleHostReplacementPhysicalCollisionDeniedV9,
        herdrReplacementRoleHostInsertAuthorityV9,
        herdrReplacementRoleHostIdentityImmutableV9,
        herdrReplacementRoleHostStateTransitionV9,
        herdrReplacementRoleHostDeleteDeniedV9,
        herdrReplacedPredecessorImmutableV9,
        "DROP INDEX herdr_repository_binding_history_repository_idx",
        "ALTER TABLE herdr_repository_binding_history RENAME TO herdr_repository_binding_history_v8",
        herdrRepositoryBindingHistoryTableV9,
        """
        INSERT INTO herdr_repository_binding_history
        SELECT * FROM herdr_repository_binding_history_v8
        """,
        "DROP TABLE herdr_repository_binding_history_v8",
        """
        CREATE INDEX herdr_repository_binding_history_repository_idx
        ON herdr_repository_binding_history(repository_id, invalidated_at)
        """,
        appendOnlyTrigger(table: "herdr_repository_binding_history", operation: "UPDATE"),
        appendOnlyTrigger(table: "herdr_repository_binding_history", operation: "DELETE"),
        herdrGenerationRolloverAuthorizationsTableV9,
        herdrGenerationRolloverAuthorizationInsertAuthorityV9,
        herdrGenerationRolloverAuthorizationUpdateDeniedV9,
        herdrGenerationRolloverAuthorizationDeleteDeniedV9,
        herdrPiRunRolloversTableV9,
        herdrPiRunRolloverInsertAuthorityV9,
        herdrPiRunRolloverUpdateDeniedV9,
        herdrPiRunRolloverDeleteDeniedV9,
        herdrRoleHostInitialQueueAuthorityV9,
        piRunsGenerationRolloverInsertAuthorityV9,
        herdrGenerationRolloverPredecessorRunImmutableV9,
        herdrGenerationRolloverPredecessorLaunchImmutableV9,
        herdrGenerationRolloverPredecessorHostImmutableV9,
        herdrJobBindingGenerationRolloverAuthorityV9,
        appSettingsGenerationRolloverResumeDeniedV9,
        appSettingsGenerationRolloverInsertResumeDeniedV9,
        appSettingsGenerationRolloverDeleteDeniedV9,
        "ALTER TABLE pi_run_launches ADD COLUMN execution_role_host_id TEXT REFERENCES herdr_replacement_role_hosts(id) ON DELETE RESTRICT",
        """
        CREATE UNIQUE INDEX pi_run_launches_one_active_execution_host_idx
        ON pi_run_launches(execution_role_host_id)
        WHERE execution_role_host_id IS NOT NULL
          AND state IN ('prepared', 'enqueued', 'running', 'resultPrepared')
        """,
        piRunLaunchIdentityImmutableV9,
        piRunLaunchInsertAuthorityV9,
      ]
    ),
    SQLiteMigration(
      version: 10,
      name: "progressive-production-rollout-authority",
      requiresBackup: true,
      statements: [
        "DROP TRIGGER app_settings_generation_rollover_resume_denied",
        "DROP TRIGGER app_settings_generation_rollover_insert_resume_denied",
        "ALTER TABLE jobs ADD COLUMN rollout_generation INTEGER NOT NULL DEFAULT 0 CHECK (rollout_generation IN (0, 1))",
        """
        CREATE TABLE rollout_authorizations (
          id TEXT PRIMARY KEY CHECK (
            length(id) = 36 AND id = lower(id) AND
            substr(id, 9, 1) = '-' AND substr(id, 14, 1) = '-' AND
            substr(id, 19, 1) = '-' AND substr(id, 24, 1) = '-' AND
            replace(id, '-', '') NOT GLOB '*[^0-9a-f]*'
          ),
          preview_sha256 TEXT NOT NULL UNIQUE CHECK (
            length(preview_sha256) = 64 AND preview_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          policy_version INTEGER NOT NULL CHECK (policy_version = 1),
          state TEXT NOT NULL CHECK (state IN (
            'active', 'draining', 'recoveryRequired', 'settled', 'revoked', 'expired', 'failed'
          )),
          scope_mode TEXT NOT NULL CHECK (scope_mode IN ('exactObject', 'finiteWindow')),
          workflow_stage TEXT NOT NULL CHECK (workflow_stage IN (
            'prReview', 'issueTriage', 'implementationPlan',
            'implementationExecute', 'generatedPRReview'
          )),
          repository_id TEXT NOT NULL REFERENCES repositories(id) ON DELETE RESTRICT,
          activated_at_ms INTEGER NOT NULL CHECK (activated_at_ms >= 0),
          expires_at_ms INTEGER NOT NULL CHECK (expires_at_ms > activated_at_ms),
          updated_at_ms INTEGER NOT NULL CHECK (updated_at_ms >= activated_at_ms),
          terminal_reason TEXT CHECK (
            terminal_reason IS NULL OR
            (length(terminal_reason) BETWEEN 1 AND 128 AND
             terminal_reason NOT GLOB '*[^A-Za-z0-9._:-]*')
          ),
          CHECK (
            (state IN ('active', 'draining', 'recoveryRequired') AND terminal_reason IS NULL) OR
            (state IN ('settled', 'revoked', 'expired', 'failed') AND terminal_reason IS NOT NULL)
          )
        ) STRICT
        """,
        """
        CREATE UNIQUE INDEX rollout_authorizations_one_open_lane_idx
        ON rollout_authorizations((1))
        WHERE state IN ('active', 'draining', 'recoveryRequired')
        """,
        """
        CREATE TABLE rollout_authorization_scopes (
          authorization_id TEXT PRIMARY KEY
            REFERENCES rollout_authorizations(id) ON DELETE RESTRICT,
          repository_node_id TEXT NOT NULL CHECK (length(repository_node_id) BETWEEN 1 AND 256),
          repository_owner TEXT NOT NULL COLLATE NOCASE
            CHECK (length(repository_owner) BETWEEN 1 AND 39),
          repository_name TEXT NOT NULL COLLATE NOCASE
            CHECK (length(repository_name) BETWEEN 1 AND 100),
          default_branch TEXT NOT NULL CHECK (length(default_branch) BETWEEN 1 AND 255),
          repository_enabled INTEGER NOT NULL CHECK (repository_enabled IN (0, 1)),
          review_enabled INTEGER NOT NULL CHECK (review_enabled IN (0, 1)),
          triage_enabled INTEGER NOT NULL CHECK (triage_enabled IN (0, 1)),
          implementation_enabled INTEGER NOT NULL CHECK (implementation_enabled IN (0, 1)),
          object_node_id TEXT CHECK (object_node_id IS NULL OR length(object_node_id) BETWEEN 1 AND 256),
          object_number INTEGER CHECK (object_number IS NULL OR object_number > 0),
          revision_key TEXT CHECK (revision_key IS NULL OR length(revision_key) BETWEEN 1 AND 256),
          canonical_input_sha256 TEXT CHECK (
            canonical_input_sha256 IS NULL OR
            (length(canonical_input_sha256) = 64 AND
             canonical_input_sha256 NOT GLOB '*[^0-9a-f]*')
          ),
          head_sha TEXT CHECK (
            head_sha IS NULL OR
            (length(head_sha) IN (40, 64) AND head_sha NOT GLOB '*[^0-9a-f]*')
          ),
          base_sha TEXT CHECK (
            base_sha IS NULL OR
            (length(base_sha) IN (40, 64) AND base_sha NOT GLOB '*[^0-9a-f]*')
          ),
          plan_sha256 TEXT CHECK (
            plan_sha256 IS NULL OR
            (length(plan_sha256) = 64 AND plan_sha256 NOT GLOB '*[^0-9a-f]*')
          ),
          narrative_sha256 TEXT CHECK (
            narrative_sha256 IS NULL OR
            (length(narrative_sha256) = 64 AND narrative_sha256 NOT GLOB '*[^0-9a-f]*')
          ),
          label_state_sha256 TEXT CHECK (
            label_state_sha256 IS NULL OR
            (length(label_state_sha256) = 64 AND label_state_sha256 NOT GLOB '*[^0-9a-f]*')
          ),
          current_step TEXT NOT NULL CHECK (
            length(current_step) BETWEEN 1 AND 64 AND current_step NOT GLOB '*[^A-Za-z0-9._-]*'
          ),
          finite_predicate_version INTEGER,
          finite_candidates_sha256 TEXT CHECK (
            finite_candidates_sha256 IS NULL OR
            (length(finite_candidates_sha256) = 64 AND
             finite_candidates_sha256 NOT GLOB '*[^0-9a-f]*')
          ),
          finite_candidate_count INTEGER,
          source_commit TEXT NOT NULL CHECK (
            length(source_commit) IN (40, 64) AND source_commit NOT GLOB '*[^0-9a-f]*'
          ),
          source_tree TEXT NOT NULL CHECK (
            length(source_tree) IN (40, 64) AND source_tree NOT GLOB '*[^0-9a-f]*'
          ),
          bundle_version TEXT NOT NULL CHECK (length(bundle_version) BETWEEN 1 AND 32),
          bundle_build INTEGER NOT NULL CHECK (bundle_build > 0),
          application_sha256 TEXT NOT NULL CHECK (
            length(application_sha256) = 64 AND application_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          helper_sha256 TEXT NOT NULL CHECK (
            length(helper_sha256) = 64 AND helper_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          herdr_host_sha256 TEXT NOT NULL CHECK (
            length(herdr_host_sha256) = 64 AND herdr_host_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          schema_version INTEGER NOT NULL CHECK (schema_version = 10),
          engine_protocol_version INTEGER NOT NULL CHECK (engine_protocol_version = 12),
          runtime_manifest_sha256 TEXT NOT NULL CHECK (
            length(runtime_manifest_sha256) = 64 AND
            runtime_manifest_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          runtime_tree_sha256 TEXT NOT NULL CHECK (
            length(runtime_tree_sha256) = 64 AND runtime_tree_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          model_profiles_sha256 TEXT NOT NULL CHECK (
            length(model_profiles_sha256) = 64 AND model_profiles_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          workflow_resources_sha256 TEXT NOT NULL CHECK (
            length(workflow_resources_sha256) = 64 AND
            workflow_resources_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          github_account TEXT NOT NULL CHECK (length(github_account) BETWEEN 1 AND 39),
          github_author_id INTEGER NOT NULL CHECK (github_author_id > 0),
          repository_configuration_sha256 TEXT NOT NULL CHECK (
            length(repository_configuration_sha256) = 64 AND
            repository_configuration_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          queue_inventory_sha256 TEXT NOT NULL CHECK (
            length(queue_inventory_sha256) = 64 AND queue_inventory_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          recovery_inventory_sha256 TEXT NOT NULL CHECK (
            length(recovery_inventory_sha256) = 64 AND
            recovery_inventory_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          mutation_inventory_sha256 TEXT NOT NULL CHECK (
            length(mutation_inventory_sha256) = 64 AND
            mutation_inventory_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          queue_item_count INTEGER NOT NULL CHECK (queue_item_count >= 0),
          recovery_item_count INTEGER NOT NULL CHECK (recovery_item_count >= 0),
          mutation_item_count INTEGER NOT NULL CHECK (mutation_item_count >= 0),
          outside_scope_queue_sha256 TEXT NOT NULL CHECK (
            length(outside_scope_queue_sha256) = 64 AND
            outside_scope_queue_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          outside_scope_recovery_sha256 TEXT NOT NULL CHECK (
            length(outside_scope_recovery_sha256) = 64 AND
            outside_scope_recovery_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          outside_scope_mutation_sha256 TEXT NOT NULL CHECK (
            length(outside_scope_mutation_sha256) = 64 AND
            outside_scope_mutation_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          outside_scope_queue_item_count INTEGER NOT NULL CHECK (
            outside_scope_queue_item_count BETWEEN 0 AND queue_item_count
          ),
          outside_scope_recovery_item_count INTEGER NOT NULL CHECK (
            outside_scope_recovery_item_count BETWEEN 0 AND recovery_item_count
          ),
          outside_scope_mutation_item_count INTEGER NOT NULL CHECK (
            outside_scope_mutation_item_count BETWEEN 0 AND mutation_item_count
          ),
          missing_labels_sha256 TEXT NOT NULL CHECK (
            length(missing_labels_sha256) = 64 AND missing_labels_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          missing_label_count INTEGER NOT NULL CHECK (missing_label_count BETWEEN 0 AND 32),
          command_plan_sha256 TEXT NOT NULL CHECK (
            length(command_plan_sha256) = 64 AND command_plan_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          command_count INTEGER NOT NULL CHECK (command_count BETWEEN 0 AND 128),
          effect_envelope_sha256 TEXT NOT NULL CHECK (
            length(effect_envelope_sha256) = 64 AND effect_envelope_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          preview_json TEXT NOT NULL CHECK (
            length(preview_json) BETWEEN 2 AND 1048576 AND
            json_valid(preview_json) AND json(preview_json) = preview_json
          ),
          CHECK (
            (object_node_id IS NULL AND object_number IS NULL AND revision_key IS NULL AND
             canonical_input_sha256 IS NULL AND finite_predicate_version = 1 AND
             finite_candidates_sha256 IS NOT NULL AND finite_candidate_count >= 0)
            OR
            (object_node_id IS NOT NULL AND object_number IS NOT NULL AND
             revision_key IS NOT NULL AND canonical_input_sha256 IS NOT NULL AND
             finite_predicate_version IS NULL AND finite_candidates_sha256 IS NULL AND
             finite_candidate_count IS NULL)
          )
        ) STRICT
        """,
        """
        CREATE TABLE rollout_authorization_budgets (
          authorization_id TEXT PRIMARY KEY
            REFERENCES rollout_authorizations(id) ON DELETE RESTRICT,
          jobs INTEGER NOT NULL CHECK (jobs BETWEEN 1 AND 10),
          github_read_requests INTEGER NOT NULL CHECK (github_read_requests BETWEEN 0 AND 10000),
          github_read_pages INTEGER NOT NULL CHECK (github_read_pages BETWEEN 0 AND 1000),
          github_read_bytes INTEGER NOT NULL CHECK (github_read_bytes BETWEEN 0 AND 1073741824),
          git_remote_reads INTEGER NOT NULL CHECK (git_remote_reads BETWEEN 0 AND 1000),
          provider_sessions INTEGER NOT NULL CHECK (provider_sessions BETWEEN 0 AND 150),
          approved_commands INTEGER NOT NULL CHECK (approved_commands BETWEEN 0 AND 128),
          marker_parts INTEGER NOT NULL CHECK (marker_parts BETWEEN 0 AND 64),
          label_writes INTEGER NOT NULL CHECK (label_writes BETWEEN 0 AND 64),
          branch_creates INTEGER NOT NULL CHECK (branch_creates BETWEEN 0 AND 10),
          pull_request_creates INTEGER NOT NULL CHECK (pull_request_creates BETWEEN 0 AND 10),
          github_sends INTEGER NOT NULL CHECK (github_sends BETWEEN 0 AND 256),
          git_sends INTEGER NOT NULL CHECK (git_sends BETWEEN 0 AND 32)
        ) STRICT
        """,
        """
        CREATE TRIGGER rollout_authorization_scopes_exact_insert
        BEFORE INSERT ON rollout_authorization_scopes
        WHEN NOT EXISTS (
          SELECT 1
          FROM rollout_authorizations AS authorization
          JOIN repositories AS repository ON repository.id = authorization.repository_id
          WHERE authorization.id = NEW.authorization_id
            AND authorization.state = 'active'
            AND authorization.scope_mode = CASE
              WHEN NEW.object_node_id IS NULL THEN 'finiteWindow' ELSE 'exactObject' END
            AND repository.node_id = NEW.repository_node_id
            AND repository.owner = NEW.repository_owner
            AND repository.name = NEW.repository_name
            AND repository.default_branch = NEW.default_branch
            AND repository.enabled = NEW.repository_enabled
            AND repository.review_enabled = NEW.review_enabled
            AND repository.triage_enabled = NEW.triage_enabled
            AND repository.implementation_enabled = NEW.implementation_enabled
            AND NEW.repository_enabled = 1
            AND (
              (authorization.workflow_stage IN ('prReview', 'generatedPRReview') AND
                NEW.review_enabled = 1) OR
              (authorization.workflow_stage = 'issueTriage' AND NEW.triage_enabled = 1) OR
              (authorization.workflow_stage IN ('implementationPlan', 'implementationExecute')
                AND NEW.implementation_enabled = 1)
            )
        )
        BEGIN
          SELECT RAISE(ABORT, 'rollout scope does not match active repository authority');
        END
        """,
        """
        CREATE TRIGGER rollout_authorization_budgets_stage_insert
        BEFORE INSERT ON rollout_authorization_budgets
        WHEN NOT EXISTS (
          SELECT 1
          FROM rollout_authorizations AS authorization
          JOIN rollout_authorization_scopes AS scope
            ON scope.authorization_id = authorization.id
          WHERE authorization.id = NEW.authorization_id
            AND authorization.state = 'active'
            AND (
              (authorization.scope_mode = 'exactObject' AND NEW.jobs = 1) OR
              authorization.scope_mode = 'finiteWindow'
            )
            AND NEW.provider_sessions <= NEW.jobs * CASE authorization.workflow_stage
              WHEN 'prReview' THEN 4
              WHEN 'generatedPRReview' THEN 4
              WHEN 'issueTriage' THEN 1
              ELSE 15 END
            AND (
              authorization.workflow_stage = 'implementationExecute' OR
              (NEW.approved_commands = 0 AND NEW.branch_creates = 0 AND
                NEW.pull_request_creates = 0 AND NEW.git_sends = 0)
            )
            AND (
              authorization.workflow_stage IN ('prReview', 'generatedPRReview',
                'implementationPlan', 'implementationExecute') OR
              NEW.git_remote_reads = 0
            )
            AND (
              authorization.workflow_stage IN ('issueTriage', 'implementationPlan',
                'implementationExecute') OR NEW.label_writes = 0
            )
        )
        BEGIN
          SELECT RAISE(ABORT, 'rollout budget exceeds stage-derived authority');
        END
        """,
        """
        CREATE TABLE rollout_authorization_events (
          id INTEGER PRIMARY KEY,
          authorization_id TEXT NOT NULL
            REFERENCES rollout_authorizations(id) ON DELETE RESTRICT,
          event_key TEXT NOT NULL UNIQUE CHECK (length(event_key) BETWEEN 1 AND 256),
          kind TEXT NOT NULL CHECK (kind IN (
            'activated', 'recoveryActivated', 'jobBound', 'effectReserved',
            'sendStarted', 'effectObserved', 'drainStarted', 'recoveryRequired',
            'settled', 'revoked', 'expired', 'failed'
          )),
          from_state TEXT CHECK (from_state IS NULL OR from_state IN (
            'active', 'draining', 'recoveryRequired', 'settled', 'revoked', 'expired', 'failed'
          )),
          to_state TEXT NOT NULL CHECK (to_state IN (
            'active', 'draining', 'recoveryRequired', 'settled', 'revoked', 'expired', 'failed'
          )),
          reason_code TEXT NOT NULL CHECK (
            length(reason_code) BETWEEN 1 AND 128 AND reason_code NOT GLOB '*[^A-Za-z0-9._:-]*'
          ),
          checkpoint_sha256 TEXT CHECK (
            checkpoint_sha256 IS NULL OR
            (length(checkpoint_sha256) = 64 AND checkpoint_sha256 NOT GLOB '*[^0-9a-f]*')
          ),
          created_at_ms INTEGER NOT NULL CHECK (created_at_ms >= 0)
        ) STRICT
        """,
        """
        CREATE INDEX rollout_authorization_events_authorization_idx
        ON rollout_authorization_events(authorization_id, id)
        """,
        """
        CREATE TRIGGER rollout_authorization_events_state_evidence
        BEFORE INSERT ON rollout_authorization_events
        WHEN NOT EXISTS (
          SELECT 1 FROM rollout_authorizations AS authorization
          WHERE authorization.id = NEW.authorization_id
            AND authorization.state = NEW.to_state
            AND (
              (NEW.kind = 'activated' AND NEW.from_state IS NULL AND
                NEW.to_state = 'active') OR
              (NEW.kind = 'recoveryActivated' AND
                NEW.from_state = 'recoveryRequired' AND NEW.to_state = 'active') OR
              (NEW.kind IN ('jobBound', 'effectReserved', 'sendStarted', 'effectObserved')
                AND NEW.from_state = NEW.to_state) OR
              (NEW.kind = 'drainStarted' AND NEW.from_state = 'active' AND
                NEW.to_state = 'draining') OR
              (NEW.kind = 'recoveryRequired' AND
                NEW.from_state IN ('active', 'draining') AND
                NEW.to_state = 'recoveryRequired') OR
              (NEW.kind = 'settled' AND
                NEW.from_state IN ('active', 'draining', 'recoveryRequired') AND
                NEW.to_state = 'settled') OR
              (NEW.kind = 'revoked' AND
                NEW.from_state IN ('active', 'draining', 'recoveryRequired') AND
                NEW.to_state = 'revoked') OR
              (NEW.kind = 'expired' AND
                NEW.from_state IN ('active', 'draining', 'recoveryRequired') AND
                NEW.to_state = 'expired') OR
              (NEW.kind = 'failed' AND
                NEW.from_state IN ('active', 'draining', 'recoveryRequired') AND
                NEW.to_state = 'failed')
            )
        )
        BEGIN
          SELECT RAISE(ABORT, 'rollout event does not evidence current state');
        END
        """,
        """
        CREATE TABLE rollout_window_candidates (
          authorization_id TEXT NOT NULL
            REFERENCES rollout_authorizations(id) ON DELETE RESTRICT,
          ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
          object_node_id TEXT NOT NULL CHECK (length(object_node_id) BETWEEN 1 AND 256),
          object_number INTEGER NOT NULL CHECK (object_number > 0),
          revision_key TEXT NOT NULL CHECK (length(revision_key) BETWEEN 1 AND 256),
          canonical_input_sha256 TEXT NOT NULL CHECK (
            length(canonical_input_sha256) = 64 AND
            canonical_input_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          PRIMARY KEY(authorization_id, ordinal),
          UNIQUE(authorization_id, object_node_id, revision_key)
        ) STRICT, WITHOUT ROWID
        """,
        """
        CREATE TRIGGER rollout_window_candidates_exact_insert
        BEFORE INSERT ON rollout_window_candidates
        WHEN NOT EXISTS (
          SELECT 1
          FROM rollout_authorizations AS authorization
          JOIN rollout_authorization_scopes AS scope
            ON scope.authorization_id = authorization.id
          WHERE authorization.id = NEW.authorization_id
            AND authorization.state = 'active'
            AND authorization.scope_mode = 'finiteWindow'
            AND (
              NEW.ordinal < scope.finite_candidate_count OR (
                json_extract(
                  scope.preview_json,
                  '$.scope.finiteWindow.allowsFutureObjects'
                ) = 1
                AND NEW.object_number > json_extract(
                  scope.preview_json,
                  '$.scope.finiteWindow.observedObjectNumberUpperBound'
                )
                AND NEW.object_number <= json_extract(
                  scope.preview_json,
                  '$.scope.finiteWindow.maximumFutureObjectNumber'
                )
              )
            )
        )
        BEGIN
          SELECT RAISE(ABORT, 'rollout candidate exceeds finite selector');
        END
        """,
        """
        CREATE TRIGGER jobs_rollout_generation_insert_authority
        BEFORE INSERT ON jobs
        WHEN NEW.rollout_generation = 1 AND NOT EXISTS (
          SELECT 1
          FROM rollout_authorizations AS authorization
          JOIN rollout_authorization_scopes AS scope
            ON scope.authorization_id = authorization.id
          WHERE authorization.state = 'active'
            AND authorization.repository_id = NEW.repository_id
            AND (
              (authorization.workflow_stage IN ('prReview', 'generatedPRReview') AND
                NEW.kind = 'prReview') OR
              (authorization.workflow_stage = 'issueTriage' AND NEW.kind = 'issueTriage') OR
              (authorization.workflow_stage IN ('implementationPlan', 'implementationExecute')
                AND NEW.kind IN ('issueImplementation', 'complexPlan'))
            )
            AND (
              (authorization.scope_mode = 'exactObject' AND
                scope.object_node_id = NEW.object_node_id AND
                scope.revision_key = NEW.revision_key) OR
              (authorization.scope_mode = 'finiteWindow' AND EXISTS (
                SELECT 1 FROM rollout_window_candidates AS candidate
                WHERE candidate.authorization_id = authorization.id
                  AND candidate.object_node_id = NEW.object_node_id
                  AND candidate.revision_key = NEW.revision_key
              ))
            )
        )
        BEGIN
          SELECT RAISE(ABORT, 'rollout-generation job insert lacks active authority');
        END
        """,
        """
        CREATE TRIGGER jobs_rollout_generation_update_authority
        BEFORE UPDATE OF rollout_generation ON jobs
        WHEN NEW.rollout_generation != OLD.rollout_generation AND (
          OLD.rollout_generation != 0 OR NEW.rollout_generation != 1 OR
          NEW.id != OLD.id OR NEW.repository_id != OLD.repository_id OR
          NEW.kind != OLD.kind OR NEW.object_node_id != OLD.object_node_id OR
          NEW.object_number IS NOT OLD.object_number OR NEW.revision_key != OLD.revision_key OR
          NOT EXISTS (
            SELECT 1
            FROM rollout_authorizations AS authorization
            JOIN rollout_authorization_scopes AS scope
              ON scope.authorization_id = authorization.id
            WHERE authorization.state = 'active'
              AND authorization.repository_id = NEW.repository_id
              AND (
                (authorization.workflow_stage IN ('prReview', 'generatedPRReview') AND
                  NEW.kind = 'prReview') OR
                (authorization.workflow_stage = 'issueTriage' AND NEW.kind = 'issueTriage') OR
                (authorization.workflow_stage IN ('implementationPlan', 'implementationExecute')
                  AND NEW.kind IN ('issueImplementation', 'complexPlan'))
              )
              AND (
                (authorization.scope_mode = 'exactObject' AND
                  scope.object_node_id = NEW.object_node_id AND
                  scope.revision_key = NEW.revision_key) OR
                (authorization.scope_mode = 'finiteWindow' AND EXISTS (
                  SELECT 1 FROM rollout_window_candidates AS candidate
                  WHERE candidate.authorization_id = authorization.id
                    AND candidate.object_node_id = NEW.object_node_id
                    AND candidate.revision_key = NEW.revision_key
                ))
              )
          )
        )
        BEGIN
          SELECT RAISE(ABORT, 'rollout generation is monotonic and authority-bound');
        END
        """,
        """
        CREATE TABLE rollout_job_bindings (
          authorization_id TEXT NOT NULL
            REFERENCES rollout_authorizations(id) ON DELETE RESTRICT,
          job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE RESTRICT,
          repository_id TEXT NOT NULL REFERENCES repositories(id) ON DELETE RESTRICT,
          workflow_stage TEXT NOT NULL CHECK (workflow_stage IN (
            'prReview', 'issueTriage', 'implementationPlan',
            'implementationExecute', 'generatedPRReview'
          )),
          object_node_id TEXT NOT NULL CHECK (length(object_node_id) BETWEEN 1 AND 256),
          revision_key TEXT NOT NULL CHECK (length(revision_key) BETWEEN 1 AND 256),
          canonical_input_sha256 TEXT NOT NULL CHECK (
            length(canonical_input_sha256) = 64 AND
            canonical_input_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          current_step TEXT NOT NULL CHECK (
            length(current_step) BETWEEN 1 AND 64 AND current_step NOT GLOB '*[^A-Za-z0-9._-]*'
          ),
          job_slot INTEGER NOT NULL CHECK (job_slot > 0),
          created_at_ms INTEGER NOT NULL CHECK (created_at_ms >= 0),
          PRIMARY KEY(authorization_id, job_id),
          UNIQUE(authorization_id, job_slot)
        ) STRICT, WITHOUT ROWID
        """,
        """
        CREATE INDEX rollout_job_bindings_job_idx
        ON rollout_job_bindings(job_id, authorization_id)
        """,
        """
        CREATE TABLE rollout_job_input_snapshots (
          authorization_id TEXT NOT NULL,
          job_id TEXT NOT NULL,
          ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
          canonical_input_sha256 TEXT NOT NULL CHECK (
            length(canonical_input_sha256) = 64 AND
            canonical_input_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          narrative_sha256 TEXT CHECK (
            narrative_sha256 IS NULL OR
            (length(narrative_sha256) = 64 AND narrative_sha256 NOT GLOB '*[^0-9a-f]*')
          ),
          base_sha TEXT NOT NULL CHECK (
            length(base_sha) IN (40, 64) AND base_sha NOT GLOB '*[^0-9a-f]*'
          ),
          label_state_sha256 TEXT CHECK (
            label_state_sha256 IS NULL OR
            (length(label_state_sha256) = 64 AND label_state_sha256 NOT GLOB '*[^0-9a-f]*')
          ),
          plan_sha256 TEXT CHECK (
            plan_sha256 IS NULL OR
            (length(plan_sha256) = 64 AND plan_sha256 NOT GLOB '*[^0-9a-f]*')
          ),
          created_at_ms INTEGER NOT NULL CHECK (created_at_ms >= 0),
          PRIMARY KEY(authorization_id, job_id, ordinal),
          FOREIGN KEY(authorization_id, job_id)
            REFERENCES rollout_job_bindings(authorization_id, job_id) ON DELETE RESTRICT
        ) STRICT, WITHOUT ROWID
        """,
        """
        CREATE INDEX rollout_job_input_snapshots_latest_idx
        ON rollout_job_input_snapshots(authorization_id, job_id, ordinal DESC)
        """,
        """
        CREATE TABLE rollout_generated_job_links (
          child_job_id TEXT PRIMARY KEY REFERENCES jobs(id) ON DELETE RESTRICT,
          parent_authorization_id TEXT NOT NULL,
          parent_job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE RESTRICT,
          repository_id TEXT NOT NULL REFERENCES repositories(id) ON DELETE RESTRICT,
          head_sha TEXT NOT NULL CHECK (
            length(head_sha) IN (40, 64) AND head_sha NOT GLOB '*[^0-9a-f]*'
          ),
          created_at_ms INTEGER NOT NULL CHECK (created_at_ms >= 0),
          FOREIGN KEY(parent_authorization_id, parent_job_id)
            REFERENCES rollout_job_bindings(authorization_id, job_id) ON DELETE RESTRICT,
          UNIQUE(parent_authorization_id, parent_job_id, child_job_id)
        ) STRICT, WITHOUT ROWID
        """,
        """
        CREATE TRIGGER rollout_generated_job_links_exact_insert
        BEFORE INSERT ON rollout_generated_job_links
        WHEN NOT EXISTS (
          SELECT 1
          FROM rollout_authorizations AS authorization
          JOIN rollout_job_bindings AS binding
            ON binding.authorization_id = authorization.id
           AND binding.job_id = NEW.parent_job_id
          JOIN jobs AS parent ON parent.id = NEW.parent_job_id
          JOIN jobs AS child ON child.id = NEW.child_job_id
          JOIN app_settings AS settings ON settings.singleton = 1
          WHERE authorization.id = NEW.parent_authorization_id
            AND authorization.state = 'active'
            AND authorization.workflow_stage = 'implementationExecute'
            AND authorization.repository_id = NEW.repository_id
            AND parent.repository_id = NEW.repository_id
            AND parent.kind IN ('issueImplementation', 'complexPlan')
            AND parent.state = 'reconciling'
            AND parent.current_step_kind = 'qa'
            AND child.repository_id = NEW.repository_id
            AND child.kind = 'prReview'
            AND child.revision_key = NEW.head_sha
            AND child.rollout_generation = 0
            AND NOT EXISTS (
              SELECT 1 FROM rollout_job_bindings AS child_binding
              WHERE child_binding.job_id = child.id
            )
            AND settings.paused = 0
            AND settings.active_rollout_authorization_id = authorization.id
        )
        BEGIN
          SELECT RAISE(ABORT, 'generated review child lacks quarantined parent authority');
        END
        """,
        """
        CREATE TRIGGER rollout_generated_job_links_immutable
        BEFORE UPDATE ON rollout_generated_job_links
        BEGIN
          SELECT RAISE(ABORT, 'rollout generated job links are immutable');
        END
        """,
        """
        CREATE TRIGGER rollout_generated_job_links_no_delete
        BEFORE DELETE ON rollout_generated_job_links
        BEGIN
          SELECT RAISE(ABORT, 'rollout generated job links are append-only');
        END
        """,
        """
        CREATE TABLE rollout_effect_reservations (
          id TEXT PRIMARY KEY CHECK (
            length(id) = 36 AND id = lower(id) AND
            substr(id, 9, 1) = '-' AND substr(id, 14, 1) = '-' AND
            substr(id, 19, 1) = '-' AND substr(id, 24, 1) = '-' AND
            replace(id, '-', '') NOT GLOB '*[^0-9a-f]*'
          ),
          authorization_id TEXT NOT NULL,
          job_id TEXT NOT NULL,
          kind TEXT NOT NULL CHECK (kind IN (
            'githubRead', 'gitRemoteRead', 'providerSession', 'approvedCommand',
            'markerBatch', 'labelWrite', 'branchCreate', 'pullRequestCreate',
            'githubMutation'
          )),
          operation_sha256 TEXT NOT NULL CHECK (
            length(operation_sha256) = 64 AND operation_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          target_sha256 TEXT NOT NULL CHECK (
            length(target_sha256) = 64 AND target_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
          attempt INTEGER NOT NULL CHECK (attempt > 0),
          github_read_requests INTEGER NOT NULL DEFAULT 0 CHECK (github_read_requests >= 0),
          github_read_pages INTEGER NOT NULL DEFAULT 0 CHECK (github_read_pages >= 0),
          github_read_bytes INTEGER NOT NULL DEFAULT 0 CHECK (github_read_bytes >= 0),
          git_remote_reads INTEGER NOT NULL DEFAULT 0 CHECK (git_remote_reads >= 0),
          provider_sessions INTEGER NOT NULL DEFAULT 0 CHECK (provider_sessions >= 0),
          approved_commands INTEGER NOT NULL DEFAULT 0 CHECK (approved_commands >= 0),
          marker_parts INTEGER NOT NULL DEFAULT 0 CHECK (marker_parts >= 0),
          label_writes INTEGER NOT NULL DEFAULT 0 CHECK (label_writes >= 0),
          branch_creates INTEGER NOT NULL DEFAULT 0 CHECK (branch_creates >= 0),
          pull_request_creates INTEGER NOT NULL DEFAULT 0 CHECK (pull_request_creates >= 0),
          github_sends INTEGER NOT NULL DEFAULT 0 CHECK (github_sends >= 0),
          git_sends INTEGER NOT NULL DEFAULT 0 CHECK (git_sends >= 0),
          state TEXT NOT NULL CHECK (state IN (
            'reserved', 'sendStarted', 'observationRequired', 'attributed', 'settled'
          )),
          mutation_intent_id TEXT REFERENCES mutation_intents(id) ON DELETE RESTRICT,
          created_at_ms INTEGER NOT NULL CHECK (created_at_ms >= 0),
          updated_at_ms INTEGER NOT NULL CHECK (updated_at_ms >= created_at_ms),
          FOREIGN KEY(authorization_id, job_id)
            REFERENCES rollout_job_bindings(authorization_id, job_id) ON DELETE RESTRICT,
          UNIQUE(authorization_id, kind, operation_sha256, ordinal, attempt),
          CHECK (
            github_read_requests + github_read_pages + github_read_bytes +
            git_remote_reads + provider_sessions + approved_commands + marker_parts +
            label_writes + branch_creates + pull_request_creates + github_sends + git_sends > 0
          ),
          CHECK (
            (kind = 'githubRead' AND github_read_requests = 1 AND
              github_read_pages = 1 AND github_read_bytes > 0 AND
              git_remote_reads + provider_sessions + approved_commands + marker_parts +
              label_writes + branch_creates + pull_request_creates + github_sends + git_sends = 0)
            OR
            (kind = 'gitRemoteRead' AND git_remote_reads = 1 AND
              github_read_requests + github_read_pages + github_read_bytes +
              provider_sessions + approved_commands + marker_parts + label_writes +
              branch_creates + pull_request_creates + github_sends + git_sends = 0)
            OR
            (kind = 'providerSession' AND provider_sessions = 1 AND
              github_read_requests + github_read_pages + github_read_bytes + git_remote_reads +
              approved_commands + marker_parts + label_writes + branch_creates +
              pull_request_creates + github_sends + git_sends = 0)
            OR
            (kind = 'approvedCommand' AND approved_commands = 1 AND
              github_read_requests + github_read_pages + github_read_bytes + git_remote_reads +
              provider_sessions + marker_parts + label_writes + branch_creates +
              pull_request_creates + github_sends + git_sends = 0)
            OR
            (kind = 'markerBatch' AND marker_parts = 1 AND github_sends = 1 AND
              github_read_requests + github_read_pages + github_read_bytes + git_remote_reads +
              provider_sessions + approved_commands + label_writes + branch_creates +
              pull_request_creates + git_sends = 0)
            OR
            (kind = 'labelWrite' AND label_writes = 1 AND github_sends = 1 AND
              github_read_requests + github_read_pages + github_read_bytes + git_remote_reads +
              provider_sessions + approved_commands + marker_parts + branch_creates +
              pull_request_creates + git_sends = 0)
            OR
            (kind = 'branchCreate' AND branch_creates = 1 AND git_sends = 1 AND
              github_read_requests + github_read_pages + github_read_bytes + git_remote_reads +
              provider_sessions + approved_commands + marker_parts + label_writes +
              pull_request_creates + github_sends = 0)
            OR
            (kind = 'pullRequestCreate' AND pull_request_creates = 1 AND
              github_sends = 1 AND
              github_read_requests + github_read_pages + github_read_bytes + git_remote_reads +
              provider_sessions + approved_commands + marker_parts + label_writes +
              branch_creates + git_sends = 0)
            OR
            (kind = 'githubMutation' AND github_sends = 1 AND
              github_read_requests + github_read_pages + github_read_bytes + git_remote_reads +
              provider_sessions + approved_commands + marker_parts + label_writes +
              branch_creates + pull_request_creates + git_sends = 0)
          )
        ) STRICT
        """,
        """
        CREATE TABLE rollout_local_effect_bindings (
          reservation_id TEXT PRIMARY KEY
            REFERENCES rollout_effect_reservations(id) ON DELETE RESTRICT,
          kind TEXT NOT NULL CHECK (kind IN ('providerSession', 'approvedCommand')),
          pi_run_id TEXT UNIQUE REFERENCES pi_runs(id) ON DELETE RESTRICT,
          approved_command_run_id TEXT UNIQUE
            REFERENCES approved_command_runs(id) ON DELETE RESTRICT,
          created_at_ms INTEGER NOT NULL CHECK (created_at_ms >= 0),
          CHECK (
            (kind = 'providerSession' AND pi_run_id IS NOT NULL
              AND approved_command_run_id IS NULL)
            OR
            (kind = 'approvedCommand' AND pi_run_id IS NULL
              AND approved_command_run_id IS NOT NULL)
          )
        ) STRICT
        """,
        """
        CREATE TRIGGER rollout_local_effect_bindings_insert_authority
        BEFORE INSERT ON rollout_local_effect_bindings
        WHEN NOT EXISTS (
          SELECT 1
          FROM rollout_effect_reservations AS reservation
          WHERE reservation.id = NEW.reservation_id
            AND reservation.kind = NEW.kind
            AND reservation.state = 'reserved'
            AND (
              (NEW.kind = 'providerSession' AND EXISTS (
                SELECT 1 FROM pi_runs AS run
                WHERE run.id = NEW.pi_run_id
                  AND run.job_id = reservation.job_id
                  AND run.runtime_kind = 'herdr'
              ))
              OR
              (NEW.kind = 'approvedCommand' AND EXISTS (
                SELECT 1 FROM approved_command_runs AS run
                WHERE run.id = NEW.approved_command_run_id
                  AND run.job_id = reservation.job_id
              ))
            )
        )
        BEGIN
          SELECT RAISE(ABORT, 'rollout local effect binding lacks reserved authority');
        END
        """,
        """
        CREATE TRIGGER rollout_local_effect_bindings_immutable
        BEFORE UPDATE ON rollout_local_effect_bindings
        BEGIN
          SELECT RAISE(ABORT, 'rollout local effect bindings are immutable');
        END
        """,
        """
        CREATE TRIGGER rollout_local_effect_bindings_no_delete
        BEFORE DELETE ON rollout_local_effect_bindings
        BEGIN
          SELECT RAISE(ABORT, 'rollout local effect bindings are append-only');
        END
        """,
        """
        CREATE TABLE rollout_scope_read_reservations (
          id TEXT PRIMARY KEY CHECK (
            length(id) = 36 AND id = lower(id) AND
            substr(id, 9, 1) = '-' AND substr(id, 14, 1) = '-' AND
            substr(id, 19, 1) = '-' AND substr(id, 24, 1) = '-' AND
            replace(id, '-', '') NOT GLOB '*[^0-9a-f]*'
          ),
          authorization_id TEXT NOT NULL
            REFERENCES rollout_authorizations(id) ON DELETE RESTRICT,
          operation_sha256 TEXT NOT NULL CHECK (
            length(operation_sha256) = 64 AND operation_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          target_sha256 TEXT NOT NULL CHECK (
            length(target_sha256) = 64 AND target_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
          github_read_requests INTEGER NOT NULL CHECK (github_read_requests = 1),
          github_read_pages INTEGER NOT NULL CHECK (github_read_pages = 1),
          github_read_bytes INTEGER NOT NULL CHECK (github_read_bytes > 0),
          state TEXT NOT NULL CHECK (state IN ('reserved', 'settled')),
          evidence_sha256 TEXT CHECK (
            evidence_sha256 IS NULL OR
            (length(evidence_sha256) = 64 AND evidence_sha256 NOT GLOB '*[^0-9a-f]*')
          ),
          created_at_ms INTEGER NOT NULL CHECK (created_at_ms >= 0),
          updated_at_ms INTEGER NOT NULL CHECK (updated_at_ms >= created_at_ms),
          UNIQUE(authorization_id, ordinal),
          UNIQUE(authorization_id, operation_sha256, ordinal)
        ) STRICT
        """,
        """
        CREATE TABLE rollout_readback_reservations (
          id TEXT PRIMARY KEY CHECK (
            length(id) = 36 AND id = lower(id) AND
            substr(id, 9, 1) = '-' AND substr(id, 14, 1) = '-' AND
            substr(id, 19, 1) = '-' AND substr(id, 24, 1) = '-' AND
            replace(id, '-', '') NOT GLOB '*[^0-9a-f]*'
          ),
          authorization_id TEXT NOT NULL,
          job_id TEXT NOT NULL,
          source_reservation_id TEXT NOT NULL
            REFERENCES rollout_effect_reservations(id) ON DELETE RESTRICT,
          operation_sha256 TEXT NOT NULL CHECK (
            length(operation_sha256) = 64 AND operation_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          target_sha256 TEXT NOT NULL CHECK (
            length(target_sha256) = 64 AND target_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
          github_read_requests INTEGER NOT NULL CHECK (github_read_requests = 1),
          github_read_pages INTEGER NOT NULL CHECK (github_read_pages = 1),
          github_read_bytes INTEGER NOT NULL CHECK (github_read_bytes > 0),
          state TEXT NOT NULL CHECK (state IN ('reserved', 'settled')),
          evidence_sha256 TEXT CHECK (
            evidence_sha256 IS NULL OR
            (length(evidence_sha256) = 64 AND evidence_sha256 NOT GLOB '*[^0-9a-f]*')
          ),
          created_at_ms INTEGER NOT NULL CHECK (created_at_ms >= 0),
          updated_at_ms INTEGER NOT NULL CHECK (updated_at_ms >= created_at_ms),
          FOREIGN KEY(authorization_id, job_id)
            REFERENCES rollout_job_bindings(authorization_id, job_id) ON DELETE RESTRICT,
          UNIQUE(authorization_id, source_reservation_id, ordinal)
        ) STRICT
        """,
        """
        CREATE TABLE rollout_git_readback_reservations (
          id TEXT PRIMARY KEY CHECK (
            length(id) = 36 AND id = lower(id) AND
            substr(id, 9, 1) = '-' AND substr(id, 14, 1) = '-' AND
            substr(id, 19, 1) = '-' AND substr(id, 24, 1) = '-' AND
            replace(id, '-', '') NOT GLOB '*[^0-9a-f]*'
          ),
          authorization_id TEXT NOT NULL,
          job_id TEXT NOT NULL,
          source_reservation_id TEXT NOT NULL
            REFERENCES rollout_effect_reservations(id) ON DELETE RESTRICT,
          operation_sha256 TEXT NOT NULL CHECK (
            length(operation_sha256) = 64 AND operation_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          target_sha256 TEXT NOT NULL CHECK (
            length(target_sha256) = 64 AND target_sha256 NOT GLOB '*[^0-9a-f]*'
          ),
          ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
          git_remote_reads INTEGER NOT NULL CHECK (git_remote_reads = 1),
          state TEXT NOT NULL CHECK (state IN ('reserved', 'settled')),
          evidence_sha256 TEXT CHECK (
            evidence_sha256 IS NULL OR
            (length(evidence_sha256) = 64 AND evidence_sha256 NOT GLOB '*[^0-9a-f]*')
          ),
          created_at_ms INTEGER NOT NULL CHECK (created_at_ms >= 0),
          updated_at_ms INTEGER NOT NULL CHECK (updated_at_ms >= created_at_ms),
          FOREIGN KEY(authorization_id, job_id)
            REFERENCES rollout_job_bindings(authorization_id, job_id) ON DELETE RESTRICT,
          UNIQUE(authorization_id, source_reservation_id, ordinal)
        ) STRICT
        """,
        "ALTER TABLE app_settings ADD COLUMN active_rollout_authorization_id TEXT REFERENCES rollout_authorizations(id) ON DELETE RESTRICT",
        "UPDATE app_settings SET paused = 1, max_concurrency = 1, active_rollout_authorization_id = NULL, updated_at = unixepoch('subsec') WHERE singleton = 1",
        """
        CREATE TRIGGER rollout_authorizations_active_insert_only
        BEFORE INSERT ON rollout_authorizations
        WHEN NEW.state != 'active' OR NEW.terminal_reason IS NOT NULL OR NOT EXISTS (
          SELECT 1 FROM app_settings
          WHERE singleton = 1 AND paused = 1
            AND active_rollout_authorization_id IS NULL AND max_concurrency = 1
        )
        BEGIN
          SELECT RAISE(ABORT, 'rollout authorization activation requires paused empty scope');
        END
        """,
        """
        CREATE TRIGGER rollout_authorizations_identity_immutable
        BEFORE UPDATE ON rollout_authorizations
        WHEN NEW.id != OLD.id OR NEW.preview_sha256 != OLD.preview_sha256 OR
          NEW.policy_version != OLD.policy_version OR NEW.scope_mode != OLD.scope_mode OR
          NEW.workflow_stage != OLD.workflow_stage OR NEW.repository_id != OLD.repository_id OR
          NEW.activated_at_ms != OLD.activated_at_ms OR NEW.expires_at_ms != OLD.expires_at_ms
        BEGIN
          SELECT RAISE(ABORT, 'rollout authorization identity is immutable');
        END
        """,
        """
        CREATE TRIGGER rollout_authorizations_state_transition
        BEFORE UPDATE OF state ON rollout_authorizations
        WHEN NEW.state = OLD.state OR NEW.updated_at_ms < OLD.updated_at_ms OR NOT (
          (OLD.state = 'active' AND NEW.state IN (
            'draining', 'recoveryRequired', 'settled', 'revoked', 'expired', 'failed'
          )) OR
          (OLD.state = 'draining' AND NEW.state IN (
            'recoveryRequired', 'settled', 'revoked', 'expired', 'failed'
          )) OR
          (OLD.state = 'recoveryRequired' AND NEW.state IN (
            'active', 'settled', 'revoked', 'expired', 'failed'
          ))
        )
        BEGIN
          SELECT RAISE(ABORT, 'invalid rollout authorization state transition');
        END
        """,
        """
        CREATE TRIGGER rollout_authorizations_metadata_transition_only
        BEFORE UPDATE OF updated_at_ms, terminal_reason ON rollout_authorizations
        WHEN NEW.state = OLD.state
        BEGIN
          SELECT RAISE(ABORT, 'rollout authorization metadata changes only with state');
        END
        """,
        """
        CREATE TRIGGER rollout_authorizations_open_lane_close_requires_pause
        BEFORE UPDATE OF state ON rollout_authorizations
        WHEN OLD.state IN ('active', 'draining', 'recoveryRequired')
          AND NEW.state != OLD.state
          AND NOT (OLD.state = 'active' AND NEW.state = 'draining')
          AND EXISTS (
            SELECT 1 FROM app_settings
            WHERE singleton = 1 AND paused = 0
              AND active_rollout_authorization_id = OLD.id
          )
        BEGIN
          SELECT RAISE(ABORT, 'rollout lane must pause before terminal transition');
        END
        """,
        appendOnlyTrigger(table: "rollout_authorizations", operation: "DELETE"),
        appendOnlyTrigger(table: "rollout_authorization_scopes", operation: "UPDATE"),
        appendOnlyTrigger(table: "rollout_authorization_scopes", operation: "DELETE"),
        appendOnlyTrigger(table: "rollout_authorization_budgets", operation: "UPDATE"),
        appendOnlyTrigger(table: "rollout_authorization_budgets", operation: "DELETE"),
        appendOnlyTrigger(table: "rollout_authorization_events", operation: "UPDATE"),
        appendOnlyTrigger(table: "rollout_authorization_events", operation: "DELETE"),
        appendOnlyTrigger(table: "rollout_window_candidates", operation: "UPDATE"),
        appendOnlyTrigger(table: "rollout_window_candidates", operation: "DELETE"),
        appendOnlyTrigger(table: "rollout_job_bindings", operation: "UPDATE"),
        appendOnlyTrigger(table: "rollout_job_bindings", operation: "DELETE"),
        appendOnlyTrigger(table: "rollout_job_input_snapshots", operation: "UPDATE"),
        appendOnlyTrigger(table: "rollout_job_input_snapshots", operation: "DELETE"),
        """
        CREATE TRIGGER rollout_job_bindings_exact_authority
        BEFORE INSERT ON rollout_job_bindings
        WHEN NOT EXISTS (
          SELECT 1
          FROM rollout_authorizations AS authorization
          JOIN rollout_authorization_scopes AS scope
            ON scope.authorization_id = authorization.id
          JOIN rollout_authorization_budgets AS budget
            ON budget.authorization_id = authorization.id
          JOIN jobs AS job ON job.id = NEW.job_id
          WHERE authorization.id = NEW.authorization_id
            AND authorization.state = 'active'
            AND authorization.repository_id = NEW.repository_id
            AND authorization.workflow_stage = NEW.workflow_stage
            AND job.rollout_generation = 1
            AND job.repository_id = NEW.repository_id
            AND job.object_node_id = NEW.object_node_id
            AND job.revision_key = NEW.revision_key
            AND job.current_step_kind = NEW.current_step
            AND (
              (NEW.workflow_stage IN ('prReview', 'generatedPRReview') AND job.kind = 'prReview') OR
              (NEW.workflow_stage = 'issueTriage' AND job.kind = 'issueTriage') OR
              (NEW.workflow_stage IN ('implementationPlan', 'implementationExecute') AND
                job.kind IN ('issueImplementation', 'complexPlan'))
            )
            AND NEW.job_slot <= budget.jobs
            AND (
              (authorization.scope_mode = 'exactObject' AND
                scope.object_node_id = NEW.object_node_id AND
                scope.revision_key = NEW.revision_key AND
                scope.canonical_input_sha256 = NEW.canonical_input_sha256) OR
              (authorization.scope_mode = 'finiteWindow' AND EXISTS (
                SELECT 1 FROM rollout_window_candidates AS candidate
                WHERE candidate.authorization_id = authorization.id
                  AND candidate.object_node_id = NEW.object_node_id
                  AND candidate.revision_key = NEW.revision_key
                  AND candidate.canonical_input_sha256 = NEW.canonical_input_sha256
              ))
            )
        )
        BEGIN
          SELECT RAISE(ABORT, 'rollout job binding lacks exact active authority');
        END
        """,
        """
        CREATE TRIGGER rollout_job_input_snapshots_exact_insert
        BEFORE INSERT ON rollout_job_input_snapshots
        WHEN NOT EXISTS (
          SELECT 1
          FROM rollout_job_bindings AS binding
          JOIN rollout_authorizations AS authorization
            ON authorization.id = binding.authorization_id
          JOIN rollout_authorization_scopes AS scope
            ON scope.authorization_id = authorization.id
          JOIN app_settings AS settings ON settings.singleton = 1
          WHERE binding.authorization_id = NEW.authorization_id
            AND binding.job_id = NEW.job_id
            AND authorization.state = 'active'
            AND authorization.expires_at_ms > NEW.created_at_ms
            AND settings.paused = 0
            AND settings.active_rollout_authorization_id = authorization.id
            AND NEW.ordinal = (
              SELECT COALESCE(MAX(existing.ordinal), -1) + 1
              FROM rollout_job_input_snapshots AS existing
              WHERE existing.authorization_id = NEW.authorization_id
                AND existing.job_id = NEW.job_id
            )
            AND NOT EXISTS (
              SELECT 1 FROM rollout_effect_reservations AS effect
              WHERE effect.authorization_id = NEW.authorization_id
                AND effect.job_id = NEW.job_id
                AND effect.kind NOT IN ('githubRead', 'gitRemoteRead')
            )
            AND (
              (authorization.scope_mode = 'exactObject'
                AND NEW.canonical_input_sha256 = scope.canonical_input_sha256
                AND NEW.narrative_sha256 IS scope.narrative_sha256
                AND NEW.base_sha = scope.base_sha
                AND NEW.label_state_sha256 IS scope.label_state_sha256
                AND NEW.plan_sha256 IS scope.plan_sha256)
              OR
              (authorization.scope_mode = 'finiteWindow' AND (
                (authorization.workflow_stage IN ('prReview', 'generatedPRReview')
                  AND NEW.narrative_sha256 IS NOT NULL
                  AND NEW.label_state_sha256 IS NULL AND NEW.plan_sha256 IS NULL)
                OR
                (authorization.workflow_stage IN ('issueTriage', 'implementationPlan')
                  AND NEW.narrative_sha256 IS NULL
                  AND NEW.label_state_sha256 IS NOT NULL AND NEW.plan_sha256 IS NULL)
              ))
            )
        )
        BEGIN
          SELECT RAISE(ABORT, 'rollout job snapshot lacks exact active authority');
        END
        """,
        """
        CREATE TRIGGER rollout_effect_reservations_identity_immutable
        BEFORE UPDATE ON rollout_effect_reservations
        WHEN NEW.id != OLD.id OR NEW.authorization_id != OLD.authorization_id OR
          NEW.job_id != OLD.job_id OR NEW.kind != OLD.kind OR
          NEW.operation_sha256 != OLD.operation_sha256 OR NEW.target_sha256 != OLD.target_sha256 OR
          NEW.ordinal != OLD.ordinal OR NEW.attempt != OLD.attempt OR
          NEW.github_read_requests != OLD.github_read_requests OR
          NEW.github_read_pages != OLD.github_read_pages OR
          NEW.github_read_bytes != OLD.github_read_bytes OR
          NEW.git_remote_reads != OLD.git_remote_reads OR
          NEW.provider_sessions != OLD.provider_sessions OR
          NEW.approved_commands != OLD.approved_commands OR
          NEW.marker_parts != OLD.marker_parts OR NEW.label_writes != OLD.label_writes OR
          NEW.branch_creates != OLD.branch_creates OR
          NEW.pull_request_creates != OLD.pull_request_creates OR
          NEW.github_sends != OLD.github_sends OR NEW.git_sends != OLD.git_sends OR
          NEW.mutation_intent_id IS NOT OLD.mutation_intent_id OR
          NEW.created_at_ms != OLD.created_at_ms
        BEGIN
          SELECT RAISE(ABORT, 'rollout effect reservation identity is immutable');
        END
        """,
        """
        CREATE TRIGGER rollout_effect_reservations_insert_authority
        BEFORE INSERT ON rollout_effect_reservations
        WHEN NEW.state != 'reserved' OR (
          NEW.github_sends + NEW.git_sends = 0 AND NEW.mutation_intent_id IS NOT NULL
        ) OR (
          NEW.github_sends + NEW.git_sends > 0 AND (
            NEW.mutation_intent_id IS NULL OR NOT EXISTS (
              SELECT 1 FROM mutation_intents AS intent
              WHERE intent.id = NEW.mutation_intent_id AND intent.job_id = NEW.job_id
                AND (
                  intent.state = 'prepared' OR (
                    intent.state = 'retryAllowed'
                    AND NEW.attempt = intent.send_epoch + 1
                    AND EXISTS (
                      SELECT 1 FROM rollout_effect_reservations AS prior
                      WHERE prior.authorization_id = NEW.authorization_id
                        AND prior.job_id = NEW.job_id
                        AND prior.mutation_intent_id = NEW.mutation_intent_id
                        AND prior.attempt = intent.send_epoch
                        AND prior.state = 'settled'
                    )
                  )
                )
            )
          )
        )
        BEGIN
          SELECT RAISE(ABORT, 'rollout reservation lacks exact prepared effect authority');
        END
        """,
        """
        CREATE TRIGGER rollout_effect_reservations_state_transition
        BEFORE UPDATE OF state ON rollout_effect_reservations
        WHEN NEW.state = OLD.state OR NOT (
          (OLD.state = 'reserved' AND NEW.state IN ('sendStarted', 'settled')) OR
          (OLD.state = 'sendStarted' AND NEW.state IN (
            'observationRequired', 'attributed', 'settled'
          )) OR
          (OLD.state = 'observationRequired' AND NEW.state IN ('attributed', 'settled')) OR
          (OLD.state = 'attributed' AND NEW.state = 'settled')
        )
        BEGIN
          SELECT RAISE(ABORT, 'invalid rollout effect reservation state transition');
        END
        """,
        appendOnlyTrigger(table: "rollout_effect_reservations", operation: "DELETE"),
        """
        CREATE TRIGGER rollout_scope_read_reservations_identity_immutable
        BEFORE UPDATE ON rollout_scope_read_reservations
        WHEN NEW.id != OLD.id OR NEW.authorization_id != OLD.authorization_id OR
          NEW.operation_sha256 != OLD.operation_sha256 OR
          NEW.target_sha256 != OLD.target_sha256 OR NEW.ordinal != OLD.ordinal OR
          NEW.github_read_requests != OLD.github_read_requests OR
          NEW.github_read_pages != OLD.github_read_pages OR
          NEW.github_read_bytes != OLD.github_read_bytes OR
          NEW.created_at_ms != OLD.created_at_ms
        BEGIN
          SELECT RAISE(ABORT, 'rollout scope read identity is immutable');
        END
        """,
        """
        CREATE TRIGGER rollout_scope_read_reservations_state_transition
        BEFORE UPDATE OF state, evidence_sha256 ON rollout_scope_read_reservations
        WHEN OLD.state != 'reserved' OR NEW.state != 'settled' OR
          NEW.evidence_sha256 IS NULL
        BEGIN
          SELECT RAISE(ABORT, 'invalid rollout scope read settlement');
        END
        """,
        appendOnlyTrigger(table: "rollout_scope_read_reservations", operation: "DELETE"),
        """
        CREATE TRIGGER rollout_scope_read_reservations_active_finite_scope
        BEFORE INSERT ON rollout_scope_read_reservations
        WHEN NEW.state != 'reserved' OR NEW.evidence_sha256 IS NOT NULL OR NOT EXISTS (
          SELECT 1
          FROM rollout_authorizations AS authorization
          JOIN rollout_authorization_budgets AS budget
            ON budget.authorization_id = authorization.id
          JOIN app_settings AS settings ON settings.singleton = 1
          WHERE authorization.id = NEW.authorization_id
            AND authorization.state = 'active'
            AND authorization.scope_mode = 'finiteWindow'
            AND authorization.expires_at_ms > NEW.created_at_ms
            AND settings.paused = 0
            AND settings.active_rollout_authorization_id = authorization.id
            AND (SELECT COALESCE(SUM(github_read_requests), 0)
                 FROM rollout_effect_reservations
                 WHERE authorization_id = NEW.authorization_id)
              + (SELECT COALESCE(SUM(github_read_requests), 0)
                 FROM rollout_scope_read_reservations
                 WHERE authorization_id = NEW.authorization_id)
              + (SELECT COALESCE(SUM(github_read_requests), 0)
                 FROM rollout_readback_reservations
                 WHERE authorization_id = NEW.authorization_id)
              + NEW.github_read_requests <= budget.github_read_requests
            AND (SELECT COALESCE(SUM(github_read_pages), 0)
                 FROM rollout_effect_reservations
                 WHERE authorization_id = NEW.authorization_id)
              + (SELECT COALESCE(SUM(github_read_pages), 0)
                 FROM rollout_scope_read_reservations
                 WHERE authorization_id = NEW.authorization_id)
              + (SELECT COALESCE(SUM(github_read_pages), 0)
                 FROM rollout_readback_reservations
                 WHERE authorization_id = NEW.authorization_id)
              + NEW.github_read_pages <= budget.github_read_pages
            AND (SELECT COALESCE(SUM(github_read_bytes), 0)
                 FROM rollout_effect_reservations
                 WHERE authorization_id = NEW.authorization_id)
              + (SELECT COALESCE(SUM(github_read_bytes), 0)
                 FROM rollout_scope_read_reservations
                 WHERE authorization_id = NEW.authorization_id)
              + (SELECT COALESCE(SUM(github_read_bytes), 0)
                 FROM rollout_readback_reservations
                 WHERE authorization_id = NEW.authorization_id)
              + NEW.github_read_bytes <= budget.github_read_bytes
        )
        BEGIN
          SELECT RAISE(ABORT, 'rollout scope read exceeds active finite budget');
        END
        """,
        """
        CREATE TRIGGER rollout_readback_reservations_identity_immutable
        BEFORE UPDATE ON rollout_readback_reservations
        WHEN NEW.id != OLD.id OR NEW.authorization_id != OLD.authorization_id OR
          NEW.job_id != OLD.job_id OR
          NEW.source_reservation_id != OLD.source_reservation_id OR
          NEW.operation_sha256 != OLD.operation_sha256 OR
          NEW.target_sha256 != OLD.target_sha256 OR NEW.ordinal != OLD.ordinal OR
          NEW.github_read_requests != OLD.github_read_requests OR
          NEW.github_read_pages != OLD.github_read_pages OR
          NEW.github_read_bytes != OLD.github_read_bytes OR
          NEW.created_at_ms != OLD.created_at_ms
        BEGIN
          SELECT RAISE(ABORT, 'rollout readback identity is immutable');
        END
        """,
        """
        CREATE TRIGGER rollout_readback_reservations_state_transition
        BEFORE UPDATE OF state, evidence_sha256 ON rollout_readback_reservations
        WHEN OLD.state != 'reserved' OR NEW.state != 'settled' OR
          NEW.evidence_sha256 IS NULL
        BEGIN
          SELECT RAISE(ABORT, 'invalid rollout readback settlement');
        END
        """,
        appendOnlyTrigger(table: "rollout_readback_reservations", operation: "DELETE"),
        """
        CREATE TRIGGER rollout_readback_reservations_exact_started_effect
        BEFORE INSERT ON rollout_readback_reservations
        WHEN NEW.state != 'reserved' OR NEW.evidence_sha256 IS NOT NULL OR NOT EXISTS (
          SELECT 1
          FROM rollout_effect_reservations AS source
          JOIN rollout_authorizations AS authorization
            ON authorization.id = source.authorization_id
          JOIN rollout_authorization_budgets AS budget
            ON budget.authorization_id = authorization.id
          JOIN app_settings AS settings ON settings.singleton = 1
          WHERE source.id = NEW.source_reservation_id
            AND source.authorization_id = NEW.authorization_id
            AND source.job_id = NEW.job_id
            AND source.mutation_intent_id IS NOT NULL
            AND source.state IN ('sendStarted', 'observationRequired')
            AND (
              (authorization.state = 'active' AND settings.paused = 0 AND
                settings.active_rollout_authorization_id = authorization.id) OR
              (authorization.state IN (
                'draining', 'recoveryRequired', 'settled', 'revoked', 'expired', 'failed'
              ) AND settings.paused = 1)
            )
            AND (SELECT COALESCE(SUM(github_read_requests), 0)
                 FROM rollout_effect_reservations
                 WHERE authorization_id = NEW.authorization_id)
              + (SELECT COALESCE(SUM(github_read_requests), 0)
                 FROM rollout_scope_read_reservations
                 WHERE authorization_id = NEW.authorization_id)
              + (SELECT COALESCE(SUM(github_read_requests), 0)
                 FROM rollout_readback_reservations
                 WHERE authorization_id = NEW.authorization_id)
              + NEW.github_read_requests <= budget.github_read_requests
            AND (SELECT COALESCE(SUM(github_read_pages), 0)
                 FROM rollout_effect_reservations
                 WHERE authorization_id = NEW.authorization_id)
              + (SELECT COALESCE(SUM(github_read_pages), 0)
                 FROM rollout_scope_read_reservations
                 WHERE authorization_id = NEW.authorization_id)
              + (SELECT COALESCE(SUM(github_read_pages), 0)
                 FROM rollout_readback_reservations
                 WHERE authorization_id = NEW.authorization_id)
              + NEW.github_read_pages <= budget.github_read_pages
            AND (SELECT COALESCE(SUM(github_read_bytes), 0)
                 FROM rollout_effect_reservations
                 WHERE authorization_id = NEW.authorization_id)
              + (SELECT COALESCE(SUM(github_read_bytes), 0)
                 FROM rollout_scope_read_reservations
                 WHERE authorization_id = NEW.authorization_id)
              + (SELECT COALESCE(SUM(github_read_bytes), 0)
                 FROM rollout_readback_reservations
                 WHERE authorization_id = NEW.authorization_id)
              + NEW.github_read_bytes <= budget.github_read_bytes
        )
        BEGIN
          SELECT RAISE(ABORT, 'rollout readback lacks an exact started effect or budget');
        END
        """,
        """
        CREATE TRIGGER rollout_git_readback_reservations_identity_immutable
        BEFORE UPDATE ON rollout_git_readback_reservations
        WHEN NEW.id != OLD.id OR NEW.authorization_id != OLD.authorization_id OR
          NEW.job_id != OLD.job_id OR
          NEW.source_reservation_id != OLD.source_reservation_id OR
          NEW.operation_sha256 != OLD.operation_sha256 OR
          NEW.target_sha256 != OLD.target_sha256 OR NEW.ordinal != OLD.ordinal OR
          NEW.git_remote_reads != OLD.git_remote_reads OR
          NEW.created_at_ms != OLD.created_at_ms
        BEGIN
          SELECT RAISE(ABORT, 'rollout Git readback identity is immutable');
        END
        """,
        """
        CREATE TRIGGER rollout_git_readback_reservations_state_transition
        BEFORE UPDATE OF state, evidence_sha256 ON rollout_git_readback_reservations
        WHEN OLD.state != 'reserved' OR NEW.state != 'settled' OR
          NEW.evidence_sha256 IS NULL
        BEGIN
          SELECT RAISE(ABORT, 'invalid rollout Git readback settlement');
        END
        """,
        appendOnlyTrigger(table: "rollout_git_readback_reservations", operation: "DELETE"),
        """
        CREATE TRIGGER rollout_git_readback_reservations_exact_started_effect
        BEFORE INSERT ON rollout_git_readback_reservations
        WHEN NEW.state != 'reserved' OR NEW.evidence_sha256 IS NOT NULL OR NOT EXISTS (
          SELECT 1
          FROM rollout_effect_reservations AS source
          JOIN rollout_authorizations AS authorization
            ON authorization.id = source.authorization_id
          JOIN rollout_authorization_budgets AS budget
            ON budget.authorization_id = authorization.id
          JOIN app_settings AS settings ON settings.singleton = 1
          WHERE source.id = NEW.source_reservation_id
            AND source.authorization_id = NEW.authorization_id
            AND source.job_id = NEW.job_id
            AND source.kind = 'branchCreate'
            AND source.mutation_intent_id IS NOT NULL
            AND source.state IN ('sendStarted', 'observationRequired')
            AND (
              (authorization.state = 'active' AND settings.paused = 0 AND
                settings.active_rollout_authorization_id = authorization.id) OR
              (authorization.state IN (
                'draining', 'recoveryRequired', 'settled', 'revoked', 'expired', 'failed'
              ) AND settings.paused = 1)
            )
            AND (SELECT COALESCE(SUM(git_remote_reads), 0)
                 FROM rollout_effect_reservations
                 WHERE authorization_id = NEW.authorization_id)
              + (SELECT COALESCE(SUM(git_remote_reads), 0)
                 FROM rollout_git_readback_reservations
                 WHERE authorization_id = NEW.authorization_id)
              + NEW.git_remote_reads <= budget.git_remote_reads
        )
        BEGIN
          SELECT RAISE(ABORT, 'rollout Git readback lacks an exact started effect or budget');
        END
        """,
        """
        CREATE TRIGGER rollout_effect_reservations_cap_and_stage
        BEFORE INSERT ON rollout_effect_reservations
        WHEN NOT EXISTS (
          SELECT 1
          FROM rollout_authorizations AS authorization
          JOIN rollout_authorization_budgets AS budget
            ON budget.authorization_id = authorization.id
          JOIN app_settings AS settings ON settings.singleton = 1
          WHERE authorization.id = NEW.authorization_id
            AND authorization.state = 'active'
            AND authorization.expires_at_ms > NEW.created_at_ms
            AND settings.paused = 0
            AND settings.active_rollout_authorization_id = authorization.id
            AND (
              (authorization.workflow_stage IN ('prReview', 'generatedPRReview') AND
                NEW.kind IN ('githubRead', 'gitRemoteRead', 'providerSession', 'markerBatch')) OR
              (authorization.workflow_stage = 'issueTriage' AND
                NEW.kind IN ('githubRead', 'providerSession', 'markerBatch', 'labelWrite')) OR
              (authorization.workflow_stage = 'implementationPlan' AND
                NEW.kind IN (
                  'githubRead', 'gitRemoteRead', 'providerSession', 'markerBatch', 'labelWrite'
                )) OR
              (authorization.workflow_stage = 'implementationExecute' AND
                NEW.kind IN (
                  'githubRead', 'gitRemoteRead', 'providerSession', 'approvedCommand',
                  'markerBatch', 'labelWrite', 'branchCreate', 'pullRequestCreate',
                  'githubMutation'
                ))
            )
            AND (SELECT COALESCE(SUM(github_read_requests), 0)
                 FROM rollout_effect_reservations
                 WHERE authorization_id = NEW.authorization_id)
              + (SELECT COALESCE(SUM(github_read_requests), 0)
                 FROM rollout_scope_read_reservations
                 WHERE authorization_id = NEW.authorization_id)
              + (SELECT COALESCE(SUM(github_read_requests), 0)
                 FROM rollout_readback_reservations
                 WHERE authorization_id = NEW.authorization_id) + NEW.github_read_requests
              <= budget.github_read_requests
            AND (SELECT COALESCE(SUM(github_read_pages), 0)
                 FROM rollout_effect_reservations
                 WHERE authorization_id = NEW.authorization_id)
              + (SELECT COALESCE(SUM(github_read_pages), 0)
                 FROM rollout_scope_read_reservations
                 WHERE authorization_id = NEW.authorization_id)
              + (SELECT COALESCE(SUM(github_read_pages), 0)
                 FROM rollout_readback_reservations
                 WHERE authorization_id = NEW.authorization_id) + NEW.github_read_pages
              <= budget.github_read_pages
            AND (SELECT COALESCE(SUM(github_read_bytes), 0)
                 FROM rollout_effect_reservations
                 WHERE authorization_id = NEW.authorization_id)
              + (SELECT COALESCE(SUM(github_read_bytes), 0)
                 FROM rollout_scope_read_reservations
                 WHERE authorization_id = NEW.authorization_id)
              + (SELECT COALESCE(SUM(github_read_bytes), 0)
                 FROM rollout_readback_reservations
                 WHERE authorization_id = NEW.authorization_id) + NEW.github_read_bytes
              <= budget.github_read_bytes
            AND (SELECT COALESCE(SUM(git_remote_reads), 0)
                 FROM rollout_effect_reservations
                 WHERE authorization_id = NEW.authorization_id)
              + (SELECT COALESCE(SUM(git_remote_reads), 0)
                 FROM rollout_git_readback_reservations
                 WHERE authorization_id = NEW.authorization_id) + NEW.git_remote_reads
              <= budget.git_remote_reads
            AND (SELECT COALESCE(SUM(provider_sessions), 0)
                 FROM rollout_effect_reservations
                 WHERE authorization_id = NEW.authorization_id) + NEW.provider_sessions
              <= budget.provider_sessions
            AND (SELECT COALESCE(SUM(approved_commands), 0)
                 FROM rollout_effect_reservations
                 WHERE authorization_id = NEW.authorization_id) + NEW.approved_commands
              <= budget.approved_commands
            AND (SELECT COALESCE(SUM(marker_parts), 0)
                 FROM rollout_effect_reservations
                 WHERE authorization_id = NEW.authorization_id) + NEW.marker_parts
              <= budget.marker_parts
            AND (SELECT COALESCE(SUM(label_writes), 0)
                 FROM rollout_effect_reservations
                 WHERE authorization_id = NEW.authorization_id) + NEW.label_writes
              <= budget.label_writes
            AND (SELECT COALESCE(SUM(branch_creates), 0)
                 FROM rollout_effect_reservations
                 WHERE authorization_id = NEW.authorization_id) + NEW.branch_creates
              <= budget.branch_creates
            AND (SELECT COALESCE(SUM(pull_request_creates), 0)
                 FROM rollout_effect_reservations
                 WHERE authorization_id = NEW.authorization_id) + NEW.pull_request_creates
              <= budget.pull_request_creates
            AND (SELECT COALESCE(SUM(github_sends), 0)
                 FROM rollout_effect_reservations
                 WHERE authorization_id = NEW.authorization_id) + NEW.github_sends
              <= budget.github_sends
            AND (SELECT COALESCE(SUM(git_sends), 0)
                 FROM rollout_effect_reservations
                 WHERE authorization_id = NEW.authorization_id) + NEW.git_sends
              <= budget.git_sends
        )
        BEGIN
          SELECT RAISE(ABORT, 'rollout effect exceeds active stage or budget');
        END
        """,
        """
        CREATE TRIGGER app_settings_rollout_scope_required
        BEFORE UPDATE OF paused, active_rollout_authorization_id ON app_settings
        WHEN NEW.paused = 0 AND (
          NEW.active_rollout_authorization_id IS NULL OR NOT EXISTS (
            SELECT 1
            FROM rollout_authorizations AS authorization
            JOIN rollout_authorization_scopes AS scope
              ON scope.authorization_id = authorization.id
            JOIN rollout_authorization_budgets AS budget
              ON budget.authorization_id = authorization.id
            JOIN repositories AS repository ON repository.id = authorization.repository_id
            WHERE authorization.id = NEW.active_rollout_authorization_id
              AND authorization.state = 'active'
              AND authorization.expires_at_ms > CAST(NEW.updated_at * 1000 AS INTEGER)
              AND NEW.max_concurrency = 1
              AND repository.node_id = scope.repository_node_id
              AND repository.owner = scope.repository_owner
              AND repository.name = scope.repository_name
              AND repository.default_branch = scope.default_branch
              AND repository.enabled = scope.repository_enabled
              AND repository.review_enabled = scope.review_enabled
              AND repository.triage_enabled = scope.triage_enabled
              AND repository.implementation_enabled = scope.implementation_enabled
              AND (
                (authorization.scope_mode = 'exactObject' AND budget.jobs = 1 AND
                  (SELECT COUNT(*) FROM rollout_job_bindings AS binding
                   WHERE binding.authorization_id = authorization.id) = 1) OR
                (authorization.scope_mode = 'finiteWindow' AND
                  (SELECT COUNT(*) FROM rollout_window_candidates AS candidate
                   WHERE candidate.authorization_id = authorization.id
                     AND candidate.ordinal < scope.finite_candidate_count)
                    = scope.finite_candidate_count)
              )
          )
        )
        BEGIN
          SELECT RAISE(ABORT, 'Resume requires exact active rollout authority');
        END
        """,
        """
        CREATE TRIGGER app_settings_rollout_insert_scope_required
        BEFORE INSERT ON app_settings
        WHEN NEW.paused = 0
        BEGIN
          SELECT RAISE(ABORT, 'Resume requires exact active rollout authority');
        END
        """,
        """
        CREATE TRIGGER app_settings_rollout_concurrency_one
        BEFORE UPDATE OF max_concurrency ON app_settings
        WHEN NEW.max_concurrency != 1
        BEGIN
          SELECT RAISE(ABORT, 'production rollout concurrency must remain one');
        END
        """,
      ]
    ),
  ]

  private static let herdrTopologyIntentsTableV7 = """
    CREATE TABLE herdr_topology_intents (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL CHECK (kind IN (
        'createWorkspace', 'applyLayout', 'primeAgentAuthority'
      )),
      repository_id TEXT NOT NULL REFERENCES repositories(id) ON DELETE RESTRICT,
      job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE RESTRICT,
      generation INTEGER NOT NULL CHECK (generation > 0),
      intent_sha256 TEXT NOT NULL CHECK (
        length(intent_sha256) = 64 AND intent_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      payload_sha256 TEXT NOT NULL CHECK (
        length(payload_sha256) = 64 AND payload_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      socket_device INTEGER NOT NULL CHECK (socket_device >= 0),
      socket_inode INTEGER NOT NULL CHECK (socket_inode > 0),
      socket_owner INTEGER NOT NULL CHECK (socket_owner >= 0),
      socket_permissions INTEGER NOT NULL CHECK (socket_permissions BETWEEN 0 AND 511),
      state TEXT NOT NULL CHECK (state IN (
        'prepared', 'sendStarted', 'attributed', 'unknown'
      )),
      attribution_json TEXT,
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL
    ) STRICT
    """

  private static let herdrTopologyIntentsTableV8 = """
    CREATE TABLE herdr_topology_intents (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL CHECK (kind IN (
        'createWorkspace', 'applyLayout', 'primeAgentAuthority', 'resetAgentAuthority'
      )),
      repository_id TEXT NOT NULL REFERENCES repositories(id) ON DELETE RESTRICT,
      job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE RESTRICT,
      generation INTEGER NOT NULL CHECK (generation > 0),
      intent_sha256 TEXT NOT NULL CHECK (
        length(intent_sha256) = 64 AND intent_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      payload_sha256 TEXT NOT NULL CHECK (
        length(payload_sha256) = 64 AND payload_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      socket_device INTEGER NOT NULL CHECK (socket_device >= 0),
      socket_inode INTEGER NOT NULL CHECK (socket_inode > 0),
      socket_owner INTEGER NOT NULL CHECK (socket_owner >= 0),
      socket_permissions INTEGER NOT NULL CHECK (socket_permissions BETWEEN 0 AND 511),
      state TEXT NOT NULL CHECK (state IN (
        'prepared', 'sendStarted', 'attributed', 'unknown'
      )),
      attribution_json TEXT,
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL
    ) STRICT
    """

  private static let herdrTopologyIntentsTableV9 = """
    CREATE TABLE herdr_topology_intents (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL CHECK (kind IN (
        'createWorkspace', 'applyLayout', 'primeAgentAuthority', 'resetAgentAuthority',
        'replaceRoleHost'
      )),
      repository_id TEXT NOT NULL REFERENCES repositories(id) ON DELETE RESTRICT,
      job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE RESTRICT,
      generation INTEGER NOT NULL CHECK (generation > 0),
      intent_sha256 TEXT NOT NULL CHECK (
        length(intent_sha256) = 64 AND intent_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      payload_sha256 TEXT NOT NULL CHECK (
        length(payload_sha256) = 64 AND payload_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      socket_device INTEGER NOT NULL CHECK (socket_device >= 0),
      socket_inode INTEGER NOT NULL CHECK (socket_inode > 0),
      socket_owner INTEGER NOT NULL CHECK (socket_owner >= 0),
      socket_permissions INTEGER NOT NULL CHECK (socket_permissions BETWEEN 0 AND 511),
      state TEXT NOT NULL CHECK (state IN (
        'prepared', 'sendStarted', 'attributed', 'unknown', 'failedNoRemoteEffect'
      )),
      attribution_json TEXT,
      failure_code TEXT CHECK (
        failure_code IS NULL OR (
          length(failure_code) BETWEEN 3 AND 64
          AND failure_code GLOB '[A-Z]*'
          AND failure_code NOT GLOB '*[^A-Z0-9_]*'
        )
      ),
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL,
      CHECK ((state = 'failedNoRemoteEffect') = (failure_code IS NOT NULL))
    ) STRICT
    """

  private static let herdrTopologyIntentsLogicalIndex = """
    CREATE UNIQUE INDEX herdr_topology_intents_logical_idx
    ON herdr_topology_intents(
      kind, repository_id, job_id, generation, payload_sha256,
      socket_device, socket_inode, socket_owner, socket_permissions
    )
    """

  private static let herdrTopologyIntentIdentityImmutable = """
    CREATE TRIGGER herdr_topology_intent_identity_immutable
    BEFORE UPDATE ON herdr_topology_intents
    WHEN NEW.id IS NOT OLD.id
      OR NEW.kind IS NOT OLD.kind
      OR NEW.repository_id IS NOT OLD.repository_id
      OR NEW.job_id IS NOT OLD.job_id
      OR NEW.generation IS NOT OLD.generation
      OR NEW.intent_sha256 IS NOT OLD.intent_sha256
      OR NEW.payload_sha256 IS NOT OLD.payload_sha256
      OR NEW.socket_device IS NOT OLD.socket_device
      OR NEW.socket_inode IS NOT OLD.socket_inode
      OR NEW.socket_owner IS NOT OLD.socket_owner
      OR NEW.socket_permissions IS NOT OLD.socket_permissions
      OR NEW.created_at IS NOT OLD.created_at
    BEGIN
      SELECT RAISE(ABORT, 'Herdr topology intent identity is immutable');
    END
    """

  private static let herdrTopologyIntentStateTransitionV7 = """
    CREATE TRIGGER herdr_topology_intent_state_transition
    BEFORE UPDATE OF state, attribution_json ON herdr_topology_intents
    WHEN NOT (
      OLD.state = 'prepared' AND NEW.state = 'sendStarted'
        AND OLD.attribution_json IS NULL AND NEW.attribution_json IS NULL
      OR OLD.state = 'sendStarted' AND NEW.state = 'attributed'
        AND OLD.attribution_json IS NULL AND NEW.attribution_json IS NOT NULL
      OR OLD.state = 'sendStarted' AND NEW.state = 'unknown'
        AND OLD.attribution_json IS NULL AND NEW.attribution_json IS NULL
    )
    BEGIN
      SELECT RAISE(ABORT, 'invalid Herdr topology intent transition');
    END
    """

  private static let herdrTopologyIntentIdentityImmutableV9 = """
    CREATE TRIGGER herdr_topology_intent_identity_immutable
    BEFORE UPDATE ON herdr_topology_intents
    WHEN NEW.id IS NOT OLD.id
      OR NEW.kind IS NOT OLD.kind
      OR NEW.repository_id IS NOT OLD.repository_id
      OR NEW.job_id IS NOT OLD.job_id
      OR NEW.generation IS NOT OLD.generation
      OR NEW.intent_sha256 IS NOT OLD.intent_sha256
      OR NEW.payload_sha256 IS NOT OLD.payload_sha256
      OR NEW.socket_device IS NOT OLD.socket_device
      OR NEW.socket_inode IS NOT OLD.socket_inode
      OR NEW.socket_owner IS NOT OLD.socket_owner
      OR NEW.socket_permissions IS NOT OLD.socket_permissions
      OR NEW.created_at IS NOT OLD.created_at
    BEGIN
      SELECT RAISE(ABORT, 'Herdr topology intent identity is immutable');
    END
    """

  private static let herdrTopologyIntentStateTransitionV9 = """
    CREATE TRIGGER herdr_topology_intent_state_transition
    BEFORE UPDATE ON herdr_topology_intents
    WHEN NOT (
      OLD.state = 'prepared' AND NEW.state = 'sendStarted'
        AND OLD.attribution_json IS NULL AND NEW.attribution_json IS NULL
        AND OLD.failure_code IS NULL AND NEW.failure_code IS NULL
        AND NEW.updated_at >= OLD.updated_at
      OR OLD.kind = 'replaceRoleHost'
        AND OLD.state = 'prepared' AND NEW.state = 'failedNoRemoteEffect'
        AND OLD.attribution_json IS NULL AND NEW.attribution_json IS NULL
        AND OLD.failure_code IS NULL AND NEW.failure_code IS NOT NULL
        AND NEW.updated_at >= OLD.updated_at
      OR OLD.state = 'sendStarted' AND NEW.state = 'attributed'
        AND OLD.attribution_json IS NULL AND NEW.attribution_json IS NOT NULL
        AND OLD.failure_code IS NULL AND NEW.failure_code IS NULL
        AND NEW.updated_at >= OLD.updated_at
      OR OLD.state = 'sendStarted' AND NEW.state = 'unknown'
        AND OLD.attribution_json IS NULL AND NEW.attribution_json IS NULL
        AND OLD.failure_code IS NULL AND NEW.failure_code IS NULL
        AND NEW.updated_at >= OLD.updated_at
    )
    BEGIN
      SELECT RAISE(ABORT, 'invalid Herdr topology intent transition');
    END
    """

  private static let piRunLaunchInsertAuthorityV6 = """
    CREATE TRIGGER pi_run_launch_insert_authority
    BEFORE INSERT ON pi_run_launches
    WHEN NOT EXISTS (
      SELECT 1
      FROM pi_runs AS run
      JOIN herdr_role_hosts AS host ON host.id = NEW.role_host_id
      WHERE run.id = NEW.run_id
        AND run.runtime_kind = 'herdr'
        AND run.settled = 0
        AND host.job_id = run.job_id
        AND host.generation = run.topology_generation
        AND host.role = run.role
        AND host.state IN ('waiting', 'running')
        AND (
          (
            NOT EXISTS (
              SELECT 1 FROM pi_run_launches AS prior_launch
              WHERE prior_launch.run_id = run.id
            )
            AND (
              (
                run.resumes_run_id IS NULL
                AND NEW.launch_mode = 'fresh'
                AND NEW.expected_session_id IS NULL
                AND NEW.resume_boundary_sha256 IS NULL
              )
              OR (
                run.resumes_run_id IS NOT NULL
                AND NEW.launch_mode = 'crossRunResume'
                AND EXISTS (
                  SELECT 1 FROM pi_runs AS origin
                  WHERE origin.id = run.resumes_run_id
                    AND origin.accepted = 1
                    AND origin.settled = 1
                    AND origin.session_id = NEW.expected_session_id
                    AND origin.session_boundary_sha256 = NEW.resume_boundary_sha256
                )
              )
            )
          )
          OR (
            EXISTS (
              SELECT 1 FROM pi_run_launches AS prior_launch
              WHERE prior_launch.run_id = run.id
            )
            AND NEW.launch_mode = 'sameRunResume'
            AND EXISTS (
              SELECT 1 FROM pi_run_session_origins AS session_origin
              WHERE session_origin.run_id = run.id
                AND session_origin.session_id = NEW.expected_session_id
                AND session_origin.origin_resume_boundary_sha256
                  IS NEW.resume_boundary_sha256
            )
            AND (
              SELECT last_launch.state
              FROM pi_run_launches AS last_launch
              WHERE last_launch.run_id = run.id
              ORDER BY last_launch.queue_sequence DESC, last_launch.launch_attempt_id DESC
              LIMIT 1
            ) IN ('failed', 'interruptedUnknown')
          )
          OR (
            NEW.launch_mode = 'fresh'
            AND NEW.expected_session_id IS NULL
            AND NEW.resume_boundary_sha256 IS NULL
            AND (
              SELECT COUNT(*) FROM pi_run_launches AS prior_launch
              WHERE prior_launch.run_id = run.id
            ) = 1
            AND EXISTS (
              SELECT 1 FROM pi_run_launches AS prior_launch
              WHERE prior_launch.run_id = run.id
                AND prior_launch.launch_mode = 'fresh'
                AND prior_launch.queue_sequence = 1
                AND prior_launch.state = 'failed'
                AND prior_launch.failure_code = 'RUNTIME_TIMEOUT'
                AND prior_launch.child_pid IS NOT NULL
            )
            AND NOT EXISTS (
              SELECT 1 FROM pi_run_session_origins AS session_origin
              WHERE session_origin.run_id = run.id
            )
            AND NOT EXISTS (
              SELECT 1 FROM pi_run_results AS result
              WHERE result.run_id = run.id
            )
            AND (
              SELECT COUNT(*) FROM job_transitions AS authorization
              WHERE authorization.job_id = run.job_id
                AND authorization.from_state = 'runningPi'
                AND authorization.to_state = 'runningPi'
                AND authorization.event_key GLOB (
                  'canary:*:pi-fresh-retry:' || run.id || ':' ||
                  (
                    SELECT prior_launch.launch_attempt_id
                    FROM pi_run_launches AS prior_launch
                    WHERE prior_launch.run_id = run.id
                    LIMIT 1
                  ) || ':*'
                )
            ) = 1
          )
          OR (
            NEW.launch_mode = 'fresh'
            AND NEW.expected_session_id IS NULL
            AND NEW.resume_boundary_sha256 IS NULL
            AND (
              SELECT COUNT(*) FROM pi_run_launches AS prior_launch
              WHERE prior_launch.run_id = run.id
            ) = 2
            AND EXISTS (
              SELECT 1 FROM pi_run_launches AS initial_launch
              WHERE initial_launch.run_id = run.id
                AND initial_launch.launch_mode = 'fresh'
                AND initial_launch.queue_sequence = 1
                AND initial_launch.state = 'failed'
                AND initial_launch.failure_code = 'RUNTIME_TIMEOUT'
                AND initial_launch.child_pid IS NOT NULL
            )
            AND EXISTS (
              SELECT 1 FROM pi_run_launches AS failed_retry
              WHERE failed_retry.run_id = run.id
                AND failed_retry.launch_mode = 'fresh'
                AND failed_retry.queue_sequence = 2
                AND failed_retry.state = 'failed'
                AND failed_retry.failure_code = 'HERDR_TRANSACTION_FAILED'
                AND failed_retry.child_pid IS NULL
            )
            AND NOT EXISTS (
              SELECT 1 FROM pi_run_session_origins AS session_origin
              WHERE session_origin.run_id = run.id
            )
            AND NOT EXISTS (
              SELECT 1 FROM pi_run_results AS result
              WHERE result.run_id = run.id
            )
            AND (
              SELECT COUNT(*) FROM job_transitions AS authorization
              WHERE authorization.job_id = run.job_id
                AND authorization.from_state = 'runningPi'
                AND authorization.to_state = 'runningPi'
                AND authorization.event_key GLOB (
                  'canary:*:pi-fresh-retry:' || run.id || ':' ||
                  (
                    SELECT initial_launch.launch_attempt_id
                    FROM pi_run_launches AS initial_launch
                    WHERE initial_launch.run_id = run.id
                      AND initial_launch.queue_sequence = 1
                  ) || ':*'
                )
            ) = 1
            AND (
              SELECT COUNT(*) FROM job_transitions AS authorization
              WHERE authorization.job_id = run.job_id
                AND authorization.from_state = 'runningPi'
                AND authorization.to_state = 'runningPi'
                AND authorization.event_key GLOB (
                  'canary:*:pi-fresh-retry:' || run.id || ':' ||
                  (
                    SELECT failed_retry.launch_attempt_id
                    FROM pi_run_launches AS failed_retry
                    WHERE failed_retry.run_id = run.id
                      AND failed_retry.queue_sequence = 2
                  ) || ':*'
                )
            ) = 1
          )
        )
    )
    BEGIN
      SELECT RAISE(ABORT, 'Pi launch lacks exact causal authority');
    END
    """

  private static let herdrPrimeRetryCandidatesViewV7 = """
    CREATE VIEW herdr_prime_retry_candidates AS
    SELECT
      run.id AS run_id,
      run.job_id AS job_id,
      job.repository_id AS repository_id,
      run.topology_generation AS generation,
      host.id AS role_host_id,
      host.workspace_id AS workspace_id,
      host.tab_id AS tab_id,
      host.pane_id AS pane_id,
      host.terminal_id AS terminal_id,
      binding.socket_device AS socket_device,
      binding.socket_inode AS socket_inode,
      binding.socket_owner AS socket_owner,
      binding.socket_permissions AS socket_permissions,
      third_launch.launch_attempt_id AS failed_launch_attempt_id
    FROM pi_runs AS run
    JOIN jobs AS job ON job.id = run.job_id
    JOIN herdr_role_hosts AS host
      ON host.job_id = run.job_id
      AND host.generation = run.topology_generation
      AND host.role = run.role
    JOIN herdr_repository_bindings AS binding
      ON binding.repository_id = job.repository_id
      AND binding.workspace_id = host.workspace_id
      AND binding.state = 'active'
    JOIN pi_run_launches AS initial_launch
      ON initial_launch.run_id = run.id AND initial_launch.queue_sequence = 1
    JOIN pi_run_launches AS second_launch
      ON second_launch.run_id = run.id AND second_launch.queue_sequence = 2
    JOIN pi_run_launches AS third_launch
      ON third_launch.run_id = run.id AND third_launch.queue_sequence = 3
    WHERE (SELECT paused FROM app_settings WHERE singleton = 1) = 1
      AND run.runtime_kind = 'herdr'
      AND run.role = 'architecture'
      AND run.settled = 0
      AND run.outcome = 'running'
      AND job.kind = 'prReview'
      AND job.state = 'runningPi'
      AND host.state IN ('waiting', 'running')
      AND host.last_queue_sequence IN (3, 4)
      AND host.host_pid IS NOT NULL
      AND host.host_start_seconds IS NOT NULL
      AND host.host_start_microseconds IS NOT NULL
      AND host.pane_id IS NOT NULL
      AND host.tab_id IS NOT NULL
      AND host.terminal_id IS NOT NULL
      AND initial_launch.launch_mode = 'fresh'
      AND initial_launch.state = 'failed'
      AND initial_launch.failure_code = 'RUNTIME_TIMEOUT'
      AND initial_launch.child_pid IS NOT NULL
      AND second_launch.launch_mode = 'fresh'
      AND second_launch.state = 'failed'
      AND second_launch.failure_code = 'HERDR_TRANSACTION_FAILED'
      AND second_launch.child_pid IS NULL
      AND third_launch.launch_mode = 'fresh'
      AND third_launch.state = 'failed'
      AND third_launch.failure_code = 'HERDR_TRANSACTION_FAILED'
      AND third_launch.child_pid IS NULL
      AND (SELECT COUNT(*) FROM pi_run_launches WHERE run_id = run.id) = 3
      AND (SELECT COUNT(*) FROM pi_run_results WHERE run_id = run.id) = 0
      AND (SELECT COUNT(*) FROM pi_run_session_origins WHERE run_id = run.id) = 0
      AND (SELECT COUNT(*) FROM artifacts WHERE job_id = run.job_id AND kind = 'review') = 0
      AND (SELECT COUNT(*) FROM job_steps WHERE job_id = run.job_id) = 0
      AND (SELECT COUNT(*) FROM approved_command_runs WHERE job_id = run.job_id) = 0
      AND (SELECT COUNT(*) FROM mutation_intents WHERE job_id = run.job_id) = 0
      AND (SELECT COUNT(*) FROM repository_leases WHERE active = 1) = 1
      AND (
        SELECT COUNT(*) FROM repository_leases
        WHERE active = 1 AND job_id = run.job_id AND repository_id = job.repository_id
      ) = 1
      AND (
        SELECT COUNT(*) FROM herdr_role_hosts
        WHERE job_id = run.job_id AND generation = run.topology_generation
          AND state = 'waiting' AND role IN ('architecture', 'security', 'test', 'synthesis')
      ) = 4
      AND (
        SELECT COUNT(*) FROM job_transitions AS authorization
        WHERE authorization.job_id = run.job_id
          AND authorization.from_state = 'runningPi'
          AND authorization.to_state = 'runningPi'
          AND authorization.event_key GLOB (
            'canary:*:pi-fresh-retry:' || run.id || ':' ||
            initial_launch.launch_attempt_id || ':*'
          )
      ) = 1
      AND (
        SELECT COUNT(*) FROM job_transitions AS authorization
        WHERE authorization.job_id = run.job_id
          AND authorization.from_state = 'runningPi'
          AND authorization.to_state = 'runningPi'
          AND authorization.event_key GLOB (
            'canary:*:pi-fresh-retry:' || run.id || ':' ||
            second_launch.launch_attempt_id || ':*'
          )
      ) = 1
      AND (
        SELECT COUNT(*) FROM job_transitions AS authorization
        WHERE authorization.job_id = run.job_id
          AND authorization.from_state = 'runningPi'
          AND authorization.to_state = 'runningPi'
          AND authorization.event_key GLOB (
            'canary:*:pi-fresh-retry:' || run.id || ':' ||
            third_launch.launch_attempt_id || ':*'
          )
      ) = 1
      AND (
        SELECT COUNT(*) FROM job_transitions AS authorization
        WHERE authorization.job_id = run.job_id
          AND authorization.from_state = 'runningPi'
          AND authorization.to_state = 'runningPi'
          AND authorization.event_key GLOB ('canary:*:pi-fresh-retry:' || run.id || ':*')
      ) = 3
    """

  private static let herdrAgentResetCandidatesViewV8 = """
    CREATE VIEW herdr_agent_reset_candidates AS
    SELECT
      run.id AS run_id,
      run.job_id AS job_id,
      job.repository_id AS repository_id,
      run.topology_generation AS generation,
      host.id AS role_host_id,
      host.workspace_id AS workspace_id,
      host.tab_id AS tab_id,
      host.pane_id AS pane_id,
      host.terminal_id AS terminal_id,
      binding.socket_device AS socket_device,
      binding.socket_inode AS socket_inode,
      binding.socket_owner AS socket_owner,
      binding.socket_permissions AS socket_permissions,
      third_launch.launch_attempt_id AS failed_launch_attempt_id,
      failed_prime.id AS failed_prime_intent_id,
      failed_prime.intent_sha256 AS failed_prime_intent_sha256,
      failed_prime.payload_sha256 AS failed_prime_payload_sha256
    FROM pi_runs AS run
    JOIN jobs AS job ON job.id = run.job_id
    JOIN herdr_role_hosts AS host
      ON host.job_id = run.job_id
      AND host.generation = run.topology_generation
      AND host.role = run.role
    JOIN herdr_repository_bindings AS binding
      ON binding.repository_id = job.repository_id
      AND binding.workspace_id = host.workspace_id
      AND binding.state = 'active'
    JOIN pi_run_launches AS initial_launch
      ON initial_launch.run_id = run.id AND initial_launch.queue_sequence = 1
    JOIN pi_run_launches AS second_launch
      ON second_launch.run_id = run.id AND second_launch.queue_sequence = 2
    JOIN pi_run_launches AS third_launch
      ON third_launch.run_id = run.id AND third_launch.queue_sequence = 3
    JOIN herdr_topology_intents AS failed_prime
      ON failed_prime.kind = 'primeAgentAuthority'
      AND failed_prime.repository_id = job.repository_id
      AND failed_prime.job_id = run.job_id
      AND failed_prime.generation = run.topology_generation
      AND failed_prime.socket_device = binding.socket_device
      AND failed_prime.socket_inode = binding.socket_inode
      AND failed_prime.socket_owner = binding.socket_owner
      AND failed_prime.socket_permissions = binding.socket_permissions
      AND failed_prime.state = 'unknown'
      AND failed_prime.attribution_json IS NULL
    WHERE (SELECT paused FROM app_settings WHERE singleton = 1) = 1
      AND run.runtime_kind = 'herdr'
      AND run.role = 'architecture'
      AND run.settled = 0
      AND run.outcome = 'running'
      AND job.kind = 'prReview'
      AND job.state = 'runningPi'
      AND host.state IN ('waiting', 'running')
      AND host.last_queue_sequence IN (3, 4)
      AND host.host_pid IS NOT NULL
      AND host.host_start_seconds IS NOT NULL
      AND host.host_start_microseconds IS NOT NULL
      AND host.pane_id IS NOT NULL
      AND host.tab_id IS NOT NULL
      AND host.terminal_id IS NOT NULL
      AND initial_launch.launch_mode = 'fresh'
      AND initial_launch.state = 'failed'
      AND initial_launch.failure_code = 'RUNTIME_TIMEOUT'
      AND initial_launch.child_pid IS NOT NULL
      AND second_launch.launch_mode = 'fresh'
      AND second_launch.state = 'failed'
      AND second_launch.failure_code = 'HERDR_TRANSACTION_FAILED'
      AND second_launch.child_pid IS NULL
      AND third_launch.launch_mode = 'fresh'
      AND third_launch.state = 'failed'
      AND third_launch.failure_code = 'HERDR_TRANSACTION_FAILED'
      AND third_launch.child_pid IS NULL
      AND (SELECT COUNT(*) FROM pi_run_launches WHERE run_id = run.id) = 3
      AND (SELECT COUNT(*) FROM pi_run_results WHERE run_id = run.id) = 0
      AND (SELECT COUNT(*) FROM pi_run_session_origins WHERE run_id = run.id) = 0
      AND (SELECT COUNT(*) FROM artifacts WHERE job_id = run.job_id AND kind = 'review') = 0
      AND (SELECT COUNT(*) FROM job_steps WHERE job_id = run.job_id) = 0
      AND (SELECT COUNT(*) FROM approved_command_runs WHERE job_id = run.job_id) = 0
      AND (SELECT COUNT(*) FROM mutation_intents WHERE job_id = run.job_id) = 0
      AND (SELECT COUNT(*) FROM repository_leases WHERE active = 1) = 1
      AND (
        SELECT COUNT(*) FROM repository_leases
        WHERE active = 1 AND job_id = run.job_id AND repository_id = job.repository_id
      ) = 1
      AND (
        SELECT COUNT(*) FROM herdr_role_hosts
        WHERE job_id = run.job_id AND generation = run.topology_generation
          AND state = 'waiting' AND role IN ('architecture', 'security', 'test', 'synthesis')
      ) = 4
      AND (
        SELECT COUNT(*) FROM herdr_topology_intents
        WHERE job_id = run.job_id AND kind = 'primeAgentAuthority'
      ) = 1
      AND (
        SELECT COUNT(*) FROM herdr_topology_intents
        WHERE job_id = run.job_id AND kind = 'resetAgentAuthority'
      ) IN (0, 1)
      AND (
        SELECT COUNT(*) FROM job_transitions AS authorization
        WHERE authorization.job_id = run.job_id
          AND authorization.from_state = 'runningPi'
          AND authorization.to_state = 'runningPi'
          AND authorization.event_key GLOB (
            'canary:*:pi-fresh-retry:' || run.id || ':' ||
            initial_launch.launch_attempt_id || ':*'
          )
      ) = 1
      AND (
        SELECT COUNT(*) FROM job_transitions AS authorization
        WHERE authorization.job_id = run.job_id
          AND authorization.from_state = 'runningPi'
          AND authorization.to_state = 'runningPi'
          AND authorization.event_key GLOB (
            'canary:*:pi-fresh-retry:' || run.id || ':' ||
            second_launch.launch_attempt_id || ':*'
          )
      ) = 1
      AND (
        SELECT COUNT(*) FROM job_transitions AS authorization
        WHERE authorization.job_id = run.job_id
          AND authorization.from_state = 'runningPi'
          AND authorization.to_state = 'runningPi'
          AND authorization.event_key GLOB (
            'canary:*:pi-fresh-retry:' || run.id || ':' ||
            third_launch.launch_attempt_id || ':*'
          )
      ) = 2
      AND (
        SELECT COUNT(*) FROM job_transitions AS authorization
        WHERE authorization.job_id = run.job_id
          AND authorization.from_state = 'runningPi'
          AND authorization.to_state = 'runningPi'
          AND authorization.event_key GLOB ('canary:*:pi-fresh-retry:' || run.id || ':*')
      ) = 4
    """

  private static let herdrQ4AuthorityCandidatesViewV8 = """
    CREATE VIEW herdr_q4_authority_candidates AS
    SELECT run_id, job_id, repository_id, generation, role_host_id, workspace_id,
      tab_id, pane_id, terminal_id, socket_device, socket_inode, socket_owner,
      socket_permissions, failed_launch_attempt_id,
      'primeAgentAuthority' AS intent_kind, 'pi-agent-prime' AS event_kind
    FROM herdr_prime_retry_candidates
    UNION ALL
    SELECT run_id, job_id, repository_id, generation, role_host_id, workspace_id,
      tab_id, pane_id, terminal_id, socket_device, socket_inode, socket_owner,
      socket_permissions, failed_launch_attempt_id,
      'resetAgentAuthority' AS intent_kind,
      'pi-agent-authority-reset' AS event_kind
    FROM herdr_agent_reset_candidates
    """

  private static let herdrRoleHostReplacementCandidatesViewV9 = """
    CREATE VIEW herdr_role_host_replacement_candidates AS
    SELECT
      candidate.run_id,
      candidate.job_id,
      candidate.repository_id,
      candidate.generation,
      candidate.role_host_id AS predecessor_role_host_id,
      candidate.workspace_id,
      candidate.tab_id,
      candidate.pane_id AS predecessor_pane_id,
      candidate.terminal_id AS predecessor_terminal_id,
      candidate.socket_device,
      candidate.socket_inode,
      candidate.socket_owner,
      candidate.socket_permissions,
      candidate.failed_launch_attempt_id,
      candidate.failed_prime_intent_id,
      candidate.failed_prime_intent_sha256,
      candidate.failed_prime_payload_sha256,
      failed_reset.id AS failed_reset_intent_id,
      failed_reset.intent_sha256 AS failed_reset_intent_sha256,
      failed_reset.payload_sha256 AS failed_reset_payload_sha256,
      anchor.id AS anchor_role_host_id,
      anchor.pane_id AS anchor_pane_id,
      anchor.terminal_id AS anchor_terminal_id
    FROM herdr_agent_reset_candidates AS candidate
    JOIN herdr_topology_intents AS failed_reset
      ON failed_reset.kind = 'resetAgentAuthority'
      AND failed_reset.repository_id = candidate.repository_id
      AND failed_reset.job_id = candidate.job_id
      AND failed_reset.generation = candidate.generation
      AND failed_reset.socket_device = candidate.socket_device
      AND failed_reset.socket_inode = candidate.socket_inode
      AND failed_reset.socket_owner = candidate.socket_owner
      AND failed_reset.socket_permissions = candidate.socket_permissions
      AND failed_reset.state = 'unknown'
      AND failed_reset.attribution_json IS NULL
    JOIN herdr_role_hosts AS anchor
      ON anchor.job_id = candidate.job_id
      AND anchor.generation = candidate.generation
      AND anchor.role = 'security'
      AND anchor.workspace_id = candidate.workspace_id
      AND anchor.tab_id = candidate.tab_id
      AND anchor.state = 'waiting'
      AND anchor.pane_id IS NOT NULL
      AND anchor.terminal_id IS NOT NULL
      AND anchor.host_pid IS NOT NULL
    """

  private static let herdrRoleHostReplacementAuthorizationsTableV9 = """
    CREATE TABLE herdr_role_host_replacement_authorizations (
      replacement_authorization_sha256 TEXT PRIMARY KEY CHECK (
        length(replacement_authorization_sha256) = 64
        AND replacement_authorization_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      payload_sha256 TEXT NOT NULL UNIQUE CHECK (
        length(payload_sha256) = 64 AND payload_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      replacement_evidence_sha256 TEXT NOT NULL CHECK (
        length(replacement_evidence_sha256) = 64
        AND replacement_evidence_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      incident_audit_sha256 TEXT NOT NULL CHECK (
        length(incident_audit_sha256) = 64
        AND incident_audit_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      canary_authorization_sha256 TEXT NOT NULL CHECK (
        length(canary_authorization_sha256) = 64
        AND canary_authorization_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      recovery_evidence_sha256 TEXT NOT NULL CHECK (
        length(recovery_evidence_sha256) = 64
        AND recovery_evidence_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      retry_evidence_sha256 TEXT NOT NULL CHECK (
        length(retry_evidence_sha256) = 64
        AND retry_evidence_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      repository_id TEXT NOT NULL REFERENCES repositories(id) ON DELETE RESTRICT,
      job_id TEXT NOT NULL UNIQUE REFERENCES jobs(id) ON DELETE RESTRICT,
      generation INTEGER NOT NULL CHECK (generation > 0),
      run_id TEXT NOT NULL UNIQUE REFERENCES pi_runs(id) ON DELETE RESTRICT,
      failed_launch_attempt_id TEXT NOT NULL UNIQUE
        REFERENCES pi_run_launches(launch_attempt_id) ON DELETE RESTRICT,
      predecessor_role_host_id TEXT NOT NULL UNIQUE
        REFERENCES herdr_role_hosts(id) ON DELETE RESTRICT,
      planned_replacement_role_host_id TEXT NOT NULL UNIQUE CHECK (
        planned_replacement_role_host_id GLOB 'rolehost-????????-????-????-????-????????????'
        AND length(planned_replacement_role_host_id) = 45
        AND planned_replacement_role_host_id NOT GLOB '*[^a-z0-9-]*'
        AND substr(planned_replacement_role_host_id, 10) NOT GLOB '*[^0-9a-f-]*'
        AND planned_replacement_role_host_id != predecessor_role_host_id
      ),
      planned_launch_attempt_id TEXT NOT NULL UNIQUE CHECK (
        planned_launch_attempt_id GLOB 'launch-????????-????-????-????-????????????'
        AND length(planned_launch_attempt_id) = 43
        AND planned_launch_attempt_id NOT GLOB '*[^a-z0-9-]*'
        AND substr(planned_launch_attempt_id, 8) NOT GLOB '*[^0-9a-f-]*'
      ),
      stale_pane_revision INTEGER NOT NULL CHECK (stale_pane_revision > 0),
      stale_pane_had_tokens INTEGER NOT NULL CHECK (stale_pane_had_tokens IN (0, 1)),
      stale_pane_tokens_sha256 TEXT NOT NULL CHECK (
        length(stale_pane_tokens_sha256) = 64
        AND stale_pane_tokens_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      q4_descriptor_sha256 TEXT NOT NULL CHECK (
        length(q4_descriptor_sha256) = 64
        AND q4_descriptor_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      q4_configuration_sha256 TEXT NOT NULL CHECK (
        length(q4_configuration_sha256) = 64
        AND q4_configuration_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      q4_prompt_sha256 TEXT NOT NULL CHECK (
        length(q4_prompt_sha256) = 64
        AND q4_prompt_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      q4_workflow_configuration_sha256 TEXT NOT NULL CHECK (
        length(q4_workflow_configuration_sha256) = 64
        AND q4_workflow_configuration_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      q4_prior_launch_descriptor_sha256 TEXT NOT NULL CHECK (
        length(q4_prior_launch_descriptor_sha256) = 64
        AND q4_prior_launch_descriptor_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      q4_prior_launch_configuration_sha256 TEXT NOT NULL CHECK (
        length(q4_prior_launch_configuration_sha256) = 64
        AND q4_prior_launch_configuration_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      q4_resource_tree_sha256 TEXT NOT NULL CHECK (
        length(q4_resource_tree_sha256) = 64
        AND q4_resource_tree_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      replacement_bootstrap_descriptor_sha256 TEXT NOT NULL CHECK (
        length(replacement_bootstrap_descriptor_sha256) = 64
        AND replacement_bootstrap_descriptor_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      host_executable_sha256 TEXT NOT NULL CHECK (
        length(host_executable_sha256) = 64
        AND host_executable_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      credential_evidence_sha256 TEXT NOT NULL CHECK (
        length(credential_evidence_sha256) = 64
        AND credential_evidence_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      created_at REAL NOT NULL,
      UNIQUE(repository_id, job_id, generation, run_id)
    ) STRICT
    """

  private static let herdrRoleHostReplacementAuthorizationInsertAuthorityV9 = """
    CREATE TRIGGER herdr_role_host_replacement_authorization_insert_authority
    BEFORE INSERT ON herdr_role_host_replacement_authorizations
    WHEN NEW.incident_audit_sha256
        != 'f855da9097441503472e85c912f881f157475381fdf6666057927f0651c5e1d7'
      OR NEW.stale_pane_revision != 3
      OR NEW.stale_pane_had_tokens != 1
      OR NEW.stale_pane_tokens_sha256
        != '9a0952938abe3db94e9d949cb36c66a891ba7777a009edb1f443b3f465c6cc01'
      OR EXISTS (
        SELECT 1 FROM herdr_role_hosts AS existing_host
        WHERE existing_host.id = NEW.planned_replacement_role_host_id
      )
      OR EXISTS (
        SELECT 1 FROM pi_run_launches AS existing_launch
        WHERE existing_launch.launch_attempt_id = NEW.planned_launch_attempt_id
      )
      OR EXISTS (
        SELECT 1 FROM herdr_topology_intents AS intent
        WHERE intent.job_id = NEW.job_id AND intent.kind = 'replaceRoleHost'
      )
      OR EXISTS (
        SELECT 1 FROM herdr_replacement_role_hosts AS replacement
        WHERE replacement.job_id = NEW.job_id
      )
      OR NOT EXISTS (
        SELECT 1
        FROM herdr_role_host_replacement_candidates AS candidate
        WHERE candidate.repository_id = NEW.repository_id
          AND candidate.job_id = NEW.job_id
          AND candidate.generation = NEW.generation
          AND candidate.run_id = NEW.run_id
          AND candidate.failed_launch_attempt_id = NEW.failed_launch_attempt_id
          AND candidate.predecessor_role_host_id = NEW.predecessor_role_host_id
          AND (
            SELECT COUNT(*) FROM job_transitions AS admit
            WHERE admit.job_id = NEW.job_id
              AND admit.event_key = (
                'canary:' || NEW.canary_authorization_sha256 || ':m8:admit:' || NEW.job_id
              )
              AND admit.id = (
                SELECT MAX(latest.id) FROM job_transitions AS latest
                WHERE latest.event_key GLOB 'canary:*:m*:admit:*'
              )
          ) = 1
          AND NOT EXISTS (
            SELECT 1 FROM job_transitions AS close
            WHERE close.job_id = NEW.job_id
              AND close.event_key = (
                'canary:' || NEW.canary_authorization_sha256 || ':m8:close:' || NEW.job_id
              )
          )
          AND (
            SELECT COUNT(*) FROM job_transitions AS recovery
            WHERE recovery.job_id = NEW.job_id
              AND recovery.event_key = (
                'canary:' || NEW.canary_authorization_sha256 ||
                ':m8:topology-recovery:' || NEW.recovery_evidence_sha256
              )
          ) = 1
          AND (
            SELECT COUNT(*) FROM job_transitions AS retry
            WHERE retry.job_id = NEW.job_id
              AND retry.from_state = 'runningPi'
              AND retry.to_state = 'runningPi'
              AND retry.event_key = (
                'canary:' || NEW.canary_authorization_sha256 || ':m8:pi-fresh-retry:' ||
                NEW.run_id || ':' || NEW.failed_launch_attempt_id || ':' ||
                NEW.retry_evidence_sha256
              )
          ) = 1
      )
    BEGIN
      SELECT RAISE(ABORT, 'replacement authorization lacks exact paused canary authority');
    END
    """

  private static let herdrRoleHostReplacementAuthorizationUpdateDeniedV9 = """
    CREATE TRIGGER herdr_role_host_replacement_authorization_update_denied
    BEFORE UPDATE ON herdr_role_host_replacement_authorizations
    BEGIN
      SELECT RAISE(ABORT, 'replacement authorization is immutable');
    END
    """

  private static let herdrRoleHostReplacementAuthorizationDeleteDeniedV9 = """
    CREATE TRIGGER herdr_role_host_replacement_authorization_delete_denied
    BEFORE DELETE ON herdr_role_host_replacement_authorizations
    BEGIN
      SELECT RAISE(ABORT, 'replacement authorization is append-only');
    END
    """

  private static let herdrReplacementIntentInsertAuthorityV9 = """
    CREATE TRIGGER herdr_replacement_intent_insert_authority
    BEFORE INSERT ON herdr_topology_intents
    WHEN NEW.kind = 'replaceRoleHost' AND (
      NEW.state != 'prepared'
      OR NEW.attribution_json IS NOT NULL
      OR EXISTS (
        SELECT 1 FROM herdr_topology_intents AS existing
        WHERE existing.job_id = NEW.job_id AND existing.kind = 'replaceRoleHost'
      )
      OR NOT EXISTS (
        SELECT 1
        FROM herdr_role_host_replacement_candidates AS candidate
        JOIN herdr_role_host_replacement_authorizations AS authorization
          ON authorization.repository_id = candidate.repository_id
          AND authorization.job_id = candidate.job_id
          AND authorization.generation = candidate.generation
          AND authorization.run_id = candidate.run_id
          AND authorization.failed_launch_attempt_id = candidate.failed_launch_attempt_id
          AND authorization.predecessor_role_host_id = candidate.predecessor_role_host_id
          AND authorization.payload_sha256 = NEW.payload_sha256
        WHERE candidate.job_id = NEW.job_id
          AND candidate.repository_id = NEW.repository_id
          AND candidate.generation = NEW.generation
          AND candidate.socket_device = NEW.socket_device
          AND candidate.socket_inode = NEW.socket_inode
          AND candidate.socket_owner = NEW.socket_owner
          AND candidate.socket_permissions = NEW.socket_permissions
      )
    )
    BEGIN
      SELECT RAISE(ABORT, 'Herdr role-host replacement lacks exact causal authority');
    END
    """

  private static let herdrReplacementIntentSendAuthorityV9 = """
    CREATE TRIGGER herdr_replacement_intent_send_authority
    BEFORE UPDATE OF state ON herdr_topology_intents
    WHEN OLD.kind = 'replaceRoleHost' AND NEW.state = 'sendStarted' AND (
      (SELECT COUNT(*) FROM herdr_topology_intents AS existing
        WHERE existing.job_id = OLD.job_id AND existing.kind = 'replaceRoleHost') != 1
      OR NOT EXISTS (
        SELECT 1
        FROM herdr_role_host_replacement_candidates AS candidate
        JOIN herdr_role_host_replacement_authorizations AS authorization
          ON authorization.repository_id = candidate.repository_id
          AND authorization.job_id = candidate.job_id
          AND authorization.generation = candidate.generation
          AND authorization.run_id = candidate.run_id
          AND authorization.failed_launch_attempt_id = candidate.failed_launch_attempt_id
          AND authorization.predecessor_role_host_id = candidate.predecessor_role_host_id
          AND authorization.payload_sha256 = OLD.payload_sha256
        WHERE candidate.job_id = OLD.job_id
          AND candidate.repository_id = OLD.repository_id
          AND candidate.generation = OLD.generation
          AND candidate.socket_device = OLD.socket_device
          AND candidate.socket_inode = OLD.socket_inode
          AND candidate.socket_owner = OLD.socket_owner
          AND candidate.socket_permissions = OLD.socket_permissions
      )
    )
    BEGIN
      SELECT RAISE(ABORT, 'Herdr role-host replacement send lacks current authority');
    END
    """

  private static let herdrReplacementIntentAttributionAuthorityV9 = """
    CREATE TRIGGER herdr_replacement_intent_attribution_authority
    BEFORE UPDATE OF state, attribution_json ON herdr_topology_intents
    WHEN OLD.kind = 'replaceRoleHost' AND NEW.state = 'attributed' AND NOT EXISTS (
      SELECT 1
      FROM herdr_role_host_replacement_authorizations AS authorization
      JOIN herdr_replacement_role_hosts AS replacement
        ON replacement.id = authorization.planned_replacement_role_host_id
        AND replacement.predecessor_role_host_id = authorization.predecessor_role_host_id
        AND replacement.replacement_intent_id = OLD.id
        AND replacement.job_id = authorization.job_id
        AND replacement.generation = authorization.generation
        AND replacement.bootstrap_descriptor_sha256
          = authorization.replacement_bootstrap_descriptor_sha256
        AND replacement.host_executable_sha256 = authorization.host_executable_sha256
        AND replacement.q4_descriptor_sha256 = authorization.q4_descriptor_sha256
        AND replacement.q4_configuration_sha256 = authorization.q4_configuration_sha256
        AND replacement.q4_prompt_sha256 = authorization.q4_prompt_sha256
        AND replacement.q4_workflow_configuration_sha256
          = authorization.q4_workflow_configuration_sha256
        AND replacement.q4_prior_launch_descriptor_sha256
          = authorization.q4_prior_launch_descriptor_sha256
        AND replacement.q4_prior_launch_configuration_sha256
          = authorization.q4_prior_launch_configuration_sha256
        AND replacement.q4_resource_tree_sha256 = authorization.q4_resource_tree_sha256
      WHERE authorization.payload_sha256 = OLD.payload_sha256
        AND authorization.repository_id = OLD.repository_id
        AND authorization.job_id = OLD.job_id
        AND authorization.generation = OLD.generation
        AND json_extract(NEW.attribution_json, '$.predecessorRoleHostID')
          = authorization.predecessor_role_host_id
        AND json_extract(NEW.attribution_json, '$.replacementRoleHostID')
          = authorization.planned_replacement_role_host_id
        AND json_extract(NEW.attribution_json, '$.replacementEvidenceSHA256')
          = authorization.replacement_evidence_sha256
        AND json_extract(NEW.attribution_json, '$.replacementAuthorizationSHA256')
          = authorization.replacement_authorization_sha256
        AND json_extract(NEW.attribution_json, '$.incidentAuditSHA256')
          = authorization.incident_audit_sha256
        AND json_extract(NEW.attribution_json, '$.credentialEvidenceSHA256')
          = authorization.credential_evidence_sha256
        AND json_extract(NEW.attribution_json, '$.q4Binding.descriptorSHA256')
          = authorization.q4_descriptor_sha256
        AND json_extract(NEW.attribution_json, '$.q4Binding.configurationSHA256')
          = authorization.q4_configuration_sha256
        AND json_extract(NEW.attribution_json, '$.q4Binding.promptSHA256')
          = authorization.q4_prompt_sha256
        AND json_extract(
          NEW.attribution_json,
          '$.q4Binding.workflowConfigurationSHA256'
        ) = authorization.q4_workflow_configuration_sha256
        AND json_extract(
          NEW.attribution_json,
          '$.q4Binding.priorLaunchDescriptorSHA256'
        ) = authorization.q4_prior_launch_descriptor_sha256
        AND json_extract(
          NEW.attribution_json,
          '$.q4Binding.priorLaunchConfigurationSHA256'
        ) = authorization.q4_prior_launch_configuration_sha256
        AND json_extract(NEW.attribution_json, '$.q4Binding.resourceTreeSHA256')
          = authorization.q4_resource_tree_sha256
        AND json_extract(NEW.attribution_json, '$.hostExecutableSHA256')
          = authorization.host_executable_sha256
        AND json_extract(NEW.attribution_json, '$.workspaceID') = replacement.workspace_id
        AND json_extract(NEW.attribution_json, '$.tabID') = replacement.tab_id
        AND json_extract(NEW.attribution_json, '$.paneID') = replacement.pane_id
        AND json_extract(NEW.attribution_json, '$.terminalID') = replacement.terminal_id
        AND json_extract(NEW.attribution_json, '$.processID') = replacement.host_pid
        AND json_extract(NEW.attribution_json, '$.startSeconds')
          = replacement.host_start_seconds
        AND json_extract(NEW.attribution_json, '$.startMicroseconds')
          = replacement.host_start_microseconds
    )
    BEGIN
      SELECT RAISE(ABORT, 'replacement attribution lacks exact authorization');
    END
    """

  private static let herdrReplacementRoleHostsTableV9 = """
    CREATE TABLE herdr_replacement_role_hosts (
      id TEXT PRIMARY KEY CHECK (
        id GLOB 'rolehost-*' AND length(id) BETWEEN 16 AND 64
        AND id NOT GLOB '*[^a-z0-9-]*'
      ),
      predecessor_role_host_id TEXT NOT NULL UNIQUE
        REFERENCES herdr_role_hosts(id) ON DELETE RESTRICT,
      replacement_intent_id TEXT NOT NULL UNIQUE CHECK (
        replacement_intent_id GLOB 'replace-*'
        AND length(replacement_intent_id) BETWEEN 16 AND 64
        AND replacement_intent_id NOT GLOB '*[^a-z0-9-]*'
      ) REFERENCES herdr_topology_intents(id) ON DELETE RESTRICT,
      job_id TEXT NOT NULL REFERENCES herdr_job_bindings(job_id) ON DELETE RESTRICT,
      generation INTEGER NOT NULL CHECK (generation > 0),
      role TEXT NOT NULL CHECK (role = 'architecture'),
      workspace_id TEXT NOT NULL,
      tab_id TEXT NOT NULL,
      pane_id TEXT NOT NULL,
      terminal_id TEXT NOT NULL,
      bootstrap_descriptor_sha256 TEXT NOT NULL CHECK (
        length(bootstrap_descriptor_sha256) = 64
        AND bootstrap_descriptor_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      host_executable_sha256 TEXT NOT NULL CHECK (
        length(host_executable_sha256) = 64
        AND host_executable_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      q4_descriptor_sha256 TEXT NOT NULL CHECK (
        length(q4_descriptor_sha256) = 64
        AND q4_descriptor_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      q4_configuration_sha256 TEXT NOT NULL CHECK (
        length(q4_configuration_sha256) = 64
        AND q4_configuration_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      q4_prompt_sha256 TEXT NOT NULL CHECK (
        length(q4_prompt_sha256) = 64
        AND q4_prompt_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      q4_workflow_configuration_sha256 TEXT NOT NULL CHECK (
        length(q4_workflow_configuration_sha256) = 64
        AND q4_workflow_configuration_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      q4_prior_launch_descriptor_sha256 TEXT NOT NULL CHECK (
        length(q4_prior_launch_descriptor_sha256) = 64
        AND q4_prior_launch_descriptor_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      q4_prior_launch_configuration_sha256 TEXT NOT NULL CHECK (
        length(q4_prior_launch_configuration_sha256) = 64
        AND q4_prior_launch_configuration_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      q4_resource_tree_sha256 TEXT NOT NULL CHECK (
        length(q4_resource_tree_sha256) = 64
        AND q4_resource_tree_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      host_pid INTEGER NOT NULL CHECK (host_pid > 0),
      host_start_seconds INTEGER NOT NULL CHECK (host_start_seconds >= 0),
      host_start_microseconds INTEGER NOT NULL CHECK (
        host_start_microseconds BETWEEN 0 AND 999999
      ),
      last_queue_sequence INTEGER NOT NULL CHECK (last_queue_sequence = 4),
      lifecycle_sequence INTEGER NOT NULL CHECK (lifecycle_sequence >= 1),
      state TEXT NOT NULL CHECK (state IN (
        'waiting', 'running', 'stopping', 'stopped', 'lost'
      )),
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL,
      UNIQUE(job_id, generation, role)
    ) STRICT
    """

  private static let herdrReplacementRoleHostsActiveTerminalIndexV9 = """
    CREATE UNIQUE INDEX herdr_replacement_role_hosts_active_terminal_idx
    ON herdr_replacement_role_hosts(terminal_id)
    WHERE state IN ('waiting', 'running', 'stopping')
    """

  private static let herdrReplacementRoleHostsActivePaneIndexV9 = """
    CREATE UNIQUE INDEX herdr_replacement_role_hosts_active_pane_idx
    ON herdr_replacement_role_hosts(pane_id)
    WHERE state IN ('waiting', 'running', 'stopping')
    """

  private static let herdrReplacementRoleHostsActiveProcessIndexV9 = """
    CREATE UNIQUE INDEX herdr_replacement_role_hosts_active_process_idx
    ON herdr_replacement_role_hosts(
      host_pid, host_start_seconds, host_start_microseconds
    )
    WHERE state IN ('waiting', 'running', 'stopping')
    """

  private static let herdrOrdinaryRoleHostReplacementInsertCollisionDeniedV9 = """
    CREATE TRIGGER herdr_ordinary_role_host_replacement_insert_collision_denied
    BEFORE INSERT ON herdr_role_hosts
    WHEN EXISTS (
      SELECT 1 FROM herdr_replacement_role_hosts AS replacement
      WHERE replacement.id = NEW.id
        OR replacement.pane_id = NEW.pane_id
        OR replacement.terminal_id = NEW.terminal_id
        OR (
          replacement.host_pid = NEW.host_pid
          AND replacement.host_start_seconds = NEW.host_start_seconds
          AND replacement.host_start_microseconds = NEW.host_start_microseconds
        )
    )
    BEGIN
      SELECT RAISE(ABORT, 'ordinary and replacement role-host identities cannot alias');
    END
    """

  private static let herdrOrdinaryRoleHostReplacementPhysicalCollisionDeniedV9 = """
    CREATE TRIGGER herdr_ordinary_role_host_replacement_physical_collision_denied
    BEFORE UPDATE OF id, pane_id, terminal_id, host_pid, host_start_seconds,
      host_start_microseconds ON herdr_role_hosts
    WHEN EXISTS (
      SELECT 1 FROM herdr_replacement_role_hosts AS replacement
      WHERE replacement.id = NEW.id
        OR replacement.pane_id = NEW.pane_id
        OR replacement.terminal_id = NEW.terminal_id
        OR (
          replacement.host_pid = NEW.host_pid
          AND replacement.host_start_seconds = NEW.host_start_seconds
          AND replacement.host_start_microseconds = NEW.host_start_microseconds
        )
    )
    BEGIN
      SELECT RAISE(ABORT, 'ordinary and replacement role-host identities cannot alias');
    END
    """

  private static let herdrReplacementRoleHostInsertAuthorityV9 = """
    CREATE TRIGGER herdr_replacement_role_host_insert_authority
    BEFORE INSERT ON herdr_replacement_role_hosts
    WHEN NEW.role != 'architecture'
      OR NEW.state != 'waiting'
      OR NEW.last_queue_sequence != 4
      OR NEW.lifecycle_sequence != 1
      OR NEW.updated_at != NEW.created_at
      OR EXISTS (
        SELECT 1 FROM herdr_role_hosts AS ordinary
        WHERE ordinary.id = NEW.id
      )
      OR EXISTS (
        SELECT 1 FROM herdr_role_hosts AS ordinary
        WHERE ordinary.pane_id = NEW.pane_id
          OR ordinary.terminal_id = NEW.terminal_id
          OR (
            ordinary.host_pid = NEW.host_pid
            AND ordinary.host_start_seconds = NEW.host_start_seconds
            AND ordinary.host_start_microseconds = NEW.host_start_microseconds
          )
      )
      OR NOT EXISTS (
        SELECT 1
        FROM herdr_role_host_replacement_candidates AS candidate
        JOIN herdr_topology_intents AS intent
          ON intent.id = NEW.replacement_intent_id
          AND intent.kind = 'replaceRoleHost'
          AND intent.repository_id = candidate.repository_id
          AND intent.job_id = candidate.job_id
          AND intent.generation = candidate.generation
          AND intent.socket_device = candidate.socket_device
          AND intent.socket_inode = candidate.socket_inode
          AND intent.socket_owner = candidate.socket_owner
          AND intent.socket_permissions = candidate.socket_permissions
          AND intent.state = 'sendStarted'
          AND intent.attribution_json IS NULL
        JOIN herdr_role_host_replacement_authorizations AS authorization
          ON authorization.payload_sha256 = intent.payload_sha256
          AND authorization.repository_id = candidate.repository_id
          AND authorization.job_id = candidate.job_id
          AND authorization.generation = candidate.generation
          AND authorization.run_id = candidate.run_id
          AND authorization.failed_launch_attempt_id = candidate.failed_launch_attempt_id
          AND authorization.predecessor_role_host_id = candidate.predecessor_role_host_id
        WHERE candidate.job_id = NEW.job_id
          AND candidate.generation = NEW.generation
          AND candidate.predecessor_role_host_id = NEW.predecessor_role_host_id
          AND candidate.workspace_id = NEW.workspace_id
          AND candidate.tab_id = NEW.tab_id
          AND authorization.planned_replacement_role_host_id = NEW.id
          AND authorization.replacement_bootstrap_descriptor_sha256
            = NEW.bootstrap_descriptor_sha256
          AND authorization.host_executable_sha256 = NEW.host_executable_sha256
          AND authorization.q4_descriptor_sha256 = NEW.q4_descriptor_sha256
          AND authorization.q4_configuration_sha256 = NEW.q4_configuration_sha256
          AND authorization.q4_prompt_sha256 = NEW.q4_prompt_sha256
          AND authorization.q4_workflow_configuration_sha256
            = NEW.q4_workflow_configuration_sha256
          AND authorization.q4_prior_launch_descriptor_sha256
            = NEW.q4_prior_launch_descriptor_sha256
          AND authorization.q4_prior_launch_configuration_sha256
            = NEW.q4_prior_launch_configuration_sha256
          AND authorization.q4_resource_tree_sha256 = NEW.q4_resource_tree_sha256
      )
    BEGIN
      SELECT RAISE(ABORT, 'replacement role host lacks exact causal authority');
    END
    """

  private static let herdrReplacementRoleHostIdentityImmutableV9 = """
    CREATE TRIGGER herdr_replacement_role_host_identity_immutable
    BEFORE UPDATE ON herdr_replacement_role_hosts
    WHEN NEW.id IS NOT OLD.id
      OR NEW.predecessor_role_host_id IS NOT OLD.predecessor_role_host_id
      OR NEW.replacement_intent_id IS NOT OLD.replacement_intent_id
      OR NEW.job_id IS NOT OLD.job_id
      OR NEW.generation IS NOT OLD.generation
      OR NEW.role IS NOT OLD.role
      OR NEW.workspace_id IS NOT OLD.workspace_id
      OR NEW.tab_id IS NOT OLD.tab_id
      OR NEW.pane_id IS NOT OLD.pane_id
      OR NEW.terminal_id IS NOT OLD.terminal_id
      OR NEW.bootstrap_descriptor_sha256 IS NOT OLD.bootstrap_descriptor_sha256
      OR NEW.host_executable_sha256 IS NOT OLD.host_executable_sha256
      OR NEW.q4_descriptor_sha256 IS NOT OLD.q4_descriptor_sha256
      OR NEW.q4_configuration_sha256 IS NOT OLD.q4_configuration_sha256
      OR NEW.q4_prompt_sha256 IS NOT OLD.q4_prompt_sha256
      OR NEW.q4_workflow_configuration_sha256 IS NOT OLD.q4_workflow_configuration_sha256
      OR NEW.q4_prior_launch_descriptor_sha256 IS NOT OLD.q4_prior_launch_descriptor_sha256
      OR NEW.q4_prior_launch_configuration_sha256
        IS NOT OLD.q4_prior_launch_configuration_sha256
      OR NEW.q4_resource_tree_sha256 IS NOT OLD.q4_resource_tree_sha256
      OR NEW.host_pid IS NOT OLD.host_pid
      OR NEW.host_start_seconds IS NOT OLD.host_start_seconds
      OR NEW.host_start_microseconds IS NOT OLD.host_start_microseconds
      OR NEW.last_queue_sequence IS NOT OLD.last_queue_sequence
      OR NEW.created_at IS NOT OLD.created_at
    BEGIN
      SELECT RAISE(ABORT, 'replacement role-host identity is immutable');
    END
    """

  private static let herdrReplacementRoleHostStateTransitionV9 = """
    CREATE TRIGGER herdr_replacement_role_host_state_transition
    BEFORE UPDATE ON herdr_replacement_role_hosts
    WHEN (
      NEW.state IS OLD.state
      AND (
        NEW.lifecycle_sequence IS NOT OLD.lifecycle_sequence
        OR NEW.updated_at IS NOT OLD.updated_at
      )
    ) OR (
      NEW.state IS NOT OLD.state
      AND NOT (
        (
          OLD.state = 'waiting' AND NEW.state IN ('running', 'stopping', 'lost')
          OR OLD.state = 'running' AND NEW.state IN ('waiting', 'stopping', 'lost')
          OR OLD.state = 'stopping' AND NEW.state IN ('stopped', 'lost')
        )
        AND NEW.lifecycle_sequence = OLD.lifecycle_sequence + 1
        AND NEW.updated_at >= OLD.updated_at
      )
    )
    BEGIN
      SELECT RAISE(ABORT, 'invalid replacement role-host transition');
    END
    """

  private static let herdrReplacementRoleHostDeleteDeniedV9 = """
    CREATE TRIGGER herdr_replacement_role_host_delete_denied
    BEFORE DELETE ON herdr_replacement_role_hosts
    BEGIN
      SELECT RAISE(ABORT, 'replacement role host is append-only');
    END
    """

  private static let herdrReplacedPredecessorImmutableV9 = """
    CREATE TRIGGER herdr_replaced_predecessor_immutable
    BEFORE UPDATE ON herdr_role_hosts
    WHEN EXISTS (
      SELECT 1 FROM herdr_replacement_role_hosts AS replacement
      WHERE replacement.predecessor_role_host_id = OLD.id
    ) AND NOT (
      OLD.state = 'waiting' AND NEW.state = 'stopped'
      AND NEW.id IS OLD.id
      AND NEW.job_id IS OLD.job_id
      AND NEW.generation IS OLD.generation
      AND NEW.role IS OLD.role
      AND NEW.workspace_id IS OLD.workspace_id
      AND NEW.tab_id IS OLD.tab_id
      AND NEW.pane_id IS OLD.pane_id
      AND NEW.terminal_id IS OLD.terminal_id
      AND NEW.bootstrap_descriptor_sha256 IS OLD.bootstrap_descriptor_sha256
      AND NEW.host_executable_sha256 IS OLD.host_executable_sha256
      AND NEW.host_pid IS OLD.host_pid
      AND NEW.host_start_seconds IS OLD.host_start_seconds
      AND NEW.host_start_microseconds IS OLD.host_start_microseconds
      AND NEW.last_queue_sequence IS OLD.last_queue_sequence
      AND NEW.lifecycle_sequence = OLD.lifecycle_sequence + 1
      AND NEW.created_at IS OLD.created_at
      AND NEW.updated_at >= OLD.updated_at
    )
    BEGIN
      SELECT RAISE(ABORT, 'replaced predecessor role host is immutable');
    END
    """

  private static let herdrRepositoryBindingHistoryTableV9 = """
    CREATE TABLE herdr_repository_binding_history (
      id INTEGER PRIMARY KEY,
      repository_id TEXT NOT NULL REFERENCES repositories(id) ON DELETE RESTRICT,
      workspace_id TEXT NOT NULL,
      identity_root TEXT NOT NULL,
      herdr_version TEXT NOT NULL,
      herdr_protocol INTEGER NOT NULL,
      socket_device INTEGER NOT NULL,
      socket_inode INTEGER NOT NULL,
      socket_owner INTEGER NOT NULL,
      socket_permissions INTEGER NOT NULL,
      reason TEXT NOT NULL CHECK (reason IN ('SOCKET_CHANGED', 'RUNTIME_CHANGED')),
      invalidated_at REAL NOT NULL
    ) STRICT
    """

  private static let herdrGenerationRolloverAuthorizationsTableV9 = """
    CREATE TABLE herdr_generation_rollover_authorizations (
      rollover_authorization_sha256 TEXT PRIMARY KEY CHECK (
        length(rollover_authorization_sha256) = 64
        AND rollover_authorization_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      rollover_evidence_sha256 TEXT NOT NULL UNIQUE CHECK (
        length(rollover_evidence_sha256) = 64
        AND rollover_evidence_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      canary_authorization_sha256 TEXT NOT NULL CHECK (
        length(canary_authorization_sha256) = 64
        AND canary_authorization_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      lineage_sha256 TEXT NOT NULL UNIQUE CHECK (
        length(lineage_sha256) = 64 AND lineage_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      isolation_sha256 TEXT NOT NULL CHECK (
        length(isolation_sha256) = 64 AND isolation_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      repository_id TEXT NOT NULL REFERENCES repositories(id) ON DELETE RESTRICT,
      job_id TEXT NOT NULL UNIQUE REFERENCES jobs(id) ON DELETE RESTRICT,
      predecessor_generation INTEGER NOT NULL CHECK (predecessor_generation > 0),
      successor_generation INTEGER NOT NULL CHECK (
        successor_generation = predecessor_generation + 1
        AND successor_generation <= 1000000
      ),
      predecessor_run_id TEXT NOT NULL UNIQUE REFERENCES pi_runs(id) ON DELETE RESTRICT,
      q1_launch_attempt_id TEXT NOT NULL UNIQUE
        REFERENCES pi_run_launches(launch_attempt_id) ON DELETE RESTRICT,
      q1_descriptor_sha256 TEXT NOT NULL CHECK (
        length(q1_descriptor_sha256) = 64 AND q1_descriptor_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      q1_failure_code TEXT NOT NULL CHECK (q1_failure_code = 'RUNTIME_TIMEOUT'),
      q1_child_pid INTEGER NOT NULL CHECK (q1_child_pid > 0),
      q1_child_process_group_id INTEGER NOT NULL CHECK (
        q1_child_process_group_id = q1_child_pid
      ),
      q1_child_start_seconds INTEGER NOT NULL CHECK (q1_child_start_seconds >= 0),
      q1_child_start_microseconds INTEGER NOT NULL CHECK (
        q1_child_start_microseconds BETWEEN 0 AND 999999
      ),
      q2_launch_attempt_id TEXT NOT NULL UNIQUE
        REFERENCES pi_run_launches(launch_attempt_id) ON DELETE RESTRICT,
      q2_descriptor_sha256 TEXT NOT NULL CHECK (
        length(q2_descriptor_sha256) = 64 AND q2_descriptor_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      q2_failure_code TEXT NOT NULL CHECK (q2_failure_code = 'HERDR_TRANSACTION_FAILED'),
      q3_launch_attempt_id TEXT NOT NULL UNIQUE
        REFERENCES pi_run_launches(launch_attempt_id) ON DELETE RESTRICT,
      q3_descriptor_sha256 TEXT NOT NULL CHECK (
        length(q3_descriptor_sha256) = 64 AND q3_descriptor_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      q3_failure_code TEXT NOT NULL CHECK (q3_failure_code = 'HERDR_TRANSACTION_FAILED'),
      predecessor_architecture_host_id TEXT NOT NULL UNIQUE
        REFERENCES herdr_role_hosts(id) ON DELETE RESTRICT,
      predecessor_architecture_bootstrap_sha256 TEXT NOT NULL CHECK (
        length(predecessor_architecture_bootstrap_sha256) = 64
        AND predecessor_architecture_bootstrap_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      successor_architecture_host_id TEXT NOT NULL UNIQUE CHECK (
        successor_architecture_host_id GLOB 'rolehost-????????-????-????-????-????????????'
        AND length(successor_architecture_host_id) = 45
        AND successor_architecture_host_id NOT GLOB '*[^a-z0-9-]*'
        AND substr(successor_architecture_host_id, 10) NOT GLOB '*[^0-9a-f-]*'
      ),
      successor_architecture_bootstrap_sha256 TEXT NOT NULL CHECK (
        length(successor_architecture_bootstrap_sha256) = 64
        AND successor_architecture_bootstrap_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      predecessor_architecture_host_executable_sha256 TEXT NOT NULL CHECK (
        length(predecessor_architecture_host_executable_sha256) = 64
        AND predecessor_architecture_host_executable_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      successor_architecture_host_executable_sha256 TEXT NOT NULL CHECK (
        length(successor_architecture_host_executable_sha256) = 64
        AND successor_architecture_host_executable_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      successor_architecture_executable_evidence_sha256 TEXT NOT NULL CHECK (
        length(successor_architecture_executable_evidence_sha256) = 64
        AND successor_architecture_executable_evidence_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      predecessor_security_host_id TEXT NOT NULL UNIQUE
        REFERENCES herdr_role_hosts(id) ON DELETE RESTRICT,
      predecessor_security_bootstrap_sha256 TEXT NOT NULL CHECK (
        length(predecessor_security_bootstrap_sha256) = 64
        AND predecessor_security_bootstrap_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      successor_security_host_id TEXT NOT NULL UNIQUE CHECK (
        successor_security_host_id GLOB 'rolehost-????????-????-????-????-????????????'
        AND length(successor_security_host_id) = 45
        AND successor_security_host_id NOT GLOB '*[^a-z0-9-]*'
        AND substr(successor_security_host_id, 10) NOT GLOB '*[^0-9a-f-]*'
      ),
      successor_security_bootstrap_sha256 TEXT NOT NULL CHECK (
        length(successor_security_bootstrap_sha256) = 64
        AND successor_security_bootstrap_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      predecessor_security_host_executable_sha256 TEXT NOT NULL CHECK (
        length(predecessor_security_host_executable_sha256) = 64
        AND predecessor_security_host_executable_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      successor_security_host_executable_sha256 TEXT NOT NULL CHECK (
        length(successor_security_host_executable_sha256) = 64
        AND successor_security_host_executable_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      successor_security_executable_evidence_sha256 TEXT NOT NULL CHECK (
        length(successor_security_executable_evidence_sha256) = 64
        AND successor_security_executable_evidence_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      predecessor_test_host_id TEXT NOT NULL UNIQUE
        REFERENCES herdr_role_hosts(id) ON DELETE RESTRICT,
      predecessor_test_bootstrap_sha256 TEXT NOT NULL CHECK (
        length(predecessor_test_bootstrap_sha256) = 64
        AND predecessor_test_bootstrap_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      successor_test_host_id TEXT NOT NULL UNIQUE CHECK (
        successor_test_host_id GLOB 'rolehost-????????-????-????-????-????????????'
        AND length(successor_test_host_id) = 45
        AND successor_test_host_id NOT GLOB '*[^a-z0-9-]*'
        AND substr(successor_test_host_id, 10) NOT GLOB '*[^0-9a-f-]*'
      ),
      successor_test_bootstrap_sha256 TEXT NOT NULL CHECK (
        length(successor_test_bootstrap_sha256) = 64
        AND successor_test_bootstrap_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      predecessor_test_host_executable_sha256 TEXT NOT NULL CHECK (
        length(predecessor_test_host_executable_sha256) = 64
        AND predecessor_test_host_executable_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      successor_test_host_executable_sha256 TEXT NOT NULL CHECK (
        length(successor_test_host_executable_sha256) = 64
        AND successor_test_host_executable_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      successor_test_executable_evidence_sha256 TEXT NOT NULL CHECK (
        length(successor_test_executable_evidence_sha256) = 64
        AND successor_test_executable_evidence_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      predecessor_synthesis_host_id TEXT NOT NULL UNIQUE
        REFERENCES herdr_role_hosts(id) ON DELETE RESTRICT,
      predecessor_synthesis_bootstrap_sha256 TEXT NOT NULL CHECK (
        length(predecessor_synthesis_bootstrap_sha256) = 64
        AND predecessor_synthesis_bootstrap_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      successor_synthesis_host_id TEXT NOT NULL UNIQUE CHECK (
        successor_synthesis_host_id GLOB 'rolehost-????????-????-????-????-????????????'
        AND length(successor_synthesis_host_id) = 45
        AND successor_synthesis_host_id NOT GLOB '*[^a-z0-9-]*'
        AND substr(successor_synthesis_host_id, 10) NOT GLOB '*[^0-9a-f-]*'
      ),
      successor_synthesis_bootstrap_sha256 TEXT NOT NULL CHECK (
        length(successor_synthesis_bootstrap_sha256) = 64
        AND successor_synthesis_bootstrap_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      predecessor_synthesis_host_executable_sha256 TEXT NOT NULL CHECK (
        length(predecessor_synthesis_host_executable_sha256) = 64
        AND predecessor_synthesis_host_executable_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      successor_synthesis_host_executable_sha256 TEXT NOT NULL CHECK (
        length(successor_synthesis_host_executable_sha256) = 64
        AND successor_synthesis_host_executable_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      successor_synthesis_executable_evidence_sha256 TEXT NOT NULL CHECK (
        length(successor_synthesis_executable_evidence_sha256) = 64
        AND successor_synthesis_executable_evidence_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      workspace_id TEXT NOT NULL,
      socket_device INTEGER NOT NULL CHECK (socket_device >= 0),
      socket_inode INTEGER NOT NULL CHECK (socket_inode > 0),
      socket_owner INTEGER NOT NULL CHECK (socket_owner >= 0),
      socket_permissions INTEGER NOT NULL CHECK (socket_permissions BETWEEN 0 AND 511),
      socket_peer_evidence_sha256 TEXT NOT NULL CHECK (
        length(socket_peer_evidence_sha256) = 64
        AND socket_peer_evidence_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      successor_run_id TEXT NOT NULL UNIQUE CHECK (
        length(successor_run_id) BETWEEN 8 AND 64
        AND successor_run_id NOT GLOB '*[^a-z0-9-]*'
      ),
      prior_attempt_count INTEGER NOT NULL CHECK (prior_attempt_count = 3),
      created_at REAL NOT NULL,
      UNIQUE(repository_id, job_id, predecessor_generation, successor_generation),
      CHECK (
        successor_architecture_host_id != successor_security_host_id
        AND successor_architecture_host_id != successor_test_host_id
        AND successor_architecture_host_id != successor_synthesis_host_id
        AND successor_security_host_id != successor_test_host_id
        AND successor_security_host_id != successor_synthesis_host_id
        AND successor_test_host_id != successor_synthesis_host_id
      )
    ) STRICT
    """

  private static let herdrGenerationRolloverAuthorizationInsertAuthorityV9 = """
    CREATE TRIGGER herdr_generation_rollover_authorization_insert_authority
    BEFORE INSERT ON herdr_generation_rollover_authorizations
    WHEN (SELECT paused FROM app_settings WHERE singleton = 1) != 1
      OR EXISTS (
        SELECT 1 FROM herdr_generation_rollover_authorizations WHERE job_id = NEW.job_id
      )
      OR EXISTS (
        SELECT 1 FROM herdr_role_host_replacement_authorizations WHERE job_id = NEW.job_id
      )
      OR EXISTS (
        SELECT 1 FROM herdr_replacement_role_hosts WHERE job_id = NEW.job_id
      )
      OR EXISTS (
        SELECT 1 FROM pi_runs WHERE id = NEW.successor_run_id
      )
      OR EXISTS (
        SELECT 1 FROM herdr_role_hosts
        WHERE id IN (
          NEW.successor_architecture_host_id, NEW.successor_security_host_id,
          NEW.successor_test_host_id, NEW.successor_synthesis_host_id
        )
      )
      OR NOT EXISTS (
        SELECT 1
        FROM jobs AS job
        JOIN herdr_job_bindings AS binding ON binding.job_id = job.id
        JOIN herdr_repository_bindings AS repository
          ON repository.repository_id = job.repository_id
        JOIN pi_runs AS run ON run.id = NEW.predecessor_run_id
        JOIN pi_run_launches AS q1
          ON q1.run_id = run.id AND q1.queue_sequence = 1
        JOIN pi_run_launches AS q2
          ON q2.run_id = run.id AND q2.queue_sequence = 2
        JOIN pi_run_launches AS q3
          ON q3.run_id = run.id AND q3.queue_sequence = 3
        WHERE job.id = NEW.job_id
          AND job.repository_id = NEW.repository_id
          AND job.kind = 'prReview'
          AND job.state = 'runningPi'
          AND binding.repository_id = NEW.repository_id
          AND binding.generation = NEW.predecessor_generation
          AND binding.workspace_id = NEW.workspace_id
          AND binding.state = 'lost'
          AND repository.state = 'active'
          AND repository.workspace_id = NEW.workspace_id
          AND repository.socket_device = NEW.socket_device
          AND repository.socket_inode = NEW.socket_inode
          AND repository.socket_owner = NEW.socket_owner
          AND repository.socket_permissions = NEW.socket_permissions
          AND run.job_id = NEW.job_id
          AND run.runtime_kind = 'herdr'
          AND run.workflow = 'pr-review'
          AND run.role = 'architecture'
          AND run.topology_generation = NEW.predecessor_generation
          AND run.resumes_run_id IS NULL
          AND run.accepted = 0 AND run.settled = 0 AND run.outcome = 'running'
          AND q1.launch_attempt_id = NEW.q1_launch_attempt_id
          AND q1.role_host_id = NEW.predecessor_architecture_host_id
          AND q1.descriptor_sha256 = NEW.q1_descriptor_sha256
          AND q1.launch_mode = 'fresh' AND q1.state = 'failed'
          AND q1.failure_code = NEW.q1_failure_code
          AND q1.child_pid = NEW.q1_child_pid
          AND q1.child_process_group_id = NEW.q1_child_process_group_id
          AND q1.child_start_seconds = NEW.q1_child_start_seconds
          AND q1.child_start_microseconds = NEW.q1_child_start_microseconds
          AND q2.launch_attempt_id = NEW.q2_launch_attempt_id
          AND q2.role_host_id = NEW.predecessor_architecture_host_id
          AND q2.descriptor_sha256 = NEW.q2_descriptor_sha256
          AND q2.launch_mode = 'fresh' AND q2.state = 'failed'
          AND q2.failure_code = NEW.q2_failure_code AND q2.child_pid IS NULL
          AND q3.launch_attempt_id = NEW.q3_launch_attempt_id
          AND q3.role_host_id = NEW.predecessor_architecture_host_id
          AND q3.descriptor_sha256 = NEW.q3_descriptor_sha256
          AND q3.launch_mode = 'fresh' AND q3.state = 'failed'
          AND q3.failure_code = NEW.q3_failure_code AND q3.child_pid IS NULL
          AND (SELECT COUNT(*) FROM pi_run_launches WHERE run_id = run.id) = 3
          AND (SELECT COUNT(*) FROM pi_run_results WHERE run_id = run.id) = 0
          AND (SELECT COUNT(*) FROM pi_run_session_origins WHERE run_id = run.id) = 0
          AND (
            SELECT COUNT(*) FROM herdr_role_hosts
            WHERE job_id = NEW.job_id AND generation = NEW.predecessor_generation
              AND state = 'lost'
          ) = 4
          AND EXISTS (
            SELECT 1 FROM herdr_role_hosts
            WHERE id = NEW.predecessor_architecture_host_id
              AND job_id = NEW.job_id AND generation = NEW.predecessor_generation
              AND role = 'architecture' AND state = 'lost'
              AND bootstrap_descriptor_sha256
                = NEW.predecessor_architecture_bootstrap_sha256
              AND host_executable_sha256
                = NEW.predecessor_architecture_host_executable_sha256
          )
          AND EXISTS (
            SELECT 1 FROM herdr_role_hosts
            WHERE id = NEW.predecessor_security_host_id
              AND job_id = NEW.job_id AND generation = NEW.predecessor_generation
              AND role = 'security' AND state = 'lost'
              AND bootstrap_descriptor_sha256 = NEW.predecessor_security_bootstrap_sha256
              AND host_executable_sha256
                = NEW.predecessor_security_host_executable_sha256
          )
          AND EXISTS (
            SELECT 1 FROM herdr_role_hosts
            WHERE id = NEW.predecessor_test_host_id
              AND job_id = NEW.job_id AND generation = NEW.predecessor_generation
              AND role = 'test' AND state = 'lost'
              AND bootstrap_descriptor_sha256 = NEW.predecessor_test_bootstrap_sha256
              AND host_executable_sha256
                = NEW.predecessor_test_host_executable_sha256
          )
          AND EXISTS (
            SELECT 1 FROM herdr_role_hosts
            WHERE id = NEW.predecessor_synthesis_host_id
              AND job_id = NEW.job_id AND generation = NEW.predecessor_generation
              AND role = 'synthesis' AND state = 'lost'
              AND bootstrap_descriptor_sha256
                = NEW.predecessor_synthesis_bootstrap_sha256
              AND host_executable_sha256
                = NEW.predecessor_synthesis_host_executable_sha256
          )
          AND (
            SELECT COUNT(*) FROM job_transitions
            WHERE job_id = NEW.job_id
              AND event_key = (
                'canary:' || NEW.canary_authorization_sha256 || ':m8:admit:' || NEW.job_id
              )
          ) = 1
          AND NOT EXISTS (
            SELECT 1 FROM job_transitions
            WHERE job_id = NEW.job_id
              AND event_key = (
                'canary:' || NEW.canary_authorization_sha256 || ':m8:close:' || NEW.job_id
              )
          )
          AND (
            SELECT COUNT(*) FROM job_transitions
            WHERE job_id = NEW.job_id
              AND event_key GLOB (
                'canary:' || NEW.canary_authorization_sha256 || ':m8:pi-fresh-retry:'
                || run.id || ':' || q1.launch_attempt_id || ':*'
              )
          ) = 1
          AND (
            SELECT COUNT(*) FROM job_transitions
            WHERE job_id = NEW.job_id
              AND event_key GLOB (
                'canary:' || NEW.canary_authorization_sha256 || ':m8:pi-fresh-retry:'
                || run.id || ':' || q2.launch_attempt_id || ':*'
              )
          ) = 1
          AND (
            SELECT COUNT(*) FROM job_transitions
            WHERE job_id = NEW.job_id
              AND event_key GLOB (
                'canary:' || NEW.canary_authorization_sha256 || ':m8:pi-fresh-retry:'
                || run.id || ':' || q3.launch_attempt_id || ':*'
              )
          ) = 2
      )
    BEGIN
      SELECT RAISE(ABORT, 'generation rollover lacks exact lost-lineage authority');
    END
    """

  private static let herdrGenerationRolloverAuthorizationUpdateDeniedV9 = """
    CREATE TRIGGER herdr_generation_rollover_authorization_update_denied
    BEFORE UPDATE ON herdr_generation_rollover_authorizations
    BEGIN
      SELECT RAISE(ABORT, 'generation rollover authorization is immutable');
    END
    """

  private static let herdrGenerationRolloverAuthorizationDeleteDeniedV9 = """
    CREATE TRIGGER herdr_generation_rollover_authorization_delete_denied
    BEFORE DELETE ON herdr_generation_rollover_authorizations
    BEGIN
      SELECT RAISE(ABORT, 'generation rollover authorization is append-only');
    END
    """

  private static let herdrPiRunRolloversTableV9 = """
    CREATE TABLE herdr_pi_run_rollovers (
      rollover_authorization_sha256 TEXT PRIMARY KEY
        REFERENCES herdr_generation_rollover_authorizations(
          rollover_authorization_sha256
        ) ON DELETE RESTRICT,
      q4_authorization_sha256 TEXT NOT NULL UNIQUE CHECK (
        length(q4_authorization_sha256) = 64
        AND q4_authorization_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      q4_evidence_sha256 TEXT NOT NULL UNIQUE CHECK (
        length(q4_evidence_sha256) = 64
        AND q4_evidence_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      predecessor_run_id TEXT NOT NULL UNIQUE REFERENCES pi_runs(id) ON DELETE RESTRICT,
      successor_run_id TEXT NOT NULL UNIQUE
        REFERENCES pi_runs(id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
      successor_architecture_host_id TEXT NOT NULL UNIQUE
        REFERENCES herdr_role_hosts(id) ON DELETE RESTRICT,
      planned_q4_launch_attempt_id TEXT NOT NULL UNIQUE CHECK (
        planned_q4_launch_attempt_id GLOB 'launch-????????-????-????-????-????????????'
        AND length(planned_q4_launch_attempt_id) = 43
        AND planned_q4_launch_attempt_id NOT GLOB '*[^a-z0-9-]*'
        AND substr(planned_q4_launch_attempt_id, 8) NOT GLOB '*[^0-9a-f-]*'
      ),
      prior_attempt_count INTEGER NOT NULL CHECK (prior_attempt_count = 3),
      lineage_sha256 TEXT NOT NULL UNIQUE CHECK (
        length(lineage_sha256) = 64 AND lineage_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      successor_run_nonce TEXT NOT NULL CHECK (
        length(successor_run_nonce) = 64 AND successor_run_nonce NOT GLOB '*[^0-9a-f]*'
      ),
      successor_request_sha256 TEXT NOT NULL CHECK (
        length(successor_request_sha256) = 64
        AND successor_request_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      successor_resource_version TEXT NOT NULL,
      successor_resource_hash TEXT NOT NULL CHECK (
        length(successor_resource_hash) = 64
        AND successor_resource_hash NOT GLOB '*[^0-9a-f]*'
      ),
      successor_model TEXT NOT NULL,
      successor_session_path TEXT NOT NULL,
      successor_channel_path TEXT NOT NULL,
      q4_descriptor_sha256 TEXT NOT NULL CHECK (
        length(q4_descriptor_sha256) = 64 AND q4_descriptor_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      q4_configuration_sha256 TEXT NOT NULL CHECK (
        length(q4_configuration_sha256) = 64
        AND q4_configuration_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      q4_prompt_sha256 TEXT NOT NULL CHECK (
        length(q4_prompt_sha256) = 64 AND q4_prompt_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      q4_workflow_configuration_sha256 TEXT NOT NULL CHECK (
        length(q4_workflow_configuration_sha256) = 64
        AND q4_workflow_configuration_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      q4_prior_launch_descriptor_sha256 TEXT NOT NULL CHECK (
        length(q4_prior_launch_descriptor_sha256) = 64
        AND q4_prior_launch_descriptor_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      q4_prior_launch_configuration_sha256 TEXT NOT NULL CHECK (
        length(q4_prior_launch_configuration_sha256) = 64
        AND q4_prior_launch_configuration_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      q4_resource_tree_sha256 TEXT NOT NULL CHECK (
        length(q4_resource_tree_sha256) = 64
        AND q4_resource_tree_sha256 NOT GLOB '*[^0-9a-f]*'
      ),
      created_at REAL NOT NULL
    ) STRICT
    """

  private static let herdrPiRunRolloverInsertAuthorityV9 = """
    CREATE TRIGGER herdr_pi_run_rollover_insert_authority
    BEFORE INSERT ON herdr_pi_run_rollovers
    WHEN (SELECT paused FROM app_settings WHERE singleton = 1) != 1
      OR EXISTS (SELECT 1 FROM pi_runs WHERE id = NEW.successor_run_id)
      OR EXISTS (
        SELECT 1 FROM pi_run_launches
        WHERE launch_attempt_id = NEW.planned_q4_launch_attempt_id
      )
      OR NOT EXISTS (
        SELECT 1
        FROM herdr_generation_rollover_authorizations AS authorization
        JOIN pi_runs AS predecessor ON predecessor.id = authorization.predecessor_run_id
        JOIN herdr_job_bindings AS binding ON binding.job_id = authorization.job_id
        WHERE authorization.rollover_authorization_sha256
            = NEW.rollover_authorization_sha256
          AND authorization.predecessor_run_id = NEW.predecessor_run_id
          AND authorization.successor_run_id = NEW.successor_run_id
          AND authorization.successor_architecture_host_id
            = NEW.successor_architecture_host_id
          AND authorization.prior_attempt_count = NEW.prior_attempt_count
          AND authorization.lineage_sha256 = NEW.lineage_sha256
          AND predecessor.job_id = authorization.job_id
          AND predecessor.topology_generation = authorization.predecessor_generation
          AND predecessor.accepted = 0 AND predecessor.settled = 0
          AND predecessor.outcome = 'running'
          AND binding.generation = authorization.successor_generation
          AND binding.workspace_id = authorization.workspace_id
          AND binding.state = 'active'
          AND (
            SELECT COUNT(*) FROM pi_runs
            WHERE job_id = authorization.job_id
              AND topology_generation = authorization.successor_generation
          ) = 0
          AND (
            SELECT COUNT(*) FROM herdr_role_hosts
            WHERE job_id = authorization.job_id
              AND generation = authorization.successor_generation
              AND state = 'waiting' AND last_queue_sequence = 0
          ) = 4
          AND EXISTS (
            SELECT 1 FROM herdr_role_hosts
            WHERE id = authorization.successor_architecture_host_id
              AND role = 'architecture' AND state = 'waiting' AND last_queue_sequence = 0
              AND bootstrap_descriptor_sha256
                = authorization.successor_architecture_bootstrap_sha256
              AND host_executable_sha256
                = authorization.successor_architecture_host_executable_sha256
          )
          AND EXISTS (
            SELECT 1 FROM herdr_role_hosts
            WHERE id = authorization.successor_security_host_id
              AND role = 'security' AND state = 'waiting' AND last_queue_sequence = 0
              AND bootstrap_descriptor_sha256
                = authorization.successor_security_bootstrap_sha256
              AND host_executable_sha256
                = authorization.successor_security_host_executable_sha256
          )
          AND EXISTS (
            SELECT 1 FROM herdr_role_hosts
            WHERE id = authorization.successor_test_host_id
              AND role = 'test' AND state = 'waiting' AND last_queue_sequence = 0
              AND bootstrap_descriptor_sha256 = authorization.successor_test_bootstrap_sha256
              AND host_executable_sha256
                = authorization.successor_test_host_executable_sha256
          )
          AND EXISTS (
            SELECT 1 FROM herdr_role_hosts
            WHERE id = authorization.successor_synthesis_host_id
              AND role = 'synthesis' AND state = 'waiting' AND last_queue_sequence = 0
              AND bootstrap_descriptor_sha256
                = authorization.successor_synthesis_bootstrap_sha256
              AND host_executable_sha256
                = authorization.successor_synthesis_host_executable_sha256
          )
      )
    BEGIN
      SELECT RAISE(ABORT, 'successor run lacks exact generation rollover authority');
    END
    """

  private static let herdrPiRunRolloverUpdateDeniedV9 = """
    CREATE TRIGGER herdr_pi_run_rollover_update_denied
    BEFORE UPDATE ON herdr_pi_run_rollovers
    BEGIN
      SELECT RAISE(ABORT, 'successor run rollover is immutable');
    END
    """

  private static let herdrPiRunRolloverDeleteDeniedV9 = """
    CREATE TRIGGER herdr_pi_run_rollover_delete_denied
    BEFORE DELETE ON herdr_pi_run_rollovers
    BEGIN
      SELECT RAISE(ABORT, 'successor run rollover is append-only');
    END
    """

  private static let herdrRoleHostInitialQueueAuthorityV9 = """
    CREATE TRIGGER herdr_role_host_initial_queue_authority
    BEFORE UPDATE OF last_queue_sequence ON herdr_role_hosts
    WHEN NEW.last_queue_sequence IS NOT OLD.last_queue_sequence
      AND NEW.last_queue_sequence != OLD.last_queue_sequence + 1
      AND NOT (
        OLD.last_queue_sequence = 0 AND NEW.last_queue_sequence = 3
        AND OLD.state = 'waiting' AND NEW.state = OLD.state
        AND NEW.id IS OLD.id AND NEW.job_id IS OLD.job_id
        AND NEW.generation IS OLD.generation AND NEW.role IS OLD.role
        AND NEW.workspace_id IS OLD.workspace_id AND NEW.tab_id IS OLD.tab_id
        AND NEW.pane_id IS OLD.pane_id AND NEW.terminal_id IS OLD.terminal_id
        AND NEW.bootstrap_descriptor_sha256 IS OLD.bootstrap_descriptor_sha256
        AND NEW.host_executable_sha256 IS OLD.host_executable_sha256
        AND NEW.host_pid IS OLD.host_pid
        AND NEW.host_start_seconds IS OLD.host_start_seconds
        AND NEW.host_start_microseconds IS OLD.host_start_microseconds
        AND NEW.lifecycle_sequence IS OLD.lifecycle_sequence
        AND NEW.created_at IS OLD.created_at AND NEW.updated_at >= OLD.updated_at
        AND EXISTS (
          SELECT 1
          FROM herdr_pi_run_rollovers AS rollover
          JOIN herdr_generation_rollover_authorizations AS authorization
            ON authorization.rollover_authorization_sha256
              = rollover.rollover_authorization_sha256
          WHERE rollover.successor_architecture_host_id = OLD.id
            AND authorization.job_id = OLD.job_id
            AND authorization.successor_generation = OLD.generation
            AND authorization.successor_architecture_host_id = OLD.id
        )
      )
    BEGIN
      SELECT RAISE(ABORT, 'role host queue offset lacks exact rollover authority');
    END
    """

  private static let piRunsGenerationRolloverInsertAuthorityV9 = """
    CREATE TRIGGER pi_runs_generation_rollover_insert_authority
    BEFORE INSERT ON pi_runs
    WHEN NEW.runtime_kind = 'herdr'
      AND EXISTS (
        SELECT 1 FROM herdr_generation_rollover_authorizations AS authorization
        WHERE authorization.job_id = NEW.job_id
          AND authorization.successor_generation = NEW.topology_generation
      )
      AND NOT EXISTS (
        SELECT 1
        FROM herdr_generation_rollover_authorizations AS authorization
        JOIN pi_runs AS predecessor ON predecessor.id = authorization.predecessor_run_id
        JOIN herdr_pi_run_rollovers AS rollover
          ON rollover.rollover_authorization_sha256
            = authorization.rollover_authorization_sha256
          AND rollover.predecessor_run_id = predecessor.id
          AND rollover.successor_run_id = authorization.successor_run_id
        JOIN herdr_job_bindings AS binding ON binding.job_id = authorization.job_id
        WHERE authorization.job_id = NEW.job_id
          AND authorization.successor_generation = NEW.topology_generation
          AND authorization.successor_run_id = NEW.id
          AND NEW.workflow = predecessor.workflow
          AND NEW.role = 'architecture' AND NEW.round = predecessor.round
          AND NEW.job_attempt = predecessor.job_attempt
          AND NEW.job_step = predecessor.job_step
          AND NEW.resumes_run_id IS NULL
          AND NEW.run_nonce = rollover.successor_run_nonce
          AND NEW.request_sha256 = rollover.successor_request_sha256
          AND NEW.resource_version = rollover.successor_resource_version
          AND NEW.resource_hash = rollover.successor_resource_hash
          AND NEW.model = rollover.successor_model
          AND NEW.session_path = rollover.successor_session_path
          AND NEW.channel_path = rollover.successor_channel_path
          AND NEW.accepted = 0 AND NEW.settled = 0
          AND NEW.structured_result_digest IS NULL AND NEW.outcome = 'prepared'
          AND binding.generation = authorization.successor_generation
          AND binding.workspace_id = authorization.workspace_id
          AND binding.state = 'active'
          AND (SELECT COUNT(*) FROM pi_runs
            WHERE job_id = NEW.job_id
              AND topology_generation = NEW.topology_generation) = 0
      )
    BEGIN
      SELECT RAISE(ABORT, 'Pi run lacks exact generation rollover identity');
    END
    """

  private static let herdrGenerationRolloverPredecessorRunImmutableV9 = """
    CREATE TRIGGER herdr_generation_rollover_predecessor_run_immutable
    BEFORE UPDATE ON pi_runs
    WHEN EXISTS (
      SELECT 1 FROM herdr_generation_rollover_authorizations AS authorization
      WHERE authorization.predecessor_run_id = OLD.id
    )
    BEGIN
      SELECT RAISE(ABORT, 'generation rollover predecessor run is immutable');
    END
    """

  private static let herdrGenerationRolloverPredecessorLaunchImmutableV9 = """
    CREATE TRIGGER herdr_generation_rollover_predecessor_launch_immutable
    BEFORE UPDATE ON pi_run_launches
    WHEN EXISTS (
      SELECT 1 FROM herdr_generation_rollover_authorizations AS authorization
      WHERE OLD.launch_attempt_id IN (
        authorization.q1_launch_attempt_id,
        authorization.q2_launch_attempt_id,
        authorization.q3_launch_attempt_id
      )
    )
    BEGIN
      SELECT RAISE(ABORT, 'generation rollover predecessor launches are immutable');
    END
    """

  private static let herdrGenerationRolloverPredecessorHostImmutableV9 = """
    CREATE TRIGGER herdr_generation_rollover_predecessor_host_immutable
    BEFORE UPDATE ON herdr_role_hosts
    WHEN EXISTS (
      SELECT 1 FROM herdr_generation_rollover_authorizations AS authorization
      WHERE OLD.id IN (
        authorization.predecessor_architecture_host_id,
        authorization.predecessor_security_host_id,
        authorization.predecessor_test_host_id,
        authorization.predecessor_synthesis_host_id
      )
    )
    BEGIN
      SELECT RAISE(ABORT, 'generation rollover predecessor hosts are immutable');
    END
    """

  private static let herdrJobBindingGenerationRolloverAuthorityV9 = """
    CREATE TRIGGER herdr_job_binding_generation_rollover_authority
    BEFORE UPDATE ON herdr_job_bindings
    WHEN EXISTS (
      SELECT 1 FROM herdr_generation_rollover_authorizations AS authorization
      WHERE authorization.job_id = OLD.job_id
    ) AND NOT EXISTS (
      SELECT 1 FROM herdr_generation_rollover_authorizations AS authorization
      WHERE authorization.job_id = OLD.job_id
        AND NEW.job_id IS OLD.job_id
        AND NEW.repository_id IS OLD.repository_id
        AND NEW.workspace_id = authorization.workspace_id
        AND NEW.created_at IS OLD.created_at
        AND NEW.updated_at >= OLD.updated_at
        AND (
          OLD.generation = authorization.predecessor_generation
            AND OLD.state = 'lost'
            AND NEW.generation = authorization.successor_generation
            AND NEW.tab_id IS NULL AND NEW.state = 'prepared'
          OR OLD.generation = authorization.successor_generation
            AND NEW.generation = OLD.generation
        )
    )
    BEGIN
      SELECT RAISE(ABORT, 'job binding lacks exact generation rollover authority');
    END
    """

  private static let appSettingsGenerationRolloverResumeDeniedV9 = """
    CREATE TRIGGER app_settings_generation_rollover_resume_denied
    BEFORE UPDATE OF paused ON app_settings
    WHEN OLD.paused = 1 AND NEW.paused = 0
      AND EXISTS (SELECT 1 FROM herdr_generation_rollover_authorizations)
    BEGIN
      SELECT RAISE(ABORT, 'Resume requires separate generation rollover authorization');
    END
    """

  private static let appSettingsGenerationRolloverInsertResumeDeniedV9 = """
    CREATE TRIGGER app_settings_generation_rollover_insert_resume_denied
    BEFORE INSERT ON app_settings
    WHEN NEW.paused = 0
      AND EXISTS (SELECT 1 FROM herdr_generation_rollover_authorizations)
    BEGIN
      SELECT RAISE(ABORT, 'Resume requires separate generation rollover authorization');
    END
    """

  private static let appSettingsGenerationRolloverDeleteDeniedV9 = """
    CREATE TRIGGER app_settings_generation_rollover_delete_denied
    BEFORE DELETE ON app_settings
    WHEN EXISTS (SELECT 1 FROM herdr_generation_rollover_authorizations)
    BEGIN
      SELECT RAISE(ABORT, 'generation rollover pause authority is immutable');
    END
    """

  private static let herdrPrimeIntentDeleteDeniedV7 = """
    CREATE TRIGGER herdr_prime_intent_delete_denied
    BEFORE DELETE ON herdr_topology_intents
    WHEN OLD.kind = 'primeAgentAuthority'
    BEGIN
      SELECT RAISE(ABORT, 'Herdr agent prime intent is append-only');
    END
    """

  private static let herdrPrimeIntentInsertAuthorityV7 = """
    CREATE TRIGGER herdr_prime_intent_insert_authority
    BEFORE INSERT ON herdr_topology_intents
    WHEN NEW.kind = 'primeAgentAuthority' AND (
      NEW.state != 'prepared'
      OR NEW.attribution_json IS NOT NULL
      OR NOT EXISTS (
        SELECT 1 FROM herdr_prime_retry_candidates AS candidate
        WHERE candidate.job_id = NEW.job_id
          AND candidate.repository_id = NEW.repository_id
          AND candidate.generation = NEW.generation
          AND candidate.socket_device = NEW.socket_device
          AND candidate.socket_inode = NEW.socket_inode
          AND candidate.socket_owner = NEW.socket_owner
          AND candidate.socket_permissions = NEW.socket_permissions
      )
    )
    BEGIN
      SELECT RAISE(ABORT, 'Herdr agent prime lacks exact causal authority');
    END
    """

  private static let herdrPrimeIntentSendAuthorityV7 = """
    CREATE TRIGGER herdr_prime_intent_send_authority
    BEFORE UPDATE OF state ON herdr_topology_intents
    WHEN OLD.kind = 'primeAgentAuthority' AND NEW.state = 'sendStarted' AND NOT EXISTS (
      SELECT 1 FROM herdr_prime_retry_candidates AS candidate
      WHERE candidate.job_id = OLD.job_id
        AND candidate.repository_id = OLD.repository_id
        AND candidate.generation = OLD.generation
        AND candidate.socket_device = OLD.socket_device
        AND candidate.socket_inode = OLD.socket_inode
        AND candidate.socket_owner = OLD.socket_owner
        AND candidate.socket_permissions = OLD.socket_permissions
    )
    BEGIN
      SELECT RAISE(ABORT, 'Herdr agent prime send lacks current authority');
    END
    """

  private static let herdrPrimeIntentDeleteDeniedV8 = """
    CREATE TRIGGER herdr_prime_intent_delete_denied
    BEFORE DELETE ON herdr_topology_intents
    WHEN OLD.kind IN ('primeAgentAuthority', 'resetAgentAuthority')
    BEGIN
      SELECT RAISE(ABORT, 'Herdr agent authority intent is append-only');
    END
    """

  private static let herdrPrimeIntentDeleteDeniedV9 = """
    CREATE TRIGGER herdr_prime_intent_delete_denied
    BEFORE DELETE ON herdr_topology_intents
    WHEN OLD.kind IN (
      'primeAgentAuthority', 'resetAgentAuthority', 'replaceRoleHost'
    )
    BEGIN
      SELECT RAISE(ABORT, 'Herdr canary recovery intent is append-only');
    END
    """

  private static let herdrPrimeIntentInsertAuthorityV8 = """
    CREATE TRIGGER herdr_prime_intent_insert_authority
    BEFORE INSERT ON herdr_topology_intents
    WHEN NEW.kind = 'primeAgentAuthority' AND (
      NEW.state != 'prepared'
      OR NEW.attribution_json IS NOT NULL
      OR EXISTS (
        SELECT 1 FROM herdr_topology_intents AS existing
        WHERE existing.job_id = NEW.job_id
          AND existing.kind IN ('primeAgentAuthority', 'resetAgentAuthority')
      )
      OR NOT EXISTS (
        SELECT 1 FROM herdr_prime_retry_candidates AS candidate
        WHERE candidate.job_id = NEW.job_id
          AND candidate.repository_id = NEW.repository_id
          AND candidate.generation = NEW.generation
          AND candidate.socket_device = NEW.socket_device
          AND candidate.socket_inode = NEW.socket_inode
          AND candidate.socket_owner = NEW.socket_owner
          AND candidate.socket_permissions = NEW.socket_permissions
      )
    )
    BEGIN
      SELECT RAISE(ABORT, 'Herdr agent prime lacks exact causal authority');
    END
    """

  private static let herdrPrimeIntentSendAuthorityV8 = """
    CREATE TRIGGER herdr_prime_intent_send_authority
    BEFORE UPDATE OF state ON herdr_topology_intents
    WHEN OLD.kind = 'primeAgentAuthority' AND NEW.state = 'sendStarted' AND (
      (SELECT COUNT(*) FROM herdr_topology_intents AS existing
        WHERE existing.job_id = OLD.job_id
          AND existing.kind = 'primeAgentAuthority') != 1
      OR EXISTS (
        SELECT 1 FROM herdr_topology_intents AS existing
        WHERE existing.job_id = OLD.job_id AND existing.kind = 'resetAgentAuthority'
      )
      OR NOT EXISTS (
        SELECT 1 FROM herdr_prime_retry_candidates AS candidate
        WHERE candidate.job_id = OLD.job_id
          AND candidate.repository_id = OLD.repository_id
          AND candidate.generation = OLD.generation
          AND candidate.socket_device = OLD.socket_device
          AND candidate.socket_inode = OLD.socket_inode
          AND candidate.socket_owner = OLD.socket_owner
          AND candidate.socket_permissions = OLD.socket_permissions
      )
    )
    BEGIN
      SELECT RAISE(ABORT, 'Herdr agent prime send lacks current authority');
    END
    """

  private static let herdrResetIntentInsertAuthorityV8 = """
    CREATE TRIGGER herdr_reset_intent_insert_authority
    BEFORE INSERT ON herdr_topology_intents
    WHEN NEW.kind = 'resetAgentAuthority' AND (
      NEW.state != 'prepared'
      OR NEW.attribution_json IS NOT NULL
      OR EXISTS (
        SELECT 1 FROM herdr_topology_intents AS existing
        WHERE existing.job_id = NEW.job_id AND existing.kind = 'resetAgentAuthority'
      )
      OR NOT EXISTS (
        SELECT 1 FROM herdr_agent_reset_candidates AS candidate
        WHERE candidate.job_id = NEW.job_id
          AND candidate.repository_id = NEW.repository_id
          AND candidate.generation = NEW.generation
          AND candidate.socket_device = NEW.socket_device
          AND candidate.socket_inode = NEW.socket_inode
          AND candidate.socket_owner = NEW.socket_owner
          AND candidate.socket_permissions = NEW.socket_permissions
      )
    )
    BEGIN
      SELECT RAISE(ABORT, 'Herdr agent authority reset lacks exact causal authority');
    END
    """

  private static let herdrResetIntentSendAuthorityV8 = """
    CREATE TRIGGER herdr_reset_intent_send_authority
    BEFORE UPDATE OF state ON herdr_topology_intents
    WHEN OLD.kind = 'resetAgentAuthority' AND NEW.state = 'sendStarted' AND (
      (SELECT COUNT(*) FROM herdr_topology_intents AS existing
        WHERE existing.job_id = OLD.job_id
          AND existing.kind = 'resetAgentAuthority') != 1
      OR NOT EXISTS (
        SELECT 1 FROM herdr_agent_reset_candidates AS candidate
        WHERE candidate.job_id = OLD.job_id
          AND candidate.repository_id = OLD.repository_id
          AND candidate.generation = OLD.generation
          AND candidate.socket_device = OLD.socket_device
          AND candidate.socket_inode = OLD.socket_inode
          AND candidate.socket_owner = OLD.socket_owner
          AND candidate.socket_permissions = OLD.socket_permissions
          AND candidate.failed_prime_intent_id = (
            SELECT failed_prime.id FROM herdr_topology_intents AS failed_prime
            WHERE failed_prime.job_id = OLD.job_id
              AND failed_prime.kind = 'primeAgentAuthority'
              AND failed_prime.state = 'unknown'
          )
      )
    )
    BEGIN
      SELECT RAISE(ABORT, 'Herdr agent authority reset send lacks current authority');
    END
    """

  private static let piRunLaunchInsertAuthorityV7 = """
    CREATE TRIGGER pi_run_launch_insert_authority
    BEFORE INSERT ON pi_run_launches
    WHEN NOT EXISTS (
      SELECT 1
      FROM pi_runs AS run
      JOIN herdr_role_hosts AS host ON host.id = NEW.role_host_id
      WHERE run.id = NEW.run_id
        AND run.runtime_kind = 'herdr'
        AND run.settled = 0
        AND host.job_id = run.job_id
        AND host.generation = run.topology_generation
        AND host.role = run.role
        AND host.state IN ('waiting', 'running')
        AND (
          (
            NOT EXISTS (
              SELECT 1 FROM pi_run_launches AS prior_launch
              WHERE prior_launch.run_id = run.id
            )
            AND (
              (
                run.resumes_run_id IS NULL
                AND NEW.launch_mode = 'fresh'
                AND NEW.expected_session_id IS NULL
                AND NEW.resume_boundary_sha256 IS NULL
              )
              OR (
                run.resumes_run_id IS NOT NULL
                AND NEW.launch_mode = 'crossRunResume'
                AND EXISTS (
                  SELECT 1 FROM pi_runs AS origin
                  WHERE origin.id = run.resumes_run_id
                    AND origin.accepted = 1
                    AND origin.settled = 1
                    AND origin.session_id = NEW.expected_session_id
                    AND origin.session_boundary_sha256 = NEW.resume_boundary_sha256
                )
              )
            )
          )
          OR (
            EXISTS (
              SELECT 1 FROM pi_run_launches AS prior_launch
              WHERE prior_launch.run_id = run.id
            )
            AND NEW.launch_mode = 'sameRunResume'
            AND EXISTS (
              SELECT 1 FROM pi_run_session_origins AS session_origin
              WHERE session_origin.run_id = run.id
                AND session_origin.session_id = NEW.expected_session_id
                AND session_origin.origin_resume_boundary_sha256 IS NEW.resume_boundary_sha256
            )
            AND (
              SELECT last_launch.state
              FROM pi_run_launches AS last_launch
              WHERE last_launch.run_id = run.id
              ORDER BY last_launch.queue_sequence DESC, last_launch.launch_attempt_id DESC
              LIMIT 1
            ) IN ('failed', 'interruptedUnknown')
          )
          OR (
            NEW.launch_mode = 'fresh'
            AND NEW.expected_session_id IS NULL
            AND NEW.resume_boundary_sha256 IS NULL
            AND (SELECT COUNT(*) FROM pi_run_launches WHERE run_id = run.id) = 1
            AND EXISTS (
              SELECT 1 FROM pi_run_launches AS prior_launch
              WHERE prior_launch.run_id = run.id
                AND prior_launch.queue_sequence = 1
                AND prior_launch.launch_mode = 'fresh'
                AND prior_launch.state = 'failed'
                AND prior_launch.failure_code = 'RUNTIME_TIMEOUT'
                AND prior_launch.child_pid IS NOT NULL
            )
            AND NOT EXISTS (SELECT 1 FROM pi_run_session_origins WHERE run_id = run.id)
            AND NOT EXISTS (SELECT 1 FROM pi_run_results WHERE run_id = run.id)
            AND (
              SELECT COUNT(*) FROM job_transitions AS authorization
              WHERE authorization.job_id = run.job_id
                AND authorization.from_state = 'runningPi'
                AND authorization.to_state = 'runningPi'
                AND authorization.event_key GLOB (
                  'canary:*:pi-fresh-retry:' || run.id || ':' ||
                  (SELECT launch_attempt_id FROM pi_run_launches WHERE run_id = run.id) || ':*'
                )
            ) = 1
          )
          OR (
            NEW.launch_mode = 'fresh'
            AND NEW.expected_session_id IS NULL
            AND NEW.resume_boundary_sha256 IS NULL
            AND (SELECT COUNT(*) FROM pi_run_launches WHERE run_id = run.id) = 2
            AND EXISTS (
              SELECT 1 FROM pi_run_launches
              WHERE run_id = run.id AND queue_sequence = 1 AND launch_mode = 'fresh'
                AND state = 'failed' AND failure_code = 'RUNTIME_TIMEOUT'
                AND child_pid IS NOT NULL
            )
            AND EXISTS (
              SELECT 1 FROM pi_run_launches
              WHERE run_id = run.id AND queue_sequence = 2 AND launch_mode = 'fresh'
                AND state = 'failed' AND failure_code = 'HERDR_TRANSACTION_FAILED'
                AND child_pid IS NULL
            )
            AND NOT EXISTS (SELECT 1 FROM pi_run_session_origins WHERE run_id = run.id)
            AND NOT EXISTS (SELECT 1 FROM pi_run_results WHERE run_id = run.id)
            AND (
              SELECT COUNT(*) FROM job_transitions AS authorization
              WHERE authorization.job_id = run.job_id
                AND authorization.from_state = 'runningPi'
                AND authorization.to_state = 'runningPi'
                AND authorization.event_key GLOB (
                  'canary:*:pi-fresh-retry:' || run.id || ':' ||
                  (SELECT launch_attempt_id FROM pi_run_launches
                    WHERE run_id = run.id AND queue_sequence = 1) || ':*'
                )
            ) = 1
            AND (
              SELECT COUNT(*) FROM job_transitions AS authorization
              WHERE authorization.job_id = run.job_id
                AND authorization.from_state = 'runningPi'
                AND authorization.to_state = 'runningPi'
                AND authorization.event_key GLOB (
                  'canary:*:pi-fresh-retry:' || run.id || ':' ||
                  (SELECT launch_attempt_id FROM pi_run_launches
                    WHERE run_id = run.id AND queue_sequence = 2) || ':*'
                )
            ) = 1
            AND (
              SELECT COUNT(*) FROM job_transitions AS authorization
              WHERE authorization.job_id = run.job_id
                AND authorization.from_state = 'runningPi'
                AND authorization.to_state = 'runningPi'
                AND authorization.event_key GLOB ('canary:*:pi-fresh-retry:' || run.id || ':*')
            ) = 2
          )
          OR (
            NEW.launch_mode = 'fresh'
            AND NEW.expected_session_id IS NULL
            AND NEW.resume_boundary_sha256 IS NULL
            AND NEW.queue_sequence = 4
            AND EXISTS (
              SELECT 1
              FROM herdr_prime_retry_candidates AS candidate
              JOIN herdr_topology_intents AS intent
                ON intent.kind = 'primeAgentAuthority'
                AND intent.repository_id = candidate.repository_id
                AND intent.job_id = candidate.job_id
                AND intent.generation = candidate.generation
                AND intent.socket_device = candidate.socket_device
                AND intent.socket_inode = candidate.socket_inode
                AND intent.socket_owner = candidate.socket_owner
                AND intent.socket_permissions = candidate.socket_permissions
                AND intent.state = 'attributed'
              WHERE candidate.run_id = run.id
                AND candidate.role_host_id = host.id
                AND json_extract(intent.attribution_json, '$.workspaceID') = candidate.workspace_id
                AND json_extract(intent.attribution_json, '$.tabID') = candidate.tab_id
                AND json_array_length(json_extract(intent.attribution_json, '$.paneIDs')) = 1
                AND json_extract(intent.attribution_json, '$.paneIDs[0]') = candidate.pane_id
                AND json_extract(intent.attribution_json, '$.terminalID') = candidate.terminal_id
                AND json_extract(intent.attribution_json, '$.agent') = 'pi'
                AND json_extract(intent.attribution_json, '$.agentSessionAbsent') = 1
                AND length(json_extract(intent.attribution_json, '$.alias')) BETWEEN 1 AND 32
                AND length(json_extract(intent.attribution_json, '$.tokensSHA256')) = 64
                AND EXISTS (
                  SELECT 1 FROM job_transitions AS prime_event
                  WHERE prime_event.job_id = run.job_id
                    AND prime_event.from_state = 'runningPi'
                    AND prime_event.to_state = 'runningPi'
                    AND prime_event.event_key GLOB (
                      'canary:*:pi-agent-prime:' || run.id || ':' ||
                      candidate.failed_launch_attempt_id || ':' || NEW.launch_attempt_id || ':' ||
                      host.id || ':' || intent.payload_sha256
                    )
                )
            )
          )
        )
    )
    BEGIN
      SELECT RAISE(ABORT, 'Pi launch lacks exact causal authority');
    END
    """

  private static let piRunLaunchInsertAuthorityV8: String = {
    let candidateNeedle = "FROM herdr_prime_retry_candidates AS candidate"
    let kindNeedle = "intent.kind = 'primeAgentAuthority'"
    let eventNeedle = "'canary:*:pi-agent-prime:' || run.id || ':' ||"
    precondition(piRunLaunchInsertAuthorityV7.contains(candidateNeedle))
    precondition(piRunLaunchInsertAuthorityV7.contains(kindNeedle))
    precondition(piRunLaunchInsertAuthorityV7.contains(eventNeedle))
    return
      piRunLaunchInsertAuthorityV7
      .replacingOccurrences(
        of: candidateNeedle,
        with: "FROM herdr_q4_authority_candidates AS candidate"
      )
      .replacingOccurrences(
        of: kindNeedle,
        with: "intent.kind = candidate.intent_kind"
      )
      .replacingOccurrences(
        of: eventNeedle,
        with: "'canary:*:' || candidate.event_kind || ':' || run.id || ':' ||"
      )
  }()

  private static let piRunLaunchIdentityImmutableV9 = """
    CREATE TRIGGER pi_run_launch_identity_immutable
    BEFORE UPDATE ON pi_run_launches
    WHEN NEW.launch_attempt_id IS NOT OLD.launch_attempt_id
      OR NEW.run_id IS NOT OLD.run_id
      OR NEW.role_host_id IS NOT OLD.role_host_id
      OR NEW.execution_role_host_id IS NOT OLD.execution_role_host_id
      OR NEW.queue_sequence IS NOT OLD.queue_sequence
      OR NEW.launch_mode IS NOT OLD.launch_mode
      OR NEW.descriptor_sha256 IS NOT OLD.descriptor_sha256
      OR NEW.expected_session_id IS NOT OLD.expected_session_id
      OR NEW.resume_boundary_sha256 IS NOT OLD.resume_boundary_sha256
      OR NEW.created_at IS NOT OLD.created_at
      OR (OLD.child_pid IS NOT NULL AND (
        NEW.child_pid IS NOT OLD.child_pid
        OR NEW.child_process_group_id IS NOT OLD.child_process_group_id
        OR NEW.child_start_seconds IS NOT OLD.child_start_seconds
        OR NEW.child_start_microseconds IS NOT OLD.child_start_microseconds
      ))
    BEGIN
      SELECT RAISE(ABORT, 'Pi launch identity is immutable');
    END
    """

  private static let piRunLaunchInsertAuthorityV9: String = {
    let prefix = "WHEN NOT EXISTS ("
    let suffix = "\n)\nBEGIN"
    let settledNeedle = "AND run.settled = 0"
    let hostSequenceNeedle = "AND host.state IN ('waiting', 'running')"
    var value = piRunLaunchInsertAuthorityV8
    guard value.contains(settledNeedle), value.contains(hostSequenceNeedle) else {
      preconditionFailure("schema-8 launch authority predicates changed")
    }
    value = value.replacingOccurrences(
      of: settledNeedle,
      with: """
        AND run.settled = 0
          AND NOT EXISTS (
            SELECT 1 FROM herdr_pi_run_rollovers AS rollover
            WHERE rollover.successor_run_id = run.id
          )
          AND NOT EXISTS (
            SELECT 1 FROM herdr_generation_rollover_authorizations AS authorization
            WHERE authorization.successor_run_id = run.id
          )
        """
    )
    value = value.replacingOccurrences(
      of: hostSequenceNeedle,
      with: """
        AND host.state IN ('waiting', 'running')
          AND NEW.queue_sequence = host.last_queue_sequence + 1
        """
    )
    guard let prefixRange = value.range(of: prefix),
      value.range(of: suffix, options: .backwards) != nil
    else { preconditionFailure("schema-8 launch authority shape changed") }
    value.replaceSubrange(
      prefixRange,
      with: "WHEN NOT (\n      (NEW.execution_role_host_id IS NULL AND EXISTS ("
    )
    guard let adjustedSuffixRange = value.range(of: suffix, options: .backwards) else {
      preconditionFailure("schema-8 launch authority suffix changed")
    }
    value.replaceSubrange(
      adjustedSuffixRange,
      with: """

            )
          )
          OR (
            NEW.execution_role_host_id IS NULL
            AND EXISTS (
              SELECT 1
              FROM herdr_pi_run_rollovers AS rollover
              JOIN herdr_generation_rollover_authorizations AS authorization
                ON authorization.rollover_authorization_sha256
                  = rollover.rollover_authorization_sha256
              JOIN pi_runs AS successor ON successor.id = rollover.successor_run_id
              JOIN pi_runs AS predecessor ON predecessor.id = rollover.predecessor_run_id
              JOIN herdr_job_bindings AS binding ON binding.job_id = successor.job_id
              JOIN herdr_role_hosts AS host ON host.id = NEW.role_host_id
              JOIN pi_run_launches AS q1
                ON q1.run_id = predecessor.id AND q1.queue_sequence = 1
              JOIN pi_run_launches AS q2
                ON q2.run_id = predecessor.id AND q2.queue_sequence = 2
              JOIN pi_run_launches AS q3
                ON q3.run_id = predecessor.id AND q3.queue_sequence = 3
              WHERE successor.id = NEW.run_id
                AND successor.runtime_kind = 'herdr'
                AND successor.workflow = 'pr-review'
                AND successor.role = 'architecture'
                AND successor.resumes_run_id IS NULL
                AND successor.accepted = 0 AND successor.settled = 0
                AND successor.outcome IN ('prepared', 'running')
                AND successor.topology_generation = authorization.successor_generation
                AND predecessor.id = authorization.predecessor_run_id
                AND predecessor.job_id = successor.job_id
                AND predecessor.topology_generation
                  = authorization.predecessor_generation
                AND predecessor.accepted = 0 AND predecessor.settled = 0
                AND host.id = rollover.successor_architecture_host_id
                AND host.id = authorization.successor_architecture_host_id
                AND host.job_id = successor.job_id
                AND host.generation = successor.topology_generation
                AND host.role = 'architecture'
                AND host.state IN ('waiting', 'running')
                AND host.last_queue_sequence = 3
                AND host.bootstrap_descriptor_sha256
                  = authorization.successor_architecture_bootstrap_sha256
                AND host.host_executable_sha256
                  = authorization.successor_architecture_host_executable_sha256
                AND binding.generation = successor.topology_generation
                AND binding.workspace_id = authorization.workspace_id
                AND binding.state = 'active'
                AND rollover.planned_q4_launch_attempt_id = NEW.launch_attempt_id
                AND rollover.q4_descriptor_sha256 = NEW.descriptor_sha256
                AND rollover.prior_attempt_count = 3
                AND rollover.lineage_sha256 = authorization.lineage_sha256
                AND NEW.queue_sequence = 4
                AND NEW.queue_sequence = host.last_queue_sequence + 1
                AND NEW.launch_mode = 'fresh'
                AND NEW.expected_session_id IS NULL
                AND NEW.resume_boundary_sha256 IS NULL
                AND (SELECT paused FROM app_settings WHERE singleton = 1) = 1
                AND (SELECT COUNT(*) FROM pi_run_launches
                  WHERE run_id = successor.id) = 0
                AND (SELECT COUNT(*) FROM pi_run_results
                  WHERE run_id = successor.id) = 0
                AND (SELECT COUNT(*) FROM pi_run_session_origins
                  WHERE run_id = successor.id) = 0
                AND q1.launch_attempt_id = authorization.q1_launch_attempt_id
                AND q1.descriptor_sha256 = authorization.q1_descriptor_sha256
                AND q1.launch_mode = 'fresh' AND q1.state = 'failed'
                AND q1.failure_code = 'RUNTIME_TIMEOUT' AND q1.child_pid IS NOT NULL
                AND q2.launch_attempt_id = authorization.q2_launch_attempt_id
                AND q2.descriptor_sha256 = authorization.q2_descriptor_sha256
                AND q2.launch_mode = 'fresh' AND q2.state = 'failed'
                AND q2.failure_code = 'HERDR_TRANSACTION_FAILED' AND q2.child_pid IS NULL
                AND q3.launch_attempt_id = authorization.q3_launch_attempt_id
                AND q3.descriptor_sha256 = authorization.q3_descriptor_sha256
                AND q3.launch_mode = 'fresh' AND q3.state = 'failed'
                AND q3.failure_code = 'HERDR_TRANSACTION_FAILED' AND q3.child_pid IS NULL
                AND (SELECT COUNT(*) FROM pi_run_launches
                  WHERE run_id = predecessor.id) = 3
                AND (SELECT COUNT(*) FROM pi_run_results
                  WHERE run_id = predecessor.id) = 0
                AND NOT EXISTS (
                  SELECT 1 FROM herdr_role_host_replacement_authorizations
                  WHERE job_id = successor.job_id
                )
            )
          )
          OR (
            NEW.execution_role_host_id IS NOT NULL
            AND EXISTS (
              SELECT 1
              FROM pi_runs AS replacement_run
              JOIN herdr_role_hosts AS predecessor
                ON predecessor.id = NEW.role_host_id
              JOIN herdr_replacement_role_hosts AS replacement
                ON replacement.id = NEW.execution_role_host_id
              JOIN herdr_topology_intents AS replacement_intent
                ON replacement_intent.id = replacement.replacement_intent_id
              JOIN herdr_role_host_replacement_authorizations AS replacement_authorization
                ON replacement_authorization.payload_sha256
                  = replacement_intent.payload_sha256
                AND replacement_authorization.repository_id
                  = replacement_intent.repository_id
                AND replacement_authorization.job_id = replacement_intent.job_id
                AND replacement_authorization.generation = replacement_intent.generation
                AND replacement_authorization.run_id = replacement_run.id
                AND replacement_authorization.predecessor_role_host_id = predecessor.id
                AND replacement_authorization.planned_replacement_role_host_id
                  = replacement.id
                AND replacement_authorization.q4_descriptor_sha256
                  = NEW.descriptor_sha256
              WHERE replacement_run.id = NEW.run_id
                AND replacement_run.runtime_kind = 'herdr'
                AND replacement_run.settled = 0
                AND replacement_run.outcome = 'running'
                AND replacement_run.role = 'architecture'
                AND predecessor.job_id = replacement_run.job_id
                AND predecessor.generation = replacement_run.topology_generation
                AND predecessor.role = replacement_run.role
                AND predecessor.state = 'stopped'
                AND predecessor.last_queue_sequence = 3
                AND replacement.predecessor_role_host_id = predecessor.id
                AND replacement.job_id = replacement_run.job_id
                AND replacement.generation = replacement_run.topology_generation
                AND replacement.role = replacement_run.role
                AND replacement.state IN ('waiting', 'running')
                AND replacement.last_queue_sequence = 4
                AND replacement.q4_descriptor_sha256
                  = replacement_authorization.q4_descriptor_sha256
                AND replacement.q4_configuration_sha256
                  = replacement_authorization.q4_configuration_sha256
                AND replacement.q4_prompt_sha256
                  = replacement_authorization.q4_prompt_sha256
                AND replacement.q4_workflow_configuration_sha256
                  = replacement_authorization.q4_workflow_configuration_sha256
                AND replacement.q4_prior_launch_descriptor_sha256
                  = replacement_authorization.q4_prior_launch_descriptor_sha256
                AND replacement.q4_prior_launch_configuration_sha256
                  = replacement_authorization.q4_prior_launch_configuration_sha256
                AND replacement.q4_resource_tree_sha256
                  = replacement_authorization.q4_resource_tree_sha256
                AND replacement_intent.kind = 'replaceRoleHost'
                AND replacement_intent.job_id = replacement_run.job_id
                AND replacement_intent.generation = replacement_run.topology_generation
                AND replacement_intent.state = 'attributed'
                AND replacement_authorization.failed_launch_attempt_id = (
                  SELECT launch_attempt_id FROM pi_run_launches
                  WHERE run_id = replacement_run.id AND queue_sequence = 3
                )
                AND replacement_authorization.planned_launch_attempt_id
                  = NEW.launch_attempt_id
                AND replacement_authorization.planned_replacement_role_host_id
                  = NEW.execution_role_host_id
                AND NEW.queue_sequence = 4
                AND NEW.launch_mode = 'fresh'
                AND NEW.expected_session_id IS NULL
                AND NEW.resume_boundary_sha256 IS NULL
                AND (SELECT COUNT(*) FROM pi_run_launches
                  WHERE run_id = replacement_run.id) = 3
                AND EXISTS (
                  SELECT 1 FROM pi_run_launches
                  WHERE run_id = replacement_run.id AND queue_sequence = 1
                    AND launch_mode = 'fresh' AND state = 'failed'
                    AND failure_code = 'RUNTIME_TIMEOUT' AND child_pid IS NOT NULL
                    AND execution_role_host_id IS NULL
                )
                AND EXISTS (
                  SELECT 1 FROM pi_run_launches
                  WHERE run_id = replacement_run.id AND queue_sequence = 2
                    AND launch_mode = 'fresh' AND state = 'failed'
                    AND failure_code = 'HERDR_TRANSACTION_FAILED' AND child_pid IS NULL
                    AND execution_role_host_id IS NULL
                )
                AND EXISTS (
                  SELECT 1 FROM pi_run_launches
                  WHERE run_id = replacement_run.id AND queue_sequence = 3
                    AND launch_mode = 'fresh' AND state = 'failed'
                    AND failure_code = 'HERDR_TRANSACTION_FAILED' AND child_pid IS NULL
                    AND execution_role_host_id IS NULL
                )
                AND NOT EXISTS (SELECT 1 FROM pi_run_results
                  WHERE run_id = replacement_run.id)
                AND NOT EXISTS (SELECT 1 FROM pi_run_session_origins
                  WHERE run_id = replacement_run.id)
                AND (
                  SELECT COUNT(*) FROM job_transitions AS authorization
                  WHERE authorization.job_id = replacement_run.job_id
                    AND authorization.from_state = 'runningPi'
                    AND authorization.to_state = 'runningPi'
                    AND authorization.event_key GLOB (
                      'canary:*:pi-fresh-retry:' || replacement_run.id || ':*'
                    )
                ) = 4
                AND json_extract(
                  replacement_intent.attribution_json,
                  '$.predecessorRoleHostID'
                ) = predecessor.id
                AND json_extract(
                  replacement_intent.attribution_json,
                  '$.replacementRoleHostID'
                ) = replacement.id
                AND json_extract(replacement_intent.attribution_json, '$.workspaceID')
                  = replacement.workspace_id
                AND json_extract(replacement_intent.attribution_json, '$.tabID')
                  = replacement.tab_id
                AND json_extract(replacement_intent.attribution_json, '$.paneID')
                  = replacement.pane_id
                AND json_extract(replacement_intent.attribution_json, '$.terminalID')
                  = replacement.terminal_id
                AND json_extract(replacement_intent.attribution_json, '$.processID')
                  = replacement.host_pid
                AND json_extract(replacement_intent.attribution_json, '$.startSeconds')
                  = replacement.host_start_seconds
                AND json_extract(replacement_intent.attribution_json, '$.startMicroseconds')
                  = replacement.host_start_microseconds
                AND json_extract(
                  replacement_intent.attribution_json,
                  '$.hostExecutableSHA256'
                ) = replacement.host_executable_sha256
                AND json_extract(
                  replacement_intent.attribution_json,
                  '$.replacementAuthorizationSHA256'
                ) = replacement_authorization.replacement_authorization_sha256
                AND json_extract(
                  replacement_intent.attribution_json,
                  '$.replacementEvidenceSHA256'
                ) = replacement_authorization.replacement_evidence_sha256
                AND json_extract(
                  replacement_intent.attribution_json,
                  '$.incidentAuditSHA256'
                ) = replacement_authorization.incident_audit_sha256
                AND json_extract(
                  replacement_intent.attribution_json,
                  '$.credentialEvidenceSHA256'
                ) = replacement_authorization.credential_evidence_sha256
                AND json_extract(
                  replacement_intent.attribution_json,
                  '$.q4Binding.descriptorSHA256'
                ) = replacement_authorization.q4_descriptor_sha256
                AND json_extract(
                  replacement_intent.attribution_json,
                  '$.q4Binding.configurationSHA256'
                ) = replacement_authorization.q4_configuration_sha256
                AND json_extract(
                  replacement_intent.attribution_json,
                  '$.q4Binding.promptSHA256'
                ) = replacement_authorization.q4_prompt_sha256
                AND json_extract(
                  replacement_intent.attribution_json,
                  '$.q4Binding.workflowConfigurationSHA256'
                ) = replacement_authorization.q4_workflow_configuration_sha256
                AND json_extract(
                  replacement_intent.attribution_json,
                  '$.q4Binding.priorLaunchDescriptorSHA256'
                ) = replacement_authorization.q4_prior_launch_descriptor_sha256
                AND json_extract(
                  replacement_intent.attribution_json,
                  '$.q4Binding.priorLaunchConfigurationSHA256'
                ) = replacement_authorization.q4_prior_launch_configuration_sha256
                AND json_extract(
                  replacement_intent.attribution_json,
                  '$.q4Binding.resourceTreeSHA256'
                ) = replacement_authorization.q4_resource_tree_sha256
                AND json_extract(replacement_intent.attribution_json, '$.agent') = 'pi'
                AND json_extract(
                  replacement_intent.attribution_json,
                  '$.agentSessionAbsent'
                ) = 1
                AND length(json_extract(
                  replacement_intent.attribution_json,
                  '$.tokensSHA256'
                )) = 64
                AND EXISTS (
                  SELECT 1 FROM job_transitions AS replacement_event
                  WHERE replacement_event.job_id = replacement_run.job_id
                    AND replacement_event.from_state = 'runningPi'
                    AND replacement_event.to_state = 'runningPi'
                    AND replacement_event.event_key = (
                      'canary:' || replacement_authorization.canary_authorization_sha256 ||
                      ':m8:pi-role-host-replacement:' || replacement_run.id || ':' ||
                      (SELECT launch_attempt_id FROM pi_run_launches
                        WHERE run_id = replacement_run.id AND queue_sequence = 3) || ':' ||
                      NEW.launch_attempt_id || ':' || predecessor.id || ':' || replacement.id || ':' ||
                      replacement_intent.payload_sha256
                    )
                )
            )
          )
        )
        BEGIN
        """
    )
    return value
  }()

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

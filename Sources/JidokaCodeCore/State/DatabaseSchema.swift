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

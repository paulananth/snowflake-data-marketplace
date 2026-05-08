# Agentic Data Marketplace on Snowflake

**Repo:** https://github.com/paulananth/snowflake-data-marketplace

End-to-end platform for building, governing, and consuming **Snowflake Semantic Views** through an AI agent, with native RBAC enforcement, a human-in-the-loop description feedback loop (RLHF-style), and a complete CI/CD lifecycle.

---

## What This Is

When a user asks a business question in natural language, the **Cortex Agent**:

1. Discovers the right semantic view across business domains
2. Verifies the user is entitled (native Snowflake RBAC)
3. If entitled → answers via Cortex Analyst
4. If not entitled → captures a justification and submits an access request to the data steward

Behind the scenes, every semantic view has a versioned lifecycle — descriptions are AI-generated then human-improved, relationships are inferred, domains are classified, usage is tracked, and access is governed.

---

## Architecture

```
                  +-------------------------------------+
                  |         USER (NL Question)          |
                  +--------------+----------------------+
                                 | user session (RBAC enforced)
                  +--------------v----------------------+
                  |  CORTEX AGENT  (Phase 4)            |
                  |  4 tools: discover, check_ent,      |
                  |  request_access, cortex_analyst     |
                  +--------------+----------------------+
                                 |
                                 v
              +-------------------------------------+
              |  SEMANTIC VIEW LIFECYCLE PLATFORM   |
              |  - 9 catalog tables (Phase 1)       |
              |  - 12 stored procedures (Ph 1+2)    |
              |  - 1 Snowflake Task     (Phase 2d)  |
              |  - Streamlit app        (Phase 3)   |
              +-------------------------------------+
                                 |
                                 v
                    +----------------------------+
                    |   SNOWFLAKE SEMANTIC VIEW  |
                    |   (TPCH_ANALYSIS_VIEW)     |
                    +----------------------------+
```

---

## Repository Layout

```
.
+-- SEMANTIC_VIEW_MARKETPLACE_PLAN.md     # Full architectural plan
+-- README.md                             # This file
+-- AGENTS.md                             # Cortex Agent + Streamlit app specifications
+-- deploy_foundation.sql                 # Phase 1: catalog schema + 6 core procs
+-- deploy_phase2_phase3.sql              # Phase 2bcd + Builder Streamlit app
+-- deploy_phase4.sql                     # Phase 4: discover proc + Cortex Agent
+-- deploy_github_integration.sql         # Snowflake <- GitHub pull-side integration
+-- streamlit_app.py                      # SEMANTIC_VIEW_BUILDER (governance, 6 tabs)
+-- streamlit_app_explorer.py             # SEMANTIC_VIEW_EXPLORER (Cortex Analyst Q&A + query builder)
+-- .gitignore
```

---

## Deployment

### Prerequisites

- Snowflake account with `ACCOUNTADMIN` (or equivalent) role
- A warehouse named `COMPUTE_WH` (or update DDL to your warehouse)
- For full functionality: Cortex inference enabled (`AI_COMPLETE`, `DATA_AGENT_RUN`). Trial accounts can deploy all objects but cannot invoke the agent at runtime; heuristic fallbacks ensure non-AI paths work.

### Deploy in Order

```sql
-- 1. Foundation (idempotent)
!source deploy_foundation.sql

-- 2. Entitlement, domain, usage aggregation, Streamlit
!source deploy_phase2_phase3.sql

-- 3. Cortex Agent
!source deploy_phase4.sql
```

### Upload Streamlit App Files

There are two Streamlit apps. Upload each app's Python file to its stage.

**Builder app:**
```sql
PUT file://streamlit_app.py @MY_DB.PUBLIC.STREAMLIT_STAGE OVERWRITE=TRUE AUTO_COMPRESS=FALSE;

-- From a Snowflake Workspace:
COPY FILES INTO @MY_DB.PUBLIC.STREAMLIT_STAGE
FROM 'snow://workspace/<USER>$.PUBLIC.DEFAULT$/versions/live'
FILES = ('streamlit_app.py');
```

**Explorer app:**
```sql
CREATE STAGE IF NOT EXISTS MY_DB.PUBLIC.SV_EXPLORER_STAGE DIRECTORY = (ENABLE = TRUE);

-- Upload renames .py to streamlit_app.py inside the stage
CALL MY_DB.PUBLIC.SP_WRITE_STAGE_FILE(
  '@MY_DB.PUBLIC.SV_EXPLORER_STAGE',
  'streamlit_app.py',
  '<paste contents of streamlit_app_explorer.py>'
);

CREATE OR REPLACE STREAMLIT MY_DB.PUBLIC.SEMANTIC_VIEW_EXPLORER
  ROOT_LOCATION = '@MY_DB.PUBLIC.SV_EXPLORER_STAGE'
  MAIN_FILE = 'streamlit_app.py'
  QUERY_WAREHOUSE = COMPUTE_WH
  TITLE = 'Semantic View Explorer';
```

**Universal helper** (works for either app once `SP_WRITE_STAGE_FILE` is deployed):
```sql
CALL MY_DB.PUBLIC.SP_WRITE_STAGE_FILE('@<stage>', 'streamlit_app.py', '<file content>');
```

### Smoke Test

```sql
-- Build the TPC-H semantic view end-to-end
CALL MY_DB.PUBLIC.SP_SV_BUILD_END_TO_END(
  ARRAY_CONSTRUCT(
    'SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.CUSTOMER',
    'SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.ORDERS',
    'SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.LINEITEM'
  ),
  ARRAY_CONSTRUCT(
    'SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.CUSTOMER',
    'SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.ORDERS',
    'SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.LINEITEM'
  ),
  'MY_DB.PUBLIC.TPCH_ANALYSIS_VIEW',
  'TPC-H semantic view: customer-orders-lineitem hierarchy'
);

-- Cross-table validation query
SELECT * FROM SEMANTIC_VIEW(
  MY_DB.PUBLIC.TPCH_ANALYSIS_VIEW
  DIMENSIONS C_MKTSEGMENT
  METRICS    O_TOTALPRICE_SUM
) ORDER BY O_TOTALPRICE_SUM DESC;
```

---

## Object Inventory

### Database & Schemas
| Object | Type |
|---|---|
| `MY_DB` | database |
| `MY_DB.SEMANTIC_CATALOG` | schema (catalog tables) |
| `MY_DB.PUBLIC` | schema (procs, agent, app) |

### Catalog Tables (`MY_DB.SEMANTIC_CATALOG`)
| Table | Purpose |
|---|---|
| `SV_REGISTRY` | Per-version state machine: DRAFT, TESTING, PENDING_APPROVAL, DEPLOYED, ARCHIVED, REJECTED |
| `SV_COLUMNS` | Column metadata; **dual descriptions** (`ai_description`, `human_description`); `effective_description = COALESCE(human, ai)` |
| `SV_RELATIONSHIPS` | Inferred + human-defined joins, with confidence scores |
| `SV_TEST_RESULTS` | CI/CD test outcomes per version |
| `SV_ANALYST_FEEDBACK` | NL questions, query IDs, human ratings (1-5) |
| `SV_DOMAINS` | AI-suggested + human-confirmed business domains; data steward assignments |
| `SV_GLOSSARY` | Business term standardization across views |
| `SV_ACCESS_REQUESTS` | Permission workflow: PENDING / APPROVED / DENIED / EXPIRED |
| `SV_USAGE_ANALYTICS` | Daily usage rollups from QUERY_HISTORY |

### Stored Procedures (`MY_DB.PUBLIC`)

**Foundation (Phase 1):**
- `SP_SV_DESCRIBE_TABLES(ARRAY)` — DESCRIBE TABLE for each input
- `SP_SV_GENERATE_AI_DESCRIPTIONS(ARRAY)` — calls `AI_GENERATE_TABLE_DESC`
- `SP_SV_CLASSIFY_COLUMNS(VARIANT, VARIANT)` — heuristic role assignment
- `SP_SV_GENERATE_DDL(VARIANT)` — composes `CREATE SEMANTIC VIEW` DDL
- `SP_SV_CREATE_AND_CATALOG(...)` — executes DDL, populates catalog
- `SP_SV_BUILD_END_TO_END(ARRAY, ARRAY, VARCHAR, VARCHAR)` — master orchestration

**Entitlement (Phase 2b):**
- `SP_SV_CHECK_ENTITLEMENT(VARCHAR)` — RBAC check for current user
- `SP_SV_REQUEST_ACCESS(VARCHAR, VARCHAR, VARCHAR)` — log access request
- `SP_SV_APPROVE_ACCESS(NUMBER, VARCHAR, VARCHAR)` — execute GRANT
- `SP_SV_DENY_ACCESS(NUMBER, VARCHAR)` — deny request

**Domain (Phase 2c):**
- `SP_SV_SUGGEST_DOMAINS(VARCHAR)` — AI domain classification with heuristic fallback

**Usage (Phase 2d):**
- `SP_SV_AGGREGATE_USAGE()` — pull from QUERY_HISTORY into SV_USAGE_ANALYTICS
- `TASK_SV_FEEDBACK_COLLECTOR` — hourly cron (suspended initially)

**Discovery (Phase 4):**
- `SP_SV_DISCOVER(VARCHAR)` — keyword search over catalog

**Utility:**
- `SP_WRITE_STAGE_FILE(stage_path VARCHAR, file_name VARCHAR, content STRING)` — pushes any text content as a file to any internal stage. Used to deploy/update Streamlit app files without an External Access Integration.

### Stages
| Stage | Purpose |
|---|---|
| `MY_DB.PUBLIC.STREAMLIT_STAGE` | Hosts the BUILDER app file |
| `MY_DB.PUBLIC.SV_EXPLORER_STAGE` | Hosts the EXPLORER app file |

### Streamlit Apps
| App | Purpose |
|---|---|
| `MY_DB.PUBLIC.SEMANTIC_VIEW_BUILDER` | 6 tabs: Build, Review, CI/CD, Domains, Access Control, Usage & Health |
| `MY_DB.PUBLIC.SEMANTIC_VIEW_EXPLORER` | Cortex Analyst NL Q&A panel + interactive query builder + entitlement gate |

### Cortex Agent
- `MY_DB.PUBLIC.SEMANTIC_MARKETPLACE_AGENT` — see [AGENTS.md](AGENTS.md)

### Semantic View Synonyms (Cortex Analyst quality)
`MY_DB.PUBLIC.TPCH_ANALYSIS_VIEW` was rebuilt with `WITH SYNONYMS` clauses on key elements so Cortex Analyst maps natural language to the right metrics/dimensions:

| Element | Synonyms |
|---|---|
| `O_TOTALPRICE_SUM` | revenue, sales, income, order value, total order value |
| `L_QUANTITY_SUM` | quantity, units, qty, volume |
| `L_EXTENDEDPRICE_SUM` | line revenue, line item revenue, gross revenue |
| `L_DISCOUNT_SUM` | discount, total discount |
| `C_NAME` | customer, client, account name |
| `C_MKTSEGMENT` | segment, market, customer segment, industry |
| `O_ORDERPRIORITY` | priority, order priority |
| `L_SHIPMODE` | ship mode, shipping mode, transport |

---

## Key Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| AI description mode | Metadata-only (`use_table_data: false`) | Avoids data exposure, lower cost |
| Description ownership | Both stored; human always wins via COALESCE | Iterative improvement preserves AI baseline |
| Agent identity | Caller's session (not service account) | Native RBAC enforcement; zero-trust by default |
| Domain taxonomy | AI suggests, human confirms | Balance automation with governance |
| Permission workflow | In-platform (catalog + Streamlit) | No external ITSM dependency for Phase 1 |
| Environment | Single account; DB name parameterized | Pragmatic; multi-env extensible later |
| Rollback | Full version archive in SV_REGISTRY | Any version replayable from stored DDL |

---

## Snowflake <-> GitHub Integration

The Snowflake-side `GIT REPOSITORY` object pulls source straight from this repo, so deployments can be re-run directly from GitHub commits.

```sql
-- One-time setup (already in deploy_github_integration.sql)
CREATE OR REPLACE API INTEGRATION GITHUB_PUBLIC_API
  API_PROVIDER = GIT_HTTPS_API
  API_ALLOWED_PREFIXES = ('https://github.com/paulananth/')
  ENABLED = TRUE;

CREATE OR REPLACE GIT REPOSITORY MY_DB.PUBLIC.MARKETPLACE_REPO
  API_INTEGRATION = GITHUB_PUBLIC_API
  ORIGIN = 'https://github.com/paulananth/snowflake-data-marketplace.git';

-- Pull latest
ALTER GIT REPOSITORY MY_DB.PUBLIC.MARKETPLACE_REPO FETCH;

-- Re-deploy any phase straight from GitHub
EXECUTE IMMEDIATE FROM @MY_DB.PUBLIC.MARKETPLACE_REPO/branches/main/deploy_foundation.sql;
```

**Trial account note:** the *push* direction (Snowflake -> GitHub via External Access Integration) is blocked on trial accounts. File uploads were performed manually via the GitHub web UI.

---

## Operational Runbook

### Resume the usage-collection task
```sql
ALTER TASK MY_DB.PUBLIC.TASK_SV_FEEDBACK_COLLECTOR RESUME;
```

### Check what's deployed
```sql
SELECT view_catalog||'.'||view_schema||'.'||view_name AS fqn,
       version_id, status, deployed_at
FROM MY_DB.SEMANTIC_CATALOG.SV_REGISTRY
ORDER BY deployed_at DESC;
```

### Edit a column description (human override)
```sql
UPDATE MY_DB.SEMANTIC_CATALOG.SV_COLUMNS
SET human_description = 'Customer total receivables balance, refreshed nightly',
    description_source = 'HUMAN_EDITED',
    last_edited_by = CURRENT_USER(),
    last_edited_at = CURRENT_TIMESTAMP()
WHERE view_name = 'TPCH_ANALYSIS_VIEW' AND column_name = 'C_ACCTBAL';
```

### Approve an access request manually
```sql
CALL MY_DB.PUBLIC.SP_SV_APPROVE_ACCESS(
  request_id    => 1,
  grant_to_role => 'ANALYST_ROLE',
  reviewer_notes=> 'Approved for Q3 revenue review'
);
```

### Inspect agent spec
```sql
DESCRIBE AGENT MY_DB.PUBLIC.SEMANTIC_MARKETPLACE_AGENT;
```

---

## Roadmap (Deferred)

| Item | Status |
|---|---|
| Phase 2a: CI/CD procs (`RUN_TESTS`, `PROMOTE_VERSION`, `ROLLBACK_VERSION`) | Not built |
| Multi-environment (DEV/STAGING/PROD) | Schema is parameterized; deployment scripts pending |
| External ITSM (ServiceNow/Jira) integration | `SP_SV_REQUEST_ACCESS` can add a webhook |
| Column-level masking on semantic views | Snowflake masking policies layer cleanly |
| Business glossary conflict resolution UI | `SV_GLOSSARY.conflicting_terms` ready for it |
| REST API wrapper for external tools | Cortex Agent REST endpoint already supports this |

---

## Trial Account Limitations

- `AI_COMPLETE`, `SNOWFLAKE.CORTEX.COMPLETE`, `DATA_AGENT_RUN`, and `/api/v2/cortex/analyst/message` all return `Access denied for trial accounts` (error code 399504)
- All catalog objects, procs, the agent, and both Streamlit apps **deploy successfully**
- `SP_SV_SUGGEST_DOMAINS` automatically falls back to keyword heuristics
- The Cortex Agent runs from Snowflake Intelligence UI **only on enabled accounts**
- The Explorer app's NL Q&A panel shows a clear "Cortex Analyst is disabled on trial accounts" banner; the query builder remains fully functional
- External Access Integration (needed for Snowflake → GitHub push) is also blocked; GitHub uploads were performed via the web UI

---

## License & Authors

- Designed and implemented during a structured planning session with Cortex Code in Snowsight
- Owner: ACCOUNTADMIN on account `rn20017`
- Date: 2026-05-08

# Agentic Data Marketplace — Semantic View Lifecycle Platform
## Plan Document v1.0 | Date: 2026-05-08

---

## 1. Vision

Build an **agentic data marketplace** where a Cortex Agent understands user
intent, discovers the right semantic view across business domains, enforces
entitlements via native Snowflake RBAC, and — when a user is not entitled —
automatically routes a permission request to the appropriate data steward.
The platform supports a human-feedback loop (RLHF-style) where descriptions
are iteratively improved and semantic views are promoted through a governed
CI/CD pipeline.

---

## 2. Scope

### Initial Target (Phase 1)
- **Tables:** `SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.CUSTOMER`, `ORDERS`, `LINEITEM`
- **Hierarchy:** CUSTOMER (top) -> ORDERS -> LINEITEM
- **Target View:** `MY_DB.PUBLIC.TPCH_ANALYSIS_VIEW`
- **Catalog Schema:** `MY_DB.SEMANTIC_CATALOG`
- **Environment:** Single Snowflake account (extensible to multi-account later)

### Designed For Scale
- Any set of tables, any account, any domain
- 100+ semantic views across multiple business domains
- Multi-team stewardship and approval workflows

---

## 3. Architecture Overview

```
                    +-------------------------------------+
                    |         USER (NL Question)          |
                    +--------------+----------------------+
                                   | user session context (RBAC enforced)
                    +--------------v----------------------+
                    |         CORTEX AGENT                |
                    |  1. Understand intent               |
                    |  2. Search domain + semantic views  |
                    |  3. Check entitlement               |
                    |  4a. Entitled -> Cortex Analyst     |
                    |  4b. Not entitled -> Request access |
                    +--------------+----------------------+
                                   |
          +------------------------+------------------------+
          v                        v                        v
   SV Discovery             Entitlement Check        Permission Request
   (SV_REGISTRY +           (native Snowflake        (SV_ACCESS_REQUESTS
    SV_COLUMNS search)       GRANT via user session)  + Steward notified)
```

---

## 4. Catalog Schema: `MY_DB.SEMANTIC_CATALOG`

Designed to mirror `INFORMATION_SCHEMA` — one concern per table, familiar naming.

### 4.1 `SV_REGISTRY` — CI/CD State Machine
```sql
view_catalog        VARCHAR    -- database name
view_schema         VARCHAR    -- schema name
view_name           VARCHAR    -- view name
version_id          NUMBER     -- auto-increment
version_tag         VARCHAR    -- e.g. 'v1.0', 'v1.1'
status              VARCHAR    -- DRAFT | TESTING | PENDING_APPROVAL
                               -- | DEPLOYED | ARCHIVED | REJECTED
view_ddl            VARCHAR    -- full CREATE SEMANTIC VIEW DDL
test_score          FLOAT      -- aggregate automated test score
created_by          VARCHAR
approved_by         VARCHAR
created_at          TIMESTAMP
deployed_at         TIMESTAMP
archived_at         TIMESTAMP
notes               VARCHAR
```

### 4.2 `SV_COLUMNS` — Dual-Description Pattern (Human Always Wins)
```sql
view_catalog          VARCHAR
view_schema           VARCHAR
view_name             VARCHAR
version_id            NUMBER
source_table          VARCHAR
column_name           VARCHAR
data_type             VARCHAR
ordinal_position      NUMBER
semantic_role         VARCHAR    -- DIMENSION | FACT | METRIC
ai_description        VARCHAR    -- AI-generated, NEVER overwritten
human_description     VARCHAR    -- NULL until human edits; takes priority
effective_description VARCHAR    -- COMPUTED:
                                 --   COALESCE(human_description, ai_description)
description_source    VARCHAR    -- AI_GENERATED | HUMAN_EDITED
is_time_dimension     BOOLEAN
time_grain            VARCHAR    -- YEAR | MONTH | QUARTER | DAY
last_edited_by        VARCHAR
last_edited_at        TIMESTAMP
```

### 4.3 `SV_RELATIONSHIPS`
```sql
view_catalog        VARCHAR
view_schema         VARCHAR
view_name           VARCHAR
version_id          NUMBER
from_table          VARCHAR
from_column         VARCHAR
to_table            VARCHAR
to_column           VARCHAR
relationship_type   VARCHAR    -- FK | PK
is_inferred         BOOLEAN    -- AI inferred vs human-defined
confidence_score    FLOAT      -- 0.0 - 1.0
```

### 4.4 `SV_TEST_RESULTS`
```sql
test_run_id         NUMBER
view_catalog        VARCHAR
view_schema         VARCHAR
view_name           VARCHAR
version_id          NUMBER
test_type           VARCHAR    -- VERIFIED_QUERY_REGRESSION
                               -- | METRIC_SANITY
                               -- | CORTEX_ANALYST_AB
test_name           VARCHAR
status              VARCHAR    -- PASS | FAIL | WARNING
score               FLOAT
details             VARIANT
run_at              TIMESTAMP
```

### 4.5 `SV_ANALYST_FEEDBACK` — Ongoing Quality Signal
```sql
feedback_id         NUMBER
view_catalog        VARCHAR
view_schema         VARCHAR
view_name           VARCHAR
version_id          NUMBER
query_text          VARCHAR    -- NL question asked
query_id            VARCHAR    -- Snowflake query ID
answered            BOOLEAN    -- did Cortex Analyst answer?
human_score         NUMBER     -- 1 - 5 if human rated
recorded_at         TIMESTAMP
```

### 4.6 `SV_DOMAINS` — Domain Taxonomy (AI Suggested, Human Confirmed)
```sql
domain_id           NUMBER
domain_name         VARCHAR    -- Finance | Sales | Operations | HR ...
parent_domain       VARCHAR    -- for sub-domains
description         VARCHAR
view_catalog        VARCHAR
view_schema         VARCHAR
view_name           VARCHAR
ai_suggested_domain     VARCHAR
ai_confidence_score     FLOAT
human_confirmed_domain  VARCHAR
confirmed_by            VARCHAR
confirmed_at            TIMESTAMP
steward_user            VARCHAR    -- data steward for this domain
steward_role            VARCHAR    -- Snowflake role of the steward
```

### 4.7 `SV_GLOSSARY` — Business Term Standardization
```sql
term                VARCHAR
canonical_definition VARCHAR
domain_id           NUMBER
applies_to_views    ARRAY
conflicting_terms   ARRAY      -- flags same term meaning differently elsewhere
created_by          VARCHAR
last_updated        TIMESTAMP
```

### 4.8 `SV_ACCESS_REQUESTS` — Permission Request Workflow
```sql
request_id              NUMBER
requestor_user          VARCHAR
view_catalog            VARCHAR
view_schema             VARCHAR
view_name               VARCHAR
justification           VARCHAR
sensitivity_level       VARCHAR    -- LOW | MEDIUM | HIGH | PII
status                  VARCHAR    -- PENDING | APPROVED | DENIED | EXPIRED
requested_at            TIMESTAMP
reviewed_by             VARCHAR
reviewed_at             TIMESTAMP
reviewer_notes          VARCHAR
snowflake_grant_executed BOOLEAN   -- TRUE once GRANT is run
```

### 4.9 `SV_USAGE_ANALYTICS` — Consumption Metrics
```sql
view_catalog        VARCHAR
view_schema         VARCHAR
view_name           VARCHAR
version_id          NUMBER
query_date          DATE
query_count         NUMBER
unique_users        NUMBER
answered_count      NUMBER
unanswered_count    NUMBER
avg_human_score     FLOAT
```

---

## 5. End-to-End Semantic View Creation Workflow

```
Step 1  - Describe Tables (parallel)
          DESCRIBE TABLE for each input table
          SHOW PRIMARY KEYS IN TABLE

Step 2  - Generate AI Column Descriptions (parallel)
          CALL AI_GENERATE_TABLE_DESC(table, {use_table_data: false})
          Parse JSON -> extract per-column descriptions

Step 3  - Classify Columns
          Heuristic rules:
          - PK / suffix _key / _id          -> DIMENSION (PK/FK)
          - VARCHAR / CHAR / TEXT / BOOLEAN -> DIMENSION
          - DATE / TIMESTAMP                -> DIMENSION + TIME
          - CHAR(1) status/flag             -> DIMENSION
          - NUMBER with price/amt/cost      -> METRIC (SUM/AVG)
          - NUMBER with qty/quantity/cnt    -> METRIC (SUM)
          - NUMBER as row-level value       -> FACT

Step 4  - Expand Time Dimensions
          For each DATE/TIMESTAMP column:
          -> Generate: raw date, year, month, quarter dimensions

Step 5  - Infer Relationships -> REVIEW GATE
          Cross-match column names across tables
          Present to user for confirmation before proceeding

Step 6  - AI Suggests Domain
          SP_SV_SUGGEST_DOMAINS() -> inserts to SV_DOMAINS (AI_SUGGESTED)
          User confirms or overrides in Streamlit

Step 7  - Generate CREATE SEMANTIC VIEW DDL
          TABLES clause       (with PKs + COMMENTs from AI descriptions)
          RELATIONSHIPS       (hierarchy: CUSTOMER -> ORDERS -> LINEITEM)
          FACTS clause        (row-level numeric values + COMMENTs)
          DIMENSIONS clause   (strings, dates, IDs, time grains + COMMENTs)
          METRICS clause      (aggregatable numerics + COMMENTs)
          AI_VERIFIED_QUERIES (5 pre-generated business questions)
          VIEW-level COMMENT

Step 8  - CI/CD Pipeline (see Section 6)

Step 9  - Populate Catalog
          SV_COLUMNS       <- AI + human descriptions
          SV_RELATIONSHIPS <- confirmed joins
          SV_USAGE_ANALYTICS <- polled via Task
```

---

## 6. CI/CD Pipeline

```
DRAFT
  User edits human_description in SV_COLUMNS
  New version_id created in SV_REGISTRY

     v "Run Tests"

TESTING  (automated, 3 parallel tests)
  - Verified Query Regression  -> all 5 NL questions return results
  - Metric Sanity Checks       -> key metrics non-null, non-zero
  - Semantic Diff              -> show what changed vs DEPLOYED version
  Tests written to SV_TEST_RESULTS

  FAIL -> status = REJECTED (must fix & resubmit)
  PASS -> status = PENDING_APPROVAL
       -> create MY_VIEW_STAGING (does not touch production)

     v "Review"

PENDING_APPROVAL  (human evaluation)
  Streamlit A/B panel:
    Left:  Cortex Analyst answers on DEPLOYED version
    Right: Cortex Analyst answers on STAGING version
  Approver rates each answer 1-5 -> saved to SV_ANALYST_FEEDBACK
  [Approve & Promote] or [Reject]

     v "Approve"

DEPLOYED
  CREATE OR REPLACE SEMANTIC VIEW (from STAGING DDL)
  Previous DEPLOYED -> ARCHIVED (DDL preserved in SV_REGISTRY)
  MY_VIEW_STAGING dropped
  TASK_SV_FEEDBACK_COLLECTOR begins polling QUERY_HISTORY

     v (if needed)

ROLLBACK
  Streamlit version history table
  Select any ARCHIVED version -> one click
  Replays DDL from SV_REGISTRY.view_ddl
  Current -> ARCHIVED, selected -> DEPLOYED
```

---

## 7. Agent Decision Flow

```
User: "What is total revenue by customer segment this quarter?"
  |
  +- Agent: search SV_DOMAINS + SV_REGISTRY
  |         -> matches "Finance" domain -> TPCH_ANALYSIS_VIEW (score: 0.91)
  |
  +- Agent: check_user_entitlement(MY_DB.PUBLIC.TPCH_ANALYSIS_VIEW)
  |         using caller's native Snowflake session (RBAC enforced)
  |
  +- ENTITLED?
  |    YES -> query_semantic_view() -> Cortex Analyst -> return answer
  |          -> record to SV_ANALYST_FEEDBACK
  |
  +- NOT ENTITLED?
       +- Pending request exists?
       |    YES -> "Your request is pending approval by [steward]"
       |
       +- NO request yet
            -> Show: what view contains + sensitivity level
            -> Prompt: "Submit access request? [Justify: _____]"
            -> SP_SV_REQUEST_ACCESS() -> notify steward in Streamlit
            -> "Request submitted to [steward]. Typical SLA: 48h."
```

---

## 8. Agent Tool Suite

| Tool | Description |
|------|-------------|
| `discover_semantic_views(intent_text)` | Semantic search over SV_REGISTRY + SV_DOMAINS + SV_COLUMNS. Returns ranked domain -> view -> confidence. |
| `check_user_entitlement(view_fqn)` | Runs under caller's session. Checks native Snowflake GRANT. Returns ENTITLED \| NOT_ENTITLED \| REQUEST_PENDING. |
| `request_access(view_fqn, justification)` | Inserts SV_ACCESS_REQUESTS. Notifies domain steward via Snowflake notification. |
| `query_semantic_view(view_fqn, nl_question)` | Calls Cortex Analyst with user session context. Records result to SV_ANALYST_FEEDBACK. |

---

## 9. Stored Procedures: `MY_DB.PUBLIC`

| Procedure | Purpose | Phase |
|-----------|---------|-------|
| `SP_SV_DESCRIBE_TABLES(table_list ARRAY)` | DESCRIBE TABLE for each table | 1 (built) |
| `SP_SV_GENERATE_AI_DESCRIPTIONS(table_list ARRAY)` | Calls AI_GENERATE_TABLE_DESC | 1 (built) |
| `SP_SV_CLASSIFY_COLUMNS(metadata, descriptions)` | Heuristic classification + time dim expansion | 1 (built) |
| `SP_SV_GENERATE_DDL(config VARIANT)` | Composes CREATE SEMANTIC VIEW DDL | 1 (built) |
| `SP_SV_CREATE_AND_CATALOG(...)` | Executes DDL + populates catalog | 1 (built) |
| `SP_SV_BUILD_END_TO_END(...)` | Master orchestration of all 5 above | 1 (built) |
| `SP_SV_RUN_TESTS(version_id)` | Executes 3 automated test suites | 2 |
| `SP_SV_PROMOTE_VERSION(version_id, approver)` | Promotes to DEPLOYED | 2 |
| `SP_SV_ROLLBACK_VERSION(version_id)` | Replays archived DDL | 2 |
| `SP_SV_SUGGEST_DOMAINS(view_metadata)` | AI domain inference | 2 |
| `SP_SV_CHECK_ENTITLEMENT(view_fqn)` | RBAC check | 2 |
| `SP_SV_REQUEST_ACCESS(view_fqn, justification)` | Creates access request | 2 |
| `SP_SV_APPROVE_ACCESS(request_id, approver)` | Executes GRANT | 2 |
| `SP_SV_DENY_ACCESS(request_id, approver, reason)` | Updates request to DENIED | 2 |

---

## 10. Snowflake Task

| Task | Purpose | Phase |
|------|---------|-------|
| `TASK_SV_FEEDBACK_COLLECTOR` | Polls QUERY_HISTORY into SV_USAGE_ANALYTICS | 2 |

---

## 11. Streamlit App: `MY_DB.PUBLIC.SEMANTIC_VIEW_BUILDER`

| Tab | Purpose |
|-----|---------|
| **1. Build** | Configure input tables, set hierarchy, set target view name |
| **2. Review & Edit** | Edit column classifications, AI descriptions, relationships, time grain toggles |
| **3. CI/CD Pipeline** | Run tests, view results, A/B comparison panel, approve/reject |
| **4. Domains** | Review AI-suggested domains, confirm/override, assign stewards, manage glossary |
| **5. Access Control** | Steward view: pending requests, approve/deny, current entitlements per view |
| **6. Usage & Health** | Query volume, answer rate trend, test pass rates, stale view alerts |

---

## 12. Complete Object Inventory

| Object | Type | Location | Status |
|--------|------|----------|--------|
| `SEMANTIC_CATALOG` | Schema | `MY_DB` | DEPLOYED |
| `SV_REGISTRY` | Table | `MY_DB.SEMANTIC_CATALOG` | DEPLOYED |
| `SV_COLUMNS` | Table | `MY_DB.SEMANTIC_CATALOG` | DEPLOYED |
| `SV_RELATIONSHIPS` | Table | `MY_DB.SEMANTIC_CATALOG` | DEPLOYED |
| `SV_TEST_RESULTS` | Table | `MY_DB.SEMANTIC_CATALOG` | DEPLOYED |
| `SV_ANALYST_FEEDBACK` | Table | `MY_DB.SEMANTIC_CATALOG` | DEPLOYED |
| `SV_DOMAINS` | Table | `MY_DB.SEMANTIC_CATALOG` | DEPLOYED |
| `SV_GLOSSARY` | Table | `MY_DB.SEMANTIC_CATALOG` | DEPLOYED |
| `SV_ACCESS_REQUESTS` | Table | `MY_DB.SEMANTIC_CATALOG` | DEPLOYED |
| `SV_USAGE_ANALYTICS` | Table | `MY_DB.SEMANTIC_CATALOG` | DEPLOYED |
| `SP_SV_DESCRIBE_TABLES` | Python Stored Proc | `MY_DB.PUBLIC` | DEPLOYED |
| `SP_SV_GENERATE_AI_DESCRIPTIONS` | Python Stored Proc | `MY_DB.PUBLIC` | DEPLOYED |
| `SP_SV_CLASSIFY_COLUMNS` | Python Stored Proc | `MY_DB.PUBLIC` | DEPLOYED |
| `SP_SV_GENERATE_DDL` | Python Stored Proc | `MY_DB.PUBLIC` | DEPLOYED |
| `SP_SV_CREATE_AND_CATALOG` | Python Stored Proc | `MY_DB.PUBLIC` | DEPLOYED |
| `SP_SV_BUILD_END_TO_END` | Python Stored Proc | `MY_DB.PUBLIC` | DEPLOYED |
| `TPCH_ANALYSIS_VIEW` | Semantic View | `MY_DB.PUBLIC` | DEPLOYED |
| `SP_SV_RUN_TESTS` | Python Stored Proc | `MY_DB.PUBLIC` | Phase 2 |
| `SP_SV_PROMOTE_VERSION` | Python Stored Proc | `MY_DB.PUBLIC` | Phase 2 |
| `SP_SV_ROLLBACK_VERSION` | Python Stored Proc | `MY_DB.PUBLIC` | Phase 2 |
| `SP_SV_SUGGEST_DOMAINS` | Python Stored Proc | `MY_DB.PUBLIC` | Phase 2 |
| `SP_SV_CHECK_ENTITLEMENT` | Python Stored Proc | `MY_DB.PUBLIC` | Phase 2 |
| `SP_SV_REQUEST_ACCESS` | Python Stored Proc | `MY_DB.PUBLIC` | Phase 2 |
| `SP_SV_APPROVE_ACCESS` | Python Stored Proc | `MY_DB.PUBLIC` | Phase 2 |
| `SP_SV_DENY_ACCESS` | Python Stored Proc | `MY_DB.PUBLIC` | Phase 2 |
| `TASK_SV_FEEDBACK_COLLECTOR` | Snowflake Task | `MY_DB.PUBLIC` | Phase 2 |
| `SEMANTIC_VIEW_BUILDER` | Streamlit App | `MY_DB.PUBLIC` | Phase 3 |
| Cortex Agent | Agent | `MY_DB.PUBLIC` | Phase 4 |

---

## 13. Deferred (Extensible Design)

| Item | Notes |
|------|-------|
| Multi-account DEV/STAGING/PROD | Schema designed with parameterized DB names |
| External ITSM (ServiceNow/Jira) | `SP_SV_REQUEST_ACCESS` can add a webhook callout |
| Infrastructure as code (DCM) | All objects are SQL-scriptable; IaC wrapper is additive |
| Column-level PII masking | Snowflake masking policies can be layered on semantic view columns |
| Business glossary conflict resolution AI | `SV_GLOSSARY.conflicting_terms` captures conflicts; resolution UI is a later tab |
| External API contract | REST UDF wrapper around stored procs enables external tool integration |

---

## 14. Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| AI description mode | Metadata-only (`use_table_data: false`) | Avoids data exposure, lower cost |
| Human vs AI descriptions | Both stored; human wins via COALESCE | Enables RLHF-style iterative improvement |
| Agent identity | User context (caller's session) | Native RBAC enforcement; zero-trust by default |
| Domain taxonomy | AI suggests, human confirms | Balance automation with governance accuracy |
| Permission workflow | In-platform (catalog + Streamlit) | No external tooling dependency for Phase 1 |
| Environment model | Single account, extensible schema design | Pragmatic for Phase 1; DB name parameterized |
| Rollback | Full version archive in SV_REGISTRY | Any version replayable from stored DDL |
| Test gate | 3 automated + 1 human A/B | Automated catches regressions; human eval catches quality |

---

## 15. Phase 1 Validation Results

| Check | Result |
|-------|--------|
| Catalog schema + 9 tables created | PASS |
| 5 core stored procs + 1 orchestrator created | PASS |
| End-to-end pipeline ran on TPC-H 3 tables | PASS |
| `TPCH_ANALYSIS_VIEW` created with 33 columns, 2 relationships | PASS |
| Cross-table query (revenue by segment) | PASS - 5 rows |
| 3-table join query (price + qty by segment + year) | PASS - 20 rows |
| Catalog populated for new view | PASS - 1 registry, 33 columns, 2 relationships |

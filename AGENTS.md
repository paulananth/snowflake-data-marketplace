# AGENTS.md

Reference document preserving the **Cortex Agent** and **Streamlit App** configurations for the Agentic Data Marketplace. Source of truth if any object needs to be redeployed.

This file covers:
- Cortex Agent `SEMANTIC_MARKETPLACE_AGENT` (Section 1)
- Streamlit app `SEMANTIC_VIEW_BUILDER` (Section 2)
- Streamlit app `SEMANTIC_VIEW_EXPLORER` (Section 3)
- Deployment utility `SP_WRITE_STAGE_FILE` (Section 4)

---

## 1. Cortex Agent: `MY_DB.PUBLIC.SEMANTIC_MARKETPLACE_AGENT`

### Purpose

Front door for the data marketplace. Routes natural-language questions to the right semantic view, enforces native Snowflake RBAC, and orchestrates a permission-request workflow when the user is not entitled.

### Profile

| Attribute | Value |
|---|---|
| Display name | Data Marketplace Agent |
| Color | blue |
| Owner | ACCOUNTADMIN |
| Orchestration model | `auto` (Snowflake-managed) |
| Default version | `VERSION$1` |

---

## Tools (4)

### Tool 1 — `discover_semantic_views`

| Property | Value |
|---|---|
| Type | `generic` (custom procedure) |
| Backing object | `MY_DB.PUBLIC.SP_SV_DISCOVER(VARCHAR)` |
| Warehouse | `COMPUTE_WH` |
| Timeout | 60s |

**Input schema**
```json
{
  "type": "object",
  "properties": {
    "intent_text": {
      "type": "string",
      "description": "The user's natural-language question or topic of interest."
    }
  },
  "required": ["intent_text"]
}
```

**Output (example)**
```json
{
  "query": "revenue by customer segment",
  "matches": [
    {
      "view_fqn": "MY_DB.PUBLIC.TPCH_ANALYSIS_VIEW",
      "domain": "Supply Chain",
      "view_comment": "TPC-H semantic view: customer-orders-lineitem hierarchy...",
      "match_score": 3,
      "matched_tokens": ["revenue", "customer", "segment"]
    }
  ]
}
```

---

### Tool 2 — `check_entitlement`

| Property | Value |
|---|---|
| Type | `generic` (custom procedure) |
| Backing object | `MY_DB.PUBLIC.SP_SV_CHECK_ENTITLEMENT(VARCHAR)` |
| Execution context | `EXECUTE AS CALLER` (critical for RBAC) |

**Input schema**
```json
{
  "type": "object",
  "properties": {
    "view_fqn": {
      "type": "string",
      "description": "Fully qualified semantic view name in the form DB.SCHEMA.NAME."
    }
  },
  "required": ["view_fqn"]
}
```

**Output**
```json
{
  "status": "ENTITLED | NOT_ENTITLED | REQUEST_PENDING | ERROR",
  "user": "<current_user>",
  "view": "<view_fqn>",
  "roles_granted": ["ROLE_NAME", ...],
  "user_roles_count": 9
}
```

---

### Tool 3 — `request_access`

| Property | Value |
|---|---|
| Type | `generic` (custom procedure) |
| Backing object | `MY_DB.PUBLIC.SP_SV_REQUEST_ACCESS(VARCHAR, VARCHAR, VARCHAR)` |

**Input schema**
```json
{
  "type": "object",
  "properties": {
    "view_fqn":          {"type": "string"},
    "justification":     {"type": "string", "description": "One-sentence business justification."},
    "sensitivity_level": {"type": "string", "description": "LOW | MEDIUM | HIGH | PII"}
  },
  "required": ["view_fqn", "justification"]
}
```

**Output**
```json
{
  "status": "PENDING | ALREADY_PENDING",
  "request_id": 1,
  "requestor": "<user>",
  "view": "<view_fqn>",
  "steward": "<steward_user_or_unassigned>",
  "message": "Access request submitted. Steward: <name> will review."
}
```

---

### Tool 4 — `tpch_analyst`

| Property | Value |
|---|---|
| Type | `cortex_analyst_text_to_sql` |
| Bound semantic view | `MY_DB.PUBLIC.TPCH_ANALYSIS_VIEW` |

The agent passes the user's NL question to this tool only when `check_entitlement` returns `ENTITLED`. Cortex Analyst performs NL → SQL using the semantic view's metrics, dimensions, and verified queries.

---

## Orchestration Logic (System Prompt)

```
You are the Data Marketplace Agent. Your job is to help users get answers
from semantic views in this Snowflake account while enforcing native RBAC
entitlements.

CRITICAL ORCHESTRATION RULES:
1. For EVERY user question, FIRST call discover_semantic_views with the
   user's intent text. Pick the highest-scoring match.
2. THEN call check_entitlement with the matched view_fqn. NEVER skip this.
3. If status is ENTITLED: use the tpch_analyst tool (Cortex Analyst) to
   answer the question against the matched view.
4. If status is NOT_ENTITLED: do NOT attempt to answer. Tell the user the
   view they need access to, ask for a one-sentence justification, then
   call request_access. After the request, tell them the request_id and
   that the steward will review.
5. If status is REQUEST_PENDING: tell the user their access request is
   already pending review.
6. ALWAYS quote the view_fqn and domain so the user knows what data is
   being used.
```

### Tool Selection (Orchestration Hint)

```
- discover_semantic_views: ALWAYS first, with raw question as intent_text
- check_entitlement:       ALWAYS second, with view_fqn from discover
- tpch_analyst:            ONLY if check_entitlement returns ENTITLED
- request_access:          ONLY if check_entitlement returns NOT_ENTITLED
```

### Response Style

```
Be concise and business-friendly. Always disclose the semantic view you
used. If access was denied, never reveal data values - only describe the
view's purpose at a high level.
```

---

## Sample Onboarding Questions

| Question | Expected Path |
|---|---|
| "What is total revenue by customer segment?" | discover → ENTITLED → tpch_analyst → answer |
| "Show me the top 10 customers by order value" | discover → ENTITLED → tpch_analyst → answer |

---

## Invocation

### From SQL (requires Cortex inference)

```sql
SELECT TRY_PARSE_JSON(
  SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
    'MY_DB.PUBLIC.SEMANTIC_MARKETPLACE_AGENT',
    $${
      "messages":[
        {"role":"user","content":[
          {"type":"text","text":"What is total revenue by customer segment?"}
        ]}
      ],
      "stream": false
    }$$
  )
):content AS reasoning_trail;
```

### From Snowflake Intelligence UI

`Snowsight > AI & ML > Snowflake Intelligence > Data Marketplace Agent`

### From REST

```
POST https://<account>.snowflakecomputing.com/api/v2/cortex/agents:run
Authorization: Bearer <PAT or session token>
Content-Type: application/json
{
  "agent_name": "MY_DB.PUBLIC.SEMANTIC_MARKETPLACE_AGENT",
  "messages": [...],
  "stream": false
}
```

---

## Redeployment

Full agent DDL is in `deploy_phase4.sql`. To redeploy:

```sql
DROP AGENT IF EXISTS MY_DB.PUBLIC.SEMANTIC_MARKETPLACE_AGENT;
-- Then run deploy_phase4.sql
```

---

## 2. Streamlit App: `MY_DB.PUBLIC.SEMANTIC_VIEW_BUILDER`

| Attribute | Value |
|---|---|
| Stage | `@MY_DB.PUBLIC.STREAMLIT_STAGE` |
| Main file | `streamlit_app.py` (workspace copy: `/streamlit_app.py`) |
| Warehouse | `COMPUTE_WH` |
| URL ID | `5lhryu6jjn2tk2i5uwfm` |
| Title | Semantic View Builder |
| Purpose | Governance / lifecycle / catalog management |

### Tabs

1. **Build** — Configure tables, hierarchy, target view name; runs `SP_SV_BUILD_END_TO_END`
2. **Review** — Edit column classifications, AI/human descriptions
3. **CI/CD** — Version history, view DDL inspection
4. **Domains** — AI-suggested domain confirmation, steward assignment
5. **Access Control** — Pending access-request review (steward view) + entitlement check
6. **Usage & Health** — Daily query volume, catalog health snapshot

### Compatibility note

This Streamlit-in-Snowflake runtime is **older than 1.23**, so `st.data_editor` is **not** available. Use `st.dataframe` + `selectbox` + `text_area` + Save button pattern instead.

### Redeployment

```sql
CALL MY_DB.PUBLIC.SP_WRITE_STAGE_FILE(
  '@MY_DB.PUBLIC.STREAMLIT_STAGE',
  'streamlit_app.py',
  $$ <full file content> $$
);
-- Streamlit object picks up the new file on next page load.
```

---

## 3. Streamlit App: `MY_DB.PUBLIC.SEMANTIC_VIEW_EXPLORER`

| Attribute | Value |
|---|---|
| Stage | `@MY_DB.PUBLIC.SV_EXPLORER_STAGE` |
| Main file | `streamlit_app.py` (workspace copy: `/streamlit_app_explorer.py`) |
| Warehouse | `COMPUTE_WH` |
| URL ID | `52enuzlvpgh22zuj6l6y` |
| Title | Semantic View Explorer |
| Purpose | Cortex Analyst NL Q&A + interactive query builder |

### Sections

1. **Sidebar** — Pick any deployed semantic view from `SV_REGISTRY`
2. **Entitlement gate** — Calls `SP_SV_CHECK_ENTITLEMENT`; non-entitled users see status only
3. **Ask a Question** (Cortex Analyst) — Free-form NL input + 5 numbered example buttons:
   - "What is the total revenue by customer market segment?"
   - "Who are the top 10 customers by total order value?"
   - "What is the monthly trend of line item revenue?"
   - "How does total order value compare across order priorities?"
   - "What is total quantity shipped by ship mode and year?"
4. **Schema details** — Dimensions / metrics / facts / source tables count + drill-down
5. **Query Builder** — Multi-select dim/metric, WHERE, ORDER BY, LIMIT; auto bar/line/area chart for 1-dim+1-metric results

### Cortex Analyst integration (Section 3)

```python
def call_cortex_analyst(question, semantic_view_fqn):
    conn = session._connection
    host = conn.host
    token = conn.rest.token
    body = {
        "messages": [{"role":"user","content":[{"type":"text","text": question}]}],
        "semantic_view": semantic_view_fqn,
        "stream": False
    }
    return requests.post(
        f"https://{host}/api/v2/cortex/analyst/message",
        headers={"Authorization": f'Snowflake Token=\"{token}\"',
                 "Content-Type":"application/json","Accept":"application/json"},
        json=body, timeout=60
    )
```

- **No EAI required** — calls to the same account's host are intra-tenant
- **Trial accounts:** REST returns `Access denied for trial accounts (399504)`. App shows a clean banner; query builder still works.
- **All questions** (success or failure) are logged to `SV_ANALYST_FEEDBACK` for the RLHF feedback loop

### Critical fix

All `to_pandas()` results MUST have columns uppercased. The shared `df()` helper does this:

```python
def df(sql, params=None):
    rows = session.sql(sql, params=params).collect() if params else session.sql(sql).collect()
    pdf = pd.DataFrame([r.as_dict() for r in rows])
    pdf.columns = [str(c).upper() for c in pdf.columns]
    return pdf
```

Without this, `DESCRIBE SEMANTIC VIEW` results have lowercase column names and attribute access fails.

### Redeployment

```sql
CALL MY_DB.PUBLIC.SP_WRITE_STAGE_FILE(
  '@MY_DB.PUBLIC.SV_EXPLORER_STAGE',
  'streamlit_app.py',
  $$ <full file content> $$
);
```

---

## 4. Utility: `MY_DB.PUBLIC.SP_WRITE_STAGE_FILE`

Generic file-push helper used to deploy/update Streamlit app content from SQL without an External Access Integration.

```sql
CREATE OR REPLACE PROCEDURE MY_DB.PUBLIC.SP_WRITE_STAGE_FILE(
  stage_path VARCHAR, file_name VARCHAR, content STRING
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
EXECUTE AS CALLER
AS
$$
import io
def main(session, stage_path, file_name, content):
    bio = io.BytesIO(content.encode('utf-8'))
    session.file.put_stream(bio, f"{stage_path}/{file_name}",
                            auto_compress=False, overwrite=True)
    return f"Wrote {file_name} ({len(content)} bytes) to {stage_path}"
$$;
```

Usage:
```sql
CALL MY_DB.PUBLIC.SP_WRITE_STAGE_FILE(
  '@MY_DB.PUBLIC.SV_EXPLORER_STAGE',
  'streamlit_app.py',
  $$<file content>$$
);
```

---

## Future Agents (Roadmap)

These are not yet built but the catalog is designed to support them:

| Agent | Purpose |
|---|---|
| `STEWARD_AGENT` | For data stewards: triage pending access requests, suggest grant decisions, summarize usage trends per domain |
| `BUILDER_AGENT` | For data engineers: take a NL description like "build me a sales pipeline view" and orchestrate `SP_SV_BUILD_END_TO_END` |
| `QUALITY_AGENT` | For governance: monitor `SV_ANALYST_FEEDBACK`, surface views with low answer rates, recommend description edits |

Each would reuse the same catalog but expose a different tool set tailored to the persona.

---

## Security & RBAC Notes

- All entitlement procs use `EXECUTE AS CALLER` so RBAC is enforced under the agent invoker's session, not the agent owner.
- `SP_SV_APPROVE_ACCESS` requires the approver to have grant authority on the target view; if the GRANT fails, the request stays PENDING with the error captured in `reviewer_notes`.
- `SHOW GRANTS ON SEMANTIC VIEW` is the source of truth for entitlement; if the view is dropped, the agent surfaces an ERROR rather than auto-creating one.
- Agent reasoning trails (full tool-use sequence) are returned to the caller — this is the audit record. Capture them in `SV_ANALYST_FEEDBACK` for compliance retention.

---

## Versioning Policy

- Agent objects in Snowflake auto-version on every `CREATE OR REPLACE`. The previous version is retained in `versions` and addressable via alias.
- After a successful redeploy, set `LAST` alias to the new version (default behavior).
- For rollback: `ALTER AGENT ... SET DEFAULT_VERSION = 'VERSION$N'`.

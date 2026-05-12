# Agentic Data Marketplace - Deployment Guide

Deploy the full Agentic Data Marketplace to any Snowflake account.

---

## Prerequisites

| Requirement | Details |
|---|---|
| Snowflake Edition | **Standard or Enterprise** (trial accounts cannot invoke Cortex Agent) |
| Role | `SYSADMIN` (see Privilege Setup below for required grants from ACCOUNTADMIN) |
| Cortex LLM access | Region must support `mistral-large2` for AI descriptions |
| Cortex Agent | Region must support Snowflake Agents (check [availability docs](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-agent)) |

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    CORTEX AGENT                                  │
│         SEMANTIC_MARKETPLACE_AGENT                               │
│  ┌──────────────┐ ┌────────────────┐ ┌──────────────────────┐  │
│  │ discover_    │ │ check_         │ │ agmp_analyst         │  │
│  │ semantic_    │ │ entitlement    │ │ (Cortex Analyst)     │  │
│  │ views        │ │                │ │                      │  │
│  └──────────────┘ └────────────────┘ └──────────────────────┘  │
│  ┌──────────────┐                                               │
│  │ request_     │                                               │
│  │ access       │                                               │
│  └──────────────┘                                               │
└─────────────────────────────────────────────────────────────────┘
           │                    │
           ▼                    ▼
┌───────────────────┐  ┌───────────────────────┐
│ <DB_NAME>.PUBLIC    │  │ <DB_NAME>.SEMANTIC_CATALOG │
│                   │  │                       │
│ • SP_AGMP_*  procs  │  │ • AGMP_REGISTRY         │
│ • Semantic Views  │  │ • AGMP_COLUMNS          │
│ • Streamlit Apps  │  │ • AGMP_RELATIONSHIPS    │
│                   │  │ • AGMP_DOMAINS          │
│                   │  │ • AGMP_ACCESS_REQUESTS  │
│                   │  │ • AGMP_USAGE_ANALYTICS  │
│                   │  │ • AGMP_ANALYST_FEEDBACK │
│                   │  │ • AGMP_TEST_RESULTS     │
│                   │  │ • AGMP_GLOSSARY         │
└───────────────────┘  └───────────────────────┘
```

---

## Privilege Setup (ACCOUNTADMIN — one-time)

Before SYSADMIN can deploy, an ACCOUNTADMIN must run this **once**:

```sql
-- Run as ACCOUNTADMIN
USE ROLE ACCOUNTADMIN;

-- Allow SYSADMIN to create the database and warehouse
GRANT CREATE DATABASE ON ACCOUNT TO ROLE SYSADMIN;
GRANT CREATE WAREHOUSE ON ACCOUNT TO ROLE SYSADMIN;

-- Create the database first (SYSADMIN will own it)
CREATE DATABASE IF NOT EXISTS <YOUR_DB>;
GRANT OWNERSHIP ON DATABASE <YOUR_DB> TO ROLE SYSADMIN COPY CURRENT GRANTS;

-- Grant agent and semantic view creation privileges
GRANT CREATE AGENT ON SCHEMA <YOUR_DB>.PUBLIC TO ROLE SYSADMIN;
GRANT CREATE SEMANTIC VIEW ON SCHEMA <YOUR_DB>.PUBLIC TO ROLE SYSADMIN;
GRANT CREATE STREAMLIT ON SCHEMA <YOUR_DB>.PUBLIC TO ROLE SYSADMIN;
GRANT CREATE STAGE ON SCHEMA <YOUR_DB>.PUBLIC TO ROLE SYSADMIN;
GRANT CREATE PROCEDURE ON SCHEMA <YOUR_DB>.PUBLIC TO ROLE SYSADMIN;
GRANT CREATE TABLE ON SCHEMA <YOUR_DB>.SEMANTIC_CATALOG TO ROLE SYSADMIN;

-- Grant Cortex LLM access (required for AI descriptions)
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE SYSADMIN;
```

---

## Deployment Steps

### Step 1: Configure Variables

Open `deploy_all.sql` and update the top configuration section:

```sql
SET DB_NAME     = 'AGMP_DB';        -- <<< CHANGE THIS to your target database name
SET WH_NAME     = 'COMPUTE_WH';    -- Change to your target warehouse
SET DEPLOY_ROLE = 'SYSADMIN';      -- SYSADMIN can deploy with proper grants
```

### Step 2: Run the Main Deployment Script

Execute `deploy_all.sql` in a SQL worksheet (or via SnowSQL/CLI):

```bash
# Via SnowSQL
snowsql -a <account> -u <user> -r SYSADMIN -f deploy_all.sql

# Via Snowflake CLI
snow sql -f deploy_all.sql --connection <connection_name>
```

This creates:
- Database + schemas
- 9 catalog tables
- 14 stored procedures
- 2 internal stages
- 2 Streamlit apps (shell - code uploaded next)
- 1 Cortex Agent

### Step 3: Upload Streamlit App Code

Upload the two Streamlit files to their respective stages:

```sql
-- Builder app
CALL MY_DB.PUBLIC.SP_WRITE_STAGE_FILE(
  '@MY_DB.PUBLIC.STREAMLIT_STAGE',
  'streamlit_app.py',
  $$<paste contents of streamlit_app.py>$$
);

-- Explorer app
CALL MY_DB.PUBLIC.SP_WRITE_STAGE_FILE(
  '@MY_DB.PUBLIC.AGMP_EXPLORER_STAGE',
  'streamlit_app.py',
  $$<paste contents of streamlit_app_explorer.py>$$
);
```

> **Tip:** If you have the files locally, you can use `PUT` via SnowSQL instead:
> ```bash
> PUT file://streamlit_app.py @MY_DB.PUBLIC.STREAMLIT_STAGE AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
> PUT file://streamlit_app_explorer.py @MY_DB.PUBLIC.AGMP_EXPLORER_STAGE/streamlit_app.py AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
> ```

### Step 4: Build Your First Semantic View (AGMP)

Build a semantic view named `AGMP` from your source tables:

```sql
CALL <YOUR_DB>.PUBLIC.SP_AGMP_BUILD_END_TO_END(
  ARRAY_CONSTRUCT(
    'YOUR_DB.YOUR_SCHEMA.TABLE1',
    'YOUR_DB.YOUR_SCHEMA.TABLE2'
  ),
  ARRAY_CONSTRUCT(
    'YOUR_DB.YOUR_SCHEMA.TABLE1',
    'YOUR_DB.YOUR_SCHEMA.TABLE2'
  ),
  '<YOUR_DB>.PUBLIC.AGMP',
  'Agentic Data Marketplace semantic view for your domain'
);
```

### Step 5: Verify Deployment

```sql
-- Check entitlement works
CALL SP_AGMP_CHECK_ENTITLEMENT('<YOUR_DB>.PUBLIC.AGMP');
-- Expected: {"status": "ENTITLED", ...}

-- Check discovery works
CALL SP_AGMP_DISCOVER('your search terms here');
-- Expected: matches with AGMP

-- Check agent exists
SHOW AGENTS IN SCHEMA <YOUR_DB>.PUBLIC;

-- Check Streamlit apps
SHOW STREAMLITS IN SCHEMA <YOUR_DB>.PUBLIC;

-- Test agent (non-trial accounts only)
SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
  '<YOUR_DB>.PUBLIC.SEMANTIC_MARKETPLACE_AGENT',
  '{"messages":[{"role":"user","content":[{"type":"text","text":"Show me data from AGMP"}]}],"stream":false}'
);
```

### Step 6: Access the UIs

| App | Navigation |
|---|---|
| Semantic View Builder | Snowsight > Streamlit > `AGMP_BUILDER` |
| Semantic View Explorer | Snowsight > Streamlit > `AGMP_EXPLORER` |
| Cortex Agent | Snowsight > AI & ML > Snowflake Intelligence > `Data Marketplace Agent` |

---

## Customization for Your Account

### Changing the Database Name

Simply set `DB_NAME` at the top of `deploy_all.sql` to any name you want. All procedures resolve the database dynamically at runtime via `CURRENT_DATABASE()`, and the agent DDL is built dynamically using the variable. No find & replace needed.

```sql
SET DB_NAME = 'MY_ANALYTICS_DB';  -- Your choice
```

**Important:** The Streamlit Python files (`streamlit_app.py`, `streamlit_app_explorer.py`) also use `CURRENT_DATABASE()` at runtime, so they adapt automatically.

### Changing the Warehouse

Replace `COMPUTE_WH` in:
- `deploy_all.sql` variable `$WH_NAME`
- Agent tool specs (`warehouse` field)
- Streamlit `QUERY_WAREHOUSE` clause

### Adding Your Own Semantic Views

After deployment, use the Builder app (Tab 1) or call directly:
```sql
CALL MY_DB.PUBLIC.SP_AGMP_BUILD_END_TO_END(
  ARRAY_CONSTRUCT('DB.SCHEMA.TABLE1', 'DB.SCHEMA.TABLE2'),
  ARRAY_CONSTRUCT('DB.SCHEMA.TABLE1', 'DB.SCHEMA.TABLE2'),  -- hierarchy order
  '<YOUR_DB>.PUBLIC.AGMP_NEW_VIEW',
  'Description of your semantic view'
);
```

### Adding the New View to the Agent

After creating a new semantic view, add it as an additional Cortex Analyst tool:
```sql
ALTER AGENT MY_DB.PUBLIC.SEMANTIC_MARKETPLACE_AGENT
  ADD TOOL my_new_analyst = {
    'type': 'cortex_analyst_text_to_sql',
    'spec': { 'semantic_view': 'MY_DB.PUBLIC.MY_NEW_VIEW' }
  };
```

---

## Granting Access to Users

```sql
-- Grant Streamlit app access
GRANT USAGE ON DATABASE <YOUR_DB> TO ROLE <user_role>;
GRANT USAGE ON SCHEMA <YOUR_DB>.PUBLIC TO ROLE <user_role>;
GRANT USAGE ON SCHEMA <YOUR_DB>.SEMANTIC_CATALOG TO ROLE <user_role>;
GRANT SELECT ON ALL TABLES IN SCHEMA <YOUR_DB>.SEMANTIC_CATALOG TO ROLE <user_role>;
GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE <user_role>;

-- Grant Streamlit usage
GRANT USAGE ON STREAMLIT <YOUR_DB>.PUBLIC.AGMP_BUILDER TO ROLE <user_role>;
GRANT USAGE ON STREAMLIT <YOUR_DB>.PUBLIC.AGMP_EXPLORER TO ROLE <user_role>;

-- Grant semantic view access (enables Cortex Analyst)
GRANT SELECT ON SEMANTIC VIEW <YOUR_DB>.PUBLIC.AGMP TO ROLE <user_role>;

-- Grant procedure execution (for builder/explorer functionality)
GRANT USAGE ON PROCEDURE <YOUR_DB>.PUBLIC.SP_AGMP_CHECK_ENTITLEMENT(VARCHAR) TO ROLE <user_role>;
GRANT USAGE ON PROCEDURE <YOUR_DB>.PUBLIC.SP_AGMP_DISCOVER(VARCHAR) TO ROLE <user_role>;
GRANT USAGE ON PROCEDURE <YOUR_DB>.PUBLIC.SP_AGMP_REQUEST_ACCESS(VARCHAR, VARCHAR, VARCHAR) TO ROLE <user_role>;
```

---

## Troubleshooting

| Issue | Cause | Fix |
|---|---|---|
| `399504 - Access denied for trial accounts` | Trial account limitation | Upgrade to Standard/Enterprise edition |
| Agent returns empty | No matching views in catalog | Run Step 4 to build your AGMP semantic view |
| Streamlit shows blank | Stage file missing | Re-run Step 3 to upload app code |
| `SP_AGMP_BUILD_END_TO_END` errors | Source tables not accessible | Verify GRANT SELECT on source tables to deploy role |
| Cortex COMPLETE fails | LLM not available in region | Check [Cortex LLM availability](https://docs.snowflake.com/en/user-guide/snowflake-cortex/llm-functions#availability) |
| `SHOW GRANTS ON SEMANTIC VIEW` fails | View not created yet | Run the build procedure first |

---

## File Inventory

| File | Purpose |
|---|---|
| `deploy_all.sql` | Single-script full deployment (run this) |
| `streamlit_app.py` | Builder UI code (upload to STREAMLIT_STAGE) |
| `streamlit_app_explorer.py` | Explorer UI code (upload to AGMP_EXPLORER_STAGE) |
| `AGENTS.md` | Architecture reference & agent config documentation |
| `DEPLOYMENT_GUIDE.md` | This file |

---

## Rollback

```sql
-- Remove everything
DROP AGENT IF EXISTS <YOUR_DB>.PUBLIC.SEMANTIC_MARKETPLACE_AGENT;
DROP STREAMLIT IF EXISTS <YOUR_DB>.PUBLIC.AGMP_BUILDER;
DROP STREAMLIT IF EXISTS <YOUR_DB>.PUBLIC.AGMP_EXPLORER;
DROP DATABASE IF EXISTS <YOUR_DB>;  -- WARNING: destroys all data
```

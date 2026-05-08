-- =============================================================================
-- Agentic Data Marketplace - GitHub Integration (Snowflake -> GitHub one-way)
-- =============================================================================
-- Allows Snowflake to fetch the deployment scripts directly from the public
-- GitHub repo. Useful for:
--   - EXECUTE IMMEDIATE FROM @repo/branches/main/deploy_foundation.sql
--   - Streamlit ROOT_LOCATION pointing at the repo for live deploys
--   - dbt project sync via SHOW GIT BRANCHES
--
-- Trial account note:
--   - This pull-side integration WORKS on trial accounts.
--   - The push-side (EXTERNAL ACCESS INTEGRATION + Python proc) is BLOCKED
--     on trial accounts. Use the GitHub Web UI for file uploads.
-- =============================================================================

-- 1. API integration scoped to the user's GitHub org/account
CREATE OR REPLACE API INTEGRATION GITHUB_PUBLIC_API
  API_PROVIDER = GIT_HTTPS_API
  API_ALLOWED_PREFIXES = ('https://github.com/paulananth/')
  ENABLED = TRUE
  COMMENT = 'Read-only access to paulananth/* GitHub repos';

-- 2. Snowflake-side Git Repository handle
CREATE OR REPLACE GIT REPOSITORY MY_DB.PUBLIC.MARKETPLACE_REPO
  API_INTEGRATION = GITHUB_PUBLIC_API
  ORIGIN = 'https://github.com/paulananth/snowflake-data-marketplace.git'
  COMMENT = 'Source-of-truth for the Agentic Data Marketplace platform';

-- 3. Pull latest commits + list contents
ALTER GIT REPOSITORY MY_DB.PUBLIC.MARKETPLACE_REPO FETCH;
SHOW GIT BRANCHES IN MY_DB.PUBLIC.MARKETPLACE_REPO;
LS @MY_DB.PUBLIC.MARKETPLACE_REPO/branches/main/;

-- =============================================================================
-- USAGE EXAMPLES
-- =============================================================================
-- Re-deploy a phase straight from GitHub:
--   EXECUTE IMMEDIATE FROM @MY_DB.PUBLIC.MARKETPLACE_REPO/branches/main/deploy_foundation.sql;
--
-- Read a file's content:
--   SELECT $1 FROM @MY_DB.PUBLIC.MARKETPLACE_REPO/branches/main/README.md (FILE_FORMAT => 'TEXT');
--
-- Refresh after a new commit on GitHub:
--   ALTER GIT REPOSITORY MY_DB.PUBLIC.MARKETPLACE_REPO FETCH;
-- =============================================================================

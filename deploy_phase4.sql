-- =============================================================================
-- Agentic Data Marketplace - Phase 4: Cortex Agent
-- Run AFTER deploy_foundation.sql and deploy_phase2_phase3.sql
-- =============================================================================
-- Adds:
--   1. SP_SV_DISCOVER       - keyword search over the SV catalog tables
--   2. SEMANTIC_MARKETPLACE_AGENT - 4-tool Cortex Agent
--
-- Note: DATA_AGENT_RUN requires Cortex inference. On trial accounts,
-- the agent object is created successfully but cannot be invoked at runtime.
-- The agent is callable from Snowflake Intelligence UI on enabled accounts.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 4.1 SP_SV_DISCOVER
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE MY_DB.PUBLIC.SP_SV_DISCOVER(intent_text VARCHAR)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
EXECUTE AS CALLER
AS
$$
def main(session, intent_text):
    if not intent_text:
        return {'matches': [], 'reason': 'empty intent_text'}
    text = (intent_text or '').lower()
    tokens = [t for t in text.replace(',', ' ').replace('?', ' ').split() if len(t) > 2]
    if not tokens:
        return {'matches': []}
    rows = session.sql(
        "WITH base AS ("
        "  SELECT r.view_catalog||'.'||r.view_schema||'.'||r.view_name AS view_fqn, "
        "         r.notes AS view_comment, "
        "         d.human_confirmed_domain AS domain, d.ai_suggested_domain, d.ai_confidence_score, "
        "         LISTAGG(c.column_name||' '||COALESCE(c.ai_description,''),' ') WITHIN GROUP (ORDER BY c.ordinal_position) AS column_text "
        "  FROM MY_DB.SEMANTIC_CATALOG.SV_REGISTRY r "
        "  LEFT JOIN MY_DB.SEMANTIC_CATALOG.SV_DOMAINS d "
        "    ON r.view_catalog=d.view_catalog AND r.view_schema=d.view_schema AND r.view_name=d.view_name "
        "  LEFT JOIN MY_DB.SEMANTIC_CATALOG.SV_COLUMNS c "
        "    ON r.view_catalog=c.view_catalog AND r.view_schema=c.view_schema AND r.view_name=c.view_name "
        "       AND c.version_id=r.version_id "
        "  WHERE r.status='DEPLOYED' "
        "  GROUP BY 1,2,3,4,5"
        ") SELECT * FROM base").collect()
    results = []
    for r in rows:
        d = r.as_dict()
        haystack = ((d.get('VIEW_FQN') or '') + ' ' + (d.get('VIEW_COMMENT') or '') + ' '
                    + (d.get('DOMAIN') or '') + ' ' + (d.get('AI_SUGGESTED_DOMAIN') or '') + ' '
                    + (d.get('COLUMN_TEXT') or '')).lower()
        score = sum(1 for t in tokens if t in haystack)
        if score > 0:
            results.append({
                'view_fqn': d.get('VIEW_FQN'),
                'domain': d.get('DOMAIN') or d.get('AI_SUGGESTED_DOMAIN'),
                'view_comment': d.get('VIEW_COMMENT'),
                'match_score': score,
                'matched_tokens': [t for t in tokens if t in haystack][:6]
            })
    results.sort(key=lambda x: -x['match_score'])
    return {'query': intent_text, 'matches': results[:5]}
$$;

-- -----------------------------------------------------------------------------
-- 4.2 SEMANTIC_MARKETPLACE_AGENT
-- -----------------------------------------------------------------------------
CREATE OR REPLACE AGENT MY_DB.PUBLIC.SEMANTIC_MARKETPLACE_AGENT
  COMMENT = 'Agentic Data Marketplace - discovers semantic views, enforces entitlement, requests access on behalf of unauthorized users'
  PROFILE = '{"display_name": "Data Marketplace Agent", "color": "blue"}'
  FROM SPECIFICATION
$$
models:
  orchestration: auto

instructions:
  system: |
    You are the Data Marketplace Agent. Your job is to help users get answers from semantic views in this Snowflake account while enforcing native RBAC entitlements.

    CRITICAL ORCHESTRATION RULES:
    1. For EVERY user question, FIRST call discover_semantic_views with the user's intent text. Pick the highest-scoring match.
    2. THEN call check_entitlement with the matched view_fqn. NEVER skip this step.
    3. If status is ENTITLED: use the tpch_analyst tool (Cortex Analyst) to answer the question against the matched view.
    4. If status is NOT_ENTITLED: do NOT attempt to answer the question. Instead, tell the user the view they need access to, then ask them for a one-sentence justification, and call request_access with their justification. After the request, tell them the request_id and that the steward will review.
    5. If status is REQUEST_PENDING: tell the user their access request is already pending review.
    6. ALWAYS quote the view_fqn and domain so the user knows what data is being used.

  response: |
    Be concise and business-friendly. Always disclose the semantic view you used. If access was denied, never reveal data values - only describe the view's purpose at a high level.

  orchestration: |
    Tool selection logic:
    - discover_semantic_views: ALWAYS first, with the raw user question as intent_text
    - check_entitlement: ALWAYS second, with the view_fqn from discover
    - tpch_analyst: ONLY if check_entitlement returns ENTITLED
    - request_access: ONLY if check_entitlement returns NOT_ENTITLED

  sample_questions:
    - question: "What is total revenue by customer segment?"
      answer: "I will discover the right view, verify your access, and answer using Cortex Analyst."
    - question: "Show me the top 10 customers by order value"
      answer: "Let me find the right semantic view and check your entitlement first."

tools:
  - tool_spec:
      type: "generic"
      name: "discover_semantic_views"
      description: "Searches the semantic view catalog (SV_REGISTRY + SV_DOMAINS + SV_COLUMNS) for views matching the user intent. Always call this FIRST. Returns a ranked list of view_fqn matches with domain and match_score."
      input_schema:
        type: "object"
        properties:
          intent_text:
            type: "string"
            description: "The user's natural-language question or topic of interest."
        required:
          - "intent_text"
  - tool_spec:
      type: "generic"
      name: "check_entitlement"
      description: "Checks whether the current user has SELECT entitlement on a specific semantic view via native Snowflake RBAC. Call this BEFORE attempting to query any view. Returns status ENTITLED, NOT_ENTITLED, or REQUEST_PENDING."
      input_schema:
        type: "object"
        properties:
          view_fqn:
            type: "string"
            description: "Fully qualified semantic view name in the form DB.SCHEMA.NAME."
        required:
          - "view_fqn"
  - tool_spec:
      type: "generic"
      name: "request_access"
      description: "Submits an access request for a semantic view the user is not entitled to. ONLY call this when check_entitlement returns NOT_ENTITLED. Notifies the data steward."
      input_schema:
        type: "object"
        properties:
          view_fqn:
            type: "string"
            description: "Fully qualified semantic view name."
          justification:
            type: "string"
            description: "One-sentence business justification for needing access."
          sensitivity_level:
            type: "string"
            description: "Sensitivity level: LOW, MEDIUM, HIGH, or PII. Default MEDIUM."
        required:
          - "view_fqn"
          - "justification"
  - tool_spec:
      type: "cortex_analyst_text_to_sql"
      name: "tpch_analyst"
      description: "Converts natural-language questions about customers, orders, and line items into SQL against the TPCH_ANALYSIS_VIEW semantic view. ONLY call when check_entitlement returns ENTITLED for MY_DB.PUBLIC.TPCH_ANALYSIS_VIEW."

tool_resources:
  discover_semantic_views:
    type: "procedure"
    identifier: "MY_DB.PUBLIC.SP_SV_DISCOVER(VARCHAR)"
    name: "MY_DB.PUBLIC.SP_SV_DISCOVER"
    execution_environment:
      query_timeout: 60
      warehouse: "COMPUTE_WH"
  check_entitlement:
    type: "procedure"
    identifier: "MY_DB.PUBLIC.SP_SV_CHECK_ENTITLEMENT(VARCHAR)"
    name: "MY_DB.PUBLIC.SP_SV_CHECK_ENTITLEMENT"
    execution_environment:
      query_timeout: 60
      warehouse: "COMPUTE_WH"
  request_access:
    type: "procedure"
    identifier: "MY_DB.PUBLIC.SP_SV_REQUEST_ACCESS(VARCHAR,VARCHAR,VARCHAR)"
    name: "MY_DB.PUBLIC.SP_SV_REQUEST_ACCESS"
    execution_environment:
      query_timeout: 60
      warehouse: "COMPUTE_WH"
  tpch_analyst:
    semantic_view: "MY_DB.PUBLIC.TPCH_ANALYSIS_VIEW"
$$;

-- =============================================================================
-- USAGE
-- =============================================================================
-- Snowflake Intelligence UI:
--   Navigate to Snowsight > AI & ML > Snowflake Intelligence > Open agent
--   "SEMANTIC_MARKETPLACE_AGENT"
--
-- Programmatic invocation (requires Cortex inference enabled):
--   SELECT TRY_PARSE_JSON(
--     SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
--       'MY_DB.PUBLIC.SEMANTIC_MARKETPLACE_AGENT',
--       $${
--         "messages": [
--           {"role":"user","content":[{"type":"text","text":"<question>"}]}
--         ],
--         "stream": false
--       }$$
--     )
--   ) AS resp;
-- =============================================================================

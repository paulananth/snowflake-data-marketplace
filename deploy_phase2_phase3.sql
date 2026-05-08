-- =============================================================================
-- Agentic Data Marketplace - Phase 2 (b/c/d) + Phase 3 Deployment Script
-- Run AFTER deploy_foundation.sql
-- =============================================================================
-- Adds:
--   2b. Entitlement procs:    SP_SV_CHECK_ENTITLEMENT, SP_SV_REQUEST_ACCESS,
--                             SP_SV_APPROVE_ACCESS, SP_SV_DENY_ACCESS
--   2c. Domain suggestion:    SP_SV_SUGGEST_DOMAINS (AI + heuristic fallback)
--   2d. Usage aggregator:     SP_SV_AGGREGATE_USAGE + TASK_SV_FEEDBACK_COLLECTOR
--   3.  Streamlit app:        SEMANTIC_VIEW_BUILDER (6 tabs)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 2b.1 SP_SV_CHECK_ENTITLEMENT
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE MY_DB.PUBLIC.SP_SV_CHECK_ENTITLEMENT(view_fqn VARCHAR)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
EXECUTE AS CALLER
AS
$$
def main(session, view_fqn):
    parts = view_fqn.split('.')
    if len(parts) != 3:
        return {'status': 'ERROR', 'reason': 'view_fqn must be DB.SCHEMA.NAME'}
    cat, sch, nm = parts[0].upper(), parts[1].upper(), parts[2].upper()
    user_row = session.sql("SELECT CURRENT_USER() AS U").collect()
    user = user_row[0]['U']
    pending = session.sql(
        "SELECT COUNT(*) AS C FROM MY_DB.SEMANTIC_CATALOG.SV_ACCESS_REQUESTS "
        "WHERE requestor_user=? AND view_catalog=? AND view_schema=? AND view_name=? AND status='PENDING'",
        params=[user, cat, sch, nm]
    ).collect()[0]['C']
    try:
        rows = session.sql(f"SHOW GRANTS ON SEMANTIC VIEW {view_fqn}").collect()
        roles_with_select = []
        for r in rows:
            d = r.as_dict()
            priv = d.get('privilege')
            grantee = d.get('grantee_name')
            if priv in ('SELECT','OWNERSHIP','REFERENCES','USAGE') and grantee:
                roles_with_select.append(grantee)
    except Exception as e:
        return {'status': 'ERROR', 'reason': str(e), 'user': user}
    user_roles = [r['ROLE'] for r in session.sql("SELECT VALUE::VARCHAR AS role FROM TABLE(FLATTEN(PARSE_JSON(CURRENT_AVAILABLE_ROLES())))").collect()]
    entitled = any(role in roles_with_select for role in user_roles)
    status = 'ENTITLED' if entitled else ('REQUEST_PENDING' if pending > 0 else 'NOT_ENTITLED')
    return {'status': status, 'user': user, 'view': view_fqn,
            'roles_granted': roles_with_select, 'user_roles_count': len(user_roles)}
$$;

-- -----------------------------------------------------------------------------
-- 2b.2 SP_SV_REQUEST_ACCESS
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE MY_DB.PUBLIC.SP_SV_REQUEST_ACCESS(
  view_fqn VARCHAR, justification VARCHAR, sensitivity_level VARCHAR
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
EXECUTE AS CALLER
AS
$$
def main(session, view_fqn, justification, sensitivity_level):
    parts = view_fqn.split('.')
    if len(parts) != 3:
        return {'status': 'ERROR', 'reason': 'view_fqn must be DB.SCHEMA.NAME'}
    cat, sch, nm = parts[0].upper(), parts[1].upper(), parts[2].upper()
    user = session.sql("SELECT CURRENT_USER() AS U").collect()[0]['U']
    existing = session.sql(
        "SELECT request_id FROM MY_DB.SEMANTIC_CATALOG.SV_ACCESS_REQUESTS "
        "WHERE requestor_user=? AND view_catalog=? AND view_schema=? AND view_name=? AND status='PENDING'",
        params=[user, cat, sch, nm]).collect()
    if existing:
        return {'status': 'ALREADY_PENDING', 'request_id': existing[0]['REQUEST_ID']}
    session.sql(
        "INSERT INTO MY_DB.SEMANTIC_CATALOG.SV_ACCESS_REQUESTS "
        "(requestor_user, view_catalog, view_schema, view_name, justification, sensitivity_level, status) "
        "SELECT ?,?,?,?,?,?, 'PENDING'",
        params=[user, cat, sch, nm, justification or '', sensitivity_level or 'MEDIUM']).collect()
    new_id = session.sql(
        "SELECT MAX(request_id) AS R FROM MY_DB.SEMANTIC_CATALOG.SV_ACCESS_REQUESTS WHERE requestor_user=?",
        params=[user]).collect()[0]['R']
    steward = session.sql(
        "SELECT MAX(steward_user) AS S FROM MY_DB.SEMANTIC_CATALOG.SV_DOMAINS "
        "WHERE view_catalog=? AND view_schema=? AND view_name=?",
        params=[cat, sch, nm]).collect()[0]['S']
    return {'status': 'PENDING', 'request_id': new_id, 'requestor': user, 'view': view_fqn,
            'steward': steward,
            'message': f'Access request submitted. Steward: {steward or "(unassigned)"} will review.'}
$$;

-- -----------------------------------------------------------------------------
-- 2b.3 SP_SV_APPROVE_ACCESS
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE MY_DB.PUBLIC.SP_SV_APPROVE_ACCESS(
  request_id NUMBER, grant_to_role VARCHAR, reviewer_notes VARCHAR
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
EXECUTE AS CALLER
AS
$$
def main(session, request_id, grant_to_role, reviewer_notes):
    approver = session.sql("SELECT CURRENT_USER() AS U").collect()[0]['U']
    row = session.sql(
        "SELECT requestor_user, view_catalog, view_schema, view_name, status "
        "FROM MY_DB.SEMANTIC_CATALOG.SV_ACCESS_REQUESTS WHERE request_id=?",
        params=[request_id]).collect()
    if not row:
        return {'status': 'ERROR', 'reason': f'request_id {request_id} not found'}
    r = row[0]
    if r['STATUS'] != 'PENDING':
        return {'status': 'ERROR', 'reason': f'request status is {r["STATUS"]}'}
    view_fqn = f"{r['VIEW_CATALOG']}.{r['VIEW_SCHEMA']}.{r['VIEW_NAME']}"
    grant_executed, grant_err = False, None
    try:
        session.sql(f"GRANT SELECT ON SEMANTIC VIEW {view_fqn} TO ROLE {grant_to_role}").collect()
        grant_executed = True
    except Exception as e:
        grant_err = str(e)
    session.sql(
        "UPDATE MY_DB.SEMANTIC_CATALOG.SV_ACCESS_REQUESTS "
        "SET status=?, reviewed_by=?, reviewed_at=CURRENT_TIMESTAMP(), reviewer_notes=?, snowflake_grant_executed=? "
        "WHERE request_id=?",
        params=['APPROVED' if grant_executed else 'PENDING', approver,
                (reviewer_notes or '') + (f' (GRANT failed: {grant_err})' if grant_err else ''),
                grant_executed, request_id]).collect()
    return {'status': 'APPROVED' if grant_executed else 'GRANT_FAILED',
            'request_id': request_id, 'requestor': r['REQUESTOR_USER'],
            'view': view_fqn, 'granted_to_role': grant_to_role, 'grant_error': grant_err}
$$;

-- -----------------------------------------------------------------------------
-- 2b.4 SP_SV_DENY_ACCESS
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE MY_DB.PUBLIC.SP_SV_DENY_ACCESS(
  request_id NUMBER, reviewer_notes VARCHAR
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
EXECUTE AS CALLER
AS
$$
def main(session, request_id, reviewer_notes):
    approver = session.sql("SELECT CURRENT_USER() AS U").collect()[0]['U']
    row = session.sql(
        "SELECT requestor_user, status FROM MY_DB.SEMANTIC_CATALOG.SV_ACCESS_REQUESTS WHERE request_id=?",
        params=[request_id]).collect()
    if not row:
        return {'status': 'ERROR', 'reason': f'request_id {request_id} not found'}
    if row[0]['STATUS'] != 'PENDING':
        return {'status': 'ERROR', 'reason': f'request status is {row[0]["STATUS"]}'}
    session.sql(
        "UPDATE MY_DB.SEMANTIC_CATALOG.SV_ACCESS_REQUESTS "
        "SET status='DENIED', reviewed_by=?, reviewed_at=CURRENT_TIMESTAMP(), reviewer_notes=? "
        "WHERE request_id=?",
        params=[approver, reviewer_notes or '', request_id]).collect()
    return {'status': 'DENIED', 'request_id': request_id, 'reviewer': approver}
$$;

-- -----------------------------------------------------------------------------
-- 2c. SP_SV_SUGGEST_DOMAINS  (AI_COMPLETE with heuristic fallback)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE MY_DB.PUBLIC.SP_SV_SUGGEST_DOMAINS(view_fqn VARCHAR)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
EXECUTE AS CALLER
AS
$$
import json
DOMAIN_KEYWORDS = {
    'Finance':      ['revenue','price','cost','tax','discount','balance','profit','expense','invoice','payment'],
    'Sales':        ['order','sales','customer','quote','opportunity','deal','pipeline','lead'],
    'Customer':     ['customer','account','contact','segment','address','phone','market'],
    'Supply Chain': ['supplier','part','lineitem','line_item','ship','receipt','warehouse','inventory','stock','order'],
    'Operations':   ['status','priority','ship','clerk','process','operation'],
    'Marketing':    ['campaign','promo','mktsegment','segment','channel','impression','click'],
    'HR':           ['employee','hire','salary','department','manager','position'],
    'Product':      ['product','sku','brand','category','part'],
}

def heuristic_domain(view_fqn, cols):
    text = view_fqn.lower() + ' ' + ' '.join(f"{r['SOURCE_TABLE']} {r['COLUMN_NAME']}" for r in cols).lower()
    scores = {dom: sum(1 for kw in kws if kw in text) for dom, kws in DOMAIN_KEYWORDS.items()}
    top = max(scores.items(), key=lambda x: x[1])
    total = sum(scores.values()) or 1
    confidence = round(top[1] / total, 2) if top[1] > 0 else 0.3
    return {'domain': top[0] if top[1] > 0 else 'Other', 'sub_domain': '',
            'confidence': confidence,
            'rationale': f'Heuristic match: {top[1]} keyword hits for {top[0]}',
            'method': 'heuristic'}

def main(session, view_fqn):
    parts = view_fqn.split('.')
    cat, sch, nm = parts[0].upper(), parts[1].upper(), parts[2].upper()
    cols = session.sql(
        "SELECT source_table, column_name, data_type, semantic_role "
        "FROM MY_DB.SEMANTIC_CATALOG.SV_COLUMNS "
        "WHERE view_catalog=? AND view_schema=? AND view_name=? "
        "ORDER BY source_table, ordinal_position",
        params=[cat, sch, nm]).collect()
    if not cols:
        return {'status': 'ERROR', 'reason': 'No columns found in catalog for this view'}
    summary = '\n'.join(
        f"  {r['SOURCE_TABLE']}.{r['COLUMN_NAME']} ({r['DATA_TYPE']}) [{r['SEMANTIC_ROLE']}]" for r in cols[:60])
    prompt = ("You are a data domain classifier. Output strict JSON: "
              "{\"domain\":\"<Finance|Sales|Marketing|Operations|HR|Product|Supply Chain|Customer|Other>\", "
              "\"sub_domain\":\"<label>\", \"confidence\":<0.0-1.0>, \"rationale\":\"<one sentence>\"}.\n"
              f"View: {view_fqn}\nColumns:\n{summary}\nOutput ONLY JSON.")
    parsed, method = None, 'heuristic'
    for fn_sql in [
        "SELECT AI_COMPLETE('claude-3-5-sonnet', ?) AS R",
        "SELECT SNOWFLAKE.CORTEX.COMPLETE('mistral-large2', ?) AS R",
        "SELECT SNOWFLAKE.CORTEX.COMPLETE('llama3.1-8b', ?) AS R"
    ]:
        try:
            resp = session.sql(fn_sql, params=[prompt]).collect()[0]['R']
            raw = resp.strip() if isinstance(resp, str) else str(resp)
            s, e = raw.find('{'), raw.rfind('}')
            if s >= 0 and e > s:
                parsed = json.loads(raw[s:e+1]); method = 'ai'; break
        except Exception:
            continue
    if not parsed:
        parsed = heuristic_domain(view_fqn, cols)
    domain = parsed.get('domain', 'Other')
    sub = parsed.get('sub_domain', '')
    conf = float(parsed.get('confidence', 0.5))
    rationale = parsed.get('rationale', '')
    session.sql(
        "DELETE FROM MY_DB.SEMANTIC_CATALOG.SV_DOMAINS "
        "WHERE view_catalog=? AND view_schema=? AND view_name=? AND human_confirmed_domain IS NULL",
        params=[cat, sch, nm]).collect()
    session.sql(
        "INSERT INTO MY_DB.SEMANTIC_CATALOG.SV_DOMAINS "
        "(domain_name, parent_domain, description, view_catalog, view_schema, view_name, "
        " ai_suggested_domain, ai_confidence_score) "
        "SELECT ?,?,?,?,?,?,?,?",
        params=[domain, sub, rationale, cat, sch, nm, domain, conf]).collect()
    return {'status': 'OK', 'view': view_fqn, 'domain': domain, 'sub_domain': sub,
            'confidence': conf, 'rationale': rationale, 'method': method}
$$;

-- -----------------------------------------------------------------------------
-- 2d.1 SP_SV_AGGREGATE_USAGE
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE MY_DB.PUBLIC.SP_SV_AGGREGATE_USAGE()
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
EXECUTE AS CALLER
AS
$$
def main(session):
    rows = session.sql(
        "SELECT view_catalog, view_schema, view_name FROM MY_DB.SEMANTIC_CATALOG.SV_REGISTRY WHERE status='DEPLOYED'"
    ).collect()
    inserted = 0
    for r in rows:
        cat, sch, nm = r['VIEW_CATALOG'], r['VIEW_SCHEMA'], r['VIEW_NAME']
        view_fqn = f"{cat}.{sch}.{nm}"
        session.sql(
            "DELETE FROM MY_DB.SEMANTIC_CATALOG.SV_USAGE_ANALYTICS "
            "WHERE view_catalog=? AND view_schema=? AND view_name=? "
            "AND query_date >= DATEADD(day,-7,CURRENT_DATE())",
            params=[cat, sch, nm]).collect()
        session.sql(
            "INSERT INTO MY_DB.SEMANTIC_CATALOG.SV_USAGE_ANALYTICS "
            "(view_catalog, view_schema, view_name, query_date, query_count, unique_users, "
            " answered_count, unanswered_count, avg_human_score) "
            "SELECT ?,?,?, DATE_TRUNC('day', start_time)::DATE, COUNT(*), COUNT(DISTINCT user_name), "
            "       SUM(IFF(execution_status='SUCCESS',1,0)), SUM(IFF(execution_status<>'SUCCESS',1,0)), NULL "
            "FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY "
            "WHERE start_time >= DATEADD(day,-7,CURRENT_DATE()) "
            "  AND POSITION(? IN UPPER(query_text)) > 0 "
            "GROUP BY DATE_TRUNC('day', start_time)::DATE",
            params=[cat, sch, nm, view_fqn.upper()]).collect()
        inserted += 1
    return {'status': 'OK', 'views_processed': inserted}
$$;

-- -----------------------------------------------------------------------------
-- 2d.2 TASK_SV_FEEDBACK_COLLECTOR  (hourly; suspended initially)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TASK MY_DB.PUBLIC.TASK_SV_FEEDBACK_COLLECTOR
  WAREHOUSE = COMPUTE_WH
  SCHEDULE = 'USING CRON 0 * * * * UTC'
  COMMENT = 'Aggregates semantic view usage from ACCOUNT_USAGE.QUERY_HISTORY into SV_USAGE_ANALYTICS'
AS
  CALL MY_DB.PUBLIC.SP_SV_AGGREGATE_USAGE();

-- To start: ALTER TASK MY_DB.PUBLIC.TASK_SV_FEEDBACK_COLLECTOR RESUME;

-- =============================================================================
-- Phase 3 - Streamlit App
-- =============================================================================
CREATE STAGE IF NOT EXISTS MY_DB.PUBLIC.STREAMLIT_STAGE
  DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'Hosts the SEMANTIC_VIEW_BUILDER Streamlit app';

-- Upload streamlit_app.py to STREAMLIT_STAGE manually:
--   - Snowsight: Data > Databases > MY_DB > PUBLIC > Stages > STREAMLIT_STAGE > +Files
--   - Or from a workspace: COPY FILES INTO @MY_DB.PUBLIC.STREAMLIT_STAGE FROM 'snow://workspace/...' FILES=('streamlit_app.py');

CREATE OR REPLACE STREAMLIT MY_DB.PUBLIC.SEMANTIC_VIEW_BUILDER
  ROOT_LOCATION = '@MY_DB.PUBLIC.STREAMLIT_STAGE'
  MAIN_FILE = 'streamlit_app.py'
  QUERY_WAREHOUSE = COMPUTE_WH
  TITLE = 'Semantic View Builder'
  COMMENT = 'Agentic Data Marketplace - 6-tab semantic view lifecycle management UI';

-- =============================================================================
-- Done. Open the app via Snowsight: Streamlit > SEMANTIC_VIEW_BUILDER
-- =============================================================================

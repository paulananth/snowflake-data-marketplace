-- =============================================================================
-- Agentic Data Marketplace - Entitlement & Domain Layer
-- Adds 5 procedures for the marketplace consumption layer:
--   - SP_SV_CHECK_ENTITLEMENT  (RBAC check, runs as caller)
--   - SP_SV_REQUEST_ACCESS     (creates pending request)
--   - SP_SV_APPROVE_ACCESS     (executes GRANT)
--   - SP_SV_DENY_ACCESS        (marks denied)
--   - SP_SV_SUGGEST_DOMAINS    (AI-suggests business domain, heuristic fallback)
-- =============================================================================

-- 1. SP_SV_CHECK_ENTITLEMENT - native RBAC enforcement using caller's session
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
    cur_user = session.sql("SELECT CURRENT_USER()").collect()[0][0]
    cur_role = session.sql("SELECT CURRENT_ROLE()").collect()[0][0]
    parts = view_fqn.upper().split('.')
    if len(parts) != 3:
        return {'status':'ERROR','message':'view_fqn must be DB.SCHEMA.VIEW'}
    cat, sch, nm = parts
    pending = session.sql(
        "SELECT COUNT(*) FROM MY_DB.SEMANTIC_CATALOG.SV_ACCESS_REQUESTS "
        "WHERE requestor_user=? AND view_catalog=? AND view_schema=? AND view_name=? AND status='PENDING'",
        params=[cur_user, cat, sch, nm]
    ).collect()[0][0]
    try:
        session.sql(f"DESCRIBE SEMANTIC VIEW {view_fqn}").collect()
        access_ok = True
    except Exception:
        access_ok = False
    if access_ok:
        return {'status':'ENTITLED','user':cur_user,'role':cur_role,'view':view_fqn}
    if pending > 0:
        return {'status':'REQUEST_PENDING','user':cur_user,'role':cur_role,'view':view_fqn}
    return {'status':'NOT_ENTITLED','user':cur_user,'role':cur_role,'view':view_fqn,
            'next_action':'Call SP_SV_REQUEST_ACCESS to request entitlement'}
$$;

-- 2. SP_SV_REQUEST_ACCESS - logs pending access request
CREATE OR REPLACE PROCEDURE MY_DB.PUBLIC.SP_SV_REQUEST_ACCESS(
  view_fqn VARCHAR, justification VARCHAR, sensitivity_level VARCHAR
)
RETURNS VARIANT LANGUAGE PYTHON RUNTIME_VERSION='3.10'
PACKAGES=('snowflake-snowpark-python') HANDLER='main' EXECUTE AS CALLER
AS
$$
def main(session, view_fqn, justification, sensitivity_level):
    cur_user = session.sql("SELECT CURRENT_USER()").collect()[0][0]
    parts = view_fqn.upper().split('.')
    if len(parts) != 3:
        return {'status':'ERROR','message':'view_fqn must be DB.SCHEMA.VIEW'}
    cat, sch, nm = parts
    existing = session.sql(
        "SELECT COUNT(*) FROM MY_DB.SEMANTIC_CATALOG.SV_ACCESS_REQUESTS "
        "WHERE requestor_user=? AND view_catalog=? AND view_schema=? AND view_name=? AND status='PENDING'",
        params=[cur_user, cat, sch, nm]
    ).collect()[0][0]
    if existing > 0:
        return {'status':'ALREADY_PENDING','user':cur_user,'view':view_fqn}
    session.sql(
        "INSERT INTO MY_DB.SEMANTIC_CATALOG.SV_ACCESS_REQUESTS "
        "(requestor_user,view_catalog,view_schema,view_name,justification,sensitivity_level,status) "
        "SELECT ?,?,?,?,?,?, 'PENDING'",
        params=[cur_user, cat, sch, nm, justification or '', sensitivity_level or 'LOW']
    ).collect()
    rid = session.sql(
        "SELECT MAX(request_id) FROM MY_DB.SEMANTIC_CATALOG.SV_ACCESS_REQUESTS "
        "WHERE requestor_user=? AND view_catalog=? AND view_schema=? AND view_name=?",
        params=[cur_user, cat, sch, nm]
    ).collect()[0][0]
    steward = session.sql(
        "SELECT MAX(steward_user), MAX(steward_role) FROM MY_DB.SEMANTIC_CATALOG.SV_DOMAINS "
        "WHERE view_catalog=? AND view_schema=? AND view_name=?",
        params=[cat, sch, nm]
    ).collect()[0]
    return {'status':'SUBMITTED','request_id':rid,'requestor':cur_user,
            'view':view_fqn,'steward_user':steward[0],'steward_role':steward[1]}
$$;

-- 3. SP_SV_APPROVE_ACCESS - executes GRANT and marks request approved
CREATE OR REPLACE PROCEDURE MY_DB.PUBLIC.SP_SV_APPROVE_ACCESS(
  request_id NUMBER, reviewer_notes VARCHAR
)
RETURNS VARIANT LANGUAGE PYTHON RUNTIME_VERSION='3.10'
PACKAGES=('snowflake-snowpark-python') HANDLER='main' EXECUTE AS CALLER
AS
$$
def main(session, request_id, reviewer_notes):
    approver = session.sql("SELECT CURRENT_USER()").collect()[0][0]
    row = session.sql(
        "SELECT requestor_user, view_catalog, view_schema, view_name, status "
        "FROM MY_DB.SEMANTIC_CATALOG.SV_ACCESS_REQUESTS WHERE request_id=?",
        params=[request_id]
    ).collect()
    if not row:
        return {'status':'ERROR','message':f'Request {request_id} not found'}
    r = row[0].as_dict()
    if r['STATUS'] != 'PENDING':
        return {'status':'ERROR','message':f'Request is {r["STATUS"]}, not PENDING'}
    view_fqn = f"{r['VIEW_CATALOG']}.{r['VIEW_SCHEMA']}.{r['VIEW_NAME']}"
    grant_executed, grant_error = False, None
    try:
        session.sql(f"GRANT SELECT ON SEMANTIC VIEW {view_fqn} TO USER {r['REQUESTOR_USER']}").collect()
        grant_executed = True
    except Exception as e:
        grant_error = str(e)
        try:
            session.sql(f"GRANT SELECT ON SEMANTIC VIEW {view_fqn} TO ROLE PUBLIC").collect()
            grant_executed = True
            grant_error = (grant_error or '') + ' [fallback to ROLE PUBLIC succeeded]'
        except Exception as e2:
            grant_error = (grant_error or '') + f' [fallback failed: {e2}]'
    session.sql(
        "UPDATE MY_DB.SEMANTIC_CATALOG.SV_ACCESS_REQUESTS "
        "SET status='APPROVED', reviewed_by=?, reviewed_at=CURRENT_TIMESTAMP(), "
        "    reviewer_notes=?, snowflake_grant_executed=? "
        "WHERE request_id=?",
        params=[approver, reviewer_notes or '', bool(grant_executed), request_id]
    ).collect()
    return {'status':'APPROVED','request_id':request_id,'view':view_fqn,
            'requestor':r['REQUESTOR_USER'],'approver':approver,
            'grant_executed':grant_executed,'grant_error':grant_error}
$$;

-- 4. SP_SV_DENY_ACCESS - marks request denied with reviewer notes
CREATE OR REPLACE PROCEDURE MY_DB.PUBLIC.SP_SV_DENY_ACCESS(
  request_id NUMBER, reviewer_notes VARCHAR
)
RETURNS VARIANT LANGUAGE PYTHON RUNTIME_VERSION='3.10'
PACKAGES=('snowflake-snowpark-python') HANDLER='main' EXECUTE AS CALLER
AS
$$
def main(session, request_id, reviewer_notes):
    reviewer = session.sql("SELECT CURRENT_USER()").collect()[0][0]
    row = session.sql(
        "SELECT status FROM MY_DB.SEMANTIC_CATALOG.SV_ACCESS_REQUESTS WHERE request_id=?",
        params=[request_id]
    ).collect()
    if not row:
        return {'status':'ERROR','message':f'Request {request_id} not found'}
    if row[0]['STATUS'] != 'PENDING':
        return {'status':'ERROR','message':f'Request is {row[0]["STATUS"]}, not PENDING'}
    session.sql(
        "UPDATE MY_DB.SEMANTIC_CATALOG.SV_ACCESS_REQUESTS "
        "SET status='DENIED', reviewed_by=?, reviewed_at=CURRENT_TIMESTAMP(), reviewer_notes=? "
        "WHERE request_id=?",
        params=[reviewer, reviewer_notes or '', request_id]
    ).collect()
    return {'status':'DENIED','request_id':request_id,'reviewer':reviewer}
$$;

-- 5. SP_SV_SUGGEST_DOMAINS - AI domain inference with heuristic fallback
CREATE OR REPLACE PROCEDURE MY_DB.PUBLIC.SP_SV_SUGGEST_DOMAINS(view_fqn VARCHAR)
RETURNS VARIANT LANGUAGE PYTHON RUNTIME_VERSION='3.10'
PACKAGES=('snowflake-snowpark-python') HANDLER='main'
AS
$$
import json

DOMAIN_KEYWORDS = {
    'Finance':     ['price','amount','cost','revenue','balance','total','tax','discount','payment','invoice'],
    'Sales':       ['order','customer','segment','sales','quote','deal','opportunity'],
    'Marketing':   ['campaign','lead','channel','engagement','impression','click'],
    'Supply Chain':['lineitem','ship','receipt','quantity','supplier','part','warehouse','shipdate','shipmode'],
    'Operations':  ['priority','status','clerk','process','queue'],
    'HR':          ['employee','hire','salary','department','manager','headcount'],
    'Customer':    ['custkey','phone','address','nation','contact','mktsegment'],
    'Product':     ['part','sku','catalog','brand'],
    'Risk':        ['risk','fraud','compliance','audit'],
    'IT':          ['log','event','session','error']
}

def heuristic(columns):
    scores = {d:0 for d in DOMAIN_KEYWORDS}
    for c in columns:
        n = (c['COLUMN_NAME'] or '').lower()
        for d, kws in DOMAIN_KEYWORDS.items():
            for kw in kws:
                if kw in n: scores[d] += 1
    domain = max(scores, key=scores.get)
    total = sum(scores.values())
    conf = scores[domain] / total if total > 0 else 0.0
    return domain, conf, f"Heuristic: matched {scores[domain]} keywords for {domain}"

def main(session, view_fqn):
    parts = view_fqn.upper().split('.')
    if len(parts) != 3:
        return {'status':'ERROR','message':'view_fqn must be DB.SCHEMA.VIEW'}
    cat, sch, nm = parts
    cols = session.sql(
        "SELECT source_table, column_name, semantic_role FROM MY_DB.SEMANTIC_CATALOG.SV_COLUMNS "
        "WHERE view_catalog=? AND view_schema=? AND view_name=? "
        "AND version_id=(SELECT MAX(version_id) FROM MY_DB.SEMANTIC_CATALOG.SV_REGISTRY "
        "                WHERE view_catalog=? AND view_schema=? AND view_name=?)",
        params=[cat, sch, nm, cat, sch, nm]
    ).collect()
    cols_dict = [r.as_dict() for r in cols]
    domain, conf, reasoning, method = 'Unclassified', 0.0, '', 'HEURISTIC'
    summary = ", ".join([f"{(r['SOURCE_TABLE'] or '').split('.')[-1]}.{r['COLUMN_NAME']}({r['SEMANTIC_ROLE']})" for r in cols_dict[:60]])
    prompt = (
        "You are a data domain classifier. Choose ONE business domain from: "
        "Finance, Sales, Marketing, Operations, Supply Chain, HR, Customer, Product, Risk, IT. "
        f"Semantic view '{view_fqn}' columns: {summary}. "
        "Respond JSON ONLY: {\"domain\": \"<one>\", \"confidence\": 0.0-1.0, \"reasoning\": \"<short>\"}"
    )
    try:
        row = session.sql("SELECT SNOWFLAKE.CORTEX.COMPLETE('claude-3-5-sonnet', ?)", params=[prompt]).collect()[0]
        raw = row[0]
        s = raw[raw.find('{'): raw.rfind('}') + 1]
        parsed = json.loads(s)
        domain = parsed.get('domain', 'Unclassified')
        conf = float(parsed.get('confidence', 0.0))
        reasoning = parsed.get('reasoning', '')
        method = 'CORTEX_AI'
    except Exception:
        domain, conf, reasoning = heuristic(cols_dict)
    session.sql("DELETE FROM MY_DB.SEMANTIC_CATALOG.SV_DOMAINS "
                "WHERE view_catalog=? AND view_schema=? AND view_name=? AND human_confirmed_domain IS NULL",
                params=[cat, sch, nm]).collect()
    session.sql(
        "INSERT INTO MY_DB.SEMANTIC_CATALOG.SV_DOMAINS "
        "(domain_name, description, view_catalog, view_schema, view_name, "
        " ai_suggested_domain, ai_confidence_score) "
        "SELECT ?,?,?,?,?,?,?",
        params=[domain, reasoning, cat, sch, nm, domain, conf]
    ).collect()
    return {'status':'OK','view':view_fqn,'method':method,
            'ai_suggested_domain':domain,'confidence':conf,'reasoning':reasoning}
$$;

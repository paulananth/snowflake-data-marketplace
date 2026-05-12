-- =============================================================================
-- AGENTIC DATA MARKETPLACE - UNIFIED DEPLOYMENT SCRIPT
-- =============================================================================
-- Deploy this script in a target Snowflake account to stand up the full
-- Agentic Data Marketplace (semantic views, entitlements, Cortex Agent, 
-- Streamlit apps).
--
-- PREREQUISITES:
--   1. SYSADMIN role with grants from ACCOUNTADMIN (see DEPLOYMENT_GUIDE.md)
--   2. Non-trial account (Cortex Agent requires Enterprise+ or Standard)
--   3. COMPUTE_WH warehouse (or change the variable below)
--
-- CONFIGURATION: Update these values for your target account
-- =============================================================================

-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  STEP 0: CONFIGURATION - CHANGE THESE FOR YOUR ACCOUNT                     ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

SET DB_NAME       = 'AGMP_DB';  -- <<< CHANGE THIS to your target database name
SET WH_NAME       = 'COMPUTE_WH';
SET DEPLOY_ROLE   = 'SYSADMIN';

USE ROLE IDENTIFIER($DEPLOY_ROLE);

-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  STEP 1: DATABASE & SCHEMAS                                                ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

CREATE DATABASE IF NOT EXISTS IDENTIFIER($DB_NAME);
USE DATABASE IDENTIFIER($DB_NAME);
CREATE SCHEMA IF NOT EXISTS PUBLIC;
CREATE SCHEMA IF NOT EXISTS SEMANTIC_CATALOG;

CREATE WAREHOUSE IF NOT EXISTS IDENTIFIER($WH_NAME)
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE;

USE WAREHOUSE IDENTIFIER($WH_NAME);

-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  STEP 2: CATALOG TABLES                                                    ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

USE SCHEMA SEMANTIC_CATALOG;

CREATE TABLE IF NOT EXISTS AGMP_REGISTRY (
    view_catalog      VARCHAR NOT NULL,
    view_schema       VARCHAR NOT NULL,
    view_name         VARCHAR NOT NULL,
    version_id        NUMBER AUTOINCREMENT,
    version_tag       VARCHAR,
    status            VARCHAR DEFAULT 'DRAFT',
    view_ddl          VARCHAR,
    test_score        FLOAT,
    created_by        VARCHAR DEFAULT CURRENT_USER(),
    approved_by       VARCHAR,
    created_at        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    deployed_at       TIMESTAMP_NTZ,
    archived_at       TIMESTAMP_NTZ,
    notes             VARCHAR
);

CREATE TABLE IF NOT EXISTS AGMP_COLUMNS (
    view_catalog       VARCHAR NOT NULL,
    view_schema        VARCHAR NOT NULL,
    view_name          VARCHAR NOT NULL,
    version_id         NUMBER  NOT NULL,
    source_table       VARCHAR NOT NULL,
    column_name        VARCHAR NOT NULL,
    data_type          VARCHAR,
    ordinal_position   NUMBER,
    semantic_role      VARCHAR,
    ai_description     VARCHAR,
    human_description  VARCHAR,
    effective_description VARCHAR AS (IFNULL(human_description, ai_description)),
    description_source VARCHAR DEFAULT 'AI_GENERATED',
    is_time_dimension  BOOLEAN DEFAULT FALSE,
    time_grain         VARCHAR,
    last_edited_by     VARCHAR,
    last_edited_at     TIMESTAMP_NTZ
);

CREATE TABLE IF NOT EXISTS AGMP_RELATIONSHIPS (
    view_catalog      VARCHAR NOT NULL,
    view_schema       VARCHAR NOT NULL,
    view_name         VARCHAR NOT NULL,
    version_id        NUMBER  NOT NULL,
    parent_table      VARCHAR NOT NULL,
    child_table       VARCHAR NOT NULL,
    join_type         VARCHAR DEFAULT 'INNER',
    join_keys         VARIANT,
    relationship_type VARCHAR DEFAULT 'ONE_TO_MANY'
);

CREATE TABLE IF NOT EXISTS AGMP_DOMAINS (
    domain_id              NUMBER AUTOINCREMENT,
    view_catalog           VARCHAR NOT NULL,
    view_schema            VARCHAR NOT NULL,
    view_name              VARCHAR NOT NULL,
    domain_name            VARCHAR,
    ai_suggested_domain    VARCHAR,
    ai_confidence_score    FLOAT,
    human_confirmed_domain VARCHAR,
    confirmed_by           VARCHAR,
    confirmed_at           TIMESTAMP_NTZ,
    steward_user           VARCHAR,
    steward_role           VARCHAR,
    description            VARCHAR
);

CREATE TABLE IF NOT EXISTS AGMP_TEST_RESULTS (
    test_id        NUMBER AUTOINCREMENT,
    view_catalog   VARCHAR NOT NULL,
    view_schema    VARCHAR NOT NULL,
    view_name      VARCHAR NOT NULL,
    version_id     NUMBER,
    test_name      VARCHAR,
    test_sql       VARCHAR,
    status         VARCHAR,
    error_message  VARCHAR,
    executed_at    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS AGMP_ANALYST_FEEDBACK (
    feedback_id    NUMBER AUTOINCREMENT,
    view_catalog   VARCHAR NOT NULL,
    view_schema    VARCHAR NOT NULL,
    view_name      VARCHAR NOT NULL,
    version_id     NUMBER,
    query_text     VARCHAR,
    query_id       VARCHAR,
    answered       BOOLEAN,
    human_score    NUMBER,
    feedback_text  VARCHAR,
    created_at     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS AGMP_ACCESS_REQUESTS (
    request_id        NUMBER AUTOINCREMENT,
    requestor_user    VARCHAR NOT NULL,
    view_catalog      VARCHAR NOT NULL,
    view_schema       VARCHAR NOT NULL,
    view_name         VARCHAR NOT NULL,
    sensitivity_level VARCHAR DEFAULT 'MEDIUM',
    justification     VARCHAR,
    status            VARCHAR DEFAULT 'PENDING',
    reviewed_by       VARCHAR,
    reviewer_notes    VARCHAR,
    requested_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    reviewed_at       TIMESTAMP_NTZ,
    granted_role      VARCHAR
);

CREATE TABLE IF NOT EXISTS AGMP_GLOSSARY (
    term_id       NUMBER AUTOINCREMENT,
    term_name     VARCHAR NOT NULL,
    definition    VARCHAR,
    domain_name   VARCHAR,
    source_view   VARCHAR,
    created_by    VARCHAR,
    created_at    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS AGMP_USAGE_ANALYTICS (
    view_catalog   VARCHAR NOT NULL,
    view_schema    VARCHAR NOT NULL,
    view_name      VARCHAR NOT NULL,
    query_date     DATE NOT NULL,
    query_count    NUMBER DEFAULT 0,
    unique_users   NUMBER DEFAULT 0,
    answered_count NUMBER DEFAULT 0,
    unanswered_count NUMBER DEFAULT 0
);

-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  STEP 3: STORED PROCEDURES - BUILDER PIPELINE                              ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

USE SCHEMA PUBLIC;

CREATE OR REPLACE PROCEDURE SP_AGMP_DESCRIBE_TABLES(table_fqns ARRAY)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
EXECUTE AS CALLER
AS
$$
import json
def main(session, table_fqns):
    results = []
    for fqn in table_fqns:
        try:
            rows = session.sql(f"DESCRIBE TABLE {fqn}").collect()
            cols = []
            for r in rows:
                cols.append({
                    "name": r["name"],
                    "type": r["type"],
                    "nullable": r["null?"] == "Y"
                })
            results.append({"table": fqn, "columns": cols, "status": "OK"})
        except Exception as e:
            results.append({"table": fqn, "columns": [], "status": f"ERROR: {e}"})
    return results
$$;

CREATE OR REPLACE PROCEDURE SP_AGMP_GENERATE_AI_DESCRIPTIONS(table_fqns ARRAY)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
EXECUTE AS CALLER
AS
$$
import json
def main(session, table_fqns):
    results = []
    for fqn in table_fqns:
        try:
            rows = session.sql(f"DESCRIBE TABLE {fqn}").collect()
            descs = []
            for r in rows:
                col_name = r["name"]
                col_type = r["type"]
                prompt = f"Write a one-sentence business description for a database column named '{col_name}' with data type '{col_type}' in table '{fqn}'. Be concise."
                try:
                    ai_row = session.sql(f"SELECT SNOWFLAKE.CORTEX.COMPLETE('mistral-large2', '{prompt}') AS D").collect()
                    desc = ai_row[0]["D"].strip().strip('"') if ai_row else col_name
                except:
                    desc = f"{col_name} column of type {col_type}"
                descs.append({"column": col_name, "description": desc})
            results.append({"table": fqn, "descriptions": descs})
        except Exception as e:
            results.append({"table": fqn, "descriptions": [], "error": str(e)})
    return results
$$;

CREATE OR REPLACE PROCEDURE SP_AGMP_CLASSIFY_COLUMNS(table_meta VARIANT, ai_descriptions VARIANT)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
AS
$$
import json
def main(session, table_meta, ai_descriptions):
    TIME_KEYWORDS = ["DATE","TIME","TIMESTAMP","YEAR","MONTH","DAY","WEEK","QUARTER","PERIOD"]
    METRIC_TYPES = ["NUMBER","FLOAT","DECIMAL","NUMERIC","INT","INTEGER","BIGINT","DOUBLE","REAL"]
    ID_KEYWORDS = ["KEY","_ID","_SK","_PK","_FK"]

    classified = []
    desc_map = {}
    if ai_descriptions:
        for tbl in ai_descriptions:
            for d in tbl.get("descriptions", []):
                desc_map[(tbl["table"], d["column"])] = d["description"]

    for tbl in table_meta:
        table_name = tbl["table"]
        for col in tbl.get("columns", []):
            name = col["name"].upper()
            dtype = col["type"].upper()
            is_time = any(k in name for k in TIME_KEYWORDS) or "DATE" in dtype or "TIMESTAMP" in dtype
            is_numeric = any(t in dtype for t in METRIC_TYPES)
            is_id = any(k in name for k in ID_KEYWORDS)
            if is_time:
                role = "DIMENSION"
                time_dim = True
            elif is_id:
                role = "DIMENSION"
                time_dim = False
            elif is_numeric:
                role = "METRIC"
                time_dim = False
            else:
                role = "DIMENSION"
                time_dim = False
            classified.append({
                "table": table_name,
                "column": name,
                "data_type": dtype,
                "semantic_role": role,
                "is_time_dimension": time_dim,
                "ai_description": desc_map.get((table_name, name), f"{name} column")
            })
    return classified
$$;

CREATE OR REPLACE PROCEDURE SP_AGMP_GENERATE_DDL(classified_cols VARIANT)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
AS
$$
import json
def main(session, classified_cols):
    if not classified_cols:
        return "-- No columns to process"

    tables = {}
    for col in classified_cols:
        t = col["table"]
        if t not in tables:
            tables[t] = []
        tables[t].append(col)

    dimensions = []
    metrics = []
    facts = []
    for tbl, cols in tables.items():
        for c in cols:
            role = c.get("semantic_role", "DIMENSION")
            entry = f'    {c["column"]} AS {c["column"]} COMMENT \'{c.get("ai_description","").replace(chr(39),"")}\''
            if role == "METRIC":
                metrics.append(entry)
            elif c.get("is_time_dimension"):
                dimensions.append(entry + " -- time_dimension")
            else:
                dimensions.append(entry)

    ddl_parts = []
    ddl_parts.append("-- Auto-generated semantic view DDL")
    ddl_parts.append("-- Dimensions")
    if dimensions:
        ddl_parts.append("DIMENSIONS")
        ddl_parts.append(",\n".join(dimensions))
    if metrics:
        ddl_parts.append("METRICS")
        ddl_parts.append(",\n".join(metrics))
    return "\n".join(ddl_parts)
$$;

CREATE OR REPLACE PROCEDURE SP_AGMP_CREATE_AND_CATALOG(
    target_view VARCHAR, view_comment VARCHAR,
    classified_cols VARIANT, relationships VARIANT, ddl_text VARCHAR
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
EXECUTE AS CALLER
AS
$$
import json
from datetime import datetime

def main(session, target_view, view_comment, classified_cols, relationships, ddl_text):
    parts = target_view.split(".")
    if len(parts) != 3:
        return {"status": "ERROR", "message": "target_view must be DB.SCHEMA.NAME"}
    v_cat, v_sch, v_nm = parts

    tables = list(set(c["table"] for c in classified_cols))
    table_refs = " ".join([f"TABLE({t})" for t in tables])
    dims, mets, facts = [], [], []
    synonyms_map = {}
    for c in classified_cols:
        col_def = f'{c["column"]} COMMENT \'{c.get("ai_description","").replace(chr(39),"")}\''
        syns = c.get("synonyms", [])
        if syns:
            synonyms_map[c["column"]] = syns
        role = c.get("semantic_role", "DIMENSION")
        if role == "METRIC":
            mets.append(col_def)
        elif c.get("is_time_dimension"):
            dims.append(col_def)
        else:
            dims.append(col_def)

    dim_block = "  DIMENSIONS\n    " + ",\n    ".join(dims) if dims else ""
    met_block = "  METRICS\n    " + ",\n    ".join(mets) if mets else ""

    rel_block = ""
    if relationships:
        rel_parts = []
        for rel in relationships:
            parent = rel.get("parent_table","")
            child = rel.get("child_table","")
            keys = rel.get("join_keys", [])
            if keys:
                key_str = " AND ".join([f'{parent}.{k["parent_col"]} = {child}.{k["child_col"]}' for k in keys])
                rel_parts.append(f"    {parent} INNER JOIN {child} ON ({key_str})")
        if rel_parts:
            rel_block = "  RELATIONSHIPS\n" + ",\n".join(rel_parts)

    synonyms_block = ""
    if synonyms_map:
        syn_parts = []
        for col, syns in synonyms_map.items():
            syn_list = ", ".join([f"'{s}'" for s in syns])
            syn_parts.append(f"    {col} SYNONYMS ({syn_list})")
        if syn_parts:
            synonyms_block = "  SYNONYMS\n" + ",\n".join(syn_parts)

    create_ddl = f"CREATE OR REPLACE SEMANTIC VIEW {target_view}\n"
    if view_comment:
        create_ddl += f"  COMMENT = '{view_comment.replace(chr(39), chr(39)+chr(39))}'\n"
    create_ddl += f"  TABLES = ({table_refs})\n"
    if rel_block: create_ddl += rel_block + "\n"
    if dim_block: create_ddl += dim_block + "\n"
    if met_block: create_ddl += met_block + "\n"
    if synonyms_block: create_ddl += synonyms_block + "\n"

    try:
        session.sql(create_ddl).collect()
    except Exception as e:
        return {"status": "ERROR", "message": f"DDL failed: {e}", "ddl": create_ddl}

    user = session.sql("SELECT CURRENT_USER()").collect()[0][0]
    cat_db = v_cat
    session.sql(f"""
        INSERT INTO {cat_db}.SEMANTIC_CATALOG.AGMP_REGISTRY
        (view_catalog, view_schema, view_name, version_id, status, view_ddl, view_comment,
         source_tables, column_count, relationship_count, created_by, deployed_at)
        SELECT '{v_cat}','{v_sch}','{v_nm}',
               COALESCE((SELECT MAX(version_id) FROM {cat_db}.SEMANTIC_CATALOG.AGMP_REGISTRY
                         WHERE view_catalog='{v_cat}' AND view_schema='{v_sch}' AND view_name='{v_nm}'),0)+1,
               'DEPLOYED', $${create_ddl}$$, '{view_comment.replace(chr(39),chr(39)+chr(39))}',
               PARSE_JSON('{json.dumps(tables)}'),
               {len(classified_cols)}, {len(relationships) if relationships else 0},
               '{user}', CURRENT_TIMESTAMP()
    """).collect()

    version_id = session.sql(f"""
        SELECT MAX(version_id) AS V FROM {cat_db}.SEMANTIC_CATALOG.AGMP_REGISTRY
        WHERE view_catalog='{v_cat}' AND view_schema='{v_sch}' AND view_name='{v_nm}'
    """).collect()[0]["V"]

    for c in classified_cols:
        desc_escaped = c.get("ai_description","").replace("'","''")
        syns_json = json.dumps(c.get("synonyms", []))
        session.sql(f"""
            INSERT INTO {cat_db}.SEMANTIC_CATALOG.AGMP_COLUMNS
            (view_catalog, view_schema, view_name, version_id, source_table,
             column_name, data_type, semantic_role, ai_description, is_time_dimension, synonyms)
            VALUES('{v_cat}','{v_sch}','{v_nm}',{version_id},'{c["table"]}',
                   '{c["column"]}','{c.get("data_type","")}','{c.get("semantic_role","DIMENSION")}',
                   '{desc_escaped}',{c.get("is_time_dimension",False)},
                   PARSE_JSON('{syns_json}'))
        """).collect()

    if relationships:
        for rel in relationships:
            session.sql(f"""
                INSERT INTO {cat_db}.SEMANTIC_CATALOG.AGMP_RELATIONSHIPS
                (view_catalog, view_schema, view_name, version_id, parent_table, child_table,
                 join_type, join_keys, relationship_type)
                VALUES('{v_cat}','{v_sch}','{v_nm}',{version_id},
                       '{rel.get("parent_table","")}','{rel.get("child_table","")}',
                       '{rel.get("join_type","INNER")}',
                       PARSE_JSON('{json.dumps(rel.get("join_keys",[]))}'),
                       '{rel.get("relationship_type","ONE_TO_MANY")}')
            """).collect()

    return {
        "status": "OK",
        "view": target_view,
        "version_id": version_id,
        "tables": len(tables),
        "columns": len(classified_cols),
        "relationships": len(relationships) if relationships else 0,
        "ddl": create_ddl
    }
$$;

CREATE OR REPLACE PROCEDURE SP_AGMP_BUILD_END_TO_END(
    table_fqns ARRAY, hierarchy ARRAY, target_view VARCHAR, view_comment VARCHAR
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
EXECUTE AS CALLER
AS
$$
import json

def main(session, table_fqns, hierarchy, target_view, view_comment):
    desc_result = json.loads(session.sql(
        f"CALL SP_AGMP_DESCRIBE_TABLES(PARSE_JSON('{json.dumps(table_fqns)}'))"
    ).collect()[0][0])

    ai_desc = json.loads(session.sql(
        f"CALL SP_AGMP_GENERATE_AI_DESCRIPTIONS(PARSE_JSON('{json.dumps(table_fqns)}'))"
    ).collect()[0][0])

    classified = json.loads(session.sql(
        f"CALL SP_AGMP_CLASSIFY_COLUMNS(PARSE_JSON($${json.dumps(desc_result)}$$), "
        f"PARSE_JSON($${json.dumps(ai_desc)}$$))"
    ).collect()[0][0])

    relationships = []
    for i in range(len(hierarchy) - 1):
        parent = hierarchy[i]
        child = hierarchy[i+1]
        parent_cols = [c for c in desc_result if c["table"] == parent]
        child_cols = [c for c in desc_result if c["table"] == child]
        if parent_cols and child_cols:
            p_col_names = [c["name"] for c in parent_cols[0].get("columns",[])]
            c_col_names = [c["name"] for c in child_cols[0].get("columns",[])]
            join_keys = []
            for pc in p_col_names:
                if pc.endswith("KEY") or pc.endswith("_ID") or pc.endswith("_PK"):
                    base = pc.replace("_PK","").replace("_KEY","")
                    for cc in c_col_names:
                        if cc == pc or cc == base + "_FK" or cc == base + "_ID" or cc == pc.replace("_PK","_FK"):
                            join_keys.append({"parent_col": pc, "child_col": cc})
                            break
            if not join_keys:
                parent_short = parent.split(".")[-1]
                fk_candidate = parent_short + "KEY"
                for cc in c_col_names:
                    if fk_candidate.upper() in cc.upper().replace("_",""):
                        pk_candidates = [pc for pc in p_col_names if "KEY" in pc.upper() or "_ID" in pc.upper() or "_PK" in pc.upper()]
                        if pk_candidates:
                            join_keys.append({"parent_col": pk_candidates[0], "child_col": cc})
                            break
            if join_keys:
                relationships.append({
                    "parent_table": parent,
                    "child_table": child,
                    "join_type": "INNER",
                    "join_keys": join_keys,
                    "relationship_type": "ONE_TO_MANY"
                })

    ddl_text = session.sql(
        f"CALL SP_AGMP_GENERATE_DDL(PARSE_JSON($${json.dumps(classified)}$$))"
    ).collect()[0][0]

    final = json.loads(session.sql(
        f"CALL SP_AGMP_CREATE_AND_CATALOG('{target_view}', "
        f"'{view_comment.replace(chr(39), chr(39)+chr(39))}', "
        f"PARSE_JSON($${json.dumps(classified)}$$), "
        f"PARSE_JSON($${json.dumps(relationships)}$$), "
        f"$${ddl_text}$$)"
    ).collect()[0][0])

    return final
$$;

-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  STEP 4: STORED PROCEDURES - ENTITLEMENT & ACCESS                          ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

CREATE OR REPLACE PROCEDURE SP_AGMP_CHECK_ENTITLEMENT(view_fqn VARCHAR)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
EXECUTE AS CALLER
AS
$$
import json

def main(session, view_fqn):
    user = session.sql("SELECT CURRENT_USER()").collect()[0][0]
    try:
        grants_rows = session.sql(f"SHOW GRANTS ON SEMANTIC VIEW {view_fqn}").collect()
    except Exception as e:
        return {"status": "ERROR", "user": user, "view": view_fqn, "message": str(e)}

    user_roles_rows = session.sql("SHOW ROLES").collect()
    user_roles_count = len(user_roles_rows)

    granted_roles = set()
    for r in grants_rows:
        d = r.as_dict()
        priv = d.get("privilege","")
        grantee = d.get("grantee_name","")
        if priv in ("SELECT", "USAGE", "OWNERSHIP"):
            granted_roles.add(grantee)

    my_roles_rows = session.sql("SELECT CURRENT_AVAILABLE_ROLES() AS R").collect()
    try:
        my_roles = json.loads(my_roles_rows[0]["R"])
    except:
        my_roles = [session.sql("SELECT CURRENT_ROLE()").collect()[0][0]]

    entitled = bool(granted_roles.intersection(set(my_roles)))

    if not entitled:
        cat_db = view_fqn.split(".")[0]
        try:
            pending = session.sql(f"""
                SELECT COUNT(*) AS C FROM {cat_db}.SEMANTIC_CATALOG.AGMP_ACCESS_REQUESTS
                WHERE requestor_user = '{user}' AND status = 'PENDING'
                  AND view_catalog||'.'||view_schema||'.'||view_name = '{view_fqn}'
            """).collect()[0]["C"]
            if pending > 0:
                return {"status": "REQUEST_PENDING", "user": user, "view": view_fqn,
                        "roles_granted": list(granted_roles), "user_roles_count": user_roles_count}
        except:
            pass
        return {"status": "NOT_ENTITLED", "user": user, "view": view_fqn,
                "roles_granted": list(granted_roles), "user_roles_count": user_roles_count}

    return {"status": "ENTITLED", "user": user, "view": view_fqn,
            "roles_granted": list(granted_roles), "user_roles_count": user_roles_count}
$$;

CREATE OR REPLACE PROCEDURE SP_AGMP_REQUEST_ACCESS(view_fqn VARCHAR, justification VARCHAR, sensitivity_level VARCHAR)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
EXECUTE AS CALLER
AS
$$
import json

def main(session, view_fqn, justification, sensitivity_level):
    parts = view_fqn.split(".")
    if len(parts) != 3:
        return {"status": "ERROR", "message": "view_fqn must be DB.SCHEMA.NAME"}
    v_cat, v_sch, v_nm = parts
    user = session.sql("SELECT CURRENT_USER()").collect()[0][0]
    cat_db = v_cat

    existing = session.sql(f"""
        SELECT request_id FROM {cat_db}.SEMANTIC_CATALOG.AGMP_ACCESS_REQUESTS
        WHERE requestor_user='{user}' AND status='PENDING'
          AND view_catalog='{v_cat}' AND view_schema='{v_sch}' AND view_name='{v_nm}'
    """).collect()
    if existing:
        return {"status": "ALREADY_PENDING", "request_id": existing[0]["REQUEST_ID"],
                "requestor": user, "view": view_fqn}

    session.sql(f"""
        INSERT INTO {cat_db}.SEMANTIC_CATALOG.AGMP_ACCESS_REQUESTS
        (requestor_user, view_catalog, view_schema, view_name, sensitivity_level, justification, status)
        VALUES('{user}','{v_cat}','{v_sch}','{v_nm}',
               '{sensitivity_level or "MEDIUM"}',
               '{justification.replace(chr(39),chr(39)+chr(39))}','PENDING')
    """).collect()

    req = session.sql(f"""
        SELECT request_id FROM {cat_db}.SEMANTIC_CATALOG.AGMP_ACCESS_REQUESTS
        WHERE requestor_user='{user}' AND view_catalog='{v_cat}'
          AND view_schema='{v_sch}' AND view_name='{v_nm}'
        ORDER BY requested_at DESC LIMIT 1
    """).collect()
    request_id = req[0]["REQUEST_ID"] if req else None

    steward = "UNASSIGNED"
    try:
        dom = session.sql(f"""
            SELECT steward_user FROM {cat_db}.SEMANTIC_CATALOG.AGMP_DOMAINS
            WHERE view_catalog='{v_cat}' AND view_schema='{v_sch}' AND view_name='{v_nm}'
              AND steward_user IS NOT NULL LIMIT 1
        """).collect()
        if dom:
            steward = dom[0]["STEWARD_USER"]
    except:
        pass

    return {"status": "PENDING", "request_id": request_id, "requestor": user,
            "view": view_fqn, "steward": steward,
            "message": f"Access request submitted. Steward: {steward} will review."}
$$;

CREATE OR REPLACE PROCEDURE SP_AGMP_APPROVE_ACCESS(request_id NUMBER, grant_role VARCHAR, reviewer_notes VARCHAR)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
EXECUTE AS CALLER
AS
$$
import json

def main(session, request_id, grant_role, reviewer_notes):
    user = session.sql("SELECT CURRENT_USER()").collect()[0][0]
    db = session.sql("SELECT CURRENT_DATABASE()").collect()[0][0]
    req = session.sql(f"""
        SELECT view_catalog, view_schema, view_name, requestor_user, status
        FROM {db}.SEMANTIC_CATALOG.AGMP_ACCESS_REQUESTS
        WHERE request_id = {int(request_id)}
    """).collect()
    if not req:
        return {"status": "ERROR", "message": f"Request {request_id} not found"}
    r = req[0].as_dict()
    if r["STATUS"] != "PENDING":
        return {"status": "ERROR", "message": f"Request is already {r['STATUS']}"}

    view_fqn = f"{r['VIEW_CATALOG']}.{r['VIEW_SCHEMA']}.{r['VIEW_NAME']}"
    try:
        session.sql(f"GRANT SELECT ON SEMANTIC VIEW {view_fqn} TO ROLE {grant_role}").collect()
    except Exception as e:
        session.sql(f"""
            UPDATE {db}.SEMANTIC_CATALOG.AGMP_ACCESS_REQUESTS
            SET reviewer_notes = 'GRANT FAILED: {str(e).replace(chr(39),chr(39)+chr(39))}'
            WHERE request_id = {int(request_id)}
        """).collect()
        return {"status": "ERROR", "message": f"GRANT failed: {e}", "request_id": request_id}

    session.sql(f"""
        UPDATE {db}.SEMANTIC_CATALOG.AGMP_ACCESS_REQUESTS
        SET status='APPROVED', reviewed_by='{user}', reviewed_at=CURRENT_TIMESTAMP(),
            reviewer_notes='{(reviewer_notes or "").replace(chr(39),chr(39)+chr(39))}',
            granted_role='{grant_role}'
        WHERE request_id = {int(request_id)}
    """).collect()

    return {"status": "APPROVED", "request_id": request_id, "view": view_fqn,
            "granted_role": grant_role, "reviewer": user}
$$;

CREATE OR REPLACE PROCEDURE SP_AGMP_DENY_ACCESS(request_id NUMBER, reviewer_notes VARCHAR)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
EXECUTE AS CALLER
AS
$$
def main(session, request_id, reviewer_notes):
    user = session.sql("SELECT CURRENT_USER()").collect()[0][0]
    db = session.sql("SELECT CURRENT_DATABASE()").collect()[0][0]
    session.sql(f"""
        UPDATE {db}.SEMANTIC_CATALOG.AGMP_ACCESS_REQUESTS
        SET status='DENIED', reviewed_by='{user}', reviewed_at=CURRENT_TIMESTAMP(),
            reviewer_notes='{(reviewer_notes or "").replace(chr(39),chr(39)+chr(39))}'
        WHERE request_id = {int(request_id)} AND status='PENDING'
    """).collect()
    return {"status": "DENIED", "request_id": request_id, "reviewer": user}
$$;

-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  STEP 5: STORED PROCEDURES - DISCOVERY & DOMAINS                           ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

CREATE OR REPLACE PROCEDURE SP_AGMP_DISCOVER(intent_text VARCHAR)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
EXECUTE AS CALLER
AS
$$
import json, re

def main(session, intent_text):
    db = session.sql("SELECT CURRENT_DATABASE()").collect()[0][0]
    views = session.sql(f"""
        SELECT view_catalog||'.'||view_schema||'.'||view_name AS view_fqn,
               COALESCE(notes, '') AS view_comment, version_id
        FROM {db}.SEMANTIC_CATALOG.AGMP_REGISTRY
        WHERE status = 'DEPLOYED'
    """).collect()

    tokens = set(re.findall(r'\w+', intent_text.lower()))
    matches = []
    for v in views:
        d = v.as_dict()
        comment_lower = (d.get("VIEW_COMMENT","") or "").lower()
        score = 0
        matched_tokens = []
        for t in tokens:
            if t in comment_lower or len(t) > 3:
                cols = session.sql(f"""
                    SELECT column_name, ai_description
                    FROM {db}.SEMANTIC_CATALOG.AGMP_COLUMNS
                    WHERE view_catalog||'.'||view_schema||'.'||view_name = '{d["VIEW_FQN"]}'
                """).collect()
                for c in cols:
                    cd = c.as_dict()
                    col_text = (cd.get("COLUMN_NAME","") + " " + (cd.get("AI_DESCRIPTION","") or "")).lower()
                    if t in col_text:
                        score += 1
                        matched_tokens.append(t)
                        break
                if t in comment_lower:
                    score += 1
                    if t not in matched_tokens:
                        matched_tokens.append(t)
        domain = "Unknown"
        try:
            dom = session.sql(f"""
                SELECT COALESCE(human_confirmed_domain, ai_suggested_domain, 'Unknown') AS D
                FROM {db}.SEMANTIC_CATALOG.AGMP_DOMAINS
                WHERE view_catalog||'.'||view_schema||'.'||view_name = '{d["VIEW_FQN"]}'
                LIMIT 1
            """).collect()
            if dom:
                domain = dom[0]["D"]
        except:
            pass

        if score > 0:
            matches.append({
                "view_fqn": d["VIEW_FQN"],
                "domain": domain,
                "view_comment": d.get("VIEW_COMMENT",""),
                "match_score": score,
                "matched_tokens": list(set(matched_tokens))
            })

    matches.sort(key=lambda x: x["match_score"], reverse=True)
    return {"query": intent_text, "matches": matches[:5]}
$$;

CREATE OR REPLACE PROCEDURE SP_AGMP_SUGGEST_DOMAINS(view_fqn VARCHAR)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
EXECUTE AS CALLER
AS
$$
import json

def main(session, view_fqn):
    parts = view_fqn.split(".")
    if len(parts) != 3:
        return {"status": "ERROR", "message": "view_fqn must be DB.SCHEMA.NAME"}
    v_cat, v_sch, v_nm = parts

    cols = session.sql(f"""
        SELECT column_name, ai_description, source_table
        FROM {v_cat}.SEMANTIC_CATALOG.AGMP_COLUMNS
        WHERE view_catalog='{v_cat}' AND view_schema='{v_sch}' AND view_name='{v_nm}'
    """).collect()

    if not cols:
        return {"status": "ERROR", "message": "No columns found for this view"}

    col_summary = ", ".join([f"{c['COLUMN_NAME']} ({c.get('AI_DESCRIPTION','')[:50]})" for c in cols[:20]])
    tables = list(set([c["SOURCE_TABLE"] for c in cols]))
    prompt = (
        f"Given these database columns: [{col_summary}] from tables {tables}, "
        f"suggest a single business domain name (e.g. 'Finance', 'Supply Chain', 'Marketing', 'HR', 'Sales'). "
        f"Return ONLY the domain name, nothing else."
    )
    prompt_escaped = prompt.replace("'", "''")
    try:
        ai_row = session.sql(f"SELECT SNOWFLAKE.CORTEX.COMPLETE('mistral-large2', '{prompt_escaped}') AS D").collect()
        domain = ai_row[0]["D"].strip().strip('"').strip("'") if ai_row else "General"
    except:
        domain = "General"

    existing = session.sql(f"""
        SELECT domain_id FROM {v_cat}.SEMANTIC_CATALOG.AGMP_DOMAINS
        WHERE view_catalog='{v_cat}' AND view_schema='{v_sch}' AND view_name='{v_nm}'
    """).collect()

    if existing:
        session.sql(f"""
            UPDATE {v_cat}.SEMANTIC_CATALOG.AGMP_DOMAINS
            SET ai_suggested_domain='{domain}', ai_confidence_score=0.75
            WHERE view_catalog='{v_cat}' AND view_schema='{v_sch}' AND view_name='{v_nm}'
        """).collect()
    else:
        session.sql(f"""
            INSERT INTO {v_cat}.SEMANTIC_CATALOG.AGMP_DOMAINS
            (view_catalog, view_schema, view_name, ai_suggested_domain, ai_confidence_score, description)
            VALUES('{v_cat}','{v_sch}','{v_nm}','{domain}', 0.75,
                   'AI-suggested based on column analysis')
        """).collect()

    return {"status": "OK", "view": view_fqn, "suggested_domain": domain, "confidence": 0.75}
$$;

-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  STEP 6: USAGE ANALYTICS                                                   ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

CREATE OR REPLACE PROCEDURE SP_AGMP_AGGREGATE_USAGE()
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
EXECUTE AS CALLER
AS
$$
import json

def main(session):
    db = session.sql("SELECT CURRENT_DATABASE()").collect()[0][0]
    views = session.sql(f"""
        SELECT view_catalog, view_schema, view_name,
               view_catalog||'.'||view_schema||'.'||view_name AS fqn
        FROM {db}.SEMANTIC_CATALOG.AGMP_REGISTRY WHERE status='DEPLOYED'
    """).collect()

    processed = 0
    for v in views:
        d = v.as_dict()
        fqn = d["FQN"]
        try:
            usage = session.sql(f"""
                SELECT query_date, COUNT(*) AS query_count,
                       COUNT(DISTINCT user_name) AS unique_users
                FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
                WHERE query_text ILIKE '%{d["VIEW_NAME"]}%'
                  AND start_time >= DATEADD(day, -7, CURRENT_TIMESTAMP())
                GROUP BY query_date
            """).collect()
            for u in usage:
                ud = u.as_dict()
                session.sql(f"""
                    MERGE INTO {db}.SEMANTIC_CATALOG.AGMP_USAGE_ANALYTICS t
                    USING (SELECT '{d["VIEW_CATALOG"]}' AS vc, '{d["VIEW_SCHEMA"]}' AS vs,
                                  '{d["VIEW_NAME"]}' AS vn, '{ud["QUERY_DATE"]}' AS qd) s
                    ON t.view_catalog=s.vc AND t.view_schema=s.vs AND t.view_name=s.vn AND t.query_date=s.qd::DATE
                    WHEN MATCHED THEN UPDATE SET query_count={ud["QUERY_COUNT"]}, unique_users={ud["UNIQUE_USERS"]}
                    WHEN NOT MATCHED THEN INSERT (view_catalog,view_schema,view_name,query_date,query_count,unique_users)
                         VALUES(s.vc,s.vs,s.vn,s.qd::DATE,{ud["QUERY_COUNT"]},{ud["UNIQUE_USERS"]})
                """).collect()
            processed += 1
        except:
            pass
    return {"status": "OK", "views_processed": processed}
$$;

-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  STEP 7: UTILITY PROCEDURE - STAGE FILE WRITER                             ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

CREATE OR REPLACE PROCEDURE SP_WRITE_STAGE_FILE(
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

-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  STEP 8: STAGES & STREAMLIT APPS                                           ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

CREATE STAGE IF NOT EXISTS STREAMLIT_STAGE
  COMMENT = 'Hosts the SEMANTIC_VIEW_BUILDER Streamlit app'
  DIRECTORY = (ENABLE = TRUE);

CREATE STAGE IF NOT EXISTS AGMP_EXPLORER_STAGE
  COMMENT = 'Hosts the SEMANTIC_VIEW_EXPLORER Streamlit app'
  DIRECTORY = (ENABLE = TRUE);

-- NOTE: After running this script, deploy Streamlit app code using:
--
--   CALL SP_WRITE_STAGE_FILE(
--     '@STREAMLIT_STAGE', 'streamlit_app.py', $$<content>$$);
--
--   CALL SP_WRITE_STAGE_FILE(
--     '@AGMP_EXPLORER_STAGE', 'streamlit_app_explorer.py', $$<content>$$);
--
-- Then create the Streamlit objects:

CREATE OR REPLACE STREAMLIT AGMP_BUILDER
  FROM '@STREAMLIT_STAGE'
  MAIN_FILE = 'streamlit_app.py'
  QUERY_WAREHOUSE = COMPUTE_WH
  TITLE = 'AGMP Builder'
  COMMENT = 'Agentic Data Marketplace - semantic view lifecycle, governance, and catalog management';

CREATE OR REPLACE STREAMLIT AGMP_EXPLORER
  FROM '@AGMP_EXPLORER_STAGE'
  MAIN_FILE = 'streamlit_app_explorer.py'
  QUERY_WAREHOUSE = COMPUTE_WH
  TITLE = 'AGMP Explorer'
  COMMENT = 'Agentic Data Marketplace - Cortex Analyst NL Q&A and interactive query builder';

-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  STEP 9: CORTEX AGENT (uses $DB_NAME variable for FQN references)          ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

EXECUTE IMMEDIATE
$$
DECLARE
  db_name VARCHAR DEFAULT GETVARIABLE('DB_NAME');
  agent_ddl VARCHAR;
BEGIN
  agent_ddl := '
CREATE OR REPLACE AGENT SEMANTIC_MARKETPLACE_AGENT
  COMMENT = ''Agentic Data Marketplace - discovers semantic views, enforces entitlement, requests access on behalf of unauthorized users''
  PROFILE = ''{"display_name": "Data Marketplace Agent", "color": "blue"}''
  FROM SPECIFICATION
  $SPEC$
  models:
    orchestration: auto

  instructions:
    response: "Be concise and business-friendly. Always disclose the semantic view you used. If access was denied, never reveal data values - only describe the view purpose at a high level."
    orchestration: "For EVERY user question, FIRST call discover_semantic_views with the user''s intent text. Pick the highest-scoring match. THEN call check_entitlement with the matched view_fqn. NEVER skip this. If status is ENTITLED, use the agmp_analyst tool (Cortex Analyst) to answer the question against the matched view. If status is NOT_ENTITLED, do NOT attempt to answer. Tell the user the view they need access to, ask for a one-sentence justification, then call request_access. After the request, tell them the request_id and that the steward will review. If status is REQUEST_PENDING, tell the user their access request is already pending review. ALWAYS quote the view_fqn and domain so the user knows what data is being used."
    sample_questions:
      - question: "What data is available in the marketplace?"
      - question: "Show me analytics from AGMP"

  tools:
    - tool_spec:
        type: "custom_tool"
        name: "discover_semantic_views"
        description: "Discovers semantic views matching the user''s intent. ALWAYS call this first with the raw question as intent_text."
        input_schema:
          type: "object"
          properties:
            intent_text:
              type: "string"
              description: "The user''s natural-language question or topic of interest."
          required:
            - "intent_text"
    - tool_spec:
        type: "custom_tool"
        name: "check_entitlement"
        description: "Checks whether the current user is entitled to query a semantic view. ALWAYS call this second with the view_fqn from discover."
        input_schema:
          type: "object"
          properties:
            view_fqn:
              type: "string"
              description: "Fully qualified semantic view name in the form DB.SCHEMA.NAME."
          required:
            - "view_fqn"
    - tool_spec:
        type: "custom_tool"
        name: "request_access"
        description: "Submits an access request for a semantic view. ONLY call if check_entitlement returns NOT_ENTITLED."
        input_schema:
          type: "object"
          properties:
            view_fqn:
              type: "string"
              description: "Fully qualified semantic view name."
            justification:
              type: "string"
              description: "One-sentence business justification."
            sensitivity_level:
              type: "string"
              description: "LOW, MEDIUM, HIGH, or PII."
          required:
            - "view_fqn"
            - "justification"
    - tool_spec:
        type: "cortex_analyst_text_to_sql"
        name: "agmp_analyst"
        description: "Answers analytical questions using Cortex Analyst against the AGMP semantic view. ONLY call if check_entitlement returns ENTITLED."

  tool_resources:
    discover_semantic_views:
      procedure_name: "' || :db_name || '.PUBLIC.SP_AGMP_DISCOVER"
      warehouse: "COMPUTE_WH"
    check_entitlement:
      procedure_name: "' || :db_name || '.PUBLIC.SP_AGMP_CHECK_ENTITLEMENT"
      warehouse: "COMPUTE_WH"
    request_access:
      procedure_name: "' || :db_name || '.PUBLIC.SP_AGMP_REQUEST_ACCESS"
      warehouse: "COMPUTE_WH"
    agmp_analyst:
      semantic_view: "' || :db_name || '.PUBLIC.AGMP"
  $SPEC$';

  EXECUTE IMMEDIATE agent_ddl;
  RETURN 'Agent SEMANTIC_MARKETPLACE_AGENT created in ' || :db_name;
END;
$$;

-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  DEPLOYMENT COMPLETE                                                       ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝
-- Next steps:
-- 1. Upload streamlit_app.py to STREAMLIT_STAGE (see STEP 8 comment)
-- 2. Upload streamlit_app_explorer.py to AGMP_EXPLORER_STAGE
-- 3. Build your first semantic view:
--    CALL SP_AGMP_BUILD_END_TO_END(
--      ARRAY_CONSTRUCT('DB.SCHEMA.TABLE1', 'DB.SCHEMA.TABLE2'),
--      ARRAY_CONSTRUCT('DB.SCHEMA.TABLE1', 'DB.SCHEMA.TABLE2'),
--      '<YOUR_DB>.PUBLIC.AGMP',
--      'Your semantic view description'
--    );
-- 4. Test: CALL SP_AGMP_CHECK_ENTITLEMENT('<YOUR_DB>.PUBLIC.AGMP')

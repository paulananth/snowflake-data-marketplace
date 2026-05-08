-- =============================================================================
-- Agentic Data Marketplace - Phase 1 Foundation Deployment Script
-- Idempotent - safe to run multiple times
-- =============================================================================
-- Creates:
--   1. MY_DB database + SEMANTIC_CATALOG and PUBLIC schemas
--   2. 9 catalog tables (mirrors INFORMATION_SCHEMA pattern)
--   3. 5 core stored procedures + 1 master orchestrator
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Database & Schemas
-- -----------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS MY_DB;
CREATE SCHEMA   IF NOT EXISTS MY_DB.SEMANTIC_CATALOG;
CREATE SCHEMA   IF NOT EXISTS MY_DB.PUBLIC;

-- -----------------------------------------------------------------------------
-- 2. Catalog Tables (INFORMATION_SCHEMA-style)
-- -----------------------------------------------------------------------------

-- 2.1 SV_REGISTRY - CI/CD state machine
CREATE TABLE IF NOT EXISTS MY_DB.SEMANTIC_CATALOG.SV_REGISTRY (
  view_catalog        VARCHAR,
  view_schema         VARCHAR,
  view_name           VARCHAR,
  version_id          NUMBER AUTOINCREMENT,
  version_tag         VARCHAR,
  status              VARCHAR,    -- DRAFT|TESTING|PENDING_APPROVAL|DEPLOYED|ARCHIVED|REJECTED
  view_ddl            VARCHAR,
  test_score          FLOAT,
  created_by          VARCHAR DEFAULT CURRENT_USER(),
  approved_by         VARCHAR,
  created_at          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  deployed_at         TIMESTAMP_NTZ,
  archived_at         TIMESTAMP_NTZ,
  notes               VARCHAR
);

-- 2.2 SV_COLUMNS - Dual-description pattern (human always wins via COALESCE)
CREATE TABLE IF NOT EXISTS MY_DB.SEMANTIC_CATALOG.SV_COLUMNS (
  view_catalog          VARCHAR,
  view_schema           VARCHAR,
  view_name             VARCHAR,
  version_id            NUMBER,
  source_table          VARCHAR,
  column_name           VARCHAR,
  data_type             VARCHAR,
  ordinal_position      NUMBER,
  semantic_role         VARCHAR,    -- DIMENSION|FACT|METRIC
  ai_description        VARCHAR,
  human_description     VARCHAR,
  effective_description VARCHAR AS (COALESCE(human_description, ai_description)),
  description_source    VARCHAR,    -- AI_GENERATED|HUMAN_EDITED
  is_time_dimension     BOOLEAN DEFAULT FALSE,
  time_grain            VARCHAR,
  last_edited_by        VARCHAR,
  last_edited_at        TIMESTAMP_NTZ
);

-- 2.3 SV_RELATIONSHIPS
CREATE TABLE IF NOT EXISTS MY_DB.SEMANTIC_CATALOG.SV_RELATIONSHIPS (
  view_catalog        VARCHAR,
  view_schema         VARCHAR,
  view_name           VARCHAR,
  version_id          NUMBER,
  from_table          VARCHAR,
  from_column         VARCHAR,
  to_table            VARCHAR,
  to_column           VARCHAR,
  relationship_type   VARCHAR,
  is_inferred         BOOLEAN,
  confidence_score    FLOAT
);

-- 2.4 SV_TEST_RESULTS
CREATE TABLE IF NOT EXISTS MY_DB.SEMANTIC_CATALOG.SV_TEST_RESULTS (
  test_run_id         NUMBER AUTOINCREMENT,
  view_catalog        VARCHAR,
  view_schema         VARCHAR,
  view_name           VARCHAR,
  version_id          NUMBER,
  test_type           VARCHAR,    -- VERIFIED_QUERY_REGRESSION|METRIC_SANITY|CORTEX_ANALYST_AB
  test_name           VARCHAR,
  status              VARCHAR,    -- PASS|FAIL|WARNING
  score               FLOAT,
  details             VARIANT,
  run_at              TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- 2.5 SV_ANALYST_FEEDBACK
CREATE TABLE IF NOT EXISTS MY_DB.SEMANTIC_CATALOG.SV_ANALYST_FEEDBACK (
  feedback_id         NUMBER AUTOINCREMENT,
  view_catalog        VARCHAR,
  view_schema         VARCHAR,
  view_name           VARCHAR,
  version_id          NUMBER,
  query_text          VARCHAR,
  query_id            VARCHAR,
  answered            BOOLEAN,
  human_score         NUMBER(2,1),
  recorded_at         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- 2.6 SV_DOMAINS
CREATE TABLE IF NOT EXISTS MY_DB.SEMANTIC_CATALOG.SV_DOMAINS (
  domain_id               NUMBER AUTOINCREMENT,
  domain_name             VARCHAR,
  parent_domain           VARCHAR,
  description             VARCHAR,
  view_catalog            VARCHAR,
  view_schema             VARCHAR,
  view_name               VARCHAR,
  ai_suggested_domain     VARCHAR,
  ai_confidence_score     FLOAT,
  human_confirmed_domain  VARCHAR,
  confirmed_by            VARCHAR,
  confirmed_at            TIMESTAMP_NTZ,
  steward_user            VARCHAR,
  steward_role            VARCHAR
);

-- 2.7 SV_GLOSSARY
CREATE TABLE IF NOT EXISTS MY_DB.SEMANTIC_CATALOG.SV_GLOSSARY (
  term                  VARCHAR,
  canonical_definition  VARCHAR,
  domain_id             NUMBER,
  applies_to_views      ARRAY,
  conflicting_terms     ARRAY,
  created_by            VARCHAR DEFAULT CURRENT_USER(),
  last_updated          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- 2.8 SV_ACCESS_REQUESTS
CREATE TABLE IF NOT EXISTS MY_DB.SEMANTIC_CATALOG.SV_ACCESS_REQUESTS (
  request_id                NUMBER AUTOINCREMENT,
  requestor_user            VARCHAR,
  view_catalog              VARCHAR,
  view_schema               VARCHAR,
  view_name                 VARCHAR,
  justification             VARCHAR,
  sensitivity_level         VARCHAR,
  status                    VARCHAR,    -- PENDING|APPROVED|DENIED|EXPIRED
  requested_at              TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  reviewed_by               VARCHAR,
  reviewed_at               TIMESTAMP_NTZ,
  reviewer_notes            VARCHAR,
  snowflake_grant_executed  BOOLEAN DEFAULT FALSE
);

-- 2.9 SV_USAGE_ANALYTICS
CREATE TABLE IF NOT EXISTS MY_DB.SEMANTIC_CATALOG.SV_USAGE_ANALYTICS (
  view_catalog        VARCHAR,
  view_schema         VARCHAR,
  view_name           VARCHAR,
  version_id          NUMBER,
  query_date          DATE,
  query_count         NUMBER,
  unique_users        NUMBER,
  answered_count      NUMBER,
  unanswered_count    NUMBER,
  avg_human_score     FLOAT
);

-- -----------------------------------------------------------------------------
-- 3. Stored Procedures
-- -----------------------------------------------------------------------------

-- 3.1 SP_SV_DESCRIBE_TABLES - DESCRIBE TABLE for each input
CREATE OR REPLACE PROCEDURE MY_DB.PUBLIC.SP_SV_DESCRIBE_TABLES(table_list ARRAY)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
AS
$$
def main(session, table_list):
    result = {}
    for fqn in table_list:
        rows = session.sql(f"DESCRIBE TABLE {fqn}").collect()
        cols = []
        for r in rows:
            d = r.as_dict()
            cols.append({
                'name':       d.get('name'),
                'type':       d.get('type'),
                'kind':       d.get('kind'),
                'null':       d.get('null?'),
                'primary_key':d.get('primary key'),
                'unique_key': d.get('unique key'),
                'comment':    d.get('comment')
            })
        result[fqn] = cols
    return result
$$;

-- 3.2 SP_SV_GENERATE_AI_DESCRIPTIONS - calls AI_GENERATE_TABLE_DESC
CREATE OR REPLACE PROCEDURE MY_DB.PUBLIC.SP_SV_GENERATE_AI_DESCRIPTIONS(table_list ARRAY)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
AS
$$
import json

def main(session, table_list):
    out = {}
    for fqn in table_list:
        try:
            sql = f"SELECT AI_GENERATE_TABLE_DESC('{fqn}', {{'describe_columns': TRUE, 'use_table_data': FALSE}})"
            row = session.sql(sql).collect()[0]
            raw = row[0]
            data = json.loads(raw) if isinstance(raw, str) else raw
            out[fqn] = data
        except Exception as e:
            out[fqn] = {'error': str(e), 'description': None, 'columns': {}}
    return out
$$;

-- 3.3 SP_SV_CLASSIFY_COLUMNS - heuristic role assignment
CREATE OR REPLACE PROCEDURE MY_DB.PUBLIC.SP_SV_CLASSIFY_COLUMNS(table_metadata VARIANT, ai_descriptions VARIANT)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
AS
$$
def is_numeric(t):
    t = (t or '').upper()
    return any(k in t for k in ['NUMBER','DECIMAL','NUMERIC','INT','FLOAT','DOUBLE','REAL'])

def is_string(t):
    t = (t or '').upper()
    return any(k in t for k in ['VARCHAR','CHAR','TEXT','STRING'])

def is_date(t):
    t = (t or '').upper()
    return any(k in t for k in ['DATE','TIMESTAMP','TIME'])

def classify(col_name, data_type, is_pk):
    n = (col_name or '').lower()
    role = 'DIMENSION'
    is_time = False
    if is_pk or n.endswith('_id') or n.endswith('_key') or n.endswith('key') or n == 'id':
        role = 'DIMENSION'
    elif is_date(data_type):
        role = 'DIMENSION'; is_time = True
    elif is_string(data_type):
        role = 'DIMENSION'
    elif is_numeric(data_type):
        if any(p in n for p in ['price','amt','amount','cost','revenue','rev','sales','balance','value','total']):
            role = 'METRIC'
        elif any(p in n for p in ['qty','quantity','cnt','count','num','volume']):
            role = 'METRIC'
        elif any(p in n for p in ['rate','ratio','pct','percent','discount','tax']):
            role = 'FACT'
        else:
            role = 'FACT'
    return role, is_time

def main(session, table_metadata, ai_descriptions):
    out = []
    for fqn, cols in table_metadata.items():
        ai_block = (ai_descriptions or {}).get(fqn, {}) or {}
        ai_cols = {}
        if isinstance(ai_block, dict):
            cols_field = ai_block.get('columns') or ai_block.get('column_descriptions') or {}
            if isinstance(cols_field, dict):
                ai_cols = {k.upper(): v for k, v in cols_field.items()}
            elif isinstance(cols_field, list):
                for c in cols_field:
                    if isinstance(c, dict):
                        nm = (c.get('name') or c.get('column_name') or '').upper()
                        ai_cols[nm] = c.get('description') or c.get('comment')
        ord_pos = 0
        for c in cols:
            ord_pos += 1
            cname = c.get('name')
            dtype = c.get('type')
            is_pk = (c.get('primary_key') or '').upper() == 'Y' if c.get('primary_key') else False
            role, is_time = classify(cname, dtype, is_pk)
            ai_desc = ai_cols.get((cname or '').upper())
            if isinstance(ai_desc, dict):
                ai_desc = ai_desc.get('description') or ai_desc.get('comment')
            out.append({
                'source_table': fqn,
                'column_name': cname,
                'data_type': dtype,
                'ordinal_position': ord_pos,
                'semantic_role': role,
                'is_time_dimension': is_time,
                'ai_description': ai_desc,
                'is_primary_key': is_pk
            })
    return out
$$;

-- 3.4 SP_SV_GENERATE_DDL - composes CREATE SEMANTIC VIEW DDL
CREATE OR REPLACE PROCEDURE MY_DB.PUBLIC.SP_SV_GENERATE_DDL(config VARIANT)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
AS
$$
def esc(s):
    if s is None: return ''
    return str(s).replace("'", "''")

def short_alias(fqn):
    return fqn.split('.')[-1]

def main(session, config):
    target_view  = config['target_view']
    tables       = config['tables']
    classifications = config['classifications']
    relationships   = config.get('relationships', [])
    verified_qs     = config.get('verified_queries', [])
    view_comment    = config.get('view_comment', '')

    by_table = {}
    for c in classifications:
        by_table.setdefault(c['source_table'], []).append(c)

    table_lines = []
    for t in tables:
        alias = short_alias(t)
        pks = [c['column_name'] for c in by_table.get(t, []) if c.get('is_primary_key')]
        pk_clause = f"PRIMARY KEY ({', '.join(pks)})" if pks else ''
        table_lines.append(f"  {alias} AS {t}{(' ' + pk_clause) if pk_clause else ''}")
    tables_block = "TABLES (\n" + ",\n".join(table_lines) + "\n  )"

    rel_lines = []
    for i, r in enumerate(relationships):
        rel_lines.append(f"  rel_{i} AS {short_alias(r['from_table'])} ({r['from_column']}) REFERENCES {short_alias(r['to_table'])} ({r['to_column']})")
    rel_block = ("RELATIONSHIPS (\n" + ",\n".join(rel_lines) + "\n  )") if rel_lines else ''

    facts, dims, metrics = [], [], []
    for c in classifications:
        alias = short_alias(c['source_table'])
        col   = c['column_name']
        desc  = (c.get('ai_description') or '').replace("'", "''")[:1000]
        comment = f" COMMENT = '{desc}'" if desc else ''
        role  = c['semantic_role']
        if role == 'FACT':
            facts.append(f"  {alias}.{col.lower()} AS {col}{comment}")
        elif role == 'METRIC':
            n = col.lower()
            agg = 'SUM' if any(p in n for p in ['price','amt','amount','cost','revenue','sales','quantity','qty','cnt','count','volume','total','balance']) else 'AVG'
            metrics.append(f"  {alias}.{col.lower()}_{agg.lower()} AS {agg}({alias}.{col}){comment}")
        else:
            dims.append(f"  {alias}.{col.lower()} AS {col}{comment}")
            if c.get('is_time_dimension'):
                dims.append(f"  {alias}.{col.lower()}_year     AS YEAR({alias}.{col})")
                dims.append(f"  {alias}.{col.lower()}_month    AS DATE_TRUNC('month',   {alias}.{col})")
                dims.append(f"  {alias}.{col.lower()}_quarter  AS DATE_TRUNC('quarter', {alias}.{col})")

    facts_block   = ("FACTS (\n"      + ",\n".join(facts)   + "\n  )") if facts else ''
    dims_block    = ("DIMENSIONS (\n" + ",\n".join(dims)    + "\n  )") if dims  else ''
    metrics_block = ("METRICS (\n"    + ",\n".join(metrics) + "\n  )") if metrics else ''

    vq_lines = []
    for vq in verified_qs:
        nm = esc(vq['name']); q = esc(vq['question']); s = esc(vq['sql'])
        onb = "ONBOARDING_QUESTION TRUE" if vq.get('onboarding') else ''
        vq_lines.append(f"  ('{nm}', '{q}', '{s}'{(' ' + onb) if onb else ''})")
    vq_block = ("AI_VERIFIED_QUERIES (\n" + ",\n".join(vq_lines) + "\n  )") if vq_lines else ''

    parts = [p for p in [tables_block, rel_block, facts_block, dims_block, metrics_block, vq_block] if p]
    body = "\n  ".join(parts)
    cmt = f"\nCOMMENT = '{esc(view_comment)}'" if view_comment else ''
    return f"CREATE OR REPLACE SEMANTIC VIEW {target_view}\n  {body}{cmt}"
$$;

-- 3.5 SP_SV_CREATE_AND_CATALOG - executes DDL + populates catalog
CREATE OR REPLACE PROCEDURE MY_DB.PUBLIC.SP_SV_CREATE_AND_CATALOG(
  target_view VARCHAR,
  ddl VARCHAR,
  classifications VARIANT,
  relationships VARIANT,
  view_comment VARCHAR
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
AS
$$
def main(session, target_view, ddl, classifications, relationships, view_comment):
    parts = target_view.split('.')
    cat, sch, nm = parts[0], parts[1], parts[2]

    session.sql(ddl).collect()

    session.sql(
        "INSERT INTO MY_DB.SEMANTIC_CATALOG.SV_REGISTRY "
        "(view_catalog, view_schema, view_name, version_tag, status, view_ddl, deployed_at, notes) "
        "SELECT ?, ?, ?, 'v1.0', 'DEPLOYED', ?, CURRENT_TIMESTAMP(), ?",
        params=[cat, sch, nm, ddl, view_comment or '']
    ).collect()

    vid_row = session.sql(
        "SELECT MAX(version_id) AS vid FROM MY_DB.SEMANTIC_CATALOG.SV_REGISTRY "
        "WHERE view_catalog=? AND view_schema=? AND view_name=?",
        params=[cat, sch, nm]
    ).collect()
    version_id = vid_row[0]['VID']

    for c in classifications:
        session.sql(
            "INSERT INTO MY_DB.SEMANTIC_CATALOG.SV_COLUMNS "
            "(view_catalog, view_schema, view_name, version_id, source_table, "
            " column_name, data_type, ordinal_position, semantic_role, "
            " ai_description, description_source, is_time_dimension) "
            "SELECT ?,?,?,?,?,?,?,?,?,?,?,?",
            params=[cat, sch, nm, version_id,
                    c.get('source_table'), c.get('column_name'),
                    c.get('data_type'), c.get('ordinal_position') or 0,
                    c.get('semantic_role'),
                    c.get('ai_description') or '', 'AI_GENERATED',
                    bool(c.get('is_time_dimension'))]
        ).collect()

    for r in (relationships or []):
        session.sql(
            "INSERT INTO MY_DB.SEMANTIC_CATALOG.SV_RELATIONSHIPS "
            "(view_catalog, view_schema, view_name, version_id, "
            " from_table, from_column, to_table, to_column, "
            " relationship_type, is_inferred, confidence_score) "
            "SELECT ?,?,?,?,?,?,?,?,?,?,?",
            params=[cat, sch, nm, version_id,
                    r['from_table'], r['from_column'],
                    r['to_table'], r['to_column'],
                    'FK', bool(r.get('is_inferred', True)),
                    float(r.get('confidence_score', 0.9))]
        ).collect()

    return {'status': 'DEPLOYED', 'version_id': version_id, 'view': target_view}
$$;

-- 3.6 SP_SV_BUILD_END_TO_END - master orchestration (inlined for cross-proc safety)
CREATE OR REPLACE PROCEDURE MY_DB.PUBLIC.SP_SV_BUILD_END_TO_END(
  table_list ARRAY,
  hierarchy ARRAY,
  target_view VARCHAR,
  view_comment VARCHAR
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
AS
$$
def short(fqn):
    return fqn.split('.')[-1]

def is_numeric(t):
    t=(t or '').upper()
    return any(k in t for k in ['NUMBER','DECIMAL','NUMERIC','INT','FLOAT','DOUBLE','REAL'])

def is_string(t):
    t=(t or '').upper()
    return any(k in t for k in ['VARCHAR','CHAR','TEXT','STRING'])

def is_date(t):
    t=(t or '').upper()
    return any(k in t for k in ['DATE','TIMESTAMP','TIME'])

def classify(col_name, data_type, is_pk):
    n=(col_name or '').lower()
    role,is_time='DIMENSION',False
    if is_pk or n.endswith('_id') or n.endswith('_key') or n.endswith('key'):
        role='DIMENSION'
    elif is_date(data_type):
        role,is_time='DIMENSION',True
    elif is_string(data_type):
        role='DIMENSION'
    elif is_numeric(data_type):
        if any(p in n for p in ['price','amt','amount','cost','revenue','rev','sales','balance','value','total']):
            role='METRIC'
        elif any(p in n for p in ['qty','quantity','cnt','count','volume']):
            role='METRIC'
        else:
            role='FACT'
    return role,is_time

def esc(s):
    return ('' if s is None else str(s)).replace("'","''")

def key_suffix(col):
    parts=col.split('_',1)
    return parts[1] if len(parts)>1 else col

def main(session, table_list, hierarchy, target_view, view_comment):
    metadata={}
    for fqn in table_list:
        rows=session.sql(f"DESCRIBE TABLE {fqn}").collect()
        cols=[]
        for r in rows:
            d=r.as_dict()
            cols.append({'name':d.get('name'),'type':d.get('type'),
                         'null':d.get('null?'),'primary_key':d.get('primary key')})
        metadata[fqn]=cols

    classifications=[]
    by_table={}
    for fqn in table_list:
        ord_pos=0
        for c in metadata[fqn]:
            ord_pos+=1
            cname,dtype=c['name'],c['type']
            is_pk=(c.get('primary_key') or '').upper()=='Y'
            role,is_time=classify(cname,dtype,is_pk)
            entry={'source_table':fqn,'column_name':cname,'data_type':dtype,
                   'ordinal_position':ord_pos,'semantic_role':role,
                   'is_time_dimension':is_time,'ai_description':'',
                   'is_primary_key':is_pk}
            classifications.append(entry)
            by_table.setdefault(fqn,[]).append(entry)

    for tbl,cols in by_table.items():
        if not any(c.get('is_primary_key') for c in cols):
            for c in cols:
                if c['column_name'].upper().endswith('KEY') and 'NUMBER' in (c.get('data_type') or '').upper():
                    c['is_primary_key']=True; break

    relationships=[]
    for i in range(len(hierarchy)-1):
        parent=hierarchy[i]; child=hierarchy[i+1]
        parent_pk=next((c['column_name'] for c in by_table.get(parent,[]) if c.get('is_primary_key')),None)
        child_fk=None
        if parent_pk:
            suffix=key_suffix(parent_pk).upper()
            for c in by_table.get(child,[]):
                if c['column_name'].upper().endswith(suffix) or c['column_name'].upper()==parent_pk.upper():
                    child_fk=c['column_name']; break
        if parent_pk and child_fk:
            relationships.append({'from_table':child,'from_column':child_fk,
                                  'to_table':parent,'to_column':parent_pk,
                                  'is_inferred':True,'confidence_score':0.95})

    table_lines=[]
    for t in hierarchy:
        alias=short(t)
        pks=[c['column_name'] for c in by_table.get(t,[]) if c.get('is_primary_key')]
        pk_clause=f" PRIMARY KEY ({', '.join(pks)})" if pks else ''
        table_lines.append(f"  {alias} AS {t}{pk_clause}")
    tables_block="TABLES (\n"+",\n".join(table_lines)+"\n  )"

    rel_lines=[]
    for i,r in enumerate(relationships):
        rel_lines.append(f"  rel_{i} AS {short(r['from_table'])} ({r['from_column']}) REFERENCES {short(r['to_table'])} ({r['to_column']})")
    rel_block=("RELATIONSHIPS (\n"+",\n".join(rel_lines)+"\n  )") if rel_lines else ''

    facts,dims,metrics=[],[],[]
    for c in classifications:
        alias=short(c['source_table']); col=c['column_name']; role=c['semantic_role']
        if role=='FACT':
            facts.append(f"  {alias}.{col.lower()} AS {col}")
        elif role=='METRIC':
            metrics.append(f"  {alias}.{col.lower()}_sum AS SUM({alias}.{col})")
        else:
            dims.append(f"  {alias}.{col.lower()} AS {col}")
            if c.get('is_time_dimension'):
                dims.append(f"  {alias}.{col.lower()}_year     AS YEAR({alias}.{col})")
                dims.append(f"  {alias}.{col.lower()}_month    AS DATE_TRUNC('month',   {alias}.{col})")
                dims.append(f"  {alias}.{col.lower()}_quarter  AS DATE_TRUNC('quarter', {alias}.{col})")

    facts_block=("FACTS (\n"+",\n".join(facts)+"\n  )") if facts else ''
    dims_block=("DIMENSIONS (\n"+",\n".join(dims)+"\n  )") if dims else ''
    metrics_block=("METRICS (\n"+",\n".join(metrics)+"\n  )") if metrics else ''

    parts=[p for p in [tables_block,rel_block,facts_block,dims_block,metrics_block] if p]
    body="\n  ".join(parts)
    cmt=f"\n  COMMENT = '{esc(view_comment)}'" if view_comment else ''
    ddl=f"CREATE OR REPLACE SEMANTIC VIEW {target_view}\n  {body}{cmt}"

    session.sql(ddl).collect()

    parts3=target_view.split('.')
    cat,sch,nm=parts3[0],parts3[1],parts3[2]

    session.sql("DELETE FROM MY_DB.SEMANTIC_CATALOG.SV_REGISTRY WHERE view_catalog=? AND view_schema=? AND view_name=?",params=[cat,sch,nm]).collect()
    session.sql("DELETE FROM MY_DB.SEMANTIC_CATALOG.SV_COLUMNS WHERE view_catalog=? AND view_schema=? AND view_name=?",params=[cat,sch,nm]).collect()
    session.sql("DELETE FROM MY_DB.SEMANTIC_CATALOG.SV_RELATIONSHIPS WHERE view_catalog=? AND view_schema=? AND view_name=?",params=[cat,sch,nm]).collect()

    session.sql("INSERT INTO MY_DB.SEMANTIC_CATALOG.SV_REGISTRY "
                "(view_catalog,view_schema,view_name,version_tag,status,view_ddl,deployed_at,notes) "
                "SELECT ?,?,?,'v1.0','DEPLOYED',?,CURRENT_TIMESTAMP(),?",
                params=[cat,sch,nm,ddl,view_comment or '']).collect()

    vid=session.sql("SELECT MAX(version_id) FROM MY_DB.SEMANTIC_CATALOG.SV_REGISTRY WHERE view_catalog=? AND view_schema=? AND view_name=?",
                    params=[cat,sch,nm]).collect()[0][0]

    for c in classifications:
        session.sql("INSERT INTO MY_DB.SEMANTIC_CATALOG.SV_COLUMNS "
                    "(view_catalog,view_schema,view_name,version_id,source_table,column_name,data_type,"
                    " ordinal_position,semantic_role,ai_description,description_source,is_time_dimension) "
                    "SELECT ?,?,?,?,?,?,?,?,?,?,?,?",
                    params=[cat,sch,nm,vid,c['source_table'],c['column_name'],c['data_type'],
                            c['ordinal_position'],c['semantic_role'],'','AI_GENERATED',
                            bool(c.get('is_time_dimension'))]).collect()

    for r in relationships:
        session.sql("INSERT INTO MY_DB.SEMANTIC_CATALOG.SV_RELATIONSHIPS "
                    "(view_catalog,view_schema,view_name,version_id,from_table,from_column,to_table,to_column,"
                    " relationship_type,is_inferred,confidence_score) "
                    "SELECT ?,?,?,?,?,?,?,?,?,?,?",
                    params=[cat,sch,nm,vid,r['from_table'],r['from_column'],r['to_table'],r['to_column'],
                            'FK',True,float(r['confidence_score'])]).collect()

    return {'status':'OK','target_view':target_view,'version_id':vid,
            'tables':len(metadata),'columns':len(classifications),
            'relationships':len(relationships),'relationships_detail':relationships,'ddl':ddl}
$$;

-- =============================================================================
-- USAGE EXAMPLE: Build the TPC-H semantic view end-to-end
-- =============================================================================
-- CALL MY_DB.PUBLIC.SP_SV_BUILD_END_TO_END(
--   ARRAY_CONSTRUCT(
--     'SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.CUSTOMER',
--     'SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.ORDERS',
--     'SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.LINEITEM'
--   ),
--   ARRAY_CONSTRUCT(
--     'SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.CUSTOMER',
--     'SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.ORDERS',
--     'SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.LINEITEM'
--   ),
--   'MY_DB.PUBLIC.TPCH_ANALYSIS_VIEW',
--   'TPC-H semantic view: customer-orders-lineitem hierarchy'
-- );

-- Sample query against the resulting semantic view:
-- SELECT * FROM SEMANTIC_VIEW(
--   MY_DB.PUBLIC.TPCH_ANALYSIS_VIEW
--   DIMENSIONS C_MKTSEGMENT, O_ORDERDATE_YEAR
--   METRICS L_EXTENDEDPRICE_SUM, L_QUANTITY_SUM
-- ) ORDER BY 1, 2;

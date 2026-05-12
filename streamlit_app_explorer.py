"""Semantic View Explorer v3 - Cortex Analyst NL Q&A + interactive query builder.

Deployed to: @<DB>.PUBLIC.AGMP_EXPLORER_STAGE/streamlit_app.py
Streamlit object: <DB>.PUBLIC.SEMANTIC_VIEW_EXPLORER
"""
import json
import pandas as pd
import requests
import streamlit as st
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="Semantic View Explorer", page_icon=":mag:", layout="wide")
session = get_active_session()
DB = session.sql("SELECT CURRENT_DATABASE()").collect()[0][0]
CATALOG = f"{DB}.SEMANTIC_CATALOG"
PUBLIC = f"{DB}.PUBLIC"

# ---------- helpers ----------
def collect_rows(sql, params=None):
    rows = session.sql(sql, params=params).collect() if params else session.sql(sql).collect()
    return [r.as_dict() for r in rows]

def df(sql, params=None):
    data = collect_rows(sql, params=params)
    if not data:
        return pd.DataFrame()
    pdf = pd.DataFrame(data)
    pdf.columns = [str(c).upper() for c in pdf.columns]
    return pdf

def get_user():
    return session.sql("SELECT CURRENT_USER() AS U").collect()[0]["U"]

def log_feedback(view_fqn, query_text, answered, query_id=None, score=None):
    cat, sch, nm = view_fqn.split(".")
    try:
        session.sql(
            f"INSERT INTO {CATALOG}.AGMP_ANALYST_FEEDBACK "
            f"(view_catalog, view_schema, view_name, version_id, query_text, query_id, answered, human_score) "
            f"SELECT ?,?,?,(SELECT MAX(version_id) FROM {CATALOG}.AGMP_REGISTRY "
            f"             WHERE view_catalog=? AND view_schema=? AND view_name=?), "
            f"       ?,?,?,?",
            params=[cat, sch, nm, cat, sch, nm, query_text, query_id, answered, score]
        ).collect()
    except Exception:
        pass

# ---------- Cortex Analyst REST call ----------
def call_cortex_analyst(question, semantic_view_fqn):
    """Calls /api/v2/cortex/analyst/message from inside SiS using the active session token."""
    conn = session._connection
    host = conn.host
    token = conn.rest.token
    body = {
        "messages": [{"role":"user","content":[{"type":"text","text": question}]}],
        "semantic_view": semantic_view_fqn,
        "stream": False
    }
    r = requests.post(
        f"https://{host}/api/v2/cortex/analyst/message",
        headers={
            "Authorization": f'Snowflake Token="{token}"',
            "Content-Type":"application/json",
            "Accept":"application/json"
        },
        json=body, timeout=60
    )
    return r.status_code, r.text

# ---------- header ----------
st.title(":mag: Semantic View Explorer")
st.caption(f"Ask questions, build queries, explore  |  user: `{get_user()}`")

views = df(
    f"SELECT view_catalog||'.'||view_schema||'.'||view_name AS FQN, version_id, deployed_at "
    f"FROM {CATALOG}.AGMP_REGISTRY WHERE status='DEPLOYED' ORDER BY deployed_at DESC"
)
if views.empty:
    st.error("No deployed semantic views found.")
    st.stop()

view_fqn = st.sidebar.selectbox("Semantic view:", views["FQN"].tolist())
cat, sch, nm = view_fqn.split(".")

# ---------- entitlement gate ----------
ent_raw = session.sql(f"CALL {PUBLIC}.SP_AGMP_CHECK_ENTITLEMENT('{view_fqn}')").collect()[0][0]
ent = json.loads(ent_raw) if isinstance(ent_raw, str) else ent_raw
if ent.get("status") != "ENTITLED":
    st.warning(f"Access status: **{ent.get('status')}**.")
    st.json(ent)
    st.stop()

# ---------- ASK A QUESTION (Cortex Analyst) ----------
st.subheader(":speech_balloon: Ask a Question")

EXAMPLES = [
    "What is the total revenue by customer market segment?",
    "Who are the top 10 customers by total order value?",
    "What is the monthly trend of line item revenue?",
    "How does total order value compare across order priorities?",
    "What is total quantity shipped by ship mode and year?"
]

q_col, b_col = st.columns([4,1])
question = q_col.text_input("Type your question (Cortex Analyst will translate it to SQL):",
                            placeholder=EXAMPLES[0], key="nl_q")
ask_btn = b_col.button("Ask", type="primary", use_container_width=True)

st.caption("Quick examples:")
ec = st.columns(len(EXAMPLES))
for i, ex in enumerate(EXAMPLES):
    if ec[i].button(f"{i+1}", key=f"ex_{i}", help=ex):
        question = ex
        ask_btn = True

if ask_btn and question:
    with st.spinner(f"Asking Cortex Analyst about `{view_fqn}`..."):
        try:
            status, body = call_cortex_analyst(question, view_fqn)
        except Exception as e:
            status, body = 0, f"transport_error: {e}"

    if status == 200:
        try:
            payload = json.loads(body)
            content = payload.get("message", {}).get("content", []) or payload.get("content", [])
            sql_text, ans_text = None, None
            for c in content:
                t = c.get("type")
                if t == "sql":
                    sql_text = c.get("statement") or c.get("sql")
                elif t == "text":
                    ans_text = c.get("text")
            if ans_text:
                st.info(ans_text)
            if sql_text:
                with st.expander("Generated SQL", expanded=True):
                    st.code(sql_text, language="sql")
                try:
                    result = df(sql_text)
                    st.success(f"Returned {len(result)} rows")
                    st.dataframe(result, use_container_width=True)
                    if len(result.columns) >= 2 and len(result) > 0:
                        first_col = result.columns[0]
                        numeric_cols = [c for c in result.columns[1:] if pd.api.types.is_numeric_dtype(result[c])]
                        if numeric_cols:
                            st.bar_chart(result.set_index(first_col)[numeric_cols])
                    csv = result.to_csv(index=False).encode("utf-8")
                    st.download_button("Download CSV", csv, file_name=f"{nm}_qa.csv", mime="text/csv")
                    log_feedback(view_fqn, question, answered=True)
                except Exception as e:
                    st.error(f"Generated SQL failed to execute: {e}")
                    log_feedback(view_fqn, question, answered=False)
            else:
                st.warning("Cortex Analyst responded but did not return executable SQL.")
                st.json(payload)
                log_feedback(view_fqn, question, answered=False)
        except Exception as e:
            st.error(f"Could not parse Analyst response: {e}")
            st.text(body)
            log_feedback(view_fqn, question, answered=False)
    else:
        log_feedback(view_fqn, question, answered=False)
        if "trial accounts" in (body or "").lower() or '"399504"' in (body or ""):
            st.warning(":lock:  Cortex Analyst is **disabled on trial accounts**.")
            st.markdown(
                "**To enable NL Q&A:**\n"
                "1. Upgrade this Snowflake account from trial to a standard edition\n"
                "2. Reload this app (no code changes needed)\n\n"
                "Until then, use the **query builder below** to explore dimensions and metrics."
            )
        else:
            st.error(f"Cortex Analyst call failed (HTTP {status}). Body:")
            st.text(body[:2000])

st.markdown("---")

# ---------- Schema info ----------
desc = df(f"DESCRIBE SEMANTIC VIEW {view_fqn}")

def find_col(d, target):
    for c in d.columns:
        if c.upper() == target.upper(): return c
    return None

ok_col   = find_col(desc, "OBJECT_KIND")
nm_col   = find_col(desc, "OBJECT_NAME")

if not ok_col or not nm_col:
    st.error(f"Unexpected DESCRIBE schema. Got: {list(desc.columns)}")
    st.stop()

desc_dims    = desc.loc[desc[ok_col]=='DIMENSION', nm_col].drop_duplicates().tolist()
desc_metrics = desc.loc[desc[ok_col]=='METRIC',    nm_col].drop_duplicates().tolist()
desc_facts   = desc.loc[desc[ok_col]=='FACT',      nm_col].drop_duplicates().tolist()

cols = df(
    f"SELECT source_table, column_name, data_type, semantic_role, "
    f"       COALESCE(human_description, ai_description) AS description, is_time_dimension "
    f"FROM {CATALOG}.AGMP_COLUMNS "
    f"WHERE view_catalog='{cat}' AND view_schema='{sch}' AND view_name='{nm}' "
    f"ORDER BY semantic_role, source_table, ordinal_position"
)

c1,c2,c3,c4 = st.columns(4)
c1.metric("Dimensions", len(desc_dims))
c2.metric("Metrics", len(desc_metrics))
c3.metric("Facts", len(desc_facts))
c4.metric("Source tables", cols["SOURCE_TABLE"].nunique() if 'SOURCE_TABLE' in cols.columns else 0)

with st.expander("Schema details (from catalog)"):
    st.dataframe(cols, use_container_width=True)

# ---------- Query builder ----------
st.subheader(":hammer_and_wrench: Query Builder")
left, right = st.columns(2)
with left:
    sel_dims = st.multiselect("Dimensions:", desc_dims, default=desc_dims[:1] if desc_dims else [])
with right:
    sel_metrics = st.multiselect("Metrics:", desc_metrics, default=desc_metrics[:1] if desc_metrics else [])

c_filt, c_lim = st.columns([3,1])
where_clause = c_filt.text_input("WHERE filter (optional):", placeholder="e.g. C_MKTSEGMENT = 'BUILDING'")
row_limit = c_lim.number_input("Row limit:", min_value=10, max_value=10000, value=100, step=10)

order_col = None
if sel_metrics or sel_dims:
    order_col = st.selectbox("Order by:", ["(none)"] + sel_metrics + sel_dims)
order_dir = st.radio("Direction:", ["DESC","ASC"], horizontal=True)

if st.button("Run Query", type="primary", key="run_qb"):
    if not sel_dims and not sel_metrics:
        st.error("Pick at least one dimension or metric.")
    else:
        sv_clauses = []
        if sel_dims: sv_clauses.append("DIMENSIONS " + ", ".join(sel_dims))
        if sel_metrics: sv_clauses.append("METRICS " + ", ".join(sel_metrics))
        sql = f"SELECT * FROM SEMANTIC_VIEW({view_fqn} " + " ".join(sv_clauses) + ")"
        if where_clause.strip(): sql += f" WHERE {where_clause}"
        if order_col and order_col != "(none)": sql += f" ORDER BY {order_col} {order_dir}"
        sql += f" LIMIT {int(row_limit)}"
        with st.expander("Generated SQL"):
            st.code(sql, language="sql")
        try:
            result = df(sql)
            st.success(f"Returned {len(result)} rows")
            st.dataframe(result, use_container_width=True)
            if len(sel_dims) == 1 and len(sel_metrics) >= 1 and not result.empty:
                dim_col = sel_dims[0]
                if dim_col in result.columns:
                    chart_type = st.radio("Chart:", ["Bar","Line","Area"], horizontal=True, key="ct")
                    chart_data = result.set_index(dim_col)[sel_metrics]
                    if chart_type == "Bar":   st.bar_chart(chart_data)
                    elif chart_type == "Line": st.line_chart(chart_data)
                    else:                       st.area_chart(chart_data)
            csv = result.to_csv(index=False).encode("utf-8")
            st.download_button("Download CSV", csv, file_name=f"{nm}_query.csv", mime="text/csv")
        except Exception as e:
            st.error(f"Query failed: {e}")

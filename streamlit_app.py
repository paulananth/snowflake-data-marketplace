"""
Semantic View Builder - Agentic Data Marketplace
6-tab Streamlit in Snowflake app for building, governing, and consuming semantic views.

Tabs:
  1. Build           - Configure tables, hierarchy, target view
  2. Review          - Edit column classifications, descriptions
  3. CI/CD           - Version history, status transitions
  4. Domains         - AI-suggested domains, human confirmation, stewards
  5. Access Control  - Pending requests, approve/deny
  6. Usage & Health  - Query volume, answer rates
"""
import json
from datetime import datetime

import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="Semantic View Builder", page_icon=":bar_chart:", layout="wide")
session = get_active_session()

DB = session.sql("SELECT CURRENT_DATABASE()").collect()[0][0]
CATALOG = f"{DB}.SEMANTIC_CATALOG"
PUBLIC = f"{DB}.PUBLIC"


# ---------------------------------------------------------------------------- #
# Helpers                                                                      #
# ---------------------------------------------------------------------------- #
def df(sql, params=None):
    return session.sql(sql, params=params).to_pandas() if params else session.sql(sql).to_pandas()


def call_proc(name, args_sql, return_type="VARIANT"):
    return session.sql(f"CALL {name}({args_sql})").collect()


def get_current_user():
    return session.sql("SELECT CURRENT_USER() AS U").collect()[0]["U"]


def list_deployed_views():
    return df(
        f"SELECT view_catalog||'.'||view_schema||'.'||view_name AS FQN, version_id, status, deployed_at "
        f"FROM {CATALOG}.AGMP_REGISTRY WHERE status='DEPLOYED' ORDER BY deployed_at DESC"
    )


# ---------------------------------------------------------------------------- #
# Header                                                                       #
# ---------------------------------------------------------------------------- #
st.title(":bar_chart: Semantic View Builder")
st.caption(f"Agentic Data Marketplace  |  user: `{get_current_user()}`")

tab1, tab2, tab3, tab4, tab5, tab6 = st.tabs(
    ["1. Build", "2. Review", "3. CI/CD", "4. Domains", "5. Access Control", "6. Usage & Health"]
)


# ---------------------------------------------------------------------------- #
# Tab 1 - Build                                                                #
# ---------------------------------------------------------------------------- #
with tab1:
    st.header("Build a New Semantic View")
    st.write("Specify source tables in hierarchy order (top-most parent first). The pipeline will:")
    st.write(
        "1. DESCRIBE each table  2. Classify columns  3. Infer relationships  "
        "4. Generate DDL  5. Create the semantic view  6. Populate the catalog"
    )

    default_tables = (
        "YOUR_DB.YOUR_SCHEMA.TABLE1\n"
        "YOUR_DB.YOUR_SCHEMA.TABLE2"
    )
    tables_text = st.text_area(
        "Source tables (one per line, fully qualified, top-of-hierarchy first):",
        value=default_tables, height=120
    )
    target_view = st.text_input("Target semantic view (DB.SCHEMA.NAME):",
                                value=f"{DB}.PUBLIC.AGMP")
    view_comment = st.text_input("View comment:",
                                 value="Agentic marketplace semantic view")

    if st.button(":rocket: Build Semantic View", type="primary"):
        tables = [t.strip() for t in tables_text.splitlines() if t.strip()]
        if len(tables) < 1:
            st.error("Provide at least one table.")
        else:
            with st.spinner("Running end-to-end pipeline..."):
                arr_sql = "ARRAY_CONSTRUCT(" + ",".join(f"'{t}'" for t in tables) + ")"
                row = session.sql(
                    f"CALL {PUBLIC}.SP_AGMP_BUILD_END_TO_END({arr_sql}, {arr_sql}, "
                    f"'{target_view}', '{view_comment.replace(chr(39),chr(39)+chr(39))}')"
                ).collect()[0][0]
                result = json.loads(row) if isinstance(row, str) else row
                st.success(f"Created {target_view} (version {result.get('version_id')})")
                col_a, col_b, col_c = st.columns(3)
                col_a.metric("Tables", result.get("tables", 0))
                col_b.metric("Columns", result.get("columns", 0))
                col_c.metric("Relationships", result.get("relationships", 0))
                with st.expander("Generated DDL"):
                    st.code(result.get("ddl", ""), language="sql")


# ---------------------------------------------------------------------------- #
# Tab 2 - Review                                                               #
# ---------------------------------------------------------------------------- #
with tab2:
    st.header("Review & Edit Column Classifications")
    views = list_deployed_views()
    if views.empty:
        st.info("No deployed views yet. Build one in Tab 1.")
    else:
        selected = st.selectbox("Select a semantic view:", views["FQN"].tolist(), key="rev_view")
        cat, sch, nm = selected.split(".")

        cols = df(
            f"SELECT version_id, source_table, column_name, data_type, semantic_role, "
            f"       ai_description, human_description, "
            f"       COALESCE(human_description, ai_description) AS effective_description, "
            f"       is_time_dimension "
            f"FROM {CATALOG}.AGMP_COLUMNS "
            f"WHERE view_catalog='{cat}' AND view_schema='{sch}' AND view_name='{nm}' "
            f"ORDER BY source_table, ordinal_position"
        )

        st.write("Edit `human_description` to override AI-generated descriptions. Human edits always win.")
        edited = st.data_editor(
            cols,
            column_config={
                "VERSION_ID":            st.column_config.NumberColumn(disabled=True),
                "SOURCE_TABLE":          st.column_config.TextColumn(disabled=True),
                "COLUMN_NAME":           st.column_config.TextColumn(disabled=True),
                "DATA_TYPE":             st.column_config.TextColumn(disabled=True),
                "SEMANTIC_ROLE":         st.column_config.SelectboxColumn(
                                            options=["DIMENSION","FACT","METRIC"]),
                "AI_DESCRIPTION":        st.column_config.TextColumn(disabled=True),
                "HUMAN_DESCRIPTION":     st.column_config.TextColumn(width="large"),
                "EFFECTIVE_DESCRIPTION": st.column_config.TextColumn(disabled=True),
                "IS_TIME_DIMENSION":     st.column_config.CheckboxColumn(disabled=True),
            },
            hide_index=True,
            num_rows="fixed",
            key="cols_editor"
        )

        if st.button(":floppy_disk: Save Description Edits"):
            user = get_current_user()
            saved = 0
            for _, r in edited.iterrows():
                old = cols.loc[(cols.SOURCE_TABLE==r.SOURCE_TABLE) & (cols.COLUMN_NAME==r.COLUMN_NAME)]
                if old.empty: continue
                old_human = old.iloc[0].HUMAN_DESCRIPTION
                old_role = old.iloc[0].SEMANTIC_ROLE
                if (r.HUMAN_DESCRIPTION or "") != (old_human or "") or r.SEMANTIC_ROLE != old_role:
                    session.sql(
                        f"UPDATE {CATALOG}.AGMP_COLUMNS "
                        f"SET human_description=?, description_source='HUMAN_EDITED', "
                        f"    semantic_role=?, last_edited_by=?, last_edited_at=CURRENT_TIMESTAMP() "
                        f"WHERE view_catalog=? AND view_schema=? AND view_name=? "
                        f"  AND source_table=? AND column_name=?",
                        params=[r.HUMAN_DESCRIPTION, r.SEMANTIC_ROLE, user,
                                cat, sch, nm, r.SOURCE_TABLE, r.COLUMN_NAME]
                    ).collect()
                    saved += 1
            st.success(f"Saved {saved} change(s).")


# ---------------------------------------------------------------------------- #
# Tab 3 - CI/CD                                                                #
# ---------------------------------------------------------------------------- #
with tab3:
    st.header("CI/CD Pipeline & Version History")
    history = df(f"SELECT view_catalog||'.'||view_schema||'.'||view_name AS FQN, "
                 f"       version_id, version_tag, status, created_by, approved_by, "
                 f"       created_at, deployed_at, archived_at, notes "
                 f"FROM {CATALOG}.AGMP_REGISTRY ORDER BY created_at DESC LIMIT 100")
    if history.empty:
        st.info("No versions yet.")
    else:
        st.dataframe(history, use_container_width=True, hide_index=True)

        st.subheader("View DDL")
        sel = st.selectbox("Pick a version to inspect:",
                           options=[f"{r.FQN} v{r.VERSION_ID} ({r.STATUS})" for _, r in history.iterrows()])
        if sel:
            vid = int(sel.split(" v")[1].split(" ")[0])
            ddl_row = df(f"SELECT view_ddl FROM {CATALOG}.AGMP_REGISTRY WHERE version_id={vid}")
            if not ddl_row.empty:
                st.code(ddl_row.iloc[0].VIEW_DDL, language="sql")


# ---------------------------------------------------------------------------- #
# Tab 4 - Domains                                                              #
# ---------------------------------------------------------------------------- #
with tab4:
    st.header("Business Domain Assignment")
    views = list_deployed_views()
    if views.empty:
        st.info("No deployed views yet.")
    else:
        sel = st.selectbox("Select a view:", views["FQN"].tolist(), key="dom_view")
        cat, sch, nm = sel.split(".")

        if st.button(":robot_face: Run AI Domain Suggestion"):
            with st.spinner("Calling SP_AGMP_SUGGEST_DOMAINS..."):
                result = session.sql(
                    f"CALL {PUBLIC}.SP_AGMP_SUGGEST_DOMAINS('{sel}')"
                ).collect()[0][0]
                if isinstance(result, str): result = json.loads(result)
                st.json(result)

        domains = df(
            f"SELECT domain_id, domain_name, ai_suggested_domain, ai_confidence_score, "
            f"       human_confirmed_domain, confirmed_by, steward_user, steward_role, description "
            f"FROM {CATALOG}.AGMP_DOMAINS "
            f"WHERE view_catalog='{cat}' AND view_schema='{sch}' AND view_name='{nm}' "
            f"ORDER BY domain_id DESC LIMIT 10"
        )
        if domains.empty:
            st.info("No domain suggestions yet. Click the button above.")
        else:
            st.write("**Confirm or override the suggested domain:**")
            for _, d in domains.iterrows():
                st.markdown(f"**Suggested:** `{d.AI_SUGGESTED_DOMAIN}` (confidence {d.AI_CONFIDENCE_SCORE:.2f})")
                st.caption(d.DESCRIPTION or "")
                colA, colB, colC = st.columns([2,2,1])
                conf = colA.text_input("Confirmed domain:", value=d.HUMAN_CONFIRMED_DOMAIN or d.AI_SUGGESTED_DOMAIN, key=f"conf_{d.DOMAIN_ID}")
                steward = colB.text_input("Steward user:", value=d.STEWARD_USER or get_current_user(), key=f"stew_{d.DOMAIN_ID}")
                if colC.button("Save", key=f"save_dom_{d.DOMAIN_ID}"):
                    session.sql(
                        f"UPDATE {CATALOG}.AGMP_DOMAINS "
                        f"SET human_confirmed_domain=?, confirmed_by=?, confirmed_at=CURRENT_TIMESTAMP(), "
                        f"    steward_user=? "
                        f"WHERE domain_id=?",
                        params=[conf, get_current_user(), steward, int(d.DOMAIN_ID)]
                    ).collect()
                    st.success(f"Domain confirmed: {conf} | Steward: {steward}")
                st.divider()


# ---------------------------------------------------------------------------- #
# Tab 5 - Access Control                                                       #
# ---------------------------------------------------------------------------- #
with tab5:
    st.header("Access Control")

    st.subheader("Request Access")
    views = list_deployed_views()
    if not views.empty:
        v = st.selectbox("Select a view to request access to:", views["FQN"].tolist(), key="req_view")
        sens = st.selectbox("Sensitivity level:", ["LOW","MEDIUM","HIGH","PII"], index=1)
        just = st.text_area("Justification:", placeholder="e.g. Need this data for the Q3 revenue analysis")
        if st.button(":key: Submit Request"):
            with st.spinner("Submitting..."):
                result = session.sql(
                    f"CALL {PUBLIC}.SP_AGMP_REQUEST_ACCESS('{v}', '{just.replace(chr(39),chr(39)+chr(39))}', '{sens}')"
                ).collect()[0][0]
                if isinstance(result, str): result = json.loads(result)
                st.json(result)

        if st.button(":mag: Check My Entitlement"):
            r = session.sql(f"CALL {PUBLIC}.SP_AGMP_CHECK_ENTITLEMENT('{v}')").collect()[0][0]
            if isinstance(r, str): r = json.loads(r)
            st.json(r)

    st.divider()
    st.subheader("Pending Requests (Steward View)")
    requests = df(
        f"SELECT request_id, requestor_user, view_catalog||'.'||view_schema||'.'||view_name AS view_fqn, "
        f"       sensitivity_level, justification, status, requested_at, reviewer_notes "
        f"FROM {CATALOG}.AGMP_ACCESS_REQUESTS "
        f"ORDER BY requested_at DESC LIMIT 50"
    )
    if requests.empty:
        st.info("No requests yet.")
    else:
        st.dataframe(requests, use_container_width=True, hide_index=True)

        pending = requests[requests.STATUS == "PENDING"]
        if not pending.empty:
            rid = st.selectbox("Request to review:", pending.REQUEST_ID.tolist(), key="rev_req")
            grant_role = st.text_input("Grant SELECT to role:", value="PUBLIC")
            notes = st.text_area("Reviewer notes:", key="rev_notes")
            ca, cb = st.columns(2)
            if ca.button(":white_check_mark: Approve & Grant"):
                r = session.sql(
                    f"CALL {PUBLIC}.SP_AGMP_APPROVE_ACCESS({int(rid)}, '{grant_role}', '{notes.replace(chr(39),chr(39)+chr(39))}')"
                ).collect()[0][0]
                if isinstance(r, str): r = json.loads(r)
                st.json(r)
            if cb.button(":x: Deny"):
                r = session.sql(
                    f"CALL {PUBLIC}.SP_AGMP_DENY_ACCESS({int(rid)}, '{notes.replace(chr(39),chr(39)+chr(39))}')"
                ).collect()[0][0]
                if isinstance(r, str): r = json.loads(r)
                st.json(r)


# ---------------------------------------------------------------------------- #
# Tab 6 - Usage & Health                                                       #
# ---------------------------------------------------------------------------- #
with tab6:
    st.header("Usage & Health")

    if st.button(":arrows_counterclockwise: Refresh usage from QUERY_HISTORY"):
        with st.spinner("Aggregating..."):
            r = session.sql(f"CALL {PUBLIC}.SP_AGMP_AGGREGATE_USAGE()").collect()[0][0]
            if isinstance(r, str): r = json.loads(r)
            st.success(f"Processed {r.get('views_processed')} view(s)")

    usage = df(
        f"SELECT view_catalog||'.'||view_schema||'.'||view_name AS view_fqn, "
        f"       query_date, query_count, unique_users, answered_count, unanswered_count "
        f"FROM {CATALOG}.AGMP_USAGE_ANALYTICS ORDER BY query_date DESC"
    )
    if usage.empty:
        st.info("No usage data yet. Click Refresh above to aggregate from QUERY_HISTORY (last 7 days).")
    else:
        st.dataframe(usage, use_container_width=True, hide_index=True)
        chart_df = usage.groupby("QUERY_DATE")[["QUERY_COUNT","UNIQUE_USERS"]].sum()
        st.line_chart(chart_df)

    st.divider()
    st.subheader("Catalog Health Snapshot")
    snap = df(f"""
        SELECT 'AGMP_REGISTRY'           AS table_name, COUNT(*) AS rows FROM {CATALOG}.AGMP_REGISTRY
        UNION ALL SELECT 'AGMP_COLUMNS',           COUNT(*) FROM {CATALOG}.AGMP_COLUMNS
        UNION ALL SELECT 'AGMP_RELATIONSHIPS',     COUNT(*) FROM {CATALOG}.AGMP_RELATIONSHIPS
        UNION ALL SELECT 'AGMP_DOMAINS',           COUNT(*) FROM {CATALOG}.AGMP_DOMAINS
        UNION ALL SELECT 'AGMP_ACCESS_REQUESTS',   COUNT(*) FROM {CATALOG}.AGMP_ACCESS_REQUESTS
        UNION ALL SELECT 'AGMP_TEST_RESULTS',      COUNT(*) FROM {CATALOG}.AGMP_TEST_RESULTS
        UNION ALL SELECT 'AGMP_ANALYST_FEEDBACK',  COUNT(*) FROM {CATALOG}.AGMP_ANALYST_FEEDBACK
        UNION ALL SELECT 'AGMP_USAGE_ANALYTICS',   COUNT(*) FROM {CATALOG}.AGMP_USAGE_ANALYTICS
    """)
    st.dataframe(snap, use_container_width=True, hide_index=True)

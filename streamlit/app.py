import snowflake.connector
import streamlit as st
import pandas as pd


# ---------------------------------------------------------------------------
# Page config
# ---------------------------------------------------------------------------

st.set_page_config(
    page_title="GitHub Analysis Platform",
    layout="wide",
)


# ---------------------------------------------------------------------------
# Connection
# ---------------------------------------------------------------------------

def get_connection() -> snowflake.connector.SnowflakeConnection:
    s = st.secrets["snowflake"]
    return snowflake.connector.connect(
        account=s["account"],
        user=s["user"],
        password=s["password"],
        role=s["role"],
        database=s["database"],
        warehouse=s["warehouse"],
    )


# ---------------------------------------------------------------------------
# Queries  (all cached for 1 hour)
# ---------------------------------------------------------------------------

@st.cache_data(ttl=3600)
def fetch_summary_metrics() -> dict:
    """
    Returns total events, date range, human/bot split, and last updated
    from mart_contributor_trends.
    """
    sql = """
        SELECT
            SUM(event_count)                AS total_events,
            MIN(event_date)                 AS min_date,
            MAX(event_date)                 AS max_date,
            SUM(CASE WHEN contributor_type = 'human' THEN event_count ELSE 0 END)
                                            AS human_events,
            SUM(CASE WHEN contributor_type = 'bot'   THEN event_count ELSE 0 END)
                                            AS bot_events,
            MAX(_sdc_batched_at)            AS last_updated
        FROM DATA_PLATFORM.GHARCHIVE.mart_contributor_trends
    """
    conn = get_connection()
    try:
        cur = conn.cursor()
        cur.execute(sql)
        row = cur.fetchone()
        total     = row[0] or 0
        min_date  = row[1]
        max_date  = row[2]
        human     = row[3] or 0
        bot       = row[4] or 0
        updated   = row[5]
        pct_human = round(human / total * 100, 1) if total else 0.0
        pct_bot   = round(bot   / total * 100, 1) if total else 0.0
        return {
            "total_events": total,
            "min_date":     min_date,
            "max_date":     max_date,
            "pct_human":    pct_human,
            "pct_bot":      pct_bot,
            "last_updated": updated,
        }
    finally:
        conn.close()


@st.cache_data(ttl=3600)
def fetch_total_repos() -> int:
    """
    Returns total repos enriched from mart_language_activity.
    Sums the per-language unique_repos count (best approximation from
    the pre-aggregated mart; individual repo names are not stored there).
    """
    sql = """
        SELECT SUM(unique_repos)
        FROM DATA_PLATFORM.GHARCHIVE.mart_language_activity
    """
    conn = get_connection()
    try:
        cur = conn.cursor()
        cur.execute(sql)
        row = cur.fetchone()
        return row[0] or 0
    finally:
        conn.close()


@st.cache_data(ttl=3600)
def fetch_top_languages() -> pd.DataFrame:
    """Top 5 languages by total push events (all time)."""
    sql = """
        SELECT
            language,
            SUM(event_count) AS total_push_events
        FROM DATA_PLATFORM.GHARCHIVE.mart_language_activity
        GROUP BY language
        ORDER BY total_push_events DESC
        LIMIT 5
    """
    conn = get_connection()
    try:
        cur = conn.cursor()
        cur.execute(sql)
        rows = cur.fetchall()
        return pd.DataFrame(rows, columns=["Language", "Push Events"])
    finally:
        conn.close()


@st.cache_data(ttl=3600)
def fetch_top_repos_by_language() -> pd.DataFrame:
    """
    Top 5 languages by total unique repos (all time).
    mart_language_activity is the finest granularity available — repo_name
    is aggregated away in the mart layer.
    """
    sql = """
        SELECT
            language,
            SUM(unique_repos) AS total_unique_repos
        FROM DATA_PLATFORM.GHARCHIVE.mart_language_activity
        GROUP BY language
        ORDER BY total_unique_repos DESC
        LIMIT 5
    """
    conn = get_connection()
    try:
        cur = conn.cursor()
        cur.execute(sql)
        rows = cur.fetchall()
        return pd.DataFrame(rows, columns=["Language", "Unique Repos"])
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

st.title("GitHub Analysis Platform")
st.caption(
    "End-to-end pipeline ingesting GH Archive push events into Snowflake "
    "via S3 + Lambda, modelled with dbt, and visualised here."
)

st.divider()

# -- Metric cards ------------------------------------------------------------

with st.spinner("Loading metrics..."):
    metrics   = fetch_summary_metrics()
    total_repos = fetch_total_repos()

col1, col2, col3, col4 = st.columns(4)

col1.metric(
    label="Total Events Ingested",
    value=f"{metrics['total_events']:,}",
)

date_range = (
    f"{metrics['min_date']} → {metrics['max_date']}"
    if metrics["min_date"]
    else "—"
)
col2.metric(
    label="Date Range Covered",
    value=date_range,
)

col3.metric(
    label="Human / Bot Split",
    value=f"{metrics['pct_human']}% human",
    delta=f"{metrics['pct_bot']}% bot",
    delta_color="off",
)

col4.metric(
    label="Total Repos Enriched",
    value=f"{total_repos:,}",
)

st.divider()

# -- Tables ------------------------------------------------------------------

with st.spinner("Loading tables..."):
    df_languages = fetch_top_languages()
    df_repos     = fetch_top_repos_by_language()

col_left, col_right = st.columns(2)

with col_left:
    st.subheader("Top 5 Languages")
    st.dataframe(df_languages, use_container_width=True, hide_index=True)

with col_right:
    st.subheader("Top 5 Languages by Unique Repos")
    st.dataframe(df_repos, use_container_width=True, hide_index=True)

st.divider()

# -- Footer ------------------------------------------------------------------

last_updated = metrics.get("last_updated")
footer_text  = f"Last updated: {last_updated}" if last_updated else "Last updated: unknown"
st.caption(footer_text)

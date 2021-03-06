CREATE OR REPLACE PACKAGE BODY &&1..iod_spm AS
/* $Header: iod_spm.pkb.sql 2017-12-07T16:20:21 carlos.sierra $ */
/* ------------------------------------------------------------------------------------ */  
PROCEDURE output (p_line IN VARCHAR2) 
IS
BEGIN
  DBMS_OUTPUT.PUT_LINE (a => p_line);
END output;
/* ------------------------------------------------------------------------------------ */  
PROCEDURE output (p_col_1 IN VARCHAR2, p_col_2 IN VARCHAR2) 
IS
BEGIN
  IF TRIM(p_col_2) IS NOT NULL THEN
    output (p_line => '| '||RPAD(SUBSTR(NVL(p_col_1, ' '), 1, 32), 32)||' : '||SUBSTR(p_col_2, 1, 108));
  END IF;
END output;
/* ------------------------------------------------------------------------------------ */  
PROCEDURE output (p_col_01 IN VARCHAR2, 
                  p_col_02 IN VARCHAR2, p_col_03 IN VARCHAR2, p_col_04 IN VARCHAR2, 
                  p_col_05 IN VARCHAR2, p_col_06 IN VARCHAR2, p_col_07 IN VARCHAR2, 
                  p_col_08 IN VARCHAR2, p_col_09 IN VARCHAR2, p_col_10 IN VARCHAR2) 
IS
  FUNCTION trim_and_pad (p_col IN VARCHAR) RETURN VARCHAR2 
  IS
  BEGIN
    RETURN LPAD(NVL(TRIM(p_col), ' '), 12);
  END trim_and_pad;
BEGIN
  output (p_col_1 => p_col_01, p_col_2 =>
    trim_and_pad(p_col_02)||trim_and_pad(p_col_03)||trim_and_pad(p_col_04)||
    trim_and_pad(p_col_05)||trim_and_pad(p_col_06)||trim_and_pad(p_col_07)||
    trim_and_pad(p_col_08)||trim_and_pad(p_col_09)||trim_and_pad(p_col_10)
    );
END output;
/* ------------------------------------------------------------------------------------ */  
PROCEDURE maintain_plans_internal (
  p_report_only                  IN VARCHAR2 DEFAULT NULL, -- (Y|N) when Y then only produces report and changes nothing
  p_create_spm_limit             IN NUMBER   DEFAULT NULL, -- limits the number of SPMs to be created in one execution
  p_promote_spm_limit            IN NUMBER   DEFAULT NULL, -- limits the number of SPMs to be promoted to "FIXED" in one execution
  p_disable_spm_limit            IN NUMBER   DEFAULT NULL, -- limits the number of SPMs to be demoted to "DISABLE" in one execution
  p_aggressiveness               IN NUMBER   DEFAULT NULL, -- (1-5) range between 1 to 5 where 1 is conservative and 5 is aggresive
  p_repo_rejected_candidates     IN VARCHAR2 DEFAULT 'Y',  -- (Y|N) include on report rejected candidates
  p_repo_non_promoted_spb        IN VARCHAR2 DEFAULT 'Y',  -- (Y|N) include on report non-fixed SPB that is not getting promoted to "FIXED"
  p_pdb_name                     IN VARCHAR2 DEFAULT NULL, -- evaluate only this one PDB
  p_sql_id                       IN VARCHAR2 DEFAULT NULL, -- evaluate only this one SQL
  p_incl_plans_appl_1            IN VARCHAR2 DEFAULT 'Y',  -- (Y|N) include SQL from 1st application (BeginTx)
  p_incl_plans_appl_2            IN VARCHAR2 DEFAULT 'Y',  -- (Y|N) include SQL from 2nd application (CommitTx)
  p_incl_plans_appl_3            IN VARCHAR2 DEFAULT 'Y',  -- (Y|N) include SQL from 3rd application (Read)
  p_incl_plans_appl_4            IN VARCHAR2 DEFAULT 'Y',  -- (Y|N) include SQL from 4th application (GC)
  p_incl_plans_non_appl          IN VARCHAR2 DEFAULT 'N',  -- (N|Y) consider as candidate SQL not qualified as "application module"
  p_execs_candidate              IN NUMBER   DEFAULT NULL, -- a plan must be executed these many times to be a candidate
  p_secs_per_exec_cand           IN NUMBER   DEFAULT NULL, -- a plan must perform better than this threshold to be a candidate
  p_first_load_time_days_cand    IN NUMBER   DEFAULT NULL, -- a sql must be loaded into memory at least this many days before it is considered as candidate
  p_awr_days                     IN NUMBER   DEFAULT NULL, -- amount of days to consider from AWR history assuming retention is at least this long
  x_plan_candidates              OUT NUMBER, -- Candidates
  x_qualified_for_spb_creation   OUT NUMBER, -- SPBs Qualified for Creation
  x_spbs_created                 OUT NUMBER, -- SPBs Created
  x_qualified_for_spb_promotion  OUT NUMBER, -- SPBs Qualified for Promotion
  x_spbs_promoted                OUT NUMBER, -- SPBs Promoted
  x_qualified_for_spb_demotion   OUT NUMBER, -- SPBs Qualified for Demotion
  x_spbs_demoted                 OUT NUMBER, -- SPBs Demoted
  x_spbs_already_fixed           OUT NUMBER  -- SPBs already Fixed
)
IS
/* ------------------------------------------------------------------------------------ */
  k_report_only                  CONSTANT CHAR(1) := NVL(UPPER(SUBSTR(TRIM(p_report_only), 1, 1)), 'Y'); -- (Y|N) when Y then only produces report and changes nothing
  k_create_spm_limit             CONSTANT NUMBER := NVL(p_create_spm_limit, 10000); -- limits the number of SPMs to be created in one execution
  k_promote_spm_limit            CONSTANT NUMBER := NVL(p_promote_spm_limit, 10000); -- limits the number of SPMs to be promoted to "FIXED" in one execution
  k_disable_spm_limit            CONSTANT NUMBER := NVL(p_disable_spm_limit, 10000); -- limits the number of SPMs to be demoted to "DISABLE" in one execution
  k_aggressiveness               CONSTANT NUMBER := GREATEST(LEAST(NVL(ROUND(p_aggressiveness), 1), 5), 1); -- (1-5) range between 1 to 5 where 1 is conservative and 5 is aggresive
  k_repo_rejected_candidates     CONSTANT CHAR(1) := NVL(UPPER(SUBSTR(TRIM(p_repo_rejected_candidates), 1, 1)), 'Y'); -- (Y|N) include on report rejected candidates
  k_repo_non_promoted_spb        CONSTANT CHAR(1) := NVL(UPPER(SUBSTR(TRIM(p_repo_non_promoted_spb), 1, 1)), 'Y'); -- (Y|N) include on report non-fixed SPB that is not getting promoted to "FIXED"
  k_pdb_name                     CONSTANT VARCHAR2(30) := SUBSTR(TRIM(p_pdb_name), 1, 30); -- evaluate only this one PDB
  k_sql_id                       CONSTANT VARCHAR2(13) := SUBSTR(TRIM(p_sql_id), 1, 13); -- evaluate only this one SQL
  k_incl_plans_appl_1            CONSTANT CHAR(1) := NVL(UPPER(SUBSTR(TRIM(p_incl_plans_appl_1), 1, 1)), 'Y'); -- (Y|N) include SQL from 1st application (BeginTx)
  k_incl_plans_appl_2            CONSTANT CHAR(1) := NVL(UPPER(SUBSTR(TRIM(p_incl_plans_appl_2), 1, 1)), 'Y'); -- (Y|N) include SQL from 2nd application (CommitTx)
  k_incl_plans_appl_3            CONSTANT CHAR(1) := NVL(UPPER(SUBSTR(TRIM(p_incl_plans_appl_3), 1, 1)), 'Y'); -- (Y|N) include SQL from 3rd application (Read)
  k_incl_plans_appl_4            CONSTANT CHAR(1) := NVL(UPPER(SUBSTR(TRIM(p_incl_plans_appl_4), 1, 1)), 'Y'); -- (Y|N) include SQL from 4th application (GC)
  k_incl_plans_non_appl          CONSTANT CHAR(1) := NVL(UPPER(SUBSTR(TRIM(p_incl_plans_non_appl), 1, 1)), 'N'); -- (N|Y) consider as candidate SQL not qualified as "application module"
  k_aggressiveness_levels        CONSTANT NUMBER := 5; -- (2-5) levels the aggressiveness parameter can take
  k_execs_candidate_min          CONSTANT NUMBER := 500; -- a plan must be executed these many times to be a candidate (for aggressiveness of 5)
  k_execs_candidate_max          CONSTANT NUMBER := 2500; -- a plan must be executed these many times to be a candidate (for aggressiveness of 1)
  k_execs_candidate              CONSTANT NUMBER := NVL(p_execs_candidate, ROUND(k_execs_candidate_max - ((k_aggressiveness - 1) * (k_execs_candidate_max - k_execs_candidate_min) / (k_aggressiveness_levels - 1))));
  k_execs_appl_cat_1_min         CONSTANT NUMBER := 5000; -- a plan of this appl category must be executed these many times to qualify for a SPB (for aggressiveness of 5)
  k_execs_appl_cat_1_max         CONSTANT NUMBER := 25000; -- a plan of this appl category must be executed these many times to qualify for a SPB (for aggressiveness of 1)
  k_execs_appl_cat_1             CONSTANT NUMBER := ROUND(k_execs_appl_cat_1_max - ((k_aggressiveness - 1) * (k_execs_appl_cat_1_max - k_execs_appl_cat_1_min) / (k_aggressiveness_levels - 1)));
  k_execs_appl_cat_2_min         CONSTANT NUMBER := 5000; -- a plan of this appl category must be executed these many times to qualify for a SPB (for aggressiveness of 5)
  k_execs_appl_cat_2_max         CONSTANT NUMBER := 25000; -- a plan of this appl category must be executed these many times to qualify for a SPB (for aggressiveness of 1)
  k_execs_appl_cat_2             CONSTANT NUMBER := ROUND(k_execs_appl_cat_2_max - ((k_aggressiveness - 1) * (k_execs_appl_cat_2_max - k_execs_appl_cat_2_min) / (k_aggressiveness_levels - 1)));
  k_execs_appl_cat_3_min         CONSTANT NUMBER := 1000; -- a plan of this appl category must be executed these many times to qualify for a SPB (for aggressiveness of 5)
  k_execs_appl_cat_3_max         CONSTANT NUMBER := 5000; -- a plan of this appl category must be executed these many times to qualify for a SPB (for aggressiveness of 1)
  k_execs_appl_cat_3             CONSTANT NUMBER := ROUND(k_execs_appl_cat_3_max - ((k_aggressiveness - 1) * (k_execs_appl_cat_3_max - k_execs_appl_cat_3_min) / (k_aggressiveness_levels - 1)));
  k_execs_appl_cat_4_min         CONSTANT NUMBER := 1000; -- a plan of this appl category must be executed these many times to qualify for a SPB (for aggressiveness of 5)
  k_execs_appl_cat_4_max         CONSTANT NUMBER := 5000; -- a plan of this appl category must be executed these many times to qualify for a SPB (for aggressiveness of 1)
  k_execs_appl_cat_4             CONSTANT NUMBER := ROUND(k_execs_appl_cat_4_max - ((k_aggressiveness - 1) * (k_execs_appl_cat_4_max - k_execs_appl_cat_4_min) / (k_aggressiveness_levels - 1)));
  k_execs_non_appl_min           CONSTANT NUMBER := 1000; -- a plan of this appl category must be executed these many times to qualify for a SPB (for aggressiveness of 5)
  k_execs_non_appl_max           CONSTANT NUMBER := 5000; -- a plan of this appl category must be executed these many times to qualify for a SPB (for aggressiveness of 1)
  k_execs_non_appl               CONSTANT NUMBER := ROUND(k_execs_non_appl_max - ((k_aggressiveness - 1) * (k_execs_non_appl_max - k_execs_non_appl_min) / (k_aggressiveness_levels - 1)));
  k_secs_per_exec_cand_min       CONSTANT NUMBER := 2.000; -- (2s) a plan must perform better than this threshold to be a candidate (for aggressiveness of 1)
  k_secs_per_exec_cand_max       CONSTANT NUMBER := 10.000; -- (10s) a plan must perform better than this threshold to be a candidate (for aggressiveness of 5)
  k_secs_per_exec_cand           CONSTANT NUMBER := NVL(p_secs_per_exec_cand, ROUND(k_secs_per_exec_cand_min + ((k_aggressiveness - 1) * (k_secs_per_exec_cand_max - k_secs_per_exec_cand_min) / (k_aggressiveness_levels - 1)), 6));
  k_secs_per_exec_appl_1_min     CONSTANT NUMBER := 0.00025; --(0.25ms) a plan must perform better than this threshold to be a candidate (for aggressiveness of 1)
  k_secs_per_exec_appl_1_max     CONSTANT NUMBER := 0.00125; -- (1.25ms) a plan must perform better than this threshold to be a candidate (for aggressiveness of 5)
  k_secs_per_exec_appl_1         CONSTANT NUMBER := ROUND(k_secs_per_exec_appl_1_min + ((k_aggressiveness - 1) * (k_secs_per_exec_appl_1_max - k_secs_per_exec_appl_1_min) / (k_aggressiveness_levels - 1)), 6);
  k_secs_per_exec_appl_2_min     CONSTANT NUMBER := 0.0005; --(0.5ms) a plan must perform better than this threshold to be a candidate (for aggressiveness of 1)
  k_secs_per_exec_appl_2_max     CONSTANT NUMBER := 0.0025; -- (2.5ms) a plan must perform better than this threshold to be a candidate (for aggressiveness of 5)
  k_secs_per_exec_appl_2         CONSTANT NUMBER := ROUND(k_secs_per_exec_appl_2_min + ((k_aggressiveness - 1) * (k_secs_per_exec_appl_2_max - k_secs_per_exec_appl_2_min) / (k_aggressiveness_levels - 1)), 6);
  k_secs_per_exec_appl_3_min     CONSTANT NUMBER := 0.010; --(10ms) a plan must perform better than this threshold to be a candidate (for aggressiveness of 1)
  k_secs_per_exec_appl_3_max     CONSTANT NUMBER := 0.050; -- (50ms) a plan must perform better than this threshold to be a candidate (for aggressiveness of 5)
  k_secs_per_exec_appl_3         CONSTANT NUMBER := ROUND(k_secs_per_exec_appl_3_min + ((k_aggressiveness - 1) * (k_secs_per_exec_appl_3_max - k_secs_per_exec_appl_3_min) / (k_aggressiveness_levels - 1)), 6);
  k_secs_per_exec_appl_4_min     CONSTANT NUMBER := 1.000; --(1s) a plan must perform better than this threshold to be a candidate (for aggressiveness of 1)
  k_secs_per_exec_appl_4_max     CONSTANT NUMBER := 5.000; -- (5s) a plan must perform better than this threshold to be a candidate (for aggressiveness of 5)
  k_secs_per_exec_appl_4         CONSTANT NUMBER := ROUND(k_secs_per_exec_appl_4_min + ((k_aggressiveness - 1) * (k_secs_per_exec_appl_4_max - k_secs_per_exec_appl_4_min) / (k_aggressiveness_levels - 1)), 6);
  k_secs_per_exec_noappl_min     CONSTANT NUMBER := 0.200; --(200ms) a plan must perform better than this threshold to be a candidate (for aggressiveness of 1)
  k_secs_per_exec_noappl_max     CONSTANT NUMBER := 1.000; -- (1s) a plan must perform better than this threshold to be a candidate (for aggressiveness of 5)
  k_secs_per_exec_noappl         CONSTANT NUMBER := ROUND(k_secs_per_exec_noappl_min + ((k_aggressiveness - 1) * (k_secs_per_exec_noappl_max - k_secs_per_exec_noappl_min) / (k_aggressiveness_levels - 1)), 6);
  k_90th_pctl_factor_cat         CONSTANT NUMBER := 2; -- the 90th percentile of "Avg Elapsed Time per Exec" should be less than this many times the "secs_per_exec" threshold for a Plan to qualify for SPM
  k_95th_pctl_factor_cat         CONSTANT NUMBER := 3; -- ditto for 95th percentile
  k_97th_pctl_factor_cat         CONSTANT NUMBER := 4; -- ditto for 97th percentile
  k_99th_pctl_factor_cat         CONSTANT NUMBER := 5; -- ditto for 99th percentile
  k_90th_pctl_factor_avg         CONSTANT NUMBER := k_90th_pctl_factor_cat * 2 * k_aggressiveness; -- the 90th percentile of "Avg Elapsed Time per Exec" should be less than this many times the "MEM/AWR/Median of Avg Elapsed Time per Exec" for a Plan to qualify for SPM
  k_95th_pctl_factor_avg         CONSTANT NUMBER := k_95th_pctl_factor_cat * 2 * k_aggressiveness; -- ditto for 95th percentile
  k_97th_pctl_factor_avg         CONSTANT NUMBER := k_97th_pctl_factor_cat * 2 * k_aggressiveness; -- ditto for 97th percentile
  k_99th_pctl_factor_avg         CONSTANT NUMBER := k_99th_pctl_factor_cat * 2 * k_aggressiveness; -- ditto for 99th percentile
  k_first_load_time_days_cand    CONSTANT NUMBER := NVL(p_first_load_time_days_cand, k_aggressiveness_levels - k_aggressiveness); -- a sql must be loaded into memory at least this many days before it is considered as candidate
  k_first_load_time_days         CONSTANT NUMBER := 7 - k_aggressiveness; -- a sql must be loaded into memory at least this many days before it qualifies for a SPB
  k_fixed_mature_days            CONSTANT NUMBER := 14; -- a non-fixed SPB needs to be older than this many days in order to be promoted to "FIXED"
  k_spb_thershold_over_cat_max   CONSTANT NUMBER := 10; -- plan must perform better than 10x category max threshold
  k_spb_thershold_over_spf_perf  CONSTANT NUMBER := 100; -- plan must perform better than 100x performance at the time SPB was created
  k_awr_days                     CONSTANT NUMBER := NVL(p_awr_days, 14); -- amount of days to consider from AWR history assuming retention is at least this long
  k_display_plan                 CONSTANT CHAR(1) := 'Y'; -- include execution plan on report
  /* ---------------------------------------------------------------------------------- */
  k_appl_cat_1                   CONSTANT VARCHAR2(10) := 'BeginTx'; -- 1st application category
  k_appl_cat_2                   CONSTANT VARCHAR2(10) := 'CommitTx'; -- 2nd application category
  k_appl_cat_3                   CONSTANT VARCHAR2(10) := 'Read'; -- 3rd application category
  k_appl_cat_4                   CONSTANT VARCHAR2(10) := 'GC'; -- 4th application category
  k_source_mem                   CONSTANT VARCHAR2(30) := 'v$sql';
  k_source_awr                   CONSTANT VARCHAR2(30) := 'dba_hist_sqlstat';
  k_display_plan_format          CONSTANT VARCHAR2(100) := 'BASIC ROWS COST OUTLINE PEEKED_BINDS PREDICATE NOTE';
  k_debugging                    CONSTANT BOOLEAN := FALSE; -- future use
  /* ---------------------------------------------------------------------------------- */
  l_candidate_was_accepted       BOOLEAN;
  l_spb_promotion_was_accepted   BOOLEAN;
  l_spb_demotion_was_accepted    BOOLEAN;
  l_spb_exists                   BOOLEAN;
  l_spb_was_promoted             BOOLEAN;
  l_spb_was_created              BOOLEAN;
  l_output                       BOOLEAN;
  l_candidate_count_p            NUMBER := 0;
  l_spb_created_count_p          NUMBER := 0;
  l_spb_promoted_count_p         NUMBER := 0;
  l_spb_created_qualified_p      NUMBER := 0;
  l_spb_promoted_qualified_p     NUMBER := 0;
  l_spb_already_fixed_count_p    NUMBER := 0;
  l_candidate_count_t            NUMBER := 0;
  l_spb_created_count_t          NUMBER := 0;
  l_spb_promoted_count_t         NUMBER := 0;
  l_spb_created_qualified_t      NUMBER := 0;
  l_spb_promoted_qualified_t     NUMBER := 0;
  l_spb_already_fixed_count_t    NUMBER := 0;
  l_spb_disable_qualified_p      NUMBER := 0;
  l_spb_disable_qualified_t      NUMBER := 0;
  l_spb_disabled_count_p         NUMBER := 0;
  l_spb_disabled_count_t         NUMBER := 0;
  l_message1                     VARCHAR2(1000);
  l_message2                     VARCHAR2(1000);
  l_dbid                         NUMBER;
  l_con_id                       NUMBER;
  l_con_id_prior                 NUMBER := -666;
  l_min_snap_id                  NUMBER;
  l_max_snap_id                  NUMBER;
  l_open_mode                    VARCHAR2(20);
  l_db_name                      VARCHAR2(9);
  l_host_name                    VARCHAR2(64);
  l_pdb_name                     VARCHAR2(128);
  l_pdb_name_prior               VARCHAR2(128) := '-666';
  l_start_time			 DATE := SYSDATE;
  l_signature                    NUMBER;
  l_sql_handle                   VARCHAR2(128);
  l_plan_name                    VARCHAR2(128);
  l_description                  VARCHAR2(500);
  l_sql_text                     CLOB;
  l_sysdate                      DATE;
  l_sqlset_name                  VARCHAR2(30);
  l_plans_returned               NUMBER;
  l_instance_startup_time        DATE;
  l_us_per_exec_c                NUMBER;
  l_us_per_exec_b                NUMBER;
  b_rec                          cdb_sql_plan_baselines%ROWTYPE;
  /* ---------------------------------------------------------------------------------- */
  CURSOR candidate_plan
  IS
    WITH
    pdbs AS (
    SELECT /*+ MATERIALIZE NO_MERGE */ -- disjoint for perf reasons
           con_id,
           name pdb_name
      FROM v$pdbs
     WHERE open_mode = 'READ WRITE'
    ),
    mem_plan_metrics AS (
    SELECT /*+ MATERIALIZE NO_MERGE */
           c.con_id,
           p.pdb_name,         
           c.parsing_schema_name,
           c.sql_id,
           SUBSTR(c.sql_text, 1, 108) sql_text,
           COUNT(*) child_cursors,
           MIN(c.child_number) min_child_number,
           MAX(c.child_number) max_child_number,
           c.plan_hash_value,
           k_source_mem metrics_source,
           SUM(c.executions) executions,
           SUM(c.buffer_gets) buffer_gets,
           SUM(c.disk_reads) disk_reads,
           SUM(c.rows_processed) rows_processed,
           SUM(c.sharable_mem) sharable_mem,
           SUM(c.elapsed_time) elapsed_time,
           SUM(c.cpu_time) cpu_time,
           SUM(c.user_io_wait_time) user_io_wait_time,
           SUM(c.application_wait_time) application_wait_time,
           SUM(c.concurrency_wait_time) concurrency_wait_time,
           MIN(c.optimizer_cost) min_optimizer_cost,
           MAX(c.optimizer_cost) max_optimizer_cost,
           MAX(c.module) module,
           MAX(c.action) action,
           MAX(c.last_active_time) last_active_time, -- newest
           MIN(TO_DATE(c.last_load_time, 'YYYY-MM-DD/HH24:MI:SS')) last_load_time, -- oldest
           MIN(TO_DATE(c.first_load_time, 'YYYY-MM-DD/HH24:MI:SS')) first_load_time, -- oldest
           c.sql_profile,
           c.sql_patch,
           c.sql_plan_baseline,
           c.exact_matching_signature
      FROM v$sql c,
           cdb_users pu,
           cdb_users ps,
           pdbs p
     WHERE c.con_id > 2 -- exclude CDB$ROOT and PDB$SEED
       AND c.parsing_user_id > 0 -- exclude SYS
       AND c.parsing_schema_id > 0 -- exclude SYS
       AND c.parsing_schema_name NOT LIKE 'C##'||CHR(37)
       AND c.plan_hash_value > 0
       AND c.executions > 0
       AND c.elapsed_time > 0
       AND pu.con_id = c.con_id
       AND pu.user_id = c.parsing_user_id
       AND pu.oracle_maintained = 'N'
       AND ps.con_id = c.con_id
       AND ps.user_id = c.parsing_schema_id
       AND ps.oracle_maintained = 'N'
       AND p.con_id = c.con_id
       AND (NVL(k_pdb_name, 'ALL') = 'ALL' OR p.pdb_name = k_pdb_name)
       AND (NVL(k_sql_id, 'ALL') = 'ALL' OR c.sql_id = k_sql_id)
       -- subquery c1 is to skip a cursor that has no SPB yet, but there are other
       -- active cursors for same SQL_ID that already have a SPB.
       -- if a SQL has already a SPB in use at the time this tool executes, we simply do not
       -- want to create a new one plan in SPB. reason is that maybe an earlier execution of this
       -- tool with a lower aggressiveness level just created a SPB, then on a subsequent
       -- execution of this tool we don't want to create a lower-quality SPB if we already
       -- have one created by more conservative level 1 execution.
       AND CASE
             WHEN c.sql_plan_baseline IS NULL THEN 
               -- verify there are no cursors with active SPB
               ( SELECT /*+ NO_MERGE QB_NAME(c1) */ COUNT(*)
                   FROM v$sql c1
                  WHERE c1.con_id = c.con_id
                    AND c1.parsing_schema_name = c.parsing_schema_name
                    AND c1.sql_id = c.sql_id
                    AND c1.sql_plan_baseline IS NOT NULL
                    AND c1.is_obsolete = 'N'
                    AND c1.is_shareable = 'Y'
                    AND SUBSTR(c1.object_status, 1, 5) = 'VALID'
                    AND c1.parsing_user_id > 0
                    AND c1.parsing_schema_id > 0
                    AND c1.parsing_schema_name NOT LIKE 'C##'||CHR(37)
                    AND c1.plan_hash_value > 0
                    AND c1.executions > 0
                    AND c1.elapsed_time > 0
                    AND ROWNUM = 1
               )
             ELSE 0 -- c.sql_plan_baseline IS NOT NULL (this cursor has a SPB)
             END = 0
     GROUP BY
           c.con_id,
           p.pdb_name,         
           c.parsing_schema_name,
           c.sql_id,
           SUBSTR(c.sql_text, 1, 108),
           c.plan_hash_value,
           c.sql_profile,
           c.sql_patch,
           c.sql_plan_baseline,
           c.exact_matching_signature
    HAVING MIN(c.is_obsolete) = 'N'
       AND MAX(c.is_shareable) = 'Y'
       AND MAX(SUBSTR(c.object_status, 1, 5)) = 'VALID'
       AND SUM(c.executions) > k_execs_candidate_min
       --AND (SUM(c.elapsed_time) / SUM(c.executions) / 1e6) < k_secs_per_exec_cand_max (removed to trap SPB regressions)
       AND MIN(TO_DATE(c.first_load_time, 'YYYY-MM-DD/HH24:MI:SS')) < SYSDATE - k_first_load_time_days_cand -- oldest
       AND MAX(c.last_active_time) > SYSDATE - k_awr_days -- ignore old plans that haven't been executed for a while
    )
    , awr_plan_metrics AS (
    SELECT /*+ MATERIALIZE NO_MERGE */
           c.con_id,
           p.pdb_name,  
           SUBSTR(c.parsing_schema_name, 1, 30) parsing_schema_name,
           c.sql_id,
           ( SELECT DBMS_LOB.SUBSTR(t.sql_text, 108) 
               FROM dba_hist_sqltext t
              WHERE t.sql_id = c.sql_id
                AND t.dbid   = l_dbid
                AND ROWNUM   = 1
           ) sql_text,
           c.plan_hash_value,
           k_source_awr metrics_source,
           SUM(c.executions_total) executions,
           SUM(c.buffer_gets_total) buffer_gets,
           SUM(c.disk_reads_total) disk_reads,
           SUM(c.rows_processed_total) rows_processed,
           SUM(c.sharable_mem) sharable_mem,
           SUM(c.elapsed_time_total) elapsed_time,
           SUM(c.cpu_time_total) cpu_time,
           SUM(c.iowait_total) user_io_wait_time,
           SUM(c.apwait_total) application_wait_time,
           SUM(c.ccwait_total) concurrency_wait_time,
           MIN(c.optimizer_cost) min_optimizer_cost,
           MAX(c.optimizer_cost) max_optimizer_cost,
           MAX(c.module) module,
           MAX(c.action) action,
           CAST(MAX(s.end_interval_time) AS DATE) last_active_time, -- newest
           c.sql_profile,
           c.snap_id,
           ROW_NUMBER() OVER (PARTITION BY c.con_id, SUBSTR(c.parsing_schema_name, 1, 30), c.sql_id, c.plan_hash_value ORDER BY c.snap_id DESC NULLS LAST) newest,
           ROW_NUMBER() OVER (PARTITION BY c.con_id, SUBSTR(c.parsing_schema_name, 1, 30), c.sql_id, c.plan_hash_value ORDER BY c.snap_id ASC  NULLS LAST) oldest
      FROM dba_hist_sqlstat c,
           dba_hist_snapshot s,
           cdb_users pu,
           cdb_users ps,
           pdbs p
     WHERE c.con_id > 2 -- exclude CDB$ROOT and PDB$SEED
       AND c.parsing_user_id > 0 -- exclude SYS
       AND c.parsing_schema_id > 0 -- exclude SYS
       AND c.parsing_schema_name NOT LIKE 'C##'||CHR(37)
       AND c.plan_hash_value > 0
       AND c.executions_total > 0
       AND c.elapsed_time_total > 0
       AND c.dbid = l_dbid
       AND c.snap_id >= l_min_snap_id
       AND s.snap_id = c.snap_id
       AND s.dbid = c.dbid
       AND s.instance_number = c.instance_number
       AND CAST(s.end_interval_time AS DATE) < SYSDATE - k_first_load_time_days_cand -- oldest
       AND pu.con_id = c.con_id
       AND pu.user_id = c.parsing_user_id
       AND pu.oracle_maintained = 'N'
       AND ps.con_id = c.con_id
       AND ps.user_id = c.parsing_schema_id
       AND ps.oracle_maintained = 'N'
       AND p.con_id = c.con_id
       AND (NVL(k_pdb_name, 'ALL') = 'ALL' OR p.pdb_name = k_pdb_name)
       AND (NVL(k_sql_id, 'ALL') = 'ALL' OR c.sql_id = k_sql_id)
       -- subqueries m1 and m2 below are needed to include awr plans for which there is
       -- no cursor, as long as their SQL is active (has at least one cursor under a 
       -- different plan but with no SPB), and the plan is not already being considered 
       -- from an existing cursor from shared pool.
       -- we don't want to select from awr a plan that we are already selecting from
       -- shared pool since the one from awr does not store sql_plan_baseline, then we
       -- could be creating and re-creating the same spb from awr every time we execute
       -- this script. 
       -- Three scenarios are handled by m1 and m2:
       -- 1. if plan x comes from awr, and shared pool contains plans x, y and z, then
       --    plan x from awr is filtered out (since awr lacks sql_plan_baseline column).
       -- 2. if plan x comes from awr, and shared pool contains only plans y and z, then
       --    plan x from awr is selected (since this plan x is a potential candidate).
       -- 3. if plan x comes from awr, and there are no plans on shared pool, then
       --    plan x from awr is filtered out (SQL is not in use).
       -- Note that if SQL has already a SPB as per cursors in shared pool, then we do
       -- not consider plans from awr.
       AND EXISTS -- SQL has at least one cursor with a plan y or z other than this x, but no SPB
           ( SELECT /*+ NO_MERGE QB_NAME(m1) */ NULL 
               FROM mem_plan_metrics m1
              WHERE m1.con_id = c.con_id
                AND m1.parsing_schema_name = SUBSTR(c.parsing_schema_name, 1, 30)
                AND m1.sql_id = c.sql_id
                AND m1.plan_hash_value <> c.plan_hash_value
                AND m1.sql_plan_baseline IS NULL
           )
       AND NOT EXISTS -- There are no cursors with this plan x
           ( SELECT /*+ NO_MERGE QB_NAME(m2) */ NULL
               FROM mem_plan_metrics m2
              WHERE m2.con_id = c.con_id
                AND m2.parsing_schema_name = SUBSTR(c.parsing_schema_name, 1, 30)
                AND m2.sql_id = c.sql_id
                AND m2.plan_hash_value = c.plan_hash_value
           )
     GROUP BY
           c.con_id,
           p.pdb_name,         
           SUBSTR(c.parsing_schema_name, 1, 30),
           c.sql_id,
           c.plan_hash_value,
           c.sql_profile,
           c.snap_id
    HAVING SUM(c.executions_total) > k_execs_candidate_min
       --AND (SUM(c.elapsed_time_total) / SUM(c.executions_total) / 1e6) < k_secs_per_exec_cand_max (removed to trap SPB regressions)
       --AND CAST(MAX(s.end_interval_time) AS DATE) > SYSDATE - k_awr_days -- ignore old plans that haven't been executed for a while (redundant due to c.snap_id >= l_min_snap_id)
    )
    , mem_and_awr_plan_metrics AS (
    SELECT /*+ MATERIALIZE NO_MERGE */
           m.con_id,
           m.pdb_name,         
           m.parsing_schema_name,
           m.sql_id,
           m.sql_text,
           m.child_cursors,
           m.min_child_number,
           m.max_child_number,
           m.plan_hash_value,
           m.metrics_source,
           m.executions,
           m.buffer_gets,
           m.disk_reads,
           m.rows_processed,
           m.sharable_mem,
           m.elapsed_time,
           m.cpu_time,
           m.user_io_wait_time,
           m.application_wait_time,
           m.concurrency_wait_time,
           m.min_optimizer_cost,
           m.max_optimizer_cost,
           m.module,
           m.action,
           m.last_active_time,
           m.last_load_time, 
           m.first_load_time, 
           m.sql_profile,
           m.sql_patch,
           m.sql_plan_baseline,
           m.exact_matching_signature
      FROM mem_plan_metrics m
     UNION ALL
    SELECT /*+ MATERIALIZE NO_MERGE */
           a.con_id,
           a.pdb_name,         
           a.parsing_schema_name,
           a.sql_id,
           a.sql_text,
           TO_NUMBER(NULL) child_cursors,
           TO_NUMBER(NULL) min_child_number,
           TO_NUMBER(NULL) max_child_number,
           a.plan_hash_value,
           a.metrics_source,
           a.executions,
           a.buffer_gets,
           a.disk_reads,
           a.rows_processed,
           a.sharable_mem,
           a.elapsed_time,
           a.cpu_time,
           a.user_io_wait_time,
           a.application_wait_time,
           a.concurrency_wait_time,
           a.min_optimizer_cost,
           a.max_optimizer_cost,
           a.module,
           a.action,
           a.last_active_time,
           TO_DATE(NULL) last_load_time,
           ( SELECT o.last_active_time 
               FROM awr_plan_metrics o 
              WHERE o.con_id = a.con_id 
                AND o.parsing_schema_name = a.parsing_schema_name
                AND o.sql_id = a.sql_id
                AND o.plan_hash_value = a.plan_hash_value
                AND o.oldest = 1
           ) first_load_time, 
           a.sql_profile,
           TO_CHAR(NULL) sql_patch,
           TO_CHAR(NULL) sql_plan_baseline,
           TO_NUMBER(NULL) exact_matching_signature
      FROM awr_plan_metrics a
     WHERE a.newest = 1
    )
    , plan_performance_time_series AS (
    SELECT /*+ MATERIALIZE NO_MERGE */
           h.con_id,
           h.sql_id,
           h.plan_hash_value,
           h.snap_id,
           SUM(h.executions_delta)/((CAST(s.end_interval_time AS DATE) - CAST(s.begin_interval_time AS DATE)) * 24 * 60 * 60) execs_per_sec,
           SUM(h.buffer_gets_delta)/SUM(h.executions_delta) buffer_gets_per_exec,
           SUM(h.disk_reads_delta)/SUM(h.executions_delta) disk_reads_per_exec,
           SUM(h.rows_processed_delta)/SUM(h.executions_delta) rows_processed_per_exec,
           SUM(h.sharable_mem) sharable_mem,
           SUM(h.elapsed_time_delta)/SUM(h.executions_delta) avg_et_us,
           SUM(h.cpu_time_delta)/SUM(h.executions_delta) avg_cpu_us,
           SUM(h.iowait_delta)/SUM(h.executions_delta) avg_user_io_us,
           SUM(h.apwait_delta)/SUM(h.executions_delta) avg_application_us,
           SUM(h.ccwait_delta)/SUM(h.executions_delta) avg_concurrency_us,
           MIN(h.optimizer_cost) min_optimizer_cost,
           MAX(h.optimizer_cost) max_optimizer_cost
      FROM dba_hist_sqlstat h,
           dba_hist_snapshot s
     WHERE h.dbid = l_dbid
       AND h.snap_id >= l_min_snap_id
       AND h.executions_delta > 0
       AND (h.con_id, h.sql_id, h.plan_hash_value) IN (SELECT cm.con_id, cm.sql_id, cm.plan_hash_value FROM mem_and_awr_plan_metrics cm)
       AND s.snap_id = h.snap_id
       AND s.dbid = h.dbid
       AND s.instance_number = h.instance_number
     GROUP BY
           h.con_id,
           h.sql_id,
           h.plan_hash_value,
           h.snap_id,
           s.end_interval_time,
           s.begin_interval_time
    )
    , plan_performance_metrics AS (
    SELECT /*+ MATERIALIZE NO_MERGE */
           con_id,
           sql_id,
           plan_hash_value,
           COUNT(*) awr_snapshots,
           AVG(execs_per_sec) avg_execs_per_sec,
           MAX(execs_per_sec) max_execs_per_sec,
           PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY execs_per_sec) p99_execs_per_sec,
           PERCENTILE_DISC(0.97) WITHIN GROUP (ORDER BY execs_per_sec) p97_execs_per_sec,
           PERCENTILE_DISC(0.95) WITHIN GROUP (ORDER BY execs_per_sec) p95_execs_per_sec,
           PERCENTILE_DISC(0.90) WITHIN GROUP (ORDER BY execs_per_sec) p90_execs_per_sec,
           MEDIAN(execs_per_sec) med_execs_per_sec,
           AVG(buffer_gets_per_exec) avg_buffer_gets_per_exec,
           MAX(buffer_gets_per_exec) max_buffer_gets_per_exec,
           PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY buffer_gets_per_exec) p99_buffer_gets_per_exec,
           PERCENTILE_DISC(0.97) WITHIN GROUP (ORDER BY buffer_gets_per_exec) p97_buffer_gets_per_exec,
           PERCENTILE_DISC(0.95) WITHIN GROUP (ORDER BY buffer_gets_per_exec) p95_buffer_gets_per_exec,
           PERCENTILE_DISC(0.90) WITHIN GROUP (ORDER BY buffer_gets_per_exec) p90_buffer_gets_per_exec,
           MEDIAN(buffer_gets_per_exec) med_buffer_gets_per_exec,
           AVG(disk_reads_per_exec) avg_disk_reads_per_exec,
           MAX(disk_reads_per_exec) max_disk_reads_per_exec,
           PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY disk_reads_per_exec) p99_disk_reads_per_exec,
           PERCENTILE_DISC(0.97) WITHIN GROUP (ORDER BY disk_reads_per_exec) p97_disk_reads_per_exec,
           PERCENTILE_DISC(0.95) WITHIN GROUP (ORDER BY disk_reads_per_exec) p95_disk_reads_per_exec,
           PERCENTILE_DISC(0.90) WITHIN GROUP (ORDER BY disk_reads_per_exec) p90_disk_reads_per_exec,
           MEDIAN(disk_reads_per_exec) med_disk_reads_per_exec,
           AVG(rows_processed_per_exec) avg_rows_processed_per_exec,
           MAX(rows_processed_per_exec) max_rows_processed_per_exec,
           PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY rows_processed_per_exec) p99_rows_processed_per_exec,
           PERCENTILE_DISC(0.97) WITHIN GROUP (ORDER BY rows_processed_per_exec) p97_rows_processed_per_exec,
           PERCENTILE_DISC(0.95) WITHIN GROUP (ORDER BY rows_processed_per_exec) p95_rows_processed_per_exec,
           PERCENTILE_DISC(0.90) WITHIN GROUP (ORDER BY rows_processed_per_exec) p90_rows_processed_per_exec,
           MEDIAN(rows_processed_per_exec) med_rows_processed_per_exec,
           AVG(sharable_mem) avg_sharable_mem,
           MAX(sharable_mem) max_sharable_mem,
           PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY sharable_mem) p99_sharable_mem,
           PERCENTILE_DISC(0.97) WITHIN GROUP (ORDER BY sharable_mem) p97_sharable_mem,
           PERCENTILE_DISC(0.95) WITHIN GROUP (ORDER BY sharable_mem) p95_sharable_mem,
           PERCENTILE_DISC(0.90) WITHIN GROUP (ORDER BY sharable_mem) p90_sharable_mem,
           MEDIAN(sharable_mem) med_sharable_mem,
           AVG(avg_et_us) avg_avg_et_us,
           MAX(avg_et_us) max_avg_et_us,
           PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY avg_et_us) p99_avg_et_us,
           PERCENTILE_DISC(0.97) WITHIN GROUP (ORDER BY avg_et_us) p97_avg_et_us,
           PERCENTILE_DISC(0.95) WITHIN GROUP (ORDER BY avg_et_us) p95_avg_et_us,
           PERCENTILE_DISC(0.90) WITHIN GROUP (ORDER BY avg_et_us) p90_avg_et_us,
           MEDIAN(avg_et_us) med_avg_et_us,
           AVG(avg_cpu_us) avg_avg_cpu_us,
           MAX(avg_cpu_us) max_avg_cpu_us,
           PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY avg_cpu_us) p99_avg_cpu_us,
           PERCENTILE_DISC(0.97) WITHIN GROUP (ORDER BY avg_cpu_us) p97_avg_cpu_us,
           PERCENTILE_DISC(0.95) WITHIN GROUP (ORDER BY avg_cpu_us) p95_avg_cpu_us,
           PERCENTILE_DISC(0.90) WITHIN GROUP (ORDER BY avg_cpu_us) p90_avg_cpu_us,
           MEDIAN(avg_cpu_us) med_avg_cpu_us,
           AVG(avg_user_io_us) avg_avg_user_io_us,
           MAX(avg_user_io_us) max_avg_user_io_us,
           PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY avg_user_io_us) p99_avg_user_io_us,
           PERCENTILE_DISC(0.97) WITHIN GROUP (ORDER BY avg_user_io_us) p97_avg_user_io_us,
           PERCENTILE_DISC(0.95) WITHIN GROUP (ORDER BY avg_user_io_us) p95_avg_user_io_us,
           PERCENTILE_DISC(0.90) WITHIN GROUP (ORDER BY avg_user_io_us) p90_avg_user_io_us,
           MEDIAN(avg_user_io_us) med_avg_user_io_us,
           AVG(avg_application_us) avg_avg_application_us,
           MAX(avg_application_us) max_avg_application_us,
           PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY avg_application_us) p99_avg_application_us,
           PERCENTILE_DISC(0.97) WITHIN GROUP (ORDER BY avg_application_us) p97_avg_application_us,
           PERCENTILE_DISC(0.95) WITHIN GROUP (ORDER BY avg_application_us) p95_avg_application_us,
           PERCENTILE_DISC(0.90) WITHIN GROUP (ORDER BY avg_application_us) p90_avg_application_us,
           MEDIAN(avg_application_us) med_avg_application_us,
           AVG(avg_concurrency_us) avg_avg_concurrency_us,
           MAX(avg_concurrency_us) max_avg_concurrency_us,
           PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY avg_concurrency_us) p99_avg_concurrency_us,
           PERCENTILE_DISC(0.97) WITHIN GROUP (ORDER BY avg_concurrency_us) p97_avg_concurrency_us,
           PERCENTILE_DISC(0.95) WITHIN GROUP (ORDER BY avg_concurrency_us) p95_avg_concurrency_us,
           PERCENTILE_DISC(0.90) WITHIN GROUP (ORDER BY avg_concurrency_us) p90_avg_concurrency_us,
           MEDIAN(avg_concurrency_us) med_avg_concurrency_us,
           MIN(min_optimizer_cost) min_optimizer_cost,
           MAX(max_optimizer_cost) max_optimizer_cost
      FROM plan_performance_time_series
     GROUP BY
           con_id,
           sql_id,
           plan_hash_value
    ) -- Categorize SQL statement
    , extended_plan_metrics AS ( -- adding application_category
    SELECT /*+ MATERIALIZE NO_MERGE */
           cm.con_id,
           cm.pdb_name,         
           cm.parsing_schema_name,
           cm.sql_id,
           cm.sql_text,
           CASE 
             WHEN cm.sql_text LIKE '/* addTransactionRow('||CHR(37)||') */'||CHR(37) 
               OR cm.sql_text LIKE '/* checkStartRowValid('||CHR(37)||') */'||CHR(37) 
             THEN k_appl_cat_1
             WHEN cm.sql_text LIKE '/* findMatchingRows('||CHR(37)||') */'||CHR(37) 
               OR cm.sql_text LIKE '/* readTransactionsSince('||CHR(37)||') */'||CHR(37) 
               OR cm.sql_text LIKE '/* writeTransactionKeys('||CHR(37)||') */'||CHR(37) 
               OR cm.sql_text LIKE '/* setValueByUpdate('||CHR(37)||') */'||CHR(37) 
               OR cm.sql_text LIKE '/* setValue('||CHR(37)||') */'||CHR(37) 
               OR cm.sql_text LIKE '/* deleteValue('||CHR(37)||') */'||CHR(37) 
               OR cm.sql_text LIKE '/* exists('||CHR(37)||') */'||CHR(37) 
               OR cm.sql_text LIKE '/* existsUnique('||CHR(37)||') */'||CHR(37) 
               OR cm.sql_text LIKE '/* updateIdentityValue('||CHR(37)||') */'||CHR(37) 
               --OR cm.sql_text LIKE 'LOCK TABLE '||CHR(37)||' IN EXCLUSIVE MODE'||CHR(37) 
               OR cm.sql_text LIKE '/* getTransactionProgress('||CHR(37)||') */'||CHR(37) 
               OR cm.sql_text LIKE '/* recordTransactionState('||CHR(37)||') */'||CHR(37) 
               OR cm.sql_text LIKE '/* checkEndRowValid('||CHR(37)||') */'||CHR(37)
             THEN k_appl_cat_2
             WHEN cm.sql_text LIKE '/* getValues('||CHR(37)||') */'||CHR(37) 
               OR cm.sql_text LIKE '/* getNextIdentityValue('||CHR(37)||') */'||CHR(37) 
               OR cm.sql_text LIKE '/* performScanQuery('||CHR(37)||') */'||CHR(37)
             THEN k_appl_cat_3
             WHEN cm.sql_text LIKE '/* populateBucketGCWorkspace */'||CHR(37) 
               OR cm.sql_text LIKE '/* deleteBucketGarbage */'||CHR(37) 
               OR cm.sql_text LIKE '/* Populate workspace for transaction GC */'||CHR(37) 
               OR cm.sql_text LIKE '/* Delete garbage for transaction GC */'||CHR(37) 
               OR cm.sql_text LIKE '/* Populate workspace in KTK GC */'||CHR(37) 
               OR cm.sql_text LIKE '/* Delete garbage in KTK GC */'||CHR(37) 
               OR cm.sql_text LIKE '/* hashBucket */'||CHR(37) 
             THEN k_appl_cat_4
           END application_category,
           cm.plan_hash_value,
           cm.metrics_source,
           cm.child_cursors,
           cm.min_child_number,
           cm.max_child_number,
           cm.executions,
           cm.buffer_gets,
           cm.disk_reads,
           cm.rows_processed,
           cm.sharable_mem,
           cm.elapsed_time,
           cm.cpu_time,
           cm.user_io_wait_time,
           cm.application_wait_time,
           cm.concurrency_wait_time,
           cm.min_optimizer_cost,
           cm.max_optimizer_cost,
           cm.module,
           cm.action,
           cm.last_active_time,
           cm.last_load_time,
           cm.first_load_time,
           cm.sql_profile,
           cm.sql_patch,
           cm.sql_plan_baseline,
           cm.exact_matching_signature,
           pm.awr_snapshots,
           pm.avg_execs_per_sec,
           pm.max_execs_per_sec,
           pm.p99_execs_per_sec,
           pm.p97_execs_per_sec,
           pm.p95_execs_per_sec,
           pm.p90_execs_per_sec,
           pm.med_execs_per_sec,
           pm.avg_buffer_gets_per_exec,
           pm.max_buffer_gets_per_exec,
           pm.p99_buffer_gets_per_exec,
           pm.p97_buffer_gets_per_exec,
           pm.p95_buffer_gets_per_exec,
           pm.p90_buffer_gets_per_exec,
           pm.med_buffer_gets_per_exec,
           pm.avg_disk_reads_per_exec,
           pm.max_disk_reads_per_exec,
           pm.p99_disk_reads_per_exec,
           pm.p97_disk_reads_per_exec,
           pm.p95_disk_reads_per_exec,
           pm.p90_disk_reads_per_exec,
           pm.med_disk_reads_per_exec,
           pm.avg_rows_processed_per_exec,
           pm.max_rows_processed_per_exec,
           pm.p99_rows_processed_per_exec,
           pm.p97_rows_processed_per_exec,
           pm.p95_rows_processed_per_exec,
           pm.p90_rows_processed_per_exec,
           pm.med_rows_processed_per_exec,
           pm.avg_sharable_mem,
           pm.max_sharable_mem,
           pm.p99_sharable_mem,
           pm.p97_sharable_mem,
           pm.p95_sharable_mem,
           pm.p90_sharable_mem,
           pm.med_sharable_mem,
           pm.avg_avg_et_us,
           pm.max_avg_et_us,
           pm.p99_avg_et_us,
           pm.p97_avg_et_us,
           pm.p95_avg_et_us,
           pm.p90_avg_et_us,
           pm.med_avg_et_us,
           pm.avg_avg_cpu_us,
           pm.max_avg_cpu_us,
           pm.p99_avg_cpu_us,
           pm.p97_avg_cpu_us,
           pm.p95_avg_cpu_us,
           pm.p90_avg_cpu_us,
           pm.med_avg_cpu_us,
           pm.avg_avg_user_io_us,
           pm.max_avg_user_io_us,
           pm.p99_avg_user_io_us,
           pm.p97_avg_user_io_us,
           pm.p95_avg_user_io_us,
           pm.p90_avg_user_io_us,
           pm.med_avg_user_io_us,
           pm.avg_avg_application_us,
           pm.max_avg_application_us,
           pm.p99_avg_application_us,
           pm.p97_avg_application_us,
           pm.p95_avg_application_us,
           pm.p90_avg_application_us,
           pm.med_avg_application_us,
           pm.avg_avg_concurrency_us,
           pm.max_avg_concurrency_us,
           pm.p99_avg_concurrency_us,
           pm.p97_avg_concurrency_us,
           pm.p95_avg_concurrency_us,
           pm.p90_avg_concurrency_us,
           pm.med_avg_concurrency_us
      FROM mem_and_awr_plan_metrics cm,
           plan_performance_metrics pm
     WHERE pm.con_id(+) = cm.con_id
       AND pm.sql_id(+) = cm.sql_id
       AND pm.plan_hash_value(+) = cm.plan_hash_value
    )
    SELECT con_id,
           pdb_name,         
           parsing_schema_name,
           sql_id,
           sql_text,
           CASE application_category
             WHEN k_appl_cat_1 THEN 'Y'
             WHEN k_appl_cat_2 THEN 'Y'
             WHEN k_appl_cat_3 THEN 'N'
             WHEN k_appl_cat_4 THEN 'Y'
           END critical_application,
           application_category,
           plan_hash_value,
           metrics_source,
           child_cursors,
           min_child_number,
           max_child_number,
           executions,
           buffer_gets,
           disk_reads,
           rows_processed,
           sharable_mem,
           elapsed_time,
           cpu_time,
           user_io_wait_time,
           application_wait_time,
           concurrency_wait_time,
           min_optimizer_cost,
           max_optimizer_cost,
           module,
           action,
           last_active_time,
           last_load_time,
           first_load_time,
           sql_profile,
           sql_patch,
           sql_plan_baseline,
           exact_matching_signature,
           awr_snapshots,
           avg_execs_per_sec,
           max_execs_per_sec,
           p99_execs_per_sec,
           p97_execs_per_sec,
           p95_execs_per_sec,
           p90_execs_per_sec,
           med_execs_per_sec,
           avg_buffer_gets_per_exec,
           max_buffer_gets_per_exec,
           p99_buffer_gets_per_exec,
           p97_buffer_gets_per_exec,
           p95_buffer_gets_per_exec,
           p90_buffer_gets_per_exec,
           med_buffer_gets_per_exec,
           avg_disk_reads_per_exec,
           max_disk_reads_per_exec,
           p99_disk_reads_per_exec,
           p97_disk_reads_per_exec,
           p95_disk_reads_per_exec,
           p90_disk_reads_per_exec,
           med_disk_reads_per_exec,
           avg_rows_processed_per_exec,
           max_rows_processed_per_exec,
           p99_rows_processed_per_exec,
           p97_rows_processed_per_exec,
           p95_rows_processed_per_exec,
           p90_rows_processed_per_exec,
           med_rows_processed_per_exec,
           avg_sharable_mem,
           max_sharable_mem,
           p99_sharable_mem,
           p97_sharable_mem,
           p95_sharable_mem,
           p90_sharable_mem,
           med_sharable_mem,
           avg_avg_et_us,
           max_avg_et_us,
           p99_avg_et_us,
           p97_avg_et_us,
           p95_avg_et_us,
           p90_avg_et_us,
           med_avg_et_us,
           avg_avg_cpu_us,
           max_avg_cpu_us,
           p99_avg_cpu_us,
           p97_avg_cpu_us,
           p95_avg_cpu_us,
           p90_avg_cpu_us,
           med_avg_cpu_us,
           avg_avg_user_io_us,
           max_avg_user_io_us,
           p99_avg_user_io_us,
           p97_avg_user_io_us,
           p95_avg_user_io_us,
           p90_avg_user_io_us,
           med_avg_user_io_us,
           avg_avg_application_us,
           max_avg_application_us,
           p99_avg_application_us,
           p97_avg_application_us,
           p95_avg_application_us,
           p90_avg_application_us,
           med_avg_application_us,
           avg_avg_concurrency_us,
           max_avg_concurrency_us,
           p99_avg_concurrency_us,
           p97_avg_concurrency_us,
           p95_avg_concurrency_us,
           p90_avg_concurrency_us,
           med_avg_concurrency_us,
           CASE application_category
             WHEN k_appl_cat_1 THEN k_secs_per_exec_appl_1
             WHEN k_appl_cat_2 THEN k_secs_per_exec_appl_2
             WHEN k_appl_cat_3 THEN k_secs_per_exec_appl_3
             WHEN k_appl_cat_4 THEN k_secs_per_exec_appl_4
             ELSE k_secs_per_exec_noappl
           END secs_per_exec_threshold,
           CASE application_category
             WHEN k_appl_cat_1 THEN k_secs_per_exec_appl_1_min
             WHEN k_appl_cat_2 THEN k_secs_per_exec_appl_2_min
             WHEN k_appl_cat_3 THEN k_secs_per_exec_appl_3_min
             WHEN k_appl_cat_4 THEN k_secs_per_exec_appl_4_min
             ELSE k_secs_per_exec_noappl_min
           END secs_per_exec_threshold_min,
           CASE application_category
             WHEN k_appl_cat_1 THEN k_secs_per_exec_appl_1_max
             WHEN k_appl_cat_2 THEN k_secs_per_exec_appl_2_max
             WHEN k_appl_cat_3 THEN k_secs_per_exec_appl_3_max
             WHEN k_appl_cat_4 THEN k_secs_per_exec_appl_4_max
             ELSE k_secs_per_exec_noappl_max
           END secs_per_exec_threshold_max,
           CASE application_category
             WHEN k_appl_cat_1 THEN k_execs_appl_cat_1
             WHEN k_appl_cat_2 THEN k_execs_appl_cat_2
             WHEN k_appl_cat_3 THEN k_execs_appl_cat_3
             WHEN k_appl_cat_4 THEN k_execs_appl_cat_4
             ELSE k_execs_non_appl
           END executions_threshold,
           CASE application_category
             WHEN k_appl_cat_1 THEN k_execs_appl_cat_1_min
             WHEN k_appl_cat_2 THEN k_execs_appl_cat_2_min
             WHEN k_appl_cat_3 THEN k_execs_appl_cat_3_min
             WHEN k_appl_cat_4 THEN k_execs_appl_cat_4_min
             ELSE k_execs_non_appl_min
           END executions_threshold_min,
           CASE application_category
             WHEN k_appl_cat_1 THEN k_execs_appl_cat_1_max
             WHEN k_appl_cat_2 THEN k_execs_appl_cat_2_max
             WHEN k_appl_cat_3 THEN k_execs_appl_cat_3_max
             WHEN k_appl_cat_4 THEN k_execs_appl_cat_4_max
             ELSE k_execs_non_appl_max
           END executions_threshold_max
      FROM extended_plan_metrics
     WHERE (    (k_incl_plans_appl_1    = 'Y' AND application_category = k_appl_cat_1) 
             OR (k_incl_plans_appl_2    = 'Y' AND application_category = k_appl_cat_2)
             OR (k_incl_plans_appl_3    = 'Y' AND application_category = k_appl_cat_3)
             OR (k_incl_plans_appl_4    = 'Y' AND application_category = k_appl_cat_4)
             OR (k_incl_plans_non_appl  = 'Y' AND application_category IS NULL)
           )
     ORDER BY
           con_id, -- 1st since we have subtotals per PDB
           CASE application_category
             WHEN k_appl_cat_1 THEN 1 
             WHEN k_appl_cat_2 THEN 2 
             WHEN k_appl_cat_3 THEN 3 
             WHEN k_appl_cat_4 THEN 4 
             ELSE 5 
           END,
           elapsed_time / executions, -- fast SQL first
           sql_id,
           plan_hash_value;  
  /* ---------------------------------------------------------------------------------- */
  PROCEDURE get_spb_rec (p_signature IN NUMBER, p_plan_name IN VARCHAR2, p_con_id IN NUMBER)
  IS
  BEGIN
    SELECT b.* 
      INTO b_rec 
      FROM cdb_sql_plan_baselines b
     WHERE b.con_id = p_con_id 
       AND b.signature = p_signature
       AND b.plan_name = p_plan_name;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      b_rec := NULL;
  END get_spb_rec;
  /* ---------------------------------------------------------------------------------- */  
  PROCEDURE load_plan_from_cursor_cache (p_sql_id IN VARCHAR2, p_plan_hash_value IN VARCHAR2, p_con_name IN VARCHAR2, r_plans OUT NUMBER)
  IS
    l_cursor_id INTEGER;
    l_statement CLOB;
    l_rows      INTEGER;
  BEGIN
    l_statement := 
    q'[DECLARE PRAGMA AUTONOMOUS_TRANSACTION; BEGIN ]'||CHR(10)||
    q'[:plans := DBMS_SPM.LOAD_PLANS_FROM_CURSOR_CACHE(sql_id => :sql_id, plan_hash_value => :plan_hash_value); ]'||CHR(10)||
    q'[COMMIT; END;]';
    l_cursor_id := DBMS_SQL.OPEN_CURSOR;
    DBMS_SQL.PARSE(c => l_cursor_id, statement => l_statement, language_flag => DBMS_SQL.NATIVE, container => p_con_name);
    DBMS_SQL.BIND_VARIABLE(c => l_cursor_id, name => ':plans', value => 0);
    DBMS_SQL.BIND_VARIABLE(c => l_cursor_id, name => ':sql_id', value => p_sql_id);
    DBMS_SQL.BIND_VARIABLE(c => l_cursor_id, name => ':plan_hash_value', value => p_plan_hash_value);
    l_rows := DBMS_SQL.EXECUTE(c => l_cursor_id);
    DBMS_SQL.VARIABLE_VALUE(c => l_cursor_id, name => ':plans', value => r_plans);
    DBMS_SQL.CLOSE_CURSOR(c => l_cursor_id);
  END load_plan_from_cursor_cache;
  /* ---------------------------------------------------------------------------------- */  
  PROCEDURE set_spb_attribute (p_sql_handle IN VARCHAR2, p_plan_name IN VARCHAR2, p_con_name IN VARCHAR2, p_attribute_name IN VARCHAR2, p_attribute_value IN VARCHAR2, r_plans OUT NUMBER)
  IS
    l_cursor_id INTEGER;
    l_statement CLOB;
    l_rows      INTEGER;
  BEGIN
    l_statement := 
    q'[DECLARE PRAGMA AUTONOMOUS_TRANSACTION; BEGIN ]'||CHR(10)||
    q'[:plans := DBMS_SPM.ALTER_SQL_PLAN_BASELINE(sql_handle => :sql_handle, plan_name => :plan_name, attribute_name => :attribute_name, attribute_value => :attribute_value); ]'||CHR(10)||
    q'[COMMIT; END;]';
    l_cursor_id := DBMS_SQL.OPEN_CURSOR;
    DBMS_SQL.PARSE(c => l_cursor_id, statement => l_statement, language_flag => DBMS_SQL.NATIVE, container => p_con_name);
    DBMS_SQL.BIND_VARIABLE(c => l_cursor_id, name => ':plans', value => 0);
    DBMS_SQL.BIND_VARIABLE(c => l_cursor_id, name => ':sql_handle', value => p_sql_handle);
    DBMS_SQL.BIND_VARIABLE(c => l_cursor_id, name => ':plan_name', value => p_plan_name);
    DBMS_SQL.BIND_VARIABLE(c => l_cursor_id, name => ':attribute_name', value => p_attribute_name);
    DBMS_SQL.BIND_VARIABLE(c => l_cursor_id, name => ':attribute_value', value => p_attribute_value);
    l_rows := DBMS_SQL.EXECUTE(c => l_cursor_id);
    DBMS_SQL.VARIABLE_VALUE(c => l_cursor_id, name => ':plans', value => r_plans);
    DBMS_SQL.CLOSE_CURSOR(c => l_cursor_id);
  END set_spb_attribute;
  /* ---------------------------------------------------------------------------------- */  
  PROCEDURE drop_sqlset (p_sqlset_name IN VARCHAR2, p_con_name IN VARCHAR2)
  IS
    l_cursor_id INTEGER;
    l_statement CLOB;
    l_rows      INTEGER;
  BEGIN
    l_statement := 
    q'[DECLARE PRAGMA AUTONOMOUS_TRANSACTION; sqlset_does_not_exist EXCEPTION; PRAGMA EXCEPTION_INIT(sqlset_does_not_exist, -13754); BEGIN ]'||CHR(10)||
    q'[DBMS_SQLTUNE.DROP_SQLSET(sqlset_name => :sqlset_name); ]'||CHR(10)||
    q'[COMMIT; EXCEPTION WHEN sqlset_does_not_exist THEN NULL; END;]';
    l_cursor_id := DBMS_SQL.OPEN_CURSOR;
    DBMS_SQL.PARSE(c => l_cursor_id, statement => l_statement, language_flag => DBMS_SQL.NATIVE, container => p_con_name);
    DBMS_SQL.BIND_VARIABLE(c => l_cursor_id, name => ':sqlset_name', value => p_sqlset_name);
    l_rows := DBMS_SQL.EXECUTE(c => l_cursor_id);
    DBMS_SQL.CLOSE_CURSOR(c => l_cursor_id);
  END drop_sqlset;
  /* ---------------------------------------------------------------------------------- */  
  PROCEDURE create_and_load_sqlset (p_sqlset_name IN VARCHAR2, p_sql_id IN VARCHAR2, p_plan_hash_value IN VARCHAR2, p_begin_snap IN NUMBER, p_end_snap IN NUMBER, p_con_name IN VARCHAR2)
  IS
    l_cursor_id INTEGER;
    l_statement CLOB;
    l_rows      INTEGER;
  BEGIN
    l_statement := 
    q'[DECLARE PRAGMA AUTONOMOUS_TRANSACTION; ref_cur DBMS_SQLTUNE.SQLSET_CURSOR; BEGIN ]'||CHR(10)||
    q'[DBMS_SQLTUNE.CREATE_SQLSET(sqlset_name => :sqlset_name); ]'||CHR(10)||
    q'[OPEN ref_cur FOR ]'||CHR(10)||
    q'[SELECT VALUE(p) FROM TABLE(DBMS_SQLTUNE.SELECT_WORKLOAD_REPOSITORY(begin_snap => :begin_snap, end_snap => :end_snap, basic_filter => :basic_filter, attribute_list => :attribute_list)) p; ]'||CHR(10)||
    q'[DBMS_SQLTUNE.LOAD_SQLSET(sqlset_name => :sqlset_name, populate_cursor => ref_cur); ]'||CHR(10)||
    q'[CLOSE ref_cur; ]'||CHR(10)||
    q'[COMMIT; END;]';
    l_cursor_id := DBMS_SQL.OPEN_CURSOR;
    DBMS_SQL.PARSE(c => l_cursor_id, statement => l_statement, language_flag => DBMS_SQL.NATIVE, container => p_con_name);
    DBMS_SQL.BIND_VARIABLE(c => l_cursor_id, name => ':begin_snap', value => p_begin_snap);
    DBMS_SQL.BIND_VARIABLE(c => l_cursor_id, name => ':end_snap', value => p_end_snap);
    DBMS_SQL.BIND_VARIABLE(c => l_cursor_id, name => ':basic_filter', value => 'sql_id = '''||p_sql_id||''' AND plan_hash_value = '||p_plan_hash_value);
    DBMS_SQL.BIND_VARIABLE(c => l_cursor_id, name => ':attribute_list', value => 'ALL');
    DBMS_SQL.BIND_VARIABLE(c => l_cursor_id, name => ':sqlset_name', value => p_sqlset_name);
    l_rows := DBMS_SQL.EXECUTE(c => l_cursor_id);
    DBMS_SQL.CLOSE_CURSOR(c => l_cursor_id);
  END create_and_load_sqlset;
  /* ---------------------------------------------------------------------------------- */  
  PROCEDURE load_plan_from_sqlset (p_sqlset_name IN VARCHAR2, p_con_name IN VARCHAR2, r_plans OUT NUMBER)
  IS
    l_cursor_id INTEGER;
    l_statement CLOB;
    l_rows      INTEGER;
  BEGIN
    l_statement := 
    q'[DECLARE PRAGMA AUTONOMOUS_TRANSACTION; BEGIN ]'||CHR(10)||
    q'[:plans := DBMS_SPM.LOAD_PLANS_FROM_SQLSET(sqlset_name => :sqlset_name); ]'||CHR(10)||
    q'[COMMIT; END;]';
    l_cursor_id := DBMS_SQL.OPEN_CURSOR;
    DBMS_SQL.PARSE(c => l_cursor_id, statement => l_statement, language_flag => DBMS_SQL.NATIVE, container => p_con_name);
    DBMS_SQL.BIND_VARIABLE(c => l_cursor_id, name => ':plans', value => 0);
    DBMS_SQL.BIND_VARIABLE(c => l_cursor_id, name => ':sqlset_name', value => p_sqlset_name);
    l_rows := DBMS_SQL.EXECUTE(c => l_cursor_id);
    DBMS_SQL.VARIABLE_VALUE(c => l_cursor_id, name => ':plans', value => r_plans);
    DBMS_SQL.CLOSE_CURSOR(c => l_cursor_id);
  END load_plan_from_sqlset;
  /* ---------------------------------------------------------------------------------- */  
  PROCEDURE get_sql_handle_and_plan_name (p_signature IN NUMBER, p_sysdate IN DATE, p_con_id IN NUMBER, r_sql_handle OUT VARCHAR2, r_plan_name OUT VARCHAR2)
  IS
  BEGIN
    SELECT sql_handle, plan_name
      INTO r_sql_handle, r_plan_name
      FROM cdb_sql_plan_baselines
     WHERE con_id = p_con_id
       AND signature = p_signature
       AND origin = 'MANUAL-LOAD'
       AND created >= p_sysdate
       AND description IS NULL
       AND ROWNUM = 1;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      r_sql_handle := NULL;
      r_plan_name := NULL;
  END get_sql_handle_and_plan_name;
  /* ---------------------------------------------------------------------------------- */  
BEGIN
  DBMS_OUTPUT.ENABLE (buffer_size => NULL);
  -- gets dbid for awr
  SELECT dbid, name, open_mode INTO l_dbid, l_db_name, l_open_mode FROM v$database;
  -- to be executed on DG primary only
  IF l_open_mode <> 'READ WRITE' THEN
    output ('*** to be executed on DG primary only ***');
    RETURN;
  END IF;
  -- gets host name and starup time
  SELECT host_name, startup_time INTO l_host_name, l_instance_startup_time FROM v$instance;
  -- gets pdb name and con_id
  l_pdb_name := SYS_CONTEXT('USERENV', 'CON_NAME');
  l_con_id := SYS_CONTEXT('USERENV', 'CON_ID');
  -- output header
  output(RPAD('+', 145, '-'));
  output('|');
  output('IOD SPM AUT FPZ',                   'Flipping-Plan Zapper (FPZ)');
  output('|');
  output('Database',                          l_db_name);
  output('Plugable Database (PDB)',           l_pdb_name||' ('||l_con_id||')');
  output('Host',                              l_host_name);
  output('Instance Startup Time',             TO_CHAR(l_instance_startup_time, 'YYYY-MM-DD"T"HH24:MI:SS'));
  output('Date and Time (begin)',             TO_CHAR(SYSDATE, 'YYYY-MM-DD"T"HH24:MI:SS'));
  output('|');
  output('Report Only',                       k_report_only);
  IF k_report_only = 'N' THEN
    output('Create SPM Limit',                k_create_spm_limit||' (0 means: report only)');
    output('Promote (to FIXED) SPM Limit',    k_promote_spm_limit||' (0 means: report only)');
    output('Demote (disable) SPM Limit',      k_disable_spm_limit||' (0 means: report only)');
  END IF;
  output('FPZ Aggressiveness',                k_aggressiveness||' (1-5) 1=conservative, 3=moderate, 5=aggressive');
  output('Report Rejected Candidates',        k_repo_rejected_candidates);
  output('Report Non-Promoted SPBs',          k_repo_non_promoted_spb);
  output('PDB Name',                          NVL(k_pdb_name, 'ALL'));
  output('SQL_ID',                            NVL(k_sql_id, 'ALL'));
  output('Evaluate '||k_appl_cat_1||' Plans', k_incl_plans_appl_1);
  output('Evaluate '||k_appl_cat_2||' Plans', k_incl_plans_appl_2);
  output('Evaluate '||k_appl_cat_3||' Plans', k_incl_plans_appl_3);
  output('Evaluate '||k_appl_cat_4||' Plans', k_incl_plans_appl_4);
  output('Evaluate Non-Application Plans',    k_incl_plans_non_appl);
  output('Min Executions - Candidate',        k_execs_candidate||' (range:'||k_execs_candidate_min||'-'||k_execs_candidate_max||')');
  output('Min Executions - '||k_appl_cat_1,   k_execs_appl_cat_1||' (category range:'||k_execs_appl_cat_1_min||'-'||k_execs_appl_cat_1_max||')');
  output('Min Executions - '||k_appl_cat_2,   k_execs_appl_cat_2||' (category range:'||k_execs_appl_cat_2_min||'-'||k_execs_appl_cat_2_max||')');
  output('Min Executions - '||k_appl_cat_3,   k_execs_appl_cat_3||' (category range:'||k_execs_appl_cat_3_min||'-'||k_execs_appl_cat_3_max||')');
  output('Min Executions - '||k_appl_cat_4,   k_execs_appl_cat_4||' (category range:'||k_execs_appl_cat_4_min||'-'||k_execs_appl_cat_4_max||')');
  IF k_incl_plans_non_appl = 'Y' THEN
    output('Min Executions - Non-Application',k_execs_non_appl||' (category range:'||k_execs_non_appl_min||'-'||k_execs_non_appl_max||')');
  END IF;
  output('Min Time (ms) - Candidate',         TO_CHAR(k_secs_per_exec_cand * 1e3, 'FM999,990.000')||' (ms) (range:'||
                                              TO_CHAR(k_secs_per_exec_cand_min * 1e3, 'FM999,990.000')||'-'||
                                              TO_CHAR(k_secs_per_exec_cand_max * 1e3, 'FM999,990.000')||')');
  output('Min Time (ms) - '||k_appl_cat_1,    TO_CHAR(k_secs_per_exec_appl_1 * 1e3, 'FM999,990.000')||' (ms) (category range:'||
                                              TO_CHAR(k_secs_per_exec_appl_1_min * 1e3, 'FM999,990.000')||'-'||
                                              TO_CHAR(k_secs_per_exec_appl_1_max * 1e3, 'FM999,990.000')||')');
  output('Min Time (ms) - '||k_appl_cat_2,    TO_CHAR(k_secs_per_exec_appl_2 * 1e3, 'FM999,990.000')||' (ms) (category range:'||
                                              TO_CHAR(k_secs_per_exec_appl_2_min * 1e3, 'FM999,990.000')||'-'||
                                              TO_CHAR(k_secs_per_exec_appl_2_max * 1e3, 'FM999,990.000')||')');
  output('Min Time (ms) - '||k_appl_cat_3,    TO_CHAR(k_secs_per_exec_appl_3 * 1e3, 'FM999,990.000')||' (ms) (category range:'||
                                              TO_CHAR(k_secs_per_exec_appl_3_min * 1e3, 'FM999,990.000')||'-'||
                                              TO_CHAR(k_secs_per_exec_appl_3_max * 1e3, 'FM999,990.000')||')');
  output('Min Time (ms) - '||k_appl_cat_4,    TO_CHAR(k_secs_per_exec_appl_4 * 1e3, 'FM999,990.000')||' (ms) (category range:'||
                                              TO_CHAR(k_secs_per_exec_appl_4_min * 1e3, 'FM999,990.000')||'-'||
                                              TO_CHAR(k_secs_per_exec_appl_4_max * 1e3, 'FM999,990.000')||')');
  IF k_incl_plans_non_appl = 'Y' THEN
    output('Min Time (ms) - Non-Application', TO_CHAR(k_secs_per_exec_noappl * 1e3, 'FM999,990.000')||' (ms) (category range:'||
                                              TO_CHAR(k_secs_per_exec_noappl_min * 1e3, 'FM999,990.000')||'-'||
                                              TO_CHAR(k_secs_per_exec_noappl_max * 1e3, 'FM999,990.000')||')');
  END IF;
  output('90th Pctl Factor - Over Min Time',  k_90th_pctl_factor_cat||'x');
  output('95th Pctl Factor - Over Min Time',  k_95th_pctl_factor_cat||'x');
  output('97th Pctl Factor - Over Min Time',  k_97th_pctl_factor_cat||'x');
  output('99th Pctl Factor - Over Min Time',  k_99th_pctl_factor_cat||'x');
  output('90th Pctl Factor - Over Avg ET',    k_90th_pctl_factor_avg||'x');
  output('95th Pctl Factor - Over Avg ET',    k_95th_pctl_factor_avg||'x');
  output('97th Pctl Factor - Over Avg ET',    k_97th_pctl_factor_avg||'x');
  output('99th Pctl Factor - Over Avg ET',    k_99th_pctl_factor_avg||'x');
  output('Min Age (days) - Candidate',        k_first_load_time_days_cand||' (days)');
  output('Min Age (days) - To Qualify',       k_first_load_time_days||' (days)');
  output('Min Age (days) - SPB 4 Promotion',  k_fixed_mature_days||' (days)');
  output('SPB Threshold - Over Category Max', k_spb_thershold_over_cat_max||'x');
  output('SPB Threshold - Over SPB Perf',     k_spb_thershold_over_spf_perf||'x');
  output('Plan History Considered (days)',    k_awr_days||' (days)');
  output('Display Execution Plans',           k_display_plan);
  output('|');
  output(RPAD('+', 145, '-'));
  -- gets min snap_id for awr 
  --SELECT MAX(snap_id) INTO l_min_snap_id FROM dba_hist_snapshot WHERE dbid = l_dbid AND CAST(begin_interval_time AS DATE) < SYSDATE - k_awr_days;
  SELECT MAX(s.snap_id) INTO l_min_snap_id FROM dba_hist_snapshot s, v$instance i WHERE s.dbid = l_dbid AND CAST(s.begin_interval_time AS DATE) < GREATEST(SYSDATE - k_awr_days, i.startup_time);
  IF l_min_snap_id IS NULL THEN
    SELECT MIN(s.snap_id) INTO l_min_snap_id FROM dba_hist_snapshot s, v$instance i WHERE s.dbid = l_dbid AND CAST(s.begin_interval_time AS DATE) > i.startup_time;
  END IF;
  -- gets max snap_id for awr 
  SELECT MAX(snap_id) INTO l_max_snap_id FROM dba_hist_snapshot WHERE dbid = l_dbid;
  /* ---------------------------------------------------------------------------------- */  
  -- Pre-select SQL_ID/PHV candidates from shared pool
  FOR c_rec IN candidate_plan
  LOOP
    IF l_candidate_count_t > 0 AND l_pdb_name_prior <> c_rec.pdb_name THEN -- totals for prior PDB
      output(RPAD('+', 145, '-'));
      output('|');
      output('Plugable Database (PDB)',       l_pdb_name_prior||' ('||l_con_id_prior||')');
      output('Candidates',                    l_candidate_count_p);
      output('SPBs Qualified for Creation',   l_spb_created_qualified_p);
      output('SPBs Created',                  l_spb_created_count_p);
      output('SPBs Qualified for Promotion',  l_spb_promoted_qualified_p);
      output('SPBs Promoted',                 l_spb_promoted_count_p);
      output('SPBs Qualified for Demotion',   l_spb_disable_qualified_p);
      output('SPBs Demoted',                  l_spb_disabled_count_p);
      output('SPBs already Fixed',            l_spb_already_fixed_count_p);
      output('Date and Time',                 TO_CHAR(SYSDATE, 'YYYY-MM-DD"T"HH24:MI:SS'));
      output('|');
      output(RPAD('+', 145, '-'));
      l_candidate_count_p := 0;
      l_spb_created_qualified_p := 0;
      l_spb_promoted_qualified_p := 0;
      l_spb_created_count_p := 0;
      l_spb_promoted_count_p := 0;
      l_spb_already_fixed_count_p := 0;
      l_spb_disable_qualified_p := 0;
      l_spb_disabled_count_p := 0;
    END IF;
    -- initialize flags and counters
    l_candidate_count_t          := l_candidate_count_t + 1;
    l_candidate_count_p          := l_candidate_count_p + 1;
    l_candidate_was_accepted     := FALSE;
    l_spb_promotion_was_accepted := FALSE;
    l_spb_demotion_was_accepted  := FALSE;
    l_spb_exists                 := FALSE;
    l_spb_was_created            := FALSE;
    l_spb_was_promoted           := FALSE;
    l_output                     := TRUE;
    l_message1                   := NULL;
    l_message2                   := NULL;
    l_plans_returned             := 0;
    b_rec                        := NULL;
    l_us_per_exec_c              := c_rec.elapsed_time / GREATEST(c_rec.executions, 1);
    l_us_per_exec_b              := NULL;
    -- figure out signature
    IF c_rec.metrics_source = k_source_mem THEN
      l_signature := c_rec.exact_matching_signature;
    ELSIF c_rec.metrics_source = k_source_awr THEN
      SELECT sql_text INTO l_sql_text FROM dba_hist_sqltext WHERE sql_id = c_rec.sql_id AND dbid = l_dbid AND ROWNUM = 1;
      l_signature := DBMS_SQLTUNE.SQLTEXT_TO_SIGNATURE(l_sql_text);
    ELSE
      l_signature := NULL;
    END IF;
    /* -------------------------------------------------------------------------------- */  
    -- If there exists a SQL Plan Baseline (SPB) for candidate 
    IF c_rec.sql_plan_baseline IS NOT NULL THEN
      get_spb_rec (
        p_signature => c_rec.exact_matching_signature,
        p_plan_name => c_rec.sql_plan_baseline,
        p_con_id    => c_rec.con_id
      );
      IF b_rec.signature IS NULL THEN -- not expected 
        l_message1 := '*** SPB is missing!';
      ELSE -- SPB record is available (as expected)
        l_spb_exists := TRUE;
        l_us_per_exec_b := b_rec.elapsed_time / GREATEST(b_rec.executions, 1);
        IF b_rec.fixed = 'YES' THEN
          l_message1 := 'Skip. SPB already FIXED.';
          l_spb_already_fixed_count_p := l_spb_already_fixed_count_p + 1;
          l_spb_already_fixed_count_t := l_spb_already_fixed_count_t + 1;
        ELSIF b_rec.enabled = 'NO' OR b_rec.accepted = 'NO' OR b_rec.reproduced = 'NO' THEN -- not expected
          l_message1 := '*** SPB is inactive: Enabled='||b_rec.enabled||' Accepted='||b_rec.accepted||' Reproduced='||b_rec.reproduced||'.';
        ELSIF (l_us_per_exec_c / 1e6 > k_spb_thershold_over_cat_max * c_rec.secs_per_exec_threshold_max)
           OR (l_us_per_exec_c > k_spb_thershold_over_spf_perf * l_us_per_exec_b) 
        /* ---------------------------------------------------------------------------- */  
        THEN -- Demote SPB if underperforms (disable it)
          l_spb_demotion_was_accepted := TRUE;
          l_spb_disable_qualified_p := l_spb_disable_qualified_p + 1;
          l_spb_disable_qualified_t := l_spb_disable_qualified_t + 1;
          IF l_spb_disabled_count_t < k_disable_spm_limit AND k_report_only = 'N' THEN
            l_message1 := 'SPB was disabled. It undeperforms. ('||
                         'cur:'||TO_CHAR(ROUND(l_us_per_exec_c / 1e3, 3), 'FM9999,990.000')||'ms, '||
                         'cat:'||k_spb_thershold_over_cat_max||'x '||TO_CHAR(ROUND(c_rec.secs_per_exec_threshold_max * 1e3, 3), 'FM9999,990.000')||'ms, '||
                         'spb:'||k_spb_thershold_over_spf_perf||'x '||TO_CHAR(ROUND(l_us_per_exec_b / 1e3, 3), 'FM9999,990.000')||'ms)';
            l_spb_disabled_count_p := l_spb_disabled_count_p + 1;
            l_spb_disabled_count_t := l_spb_disabled_count_t + 1;
            -- call dbms_spm
            set_spb_attribute (
              p_sql_handle        => b_rec.sql_handle,
              p_plan_name         => b_rec.plan_name,
              p_con_name          => c_rec.pdb_name,
              p_attribute_name    => 'ENABLED',
              p_attribute_value   => 'NO',
              r_plans             => l_plans_returned
            );
            l_description := 'IOD FPZ SQL_ID='||c_rec.sql_id||' PHV='||c_rec.plan_hash_value||' DISABLED='||TO_CHAR(SYSDATE, 'YYYY-MM-DD"T"HH24:MI:SS');
            set_spb_attribute (
              p_sql_handle        => b_rec.sql_handle,
              p_plan_name         => b_rec.plan_name,
              p_con_name          => c_rec.pdb_name,
              p_attribute_name    => 'DESCRIPTION',
              p_attribute_value   => l_description,
              r_plans             => l_plans_returned
            );
            get_spb_rec (
              p_signature         => b_rec.signature,
              p_plan_name         => b_rec.plan_name,
              p_con_id            => c_rec.con_id
            );
          ELSE -- l_spb_disabled_count_t < k_disable_spm_limit
            l_message1 := 'SPB would be disabled. It undeperforms. ('||
                         'cur:'||TO_CHAR(ROUND(l_us_per_exec_c / 1e3, 3), 'FM9999,990.000')||'ms, '||
                         'cat:'||k_spb_thershold_over_cat_max||'x '||TO_CHAR(ROUND(c_rec.secs_per_exec_threshold_max * 1e3, 3), 'FM9999,990.000')||'ms, '||
                         'spb:'||k_spb_thershold_over_spf_perf||'x '||TO_CHAR(ROUND(l_us_per_exec_b / 1e3, 3), 'FM9999,990.000')||'ms)';
          END IF; -- l_spb_disabled_count_t < k_disable_spm_limit
        -- If existing SQL Plan Baseline (SPB) for candidate is valid then
        -- Evaluate and perform conditional SPB promotion
        ELSIF b_rec.created > SYSDATE - k_fixed_mature_days THEN
          l_message1 := 'SPB promotion to "FIXED" is rejected at this time. SPB needs to be older than '||k_fixed_mature_days||' days.';
        --ELSIF b_rec.last_executed < SYSDATE - k_fixed_mature_days THEN (had to remove this, "last_executed" is not reliable)
          --l_message1 := 'SPB promotion to "FIXED" is rejected at this time. SPB has not been used within the last '||k_fixed_mature_days||' days.';
        /* ---------------------------------------------------------------------------- */  
        ELSE -- Promote SPB after proven performance (fix it)
          l_spb_promotion_was_accepted := TRUE;
          l_spb_promoted_qualified_p := l_spb_promoted_qualified_p + 1;
          l_spb_promoted_qualified_t := l_spb_promoted_qualified_t + 1;
          IF l_spb_promoted_count_t < k_promote_spm_limit AND k_report_only = 'N' THEN
            l_spb_promoted_count_p := l_spb_promoted_count_p + 1;
            l_spb_promoted_count_t := l_spb_promoted_count_t + 1;
            l_message1 := 'SPB promoted to "FIXED".';
            l_spb_was_promoted := TRUE;
            -- call dbms_spm
            set_spb_attribute (
              p_sql_handle        => b_rec.sql_handle,
              p_plan_name         => b_rec.plan_name,
              p_con_name          => c_rec.pdb_name,
              p_attribute_name    => 'FIXED',
              p_attribute_value   => 'YES',
              r_plans             => l_plans_returned
            );
            l_description := 'IOD FPZ SQL_ID='||c_rec.sql_id||' PHV='||c_rec.plan_hash_value||' FIXED='||TO_CHAR(SYSDATE, 'YYYY-MM-DD"T"HH24:MI:SS');
            set_spb_attribute (
              p_sql_handle        => b_rec.sql_handle,
              p_plan_name         => b_rec.plan_name,
              p_con_name          => c_rec.pdb_name,
              p_attribute_name    => 'DESCRIPTION',
              p_attribute_value   => l_description,
              r_plans             => l_plans_returned
            );
            get_spb_rec (
              p_signature         => b_rec.signature,
              p_plan_name         => b_rec.plan_name,
              p_con_id            => c_rec.con_id
            );
          ELSE -- l_spb_promoted_count_t > k_promote_spm_limit
            l_message1 := 'SPB qualifies for promotion to "FIXED".';
          END IF; -- l_spb_promoted_count_t < k_promote_spm_limit
        END IF; -- b_rec.fixed = 'YES'
      END IF; -- b_rec.signature IS NULL
    /* -------------------------------------------------------------------------------- */  
    ELSE -- If there does not exist a SQL Plan Baseline (SPB) for candidate
      -- Further screen candidate
      IF l_us_per_exec_c / 1e6 > k_secs_per_exec_cand OR c_rec.executions < k_execs_candidate THEN
        l_output := FALSE; -- simply ignore. this is to make it up for adjusting predicates from mem_plan_metrics and awr_plan_metrics queries on candidate_plan
      ELSIF c_rec.first_load_time > SYSDATE - k_first_load_time_days THEN
        l_message1 := 'Rejected. SQL''s first load time is too recent. Still within the last '||ROUND(k_first_load_time_days, 3)||' day(s) window.';
      ELSIF c_rec.executions < c_rec.executions_threshold THEN
        l_message1 := 'Rejected. '||c_rec.executions||' executions is less than '||c_rec.executions_threshold||' threshold for this SQL category.';
      ELSIF l_us_per_exec_c / 1e6 > c_rec.secs_per_exec_threshold AND c_rec.metrics_source = k_source_mem THEN
        l_message1 := 'Rejected. "MEM Avg Elapsed Time per Exec" exceeds '||(c_rec.secs_per_exec_threshold * 1e3)||'ms threshold for this SQL category.';
      ELSIF c_rec.avg_avg_et_us / 1e6 > c_rec.secs_per_exec_threshold THEN
        l_message1 := 'Rejected. "AWR Avg Elapsed Time per Exec" exceeds '||(c_rec.secs_per_exec_threshold * 1e3)||'ms threshold for this SQL category.';
      ELSIF c_rec.med_avg_et_us / 1e6 > c_rec.secs_per_exec_threshold THEN
        l_message1 := 'Rejected. "Median Elapsed Time per Exec" exceeds '||(c_rec.secs_per_exec_threshold * 1e3)||'ms threshold for this SQL category.';
      ELSIF c_rec.p90_avg_et_us / 1e6 > k_90th_pctl_factor_cat * c_rec.secs_per_exec_threshold THEN
        l_message1 := 'Rejected. "90th Pctl Elapsed Time per Exec" exceeds '||(k_90th_pctl_factor_cat * c_rec.secs_per_exec_threshold * 1e3)||'ms threshold for this SQL category.';
      ELSIF c_rec.p95_avg_et_us / 1e6 > k_95th_pctl_factor_cat * c_rec.secs_per_exec_threshold THEN
        l_message1 := 'Rejected. "95th Pctl Elapsed Time per Exec" exceeds '||(k_95th_pctl_factor_cat * c_rec.secs_per_exec_threshold * 1e3)||'ms threshold for this SQL category.';
      ELSIF c_rec.p97_avg_et_us / 1e6 > k_97th_pctl_factor_cat * c_rec.secs_per_exec_threshold THEN
        l_message1 := 'Rejected. "97th Pctl Elapsed Time per Exec" exceeds '||(k_97th_pctl_factor_cat * c_rec.secs_per_exec_threshold * 1e3)||'ms threshold for this SQL category.';
      ELSIF c_rec.p99_avg_et_us / 1e6 > k_99th_pctl_factor_cat * c_rec.secs_per_exec_threshold THEN
        l_message1 := 'Rejected. "99th Pctl Elapsed Time per Exec" exceeds '||(k_99th_pctl_factor_cat * c_rec.secs_per_exec_threshold * 1e3)||'ms threshold for this SQL category.';
      ELSIF c_rec.p90_avg_et_us > k_90th_pctl_factor_avg * l_us_per_exec_c AND c_rec.metrics_source = k_source_mem THEN
        l_message1 := 'Rejected. "90th Pctl Elapsed Time per Exec" exceeds '||k_90th_pctl_factor_avg||'x "MEM Avg Elapsed Time per Exec" threshold.';
      ELSIF c_rec.p90_avg_et_us > k_90th_pctl_factor_avg * c_rec.avg_avg_et_us THEN
        l_message1 := 'Rejected. "90th Pctl Elapsed Time per Exec" exceeds '||k_90th_pctl_factor_avg||'x "AWR Avg Elapsed Time per Exec" threshold.';
      ELSIF c_rec.p90_avg_et_us > k_90th_pctl_factor_avg * c_rec.med_avg_et_us THEN
        l_message1 := 'Rejected. "90th Pctl Elapsed Time per Exec" exceeds '||k_90th_pctl_factor_avg||'x "Median Elapsed Time per Exec" threshold.';
      ELSIF c_rec.p95_avg_et_us > k_95th_pctl_factor_avg * l_us_per_exec_c AND c_rec.metrics_source = k_source_mem THEN
        l_message1 := 'Rejected. "95th Pctl Elapsed Time per Exec" exceeds '||k_95th_pctl_factor_avg||'x "MEM Avg Elapsed Time per Exec" threshold.';
      ELSIF c_rec.p95_avg_et_us > k_95th_pctl_factor_avg * c_rec.avg_avg_et_us THEN
        l_message1 := 'Rejected. "95th Pctl Elapsed Time per Exec" exceeds '||k_95th_pctl_factor_avg||'x "AWR Avg Elapsed Time per Exec" threshold.';
      ELSIF c_rec.p95_avg_et_us > k_95th_pctl_factor_avg * c_rec.med_avg_et_us THEN
        l_message1 := 'Rejected. "95th Pctl Elapsed Time per Exec" exceeds '||k_95th_pctl_factor_avg||'x "Median Elapsed Time per Exec" threshold.';
      ELSIF c_rec.p97_avg_et_us > k_97th_pctl_factor_avg * l_us_per_exec_c AND c_rec.metrics_source = k_source_mem THEN
        l_message1 := 'Rejected. "97th Pctl Elapsed Time per Exec" exceeds '||k_97th_pctl_factor_avg||'x "MEM Avg Elapsed Time per Exec" threshold.';
      ELSIF c_rec.p97_avg_et_us > k_97th_pctl_factor_avg * c_rec.avg_avg_et_us THEN
        l_message1 := 'Rejected. "97th Pctl Elapsed Time per Exec" exceeds '||k_97th_pctl_factor_avg||'x "AWR Avg Elapsed Time per Exec" threshold.';
      ELSIF c_rec.p97_avg_et_us > k_97th_pctl_factor_avg * c_rec.med_avg_et_us THEN
        l_message1 := 'Rejected. "97th Pctl Elapsed Time per Exec" exceeds '||k_97th_pctl_factor_avg||'x "Median Elapsed Time per Exec" threshold.';
      ELSIF c_rec.p99_avg_et_us > k_99th_pctl_factor_avg * l_us_per_exec_c AND c_rec.metrics_source = k_source_mem THEN
        l_message1 := 'Rejected. "99th Pctl Elapsed Time per Exec" exceeds '||k_99th_pctl_factor_avg||'x "MEM Avg Elapsed Time per Exec" threshold.';
      ELSIF c_rec.p99_avg_et_us > k_99th_pctl_factor_avg * c_rec.avg_avg_et_us THEN
        l_message1 := 'Rejected. "99th Pctl Elapsed Time per Exec" exceeds '||k_99th_pctl_factor_avg||'x "AWR Avg Elapsed Time per Exec" threshold.';
      ELSIF c_rec.p99_avg_et_us > k_99th_pctl_factor_avg * c_rec.med_avg_et_us THEN
        l_message1 := 'Rejected. "99th Pctl Elapsed Time per Exec" exceeds '||k_99th_pctl_factor_avg||'x "Median Elapsed Time per Exec" threshold.';
      /* ------------------------------------------------------------------------------ */  
      ELSE -- Create SPB if candidate is accepted
        l_spb_created_qualified_p := l_spb_created_qualified_p + 1;
        l_spb_created_qualified_t := l_spb_created_qualified_t + 1;
        l_sysdate := SYSDATE;
        l_candidate_was_accepted := TRUE;
        IF l_spb_created_count_t < k_create_spm_limit AND k_report_only = 'N' THEN
          -- call dbms_spm
          IF c_rec.metrics_source = k_source_mem THEN
            load_plan_from_cursor_cache (
              p_sql_id          => c_rec.sql_id, 
              p_plan_hash_value => c_rec.plan_hash_value,
              p_con_name        => c_rec.pdb_name,
              r_plans           => l_plans_returned
            );
          ELSE -- c_rec.metrics_source = k_source_awr THEN
            l_sqlset_name := c_rec.sql_id||'_'||c_rec.plan_hash_value;
            drop_sqlset (
              p_sqlset_name     => l_sqlset_name,
              p_con_name        => c_rec.pdb_name
            );
            create_and_load_sqlset (
              p_sqlset_name     => l_sqlset_name,
              p_sql_id          => c_rec.sql_id, 
              p_plan_hash_value => c_rec.plan_hash_value,
              p_begin_snap      => l_min_snap_id,
              p_end_snap        => l_max_snap_id,
              p_con_name        => c_rec.pdb_name
            );
            load_plan_from_sqlset (
              p_sqlset_name     => l_sqlset_name,
              p_con_name        => c_rec.pdb_name,
              r_plans           => l_plans_returned
            );
            drop_sqlset (
              p_sqlset_name     => l_sqlset_name,
              p_con_name        => c_rec.pdb_name
            );
          END IF;
          IF l_plans_returned > 0 THEN
            get_sql_handle_and_plan_name (
              p_signature         => l_signature,
              p_sysdate           => l_sysdate,
              p_con_id            => c_rec.con_id,
              r_sql_handle        => l_sql_handle,
              r_plan_name         => l_plan_name
            );
            l_description := 'IOD FPZ LVL='||LPAD(k_aggressiveness, 2, '0')||' SQL_ID='||c_rec.sql_id||' PHV='||c_rec.plan_hash_value;
            set_spb_attribute (
              p_sql_handle        => l_sql_handle,
              p_plan_name         => l_plan_name,
              p_con_name          => c_rec.pdb_name,
              p_attribute_name    => 'DESCRIPTION',
              p_attribute_value   => l_description,
              r_plans             => l_plans_returned
            );
            get_spb_rec (
              p_signature         => l_signature,
              p_plan_name         => l_plan_name,
              p_con_id            => c_rec.con_id
            );
            l_spb_created_count_p := l_spb_created_count_p + 1;
            l_spb_created_count_t := l_spb_created_count_t + 1;
            l_spb_exists := TRUE;
            l_message1 := 'SPB created.';
            l_spb_was_created := TRUE;
          ELSE
            l_message1 := 'Plan qualifies for SPB creation. SPB was not created. Load API returned no plans.';
            l_message2 := 'sqlset='||l_sqlset_name||', min_snap_id='||l_min_snap_id||', max_snap_id:'||l_max_snap_id;
          END IF;
        ELSE -- l_spb_created_count_t > k_create_spm_limit
          l_message1 := 'Plan qualifies for SPB creation. SPB was not created. Limit reached or Report Only.';
        END IF; -- l_spb_created_count_t < k_create_spm_limit
      END IF; -- c_rec.first_load_time > SYSDATE - k_first_load_time_days
    END IF; -- If there exists a SQL Plan Baseline (SPB) for candidate 
    /* -------------------------------------------------------------------------------- */  
    -- Output cursor details
    IF l_output AND (l_candidate_was_accepted OR k_repo_rejected_candidates = 'Y' OR l_spb_demotion_was_accepted OR l_spb_promotion_was_accepted OR k_repo_non_promoted_spb = 'Y') THEN
      output(RPAD('+', 145, '-'));
      output('|');
      output('FPZ Aggressiveness',            k_aggressiveness||' (1-5) 1=conservative, 3=moderate, 5=aggressive');
      output('Candidate Number',              l_candidate_count_t);
      output('Plugable Database (PDB)',       c_rec.pdb_name||' ('||c_rec.con_id||')');
      output('Parsing Schema Name',           c_rec.parsing_schema_name);
      output('SQL Text',                      REPLACE(REPLACE(c_rec.sql_text, CHR(10), CHR(32)), CHR(9), CHR(32)));
      output('SQL ID',                        c_rec.sql_id);
      output('Plan Hash Value (PHV)',         c_rec.plan_hash_value);
      output('Metrics Source',                c_rec.metrics_source);
      IF c_rec.child_cursors > 1 THEN
        output('Child Cursors',               c_rec.child_cursors);
        output('Min Child Number',            c_rec.min_child_number);
        output('Max Child Number',            c_rec.max_child_number);
      ELSE
        output('Child Number',                c_rec.min_child_number);
      END IF;
      output('Executions',                    c_rec.executions);
      output('Buffer Gets',                   c_rec.buffer_gets);
      output('Disk Reads',                    c_rec.disk_reads);
      output('Rows Processed',                c_rec.rows_processed);
      output('Shared Memory (bytes)',         c_rec.sharable_mem);
      output('Elapsed Time (us)',             c_rec.elapsed_time);
      output('CPU Time (us)',                 c_rec.cpu_time);
      output('User I/O Wait Time (us)',       c_rec.user_io_wait_time);
      output('Application Wait Time (us)',    c_rec.application_wait_time);
      output('Concurrency Wait Time (us)',    c_rec.concurrency_wait_time);
      IF NVL(c_rec.min_optimizer_cost, -1) <> NVL(c_rec.max_optimizer_cost, -2) THEN
        output('Min Optimizer Cost',          c_rec.min_optimizer_cost);
        output('Max Optimizer Cost',          c_rec.max_optimizer_cost);
      ELSE
        output('Optimizer Cost',              c_rec.min_optimizer_cost);
      END IF;
      output('Module',                        c_rec.module);
      output('Action',                        c_rec.action);
      output('Last Active Time',              TO_CHAR(c_rec.last_active_time, 'YYYY-MM-DD"T"HH24:MI:SS'));
      output('Last Load Time',                TO_CHAR(c_rec.last_load_time, 'YYYY-MM-DD"T"HH24:MI:SS'));
      output('First Load Time',               TO_CHAR(c_rec.first_load_time, 'YYYY-MM-DD"T"HH24:MI:SS'));
      output('SQL Profile',                   c_rec.sql_profile);
      output('SQL Patch',                     c_rec.sql_patch);
      output('SQL Plan Baseline (SPB)',       c_rec.sql_plan_baseline);
      output('Exact Matching Signature',      l_signature);
      output('|');
      output('Application Category',          c_rec.application_category);
      output('Critical Application',          c_rec.critical_application);
      output('Executions Threshold',          c_rec.executions_threshold||' (category range:'||c_rec.executions_threshold_min||'-'||c_rec.executions_threshold_max||')');
      output('Time per Exec Threshold (ms)',  TO_CHAR(c_rec.secs_per_exec_threshold * 1e3, 'FM999,990.000')||' (ms) (category range:'||
                                              TO_CHAR(c_rec.secs_per_exec_threshold_min * 1e3, 'FM999,990.000')||'-'||
                                              TO_CHAR(c_rec.secs_per_exec_threshold_max * 1e3, 'FM999,990.000')||')');
      -- Output plan performance metrics
      output('|');
      output(
        'Plan Performance Metrics',
        'MEM Avg',
        'SPB Avg',
        'AWR Avg',
        'Median',
        '90th Pctl',
        '95th Pctl',
        '97th Pctl',
        '99th Pctl',
        'Maximum'
      );
      output(
        '(with '||TRIM(TO_CHAR(NVL(c_rec.awr_snapshots, 0), 'FM99,990'))||' AWR snapshots)',
        LPAD('-', 11, '-'),        
        LPAD('-', 11, '-'),        
        LPAD('-', 11, '-'),        
        LPAD('-', 11, '-'),        
        LPAD('-', 11, '-'),        
        LPAD('-', 11, '-'),        
        LPAD('-', 11, '-'),        
        LPAD('-', 11, '-'),        
        LPAD('-', 11, '-')
      );      
      output(
        'Avg Elapsed Time per Exec (ms)',
        TO_CHAR(ROUND(l_us_per_exec_c / 1e3, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(l_us_per_exec_b / 1e3, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.avg_avg_et_us / 1e3, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.med_avg_et_us / 1e3, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p90_avg_et_us / 1e3, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p95_avg_et_us / 1e3, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p97_avg_et_us / 1e3, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p99_avg_et_us / 1e3, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.max_avg_et_us / 1e3, 3), 'FM9999,990.000')
        );
      output(
        'Avg CPU Time per Exec (ms)',
        TO_CHAR(ROUND(c_rec.cpu_time / GREATEST(c_rec.executions, 1) / 1e3, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(b_rec.cpu_time / GREATEST(b_rec.executions, 1) / 1e3, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.avg_avg_cpu_us / 1e3, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.med_avg_cpu_us / 1e3, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p90_avg_cpu_us / 1e3, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p95_avg_cpu_us / 1e3, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p97_avg_cpu_us / 1e3, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p99_avg_cpu_us / 1e3, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.max_avg_cpu_us / 1e3, 3), 'FM9999,990.000')
        );
      output(
        'Avg User I/O Time per Exec (ms)',
        TO_CHAR(ROUND(c_rec.user_io_wait_time / GREATEST(c_rec.executions, 1) / 1e3, 3), 'FM9999,990.000'),
        NULL,
        TO_CHAR(ROUND(c_rec.avg_avg_user_io_us / 1e3, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.med_avg_user_io_us / 1e3, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p90_avg_user_io_us / 1e3, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p95_avg_user_io_us / 1e3, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p97_avg_user_io_us / 1e3, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p99_avg_user_io_us / 1e3, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.max_avg_user_io_us / 1e3, 3), 'FM9999,990.000')
        );
      output(
        'Avg Appl Time per Exec (ms)',
        TO_CHAR(ROUND(c_rec.application_wait_time / GREATEST(c_rec.executions, 1) / 1e3, 3), 'FM9999,990.000'),
        NULL,
        TO_CHAR(ROUND(c_rec.avg_avg_application_us / 1e3, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.med_avg_application_us / 1e3, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p90_avg_application_us / 1e3, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p95_avg_application_us / 1e3, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p97_avg_application_us / 1e3, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p99_avg_application_us / 1e3, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.max_avg_application_us / 1e3, 3), 'FM9999,990.000')
        );
      output(
        'Avg Conc Time per Exec (ms)',
        TO_CHAR(ROUND(c_rec.concurrency_wait_time / GREATEST(c_rec.executions, 1) / 1e3, 3), 'FM9999,990.000'),
        NULL,
        TO_CHAR(ROUND(c_rec.avg_avg_concurrency_us / 1e3, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.med_avg_concurrency_us / 1e3, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p90_avg_concurrency_us / 1e3, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p95_avg_concurrency_us / 1e3, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p97_avg_concurrency_us / 1e3, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p99_avg_concurrency_us / 1e3, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.max_avg_concurrency_us / 1e3, 3), 'FM9999,990.000')
        );
      output(
        'Avg Executions (per second)',
        NULL,
        NULL,
        TO_CHAR(ROUND(c_rec.avg_execs_per_sec, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.med_execs_per_sec, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p90_execs_per_sec, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p95_execs_per_sec, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p97_execs_per_sec, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p99_execs_per_sec, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.max_execs_per_sec, 3), 'FM9999,990.000')
        );
      output(
        'Avg Rows Processed per Exec',
        TO_CHAR(ROUND(c_rec.rows_processed / GREATEST(c_rec.executions, 1), 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(b_rec.rows_processed / GREATEST(b_rec.executions, 1), 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.avg_rows_processed_per_exec, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.med_rows_processed_per_exec, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p90_rows_processed_per_exec, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p95_rows_processed_per_exec, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p97_rows_processed_per_exec, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p99_rows_processed_per_exec, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.max_rows_processed_per_exec, 3), 'FM9999,990.000')
        );
      output(
        'Avg Buffer Gets per Exec',
        TO_CHAR(ROUND(c_rec.buffer_gets / GREATEST(c_rec.executions, 1), 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(b_rec.buffer_gets / GREATEST(b_rec.executions, 1), 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.avg_buffer_gets_per_exec, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.med_buffer_gets_per_exec, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p90_buffer_gets_per_exec, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p95_buffer_gets_per_exec, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p97_buffer_gets_per_exec, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p99_buffer_gets_per_exec, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.max_buffer_gets_per_exec, 3), 'FM9999,990.000')
        );
      output(
        'Avg Disk Reads per Exec',
        TO_CHAR(ROUND(c_rec.disk_reads / GREATEST(c_rec.executions, 1), 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(b_rec.disk_reads / GREATEST(b_rec.executions, 1), 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.avg_disk_reads_per_exec, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.med_disk_reads_per_exec, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p90_disk_reads_per_exec, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p95_disk_reads_per_exec, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p97_disk_reads_per_exec, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p99_disk_reads_per_exec, 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.max_disk_reads_per_exec, 3), 'FM9999,990.000')
        );
      output(
        'Sum Shared Memory (MBs)',
        TO_CHAR(ROUND(c_rec.sharable_mem / POWER(2, 20), 3), 'FM9999,990.000'),
        NULL,
        TO_CHAR(ROUND(c_rec.avg_sharable_mem / POWER(2, 20), 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.med_sharable_mem / POWER(2, 20), 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p90_sharable_mem / POWER(2, 20), 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p95_sharable_mem / POWER(2, 20), 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p97_sharable_mem / POWER(2, 20), 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.p99_sharable_mem / POWER(2, 20), 3), 'FM9999,990.000'),
        TO_CHAR(ROUND(c_rec.max_sharable_mem / POWER(2, 20), 3), 'FM9999,990.000')
        );
      -- Output SQL Plan Baseline details
      IF l_spb_exists OR l_spb_demotion_was_accepted OR l_spb_promotion_was_accepted THEN
        output('|');
        output('Signature',                   b_rec.signature);
        output('SQL Handle',                  b_rec.sql_handle);
        output('Plan Name',                   b_rec.plan_name);
        output('Creator',                     b_rec.creator);
        output('Origin',                      b_rec.origin);
        output('Parsing Schema Name',         b_rec.parsing_schema_name);
        output('Description',                 b_rec.description);
        output('Version',                     b_rec.version);
        output('Enabled',                     b_rec.enabled);
        output('Accepted',                    b_rec.accepted);
        output('Fixed',                       b_rec.fixed);
        output('Reproduced',                  b_rec.reproduced);
        output('Autopurge',                   b_rec.autopurge);
        output('Adaptive',                    b_rec.adaptive);
        output('Executions',                  b_rec.executions);
        output('Buffer Gets',                 b_rec.buffer_gets);
        output('Disk Reads',                  b_rec.disk_reads);
        output('Rows Processed',              b_rec.rows_processed);
        output('Elapsed Time (us)',           b_rec.elapsed_time);
        output('CPU Time (us)',               b_rec.cpu_time);
        output('Optimizer Cost',              b_rec.optimizer_cost);
        output('Module',                      b_rec.module);
        output('Action',                      b_rec.action);
        output('Last Executed',               TO_CHAR(b_rec.last_executed, 'YYYY-MM-DD"T"HH24:MI:SS'));
        output('Last Modified',               TO_CHAR(b_rec.last_modified, 'YYYY-MM-DD"T"HH24:MI:SS'));
        output('Last Verified',               TO_CHAR(b_rec.last_verified, 'YYYY-MM-DD"T"HH24:MI:SS'));
        output('Created',                     TO_CHAR(b_rec.created, 'YYYY-MM-DD"T"HH24:MI:SS'));
      END IF; -- Output SQL Plan Baseline details
      IF l_message1 IS NOT NULL THEN
        output('|');
        output('Message1',                    SUBSTR(l_message1, 1, 108));
        output('Message2',                    SUBSTR(l_message2, 1, 108));
      END IF;
      IF k_display_plan = 'Y' AND c_rec.metrics_source = k_source_mem /*AND NOT l_spb_was_promoted AND NOT l_spb_was_created*/ THEN
        output('|');
        FOR pln_rec IN (SELECT plan_table_output FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(c_rec.sql_id, c_rec.max_child_number, k_display_plan_format)))
        LOOP
          output('| '||pln_rec.plan_table_output);
        END LOOP;
      END IF;
      IF k_display_plan = 'Y' AND c_rec.metrics_source = k_source_awr THEN
        output('|');
        FOR pln_rec IN (SELECT plan_table_output FROM TABLE(DBMS_XPLAN.DISPLAY_AWR(c_rec.sql_id, c_rec.plan_hash_value, l_dbid, k_display_plan_format, c_rec.con_id)))
        LOOP
          output('| '||pln_rec.plan_table_output);
        END LOOP;
      END IF;
      IF k_display_plan = 'Y' AND (l_spb_exists OR l_spb_demotion_was_accepted OR l_spb_promotion_was_accepted) AND c_rec.con_id = l_con_id THEN
        output('|');
        FOR pln_rec IN (SELECT plan_table_output FROM TABLE(DBMS_XPLAN.DISPLAY_SQL_PLAN_BASELINE(b_rec.sql_handle, b_rec.plan_name, k_display_plan_format)))
        LOOP
          output('| '||pln_rec.plan_table_output);
        END LOOP;
        output('|');
      END IF; 
      IF k_display_plan = 'N' THEN
        output('|');
      END IF;
      output(RPAD('+', 145, '-'));
    END IF; -- Output cursor details
    l_pdb_name_prior := c_rec.pdb_name;
    l_con_id_prior := c_rec.con_id;
  END LOOP;
  /* ---------------------------------------------------------------------------------- */  
  -- output footer
  IF l_pdb_name_prior <> l_pdb_name AND l_pdb_name_prior <> '-666' AND NVL(k_pdb_name, 'ALL') = 'ALL' THEN
    output(RPAD('+', 145, '-'));
    output('|');
    output('Plugable Database (PDB)',         l_pdb_name_prior||' ('||l_con_id_prior||')');
    output('Candidates',                      l_candidate_count_p);
    output('SPBs Qualified for Creation',     l_spb_created_qualified_p);
    output('SPBs Created',                    l_spb_created_count_p);
    output('SPBs Qualified for Promotion',    l_spb_promoted_qualified_p);
    output('SPBs Promoted',                   l_spb_promoted_count_p);
    output('SPBs Qualified for Demotion',     l_spb_disable_qualified_p);
    output('SPBs Demoted',                    l_spb_disabled_count_p);
    output('SPBs already Fixed',              l_spb_already_fixed_count_p);
    output('Date and Time',                   TO_CHAR(SYSDATE, 'YYYY-MM-DD"T"HH24:MI:SS'));
    output('|');
    output(RPAD('+', 145, '-'));
  END IF;
  output(RPAD('+', 145, '-'));
  output('|');
  output('FPZ Aggressiveness',                k_aggressiveness||' (1-5) 1=conservative, 3=moderate, 5=aggressive');
  output('Candidates',                        l_candidate_count_t);
  output('SPBs Qualified for Creation',       l_spb_created_qualified_t);
  output('SPBs Created',                      l_spb_created_count_t);
  output('SPBs Qualified for Promotion',      l_spb_promoted_qualified_t);
  output('SPBs Promoted',                     l_spb_promoted_count_t);
  output('SPBs Qualified for Demotion',       l_spb_disable_qualified_t);
  output('SPBs Demoted',                      l_spb_disabled_count_t);
  output('SPBs already Fixed',                l_spb_already_fixed_count_t);
  output('Date and Time (end)',               TO_CHAR(SYSDATE, 'YYYY-MM-DD"T"HH24:MI:SS'));
  output('Duration (secs)',                   ROUND((SYSDATE - l_start_time) * 24 * 60 * 60));
  output('|');
  output(RPAD('+', 145, '-'));
  /* ---------------------------------------------------------------------------------- */  
  -- output parameters
  x_plan_candidates              := l_candidate_count_t;
  x_qualified_for_spb_creation   := l_spb_created_qualified_t;
  x_spbs_created                 := l_spb_created_count_t;
  x_qualified_for_spb_promotion  := l_spb_promoted_qualified_t;
  x_spbs_promoted                := l_spb_promoted_count_t;
  x_qualified_for_spb_demotion   := l_spb_disable_qualified_t;
  x_spbs_demoted                 := l_spb_disabled_count_t;
  x_spbs_already_fixed           := l_spb_already_fixed_count_t;
END maintain_plans_internal;
/* ------------------------------------------------------------------------------------ */
PROCEDURE maintain_plans (
  p_report_only                  IN VARCHAR2 DEFAULT NULL, -- (Y|N) when Y then only produces report and changes nothing
  p_create_spm_limit             IN NUMBER   DEFAULT NULL, -- limits the number of SPMs to be created in one execution
  p_promote_spm_limit            IN NUMBER   DEFAULT NULL, -- limits the number of SPMs to be promoted to "FIXED" in one execution
  p_disable_spm_limit            IN NUMBER   DEFAULT NULL, -- limits the number of SPMs to be demoted to "DISABLE" in one execution
  p_aggressiveness               IN NUMBER   DEFAULT NULL, -- (1-5) range between 1 to 5 where 1 is conservative and 5 is aggresive
  p_repo_rejected_candidates     IN VARCHAR2 DEFAULT 'Y',  -- (Y|N) include on report rejected candidates
  p_repo_non_promoted_spb        IN VARCHAR2 DEFAULT 'Y',  -- (Y|N) include on report non-fixed SPB that is not getting promoted to "FIXED"
  p_pdb_name                     IN VARCHAR2 DEFAULT NULL, -- evaluate only this one PDB
  p_sql_id                       IN VARCHAR2 DEFAULT NULL, -- evaluate only this one SQL
  p_incl_plans_appl_1            IN VARCHAR2 DEFAULT 'Y',  -- (Y|N) include SQL from 1st application (BeginTx)
  p_incl_plans_appl_2            IN VARCHAR2 DEFAULT 'Y',  -- (Y|N) include SQL from 2nd application (CommitTx)
  p_incl_plans_appl_3            IN VARCHAR2 DEFAULT 'Y',  -- (Y|N) include SQL from 3rd application (Read)
  p_incl_plans_appl_4            IN VARCHAR2 DEFAULT 'Y',  -- (Y|N) include SQL from 4th application (GC)
  p_incl_plans_non_appl          IN VARCHAR2 DEFAULT 'N',  -- (N|Y) consider as candidate SQL not qualified as "application module"
  p_execs_candidate              IN NUMBER   DEFAULT NULL, -- a plan must be executed these many times to be a candidate
  p_secs_per_exec_cand           IN NUMBER   DEFAULT NULL, -- a plan must perform better than this threshold to be a candidate
  p_first_load_time_days_cand    IN NUMBER   DEFAULT NULL, -- a sql must be loaded into memory at least this many days before it is considered as candidate
  p_awr_days                     IN NUMBER   DEFAULT NULL  -- amount of days to consider from AWR history assuming retention is at least this long
)
IS
  l_candidate_count_t            NUMBER := 0;
  l_spb_created_qualified_t      NUMBER := 0;
  l_spb_created_count_t          NUMBER := 0;
  l_spb_promoted_qualified_t     NUMBER := 0;
  l_spb_promoted_count_t         NUMBER := 0;
  l_spb_disable_qualified_t      NUMBER := 0;
  l_spb_disabled_count_t         NUMBER := 0;
  l_spb_already_fixed_count_t    NUMBER := 0;
/* ------------------------------------------------------------------------------------ */
BEGIN
  maintain_plans_internal (
    p_report_only                  => p_report_only                  ,
    p_create_spm_limit             => p_create_spm_limit             ,
    p_promote_spm_limit            => p_promote_spm_limit            ,
    p_disable_spm_limit            => p_disable_spm_limit            ,
    p_aggressiveness               => p_aggressiveness               ,
    p_repo_rejected_candidates     => p_repo_rejected_candidates     ,
    p_repo_non_promoted_spb        => p_repo_non_promoted_spb        ,
    p_pdb_name                     => p_pdb_name                     ,
    p_sql_id                       => p_sql_id                       ,
    p_incl_plans_appl_1            => p_incl_plans_appl_1            ,
    p_incl_plans_appl_2            => p_incl_plans_appl_2            ,
    p_incl_plans_appl_3            => p_incl_plans_appl_3            ,
    p_incl_plans_appl_4            => p_incl_plans_appl_4            ,
    p_incl_plans_non_appl          => p_incl_plans_non_appl          ,
    p_execs_candidate              => p_execs_candidate              ,
    p_secs_per_exec_cand           => p_secs_per_exec_cand           ,
    p_first_load_time_days_cand    => p_first_load_time_days_cand    ,
    p_awr_days                     => p_awr_days                     ,
    x_plan_candidates              => l_candidate_count_t            ,
    x_qualified_for_spb_creation   => l_spb_created_qualified_t      ,
    x_spbs_created                 => l_spb_created_count_t          ,
    x_qualified_for_spb_promotion  => l_spb_promoted_qualified_t     ,
    x_spbs_promoted                => l_spb_promoted_count_t         ,
    x_qualified_for_spb_demotion   => l_spb_disable_qualified_t      ,
    x_spbs_demoted                 => l_spb_disabled_count_t         ,
    x_spbs_already_fixed           => l_spb_already_fixed_count_t    );
END maintain_plans;
/* ------------------------------------------------------------------------------------ */
PROCEDURE fpz (
  p_report_only                  IN VARCHAR2 DEFAULT NULL, -- (Y|N) when Y then only produces report and changes nothing
  p_pdb_name                     IN VARCHAR2 DEFAULT NULL, -- evaluate only this one PDB
  p_sql_id                       IN VARCHAR2 DEFAULT NULL  -- evaluate only this one SQL
)
IS
  l_sleep_seconds                NUMBER := 10;
  l_start_time			 DATE := SYSDATE;
  l_db_name                      VARCHAR2(9);
  l_host_name                    VARCHAR2(64);
  l_candidate_count_t            NUMBER := 0;
  l_spb_created_qualified_t      NUMBER := 0;
  l_spb_created_count_t          NUMBER := 0;
  l_spb_promoted_qualified_t     NUMBER := 0;
  l_spb_promoted_count_t         NUMBER := 0;
  l_spb_disable_qualified_t      NUMBER := 0;
  l_spb_disabled_count_t         NUMBER := 0;
  l_spb_already_fixed_count_t    NUMBER := 0;
  l_candidate_count_gt           NUMBER := 0;
  l_spb_created_qualified_gt     NUMBER := 0;
  l_spb_created_count_gt         NUMBER := 0;
  l_spb_promoted_qualified_gt    NUMBER := 0;
  l_spb_promoted_count_gt        NUMBER := 0;
  l_spb_disable_qualified_gt     NUMBER := 0;
  l_spb_disabled_count_gt        NUMBER := 0;
  l_spb_already_fixed_count_gt   NUMBER := 0;
/* ------------------------------------------------------------------------------------ */
BEGIN
  -- gets host name 
  SELECT host_name INTO l_host_name FROM v$instance;
  -- gets database name
  SELECT name INTO l_db_name FROM v$database;
  -- 
  IF p_sql_id IS NULL THEN -- by CDB (p_pdb_name IS NULL) or by PDB (p_pdb_name IS NOT NULL)
    -- level 1
    maintain_plans_internal (
      p_report_only                  => p_report_only                  ,
      p_aggressiveness               => 1                              ,
      p_repo_rejected_candidates     => 'N'                            ,
      p_repo_non_promoted_spb        => 'N'                            ,
      p_pdb_name                     => p_pdb_name                     ,
      x_plan_candidates              => l_candidate_count_t            ,
      x_qualified_for_spb_creation   => l_spb_created_qualified_t      ,
      x_spbs_created                 => l_spb_created_count_t          ,
      x_qualified_for_spb_promotion  => l_spb_promoted_qualified_t     ,
      x_spbs_promoted                => l_spb_promoted_count_t         ,
      x_qualified_for_spb_demotion   => l_spb_disable_qualified_t      ,
      x_spbs_demoted                 => l_spb_disabled_count_t         ,
      x_spbs_already_fixed           => l_spb_already_fixed_count_t    );
    l_candidate_count_gt         := l_candidate_count_gt         + l_candidate_count_t        ;
    l_spb_created_qualified_gt   := l_spb_created_qualified_gt   + l_spb_created_qualified_t  ;
    l_spb_created_count_gt       := l_spb_created_count_gt       + l_spb_created_count_t      ;
    l_spb_promoted_qualified_gt  := l_spb_promoted_qualified_gt  + l_spb_promoted_qualified_t ;
    l_spb_promoted_count_gt      := l_spb_promoted_count_gt      + l_spb_promoted_count_t     ;
    l_spb_disable_qualified_gt   := l_spb_disable_qualified_gt   + l_spb_disable_qualified_t  ;
    l_spb_disabled_count_gt      := l_spb_disabled_count_gt      + l_spb_disabled_count_t     ;
    l_spb_already_fixed_count_gt := l_spb_already_fixed_count_gt + l_spb_already_fixed_count_t;
    IF p_report_only = 'N' THEN
      DBMS_LOCK.SLEEP(l_sleep_seconds);
    END IF;
    -- level 2
    maintain_plans_internal (
      p_report_only                  => p_report_only                  ,
      p_aggressiveness               => 2                              ,
      p_repo_rejected_candidates     => 'N'                            ,
      p_repo_non_promoted_spb        => 'N'                            ,
      p_pdb_name                     => p_pdb_name                     ,
      x_plan_candidates              => l_candidate_count_t            ,
      x_qualified_for_spb_creation   => l_spb_created_qualified_t      ,
      x_spbs_created                 => l_spb_created_count_t          ,
      x_qualified_for_spb_promotion  => l_spb_promoted_qualified_t     ,
      x_spbs_promoted                => l_spb_promoted_count_t         ,
      x_qualified_for_spb_demotion   => l_spb_disable_qualified_t      ,
      x_spbs_demoted                 => l_spb_disabled_count_t         ,
      x_spbs_already_fixed           => l_spb_already_fixed_count_t    );
    l_candidate_count_gt         := l_candidate_count_gt         + l_candidate_count_t        ;
    l_spb_created_qualified_gt   := l_spb_created_qualified_gt   + l_spb_created_qualified_t  ;
    l_spb_created_count_gt       := l_spb_created_count_gt       + l_spb_created_count_t      ;
    l_spb_promoted_qualified_gt  := l_spb_promoted_qualified_gt  + l_spb_promoted_qualified_t ;
    l_spb_promoted_count_gt      := l_spb_promoted_count_gt      + l_spb_promoted_count_t     ;
    l_spb_disable_qualified_gt   := l_spb_disable_qualified_gt   + l_spb_disable_qualified_t  ;
    l_spb_disabled_count_gt      := l_spb_disabled_count_gt      + l_spb_disabled_count_t     ;
    l_spb_already_fixed_count_gt := l_spb_already_fixed_count_gt + l_spb_already_fixed_count_t;
    IF p_report_only = 'N' THEN
      DBMS_LOCK.SLEEP(l_sleep_seconds);
    END IF;
    -- level 3
    maintain_plans_internal (
      p_report_only                  => p_report_only                  ,
      p_aggressiveness               => 3                              ,
      p_repo_rejected_candidates     => 'N'                            ,
      p_repo_non_promoted_spb        => 'N'                            ,
      p_pdb_name                     => p_pdb_name                     ,
      x_plan_candidates              => l_candidate_count_t            ,
      x_qualified_for_spb_creation   => l_spb_created_qualified_t      ,
      x_spbs_created                 => l_spb_created_count_t          ,
      x_qualified_for_spb_promotion  => l_spb_promoted_qualified_t     ,
      x_spbs_promoted                => l_spb_promoted_count_t         ,
      x_qualified_for_spb_demotion   => l_spb_disable_qualified_t      ,
      x_spbs_demoted                 => l_spb_disabled_count_t         ,
      x_spbs_already_fixed           => l_spb_already_fixed_count_t    );
    l_candidate_count_gt         := l_candidate_count_gt         + l_candidate_count_t        ;
    l_spb_created_qualified_gt   := l_spb_created_qualified_gt   + l_spb_created_qualified_t  ;
    l_spb_created_count_gt       := l_spb_created_count_gt       + l_spb_created_count_t      ;
    l_spb_promoted_qualified_gt  := l_spb_promoted_qualified_gt  + l_spb_promoted_qualified_t ;
    l_spb_promoted_count_gt      := l_spb_promoted_count_gt      + l_spb_promoted_count_t     ;
    l_spb_disable_qualified_gt   := l_spb_disable_qualified_gt   + l_spb_disable_qualified_t  ;
    l_spb_disabled_count_gt      := l_spb_disabled_count_gt      + l_spb_disabled_count_t     ;
    l_spb_already_fixed_count_gt := l_spb_already_fixed_count_gt + l_spb_already_fixed_count_t;
    IF p_report_only = 'N' THEN
      DBMS_LOCK.SLEEP(l_sleep_seconds);
    END IF;
    -- level 4
    maintain_plans_internal (
      p_report_only                  => p_report_only                  ,
      p_aggressiveness               => 4                              ,
      p_repo_rejected_candidates     => 'N'                            ,
      p_repo_non_promoted_spb        => 'N'                            ,
      p_pdb_name                     => p_pdb_name                     ,
      x_plan_candidates              => l_candidate_count_t            ,
      x_qualified_for_spb_creation   => l_spb_created_qualified_t      ,
      x_spbs_created                 => l_spb_created_count_t          ,
      x_qualified_for_spb_promotion  => l_spb_promoted_qualified_t     ,
      x_spbs_promoted                => l_spb_promoted_count_t         ,
      x_qualified_for_spb_demotion   => l_spb_disable_qualified_t      ,
      x_spbs_demoted                 => l_spb_disabled_count_t         ,
      x_spbs_already_fixed           => l_spb_already_fixed_count_t    );
    l_candidate_count_gt         := l_candidate_count_gt         + l_candidate_count_t        ;
    l_spb_created_qualified_gt   := l_spb_created_qualified_gt   + l_spb_created_qualified_t  ;
    l_spb_created_count_gt       := l_spb_created_count_gt       + l_spb_created_count_t      ;
    l_spb_promoted_qualified_gt  := l_spb_promoted_qualified_gt  + l_spb_promoted_qualified_t ;
    l_spb_promoted_count_gt      := l_spb_promoted_count_gt      + l_spb_promoted_count_t     ;
    l_spb_disable_qualified_gt   := l_spb_disable_qualified_gt   + l_spb_disable_qualified_t  ;
    l_spb_disabled_count_gt      := l_spb_disabled_count_gt      + l_spb_disabled_count_t     ;
    l_spb_already_fixed_count_gt := l_spb_already_fixed_count_gt + l_spb_already_fixed_count_t;
    IF p_report_only = 'N' THEN
      DBMS_LOCK.SLEEP(l_sleep_seconds);
    END IF;
    -- level 5
    maintain_plans_internal (
      p_report_only                  => p_report_only                  ,
      p_aggressiveness               => 5                              ,
      p_repo_rejected_candidates     => 'Y'                            ,
      p_repo_non_promoted_spb        => 'Y'                            ,
      p_pdb_name                     => p_pdb_name                     ,
      x_plan_candidates              => l_candidate_count_t            ,
      x_qualified_for_spb_creation   => l_spb_created_qualified_t      ,
      x_spbs_created                 => l_spb_created_count_t          ,
      x_qualified_for_spb_promotion  => l_spb_promoted_qualified_t     ,
      x_spbs_promoted                => l_spb_promoted_count_t         ,
      x_qualified_for_spb_demotion   => l_spb_disable_qualified_t      ,
      x_spbs_demoted                 => l_spb_disabled_count_t         ,
      x_spbs_already_fixed           => l_spb_already_fixed_count_t    );
    l_candidate_count_gt         := l_candidate_count_gt         + l_candidate_count_t        ;
    l_spb_created_qualified_gt   := l_spb_created_qualified_gt   + l_spb_created_qualified_t  ;
    l_spb_created_count_gt       := l_spb_created_count_gt       + l_spb_created_count_t      ;
    l_spb_promoted_qualified_gt  := l_spb_promoted_qualified_gt  + l_spb_promoted_qualified_t ;
    l_spb_promoted_count_gt      := l_spb_promoted_count_gt      + l_spb_promoted_count_t     ;
    l_spb_disable_qualified_gt   := l_spb_disable_qualified_gt   + l_spb_disable_qualified_t  ;
    l_spb_disabled_count_gt      := l_spb_disabled_count_gt      + l_spb_disabled_count_t     ;
    l_spb_already_fixed_count_gt := l_spb_already_fixed_count_gt + l_spb_already_fixed_count_t;
    -- global summary
    output(RPAD('+', 145, '-'));
    output('|');
    output('IOD SPM AUT FPZ',                   'Flipping-Plan Zapper (FPZ)');
    output('|');
    output('Database',                          l_db_name);
    output('Host',                              l_host_name);
    output('|');
    output('Candidates',                        l_candidate_count_gt);
    output('SPBs Qualified for Creation',       l_spb_created_qualified_gt);
    output('SPBs Created',                      l_spb_created_count_gt);
    output('SPBs Qualified for Promotion',      l_spb_promoted_qualified_gt);
    output('SPBs Promoted',                     l_spb_promoted_count_gt);
    output('SPBs Qualified for Demotion',       l_spb_disable_qualified_gt);
    output('SPBs Demoted',                      l_spb_disabled_count_gt);
    output('SPBs already Fixed',                l_spb_already_fixed_count_gt);
    output('Date and Time (end)',               TO_CHAR(SYSDATE, 'YYYY-MM-DD"T"HH24:MI:SS'));
    output('Duration (secs)',                   ROUND((SYSDATE - l_start_time) * 24 * 60 * 60));
    output('|');
    output(RPAD('+', 145, '-'));
  ELSE -- p_sql_id IS NOT NULL 
    -- level 1
    maintain_plans_internal (
      p_report_only                  => p_report_only                  ,
      p_aggressiveness               => 1                              ,
      p_pdb_name                     => p_pdb_name                     ,
      p_sql_id                       => p_sql_id                       ,
      x_plan_candidates              => l_candidate_count_t            ,
      x_qualified_for_spb_creation   => l_spb_created_qualified_t      ,
      x_spbs_created                 => l_spb_created_count_t          ,
      x_qualified_for_spb_promotion  => l_spb_promoted_qualified_t     ,
      x_spbs_promoted                => l_spb_promoted_count_t         ,
      x_qualified_for_spb_demotion   => l_spb_disable_qualified_t      ,
      x_spbs_demoted                 => l_spb_disabled_count_t         ,
      x_spbs_already_fixed           => l_spb_already_fixed_count_t    );
    IF l_spb_created_count_t > 0 THEN
      RETURN;
    END IF;    
    -- level 2
    maintain_plans_internal (
      p_report_only                  => p_report_only                  ,
      p_aggressiveness               => 2                              ,
      p_pdb_name                     => p_pdb_name                     ,
      p_sql_id                       => p_sql_id                       ,
      x_plan_candidates              => l_candidate_count_t            ,
      x_qualified_for_spb_creation   => l_spb_created_qualified_t      ,
      x_spbs_created                 => l_spb_created_count_t          ,
      x_qualified_for_spb_promotion  => l_spb_promoted_qualified_t     ,
      x_spbs_promoted                => l_spb_promoted_count_t         ,
      x_qualified_for_spb_demotion   => l_spb_disable_qualified_t      ,
      x_spbs_demoted                 => l_spb_disabled_count_t         ,
      x_spbs_already_fixed           => l_spb_already_fixed_count_t    );
    IF l_spb_created_count_t > 0 THEN
      RETURN;
    END IF;    
    -- level 3
    maintain_plans_internal (
      p_report_only                  => p_report_only                  ,
      p_aggressiveness               => 3                              ,
      p_pdb_name                     => p_pdb_name                     ,
      p_sql_id                       => p_sql_id                       ,
      x_plan_candidates              => l_candidate_count_t            ,
      x_qualified_for_spb_creation   => l_spb_created_qualified_t      ,
      x_spbs_created                 => l_spb_created_count_t          ,
      x_qualified_for_spb_promotion  => l_spb_promoted_qualified_t     ,
      x_spbs_promoted                => l_spb_promoted_count_t         ,
      x_qualified_for_spb_demotion   => l_spb_disable_qualified_t      ,
      x_spbs_demoted                 => l_spb_disabled_count_t         ,
      x_spbs_already_fixed           => l_spb_already_fixed_count_t    );
    IF l_spb_created_count_t > 0 THEN
      RETURN;
    END IF;    
    -- level 4
    maintain_plans_internal (
      p_report_only                  => p_report_only                  ,
      p_aggressiveness               => 4                              ,
      p_pdb_name                     => p_pdb_name                     ,
      p_sql_id                       => p_sql_id                       ,
      x_plan_candidates              => l_candidate_count_t            ,
      x_qualified_for_spb_creation   => l_spb_created_qualified_t      ,
      x_spbs_created                 => l_spb_created_count_t          ,
      x_qualified_for_spb_promotion  => l_spb_promoted_qualified_t     ,
      x_spbs_promoted                => l_spb_promoted_count_t         ,
      x_qualified_for_spb_demotion   => l_spb_disable_qualified_t      ,
      x_spbs_demoted                 => l_spb_disabled_count_t         ,
      x_spbs_already_fixed           => l_spb_already_fixed_count_t    );
    IF l_spb_created_count_t > 0 THEN
      RETURN;
    END IF;    
    -- level 5
    maintain_plans_internal (
      p_report_only                  => p_report_only                  ,
      p_aggressiveness               => 5                              ,
      p_pdb_name                     => p_pdb_name                     ,
      p_sql_id                       => p_sql_id                       ,
      p_execs_candidate              => 1                              , -- laxed
      p_secs_per_exec_cand           => 60                             , -- laxed
      p_first_load_time_days_cand    => 0                              , -- laxed
      x_plan_candidates              => l_candidate_count_t            ,
      x_qualified_for_spb_creation   => l_spb_created_qualified_t      ,
      x_spbs_created                 => l_spb_created_count_t          ,
      x_qualified_for_spb_promotion  => l_spb_promoted_qualified_t     ,
      x_spbs_promoted                => l_spb_promoted_count_t         ,
      x_qualified_for_spb_demotion   => l_spb_disable_qualified_t      ,
      x_spbs_demoted                 => l_spb_disabled_count_t         ,
      x_spbs_already_fixed           => l_spb_already_fixed_count_t    );
  END IF;    
END fpz;
/* ------------------------------------------------------------------------------------ */
END iod_spm;
/

SET FEED ON VER OFF HEA ON LIN 32767 PAGES 100 TIMI OFF LONG 80 LONGC 80 TRIMS ON AUTOT OFF;
COL current_time NEW_V current_time FOR A15 NOPRI;
SELECT 'current_time: ' x, TO_CHAR(SYSDATE, 'YYYYMMDD_HH24MISS') current_time FROM DUAL;
SPO active_sql_&&current_time..txt

COL sql_text_100 FOR A100;
COL module_30 FOR A30;

SELECT sq.sql_id,
       SUM(sq.executions) executions,
       ROUND(SUM(sq.elapsed_time)/1e6) elapsed_time_secs,
       ROUND(SUM(sq.elapsed_time)/1e3/SUM(sq.executions),3) ms_per_exec,
       SUBSTR(sq.sql_text, 1, 100) sql_text_100,
       SUBSTR(sq.module, 1, 30) module_30
  FROM gv$session se,
       gv$sql sq
 WHERE se.status = 'ACTIVE'
   AND sq.inst_id = se.inst_id
   AND sq.sql_id = se.sql_id
   AND sq.child_number = se.sql_child_number
   AND sq.executions > 0
 GROUP BY
       sq.sql_id,
       SUBSTR(sq.sql_text, 1, 100),
       SUBSTR(sq.module, 1, 30)
 HAVING
       ROUND(SUM(sq.elapsed_time)/1e6) > 60 OR SUM(sq.executions) > 1000
/
       
SPO OFF;

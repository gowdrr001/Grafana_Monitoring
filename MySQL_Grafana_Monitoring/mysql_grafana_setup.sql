/**********************************************
* DATABASE & TABLE SETUP FOR GRAFANA MONITORING
**********************************************/

CREATE DATABASE IF NOT EXISTS grafana_monitoring;
USE grafana_monitoring;

-- Table to store time-series metric snapshots
CREATE TABLE IF NOT EXISTS status (
  VARIABLE_NAME   VARCHAR(64)  CHARACTER SET utf8 NOT NULL DEFAULT '',
  VARIABLE_VALUE  VARCHAR(1024) CHARACTER SET utf8 DEFAULT NULL,
  TIMEST          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY idx01 (VARIABLE_NAME, TIMEST)
) ENGINE=InnoDB;

-- Table to store latest snapshot (used for delta calculations)
CREATE TABLE IF NOT EXISTS current (
  VARIABLE_NAME   VARCHAR(64) CHARACTER SET utf8 NOT NULL DEFAULT '',
  VARIABLE_VALUE  VARCHAR(1024) CHARACTER SET utf8 DEFAULT NULL,
  UNIQUE KEY idx02 (VARIABLE_NAME)
) ENGINE=InnoDB;


/**********************************************
* PROCEDURE: collect_stats()
* Collects MySQL system metrics
**********************************************/

DROP PROCEDURE IF EXISTS collect_stats;
DELIMITER //

CREATE PROCEDURE collect_stats()
BEGIN

  DECLARE a DATETIME;
  DECLARE v VARCHAR(10);

  SET sql_log_bin = 0;

  SET a = NOW();

  SELECT SUBSTR(VERSION(),1,3) INTO v;

  -- Collect numeric system variables
  INSERT INTO grafana_monitoring.status(variable_name, variable_value, timest)
    SELECT UPPER(variable_name), variable_value, a
    FROM performance_schema.global_status
    WHERE variable_value REGEXP '^-*[[:digit:]]+(\\.[[:digit:]]+)?$'
      AND variable_name NOT LIKE 'Performance_schema_%'
      AND variable_name NOT LIKE 'SSL_%';


  -- Replication worker execution time
  INSERT INTO grafana_monitoring.status(variable_name, variable_value, timest)
    SELECT 'REPLICATION_MAX_WORKER_TIME', COALESCE(MAX(PROCESSLIST_TIME),0.1), a
    FROM performance_schema.threads
    WHERE (NAME='thread/sql/slave_worker'
      AND (PROCESSLIST_STATE IS NULL
      OR PROCESSLIST_STATE!='Waiting for an event from Coordinator'))
      OR NAME='thread/sql/slave_sql';


  -- Process count by user
  INSERT INTO grafana_monitoring.status(variable_name, variable_value, timest)
    SELECT CONCAT('PROCESSES.',user), COUNT(*), a
    FROM information_schema.processlist
    GROUP BY user;


  -- Process count by host
  INSERT INTO grafana_monitoring.status(variable_name, variable_value, timest)
    SELECT CONCAT('PROCESSES_HOSTS.',SUBSTRING_INDEX(host,':',1)), COUNT(*), a
    FROM information_schema.processlist
    GROUP BY SUBSTRING_INDEX(host,':',1);


  -- Process by command
  INSERT INTO grafana_monitoring.status(variable_name, variable_value, timest)
    SELECT CONCAT('PROCESSES_COMMAND.',command), COUNT(*), a
    FROM information_schema.processlist
    GROUP BY command;


  -- Process by state
  INSERT INTO grafana_monitoring.status(variable_name, variable_value, timest)
    SELECT SUBSTR(CONCAT('PROCESSES_STATE.',state),1,64), COUNT(*), a
    FROM information_schema.processlist
    GROUP BY state;


  -- Statement wait time
  INSERT INTO grafana_monitoring.status(variable_name, variable_value, timest)
    SELECT 'SUM_TIMER_WAIT', SUM(sum_timer_wait*1.0), a
    FROM performance_schema.events_statements_summary_global_by_event_name;



/******** DELTA CALCULATIONS ********/

  INSERT INTO grafana_monitoring.status(variable_name, variable_value, timest)
    SELECT CONCAT(UPPER(s.variable_name),'-d'),
    GREATEST(s.variable_value - c.variable_value,0), a
    FROM performance_schema.global_status s
    JOIN grafana_monitoring.current c
    ON s.variable_name = c.variable_name;



  INSERT INTO grafana_monitoring.status(variable_name, variable_value, timest)
    SELECT CONCAT('COM_',UPPER(SUBSTR(s.EVENT_NAME,15,58)),'-d'),
    GREATEST(s.COUNT_STAR - c.variable_value,0), a
    FROM performance_schema.events_statements_summary_global_by_event_name s
    JOIN grafana_monitoring.current c
    ON s.EVENT_NAME = c.variable_name
    WHERE s.EVENT_NAME LIKE 'statement/sql/%';



  INSERT INTO grafana_monitoring.status(variable_name, variable_value, timest)
    SELECT 'SUM_TIMER_WAIT-d',
    SUM(sum_timer_wait*1.0) - c.variable_value, a
    FROM performance_schema.events_statements_summary_global_by_event_name,
    grafana_monitoring.current c
    WHERE c.variable_name='SUM_TIMER_WAIT';



/******** REPLICATION STATUS ********/

  INSERT INTO grafana_monitoring.status(variable_name, variable_value, timest)
    SELECT 'REPLICATION_CONNECTION_STATUS',
    IF(SERVICE_STATE='ON',1,0), a
    FROM performance_schema.replication_connection_status;



  INSERT INTO grafana_monitoring.status(variable_name, variable_value, timest)
    SELECT 'REPLICATION_APPLIER_STATUS',
    IF(SERVICE_STATE='ON',1,0), a
    FROM performance_schema.replication_applier_status;



/******** UPDATE CURRENT SNAPSHOT ********/

  DELETE FROM grafana_monitoring.current;



  INSERT INTO grafana_monitoring.current(variable_name, variable_value)
    SELECT UPPER(variable_name), variable_value+0
    FROM performance_schema.global_status
    WHERE variable_value REGEXP '^-*[[:digit:]]+(\\.[[:digit:]]+)?$'
      AND variable_name NOT LIKE 'Performance_schema_%'
      AND variable_name NOT LIKE 'SSL_%';



  INSERT INTO grafana_monitoring.current(variable_name, variable_value)
    SELECT SUBSTR(EVENT_NAME,1,40), COUNT_STAR
    FROM performance_schema.events_statements_summary_global_by_event_name
    WHERE EVENT_NAME LIKE 'statement/sql/%';



  INSERT INTO grafana_monitoring.current(variable_name, variable_value)
    SELECT 'SUM_TIMER_WAIT', SUM(sum_timer_wait*1.0)
    FROM performance_schema.events_statements_summary_global_by_event_name;



  INSERT INTO grafana_monitoring.current(variable_name, variable_value)
    SELECT CONCAT('PROCESSES_COMMAND.',command), COUNT(*)
    FROM information_schema.processlist
    GROUP BY command;



  INSERT INTO grafana_monitoring.current(variable_name, variable_value)
    SELECT UPPER(variable_name), variable_value
    FROM performance_schema.global_variables
    WHERE variable_name IN
    ('max_connections',
     'innodb_buffer_pool_size',
     'query_cache_size',
     'innodb_log_buffer_size',
     'key_buffer_size',
     'table_open_cache');

  SET sql_log_bin = 1;

END //

DELIMITER ;



/**********************************************
* PROCEDURE: collect_daily_stats()
**********************************************/

DROP PROCEDURE IF EXISTS collect_daily_stats;
DELIMITER //

CREATE PROCEDURE collect_daily_stats()
BEGIN

  DECLARE a DATETIME;

  SET sql_log_bin = 0;

  SET a = NOW();


  INSERT INTO grafana_monitoring.status(variable_name, variable_value, timest)
    SELECT CONCAT('SIZEDB.',table_schema),
    SUM(data_length + index_length), a
    FROM information_schema.tables
    GROUP BY table_schema;



  INSERT INTO grafana_monitoring.status(variable_name, variable_value, timest)
    SELECT 'SIZEDB.TOTAL',
    SUM(data_length + index_length), a
    FROM information_schema.tables;



  DELETE FROM grafana_monitoring.status
  WHERE timest < DATE_SUB(NOW(), INTERVAL 62 DAY)
  AND variable_name <> 'SIZEDB.TOTAL';



  DELETE FROM grafana_monitoring.status
  WHERE timest < DATE_SUB(NOW(), INTERVAL 365 DAY);



  SET sql_log_bin = 1;

END //

DELIMITER ;



/**********************************************
* EVENT SCHEDULER
**********************************************/

SET GLOBAL event_scheduler = ON;

SET sql_log_bin = 0;

DROP EVENT IF EXISTS collect_stats;

CREATE EVENT collect_stats
ON SCHEDULE EVERY 5 MINUTE
DO CALL collect_stats();



DROP EVENT IF EXISTS collect_daily_stats;

CREATE EVENT collect_daily_stats
ON SCHEDULE EVERY 1 DAY
DO CALL collect_daily_stats();

SET sql_log_bin = 1;



/**********************************************
* GRAFANA MONITOR USER
**********************************************/

CREATE USER IF NOT EXISTS 'grafana_monitoring'@'localhost'
IDENTIFIED BY 'Grafana@123';

GRANT SELECT, INSERT, DELETE
ON grafana_monitoring.*
TO 'grafana_monitoring'@'localhost';

GRANT SELECT
ON performance_schema.*
TO 'grafana_monitoring'@'localhost';

GRANT PROCESS
ON *.*
TO 'grafana_monitoring'@'localhost';

FLUSH PRIVILEGES;

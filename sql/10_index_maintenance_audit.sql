/* =====================================================================
   Индексы: фрагментация, плотность, использование, подсказки Missing Index
   Вопросы 7, 54 методички.
   ===================================================================== */

/* ---------- 1. Фрагментация и плотность (LIMITED не даёт плотности -> SAMPLED) ---------- */
SELECT OBJECT_SCHEMA_NAME(ps.object_id) + N'.' + OBJECT_NAME(ps.object_id) AS table_name,
       i.name AS index_name, ps.index_type_desc, ps.page_count,
       ps.avg_fragmentation_in_percent,        -- внешняя (логическая) фрагментация
       ps.avg_page_space_used_in_percent,      -- плотность = обратная сторона внутренней
       i.fill_factor
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'SAMPLED') ps
JOIN sys.indexes i ON i.object_id = ps.object_id AND i.index_id = ps.index_id
WHERE ps.page_count > 1000 AND ps.index_level = 0
ORDER BY ps.avg_fragmentation_in_percent DESC;
/* Классический ориентир: 10–30% -> REORGANIZE, > 30% -> REBUILD.
   На SSD внешняя фрагментация почти не влияет на seek; важнее плотность страниц. */
GO

/* ---------- 2. Использование индексов с момента старта (LEFT JOIN: неиспользуемых нет в DMV!) ---------- */
SELECT OBJECT_SCHEMA_NAME(i.object_id) + N'.' + OBJECT_NAME(i.object_id) AS table_name,
       i.name AS index_name, i.is_unique,
       ISNULL(us.user_seeks, 0) AS seeks, ISNULL(us.user_scans, 0) AS scans,
       ISNULL(us.user_lookups, 0) AS lookups, ISNULL(us.user_updates, 0) AS updates,
       us.last_user_seek, us.last_user_scan
FROM sys.indexes i
JOIN sys.objects o ON o.object_id = i.object_id AND o.type = 'U'
LEFT JOIN sys.dm_db_index_usage_stats us
       ON us.database_id = DB_ID() AND us.object_id = i.object_id AND us.index_id = i.index_id
WHERE i.index_id >= 2 AND i.is_primary_key = 0 AND i.is_unique_constraint = 0
ORDER BY ISNULL(us.user_seeks + us.user_scans + us.user_lookups, 0), ISNULL(us.user_updates, 0) DESC;

SELECT sqlserver_start_time FROM sys.dm_os_sys_info;   -- с какого момента копится статистика
GO

/* ---------- 3. Подсказки Missing Index: только как материал для анализа ---------- */
SELECT TOP (25)
    mid.statement AS table_name,
    mid.equality_columns, mid.inequality_columns, mid.included_columns,
    migs.user_seeks, migs.avg_total_user_cost, migs.avg_user_impact,
    migs.user_seeks * migs.avg_total_user_cost * migs.avg_user_impact / 100.0 AS rough_benefit
FROM sys.dm_db_missing_index_details mid
JOIN sys.dm_db_missing_index_groups mig        ON mig.index_handle = mid.index_handle
JOIN sys.dm_db_missing_index_group_stats migs  ON migs.group_handle = mig.index_group_handle
WHERE mid.database_id = DB_ID()
ORDER BY rough_benefit DESC;
/* Перед CREATE INDEX: сравнить с существующими индексами таблицы (sp_helpindex),
   проверить запрос на SARGable/типы/SELECT *, оценить нагрузку записи (updates выше). */
GO

/* ---------- 4. Существующие индексы таблицы с ключами и INCLUDE ---------- */
-- EXEC sp_helpindex N'dbo.Orders';
SELECT i.name, i.type_desc, i.is_unique, i.fill_factor, i.filter_definition,
       STUFF((SELECT N', ' + c.name + CASE WHEN ic.is_descending_key = 1 THEN N' DESC' ELSE N'' END
              FROM sys.index_columns ic JOIN sys.columns c
                   ON c.object_id = ic.object_id AND c.column_id = ic.column_id
              WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
              ORDER BY ic.key_ordinal FOR XML PATH('')), 1, 2, N'') AS key_columns,
       STUFF((SELECT N', ' + c.name
              FROM sys.index_columns ic JOIN sys.columns c
                   ON c.object_id = ic.object_id AND c.column_id = ic.column_id
              WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 1
              FOR XML PATH('')), 1, 2, N'') AS included_columns
FROM sys.indexes i
WHERE i.object_id = OBJECT_ID(N'dbo.Orders') AND i.index_id > 0;
GO

/* ---------- 5. Обслуживание ---------- */
-- ALTER INDEX IX_Name ON dbo.T REORGANIZE;
-- ALTER INDEX IX_Name ON dbo.T REBUILD WITH (FILLFACTOR = 90, ONLINE = ON);  -- ONLINE: Enterprise
-- UPDATE STATISTICS dbo.T WITH FULLSCAN;    -- после REORGANIZE: он статистику НЕ обновляет

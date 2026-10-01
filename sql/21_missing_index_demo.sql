/* =====================================================================
   Missing Index: откуда берутся подсказки, как их читать и как не надо их применять
   Вопрос 54 методички. Тестовый экземпляр, SQL Server 2016+ (блок 4 — 2019+).
   Выполнять ПО БЛОКАМ. Включите фактический план (Ctrl+M) и SET STATISTICS IO ON.
   ===================================================================== */
USE master;
GO
IF DB_ID(N'MissingIdxDemo') IS NOT NULL
BEGIN
    ALTER DATABASE MissingIdxDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE MissingIdxDemo;
END;
GO
CREATE DATABASE MissingIdxDemo;
GO
USE MissingIdxDemo;
GO

/* ---------- 0. 500 000 заказов, кроме первичного ключа индексов нет ---------- */
CREATE TABLE dbo.Orders
(
    OrderID    int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED,
    Status     tinyint       NOT NULL,     -- столбец идёт РАНЬШЕ CustomerID: увидим порядок в подсказке
    CustomerID int           NOT NULL,
    OrderDate  date          NOT NULL,
    Amount     decimal(12,2) NOT NULL,
    Comment    nvarchar(200) NOT NULL
);
GO
;WITH n AS (SELECT TOP (500000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
            FROM sys.all_columns a CROSS JOIN sys.all_columns b)
INSERT dbo.Orders (Status, CustomerID, OrderDate, Amount, Comment)
SELECT (n / 7) % 5, n % 10000 + 1, DATEADD(DAY, -(n % 1000), '20260101'), n % 1000, N'комментарий'
FROM n;
GO
SET STATISTICS IO ON;
GO

/* =====================================================================
   БЛОК 1. Подсказка появляется: Clustered Index Scan + зелёный текст над планом
   ===================================================================== */
-- 1.1 Равенства по CustomerID и Status, выбираем Amount и OrderDate
SELECT OrderID, OrderDate, Amount
FROM dbo.Orders
WHERE CustomerID = 42 AND Status = 2;
GO
-- 1.2 Равенство по CustomerID + диапазон по дате, выбираем Amount
SELECT OrderID, Amount
FROM dbo.Orders
WHERE CustomerID = 42 AND OrderDate >= '20250101';
GO
-- 1.3 SELECT * — подсказка предложит INCLUDE почти всех столбцов
SELECT *
FROM dbo.Orders
WHERE CustomerID = 77;
GO
-- Выполните каждый запрос 2–3 раза, чтобы набрались user_seeks.

/* =====================================================================
   БЛОК 2. Подсказки в DMV: как читать
   ===================================================================== */
SELECT mid.statement                 AS table_name,
       mid.equality_columns,         -- порядок: по column_id (Status раньше CustomerID!), не по пользе
       mid.inequality_columns,
       mid.included_columns,         -- у запроса 1.3 — почти все столбцы
       migs.user_seeks, migs.avg_total_user_cost, migs.avg_user_impact
FROM sys.dm_db_missing_index_details mid
JOIN sys.dm_db_missing_index_groups mig       ON mig.index_handle = mid.index_handle
JOIN sys.dm_db_missing_index_group_stats migs ON migs.group_handle = mig.index_group_handle
WHERE mid.database_id = DB_ID()
ORDER BY migs.avg_user_impact DESC;
GO

/* =====================================================================
   БЛОК 3. Все подсказки из XML плана в кэше
   ===================================================================== */
WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
SELECT SUBSTRING(st.text, qs.statement_start_offset / 2 + 1, 120)       AS stmt,
       g.value('@Impact', 'float')                                      AS impact_pct,
       cg.value('@Usage', 'nvarchar(20)')                               AS usage,      -- EQUALITY / INEQUALITY / INCLUDE
       c.value('@Name', 'nvarchar(128)')                                AS column_name
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) qp
CROSS APPLY qp.query_plan.nodes('//MissingIndexGroup') AS x(g)
CROSS APPLY g.nodes('MissingIndex/ColumnGroup') AS y(cg)
CROSS APPLY cg.nodes('Column') AS z(c)
WHERE st.text LIKE N'%dbo.Orders%' AND st.text NOT LIKE N'%dm_exec%'
ORDER BY stmt, usage;
GO

/* =====================================================================
   БЛОК 4. SQL Server 2019+: какой запрос просил индекс
   ===================================================================== */
-- SELECT migsq.user_seeks, migsq.avg_user_impact, mid.equality_columns, mid.inequality_columns,
--        mid.included_columns,
--        SUBSTRING(st.text, migsq.last_statement_start_offset / 2 + 1, 200) AS query_text
-- FROM sys.dm_db_missing_index_group_stats_query migsq
-- JOIN sys.dm_db_missing_index_groups mig  ON mig.index_group_handle = migsq.group_handle
-- JOIN sys.dm_db_missing_index_details mid ON mid.index_handle = mig.index_handle
-- CROSS APPLY sys.dm_exec_sql_text(migsq.last_sql_handle) st
-- WHERE mid.database_id = DB_ID();

/* =====================================================================
   БЛОК 5. Как НЕ надо и как надо
   ===================================================================== */
-- 5.1 «Слепо»: три индекса по трём подсказкам, в том числе копия таблицы для SELECT *
--     (не выполняйте на рабочих базах; здесь — чтобы увидеть размер)
CREATE INDEX IX_Blind_1 ON dbo.Orders (Status, CustomerID) INCLUDE (OrderDate, Amount);
CREATE INDEX IX_Blind_2 ON dbo.Orders (CustomerID, OrderDate) INCLUDE (Amount);
CREATE INDEX IX_Blind_3 ON dbo.Orders (CustomerID) INCLUDE (Status, OrderDate, Amount, Comment);
GO
SELECT i.name, ps.used_page_count, ps.row_count
FROM sys.dm_db_partition_stats ps
JOIN sys.indexes i ON i.object_id = ps.object_id AND i.index_id = ps.index_id
WHERE ps.object_id = OBJECT_ID(N'dbo.Orders');      -- IX_Blind_3 почти размером с таблицу
GO
DROP INDEX IX_Blind_1 ON dbo.Orders;
DROP INDEX IX_Blind_2 ON dbo.Orders;
DROP INDEX IX_Blind_3 ON dbo.Orders;
GO
-- 5.2 «Осмысленно»: один индекс закрывает запросы 1.1 и 1.2.
--     CustomerID первым (есть во всех запросах), OrderDate — диапазон, Status проверится как Predicate
--     среди ~50 заказов клиента. SELECT * в 1.3 правильнее переписать на нужные столбцы.
CREATE INDEX IX_Orders_Customer_Date ON dbo.Orders (CustomerID, OrderDate) INCLUDE (Status, Amount);
GO
-- 5.3 Проверка «до/после»: Index Seek вместо скана, logical reads — единицы вместо тысяч
SELECT OrderID, OrderDate, Amount FROM dbo.Orders WHERE CustomerID = 42 AND Status = 2;
SELECT OrderID, Amount            FROM dbo.Orders WHERE CustomerID = 42 AND OrderDate >= '20250101';
GO
-- 5.4 Подсказки по таблице сброшены при изменении её метаданных (создании индекса)
SELECT COUNT(*) AS suggestions_left
FROM sys.dm_db_missing_index_details
WHERE database_id = DB_ID() AND object_id = OBJECT_ID(N'dbo.Orders');
GO
SET STATISTICS IO OFF;
GO
-- Уборка
-- USE master; ALTER DATABASE MissingIdxDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE MissingIdxDemo;

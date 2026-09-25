/* =====================================================================
   Практикум: Query Store на базе WarningsDemo (SQL Server 2019)
   Сценарий: у запроса из-за parameter sniffing появляются два плана,
   находим их в Query Store, сравниваем и закрепляем один из них.
   Выполнять ПО ШАГАМ, между шагами смотреть отчёты в SSMS.
   ПРЕДВАРИТЕЛЬНО: выполните 03_plan_warnings_demo.sql — он создаёт
   базу WarningsDemo с таблицей dbo.Sales (1 млн строк).
   ===================================================================== */
USE WarningsDemo;
GO

/* ---------------------------------------------------------------------
   Шаг 0. Настройка Query Store для учёбы
   Интервал 1 минута — чтобы на графике было видно смену плана
   во времени (на рабочих базах обычно 15–60 минут).
   CLEAR — очистить всё собранное ранее, чтобы картинка была чистой.
   --------------------------------------------------------------------- */
ALTER DATABASE WarningsDemo SET QUERY_STORE
    (OPERATION_MODE = READ_WRITE, QUERY_CAPTURE_MODE = ALL,
     INTERVAL_LENGTH_MINUTES = 1);
ALTER DATABASE WarningsDemo SET QUERY_STORE CLEAR;
GO

/* ---------------------------------------------------------------------
   Шаг 1. Данные с перекосом: половина продаж у клиента 1,
   у остальных — по 0–2 продажи. Индекс по ClientID НЕ покрывающий:
   для мелкого клиента выгоден Seek + Key Lookup,
   для клиента 1 — Clustered Index Scan.
   --------------------------------------------------------------------- */
UPDATE dbo.Sales SET ClientID = 1 WHERE SaleID % 2 = 0;
CREATE INDEX IX_Sales_ClientID ON dbo.Sales (ClientID);
UPDATE STATISTICS dbo.Sales WITH FULLSCAN;
GO

CREATE OR ALTER PROCEDURE dbo.GetClientSales @ClientID int
AS
    SELECT COUNT_BIG(*) AS Cnt, SUM(Amount) AS Total, MAX(SaleDate) AS LastDate
    FROM dbo.Sales
    WHERE ClientID = @ClientID;
GO

/* ---------------------------------------------------------------------
   Шаг 2. Фаза «А»: план компилируется под МЕЛКОГО клиента
   (Index Seek + Key Lookup + Nested Loops), потом им же
   обслуживается крупный клиент → ~500 тыс. Key Lookup.
   --------------------------------------------------------------------- */
EXEC sp_recompile N'dbo.GetClientSales';
GO
EXEC dbo.GetClientSales @ClientID = 777;
GO 20
EXEC dbo.GetClientSales @ClientID = 1;
GO 5

/* ---------------------------------------------------------------------
   Шаг 3. Подождите 1–2 минуты (чтобы начался новый интервал),
   затем фаза «Б»: план компилируется под КРУПНОГО клиента
   (Clustered Index Scan), и им же обслуживаются мелкие →
   каждый мелкий вызов сканирует всю таблицу.
   --------------------------------------------------------------------- */
EXEC sp_recompile N'dbo.GetClientSales';
GO
EXEC dbo.GetClientSales @ClientID = 1;
GO 5
EXEC dbo.GetClientSales @ClientID = 777;
GO 20

/* ---------------------------------------------------------------------
   Шаг 4. То же, что в отчётах, но запросом:
   какие планы были у запроса процедуры и как они работали.
   Время в Query Store — в микросекундах, чтения — в страницах 8 КБ.
   --------------------------------------------------------------------- */
SELECT
    q.query_id,
    p.plan_id,
    p.is_forced_plan,
    SUM(rs.count_executions)                             AS execs,
    CAST(AVG(rs.avg_duration) / 1000.0 AS decimal(12,2)) AS avg_duration_ms,
    CAST(MAX(rs.max_duration) / 1000.0 AS decimal(12,2)) AS max_duration_ms,
    CAST(AVG(rs.avg_logical_io_reads) AS bigint)         AS avg_logical_reads,
    CAST(MAX(rs.max_logical_io_reads) AS bigint)         AS max_logical_reads,
    TRY_CAST(p.query_plan AS xml)                        AS query_plan
FROM sys.query_store_query          AS q
JOIN sys.query_store_plan           AS p  ON p.query_id = q.query_id
JOIN sys.query_store_runtime_stats  AS rs ON rs.plan_id = p.plan_id
WHERE q.object_id = OBJECT_ID(N'dbo.GetClientSales')
GROUP BY q.query_id, p.plan_id, p.is_forced_plan, p.query_plan
ORDER BY p.plan_id;
GO

/* ---------------------------------------------------------------------
   Шаг 5. Закрепить план (подставьте свои query_id и plan_id
   из шага 4 или из отчёта). Или кнопка Force Plan в отчёте.
   --------------------------------------------------------------------- */
-- EXEC sp_query_store_force_plan @query_id = 1, @plan_id = 1;
GO

/* ---------------------------------------------------------------------
   Шаг 6. Проверка: сбрасываем план и нарочно вызываем «не тем»
   клиентом первым — план всё равно должен быть закреплённым.
   В фактическом плане (Ctrl+M) у корневого SELECT свойство
   Use plan = True; в отчёте у точек закреплённого плана — галочка.
   --------------------------------------------------------------------- */
EXEC sp_recompile N'dbo.GetClientSales';
GO
EXEC dbo.GetClientSales @ClientID = 1;
GO 3
EXEC dbo.GetClientSales @ClientID = 777;
GO 10

-- Закрепление применилось без ошибок?
SELECT query_id, plan_id, is_forced_plan,
       force_failure_count, last_force_failure_reason_desc
FROM sys.query_store_plan
WHERE is_forced_plan = 1;
GO

/* ---------------------------------------------------------------------
   Шаг 7. Снять закрепление
   --------------------------------------------------------------------- */
-- EXEC sp_query_store_unforce_plan @query_id = 1, @plan_id = 1;
GO

/* ---------------------------------------------------------------------
   Шаг 8. Правильное лечение: покрывающий индекс убирает развилку планов.
   После него Seek без Lookup выгоден для любого клиента.
   --------------------------------------------------------------------- */
-- CREATE INDEX IX_Sales_ClientID ON dbo.Sales (ClientID) INCLUDE (Amount, SaleDate)
-- WITH (DROP_EXISTING = ON);

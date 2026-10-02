/* =====================================================================
   Вложенный запрос или временная таблица: оценка кардинальности
   Вопрос 39а методички. Тестовый экземпляр, SQL Server 2016+.
   Выполнять ПО БЛОКАМ с фактическим планом (Ctrl+M) и SET STATISTICS IO ON.
   Смотреть: Estimated vs Actual на выходе HAVING (Filter), алгоритм соединения
   с Orders, logical reads по Orders.
   ===================================================================== */
USE master;
GO
IF DB_ID(N'SubqueryDemo') IS NOT NULL
BEGIN
    ALTER DATABASE SubqueryDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE SubqueryDemo;
END;
GO
CREATE DATABASE SubqueryDemo;
GO
USE SubqueryDemo;
GO

/* ---------- 0. 50 000 клиентов, ~1 000 000 заказов.
   40 «крупных» клиентов получают редкие заказы на 50 000 — только они пройдут HAVING > 100 000. ---------- */
CREATE TABLE dbo.Customers
(
    CustomerID int          NOT NULL CONSTRAINT PK_Customers PRIMARY KEY CLUSTERED,
    Name       nvarchar(50) NOT NULL,
    Region     nvarchar(30) NOT NULL
);
CREATE TABLE dbo.Orders
(
    OrderID    int           NOT NULL CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED,
    CustomerID int           NOT NULL,
    OrderDate  date          NOT NULL,
    Amount     decimal(12,2) NOT NULL
);
GO
;WITH n AS (SELECT TOP (1000000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
            FROM sys.all_columns a CROSS JOIN sys.all_columns b)
SELECT n INTO #N FROM n;
INSERT dbo.Customers SELECT n, N'Клиент ' + CAST(n AS nvarchar(10)),
       CASE n % 5 WHEN 0 THEN N'Москва' WHEN 1 THEN N'Казань' WHEN 2 THEN N'Пермь' WHEN 3 THEN N'Томск' ELSE N'Омск' END
FROM #N WHERE n <= 50000;
INSERT dbo.Orders
SELECT n,
       CASE WHEN n % 2500 = 0 THEN (n / 2500) % 40 + 1 ELSE n % 50000 + 1 END,   -- 40 «крупных» клиентов
       CASE WHEN n % 2500 = 0 THEN CAST('20250615' AS date) ELSE DATEADD(DAY, -(n % 1500), '20260101') END,
       CASE WHEN n % 2500 = 0 THEN 50000 ELSE n % 1000 END
FROM #N;
DROP TABLE #N;
GO
CREATE INDEX IX_Orders_CustomerID ON dbo.Orders (CustomerID) INCLUDE (OrderDate, Amount);
CREATE INDEX IX_Orders_OrderDate  ON dbo.Orders (OrderDate)  INCLUDE (CustomerID, Amount);
UPDATE STATISTICS dbo.Orders WITH FULLSCAN;
UPDATE STATISTICS dbo.Customers WITH FULLSCAN;
GO
SET STATISTICS IO ON;
GO

/* =====================================================================
   БЛОК 1. Один запрос с вложенным: оценка после HAVING — догадка
   ===================================================================== */
-- В плане найдите Filter (HAVING) после агрегата: Estimated — тысячи, Actual — 40.
-- Дальше соединение с Orders: обычно Hash Match + скан, logical reads по Orders — тысячи страниц.
SELECT c.Name, x.Total, o.OrderID, o.OrderDate
FROM (SELECT CustomerID, SUM(Amount) AS Total
      FROM dbo.Orders
      WHERE OrderDate >= '20250101' AND OrderDate < '20260101'
      GROUP BY CustomerID
      HAVING SUM(Amount) > 100000) x
JOIN dbo.Customers c ON c.CustomerID = x.CustomerID
JOIN dbo.Orders o    ON o.CustomerID = x.CustomerID
                    AND o.OrderDate >= '20250101' AND o.OrderDate < '20260101'
OPTION (MAXDOP 1);
GO

/* =====================================================================
   БЛОК 2. То же через временную таблицу: шаг 2 знает реальные 40 строк
   ===================================================================== */
SELECT CustomerID, SUM(Amount) AS Total
INTO #Big
FROM dbo.Orders
WHERE OrderDate >= '20250101' AND OrderDate < '20260101'
GROUP BY CustomerID
HAVING SUM(Amount) > 100000;

CREATE CLUSTERED INDEX CIX_Big ON #Big (CustomerID);      -- аналог ИНДЕКСИРОВАТЬ ПО

-- Estimated ≈ Actual = 40 на #Big; соединение с Orders — Nested Loops + Index Seek (40 выполнений)
SELECT c.Name, b.Total, o.OrderID, o.OrderDate
FROM #Big b
JOIN dbo.Customers c ON c.CustomerID = b.CustomerID
JOIN dbo.Orders o    ON o.CustomerID = b.CustomerID
                    AND o.OrderDate >= '20250101' AND o.OrderDate < '20260101'
OPTION (MAXDOP 1);
GO
-- Статистика у временной таблицы настоящая
DBCC SHOW_STATISTICS (N'tempdb..#Big', N'CIX_Big') WITH STAT_HEADER, HISTOGRAM;
GO
DROP TABLE #Big;
GO

/* =====================================================================
   БЛОК 3. Табличная переменная: материализация есть, статистики нет
   ===================================================================== */
-- До SQL Server 2019 (или с хинтом ниже) — оценка 1 строка; в 2019+ — 40 по числу строк,
-- но без гистограммы. Сравните план с блоком 2.
DECLARE @Big TABLE (CustomerID int PRIMARY KEY, Total decimal(18,2));
INSERT @Big
SELECT CustomerID, SUM(Amount)
FROM dbo.Orders
WHERE OrderDate >= '20250101' AND OrderDate < '20260101'
GROUP BY CustomerID
HAVING SUM(Amount) > 100000;

SELECT c.Name, b.Total, o.OrderID, o.OrderDate
FROM @Big b
JOIN dbo.Customers c ON c.CustomerID = b.CustomerID
JOIN dbo.Orders o    ON o.CustomerID = b.CustomerID
                    AND o.OrderDate >= '20250101' AND o.OrderDate < '20260101'
OPTION (MAXDOP 1, USE HINT('DISABLE_DEFERRED_COMPILATION_TV'));
GO

/* =====================================================================
   БЛОК 4. CTE, на который сослались дважды, вычисляется дважды
   ===================================================================== */
-- В плане — два независимых агрегата по Orders; logical reads по Orders удваиваются
WITH x AS
(
    SELECT CustomerID, SUM(Amount) AS Total
    FROM dbo.Orders
    WHERE OrderDate >= '20250101' AND OrderDate < '20260101'
    GROUP BY CustomerID
)
SELECT (SELECT COUNT(*) FROM x WHERE Total > 100000) AS big_customers,
       (SELECT AVG(Total) FROM x)                    AS avg_total
OPTION (MAXDOP 1);
GO

/* =====================================================================
   БЛОК 5. Когда вложенный запрос — нормально
   ===================================================================== */
-- IN по таблице с индексом -> semi join по статистике базовых таблиц, оценки точные,
-- временная таблица ничего не даст
SELECT o.OrderID, o.Amount
FROM dbo.Orders o
WHERE o.CustomerID IN (SELECT c.CustomerID FROM dbo.Customers c WHERE c.CustomerID BETWEEN 100 AND 120)
OPTION (MAXDOP 1);
GO

SET STATISTICS IO OFF;
GO
-- Уборка
-- USE master; ALTER DATABASE SubqueryDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE SubqueryDemo;

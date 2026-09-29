/* =====================================================================
   Seek Predicates и Predicate: навигация по индексу и остаточная проверка
   Вопросы 42, 44 методички. Тестовый экземпляр, SQL Server 2016 SP1+.
   Включите фактический план (Ctrl+M). У оператора чтения смотрите (F4):
     Seek Predicates (Prefix / Start / End), Predicate,
     Number of Rows Read и Actual Number of Rows.
   ===================================================================== */
USE master;
GO
IF DB_ID(N'PredicateDemo') IS NOT NULL
BEGIN
    ALTER DATABASE PredicateDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE PredicateDemo;
END;
GO
CREATE DATABASE PredicateDemo;
GO
USE PredicateDemo;
GO

/* ---------- 0. 200 клиентов × 1 000 заказов = 200 000 строк ---------- */
CREATE TABLE dbo.Orders
(
    OrderID    int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED,
    CustomerID int           NOT NULL,
    OrderDate  date          NOT NULL,
    Status     tinyint       NOT NULL,
    Amount     decimal(12,2) NOT NULL,
    Comment    nvarchar(100) NOT NULL
);
GO
;WITH n AS (SELECT TOP (200000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
            FROM sys.all_columns a CROSS JOIN sys.all_columns b)
INSERT dbo.Orders (CustomerID, OrderDate, Status, Amount, Comment)
SELECT n % 200 + 1,
       DATEADD(DAY, (n / 200) % 1000, '20240101'),       -- у каждого клиента ~1 000 дат с 2024-01-01
       (n / 7) % 30,                                     -- Status = 3 примерно у 1/30 заказов каждого клиента
       n % 1000,
       CASE WHEN n % 199 = 0 THEN N'срочно, позвонить' ELSE N'обычный заказ' END
FROM n;
GO
CREATE INDEX IX_Orders_Cust_Date ON dbo.Orders (CustomerID, OrderDate) INCLUDE (Status, Amount);
GO
SET STATISTICS IO ON;
GO

-- 1. Оба условия в Seek Predicates: Prefix CustomerID = 42, Start OrderDate >= …
--    Rows Read = Actual Rows
SELECT OrderID, Amount FROM dbo.Orders
WHERE CustomerID = 42 AND OrderDate >= '20260101';
GO
-- 2. Status только в INCLUDE -> Seek по CustomerID, Predicate: Status = 3
--    Rows Read ≈ 1 000, Actual — несколько десятков
SELECT OrderID, Amount FROM dbo.Orders
WHERE CustomerID = 42 AND Status = 3;
GO
-- 3. Нет условия на первый столбец -> Index Scan + Predicate, Rows Read = 200 000
SELECT OrderID, Amount FROM dbo.Orders
WHERE OrderDate >= '20260101';
GO
-- 4a. Функция над столбцом -> YEAR(...) в Predicate, Rows Read ≈ 1 000
SELECT OrderID, Amount FROM dbo.Orders
WHERE CustomerID = 42 AND YEAR(OrderDate) = 2026;
-- 4b. То же саргабельно -> оба условия в Seek Predicates, Rows Read = Actual
SELECT OrderID, Amount FROM dbo.Orders
WHERE CustomerID = 42 AND OrderDate >= '20260101' AND OrderDate < '20270101';
GO
-- 5. Диапазон по первому столбцу -> Start/End по CustomerID, OrderDate в Predicate
--    Rows Read ≈ 6 000 (6 клиентов × 1 000), Actual — единицы
SELECT OrderID, Amount FROM dbo.Orders
WHERE CustomerID BETWEEN 40 AND 45 AND OrderDate = '20260315';
GO
-- 6. Comment нет в индексе -> Index Seek + Key Lookup (Executions ≈ 1 000),
--    у Key Lookup Predicate: Comment LIKE …
SELECT OrderID, Amount FROM dbo.Orders
WHERE CustomerID = 42 AND Comment LIKE N'%срочно%';
GO
-- 7. Отдельный оператор Filter: условие по результату агрегата (HAVING)
SELECT CustomerID, COUNT(*) AS Cnt
FROM dbo.Orders
WHERE OrderDate >= '20260101'
GROUP BY CustomerID
HAVING COUNT(*) > 260;
GO
-- 8. Текстовый план: SEEK:(…) — навигация, WHERE:(…) — остаточная проверка
SET STATISTICS IO OFF;
GO
SET SHOWPLAN_TEXT ON;
GO
SELECT OrderID, Amount FROM dbo.Orders WHERE CustomerID = 42 AND Status = 3;
GO
SET SHOWPLAN_TEXT OFF;
GO
-- Уборка
-- USE master; ALTER DATABASE PredicateDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE PredicateDemo;

/* =====================================================================
   Nested Loops, Merge Join, Hash Match: когда оптимизатор выбирает каждый
   Вопрос 45 методички. Тестовый экземпляр, SQL Server 2016+.
   Выполнять ПО БЛОКАМ с фактическим планом (Ctrl+M), SET STATISTICS IO, TIME ON.
   Сравнивайте: оператор соединения, Estimated Subtree Cost на SELECT,
   logical reads по таблицам, CPU/elapsed time.
   MAXDOP 1 — чтобы сравнивать алгоритмы без влияния параллелизма.
   Ожидаемые планы описаны «как обычно бывает»: на вашем сервере выбор может отличаться.
   ===================================================================== */
USE master;
GO
IF DB_ID(N'JoinAlgoDemo') IS NOT NULL
BEGIN
    ALTER DATABASE JoinAlgoDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE JoinAlgoDemo;
END;
GO
CREATE DATABASE JoinAlgoDemo;
GO
USE JoinAlgoDemo;
GO

/* ---------- 0. Данные ---------- */
CREATE TABLE dbo.Customers
(
    CustomerID int           NOT NULL CONSTRAINT PK_Customers PRIMARY KEY CLUSTERED,
    Name       nvarchar(50)  NOT NULL,
    Region     nvarchar(30)  NOT NULL
);
CREATE TABLE dbo.Managers
(
    ManagerID   int          NOT NULL CONSTRAINT PK_Managers PRIMARY KEY CLUSTERED,
    ManagerCode varchar(10)  NOT NULL,          -- индекса по коду НЕТ
    ManagerName nvarchar(50) NOT NULL
);
CREATE TABLE dbo.Orders
(
    OrderID     int           NOT NULL CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED,
    CustomerID  int           NOT NULL,
    ManagerCode varchar(10)   NOT NULL,         -- индекса НЕТ
    OrderDate   date          NOT NULL,
    Amount      decimal(12,2) NOT NULL
);
CREATE TABLE dbo.Payments
(
    OrderID    int           NOT NULL,
    PaymentNo  tinyint       NOT NULL,
    PaidAmount decimal(12,2) NOT NULL,
    CONSTRAINT PK_Payments PRIMARY KEY CLUSTERED (OrderID, PaymentNo)   -- отсортирована по OrderID
);
GO
;WITH n AS (SELECT TOP (1000000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
            FROM sys.all_columns a CROSS JOIN sys.all_columns b)
SELECT n INTO #N FROM n;

INSERT dbo.Customers SELECT n, N'Клиент ' + CAST(n AS nvarchar(10)), N'Регион ' + CAST(n % 20 AS nvarchar(5))
FROM #N WHERE n <= 50000;
INSERT dbo.Managers  SELECT n, 'M' + CAST(n AS varchar(5)), N'Менеджер ' + CAST(n AS nvarchar(5))
FROM #N WHERE n <= 500;
INSERT dbo.Orders    SELECT n, (n * 7) % 50000 + 1, 'M' + CAST(n % 500 + 1 AS varchar(5)),
                            DATEADD(DAY, -(n % 1000), '20260101'), n % 1000
FROM #N;
INSERT dbo.Payments  SELECT n, 1, n % 1000 FROM #N;
DROP TABLE #N;
GO
CREATE INDEX IX_Orders_CustomerID ON dbo.Orders (CustomerID) INCLUDE (OrderDate, Amount);
UPDATE STATISTICS dbo.Customers WITH FULLSCAN;
UPDATE STATISTICS dbo.Managers  WITH FULLSCAN;
UPDATE STATISTICS dbo.Orders    WITH FULLSCAN;
UPDATE STATISTICS dbo.Payments  WITH FULLSCAN;
GO
SET STATISTICS IO, TIME ON;
GO

/* =====================================================================
   БЛОК 1. NESTED LOOPS: маленький верхний вход + индекс на нижнем
   ===================================================================== */
-- 1.1 Выбор оптимизатора: Nested Loops, сверху Clustered Index Seek по Customers (10 строк),
--     снизу Index Seek по IX_Orders_CustomerID (Number of Executions = 10). Чтения — десятки страниц.
SELECT c.Name, o.OrderID, o.Amount
FROM dbo.Customers c
JOIN dbo.Orders o ON o.CustomerID = c.CustomerID
WHERE c.CustomerID BETWEEN 1 AND 10
OPTION (MAXDOP 1);
GO
-- 1.2 Навязанные альтернативы: Hash и Merge читают/сортируют намного больше
SELECT c.Name, o.OrderID, o.Amount
FROM dbo.Customers c JOIN dbo.Orders o ON o.CustomerID = c.CustomerID
WHERE c.CustomerID BETWEEN 1 AND 10
OPTION (MAXDOP 1, HASH JOIN);
SELECT c.Name, o.OrderID, o.Amount
FROM dbo.Customers c JOIN dbo.Orders o ON o.CustomerID = c.CustomerID
WHERE c.CustomerID BETWEEN 1 AND 10
OPTION (MAXDOP 1, MERGE JOIN);
GO

/* =====================================================================
   БЛОК 2. MERGE JOIN: оба входа уже отсортированы по ключу соединения
   ===================================================================== */
-- 2.1 Выбор оптимизатора: Merge Join без Sort. Оба Clustered Index Scan с Ordered = True.
--     Каждая таблица прочитана один раз. Результат уже отсортирован по OrderID.
SELECT o.OrderID, o.Amount, p.PaidAmount
FROM dbo.Orders o
JOIN dbo.Payments p ON p.OrderID = o.OrderID
OPTION (MAXDOP 1);
GO
-- 2.2 Альтернативы: Hash строит хеш-таблицу на миллион строк (грант памяти),
--     Nested Loops делает миллион поисков
SELECT o.OrderID, o.Amount, p.PaidAmount
FROM dbo.Orders o JOIN dbo.Payments p ON p.OrderID = o.OrderID
OPTION (MAXDOP 1, HASH JOIN);
SELECT o.OrderID, o.Amount, p.PaidAmount
FROM dbo.Orders o JOIN dbo.Payments p ON p.OrderID = o.OrderID
OPTION (MAXDOP 1, LOOP JOIN);
GO
-- 2.3 Порядок бесплатный: ORDER BY по ключу соединения не добавляет Sort после Merge
SELECT TOP (100) o.OrderID, o.Amount, p.PaidAmount
FROM dbo.Orders o JOIN dbo.Payments p ON p.OrderID = o.OrderID
ORDER BY o.OrderID
OPTION (MAXDOP 1, MERGE JOIN);
GO

/* =====================================================================
   БЛОК 3. HASH MATCH: большой неотсортированный вход, индексов нет
   ===================================================================== */
-- 3.1 Выбор оптимизатора: Hash Match, build = Managers (500 строк), probe = Orders (1 000 000).
--     У SELECT смотрите MemoryGrantInfo: грант небольшой — хеш-таблица на 500 строк.
SELECT m.ManagerName, SUM(o.Amount) AS Total
FROM dbo.Orders o
JOIN dbo.Managers m ON m.ManagerCode = o.ManagerCode
GROUP BY m.ManagerName
OPTION (MAXDOP 1);
GO
-- 3.2 Альтернативы: Merge — два Sort (в том числе миллиона строк), Nested Loops —
--     для каждого заказа скан Managers или Table Spool
SELECT m.ManagerName, SUM(o.Amount) AS Total
FROM dbo.Orders o JOIN dbo.Managers m ON m.ManagerCode = o.ManagerCode
GROUP BY m.ManagerName
OPTION (MAXDOP 1, MERGE JOIN);
SELECT m.ManagerName, SUM(o.Amount) AS Total
FROM dbo.Orders o JOIN dbo.Managers m ON m.ManagerCode = o.ManagerCode
GROUP BY m.ManagerName
OPTION (MAXDOP 1, LOOP JOIN);
GO

/* =====================================================================
   БЛОК 4. Как меняется выбор при изменении условий
   ===================================================================== */
-- 4.1 Nested Loops -> Hash: верхний вход вырос с 10 до 20 000 клиентов
SELECT c.Name, o.OrderID, o.Amount
FROM dbo.Customers c JOIN dbo.Orders o ON o.CustomerID = c.CustomerID
WHERE c.CustomerID BETWEEN 1 AND 20000
OPTION (MAXDOP 1);
GO
-- 4.2 Hash -> Nested Loops: появился индекс по коду менеджера и отбор по одному менеджеру
CREATE INDEX IX_Orders_ManagerCode ON dbo.Orders (ManagerCode) INCLUDE (Amount);
GO
SELECT m.ManagerName, SUM(o.Amount) AS Total
FROM dbo.Orders o JOIN dbo.Managers m ON m.ManagerCode = o.ManagerCode
WHERE m.ManagerID = 7
GROUP BY m.ManagerName
OPTION (MAXDOP 1);
GO

SET STATISTICS IO, TIME OFF;
GO
-- Уборка
-- USE master; ALTER DATABASE JoinAlgoDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE JoinAlgoDemo;

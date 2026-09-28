/* =====================================================================
   Неэффективный JOIN: симптомы в плане и их лечение
   Вопрос 47а методички (а также 45–51, 55а). Тестовый экземпляр, SQL Server 2016+.
   Выполнять ПО БЛОКАМ с фактическим планом (Ctrl+M) и SET STATISTICS IO ON.
   Смотреть: алгоритм соединения, Number of Executions нижнего входа,
   Estimated vs Actual, предупреждения, Scan count / logical reads по таблицам.
   Планы описаны «как обычно бывает» — на вашем сервере выбор может отличаться.
   ===================================================================== */
USE master;
GO
IF DB_ID(N'JoinDemo') IS NOT NULL
BEGIN
    ALTER DATABASE JoinDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE JoinDemo;
END;
GO
CREATE DATABASE JoinDemo;
GO
USE JoinDemo;
GO

/* ---------- 0. Данные: 10 000 клиентов, 300 000 заказов ---------- */
CREATE TABLE dbo.Customers
(
    CustomerID int           NOT NULL CONSTRAINT PK_Customers PRIMARY KEY CLUSTERED,
    Code       nvarchar(20)  NOT NULL,          -- nvarchar ...
    Name       nvarchar(100) NOT NULL,
    Region     nvarchar(30)  NOT NULL
);
CREATE TABLE dbo.Orders
(
    OrderID      int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED,
    CustomerID   int           NOT NULL,
    CustomerCode varchar(20)   NOT NULL,        -- ... а здесь varchar: ловушка для блока 4
    PayerID      int           NOT NULL,        -- второй «клиент» заказа: для OR в блоке 8
    OrderDate    date          NOT NULL,
    Amount       decimal(12,2) NOT NULL,
    Note         char(200)     NOT NULL         -- балласт: Key Lookup и Hash дороги
);
GO
;WITH n AS (SELECT TOP (10000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
            FROM sys.all_columns a CROSS JOIN sys.all_columns b)
INSERT dbo.Customers (CustomerID, Code, Name, Region)
SELECT n, N'C' + RIGHT(N'00000' + CAST(n AS nvarchar(10)), 5), N'Клиент ' + CAST(n AS nvarchar(10)),
       CASE n % 5 WHEN 0 THEN N'Москва' WHEN 1 THEN N'Казань' WHEN 2 THEN N'Пермь'
                  WHEN 3 THEN N'Томск' ELSE N'Омск' END
FROM n;

;WITH n AS (SELECT TOP (300000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
            FROM sys.all_columns a CROSS JOIN sys.all_columns b)
INSERT dbo.Orders (CustomerID, CustomerCode, PayerID, OrderDate, Amount, Note)
SELECT n % 10000 + 1,
       'C' + RIGHT('00000' + CAST(n % 10000 + 1 AS varchar(10)), 5),
       (n * 7) % 10000 + 1,
       DATEADD(DAY, -(n % 730), '20260101'),
       n % 1000,
       'x'
FROM n;
GO
UPDATE STATISTICS dbo.Customers WITH FULLSCAN;
UPDATE STATISTICS dbo.Orders    WITH FULLSCAN;
GO
SET STATISTICS IO ON;
GO

/* =====================================================================
   БЛОК 1. Нет индекса по столбцу соединения на внутренней таблице
   ===================================================================== */
-- 1.1 Обычно: Hash Match + полный Clustered Index Scan по Orders ради 150 строк
SELECT c.Name, o.OrderDate, o.Amount
FROM dbo.Customers c
JOIN dbo.Orders o ON o.CustomerID = c.CustomerID
WHERE c.CustomerID BETWEEN 1 AND 5;
GO
-- 1.2 Эксперимент: заставим Nested Loops -> на нижнем входе скан или Index Spool
--     (оптимизатор сам строит временный индекс — сигнал «не хватает индекса»)
SELECT c.Name, o.OrderDate, o.Amount
FROM dbo.Customers c
JOIN dbo.Orders o ON o.CustomerID = c.CustomerID
WHERE c.CustomerID BETWEEN 1 AND 5
OPTION (LOOP JOIN);
GO

/* =====================================================================
   БЛОК 2. Индекс по столбцу соединения: Seek + Key Lookup, затем покрытие
   ===================================================================== */
CREATE INDEX IX_Orders_CustomerID ON dbo.Orders (CustomerID);
GO
-- 2.1 Nested Loops: Index Seek по Orders (5 выполнений) + Key Lookup на каждую строку
SELECT c.Name, o.OrderDate, o.Amount
FROM dbo.Customers c
JOIN dbo.Orders o ON o.CustomerID = c.CustomerID
WHERE c.CustomerID BETWEEN 1 AND 5;
GO
-- 2.2 Покрывающий индекс: Key Lookup исчез
CREATE INDEX IX_Orders_CustomerID ON dbo.Orders (CustomerID)
INCLUDE (OrderDate, Amount) WITH (DROP_EXISTING = ON);
GO
SELECT c.Name, o.OrderDate, o.Amount
FROM dbo.Customers c
JOIN dbo.Orders o ON o.CustomerID = c.CustomerID
WHERE c.CustomerID BETWEEN 1 AND 5;
GO

/* =====================================================================
   БЛОК 3. Недооценка верхнего входа -> Nested Loops на тысячи итераций
   ===================================================================== */
-- 3.1 Табличная переменная со старым поведением: оценка 1 строка, фактически 3 000.
--     Note не в индексе -> Key Lookup ~90 000 раз (Number of Executions).
DECLARE @t TABLE (CustomerID int PRIMARY KEY);
INSERT @t SELECT CustomerID FROM dbo.Customers WHERE CustomerID <= 3000;
SELECT o.OrderID, o.Note
FROM @t t
JOIN dbo.Orders o ON o.CustomerID = t.CustomerID
OPTION (USE HINT('DISABLE_DEFERRED_COMPILATION_TV'));
GO
-- 3.2 Временная таблица со статистикой: оценка верная -> обычно Hash Match + скан
CREATE TABLE #t (CustomerID int PRIMARY KEY);
INSERT #t SELECT CustomerID FROM dbo.Customers WHERE CustomerID <= 3000;
SELECT o.OrderID, o.Note
FROM #t t
JOIN dbo.Orders o ON o.CustomerID = t.CustomerID;
DROP TABLE #t;
GO

/* =====================================================================
   БЛОК 4. Неявное преобразование на столбце соединения
   ===================================================================== */
CREATE INDEX IX_Orders_CustomerCode ON dbo.Orders (CustomerCode);
GO
-- 4.1 varchar = nvarchar: CONVERT_IMPLICIT на o.CustomerCode, предупреждение PlanAffectingConvert
--     (в зависимости от сортировки — скан или «динамический» seek с худшей оценкой)
SELECT c.Name, o.OrderID
FROM dbo.Customers c
JOIN dbo.Orders o ON o.CustomerCode = c.Code
WHERE c.CustomerID BETWEEN 1 AND 5;
GO
-- 4.2 Привели МЕНЬШУЮ сторону к типу столбца индекса -> обычный Index Seek
SELECT c.Name, o.OrderID
FROM dbo.Customers c
JOIN dbo.Orders o ON o.CustomerCode = CAST(c.Code AS varchar(20))
WHERE c.CustomerID BETWEEN 1 AND 5;
GO

/* =====================================================================
   БЛОК 5. Hash Match со spill в tempdb
   ===================================================================== */
-- Широкий build-вход (Note) и искусственно урезанная память -> Hash Warning / spill
SELECT o1.OrderID, o1.Note, o2.Amount
FROM dbo.Orders o1
INNER HASH JOIN dbo.Orders o2 ON o2.OrderID = o1.OrderID
OPTION (MAX_GRANT_PERCENT = 0);
GO

/* =====================================================================
   БЛОК 6. Sort перед Merge Join
   ===================================================================== */
-- PayerID не проиндексирован: чтобы соединить слиянием, нужно отсортировать 300 000 строк
SELECT c.Name, o.OrderID
FROM dbo.Customers c
INNER MERGE JOIN dbo.Orders o ON o.PayerID = c.CustomerID;
GO
-- Для сравнения — выбор оптимизатора без хинта (обычно Hash Match, без Sort)
SELECT c.Name, o.OrderID
FROM dbo.Customers c
JOIN dbo.Orders o ON o.PayerID = c.CustomerID;
GO

/* =====================================================================
   БЛОК 7. «Размножение» строк: соединение по неуникальному столбцу
   ===================================================================== */
-- На входах по 90 строк, на выходе 2 700: каждый заказ клиента × каждый заказ того же клиента.
-- Часто это ошибка условия (не тот столбец, неполный ключ), замаскированная DISTINCT.
SELECT o1.OrderID, o2.OrderID
FROM dbo.Orders o1
JOIN dbo.Orders o2 ON o2.CustomerID = o1.CustomerID
WHERE o1.CustomerID <= 3;
GO

/* =====================================================================
   БЛОК 8. OR в условии соединения -> только Nested Loops, N × M
   ===================================================================== */
-- 8.1 20 клиентов × 300 000 заказов проверок условия
SELECT c.CustomerID, o.OrderID
FROM dbo.Customers c
JOIN dbo.Orders o ON o.CustomerID = c.CustomerID OR o.PayerID = c.CustomerID
WHERE c.CustomerID <= 20;
GO
-- 8.2 Переписали через UNION: две части с равенством (UNION убирает дубли пересечения)
CREATE INDEX IX_Orders_PayerID ON dbo.Orders (PayerID);
GO
SELECT c.CustomerID, o.OrderID
FROM dbo.Customers c JOIN dbo.Orders o ON o.CustomerID = c.CustomerID
WHERE c.CustomerID <= 20
UNION
SELECT c.CustomerID, o.OrderID
FROM dbo.Customers c JOIN dbo.Orders o ON o.PayerID = c.CustomerID
WHERE c.CustomerID <= 20;
GO

SET STATISTICS IO OFF;
GO
-- Уборка
-- USE master; ALTER DATABASE JoinDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE JoinDemo;

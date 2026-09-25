/* =====================================================================
   #временная таблица против @табличной переменной: оценки оптимизатора
   Вопрос 38 методички. Нужна база StatsDemo (02_statistics_demo.sql).
   Включите фактический план и сравните Estimated / Actual Rows.
   ===================================================================== */
USE StatsDemo;
GO
SET STATISTICS IO ON;
GO
-- 1. Табличная переменная: статистики нет.
--    До SQL Server 2019 (или при уровне совместимости < 150) оценка = 1 строка.
--    С 2019 (deferred compilation) — реальное число строк, но без гистограммы.
DECLARE @t TABLE (CustomerID int PRIMARY KEY);
INSERT @t SELECT DISTINCT CustomerID FROM dbo.Orders WHERE CustomerID <= 3000;

SELECT o.OrderID, o.Amount
FROM @t t JOIN dbo.Orders o ON o.CustomerID = t.CustomerID;

-- Старое поведение для сравнения:
SELECT o.OrderID, o.Amount
FROM @t t JOIN dbo.Orders o ON o.CustomerID = t.CustomerID
OPTION (USE HINT('DISABLE_DEFERRED_COMPILATION_TV'));
GO
-- 2. Временная таблица: есть статистика, оценка точная, выбор соединения адекватный
CREATE TABLE #t (CustomerID int PRIMARY KEY);
INSERT #t SELECT DISTINCT CustomerID FROM dbo.Orders WHERE CustomerID <= 3000;

SELECT o.OrderID, o.Amount
FROM #t t JOIN dbo.Orders o ON o.CustomerID = t.CustomerID;

DROP TABLE #t;
GO
-- 3. С SQL Server 2014 у табличной переменной можно объявить и обычный индекс inline:
DECLARE @t2 TABLE (CustomerID int NOT NULL, Amount decimal(12,2), INDEX IX_c (CustomerID));
GO
SET STATISTICS IO OFF;

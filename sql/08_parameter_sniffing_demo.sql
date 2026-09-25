/* =====================================================================
   Parameter sniffing: воспроизведение, диагностика, способы лечения
   Вопросы 56–58 методички. Нужна база StatsDemo из 02_statistics_demo.sql
   (клиент 1 — ~10% заказов, остальные — по ~20).
   Включите фактический план (Ctrl+M) и SET STATISTICS IO ON.
   ===================================================================== */
USE StatsDemo;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Orders_CustomerID')
    CREATE INDEX IX_Orders_CustomerID ON dbo.Orders (CustomerID);   -- НЕ покрывающий
GO
CREATE OR ALTER PROCEDURE dbo.GetOrders @CustomerID int
AS
    SELECT OrderID, OrderDate, Amount, Region
    FROM dbo.Orders
    WHERE CustomerID = @CustomerID;
GO
SET STATISTICS IO ON;
GO

/* ---------- 1. Первым пришёл мелкий клиент: в кэше Seek + Key Lookup ---------- */
EXEC sp_recompile N'dbo.GetOrders';
EXEC dbo.GetOrders @CustomerID = 42;   -- мало строк, план хороший
EXEC dbo.GetOrders @CustomerID = 1;    -- ~10 000 Key Lookup по чужому плану
-- В плане: SELECT -> Properties -> Parameter List:
--   Parameter Compiled Value = 42, Parameter Runtime Value = 1
--   Estimated Rows ≈ 20, Actual Rows ≈ 10 000
GO

/* ---------- 2. Первым пришёл крупный клиент: в кэше Clustered Index Scan ---------- */
EXEC sp_recompile N'dbo.GetOrders';
EXEC dbo.GetOrders @CustomerID = 1;
EXEC dbo.GetOrders @CustomerID = 42;   -- каждый мелкий вызов сканирует всю таблицу
GO

/* ---------- 3. Кто в кэше и под какое значение скомпилирован ---------- */
SELECT qs.execution_count, qs.min_logical_reads, qs.max_logical_reads,
       qp.query_plan   -- в XML: ParameterCompiledValue
FROM sys.dm_exec_procedure_stats ps
JOIN sys.dm_exec_query_stats qs ON qs.plan_handle = ps.plan_handle
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) qp
WHERE ps.object_id = OBJECT_ID(N'dbo.GetOrders');
GO

/* ---------- 4. Варианты лечения (по одному, сравнивайте чтения) ---------- */
-- 4.1 RECOMPILE: план под каждое значение, плата — компиляция при каждом вызове
CREATE OR ALTER PROCEDURE dbo.GetOrders @CustomerID int AS
    SELECT OrderID, OrderDate, Amount, Region FROM dbo.Orders
    WHERE CustomerID = @CustomerID OPTION (RECOMPILE);
GO
EXEC dbo.GetOrders 42; EXEC dbo.GetOrders 1;
GO
-- 4.2 OPTIMIZE FOR UNKNOWN: оценка по плотности (Rows × density), план «под среднего»
CREATE OR ALTER PROCEDURE dbo.GetOrders @CustomerID int AS
    SELECT OrderID, OrderDate, Amount, Region FROM dbo.Orders
    WHERE CustomerID = @CustomerID OPTION (OPTIMIZE FOR UNKNOWN);
GO
EXEC dbo.GetOrders 42; EXEC dbo.GetOrders 1;
GO
-- 4.3 Разделение на РАЗНЫЕ процедуры (IF внутри одной процедуры не помогает!)
CREATE OR ALTER PROCEDURE dbo.GetOrders_Small @CustomerID int AS
    SELECT OrderID, OrderDate, Amount, Region FROM dbo.Orders WHERE CustomerID = @CustomerID;
GO
CREATE OR ALTER PROCEDURE dbo.GetOrders_Big @CustomerID int AS
    SELECT OrderID, OrderDate, Amount, Region FROM dbo.Orders WHERE CustomerID = @CustomerID;
GO
CREATE OR ALTER PROCEDURE dbo.GetOrders @CustomerID int AS
    IF @CustomerID = 1       -- в жизни: таблица «крупных» клиентов
        EXEC dbo.GetOrders_Big @CustomerID;
    ELSE
        EXEC dbo.GetOrders_Small @CustomerID;
GO
EXEC dbo.GetOrders 42; EXEC dbo.GetOrders 1;
GO
-- 4.4 Убрать развилку: покрывающий индекс — один план хорош для всех
CREATE OR ALTER PROCEDURE dbo.GetOrders @CustomerID int AS
    SELECT OrderID, OrderDate, Amount, Region FROM dbo.Orders WHERE CustomerID = @CustomerID;
GO
CREATE INDEX IX_Orders_CustomerID ON dbo.Orders (CustomerID)
    INCLUDE (OrderDate, Amount, Region) WITH (DROP_EXISTING = ON);
GO
EXEC sp_recompile N'dbo.GetOrders';
EXEC dbo.GetOrders 42; EXEC dbo.GetOrders 1;   -- оба: только Index Seek
GO
SET STATISTICS IO OFF;
GO

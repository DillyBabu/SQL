Go
-- Add columns to the clients table
IF NOT EXISTS (SELECT * FROM sys.columns WHERE object_id = OBJECT_ID('clients') AND COLUMN_NAME = 'email')
BEGIN
    ALTER TABLE [dbo].[clients]
    ADD email VARCHAR(255);
END
GO

-- Add foreign key constraint to the clients table
IF NOT EXISTS (SELECT * FROM sys.foreign_keys WHERE object_id = OBJECT_ID('FK_clients_orders'))
BEGIN
    ALTER TABLE [dbo].[clients]
    ADD CONSTRAINT FK_clients_orders FOREIGN KEY (client_id) REFERENCES orders(client_id);
    FOREIGN KEY (client_id) REFERENCES orders(client_id);
END
GO

--Add check constraint to the clients table
IF NOT EXISTS (SELECT * FROM sys.check_constraints WHERE object_id = OBJECT_ID('CK_clients_email'))
BEGIN
    ALTER TABLE [dbo].[clients]
    ADD CONSTRAINT CK_clients_email CHECK (email LIKE '%@%.%');
END
GO
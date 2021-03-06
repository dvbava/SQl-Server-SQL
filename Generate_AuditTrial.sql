
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO

ALTER PROCEDURE [dbo].[GenerateAuditTrail]
    @TableName varchar(128),
    @Owner varchar(128) = 'dbo',
    @AuditOwner varchar(128) = 'audit',
    @AuditNameExtension varchar(128) = 'Change'
AS
BEGIN

    DECLARE @sourceTable nvarchar(128)
    DECLARE @auditTable nvarchar(128)

    PRINT 'Attempting to generate auditing for ' + @TableName

    SET @TableName = REPLACE(REPLACE(@TableName, '[' + @Owner + '].[', ''), ']', '')

    PRINT 'TableName renamed to: ' + @TableName

    SET @sourceTable = N'[' + @Owner + '].[' + @TableName + ']'
    SET @auditTable = N'[' + @AuditOwner + '].[' + @TableName + @AuditNameExtension + ']'

    -- Check if table exists
    IF not exists (SELECT * FROM dbo.sysobjects WHERE id = object_id(@sourceTable) and OBJECTPROPERTY(id, N'IsUserTable') = 1)
    BEGIN
        PRINT 'ERROR: Table ' + @sourceTable + ' does not exist'
        RETURN
    END

    -- Check @AuditNameExtension
    IF @AuditNameExtension is null
    BEGIN
        PRINT 'ERROR: @AuditNameExtension cannot be null'
        RETURN
    END

    -- Declare cursor to loop over columns
    DECLARE TableColumns CURSOR Read_Only
    FOR SELECT b.name, c.name as TypeName, b.length, b.isnullable, b.collation, b.xprec, b.xscale
        FROM sysobjects a 
        inner join syscolumns b on a.id = b.id 
        inner join systypes c on b.xtype = c.xtype and c.name <> 'sysname' 
        WHERE a.id = object_id(@sourceTable) 
        and OBJECTPROPERTY(a.id, N'IsUserTable') = 1 
        ORDER BY b.colId

    OPEN TableColumns

    -- Declare temp variable to fetch records into
    DECLARE @ColumnName varchar(128)
    DECLARE @ColumnType varchar(128)
    DECLARE @ColumnLength smallint
    DECLARE @ColumnNullable int
    DECLARE @ColumnCollation sysname
    DECLARE @ColumnPrecision tinyint
    DECLARE @ColumnScale tinyint

    -- Declare variable to build statements
    DECLARE @CreateStatement varchar(8000)
    DECLARE @ListOfFields varchar(2000)
    SET @ListOfFields = ''


    -- Check if audit table exists
    IF exists (SELECT * FROM dbo.sysobjects WHERE id = object_id(@auditTable) and OBJECTPROPERTY(id, N'IsUserTable') = 1)
    BEGIN
        -- AuditTable exists, update needed
        PRINT 'Table already exists. Only triggers will be updated.'

        FETCH Next FROM TableColumns
        INTO @ColumnName, @ColumnType, @ColumnLength, @ColumnNullable, @ColumnCollation, @ColumnPrecision, @ColumnScale
        
        WHILE @@FETCH_STATUS = 0
        BEGIN
            IF (@ColumnType <> 'text' and @ColumnType <> 'ntext' and @ColumnType <> 'image' and @ColumnType <> 'timestamp')
            BEGIN
                SET @ListOfFields = @ListOfFields + @ColumnName + ','
            END

            FETCH Next FROM TableColumns
            INTO @ColumnName, @ColumnType, @ColumnLength, @ColumnNullable, @ColumnCollation, @ColumnPrecision, @ColumnScale

        END
    END
    ELSE
    BEGIN
        -- AuditTable does not exist, create new

        -- Start of create table
        SET @CreateStatement = 'CREATE TABLE ' + @auditTable + ' ('
        SET @CreateStatement = @CreateStatement + '[AuditId] [bigint] IDENTITY (1, 1) NOT NULL,'

        FETCH Next FROM TableColumns
        INTO @ColumnName, @ColumnType, @ColumnLength, @ColumnNullable, @ColumnCollation, @ColumnPrecision, @ColumnScale
        
        WHILE @@FETCH_STATUS = 0
        BEGIN
            IF (@ColumnType <> 'text' and @ColumnType <> 'ntext' and @ColumnType <> 'image' and @ColumnType <> 'timestamp')
            BEGIN
                SET @ListOfFields = @ListOfFields + @ColumnName + ','
        
                SET @CreateStatement = @CreateStatement + '[' + @ColumnName + '] [' + @ColumnType + '] '
                
                IF @ColumnType in ('binary', 'char', 'nchar', 'nvarchar', 'varbinary', 'varchar')
                BEGIN
                    IF (@ColumnLength = -1)
                        Set @CreateStatement = @CreateStatement + '(max) '	 	
                    ELSE
                        SET @CreateStatement = @CreateStatement + '(' + cast(@ColumnLength as varchar(10)) + ') '	 	
                END
        
                IF @ColumnType in ('decimal', 'numeric')
                    SET @CreateStatement = @CreateStatement + '(' + cast(@ColumnPrecision as varchar(10)) + ',' + cast(@ColumnScale as varchar(10)) + ') '	 	
        
                IF @ColumnType in ('char', 'nchar', 'nvarchar', 'varchar', 'text', 'ntext')
                    SET @CreateStatement = @CreateStatement + 'COLLATE ' + @ColumnCollation + ' '
        
                IF @ColumnNullable = 0
                    SET @CreateStatement = @CreateStatement + 'NOT '	 	
        
                SET @CreateStatement = @CreateStatement + 'NULL, '	 	
            END

            FETCH Next FROM TableColumns
            INTO @ColumnName, @ColumnType, @ColumnLength, @ColumnNullable, @ColumnCollation, @ColumnPrecision, @ColumnScale
        END
        
        -- Add audit trail columns
        SET @CreateStatement = @CreateStatement + '[AuditAction] [char] (1) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL ,'
        SET @CreateStatement = @CreateStatement + '[AuditDate] [datetime] NOT NULL ,'
        SET @CreateStatement = @CreateStatement + '[AuditUser] [varchar] (50) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,'
        SET @CreateStatement = @CreateStatement + '[AuditApp] [varchar](128) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,'
        SET @CreateStatement = @CreateStatement + '[AuditCommentId] [int] NULL)' 

        -- Create audit table
        PRINT 'Creating audit table ' + @auditTable
        EXEC (@CreateStatement)

        -- Set primary key and default values
        SET @CreateStatement = 'ALTER TABLE ' + @auditTable + ' ADD '
        SET @CreateStatement = @CreateStatement + 'CONSTRAINT [DF_' + @TableName + @AuditNameExtension + '_AuditDate] DEFAULT (getdate()) FOR [AuditDate],'
        SET @CreateStatement = @CreateStatement + 'CONSTRAINT [DF_' + @TableName + @AuditNameExtension + '_AuditUser] DEFAULT (PARSENAME(REPLACE(dbo.AuditGetContext(), ''|'', ''.''), 2)) FOR [AuditUser],CONSTRAINT [PK_' + @TableName + @AuditNameExtension + '] PRIMARY KEY  CLUSTERED'
        SET @CreateStatement = @CreateStatement + '([AuditId])  ON [PRIMARY], '
        SET @CreateStatement = @CreateStatement + 'CONSTRAINT [DF_' + @TableName + @AuditNameExtension + '_AuditCommentId] DEFAULT (Cast(PARSENAME(REPLACE(dbo.AuditGetContext(), ''|'', ''.''), 1) as int)) FOR [AuditCommentId],'
        SET @CreateStatement = @CreateStatement + 'CONSTRAINT [DF_' + @TableName + @AuditNameExtension + '_AuditApp]  DEFAULT (''App=('' + rtrim(isnull(app_name(),'''')) + '') '') for [AuditApp]'

        EXEC (@CreateStatement)

    END

    CLOSE TableColumns
    DEALLOCATE TableColumns

    PRINT 'Dropping triggers'
    IF exists (SELECT * FROM dbo.sysobjects WHERE id = object_id(N'[' + @Owner + '].[audit_' + @TableName + '_Insert]') and OBJECTPROPERTY(id, N'IsTrigger') = 1) 
        EXEC ('drop trigger [' + @Owner + '].[audit_' + @TableName + '_Insert]')

    IF exists (SELECT * FROM dbo.sysobjects WHERE id = object_id(N'[' + @Owner + '].[audit_' + @TableName + '_Update]') and OBJECTPROPERTY(id, N'IsTrigger') = 1) 
        EXEC ('drop trigger [' + @Owner + '].[audit_' + @TableName + '_Update]')

    IF exists (SELECT * FROM dbo.sysobjects WHERE id = object_id(N'[' + @Owner + '].[audit_' + @TableName + '_Delete]') and OBJECTPROPERTY(id, N'IsTrigger') = 1) 
        EXEC ('drop trigger [' + @Owner + '].[audit_' + @TableName + '_Delete]')

    PRINT 'Creating triggers' 
    EXEC ('CREATE TRIGGER audit_' + @TableName + '_Insert ON ' + @sourceTable + ' FOR INSERT AS INSERT INTO ' + @auditTable + '(' +  @ListOfFields + 'AuditAction) SELECT ' + @ListOfFields + '''I'' FROM Inserted')

    EXEC ('CREATE TRIGGER audit_' + @TableName + '_Update ON ' + @sourceTable + ' FOR UPDATE AS INSERT INTO ' + @auditTable + '(' +  @ListOfFields + 'AuditAction) SELECT ' + @ListOfFields + '''U'' FROM Inserted')

    EXEC ('CREATE TRIGGER audit_' + @TableName + '_Delete ON ' + @sourceTable + ' FOR DELETE AS INSERT INTO ' + @auditTable + '(' +  @ListOfFields + 'AuditAction) SELECT ' + @ListOfFields + '''D'' FROM Deleted')

END

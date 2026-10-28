IF OBJECT_ID('dbo.Sentimentos', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Sentimentos (
        Id UNIQUEIDENTIFIER NOT NULL PRIMARY KEY,
        Comentario NVARCHAR(MAX) NOT NULL,
        Sentimento VARCHAR(8) NOT NULL CHECK (Sentimento IN ('positive','neutral','negative')),
        SentimentoOriginal VARCHAR(8) NOT NULL,
        ColetadoEm DATETIME2 NOT NULL,
        RegistradoEm DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX IX_Sentimentos_Sentimento ON dbo.Sentimentos (Sentimento);
END;

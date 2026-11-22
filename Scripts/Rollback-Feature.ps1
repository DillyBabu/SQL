param(
    [parameter(Mandatory = $true)]
    [string]$ChecklistPath,

    [parameter(Mandatory = $true)]
    [string]$ConfigFilePath,

    [parameter(Mandatory = $true)]
    [string]$Environment,

    [parameter(Mandatory = $true)]
    [string]$ReleaseVersion,

    # Comma-separated list of feature names to roll back.
    # Example: "Config,DataMigration"
    [parameter(Mandatory = $true)]
    [string]$FeatureFilter,

    [parameter(Mandatory = $false)]
    [string]$ApplicationFilter = 'all',

    [parameter(Mandatory = $false)]
    [string]$ArtifactsDirectory = "$(Join-Path $PWD 'artifacts')",

    # Comma-separated list of Client_Name values to exclude from rollback.
    [parameter(Mandatory = $false)]
    [string]$ExcludedClients = '',

    [parameter(Mandatory = $false)]
    [string]$DryRun = 'true'
)

$VarDryRun = [System.Convert]::ToBoolean($DryRun)

# Import required modules
Add-Type -AssemblyName System.Data

# Global tracking
$Global:RollbackResults = @()
$Global:ExecutionStartTime = Get-Date

function Write-StageHeader {
    param([string]$Message)
    Write-Host ""
    Write-Host $Message -ForegroundColor Cyan
    Write-Host ('=' * ($Message.Length + 3)) -ForegroundColor Cyan
}

function Write-RollbackStatus {
    param(
        [string]$Message,
        [string]$Status = "Info"
    )
    switch ($Status) {
        "Success"  { Write-Host "[+] $Message" -ForegroundColor Green }
        "Failed"   { Write-Host "[-] $Message" -ForegroundColor Red }
        "Warning"  { Write-Host "[!] $Message" -ForegroundColor Yellow }
        "Info"     { Write-Host "[*] $Message" }
        "Rollback" { Write-Host "[R] $Message" -ForegroundColor Magenta }
    }
}

function Undo-SqlTransaction {
    param([System.Data.SqlClient.SqlTransaction]$Transaction)

    if ($null -eq $Transaction.Connection) {
        Write-Host "##[warning]The transaction was already ended by SQL Server. Verify the database state manually."
        return "EndedByServer"
    }

    try {
        $Transaction.Rollback()
        return "RolledBack"
    }
    catch {
        Write-Host "##[error]Transaction rollback failed: $($_.Exception.Message)"
        return "RollbackFailed"
    }
}

function Invoke-SQLScript {
    param(
        [string]$ScriptPath,
        [string]$ConnectionString,
        [string]$DatabaseName,
        [int]$TimeoutSeconds = 0
    )

    $result = @{
        Success           = $false
        ExecutionTime     = 0
        RowsAffected      = 0
        BatchesExecuted   = 0
        TotalBatches      = 0
        FailedBatch       = $null
        ErrorMessage      = $null
        Output            = $null
        ActualServer      = $null
        ActualDatabase    = $null
        TransactionStatus = "NotStarted"
        StartTime         = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        EndTime           = $null
    }

    $connection = $null
    $transaction = $null
    $stopWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $scriptName = Split-Path -Path $ScriptPath -Leaf
    $batchFailed = $false

    try {
        if (-Not (Test-Path -Path $ScriptPath)) {
            throw "Rollback script file not found: $ScriptPath"
        }

        $ScriptContent = Get-Content -Path $ScriptPath -Raw

        if ([string]::IsNullOrWhiteSpace($ScriptContent)) {
            throw "Rollback script file is empty: $ScriptPath"
        }

        if ($ConnectionString -notmatch "(?i)(database|initial\s+catalog)") {
            throw "Connection string does not specify a database. Aborting for safety."
        }

        $ScriptContent = $ScriptContent.TrimStart([char]0xFEFF)

        $useTransaction = $ScriptContent -notmatch '(?im)^\s*--\s*@NoTransaction\b'

        # Split into batches on GO statement
        $batches = $ScriptContent -split "(?im)^\s*GO\s*$"
        $batches = @($batches | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

        $result.TotalBatches = $batches.Count
        Write-Host ""
        Write-Host "================="
        Write-Host "Executing Rollback Script: $scriptName"
        Write-Host "Database: $DatabaseName"
        Write-Host "Total Batches: $($batches.Count)"
        Write-Host "================="

        try {
            $connection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
            $connection.Open()
            $result.ActualServer = $connection.DataSource
            Write-Host "Connected to SQL Server: $($connection.DataSource)" -ForegroundColor Green

            if ($connection.Database -ne $DatabaseName) {
                Write-Host "Switching database: $($connection.Database) -> $DatabaseName"
                $connection.ChangeDatabase($DatabaseName)
            }
            $result.ActualDatabase = $connection.Database
        }
        catch [System.Data.SqlClient.SqlException] {
            $sqlException = $_.Exception
            $result.ErrorMessage = "SQL Login failed: $($sqlException.Message)"
            Write-Host "##[error] SQL Server connection failed." -ForegroundColor Red
            Write-Host "Error: $($sqlException.Message)" -ForegroundColor Red
            return $result
        }

        if ($useTransaction) {
            $transaction = $connection.BeginTransaction()
            $result.TransactionStatus = "Open"
            Write-Host "Transaction started."
        }
        else {
            $result.TransactionStatus = "NotUsed"
            Write-Host "##[warning]Script is marked -- @NoTransaction."
        }

        $totalRowsAffected = 0
        $batchNumber = 0

        foreach ($batch in $batches) {
            $batchNumber++
            Write-Host ""
            Write-Host "Executing Batch $batchNumber of $($batches.Count)"

            $command = $null
            try {
                $command = $connection.CreateCommand()
                if ($transaction) {
                    $command.Transaction = $transaction
                }
                $command.CommandText = $batch.Trim()
                $command.CommandTimeout = $TimeoutSeconds

                $rows = $command.ExecuteNonQuery()

                if ($rows -ge 0) {
                    $totalRowsAffected += $rows
                }

                $result.BatchesExecuted++
                Write-Host "Batch $batchNumber executed successfully." -ForegroundColor Green
            }
            catch [System.Data.SqlClient.SqlException] {
                $batchFailed = $true
                $result.FailedBatch = $batchNumber
                $result.ErrorMessage = "Batch $batchNumber failed: $($_.Exception.Message)"

                Write-Host "Batch $batchNumber failed." -ForegroundColor Red
                foreach ($sqlError in $_.Exception.Errors) {
                    Write-Host "Error: $($sqlError.Message)" -ForegroundColor Red
                }
                break
            }
            finally {
                if ($command) { $command.Dispose() }
            }
        }

        $result.RowsAffected = $totalRowsAffected

        if ($batchFailed) {
            if ($transaction) {
                Write-Host "##[error]Rolling back transaction for $scriptName"
                $result.TransactionStatus = Undo-SqlTransaction -Transaction $transaction
            }
            $result.Success = $false
        }
        else {
            if ($transaction) {
                $transaction.Commit()
                $result.TransactionStatus = "Committed"
                Write-Host "Transaction committed." -ForegroundColor Green
            }
            $result.Success = $true
        }
    }
    catch {
        $result.Success = $false
        if (-not $result.ErrorMessage) {
            $result.ErrorMessage = $_.Exception.Message
        }

        if ($transaction -and $result.TransactionStatus -eq "Open") {
            $result.TransactionStatus = Undo-SqlTransaction -Transaction $transaction
        }
    }
    finally {
        $stopWatch.Stop()
        $result.ExecutionTime = [math]::Round($stopWatch.Elapsed.TotalSeconds, 2)
        $result.EndTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

        if ($transaction) { $transaction.Dispose() }
        if ($connection) {
            if ($connection.State -ne [System.Data.ConnectionState]::Closed) {
                $connection.Close()
            }
            $connection.Dispose()
        }
    }
    return $result
}

function Get-ClientConfiguration {
    param(
        [array]$ConfigData,
        [string]$ClientName,
        [string]$Environment
    )

    $clientConfigs = @($ConfigData | Where-Object { $_.clientName -eq $ClientName })

    if ($clientConfigs.Count -eq 0) {
        Write-Warning "Client '$ClientName' not found in configuration"
    }

    return $clientConfigs
}

function Expand-RollbackPlanForClient {
    param(
        [object]$ScriptRow,
        [object[]]$ClientConfigs,
        [hashtable]$SeenTargets
    )

    $expandedRows = @()

    foreach ($clientConfig in $ClientConfigs) {
        if (-not $clientConfig.servers) {
            Write-Warning "No servers found for client $($clientConfig.clientName)"
            continue
        }

        foreach ($server in $clientConfig.servers) {
            $databases = @($server.databases | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

            if ($databases.Count -eq 0) {
                Write-Warning "No databases found for server $($server.serverName) in client $($clientConfig.clientName)"
                continue
            }

            foreach ($database in $databases) {
                $targetKey = "$($server.serverName)|$database".ToLowerInvariant()
                if ($SeenTargets.ContainsKey($targetKey)) {
                    continue
                }
                $SeenTargets[$targetKey] = $clientConfig.clientName

                $expandedRows += [PSCustomObject]@{
                    Release_Version        = $ScriptRow.Release_Version
                    Application_Name       = $ScriptRow.Application_Name
                    Feature_Name           = $ScriptRow.Feature_Name
                    Feature_Order          = $ScriptRow.Feature_Order
                    SQL_Path               = $ScriptRow.SQL_Path
                    Rollback_Script_Path   = $ScriptRow.Rollback_Script_Path
                    Feature_Rollback_Order = $ScriptRow.Feature_Rollback_Order
                    Script_Type            = $ScriptRow.Script_Type
                    Script_Order           = $ScriptRow.Script_Order
                    Client_Name            = $clientConfig.clientName
                    Server_Name            = $server.serverName
                    Database_Name          = $database
                    ConnectionStringVar    = $server.connectionStringVar
                    Execution_Status       = "Pending"
                    Duration               = ""
                    Rows_Affected          = ""
                    Error_Message          = ""
                    Execution_Date         = ""
                    Executed_By            = ""
                }
            }
        }
    }

    return $expandedRows
}

# ============================================================================
# Main execution block
# ============================================================================

Write-StageHeader "Feature Rollback Pipeline"
Write-Host "Environment        : $Environment"
Write-Host "Release Version    : $ReleaseVersion"
Write-Host "Application Filter : $ApplicationFilter"
Write-Host "Feature Filter     : $FeatureFilter"
Write-Host "Dry Run            : $DryRun"

# Validate paths
if (-not (Test-Path $ChecklistPath)) {
    Write-Error "Checklist path '$ChecklistPath' does not exist."
    exit 1
}

if (-not (Test-Path $ConfigFilePath)) {
    Write-Error "Config file path '$ConfigFilePath' does not exist."
    exit 1
}

if (-not (Test-Path -Path $ArtifactsDirectory)) {
    New-Item -ItemType Directory -Path $ArtifactsDirectory -Force | Out-Null
}

# Read configuration
Write-Host "Reading client configuration from $ConfigFilePath"
try {
    $configContent = Get-Content -Path $ConfigFilePath -Raw
    $ConfigData = $configContent | ConvertFrom-Json
    Write-Host "Loaded configuration for $($ConfigData.Count) client(s)" -ForegroundColor Cyan
}
catch {
    Write-Error "Failed to read config file: $($_.Exception.Message)"
    exit 1
}

# Read checklist
Write-Host "Reading checklist from $ChecklistPath"
try {
    $Checklist = Import-Csv $ChecklistPath
    Write-Host "Total records in checklist: $($Checklist.Count)" -ForegroundColor Cyan
}
catch {
    Write-Error "Failed to read checklist: $($_.Exception.Message)"
    exit 1
}

# Filter for environment, release version, and scripts that have rollback paths
$baseScripts = $Checklist | Where-Object {
    $_.Environment -eq $Environment -and
    $_.Release_Version -eq $ReleaseVersion -and
    -not [string]::IsNullOrWhiteSpace($_.Rollback_Script_Path)
}

if ($baseScripts.Count -eq 0) {
    Write-Warning "No scripts with rollback paths found for Environment '$Environment' and Release Version '$ReleaseVersion'"
    exit 1
}

# Apply Application Filter
if ($ApplicationFilter -ne 'all') {
    $baseScripts = $baseScripts | Where-Object { $_.Application_Name -eq $ApplicationFilter }
}

# Apply Feature Filter (mandatory for rollback - comma-separated)
$featureList = @($FeatureFilter -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
Write-Host "Features to roll back: $($featureList -join ', ')" -ForegroundColor Yellow
$baseScripts = $baseScripts | Where-Object { $_.Feature_Name -in $featureList }

if ($baseScripts.Count -eq 0) {
    Write-Warning "No rollback scripts found for the specified feature(s): $($featureList -join ', ')"
    Write-Host "Available features with rollback scripts:" -ForegroundColor Yellow
    $Checklist | Where-Object {
        $_.Environment -eq $Environment -and
        $_.Release_Version -eq $ReleaseVersion -and
        -not [string]::IsNullOrWhiteSpace($_.Rollback_Script_Path)
    } | Select-Object Application_Name, Feature_Name -Unique | Format-Table -AutoSize
    exit 1
}

# Build the exclusion list
$excludedList = @()
if (-not [string]::IsNullOrWhiteSpace($ExcludedClients)) {
    $excludedList = @($ExcludedClients -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    Write-Host "Excluded clients: $($excludedList -join ', ')" -ForegroundColor Yellow
}

# Expand rollback plan by client and database
Write-StageHeader "Building Rollback Plan"
$RollbackPlan = @()
$SkippedRows = @()

foreach ($script in $baseScripts) {
    $clientName = $script.Client_Name

    if ([string]::IsNullOrWhiteSpace($clientName)) {
        Write-Warning "Skipping row - Client_Name is empty for: $($script.Rollback_Script_Path)"
        $SkippedRows += @($script)
        continue
    }

    $clientNames = @($clientName -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $seenTargets = @{}

    foreach ($clientId in $clientNames) {
        if ($excludedList.Count -gt 0 -and $clientId -in $excludedList) {
            Write-Host "[EXCLUDED] Client '$clientId' skipped for rollback" -ForegroundColor Yellow
            continue
        }

        $clientConfigs = @(Get-ClientConfiguration -ConfigData $ConfigData -ClientName $clientId -Environment $Environment)

        if ($clientConfigs.Count -eq 0) {
            Write-Warning "Client '$clientId' not found in configuration - skipping"
            $SkippedRows += @(@{
                Rollback_Script_Path = $script.Rollback_Script_Path
                Client_Name          = $clientId
                Reason               = "Client not found in configuration"
            })
            continue
        }

        $expandedRows = @(Expand-RollbackPlanForClient -ScriptRow $script -ClientConfigs $clientConfigs -SeenTargets $seenTargets)
        if ($expandedRows.Count -gt 0) {
            $RollbackPlan += $expandedRows
        }
    }
}

if ($RollbackPlan.Count -eq 0) {
    Write-Error "No rollback plan rows generated"
    exit 1
}

# Sort: features in REVERSE Feature_Order, then within each feature by DESCENDING Feature_Rollback_Order
$RollbackPlan = $RollbackPlan | Sort-Object -Property `
    @{ Expression = { [int]$_.Feature_Order }; Descending = $true },
    Application_Name, Feature_Name,
    @{ Expression = { [int]$_.Feature_Rollback_Order }; Descending = $true },
    Server_Name, Database_Name

Write-Host "Total rollback plan rows: $($RollbackPlan.Count)" -ForegroundColor Green

# Display rollback plan
Write-Host ""
Write-Host "Rollback Execution Order:" -ForegroundColor Yellow
$featureGroups = @($RollbackPlan | Group-Object -Property Application_Name, Feature_Name |
    Sort-Object -Property @{ Expression = { [int]$_.Group[0].Feature_Order } } -Descending)

$position = 0
foreach ($fg in $featureGroups) {
    $position++
    $first = $fg.Group[0]
    $clients = @($fg.Group | Select-Object -ExpandProperty Client_Name -Unique | Sort-Object) -join ', '
    $scriptCount = @($fg.Group | Select-Object -Property Rollback_Script_Path -Unique).Count
    Write-Host "  $position. [Feature_Order $($first.Feature_Order)] $($first.Application_Name) > $($first.Feature_Name) - $scriptCount rollback script(s), clients: $clients" -ForegroundColor Yellow
}

# Dry run: show plan and exit
if ($VarDryRun) {
    Write-StageHeader "DRY RUN - Rollback Plan Preview"
    $RollbackPlan | Format-Table -AutoSize -Property @(
        @{ Label = "Feature"; Expression = { "$($_.Feature_Order). $($_.Feature_Name)" } },
        @{ Label = "RB_Order"; Expression = { $_.Feature_Rollback_Order } },
        @{ Label = "Client"; Expression = { $_.Client_Name } },
        @{ Label = "Server"; Expression = { $_.Server_Name } },
        @{ Label = "Database"; Expression = { $_.Database_Name } },
        @{ Label = "Rollback_Script"; Expression = { Split-Path $_.Rollback_Script_Path -Leaf } }
    )

    # Export rollback plan CSV for review
    $planPath = Join-Path $ArtifactsDirectory "rollback_plan.csv"
    $RollbackPlan | Export-Csv -Path $planPath -NoTypeInformation -Force
    Write-Host "Rollback plan exported to: $planPath" -ForegroundColor Green

    Write-StageHeader "End of DRY RUN"
    exit 0
}

# ============================================================================
# Execute Rollback
# ============================================================================

Write-StageHeader "Executing Rollback"

$rollbackSuccess = $true
$totalExecuted = 0
$totalFailed = 0
$totalSkipped = 0

foreach ($fg in $featureGroups) {
    $applicationName = $fg.Group[0].Application_Name
    $featureName = $fg.Group[0].Feature_Name

    Write-StageHeader "Rolling back: $applicationName > $featureName"

    # Group by target (server|database), execute rollback scripts per target
    $targetGroups = @($fg.Group | Group-Object -Property {
        "$($_.Server_Name)|$($_.Database_Name)".ToLowerInvariant()
    })

    foreach ($targetGroup in $targetGroups) {
        $targetScripts = @($targetGroup.Group | Sort-Object -Property @{
            Expression = { [int]$_.Feature_Rollback_Order }; Descending = $true
        })
        $targetLabel = "$($targetScripts[0].Client_Name) ($($targetScripts[0].Server_Name).$($targetScripts[0].Database_Name))"

        Write-RollbackStatus "Target: $targetLabel - $($targetScripts.Count) rollback script(s)" "Info"

        $targetFailed = $false

        foreach ($script in $targetScripts) {
            $rollbackPath = $script.Rollback_Script_Path

            if ($targetFailed) {
                Write-RollbackStatus "[SKIPPED] $(Split-Path $rollbackPath -Leaf) - previous rollback script failed" "Warning"
                $script.Execution_Status = "Skipped"
                $script.Error_Message = "Skipped: previous rollback script failed for this target"
                $totalSkipped++
                $Global:RollbackResults += $script
                continue
            }

            if (-not (Test-Path $rollbackPath)) {
                Write-RollbackStatus "Rollback script not found: $rollbackPath" "Failed"
                $script.Execution_Status = "Failed"
                $script.Error_Message = "Rollback script file not found: $rollbackPath"
                $targetFailed = $true
                $rollbackSuccess = $false
                $totalFailed++
                $Global:RollbackResults += $script
                continue
            }

            # Get connection string from environment variable
            $connVarName = $script.ConnectionStringVar
            $connectionString = (Get-ChildItem Env:$connVarName -ErrorAction SilentlyContinue).Value

            if (-not $connectionString) {
                Write-RollbackStatus "Connection string variable '$connVarName' not set" "Failed"
                $script.Execution_Status = "Failed"
                $script.Error_Message = "Connection string variable '$connVarName' not found"
                $targetFailed = $true
                $rollbackSuccess = $false
                $totalFailed++
                $Global:RollbackResults += $script
                continue
            }

            Write-RollbackStatus "Executing: $(Split-Path $rollbackPath -Leaf) on $($script.Server_Name).$($script.Database_Name)" "Rollback"

            $execResult = Invoke-SQLScript -ScriptPath $rollbackPath `
                -ConnectionString $connectionString `
                -DatabaseName $script.Database_Name `
                -TimeoutSeconds 0

            $script.Execution_Date = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            $script.Executed_By = [System.Environment]::UserName
            $script.Duration = $execResult.ExecutionTime
            $script.Rows_Affected = $execResult.RowsAffected

            if ($execResult.Success) {
                Write-RollbackStatus "Rollback script completed successfully" "Success"
                $script.Execution_Status = "Rollback Success"
                $totalExecuted++
            }
            else {
                Write-RollbackStatus "Rollback script failed: $($execResult.ErrorMessage)" "Failed"
                $script.Execution_Status = "Rollback Failed"
                $script.Error_Message = "Rollback failed: $($execResult.ErrorMessage)"
                $targetFailed = $true
                $rollbackSuccess = $false
                $totalFailed++
            }

            $Global:RollbackResults += $script
        }
    }
}

# ============================================================================
# Results
# ============================================================================

Write-StageHeader "Rollback Results"

$executionTime = [math]::Round(((Get-Date) - $Global:ExecutionStartTime).TotalSeconds, 2)

Write-Host "Successful Rollbacks : $totalExecuted" -ForegroundColor Green
Write-Host "Failed Rollbacks     : $totalFailed" -ForegroundColor Red
Write-Host "Skipped              : $totalSkipped" -ForegroundColor Yellow
Write-Host "Total                : $($Global:RollbackResults.Count)" -ForegroundColor Yellow
Write-Host "Execution Time       : $executionTime seconds" -ForegroundColor Yellow

# Display details
$Global:RollbackResults | Format-Table -AutoSize -Property @(
    @{ Label = "Feature"; Expression = { "$($_.Feature_Order). $($_.Feature_Name)" } },
    @{ Label = "RB_Order"; Expression = { $_.Feature_Rollback_Order } },
    @{ Label = "Client"; Expression = { $_.Client_Name } },
    @{ Label = "Server"; Expression = { $_.Server_Name } },
    @{ Label = "Database"; Expression = { $_.Database_Name } },
    @{ Label = "Script"; Expression = { Split-Path $_.Rollback_Script_Path -Leaf } },
    @{ Label = "Status"; Expression = { $_.Execution_Status } },
    @{ Label = "Duration(s)"; Expression = { $_.Duration } }
) | Out-String -Width 4096 | Write-Host

# Export results
$buildId = $env:BUILD_BUILDID
if ([string]::IsNullOrWhiteSpace($buildId)) { $buildId = "local" }
$resultsPath = Join-Path $ArtifactsDirectory "rollback-results-$buildId.csv"

$Global:RollbackResults | Export-Csv -Path $resultsPath -NoTypeInformation -Force
Write-Host "Results exported to: $resultsPath" -ForegroundColor Green

# Set pipeline variables
Write-Host ""
Write-Host "##vso[task.setvariable variable=RollbackSuccess;isOutput=true]$rollbackSuccess"
Write-Host "##vso[task.setvariable variable=RollbackExecuted;isOutput=true]$totalExecuted"
Write-Host "##vso[task.setvariable variable=RollbackFailed;isOutput=true]$totalFailed"
Write-Host "##vso[task.setvariable variable=RollbackSkipped;isOutput=true]$totalSkipped"
Write-Host "##vso[task.setvariable variable=ExecutionTime;isOutput=true]$executionTime"

if ($rollbackSuccess) {
    Write-Host "[SUCCESS] Feature rollback completed successfully" -ForegroundColor Green
    exit 0
}
else {
    Write-Host "[FAILED] Feature rollback completed with failures" -ForegroundColor Red
    exit 1
}

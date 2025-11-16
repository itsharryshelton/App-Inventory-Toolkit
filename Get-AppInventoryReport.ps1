function Get-AppCount {
    <#
    .EXAMPLE
    Get-AppCount
    .DESCRIPTION
    Groups and counts all applications found in the $Global:AllData variable.
    #>
    if (-not $Global:AllData) {
        Write-Error "Data not loaded. Run the main script first."
        return
    }
    Write-Host "--- Top 20 Most Common Apps ---"
    $Global:AllData.Applications | Group-Object DisplayName | Sort-Object Count -Descending | Select-Object -First 20 Count, Name
}

function Get-AppSearch {
    <#
    .EXAMPLE
    Get-AppSearch -Name "Adobe Reader"
    Get-AppSearch -Name "Chrome" -Version "100*"
    .DESCRIPTION
    Searches all machines in $Global:AllData for a specific application.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Name,
        
        [string]$Version = "*"
    )
    if (-not $Global:AllData) {
        Write-Error "Data not loaded. Run the main script first."
        return
    }

    Write-Host "--- Machines with '$Name' (Version: $Version) ---"
    
    $machinesFound = @()
    foreach ($machine in $Global:AllWData) {
        $foundApp = $machine.Applications | Where-Object { 
            $_.DisplayName -like "*$Name*" -and $_.DisplayVersion -like $Version 
        }
        
        if ($foundApp) {
            Write-Host "$($machine.ComputerName):"
            $foundApp | Format-Table -AutoSize DisplayName, DisplayVersion
            $machinesFound += $machine
        }
    }
    
    if ($machinesFound.Count -eq 0) {
        Write-Host "No machines found with that application."
    }
}


#CONFIGURATION

# Specify the customer folder you want to query - Match the R2 Folder Name
$CustomerName = "EDITME" 

#Fill these in from your Cloudflare R2 API Token & Bucket Info ---
$AccessKey = "EDITME"
$SecretKey = "EDITME"
$BucketName = "EDITME"
$R2Endpoint = "EDITME"

#rclone Config (Internal)
$rcloneRemoteName = "TempR2" # A temporary name for the in-memory remote
$localSyncBasePath = "C:\temp\R2Inventory" 

# MAIN SCRIPT LOGIC
try {
    if (-not $CustomerName -or $CustomerName -eq "CustomerA") {
        Write-Warning "The `$CustomerName` variable is set to the default ('CustomerA'). Please edit the script to set the correct customer folder."
    }
    $localSyncPath = Join-Path $localSyncBasePath $CustomerName
    New-Item -Path $localSyncPath -ItemType Directory -Force | Out-Null

    #rclone.exe
    Write-Host "Checking for rclone..."
    $scriptPath = $PSScriptRoot
    [string]$rcloneExePath = Join-Path $scriptPath "rclone.exe"
    
    if (-not (Test-Path $rcloneExePath)) {
        #Not found in script root. Try system PATH.
        Write-Host "Not found in script folder, checking system PATH..."
        $rcloneCmd = Get-Command rclone -ErrorAction SilentlyContinue
        if (-not $rcloneCmd) {
            Write-Error "rclone.exe not found. Please place rclone.exe in the same directory as this script OR add it to your system PATH."
            throw "rclone.exe not found."
        }
        #Found in PATH. Get the full path string.
        $rcloneExePath = $rcloneCmd.Source
    }
    
    Write-Host "Found rclone at $rcloneExePath"

    #Set rclone environment variables IN-MEMORY
    Write-Host "Setting temporary R2 credentials for rclone..."
    Set-Item -Path "env:RCLONE_CONFIG_${rcloneRemoteName}_TYPE" -Value "s3"
    Set-Item -Path "env:RCLONE_CONFIG_${rcloneRemoteName}_PROVIDER" -Value "Cloudflare"
    Set-Item -Path "env:RCLONE_CONFIG_${rcloneRemoteName}_ENDPOINT" -Value ($R2Endpoint.Replace("https://", ""))
    Set-Item -Path "env:RCLONE_CONFIG_${rcloneRemoteName}_ACCESS_KEY_ID" -Value $AccessKey
    Set-Item -Path "env:RCLONE_CONFIG_${rcloneRemoteName}_SECRET_ACCESS_KEY" -Value $SecretKey

    #Run rclone sync
    Write-Host "Syncing inventory for '$CustomerName' from R2..."
    $rcloneSource = "$($rcloneRemoteName):$BucketName/$CustomerName"
    
    #Build the argument string cleanly using the -f format operator
    $argList = 'sync "{0}" "{1}"' -f $rcloneSource, $localSyncPath
    
    #Run the logic
    $proc = Start-Process -FilePath $rcloneExePath -ArgumentList $argList -NoNewWindow -PassThru -Wait -RedirectStandardError ".\rclone-error.log"
    
    if ($proc.ExitCode -ne 0) {
        Write-Error "rclone sync failed. Check rclone-error.log for details."
        throw "rclone sync failed."
    }
    Write-Host "Sync complete. Loading data into memory..."

    #Load data from synced files
    $Global:AllData = Get-ChildItem -Path $localSyncPath -Filter "*.json" | ForEach-Object {
        Get-Content -Path $_.FullName -Raw | ConvertFrom-Json
    }
    
    if ($Global:AllData.Count -eq 0) {
        Write-Warning "No inventory files found for '$CustomerName'. Check the folder name and bucket."
    }

    #Make data and functions available to the user's console
    Write-Host "`nReady to query! $($Global:AllData.Count) machines loaded for '$CustomerName'." -ForegroundColor Green
    Write-Host "The data is in the global `$AllData` variable."
    Write-Host "Try running: Get-AppCount or Get-AppSearch -Name 'Chrome'"
}
catch {
    Write-Error "Script failed: $_"
}

function Export-InventoryReport {
    <#
    .EXAMPLE
    Export-InventoryReport -CustomerName "CustomerA"
    .DESCRIPTION
    Creates a multi-sheet Excel report from the $Global:AllData variable.
    #>
    param(
        [string]$CustomerName
    )

    # 1. Check for the ImportExcel module
    if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
        Write-Error "This report requires the 'ImportExcel' module. Please run: Install-Module ImportExcel -Scope CurrentUser" -ForegroundColor Red
        return
    }

    # 2. Check that data is loaded
    if (-not $Global:AllData) {
        Write-Error "Data not loaded. Run the main query script first."
        return
    }

    $outputPath = "C:\temp\R2Inventory\${CustomerName}_Application_Report.xlsx"
    Write-Host "Flattening data for $($Global:AllData.Count) machines..."

    # 3. Create the "Raw Data" sheet content
    # This creates the full list: 100 machines * 80 apps = 8,000 rows
    $flatData = $Global:AllData | ForEach-Object {
        $machineName = $_.ComputerName
        $reportDate = $_.ReportDate
        
        $_.Applications | ForEach-Object {
            [PSCustomObject]@{
                ComputerName = $machineName
                AppName      = $_.DisplayName
                AppVersion   = $_.DisplayVersion
                Publisher    = $_.Publisher
                InstallDate  = $_.InstallDate
                LastReport   = $reportDate
            }
        }
    }
    
    Write-Host "Data flattened. Found $($flatData.Count) total application installs."
    Write-Host "Generating summary..."

    #Create the "Summary" sheet content
    $summaryData = $flatData | Group-Object AppName | Select-Object @{Name="InstallCount"; Expression={$_.Count}}, @{Name="ApplicationName"; Expression={$_.Name}} | Sort-Object InstallCount -Descending
    
    Write-Host "Exporting to $outputPath..."
    Write-Host "(This may take a moment for a large number of machines...)"

    #Export to a multi-sheet Excel file
    #Sheet 1: Raw Data
    $flatData | Export-Excel -Path $outputPath -WorksheetName "Raw Data" -AutoSize -FreezeTopRow
    
    #Sheet 2: Summary
    $summaryData | Export-Excel -Path $outputPath -WorksheetName "Summary" -AutoSize -FreezeTopRow
    
    Write-Host "Report complete! $outputPath" -ForegroundColor Green
    Invoke-Item $outputPath
}

Export-InventoryReport -CustomerName $CustomerName

#Written by Harry Shelton
#Nov 2025

#Edit This - Keep One Word (e.g. UntastyCoffeeCo) - This is your R2 Bucket Folder Name
$CustomerName = "EDITME"

#AWS Signature Helpers, don't edit
function Get-Sha256Hash($Message) {
    $sha256 = New-Object -TypeName System.Security.Cryptography.SHA256Managed
    $utf8 = New-Object -TypeName System.Text.UTF8Encoding
    $hash = [System.BitConverter]::ToString($sha256.ComputeHash($utf8.GetBytes($Message)))
    return $hash.Replace('-', '').ToLower()
}

function Get-HmacSha256Signature([byte[]]$Key, [string]$Message) {
    $hmacsha = New-Object -TypeName System.Security.Cryptography.HMACSHA256
    $hmacsha.Key = $Key
    return $hmacsha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Message))
}

function Get-AwsSigV4SigningKey {
    param (
        [string]$SecretKey,
        [string]$DateStamp,
        [string]$Region,
        [string]$Service
    )
    $kSecret = [System.Text.Encoding]::UTF8.GetBytes("AWS4" + $SecretKey)
    $kDate = Get-HmacSha256Signature $kSecret $DateStamp
    $kRegion = Get-HmacSha256Signature $kDate $Region
    $kService = Get-HmacSha256Signature $kRegion $Service
    $kSigning = Get-HmacSha256Signature $kService "aws4_request"
    return $kSigning
}


# MAIN SCRIPT LOGIC
$AccessKey = "EDIT ME"
$SecretKey = "EDIT ME"
$BucketName = "EDIT ME"
$R2Endpoint = "https://EDITME.r2.cloudflarestorage.com"
$Region = "auto"

try {
    Write-Host "Starting application inventory..."

    #Get Application Inventory
    function Get-InstalledApps {
        $registryPaths = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        )
        $installedApps = @()

        foreach ($path in $registryPaths) {
            if (Test-Path $path) {
                try {
                    $apps = Get-ChildItem -Path $path -ErrorAction SilentlyContinue | Get-ItemProperty -ErrorAction SilentlyContinue | Where-Object {
                        $_.DisplayName -and 
                        $_.DisplayName -notlike "Microsoft Visual C++*" -and
                        $_.DisplayName -notlike "Microsoft .NET*" -and
                        $_.SystemComponent -ne 1 -and
                        $_.ParentKeyName -eq $null
                    } | Select-Object DisplayName, DisplayVersion, Publisher, InstallDate
                    
                    $installedApps += $apps
                }
                catch {
                    Write-Warning "Could not access registry path $path. Skipping."
                }
            }
        }
        return $installedApps | Sort-Object DisplayName | Get-Unique -AsString
    }

    #Create JSON Payload
    $computerName = $env:COMPUTERNAME
    $applications = Get-InstalledApps

    $outputObject = [PSCustomObject]@{
        ComputerName = $computerName
        ReportDate   = (Get-Date).ToUniversalTime().ToString('o')
        Applications = $applications
        CustomerName = $CustomerName
    }
    
    $jsonData = $outputObject | ConvertTo-Json -Depth 5 -Compress
    $payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonData)

    Write-Host "Inventory complete. Found $($applications.Count) applications."

    #Prepare for R2 Upload
    $service = "s3"
    $method = "PUT"
    $objectKey = "$($CustomerName)/$($computerName).json" 
    $amzDate = (Get-Date).ToUniversalTime().ToString("yyyyMMdd'T'HHmmss'Z'")
    $dateStamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd")

    #Create AWS SigV4 Request
    
    #Create Canonical Request
    $payloadHash = Get-Sha256Hash $jsonData
    $endpointHost = $R2Endpoint.Replace("https://", "")
    $canonicalUri = "/$BucketName/$objectKey"
    $canonicalHeaders = "host:$endpointHost`nx-amz-content-sha256:$payloadHash`nx-amz-date:$amzDate`n"
    $signedHeaders = "host;x-amz-content-sha256;x-amz-date"

    $canonicalRequest = "$method`n" +
                        "$canonicalUri`n" +
                        "`n" + # Canonical Query String (empty)
                        "$canonicalHeaders`n" +
                        "$signedHeaders`n" +
                        "$payloadHash"

    #Create String to Sign
    $algorithm = "AWS4-HMAC-SHA256"
    $credentialScope = "$dateStamp/$Region/$service/aws4_request"
    $canonicalRequestHash = Get-Sha256Hash $canonicalRequest

    $stringToSign = "$algorithm`n" +
                    "$amzDate`n" +
                    "$credentialScope`n" +
                    "$canonicalRequestHash"
                    
    $signingKey = Get-AwsSigV4SigningKey -SecretKey $SecretKey -DateStamp $dateStamp -Region $Region -Service $service
    $signatureBytes = Get-HmacSha256Signature $signingKey $stringToSign
    $signature = [System.BitConverter]::ToString($signatureBytes).Replace('-', '').ToLower()
    $authorizationHeader = "$algorithm Credential=$AccessKey/$credentialScope, SignedHeaders=$signedHeaders, Signature=$signature"

    #Build .NET WebRequest and Execute Upload
    $uri = "$R2Endpoint$canonicalUri"
    Write-Host "Uploading data to $uri..."
    $request = [System.Net.WebRequest]::Create($uri)
    $request.Method = "PUT"
    $request.ContentType = "application/json"
    $request.ContentLength = $payloadBytes.Length

    #Manually add all headers
    $request.Headers.Add("Authorization", $authorizationHeader)
    $request.Headers.Add("x-amz-content-sha256", $payloadHash)
    $request.Headers.Add("x-amz-date", $amzDate)
    $request.Host = $endpointHost

    try {
        #Write the JSON data into the request stream
        $requestStream = $request.GetRequestStream()
        $requestStream.Write($payloadBytes, 0, $payloadBytes.Length)
        $requestStream.Close()
        $response = $request.GetResponse()
        $response.Close()
    }
    catch {
        #Catch any web-related errors
        $webException = $_.Exception
        if ($webException -is [System.Net.WebException]) {
            $responseStream = $webException.Response.GetResponseStream()
            $streamReader = New-Object System.IO.StreamReader -ArgumentList $responseStream
            $errorBody = $streamReader.ReadToEnd()
            $streamReader.Close()
            Write-Error "Web Request failed: $errorBody"
        }
        else {
            Write-Error "Script failed: $_"
        }
        exit 1
    }

    Write-Host "Successfully uploaded inventory for $computerName."
    }
catch {
    Write-Error "Script failed with an unexpected error: $_"
    exit 1
}

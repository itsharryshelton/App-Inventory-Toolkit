# App Inventory Toolkit
Work with your RMM or GPO to grab all applications, upload to R2 Bucket and then summarise all the information into one easy excel sheet.

## `Start-AppInventoryUpload.ps1`

This script is the "client-side" component of the App-Inventory Toolkit. It's designed to be deployed by an RMM (like Datto, N-able, ConnectWise, etc.) onto client endpoints.

It is lightweight, self-contained, and has **no external module dependencies**. It uses older .NET classes (`System.Net.WebRequest`) to ensure compatibility with legacy PowerShell (v2.0+) environments often found in RMMs.

## What it Does

1.  **Gathers Apps:** Scans the local machine's registry (`HKLM:\...` Uninstall keys) to find all installed 32-bit and 64-bit applications. It filters out common junk like Windows updates and .NET Runtimes.
2.  **Creates JSON Payload:** Compiles the app list, computer name, and customer name into a single JSON object.
3.  **Generates Auth Header:** Manually builds a pure PowerShell **AWS Signature Version 4 (SigV4)** header to authenticate with the Cloudflare R2 S3-compatible API.
4.  **Uploads to R2:** Uses the built-in .NET `HttpWebRequest` class to upload the JSON file directly to your specified R2 bucket.

The final file is uploaded to the R2 bucket in this format: `[BucketName]/[CustomerName]/[ComputerName].json`.

## How to Use (Configuration)

This script **must be configured** before deployment. Open the script and edit the variables in the main script logic section (around line 40).

```powershell
# 1. Set the Customer Name (MUST BE ONE WORD)
# This defines the R2 folder for this client
$CustomerName = "EDITME"

...

# 2. Set R2 API Details
# These are your Cloudflare R2 credentials
$AccessKey = "EDIT ME"
$SecretKey = "EDIT ME"
$BucketName = "EDIT ME"
$R2Endpoint = "[https://EDITME.r2.cloudflarestorage.com](https://EDITME.r2.cloudflarestorage.com)"
```
`$CustomerName`: This is the most important field to change for each client. It must be a single word (e.g., UntastyCoffeeCo, ClientXYZ) as it becomes the folder name in R2.

`$AccessKey` / `$SecretKey`: Your R2 API Token credentials.

`$BucketName`: The name of your R2 bucket.

`$R2Endpoint`: Your R2 account's S3-compatible endpoint URL.

⚠️ Security Note: The R2 API Token used here should be scoped with "Object Read & Write" permissions and locked down to only the specific R2 bucket you are using for this toolkit. ⚠️

### RMM Deployment
Configure: Create a copy of the script for the customer you're deploying to. Edit the $CustomerName and R2 variables as shown above.

Deploy: Create a new script component in your RMM (e.g., Datto) and paste the entire configured script into it - ensure it is deployed as system/admin, not logged in user.

Schedule: Configure the script to run on a schedule (e.g., once daily) across the target devices for that customer.

Monitor: The script will output its progress to StdOut (e.g., "Starting application inventory..."). If it fails, it will write a descriptive message to StdError and exit with a non-zero code, which your RMM should detect as a failure.

------------------------------

## `Get-AppInventoryReport.ps1`

This is the "admin-side" script for the App-Inventory Toolkit. It's designed to be run by an engineer on their local machine.

Its primary purpose is to connect to the Cloudflare R2 bucket, download all the individual JSON inventory files for a specific customer, and compile them into a single, easy-to-read Excel report.

## What it Does

1.  **Connects to R2:** Uses a bundled `rclone.exe` and in-memory API keys to securely connect to your R2 bucket. **No `rclone config` is needed.**
2.  **Downloads Data:** Syncs all `.json` files from the specified customer's folder in R2 to a local temp folder (`C:\temp\R2Inventory\[CustomerName]`).
3.  **Loads Data:** Reads all downloaded JSON files into memory.
4.  **Generates Excel Report:** Creates a multi-sheet `.xlsx` report with two tabs:
    * **Sheet 1: "Raw Data"** - A flat list of every single application on every single machine.
    * **Sheet 2: "Summary"** - A pivot-table-style summary showing the most common applications and their install counts.
5.  **Auto-Opens Report:** Automatically opens the generated Excel file for immediate review.

---

## Prerequisites (One-Time Setup)

Before running this script, your admin machine needs two things:

### 1. `rclone.exe`

This script requires `rclone.exe` to communicate with R2.

* Download `rclone.exe` from the [official rclone website](https://rclone.org/downloads/).
* Place the `rclone.exe` file in the **same folder** as this `Get-AppInventoryReport.ps1` script.

### 2. `ImportExcel` PowerShell Module

This script uses a popular module to create the `.xlsx` file without needing Microsoft Excel installed.

* Open a PowerShell window (as an admin) and run this command once:

```powershell
Install-Module ImportExcel -Scope CurrentUser
```

## How to Use

Configure Script: Open Get-AppInventoryReport.ps1 in a code editor (like VS Code or PowerShell ISE). Fill in the CONFIGURATION block:

```powershell

# Specify the customer folder you want to query - Match the R2 Folder Name
$CustomerName = "EDITME" 

#Fill these in from your Cloudflare R2 API Token & Bucket Info ---
$AccessKey = "EDITME_YOUR_ACCESS_KEY"
$SecretKey = "EDITME_YOUR_SECRET_KEY"
$BucketName = "EDITME_YOUR_BUCKET_NAME"
$R2Endpoint = "https://EDITME_ACCOUNT_ID.r2.cloudflarestorage.com"
```
Run Script:

Open a PowerShell terminal and navigate (cd) to the folder containing the script and rclone.exe.

Run the script directly:

```powershell

.\Get-AppInventoryReport.ps1
The script will run, show its progress (syncing, loading, exporting), and then automatically open the final Excel report.
```

Optional: Manual Querying

The script also includes helper functions (Get-AppCount, Get-AppSearch) that you can use for quick manual checks.

To use them, you must dot-source the script when you run it (note the . at the beginning):

```powershell

. .\Get-AppInventoryReport.ps1
After it finishes, the $Global:AllData variable and the helper functions will be available in your terminal. You can then run:
```
```powershell
# See the top 20 most common apps
Get-AppCount

# Find all machines with 'Chrome'
Get-AppSearch -Name "Chrome"
```

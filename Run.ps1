param (
    [switch]$IncludeReportOnly,
    [switch]$SkipUserImpactMatrix,
    [int]$UserImpactMatrixLimit,
    [string]$RemovePersonaURL,
    [string]$AddPersonaURL,
    [switch]$Help
)

if ($Help) {
    Write-Host @"
Conditional Access Validator - Help

Usage:
    .\run.ps1 [options]

Options:
    -IncludeReportOnly       Include policies enabled for reporting only.
    -SkipUserImpactMatrix    Skip generation of the User Impact Matrix.
    -UserImpactMatrixLimit   Limit the number of users in the User Impact Matrix.
    -RemovePersonaURL        Custom URL for removing personas from policies.
    -AddPersonaURL           Custom URL for adding personas to policies.
    -Help                    Show this help message.

Description:
    This script connects to Microsoft Graph, fetches Conditional Access policies,
    generates Maester tests, flow charts, user impact matrices, persona reports,
    and outputs a comprehensive HTML report.

Examples:
    .\run.ps1
    .\run.ps1 -IncludeReportOnly
    .\run.ps1 -UserImpactMatrixLimit 100
    .\run.ps1 -Help

For more information, visit:
    https://github.com/jasperbaes/Conditional-Access-Validator

"@
    exit
}

# Import scripts
. ([System.IO.Path]::Combine($PSScriptRoot, 'scripts/test-psversion.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'scripts/shared.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'scripts/test-generator.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'scripts/maester-code-generator.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'scripts/flow-diagram.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'scripts/user-impact-matrix.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'scripts/persona-report.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'scripts/nested-groups.ps1'))

# Get current version
$jsonContent = Get-Content -Path "./assets/latestVersion.json" -Raw | ConvertFrom-Json

$Global:CURRENTVERSION = $jsonContent.latestVersion
$Global:LATESTVERSION = ""
$Global:UPTODATE = $true 

# Start the timer
$startTime = Get-Date

Write-Host "`n ## Conditional Access Validator ## " -ForegroundColor Cyan -NoNewline; Write-Host "v$CURRENTVERSION" -ForegroundColor DarkGray
Write-Host " Part of the Conditional Access Blueprint - https://jbaes.be/Conditional-Access-Blueprint" -ForegroundColor DarkGray
Write-Host " Created by Jasper Baes - https://github.com/jasperbaes/Conditional-Access-Validator`n" -ForegroundColor DarkGray

# Check if using the latest version
try {
    # Fetch latest version from GitHub
    Write-OutputInfo "Checking version"
    $response = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/jasperbaes/Conditional-Access-Validator/main/assets/latestVersion.json'
    $LATESTVERSION = $response.latestVersion

    # If latest version from GitHub does not match script version, display update message
    if ($LATESTVERSION -ne $CURRENTVERSION) {
        $Global:UPTODATE = $false
        Write-OutputError "Update available! Run 'git pull' to update from $CURRENTVERSION --> $LATESTVERSION"
    } else {
        Write-OutputSuccess "Conditional Access Validator version is up to date"
    }
} catch { }

# Import settings
Write-OutputInfo "Importing settings"

try {
    if (Test-Path -Path "settings.json") {
        $jsonContent = Get-Content -Path "settings.json" -Raw | ConvertFrom-Json

        if ($jsonContent.tenantID -and $jsonContent.clientID -and $jsonContent.clientSecret) {
            $Global:TENANTID = $jsonContent.tenantID
            $Global:CLIENTID = $jsonContent.clientID
            $Global:CLIENTSECRET = $jsonContent.clientSecret
        } 
    }
} catch {
    Write-OutputError "An error occurred while importing settings: $_"
}

# Check if Microsoft.Graph.Authentication module is installed
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-OutputError "The Microsoft.Graph.Authentication module is not installed. Please install it first using the following command: 'Install-Module -Name Microsoft.Graph.Authentication'"
    Write-OutputError "Exiting script."
    Exit
} 

Import-Module Microsoft.Graph.Identity.DirectoryManagement -Force

# Connect to Microsoft Graph
Write-OutputInfo "Connecting to Microsoft Graph"

# Get current MgGraph session from the terminal
$mgContext = Get-MgContext

if([string]::IsNullOrEmpty($mgContext)) { # if a MgGraph session does not exist yet in the terminal
    Write-OutputInfo "No active MgGraph session detected. Checking your options..."

    # Check if App credentials are set in settings.json
    if ([string]::IsNullOrWhiteSpace($Global:TENANTID) -or [string]::IsNullOrWhiteSpace($Global:CLIENTID) -or [string]::IsNullOrWhiteSpace($Global:CLIENTSECRET)) {
        Write-OutputError "Failed to connect to Microsoft Graph"
        Write-OutputError "Please login with 'Connect-MgGraph' command, or set the tenantID, clientID and clientSecret in settings.json and try again."
    } else { # if app credentials are set in settings.json, then try to sign-in
        Write-OutputInfo "Connecting to the Microsoft Graph with application"

        $clientSecret = ConvertTo-SecureString -AsPlainText $CLIENTSECRET -Force
        [pscredential]$clientSecretCredential = New-Object System.Management.Automation.PSCredential($CLIENTID, $clientSecret)

        try { # Connect with App Registration
            Connect-MgGraph -TenantId $TENANTID -ClientSecretCredential $clientSecretCredential -NoWelcome -ErrorAction Stop
            $mgContext = Get-MgContext
            Write-OutputSuccess "Connected to the Microsoft Graph with Service Principal $($mgContext.AppName)"
        } catch {
            Write-OutputError "Failed to connect to Microsoft Graph: $($_.Exception.Message)"
            Write-OutputError "Please login with 'Connect-MgGraph' command, or set the correct tenantID, clientID and clientSecret in settings.json and try again."
            Exit
        }
    }
} else { # if a MgGraph session already exists
    if (-not [string]::IsNullOrEmpty($mgContext.Account)) {
        Write-OutputSuccess "Connected to the Microsoft Graph with account $($mgContext.Account)"
    } elseif (-not [string]::IsNullOrEmpty($mgContext.AppName)) {
        Write-OutputSuccess "Connected to the Microsoft Graph with Service Principal $($mgContext.AppName)"
    }     
}

# Set organization tenant name
$Global:ORGANIZATIONNAME = (Get-MgOrganization).DisplayName

# Fetch Conditional Access policies
Write-OutputInfo "Fetching Conditional Access policies"
$conditionalAccessPoliciesRaw = Invoke-MgGraphRequest -Method GET 'https://graph.microsoft.com/v1.0/policies/conditionalAccessPolicies?$orderby=displayName'
$conditionalAccessPolicies = $conditionalAccessPoliciesRaw.value | Select id, displayName, state, conditions, grantControls
$conditionalAccessPoliciesRaw = $conditionalAccessPoliciesRaw | ConvertTo-Json -Depth 99


if ($conditionalAccessPolicies.count -gt 0) {
    Write-OutputSuccess "$($conditionalAccessPolicies.count) Conditional Access policies detected"
} else {
    Write-OutputError "0 Conditional Access policies detected. Verify the credentials in settings.json are correct, the Service Principal has the correct permissions, your user has the correct permissions or the tenant has Conditional Access policies in place. Exiting script."
    Exit
}

# Filter enabled policies
Write-OutputInfo "Filtering enabled Conditional Access policies"

if ($IncludeReportOnly) {
    $conditionalAccessPolicies = $conditionalAccessPolicies | Where-Object { $_.state -eq 'enabledForReportingButNotEnforced' -or  $_.state -eq 'enabled'}
} else {
    $conditionalAccessPolicies = $conditionalAccessPolicies | Where-Object { $_.state -eq 'enabled' }
}

Write-OutputSuccess "$($conditionalAccessPolicies.count) enabled Conditional Access policies detected"

##################
# TEST GENERATOR #
##################

$MaesterTests = Create-Simulations $conditionalAccessPolicies

##########################
# MAESTER CODE GENERATOR #
##########################

$templateMaester = Create-MaesterCode $MaesterTests $IncludeReportOnly

##############
# JSON CRACK #
##############

$CAJSON = Get-ConditionalAccessFlowChart $MaesterTests
    
$filenameTemplate = "$((Get-Date -Format 'yyyyMMddHHmm'))-$($ORGANIZATIONNAME)-ConditionalAccessMaesterTests"
# $CAJSON | ConvertTo-Json -Depth 99 # Uncomment for debugging purposes
$CAjsonRaw = $CAJSON | ConvertTo-Json -Depth 99 # used in JSON Crack

######################
# User Impact Matrix #
######################

$userImpactMatrix = @()

if ($SkipUserImpactMatrix) {
    Write-OutputInfo "Skipping User Impact Matrix"
} else {
    $userImpactMatrix = Get-UserImpactMatrix $conditionalAccessPolicies $UserImpactMatrixLimit
    $columnNames = @($userImpactMatrix[0].Keys)
    $userImpactMatrix | Export-CSV -Path "$filenameTemplate.csv"
    Write-OutputSuccess "User Impact Matrix available at: '$filenameTemplate.csv'"
}

##################
# Persona Report #
##################

$PersonaReport = Get-PersonaReport $conditionalAccessPolicies

#################
# NESTED GROUPS #
#################

$NestedGroups = Get-NestedGroups
$NestedGroupsJsonRaw = $NestedGroups | ConvertTo-Json -Depth 99

##################

$endTime = Get-Date # end script timer

$elapsedTime = $endTime - $startTime
$minutes = [math]::Floor($elapsedTime.TotalMinutes)
$seconds = $elapsedTime.Seconds

# ##########
# # REPORT #
# ##########

Write-OutputInfo "Generating report"
$datetime = Get-Date -Format "dddd, MMMM dd, yyyy HH:mm:ss"

$template = @"
<!DOCTYPE html>
          <html lang="en">
            <head>
              <meta charset="UTF-8">
              <meta name="viewport" content="width=device-width, initial-scale=1.0">
              <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.5/dist/css/bootstrap.min.css" rel="stylesheet" integrity="sha384-SgOJa3DmI69IUzQ2PVdRZhwQ+dy64/BUtbMJw1MZ8t5HZApcHrRKUc4W0kG879m7" crossorigin="anonymous">
              <link rel="stylesheet" href="assets/fonts/AvenirBlack.ttf">
              <link rel="stylesheet" href="assets/fonts/AvenirBook.ttf">
              <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/bootstrap-icons.min.css">
              <style>
                @font-face {
                        font-family: mcgaFont;
                        src: url(./assets/fonts/AvenirBook.ttf);
                    }

                    @font-face {
                        font-family: mcgaFontBold;
                        src: url(./assets/fonts/AvenirBlack.ttf);
                    }

                    * {
                        font-family: mcgaFont !important
                    }

                    .font-bold {
                        font-family: mcgaFontBold !important
                    }

                    body { font-size: 1.2rem}

                    .color-primary { color: #27374d !important }
                    .color-secondary { color: #545454 !important }
                    .color-accent { color: #ff9142 !important }
                    .color-lightgrey { color:rgb(161, 161, 161) !important }

                    .bg-orange { background-color: #ff9142 !important; }
                    .bg-lightorange { background-color: #ffe9db !important; border-radius: 10px; }
                    .bg-lightgrey { background-color: rgb(242, 242, 242) !important; border-radius: 10px; }
                    
                    .border-orange { border: 2px solid #ff9142 !important }
                    .border-lightorange { border: 2px solid #ffe9db !important }
                    .border-grey { border: 1px solid #545454 !important }
                    .border-lightgrey { border: 2px solid rgb(218, 218, 218) !important }

                    h1 > span:nth-of-type(2) { color: #ff9142 !important; background-color: #ffe9db; border-radius: 15px;}
                    .badge { font-size: 1rem !important }
                    .small { font-size: 0.7rem !important }
                    th { color: #ff9142 !important; font-size: 1.4rem !important }
                    @keyframes pulse {
                        0% { transform: scale(1); }
                        50% { transform: scale(1.1); }
                        100% { transform: scale(1); }
                    }
                    .icon-pulse { display: inline-block; animation: pulse 2s infinite; }
                    .rounded { border-radius: 15px !important; }
                    button.active { color: #ff9142 !important }
                    .accordion-button:not(.collapsed) { background-color: white !important; }
                    .pointer:hover { cursor: pointer}
                    .table-matrix td { border-right: 1px solid #ffe9db !important; border-bottom: 1px solid #ffe9db !important }
                    .table-matrix tr td:last-child { border-right: none !important; }
                    .table-matrix tr:last-child { border-bottom: none !important; }
              </style>
              <title>&#9889; Conditional Access Validator</title>
            </head>
            <body>
              <div class="container mt-5 mb-5 position-relative">
                <h1 class="mb-0 text-center font-bold color-primary"> 
                    <span class="icon-pulse">&#9889;</span> Conditional Access 
                    <span class="font-bold color-white px-2 py-0 ">Validator</span>
                </h1>
                <p class="text-center mt-3 mb-2 color-secondary">Part of the <a href="https://jbaes.be/Conditional-Access-Blueprint" target="_blank" class="font-bold color-secondary">Conditional Access Blueprint</a> framework</p>
                <i class="bi bi-question-circle position-absolute pointer color-secondary" style="top: 10px; right: 10px;" data-bs-toggle="modal" data-bs-target="#infoModal"></i>

                <div class="modal fade" id="infoModal" tabindex="-1" aria-labelledby="exampleModalLabel" aria-hidden="true">
                    <div class="modal-dialog modal-lg modal-dialog-centered modal-dialog-scrollable">
                        <div class="modal-content">
                            <div class="modal-header">
                                <h1 class="modal-title fs-5 font-bold">About the Conditional Access Validator</h1>
                                <button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="Close"></button>
                            </div>
                            <div class="modal-body">
                                <p>The goal of the Conditional Access Validator is to help you automatically validate the effectiveness of a Conditional Access setup.</p>
                                
                                <div class="alert alert-warning d-flex align-items-center fade show" role="alert">
                                    <i class="bi bi-exclamation-circle me-4"></i>
                                    <div class="">
                                        <p class="mb-0">This project is <span class="font-bold">open-source</span> and may contain errors, bugs or inaccuracies. If so, please create an <a href="https://github.com/jasperbaes/Conditional-Access-Validator/issues" target="_blank" class="font-bold color-secondary">issue</a>. No one can be held responsible for any issues arising from the use of this project. </p>
                                    </div>
                                </div>

                                <p>The tool creates a set of Maester tests based on the current Conditional Access setup of the tenant, rather than the desired state. Therefore, the output might need adjustments to accurately represent the desired state.</p>
                                
                                <hr class="mt-3 mb-3 w-100"/>

                                <p>Here's how you can contribute to our mission:</p>

                                <ul>
                                    <li class="color-accent font-bold mb-0 mt-2">Use it: <span class="text-dark">Use the tool and other referenced tools of the <a class="color-secondary font-bold" href="https://jbaes.be/Conditional-Access-Blueprint" target="_blank">Conditional Access Blueprint</a>! That's why they were build.</span></li>
                                    <li class="color-accent font-bold mb-0 mt-2">Talk about it: <span class="text-dark">Engage in discussions about this, or invite me to spreak about the tool.</span></li>
                                    <li class="color-accent font-bold mb-0 mt-2">Feedback or share ideas: <span class="text-dark">Have ideas or suggestions to improve this tool? Message me on <a class="font-bold color-secondary" href="https://www.linkedin.com/in/jasper-baes" target="_blank">LinkedIn</a> (Jasper Baes)</span></li>
                                    <li class="color-accent font-bold mb-0 mt-2">Contribute: <span class="text-dark">Join efforts to improve the quality, code and usability of this tool.</span></li>
                                    <li class="color-accent font-bold mb-0 mt-2">Donate: <span class="text-dark">Consider supporting financially to cover costs (domain name, hosting, development costs, time, production costs, professional travel, ...) or future investments: donate on</span>
                                        <div class="mt-2">
                                            <a class="font-bold" href="https://www.buymeacoffee.com/jasperbaes" target="_blank"><button type="button" class="btn bg-orange text-white font-bold mb-3">☕ Buy Me A Coffee</button></a>
                                        </div>    
                                    </li>
                                </ul>
                                <p class="small text-secondary">The Conditional Access Validator was developed entirely on my own time, without any support or involvement from any organization or employer.</p>
                                <p class="small text-secondary">Please be aware that this project is only allowed for use by organizations seeking financial gain, on 2 conditions: 1. this is communicated to me over LinkedIn, 2. the header and footer of the HTML report is unchanged. Colors can be changed. Other items can be added.</p>
                                <p class="small text-secondary">Thank you for respecting these usage terms and contributing to a fair and ethical software community. </p>
                            </div>
                        </div>
                    </div>
                </div>

                <div class="d-flex justify-content-center mt-4">
                    <div class="row w-75">
                        <div class="col-4">
                            <div class="px-3 pt-4 pb-3 bg-white rounded border-lightorange" style="line-height: 0.5;"> 
                                <p class="font-bold my-0 fs-1 color-accent">$($conditionalAccessPolicies.count)<p>
                                <p class="font-bold my-0 fs-6 color-lightgrey">Conditional Access policies</p>
                            </div>
                        </div>
                        <div class="col-4">
                            <div class="px-3 pt-4 pb-3 bg-white rounded border-lightorange" style="line-height: 0.5;">
                                <p class="font-bold my-0 fs-1 color-accent">$($MaesterTests.count)<p>
                                <p class="font-bold my-0 fs-6 color-lightgrey">generated Maester tests</p>
                            </div>
                        </div>
                        <div class="col-4">
                            <div class="px-3 pt-4 pb-3 bg-white rounded border-lightorange" style="line-height: 0.5;">
                                <p class="font-bold my-0 fs-1 color-accent">$($minutes)<span class="fs-6">m</span>$($seconds)<span class="fs-6">s</span><p>
                                <p class="font-bold my-0 fs-6 color-lightgrey">time to generate</p>
                            </div>
                        </div>
                    </div>
                </div>
                               
                <p class="text-center mt-3 mb-5 small text-secondary">Generated on $($datetime) for $($ORGANIZATIONNAME)</p>
"@        

# Show alert to update to new version
if ($UPTODATE -eq $false) {
    $template += @"

    <div class="alert alert-danger d-flex align-items-center alert-dismissible fade show" role="alert">
        <i class="bi bi-exclamation-circle me-3"></i>
        <div>
            <span class="font-bold">Update available!</span> Run 'git pull' to update from <em>$($CURRENTVERSION)</em> to <em>$($LATESTVERSION)</em>.
        </div>
        <button type="button" class="btn-close small mt-1" data-bs-dismiss="alert" aria-label="Close"></button>
    </div>
"@   
}

$template += @"

    <ul class="nav nav-tabs justify-content-center" id="myTab" role="tablist">
        <li class="nav-item" role="presentation">
            <button class="nav-link color-secondary font-bold px-4 active" id="code-tab" data-bs-toggle="tab" data-bs-target="#code-tab-pane" type="button" role="tab" aria-controls="code-tab-pane" aria-selected="true">Maester Code</button>
        </li>
        <li class="nav-item" role="presentation">
            <button class="nav-link color-secondary font-bold px-4" id="table-tab" data-bs-toggle="tab" data-bs-target="#table-tab-pane" type="button" role="tab" aria-controls="table-tab-pane" aria-selected="false">Simulation List</button>
        </li>
        <li class="nav-item" role="presentation">
            <button class="nav-link color-secondary font-bold px-4" id="flow-tab" data-bs-toggle="tab" data-bs-target="#flow-tab-pane" type="button" role="tab" aria-controls="flow-tab-pane" aria-selected="false">Flow Chart</button>
        </li>
        <li class="nav-item" role="presentation">
            <button class="nav-link color-secondary font-bold px-4" id="matrix-tab" data-bs-toggle="tab" data-bs-target="#matrix-tab-pane" type="button" role="tab" aria-controls="matrix-tab-pane" aria-selected="false">User Impact Matrix</button>
        </li>
        <li class="nav-item" role="presentation">
            <button class="nav-link color-secondary font-bold px-4" id="persona-report-tab" data-bs-toggle="tab" data-bs-target="#persona-report-tab-pane" type="button" role="tab" aria-controls="persona-report-tab-pane" aria-selected="true">Persona Report</button>
        </li>
    </ul>

    <div class="tab-content" id="myTabContent">
      <div class="tab-pane fade show active" id="code-tab-pane" role="tabpanel" aria-labelledby="code-tab" tabindex="0">
            <div class="position-relative">
                <pre class="bg-lightgrey mt-3 px-5 py-0 border-lightgrey rounded">
                    <code id="templateMaester">
                        $($templateMaester)
                    </code>
                </pre>
                <div class="row position-absolute top-0 end-0 m-3"> 
                    <button class="btn btn-secondary col me-2 rounded" id="liveToastBtn" data-bs-toggle="tooltip" data-bs-title="Click to copy to clipboard">
                        <i class="bi bi-copy"></i>
                    </button>
                    <button class="btn btn-secondary col rounded" id="liveToastBtnDownload" data-bs-toggle="tooltip" data-bs-title="Click to download into your Maester project">
                        <i class="bi bi-download"></i>
                    </button>
                </div>
            </div>
            
            <div class="toast-container position-fixed bottom-0 end-0 p-3">
                <div id="liveToast" class="toast text-bg-secondary" role="alert" aria-live="assertive" aria-atomic="true">
                    <div class="toast-body font-bold">$($MaesterTests.count) Maester tests copied to clipboard!</div>
                </div>
            </div>
        </div>

        <div class="tab-pane fade show" id="table-tab-pane" role="tabpanel" aria-labelledby="table-tab" tabindex="1">
            <div class="accordion" id="accordionExample">
"@

$index = 0
foreach ($MaesterTest in $MaesterTests) { 
    $template += @"
        <div class="accordion-item">
            <h2 class="accordion-header">
                <button class="accordion-button font-bold text-secondary" type="button" data-bs-toggle="collapse" data-bs-target="#collapse$index" aria-expanded="true" aria-controls="collapse$index">
                    $($MaesterTest.testTitle)
"@                

if ($MaesterTest.inverted) {
    $template += @"
        <span class="badge rounded-pill bg-lightorange color-accent border-orange position-absolute end-0 me-5">no $($MaesterTest.expectedControl)</span>
"@   
} else {
    $template += @"
        <span class="badge rounded-pill bg-lightorange color-accent border-orange position-absolute end-0 me-5">$($MaesterTest.expectedControl)</span>
"@ 
}
              
    $template += @"
                </button>
            </h2>
            <div id="collapse$index" class="accordion-collapse collapse" data-bs-parent="#accordionExample">
                <div class="accordion-body">
                    <table class="table table-responsive table-sm fs-6 text-secondary">
                        <tbody class="text-secondary">
                            <tr>
                                <td>Conditional Access policy</td>
                                <td>$($MaesterTest.CAPolicyName)</td>
                            </tr>
                            <tr>
                                <td>Conditional Access policy ID</td>
                                <td>$($MaesterTest.CAPolicyID)</td>
                            </tr>
                             <tr>
                                <td>Expected control</td>
"@

                            if ($MaesterTest.inverted) { 
                                $template += "<td>no $($MaesterTest.expectedControl)</td>"
                            } else {
                                $template += "<td>$($MaesterTest.expectedControl)</td>"
                            }

$template += @"
                            </tr>
                             <tr>
                                <td>User ID</td>
                                <td>$($MaesterTest.userID)</td>
                            </tr>
                             <tr>
                                <td>UPN</td>
                                <td>$($MaesterTest.UPN)</td>
                            </tr>
                             <tr>
                                <td>Application</td>
                                <td>$($MaesterTest.appName)</td>
                            </tr>
                             <tr>
                                <td>Application ID</td>
                                <td>$($MaesterTest.appID)</td>
                            </tr>
                            
                             <tr>
                                <td>Client application</td>
                                <td>$($MaesterTest.clientApp)</td>
                            </tr>
                             <tr>
                                <td>IP range</td>
                                <td>$($MaesterTest.IPRange)</td>
                            </tr>
                             <tr>
                                <td>Device Platform</td>
                                <td>$($MaesterTest.devicePlatform)</td>
                            </tr>
                            <tr>
                                <td>User risk</td>
                                <td>$($MaesterTest.userRisk)</td>
                            </tr>
                            <tr>
                                <td>Signin risk</td>
                                <td>$($MaesterTest.signInRisk)</td>
                            </tr>
                             <tr>
                                <td>User action</td>
                                <td>$($MaesterTest.userAction)</td>
                            </tr>
                        </tbody>
                    </table>
                </div>
            </div>
        </div>

"@
$index++
}


$template += @"
            </div>
        </div> 

        <div class="tab-pane fade show" id="flow-tab-pane" role="tabpanel" aria-labelledby="flow-tab" tabindex="2"> 
            <p class="small text-secondary mt-3 mb-1">If the chart below doesn't load, please refresh with this button:</p>
            <button class="btn btn-secondary rounded" onclick="refreshAllIframes()"  data-bs-toggle="tooltip" data-bs-title="Click to refresh the iframe">
                <i class="bi bi-arrow-clockwise ms-2"></i>
                Refresh 
            </button>
            <iframe class="mt-3 rounded" id="jsoncrackEmbed" src="https://jsoncrack.com/widget" width="100%" height="800px"></iframe>
        </div>
        
        <div class="tab-pane fade show" id="matrix-tab-pane" role="tabpanel" aria-labelledby="matrix-tab" tabindex="3">
            <a href="$($filenameTemplate).csv" target="_blank" class="btn bg-orange text-white rounded mt-2">
                <i class="bi bi-download me-2 ms-1"></i>
                Download full CSV ($($userImpactMatrix.count) users)
            </a>

            <button class="btn bg-orange text-white rounded mt-2" id="downloadPoliciesJsonBtn">
                    <i class="bi bi-download me-2 ms-1"></i>
                    Download all Conditional Access policies (JSON)
            </button>

            <table class="small table-matrix">
                <thead>
                    <tr>
"@                

foreach ($columnName in $columnNames) { 
    $template += @"
        <td class="p-2 font-bold">$($columnName)</td>
"@
}


$template += @"
                    </tr>
                </thead>
                <tbody>
"@   

foreach ($userImpactRow in ($userImpactMatrix | Select-Object -First 10)) {
    $template += "<tr>`n"

    foreach ($item in $userImpactRow.Values) {
        if ($item -eq $true) {
            $template += '    <td class="text-center p-2"> <i class="bi bi-check-circle-fill text-success"></i> </td>'
        } elseif ($item -eq $false) {
            $template += '    <td class="text-center p-2"> <i class="bi bi-x-circle-fill text-danger"></i> </td>'
        } else {
            $template += '   <td class="p-2"> ' + $item + ' </td>'
        }
    }

    $template += "</tr>`n"
}

     
$template += @"
                </tbody>
            </table>

            <p class="mt-5 mb-1"><i class="bi bi-check-circle-fill text-success me-3"></i>The user is included in the Conditional Access policy</p>
            <p><i class="bi bi-x-circle-fill text-danger me-3"></i>The user is excluded from the Conditional Access policy</p>

            <p class="mt-4 mb-1 font-bold">Next steps:</p>
            <ol>
                <li>Download and open the full CSV</li>
                <li>Select the full A column</li>
                <li>Go to the tab 'Data' and click 'Text to Columns'</li>
                <li>Select 'Delimited' and click Next</li>
                <li>Only select 'Comma' and click Finish</li>
                <li>Click on any cell with text and click 'Filter' in the 'Data' tab</li>
                <li><span class="font-bold">Review by filtering</span> 1 or multiple columns, or search in columns</li>
                <li>Add Conditional Formatting rules for coloring 'TRUE' and 'FALSE'</li>
            </ol>
        </div>

        <div class="tab-pane fade show" id="persona-report-tab-pane" role="tabpanel" aria-labelledby="persona-report-tab" tabindex="4">
            <p class="text-secondary mt-3 mb-3">The primary goal of the <a class="color-secondary" href="https://jbaes.be/Conditional-Access-Blueprint" target="_blank">Conditional Access Blueprint</a> approach is to use a static set Conditional Access policies and only add/remove personas (=Entra groups) as needed. This report shows the personas per CA policy: </p> 

            <table class="table mb-5">
                    <thead>
                        <tr class="font-bold">
                            <th scope="col" class="font-bold">Conditional Access policy</th>
                            <th scope="col" class="font-bold">Included personas</th>
                            <th scope="col" class="font-bold">Excluded personas</th>
                        </tr>
                    </thead>

"@

foreach ($result in $PersonaReport) {
    $template += @"
        <tr>
            <td scope="col" class="font-bold color-secondary align-middle">$($result.policyName)
            <span class="badge rounded-pill text-bg-light small color-secondary bg-lightgrey">$($result.policyState)</span>
        </td>
        <td scope="col">
"@

    if ($RemovePersonaURL -eq "") {
        $usedRemovePersonaURL = "https://entra.microsoft.com/#view/Microsoft_AAD_ConditionalAccess/PolicyBlade/policyId/$($result.policyID)"
    } else {
        $usedRemovePersonaURL = $RemovePersonaURL
    }

    if ($AddPersonaURL -eq "") {
        $usedAddPersonaURL = "https://entra.microsoft.com/#view/Microsoft_AAD_ConditionalAccess/PolicyBlade/policyId/$($result.policyID)"
    } else {
        $usedAddPersonaURL = $AddPersonaURL
    }

    foreach ($includedGroup in $result.includedGroups) {
        $template += @"
        <div class="mt-1 mb-1">
            <a href="https://entra.microsoft.com/#view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/Overview/groupId/$($includedGroup.groupID)" target="_blank" class="badge rounded-pill bg-lightorange color-accent border-orange position-relative text-decoration-none" data-bs-toggle="tooltip" data-bs-title="The Entra group '$($includedGroup.groupName)' has $($includedGroup.memberCount) member(s). Click to open the group in the Entra Portal.">
                $($includedGroup.groupName)
                <span class="position-absolute top-0 start-100 translate-middle badge rounded-pill text-white small" style="background-color: #ff9142 !important;">
                    $($includedGroup.memberCount)
                </span>
            </a>
            <a href="$($usedRemovePersonaURL)" target="_blank"><i class="bi bi-x ms-2 mt-1 color-accent" data-bs-toggle="tooltip" data-bs-title="Remove the Persona '$($includedGroup.groupName)' from the Conditional Access Policy '$($result.policyName)'."></i></a>
        </div>
"@    
    }

    $template += @"
                    <a href="$($usedAddPersonaURL)" target="_blank"><i class="bi bi-plus color-lightgrey" data-bs-toggle="tooltip" data-bs-title="Add a Persona to be included in the Conditional Access Policy '$($result.policyName)'."></i></a>
                </td>
                <td scope="col">
"@

    foreach ($excludedGroup in $result.excludedGroups) {
        $template += @"
        <div class="mt-1 mb-1">
            <a href="https://entra.microsoft.com/#view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/Overview/groupId/$($excludedGroup.groupID)" target="_blank" class="badge rounded-pill bg-lightorange color-accent border-orange position-relative text-decoration-none" data-bs-toggle="tooltip" data-bs-title="The Entra group '$($excludedGroup.groupName)' has $($excludedGroup.memberCount) member(s). Click to open the group in the Entra Portal.">
                $($excludedGroup.groupName)
                <span class="position-absolute top-0 start-100 translate-middle badge rounded-pill text-white small" style="background-color: #ff9142 !important;">
                    $($excludedGroup.memberCount)
                </span>
                <a href="$($usedRemovePersonaURL)" target="_blank"><i class="bi bi-x ms-2 mt-1 color-accent" data-bs-toggle="tooltip" data-bs-title="Remove the Persona '$($excludedGroup.groupName)' from the Conditional Access Policy '$($result.policyName)'."></i></a>
            </a>
        </div>
"@    
}

$template += @"
                    <a href="$($usedAddPersonaURL)" target="_blank"><i class="bi bi-plus color-lightgrey" data-bs-toggle="tooltip" data-bs-title="Add a Persona to be excluded from the Conditional Access Policy '$($result.policyName)'."></i></a>
                </td>
                <td scope="col">
"@
}
                
$template += @"
            </table>                 

            <hr class="mt-5 mb-5"/>
            <h5 class="font-bold color-secondary mb-2 mt-2">Entra Nested Groups Visualization</h5>
            <p>This visualization shows the nested groups in your Entra tenant. It can be used to understand the group (a.k.a persona) hierarchy in Conditional Access and how groups are nested within each other.</p>
            <p class="small text-secondary mt-3 mb-1">If the chart below doesn't load, please refresh with this button:</p>
            <button class="btn btn-secondary rounded" onclick="refreshAllIframes()"  data-bs-toggle="tooltip" data-bs-title="Click to refresh the iframe">
                <i class="bi bi-arrow-clockwise ms-2"></i>
                Refresh 
            </button>
            <iframe class="mt-3 rounded" id="nestedGroupsJsoncrackEmbed" src="https://jsoncrack.com/widget" width="100%" height="800px"></iframe>
        </div> 
"@

$template += @"
            <p class="text-center mt-5 mb-0"><a class="color-primary font-bold text-decoration-none" href="https://github.com/jasperbaes/Conditional-Access-Validator" target="_blank">&#9889;Conditional Access Validator</a>, made by <a class="color-accent font-bold text-decoration-none" href="https://www.linkedin.com/in/jasper-baes" target="_blank">Jasper Baes</a></p>
            <p class="text-center mt-1 mb-0 small"><a class="color-secondary" href="https://github.com/jasperbaes/Conditional-Access-Validator" target="_blank">https://github.com/jasperbaes/Conditional-Access-Validator</a></p>
            <p class="text-center mt-1 mb-5 small">This tool is part of the <a class="color-secondary font-bold" href="https://jbaes.be/Conditional-Access-Blueprint" target="_blank">Conditional Access Blueprint</a>. Read the <a class="color-secondary font-bold" href="https://github.com/jasperbaes/Conditional-Access-Validator?tab=readme-ov-file#-license" target="_blank">license</a> for info about organizational profit-driven.</p>
"@                     

$template += @"
            <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.2.3/dist/js/bootstrap.bundle.min.js" integrity="sha384-kenU1KFdBIe4zVF0s0G1M5b4hcpxyD9F7jL+jjXkk+Q2h455rYXK/7HAuoJl+0I4" crossorigin="anonymous"></script>
            <script>
                const toastTrigger = document.getElementById('liveToastBtn')
                const toastLiveExample = document.getElementById('liveToast')

                if (toastTrigger) {
                    const toastBootstrap = bootstrap.Toast.getOrCreateInstance(toastLiveExample)
                    toastTrigger.addEventListener('click', () => {
                        // Get the content of the code element
                        var codeContent = document.getElementById('templateMaester').textContent;

                        // Create a temporary textarea element
                        var tempTextarea = document.createElement('textarea');
                        tempTextarea.value = codeContent;
                        document.body.appendChild(tempTextarea);
                        
                        // Select the content of the textarea
                        tempTextarea.select();
                        tempTextarea.setSelectionRange(0, 99999);

                        // Copy the selected content to the clipboard
                        document.execCommand('copy');

                        // Remove the temporary textarea element
                        document.body.removeChild(tempTextarea);
                    
                        toastBootstrap.show()
                    })
                }

                const downloadTrigger = document.getElementById('liveToastBtnDownload');

                if (downloadTrigger) {
                    downloadTrigger.addEventListener('click', () => {
                        // Get the content of the code element
                        var codeContent = document.getElementById('templateMaester').textContent;

                        // Create a Blob with the code content
                        var blob = new Blob([codeContent], { type: 'text/plain' });

                        // Create a temporary anchor element
                        var downloadLink = document.createElement('a');
                        downloadLink.href = URL.createObjectURL(blob);
                        downloadLink.download = 'CA.Tests.ps1';

                        // Append the anchor, trigger the download, then remove it
                        document.body.appendChild(downloadLink);
                        downloadLink.click();
                        document.body.removeChild(downloadLink);
                    });
                }

                const jsonCrackEmbed = document.querySelector("#jsoncrackEmbed");
                let json = JSON.stringify($CAjsonRaw);
                let options = { theme: "light" };

                // NestedGroups JSON Crack injection
                const nestedGroupsJsoncrackEmbed = document.querySelector("#nestedGroupsJsoncrackEmbed");
                let nestedGroupsJson = JSON.stringify($NestedGroupsJsonRaw);

                // Inject JSON only after iframe loads, not on every message event
                if (jsonCrackEmbed) {
                    jsonCrackEmbed.onload = function() {
                        jsonCrackEmbed.contentWindow.postMessage({ json, options }, "*");
                    };
                }
                if (nestedGroupsJsoncrackEmbed) {
                    nestedGroupsJsoncrackEmbed.onload = function() {
                        nestedGroupsJsoncrackEmbed.contentWindow.postMessage({ json: nestedGroupsJson, options }, "*");
                    };
                }

                const tooltipTriggerList = document.querySelectorAll('[data-bs-toggle="tooltip"]')
                const tooltipList = [...tooltipTriggerList].map(tooltipTriggerEl => new bootstrap.Tooltip(tooltipTriggerEl))


                function refreshAllIframes() {
                    const iframes = document.querySelectorAll('iframe');
                    iframes.forEach(iframe => {
                        iframe.src = iframe.src;
                    });
                }

                // Policy documentation download button
                const downloadPoliciesJsonBtn = document.getElementById('downloadPoliciesJsonBtn');
                if (downloadPoliciesJsonBtn) {
                    downloadPoliciesJsonBtn.addEventListener('click', function() {
                        // The JSON string is injected below
                        var policiesJson = JSON.stringify($conditionalAccessPoliciesRaw);
                        var blob = new Blob([policiesJson], { type: 'application/json' });
                        var downloadLink = document.createElement('a');
                        downloadLink.href = URL.createObjectURL(blob);
                        downloadLink.download = 'ConditionalAccessPolicies.json';
                        document.body.appendChild(downloadLink);
                        downloadLink.click();
                        document.body.removeChild(downloadLink);
                    });
                }

            </script>
        </body>
    </html>
"@

$template | Out-File -FilePath "$filenameTemplate.html"
Start-Process "$filenameTemplate.html"
Write-OutputSuccess "Report available at: '$filenameTemplate.html'`n"
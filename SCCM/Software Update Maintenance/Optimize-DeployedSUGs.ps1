#REQUIRES -Version 4.0
<#
.Synopsis
   Optimize-DeployedSUGs
.DESCRIPTION
   Script is meant to Optimize Deployed Software Update Groups (SUGs). It is built to ensure updates in SUGs are valid. It also ensures 
    Deployment Packages only contains valid updates, avoiding misusage of WAN/LAN links. Additionally, script will also remove deployments for test collections,
    reducing amount of policy to be processed by a SCCM Client.
   
   Starting concepts:
    -> Monthly SUG -> Software Update Groups generated monthly by an Automatic Deployment Rule (ADR) or Administrator (Manual process).
    -> Aged SUG    -> Software Update Group meant to contain old, but valid, updates. An Aged SUG will contain updates 
        that are likely either embedded in Organization's WIM or are deployed for such a long time that its deployment is considered complete, but for compliance
        purposes, requires tracking and compliance. 
    -> Monthly Deployment Package -> Package meant to host content for recently deployed updates. It is expected to have a High Priority Distribution Setting in SCCM.
    -> Aged Deployment Package -> Package meant to host content for old, but valid updates. It is expected to have a Medium Priority Distribution Setting in SCCM.
   
   Starting from a set of basic information (INPUT Section below), it will evaluate all Software Update Groups meeting the criteria defined.
   
       If an update is expired, it will be removed.
       If an update is superseded and its Post Date is older than $timeMonthSuperseded, it will be removed.
       If an update is valid (not superseded nor expired) and its Post Date is older than $timeAgedUpd, it will be removed from Monthly SUG and moved into Aged SUG
       If an update is missing in a Deployment Package, it will be downloaded.
       If an update is no longer needed in a Deployment Package, it will be deleted.
       SUGS to be evaluated must meet $sTemplateName name criteria
       Deployment Packages to be evaluated must meet $sTemplateName criteria
       SUG Deployments older than $timeMonthSuperseded must meet $sFinalCollection criteria to avoid deletion

   INPUT: Is managed in the "Script Specific variables" under the "$Scope" switch. If desired, info can be added to switch block and "$Scope" parameter.
    Such action will script to run with Action "Auto-Run" in a more automated manner.
        
        => Information to be added in Switch block. If any is missing, Administrator will be required to add during script execution.
        -> SMS Provider Server Name: Server running SMSProvider. Usually, but not always, is the Central Site Server or the Primary Site Server
        -> SCCM SiteCode: Site code in which Actions are targeted to
        -> TemplateName: <TemplateName> will act as a filter to target only desired SUGS/Deployment Packages/ADRs
            e.g.: TemplateName = "Server-" 
                Script will look for Deployment packages "Server-Monthly" and "Server-Aged". If they are not found, they will be created.
                Script will look for SUGS names "Server-ADR YYYY-MM-DD HH:MM" These will be considered "Monthly SUGs"
                Script will expect SUG Server-Aged. If it is not found, it will create it.
        -> FinalCollection: Collection(s) names which are considered "Final Deployment"
            e.g.: FinalCollectioon = @("Ring4","OutOfScope")
                Within SUG list (filtered by TemplateName AND Superseded Threshold), script will look for any deployment to a collection that does not 
                meet "FinalCollection" criteria. If found, deployment is deleted.
                If a SUG Create Date is lesser than supersede threshold, no action will be taken towards "Initial" Deployments
        -> Superseded Threshold: How many days, after an update is posted, it is valid to be removed due to being superseded. Value recommendation is amount of days
            required to reach compliance KPI.
            e.g.: On average, internal KPI (95%) is reached within 20 days after Patch Tuesday -> Set Superseded Threshold to 20
        -> Aged Threshold: How many days, after an update is posted, it takes for an update to find its way into company's load process "WIM".
            e.g.: New WIMs are generated yearly. Set Aged Threshold to 365
            
    All actions will be recorded in SCCM Server Logs folder under the name "Optimize-DeployedSUGs.log"

.EXAMPLE
   .\Optimize-DeployedSUGs.ps1
        -> IMPLIED PARAMETER: -Scope Other    -> Script will ask additional information in order to execute
        -> IMPLIED PARAMETER: -Action Check   -> Script will not take maintenance actions. Some action might be required (create SUGs or Create Deployment Packages).        
.EXAMPLE
   .\Optimize-DeployedSUGs.ps1 -Scope MySCCM -Action Run
        -> PARAMETER: -Scope MySCCM   -> Script will use information listed under "MySCCM" variable block. Additional information might be required in order 
            to execute
        -> PARAMETER: -Action Run     -> Script will take maintenance actions, deleting/downloading updates, moving updates between SUGs, deleting SUGs.                 
.EXAMPLE
   .\Optimize-DeployedSUGs.ps1 -Scope MySCCM -Action Auto-Run
        -> PARAMETER: -Scope MySCCM   -> Script will use information listed under "MySCCM" variable block.
        -> PARAMETER: -Action Auto-Run-> Script will take maintenance actions, deleting/downloading updates, moving updates between SUGs, deleting SUGs. 
            No additional information will be asked from Admin. Missing information will cause the script to abort.        
#>
param( 
    [ValidateSet("Check","Run","Auto-Run")][string]$Action="Check",
    [ValidateSet("CAS","VAR","PVA","Other")][string]$Scope="Other"
)
# --------------------------------------------------------------------------------------------
#region HEADER
$SCRIPT_TITLE = "Optimize-DeployedSUGs"
$SCRIPT_VERSION = "1.0"

$ErrorActionPreference 	= "Continue"	# SilentlyContinue / Stop / Continue

# -Script Name: Optimize-DeployedSUGs.ps1------------------------------------------------------ 
# Based on PS Template Script Version: 1.0
# Author: Jose Varandas

# Credits: Credit to Tevor Sullivan. Modified from his original for use here.
#          http://trevorsullivan.net/2011/11/29/configmgr-cleanup-software-updates-objects/
#            ->Test-SCCMUpdateAge
#            ->Test-SccmUpdateExpired
#            ->Test-SccmUpdateSuperseded
#          Credit to Steve Rachui. Modified from his original for use here.
#          https://blogs.msdn.microsoft.com/steverac/2014/06/11/automating-software-updates/
#            ->MaintainSoftwareUpdateGroupDeploymentPackages
#            ->EvaluateNumberOfUpdatesinGRoups
#            ->SingleUpdateGroupMaintenance
#            ->UpdateGroupPairMaintenance
#            ->ReportingSoftwareUpdateGroupMaintenance
#
# Owned By: Jose Varandas
# Purpose: Ensure Deployed SUGs are optimized without expired or superseded KBs. 
# Aged KBs are to be moved into lower priority package, allowing monthly package to be as small as possible.
#
# Dependencies: 
#                ID running script must be SCCM administrator
#                SCCM Powershell Module
#                ID running script must be able to reach SMSProviderWMI
#                Script must run locally in SMSProvider Server
#                SCCM Current Branch 1802 or higher
#
# Known Issues: 
#                During Package clean-up, WMI in SMSProvider might fail to delete content if inconsistencies are found. Script will try another 5 times an
#                if it is unable to complete, it will proceed remaining maintenance actions. Script will exit with specific error code and log respective
#                Windows Event. 
#
# Arguments: 
Function Show-ScriptUsage(){
    Write-Log -sMessage "============================================================================================================================" -iTabs 1            
    Write-Log -sMessage "NAME:" -iTabs 1
        Write-Log -sMessage ".\$sScriptName " -iTabs 2     
    Write-Log -sMessage "============================================================================================================================" -iTabs 1            
    Write-Log -sMessage "ARGUMENTS:" -iTabs 1            
            Write-Log -sMessage "-Action (Check/Run/Auto-Run) -> Defines Script Execution Mode" -iTabs 3        
                Write-Log -sMessage "-> Check (Default)-> Script will run Pre-checks and Pos-Checks. No Execution" -iTabs 4        
                Write-Log -sMessage "-> Run -> Runs script (Pre-Checks,Excecution,Post-Checks)" -iTabs 4
                Write-Log -sMessage "-> Auto-Run -> Runs script accepting default options while running Pre-Checks,Excecution,Post-Checks" -iTabs 4
            Write-Log -sMessage "-Scope (CAS/VAR/PVA/Other) -> Defines which SCCM Scope will be targeted." -iTabs 3        
                Write-Log -sMessage "-> CAS: Script targets SCCM01.zlab.varandas.com as Central Server/WMIProvider and WKS-SecurityUpdates as naming convention" -iTabs 4                        
                Write-Log -sMessage "-> VAR: Script targets SCCM01.vlab.varandas.com as Central Server/WMIProvider and VAR as naming convention" -iTabs 4
                Write-Log -sMessage "-> PVA: Script targets SCCM01.plab.varandas.com as Central Server/WMIProvider and VAR as naming convention" -iTabs 4
                Write-Log -sMessage "-> Other: Script doesn't have a target server or naming convention and will require all info to be entered manually." -iTabs 4                   
    Write-Log -sMessage "============================================================================================================================" -iTabs 1            
    Write-Log -sMessage "EXAMPLE:" -iTabs 1
        Write-Log -sMessage ".\$sScriptName -Action Check -Scope CAS" -iTabs 2     
            Write-Log -sMessage "Script will run all Pre-Checks in CAS environment. No Changes will happen to the device. Action Argument will not be used with `"-Behavior Check`"" -iTabs 2     
        Write-Log -sMessage ".\$sScriptName -Action Run -Scope VAR" -iTabs 2     
            Write-Log -sMessage "Script will run all coded remediations, pre and  post checks in VAR Environment." -iTabs 2  
    Write-Log -sMessage "============================================================================================================================" -iTabs 1            
    Write-Log -sMessage "NOTE:" -iTabs 1
        Write-Log -sMessage "Action Auto-Run is not supported with Scope Other" -iTabs 2                 
    Write-Log -sMessage "============================================================================================================================" -iTabs 1            
#		
}
#endregion
#region EXIT_CODES
<# Exit Codes:
            0 - Script completed successfully

            3xxx - SUCCESS

            5xxx - INFORMATION
            5001 - User aborted script
            5002 - User aborted at Aged SUG Creation
            5003 - Script Started

            7xxx - WARNING
            7001 - Error while deleting empty SUG

            9XXX - ERROR
            9001 - Unable to load SCCM PS Module
            9002 - Wrong parameter usage
            9003 - Unable to access SCCM PS Location
            9004 - Unable to query ADRs in SCCM Environment
            9005 - Unable to query SUGs in SCCM Environment
            9006 - Error while creating SUG Aged
            9007 - Error while getting deployment packages
            9008 - Error while creating Deployment packages
            9009 - Error while querying updates from SCCM
            9010 - Error while reviewing Aged SUG
            9011 - Error while processing new SUG
            9012 - Error while processing stable SUG
            9013 - Error while processing aged SUG
            9999 - Unhandled Exception     

   
 Revision History: (Date, Author, Version, Changelog)
		2019/04/07 - Jose Varandas - 1.0			
           CHANGELOG:
               -> Script Created
#>							
# -------------------------------------------------------------------------------------------- 
#endregion
# --------------------------------------------------------------------------------------------
#region FUNCTIONS
Function Start-Log(){	
# --------------------------------------------------------------------------------------------
# Function Start-Log

# Purpose: Checks to see if a log file exists and if not, created it
#          Also checks log file size
# Parameters:
# Returns: None
# --------------------------------------------------------------------------------------------
    #Check to see if the log folder exists. If not, create it.
    If (!(Test-Path $sOutFilePath )) {
        New-Item -type directory -path $sOutFilePath | Out-Null
    }
    #Check to see if the log file exists. If not, create it
    If (!(Test-Path $sLogFile )) {
        New-Item $sOutFilePath -name $sOutFileName -type file | Out-Null
    }
	Else
	{
        #File exists, check file size
		$sLogFile = Get-Item $sLogFile
        
        # Check to see if the file is > 1 MB and purge if possible
        If ($sLogFile.Length -gt $iLogFileSize) {
            $sHeader = "`nMax file size reached. Log file deleted at $global:dtNow."
            Remove-Item $sLogFile  #Remove the existing log file
            New-Item $sOutFilePath -name $sOutFileName -type file  #Create the new log file
        }
    }
    Write-Log $sHeader -iTabs 0  
	Write-Log -sMessage "############################################################" -iTabs 0 
    Write-Log -sMessage "" -iTabs 0 
    Write-Log -sMessage "============================================================" -iTabs 0 	
    Write-Log -sMessage "$SCRIPT_TITLE ($sScriptName) $SCRIPT_VERSION - Start" -iTabs 0 -bEventLog $true -iEventID 5003 -sSource $sEventSource
	Write-Log -sMessage "============================================================" -iTabs 0 
	Write-Log -sMessage "Script Started at $(Get-Date)" -iTabs 0 
	Write-Log -sMessage "" -iTabs 0     
	Write-Log -sMessage "Variables:" -iTabs 0 
	Write-Log -sMessage "Script Title.....:$SCRIPT_TITLE" -iTabs 1 
	Write-Log -sMessage "Script Name......:$sScriptName" -iTabs 1 
	Write-Log -sMessage "Script Version...:$SCRIPT_VERSION" -iTabs 1 
	Write-Log -sMessage "Script Path......:$sScriptPath" -iTabs 1
	Write-Log -sMessage "User Name........:$sUserDomain\$sUserName" -iTabs 1
	Write-Log -sMessage "Machine Name.....:$sMachineName" -iTabs 1
	Write-Log -sMessage "Log File.........:$sLogFile" -iTabs 1
	Write-Log -sMessage "Command Line.....:$sCMDArgs" -iTabs 1
    Write-Log -sMessage "Arguments===================================================" -iTabs 0 
	Write-Log -sMessage "-DebugLog...:$DebugLog" -iTabs 1
    Write-Log -sMessage "-NoRelaunch.:$NoRelaunch" -iTabs 1 
    Write-Log -sMessage "-Action.....:$Action" -iTabs 1 
    Write-Log -sMessage "-Scope:$Scope" -iTabs 1    
	Write-Log -sMessage "============================================================" -iTabs 0    
}           ##End of Start-Log function
Function Write-Log(){
# --------------------------------------------------------------------------------------------
# Function Write-Log

# Purpose: Writes specified text to the log file
# Parameters: 
#    sMessage - Message to write to the log file
#    iTabs - Number of tabs to indent text
#    sFileName - name of the log file (optional. If not provided will default to the $sLogFile in the script
# Returns: None
# --------------------------------------------------------------------------------------------
    param( 
        [string]$sMessage="", 
        [int]$iTabs=0, 
        [string]$sFileName=$sLogFile,
        [boolean]$bTxtLog=$true,
        [boolean]$bConsole=$true,
        [string]$sColor="white",         
        [boolean]$bEventLog=$false,        
        [int]$iEventID=0,
        [ValidateSet("Error","Information","Warning")][string]$sEventLogType="Information",
        [string]$sSource=$sEventIDSource        
    )
    
    #Loop through tabs provided to see if text should be indented within file
    $sTabs = ""
    For ($a = 1; $a -le $iTabs; $a++) {
        $sTabs = $sTabs + "    "
    }

    #Populated content with timeanddate, tabs and message
    $sContent = "||"+$(Get-Date -UFormat %Y-%m-%d_%H:%M:%S)+"|"+$sTabs + "|"+$sMessage

    #Write content to the file
    if ($bTxtLog){
        Add-Content $sFileName -value  $sContent -ErrorAction SilentlyContinue
    }    
    #write content to Event Viewer
    if($bEventLog){
        try{
            New-EventLog -LogName Application -Source $sSource -ErrorAction SilentlyContinue
            if ($iEventID -gt 9000){
                $sEventLogType = "Error"
            }
            elseif ($iEventID -gt 7000){
                $sEventLogType = "Warning"
            }
            else{
                $sEventLogType = "Information"
            }
            Write-EventLog -LogName Application -Source $sSource -EntryType $sEventLogType -EventId $iEventID -Message $sMessage -ErrorAction SilentlyContinue
        }
        catch{
            
        }
    }
    # Write Content to Console
    if($bConsole){        
            Write-Host $sContent -ForegroundColor $scolor        
    }
	
}           ##End of Write-Log function
Function Stop-Log(){
# --------------------------------------------------------------------------------------------
# Function EndLog
# Purpose: Writes the last log information to the log file
# Parameters: None
# Returns: None
# --------------------------------------------------------------------------------------------
    #Loop through tabs provided to see if text should be indented within file
	Write-Log -sMessage "" -iTabs 0 
    Write-Log -sMessage "$SCRIPT_TITLE ($sScriptName) $SCRIPT_VERSION Completed at $(Get-date) with Exit Code $global:iExitCode - Finish" -iTabs 0  -bEventLog $true -sSource $sEventSource -iEventID $global:iExitCode    
    Write-Log -sMessage "============================================================" -iTabs 0     
    Write-Log -sMessage "" -iTabs 0     
    Write-Log -sMessage "" -iTabs 0 
    Write-Log -sMessage "" -iTabs 0 
    Write-Log -sMessage "" -iTabs 0 
 
}             ##End of End-Log function
function ConvertTo-Array{
    begin{
        $output = @(); 
    }
    process{
        $output += $_;   
    }
    end{
        return ,$output;   
    }
}
#endregion
# --------------------------------------------------------------------------------------------
#region SUP-FUNCTIONS
Function Test-SccmUpdateExpired{
    param(
        [Parameter(Mandatory = $true)]
        $UpdateId,
        $ExpUpdates
    )
    
    # If the WMI query returns more than 0 instances (should NEVER be more than 1 at most), then the update is expired.
    if ($ExpUpdates -match $Updateid){            
        return $true
    }
    else{          
        return $false        
    }
}
Function Test-SccmUpdateSuperseded{
    param(
        [Parameter(Mandatory = $true)]
        $UpdateId,
        $SupUpdate
    )            
    If ($SupUpdate -match $UpdateId){            
        return $true
    }
    else{
        return $false
    }
}
Function Test-SCCMUpdateAge{
    param(
        [Parameter(Mandatory = $true)]
        $UpdateId,            
        $OldUpdates
    )
        
    If ($OldUpdates -match $UpdateId){            
        return $true
    }
    else{
        return $false
    }
}
Function Set-Sug{
# This script is designed to ensure consistent membership of the reporting software update group.
# In this version it is assumed there is only one reporting software update group.  A reporting software
# update group is assumed to never be deployed.  Accordingly, The script will first check to see if the 
# reporting software update group is deployed.  If so the script will display an error and exit.
# If no error then the updates in every other software update group will be reviewed and added to the
# reporting software update group.  There is no check to see if the update is already in the reporting
# software update group because if it is it won't be added twice.
    Param(
        [Parameter(Mandatory = $true)]
        $SiteServerName,
        [Parameter(Mandatory = $true)]
        $SiteCode,
        [Parameter(Mandatory = $true)]
        $SUGName,
        [Parameter(Mandatory = $false)]
        $updInSUG,
        [Parameter(Mandatory = $false)]
        $updNotInSUG
        )
    #finding updates that are in Rpt SUG but not in any Non-Rpt SUG
    $updToRemove = @()
    foreach ($update in $updInSUG){
        if (!($updNotInSUG -match $update)){
            $updToRemove += $update
            Write-Log -iTabs 5 "$update flagged for removal" -bConsole $true       
        }
    }
    #finding updates that aren't in Rpt SUG but are in any Non-Rpt SUG
    $updToAdd = @()
    foreach ($update in $updNotInSUG){
        if (!($updInSUG -match $update)){
            $updToAdd += $update      
            Write-Log -iTabs 5 "$update flagged for addition" -bConsole $true        
        }
    }
    #removing extra updates from SUG Rpt
    if ($updToRemove.Count -gt 0){        
        Write-Log -iTabs 4 "Removing $($updToRemove.Count) from $SUGName" -bConsole $true         
        if ($action -like "*Run"){
            Remove-CMSoftwareUpdateFromGroup -SoftwareUpdateId $updToRemove -SoftwareUpdateGroupName $SUGName -Force #-warningaction silentlycontinue
        }
        <#$updcnt=1
        foreach ($upd in $updToRemove){
            try{
                if ($action -like "*Run"){
                    Remove-CMSoftwareUpdateFromGroup -SoftwareUpdateId $upd -SoftwareUpdateGroupName $SUGName -Force -warningaction silentlycontinue
                }
                Write-Log -iTabs 5 "($updcnt/$($updToRemove.Count)) - Removed $upd from $SUGName" -bConsole $true
                $updcnt++
            }
            catch{
                Write-Log -iTabs 5 "Error while running Remove-CMSoftwareUpdateFromGroup" -bConsole $true -sColor Red                 
            }                
        }#>
        Write-Log -iTabs 5 "$($updToRemove.Count) updates removed from $SUGName" -bConsole $true -sColor Green                              
    }
    else{
        Write-Log -iTabs 4 "No updates to remove from $SUGName" -bConsole $true
    }
    #adding updates
    if ($updToAdd.Count -gt 0){        
        Write-Log -iTabs 4 "Adding $($updToAdd.Count) to $SUGName" -bConsole $true         
        if ($action -like "*Run"){
            Add-CMSoftwareUpdateToGroup -SoftwareUpdateId $updToAdd -SoftwareUpdateGroupName $SUGName -Force #-warningaction silentlycontinue               
        }
        <#
        $updcnt=1

        foreach ($upd in $updToAdd){ 
            try{       
                if ($action -like "*Run"){     
                    Add-CMSoftwareUpdateToGroup -SoftwareUpdateId $upd -SoftwareUpdateGroupName $SUGName -Force -warningaction silentlycontinue               
                }
                Write-Log -iTabs 5 "($updcnt/$($updToAdd.Count)) - Added $upd to $SUGName" -bConsole $true
                $updcnt++
            }
            catch{
                Write-Log -iTabs 5 "Error while running Add-CMSoftwareUpdateToGroup" -bConsole $true -sColor Red 
            }                
        }#>
        Write-Log -iTabs 5 "$($updToAdd.Count) updates added to $SUGName" -bConsole $true -sColor Green                 
    }
    else{
        Write-Log -iTabs 4 "No updates to add to $SUGName" -bConsole $true
    }
}
function Set-SUGPair{

    Param(
        [Parameter(Mandatory = $true)]
        $SiteProviderServerName,
        [Parameter(Mandatory = $true)]
        $SiteCode,
        [Parameter(Mandatory = $true)]
        $CurrentUpdateGroup,
        [Parameter(Mandatory = $true)]
        $CurUpdList,        
        $PersistentUpdateGroup,        
        $PerUpdList,
        [Parameter(Mandatory = $false)]  
        $HandleAgedUpdates=$false,               
        $aAgedUpdates, 
        [Parameter(Mandatory = $false)]
        $PurgeExpired=$false,        
        $aExpUpdates,
        [Parameter(Mandatory = $false)]
        $PurgeSuperseded=$false,
        $aSupersededUpdates,
        [Parameter(Mandatory = $false)]
        $pkgSusName,
        [Parameter(Mandatory = $false)]
        $pkgSusList=$false
        )
    # If Current and persistent SUGs are equal, exit
    If ($CurrentUpdateGroup -eq $PersistentUpdateGroup){
        write-host ("The Current and Persistent update groups are the same group.  This is not allowed.  Exiting")
        exit
    }         
    #starting arrays
    $updatesToRemove =@()
    $updatesToMove   =@()

    ForEach ($UpdateID in $CurUpdList){               
        If (($PurgeExpired) -and (Test-SccmUpdateExpired -UpdateID $UpdateID -ExpUpdates $aExpUpdates)){            
            Write-Log -iTabs 4 "(CI_ID:$UpdateId) Expired." -bConsole $true -sColor DarkGray
            $updatesToRemove += $updateID            
        }
        elseIf (($PurgeSuperseded) -and (Test-SCCMUpdateSuperseded -UpdateID $UpdateID -SupUpdate $aSupersededUpdates)){            
            Write-Log -iTabs 4 "(CI_ID:$UpdateId) Superseded." -bConsole $true -sColor DarkYellow
            $updatesToRemove += $updateID
        }
        elseIf (($HandleAgedUpdates) -and (Test-SCCMUpdateAge -UpdateID $UpdateID -OldUpdates $aAgedUpdates)){
            Write-Log -iTabs 4 "(CI_ID:$UpdateId) Aged." -bConsole $true -sColor DarkGreen
            $updatesToMove += $updateID
        }
        else{
            #Write-Log -iTabs 4 "(CI_ID:$UpdateId) valid." -bConsole $true
        }
    }
    #If Superseded or Expired updates were flagged, script will remove them now
    If ($updatesToRemove.Count -gt 0){
        Write-Log -iTabs 4 "Removing $($updatesToRemove.Count) updates from $CurrentUpdateGroup due to being Expired or Superseded" -bConsole $true         
        try{
            $updcnt=1            
            foreach ($upd in $updatesToRemove){
                if ($action -like "*Run"){ 
                    Remove-CMSoftwareUpdateFromGroup -SoftwareUpdateId $upd -SoftwareUpdateGroupName $CurrentUpdateGroup -Force
                }
                Write-Log -iTabs 5 "($updcnt/$($updatesToRemove.Count)) - Update $upd removed from $CurrentUpdateGroup" -bConsole $true
                $updcnt++
            }
            Write-Log -iTabs 5 "All $($updatesToRemove.Count) flagged updates removed from $CurrentUpdateGroup" -bConsole $true -sColor Green
        }
        catch{
            Write-Log -iTabs 5 "Error while running Remove-CMSoftwareUpdateFromGroup" -bConsole $true -sColor Red 
        }
    }        
    #If aged updates were flagged, script will check if they need to be downloaded to sustainer, add them to sustainer SUG and finally remove from current SUG
    If (($updatesToMove.Count -gt 0) -and ($HandleAgedUpdates)){
        # due to the sensitivity of this process, a controll variable will be used named "$proceed" once it enters any major loop it will get value as $false.
        # once major loop is completed without errors the variable will receive value $true, allowing next major loop to start
        Write-Log -iTabs 4 "Adding $($updatesToMove.Count) updates to $PersistentUpdateGroup due to being Aged" -bConsole $true            
        # checking if there is a need to download updates
        Write-Log -iTabs 5 "Checking if updates to be moved, have to be downloaded." -bConsole $true
        $updatesToDownload =@()
        $downloadUpd=$false
        foreach ($update in $updatesToMove){            
            if (!($pkgSusList.CI_ID -match $update)){
                $updatesToDownload += $update
                $downloadUpd=$true
            }
        }
        Write-Log -iTabs 5 "Found $($updatesToDownload.Count) updates to be downloaded." -bConsole $true
        # downloading updates if needed
        $proceed=$true
        if (($downloadUpd) -and ($proceed)){            
            $proceed=$false
            Write-Log -iTabs 5 "Downloading $($updatesToDownload.Count) updates." -bConsole $true
            $updcnt=0
            foreach ($upd in $updatesToDownload){
                try{                    
                    if ($action -like "*Run"){
                        Save-CMSoftwareUpdate -SoftwareUpdateId $upd -DeploymentPackageName $pkgSusName -SoftwareUpdateLanguage "English" -DisableWildcardHandling -WarningAction SilentlyContinue                         
                    }
                    $updcnt++
                    Write-Log -iTabs 6 "($updcnt/$($updatesToDownload.Count)) - Update $upd downloaded to $pkgSusName pkg." -bConsole $true                    
                }
                catch{            
                    Write-Log -iTabs 6 "Error Downloading $upd into $pkgSusName." -bConsole $true -sColor red                                        
                    $global:iExitCode = 9015                     
                }
            }
            
            Write-Log -iTabs 6 "$($updatesToDownload.Count) updates Downloaded into $pkgSusName." -bConsole $true -sColor Green
            if ($updcnt -eq $updatesToDownload.count){
                $proceed=$true
            }
        }
        else{
            Write-Log -iTabs 5 "No need to download updates at this moment." -bConsole $true
        }
        # Adding updates to Sustainer
        if (!($proceed)){
            Write-Log -iTabs 4 "Failure detected while downloading KBs into Sustainer. KB Move will not proceed." -bConsole $true -sColor red
        }
        else{
            $proceed=$false
            try{            
                Write-Log -iTabs 5 "Adding $($updatesToMove.Count) to Sustainer SUG." -bConsole $true
                $updcnt=0
                foreach ($upd in $updatesToMove){
                    if ($action -like "*Run"){  
                        Add-CMSoftwareUpdateToGroup -SoftwareUpdateId $upd -SoftwareUpdateGroupName $PersistentUpdateGroup -Force -WarningAction SilentlyContinue
                    }
                    $updcnt++
                    Write-Log -iTabs 5 "($updcnt/$($updatesToMove.Count)) - $upd added to $PersistentUpdateGroup." -bConsole $true                    
                }                
                Write-Log -iTabs 5 "$($updatesToMove.Count) updates added to $PersistentUpdateGroup" -bConsole $true -sColor Green
            }
            catch{
                Write-Log -iTabs 5 "Error while running Add-CMSoftwareUpdateToGroup" -bConsole $true -sColor Red 
                Write-Log -iTabs 5 "Aborting script." -bConsole $true -sColor red
                $global:iExitCode = 9015
                return $global:iExitCode
            }
            if ($updcnt -eq $updatesToMove.Count){
                $proceed=$true
            }  
        }              
        # removing updates from Monthly SUG
        if ($proceed){
            Write-Log -iTabs 4 "Removing $($updatesToMove.Count) from $CurrentUpdateGroup due to being Aged" -bConsole $true            
            $updcnt=1
            foreach ($upd in $updatesToMove){
                try{
                    if ($action -like "*Run"){  
                        Remove-CMSoftwareUpdateFromGroup -SoftwareUpdateId $upd -SoftwareUpdateGroupName $CurrentUpdateGroup -Force
                    }
                    Write-Log -iTabs 5 "($updcnt/$($updatesToMove.Count)) - $upd added to $PersistentUpdateGroup." -bConsole $true
                    $updcnt++
                }
                catch{
                    Write-Log -iTabs 4 "Error while running Remove-CMSoftwareUpdateFromGroup" -bConsole $true -sColor Red                 
                }                
            }    
            Write-Log -iTabs 4 "$($updatesToMove.Count) updates removed from $CurrentUpdateGroup" -bConsole $true -sColor Green          
            #if updates removed and moved adds up to total updates, delete SUG
            if ($CurUpdList.count -eq ($updatesToMove.Count+$updatesToRemove.Count)){
                Write-Log -iTabs 4 "No updates left in $CurrentUpdateGroup. SUG will be deleted." -bConsole $true                    
                try{
                    if ($action -like "*Run"){
                        Remove-CMSoftwareUpdateGroup -Name $CurrentUpdateGroup -Force
                    }
                    Write-Log -iTabs 5 "SUG was deleted" -bConsole $true           
                }
                catch{
                    Write-Log -iTabs 5 "Error while deleting SUG." -bConsole $true -sColor Red                
                }
            }
        }
        else{
            Write-Log -iTabs 4 "Script will not remove updates from $CurrentUpdateGroup since it failed to add updates in Sustainer" -bConsole $true            
        }
    }
}
function Set-DeploymentPackages {
    Param(
        [Parameter(Mandatory = $false)]
        $SiteProviderServerName,
        [Parameter(Mandatory = $false)]
        $SiteCode,
        [Parameter(Mandatory = $false)]
        $monUpdList,
        [Parameter(Mandatory = $false)]
        $susUpdList,
        [Parameter(Mandatory = $false)]
        $pkgMonthlyList,
        [Parameter(Mandatory = $false)]
        $pkgSustainerList,
        [Parameter(Mandatory = $false)]
        $pkgMonthly,
        [Parameter(Mandatory = $false)]
        $pkgSustainer
        )   
    # Checkig if all Upd from SUGs are present in at least 1 pkg
    $updatesToDownloadMonth =@()
    $updatesToDownloadSus =@()
    Write-Log -iTabs 3 "Evaluating if downloaded updates are deployed in SUGs" -bConsole $true
    foreach ($update in $monUpdList){
        if (!($pkgMonthlyList.CI_ID -match $update)){
            $updatesToDownloadMonth += $update
        }
    }
    foreach ($update in $susUpdList){
        if (!($pkgSustainerList.CI_ID -match $update)){
            $updatesToDownloadSus += $update
        }
    }
    # Checking if all updates in Sustainer package is present in SUGs
    $updatesToDeleteSus = @()
    foreach ($update in $pkgSustainerList){
        if (!($susUpdList -match $update.CI_ID)){
            $updatesToDeleteSus += $update        
        }
    }
    $updatesToDeleteMonth = @()
    foreach ($update in $pkgMonthlyList){
        if (!($monUpdList -match $update.CI_ID)){
            $updatesToDeleteMonth += $update        
        }
    }
    # Deleting Updates from Sustainer package, if needed
    if ($updatesToDeleteSus.count -gt 0){
        Write-Log -iTabs 4 "Found $($updatesToDeleteSus.count) extra updates to be deleted from Aged Pkg" -bConsole $true
        #creating obj with Package WMI
        $susPackageWMI = Get-WmiObject -ComputerName $SiteProviderServerName -Namespace root\sms\site_$($SiteCode) -Class SMS_SoftwareUpdatesPackage -Filter "Name ='$pkgSustainer'"
        $ContentIDArray = @()
        # Converting CI_ID into ContentID
        foreach($upd in $updatesToDeleteSus){            
            $ContentIDtoContent = Get-WMIObject -NameSpace root\sms\site_$($SiteCode) -Class SMS_CItoContent -Filter "CI_ID='$($upd.CI_ID)'"
            $ContentIDArray += $ContentIDtoContent.ContentID
        }
        Write-Log -iTabs 5 "Converted updates into $($contentIDArray.count) ContentIDs" -bConsole $true
        #calling Remove Content Method known WMI bug might cause a temporary failure. Adding loop for resiliency while removing content.        
        $pause=0
        $pkgClean = $false
        while($pkgClean -eq $false){
            try{                   
                Start-Sleep $pause
                if ($action -like "*Run"){
                    $susPackageWMI.RemoveContent($ContentIDArray,$true) | Out-Null
                }
                $pkgClean=$true
                Write-Log -itabs 5 "Package clean-up finished" -bConsole $true
            }
            catch{                             
                Write-Log -itabs 5 "Package clean-up failed, but is a known issue. Will try again" -bConsole $true -sColor red               
                $pause +=5                
                if ($pause -eq 25 ){
                    $pkgClean=$true
                    Write-Log -itabs 5 "Unable to clena package. Try again later" -bConsole $true -sColor red               
                }
            }
        }       
    }    
    # Deleting Updates from Monthly package, if needed
    if ($updatesToDeleteMonth.count -gt 0){
        Write-Log -iTabs 4 "Found $($updatesToDeleteMonth.count) extra updates to be deleted from Monthly Pkg" -bConsole $true
        #creating obj with Package WMI
        $monPackageWMI = Get-WmiObject -ComputerName $SiteProviderServerName -Namespace root\sms\site_$($SiteCode) -Class SMS_SoftwareUpdatesPackage -Filter "Name ='$pkgMonthly'"
        $ContentIDArray = @()
        # Converting CI_ID into ContentID
        foreach($upd in $updatesToDeleteMonth){            
            $ContentIDtoContent = Get-WMIObject -NameSpace root\sms\site_$($SiteCode) -Class SMS_CItoContent -Filter "CI_ID='$($upd.CI_ID)'"
            $ContentIDArray += $ContentIDtoContent.ContentID
        }
        Write-Log -iTabs 5 "Converted updates into $($contentIDArray.count) ContentIDs" -bConsole $true
        #calling Remove Content Method known WMI bug might cause a temporary failure. Adding loop for resiliency while removing content.
        $pause=0
        $pkgClean = $false
        while($pkgClean -eq $false){
            try{                   
                Start-Sleep $pause
                if ($action -like "*Run"){
                    $MonPackageWMI.RemoveContent($ContentIDArray,$true) | Out-Null
                }
                $pkgClean=$true
                Write-Log -itabs 5 "Package clean-up finished" -bConsole $true
            }
            catch{                             
                Write-Log -itabs 5 "Package clean-up failed, but is a known issue. Will try again" -bConsole $true -sColor red               
                $pause +=5                
                if ($pause -eq 25 ){
                    $pkgClean=$true
                    Write-Log -itabs 5 "Unable to clena package. Try again later" -bConsole $true -sColor red               
                }
            }
        }
    }    
    # Downloading updates to Sustainer package, if needed
    if ($updatesToDownloadSus.count -gt 0){
        Write-Log -iTabs 4 "Found $($updatesToDownloadSus.count) required to be downloaded into Sustainer Pkg" -bConsole $true
        $updcnt=1
        Foreach ($upd in $updatesToDownloadSus){
            try{
                if ($action -like "*Run"){                
                    Save-CMSoftwareUpdate -SoftwareUpdateId $upd -DeploymentPackageName $pkgSustainer -SoftwareUpdateLanguage "English" -DisableWildcardHandling -WarningAction SilentlyContinue                         
                }
                Write-Log -iTabs 5 "($updcnt/$($updatesToDownloadSus.count)) - Update $upd downloaded to Sustainer Pkg." -bConsole $true
                $updcnt++
            }
            catch{
                Write-Log -iTabs 5 "$updcnt - Error Downloading $upd into Sustainer Pkg." -bConsole $true -sColor red                                                        
                $updcnt++
            }
        }
    }
    # Downloading Updates to Monthly Package, if needed
    if ($updatesToDownloadMonth.count -gt 0){
        Write-Log -iTabs 4 "Found $($updatesToDownloadMonth.count) required to be downloaded into Monthly Pkg" -bConsole $true
        $updcnt=1
        Foreach ($upd in $updatesToDownloadMonth){
            try{
                if ($action -like "*Run"){                
                    Save-CMSoftwareUpdate -SoftwareUpdateId $upd -DeploymentPackageName $pkgMonthly -SoftwareUpdateLanguage "English" -DisableWildcardHandling -WarningAction SilentlyContinue                         
                }
                Write-Log -iTabs 5 "($updcnt/$($updatesToDownloadMonth.count)) - Update $upd downloaded to Monthly Pkg." -bConsole $true
                $updcnt++
            }
            catch{
                Write-Log -iTabs 5 "$updcnt - Error Downloading $upd into Monthly Pkg." -bConsole $true -sColor red                                        
                $global:iExitCode = 9015
                $updcnt++
            }
        }
    }
    Write-Log -iTabs 3 "Deployment Packages review is now complete"

}
function Get-NumUpdInGroups{
# This script will examine the count of updates in each deployed update group and provide a warning
# when the number of updates in a given group exceeds 900.
    Param(
        [Parameter(Mandatory = $true)]
        $SiteServerName,
        [Parameter(Mandatory = $true)]
        $SiteCode,
        [Parameter(Mandatory = $true)]
        $sugs
        )    
    # Loop through each software update group and check the total number of updates in each.    
    ForEach ($sug in $sugs | Sort-Object $sugs.LocalizedDisplayName){        
        # Only test update groups that are deployed.  Reporting software update groups may be used
        # in some environments and as long as these groups aren't deployed they can contain greater
        # than 1000 updates.  Accordingly, warning for those groups doesn't apply.
        if (($sug.Updates.Count -gt 900) -and ($sug.IsDeployed -eq 'True')){
            $textColor="Red"
        }
        else{
            $textColor="white"
        }           
        write-log -itabs 4 "# of Updates found in $($sug.LocalizedDisplayName): $($sug.Updates.Count)." -bConsole $true -sColor $textColor
        if ($textcolor -eq "Red"){            
            write-log -itabs 5 "SUGs deployed should contain less than 900 updates. Consider splitting this SUG into more." -bConsole $true -sColor $textColor
        }
        if (($sug.Updates.Count -eq 0) -and ($sug.DateCreated -lt $timeAgedUpd)){
            write-log -itabs 5 "Empty SUGs older than Aged threshold.Deleting it..." -bConsole $true
            try{
                Remove-CMSoftwareUpdateGroup -Name $sug.LocalizedDisplayName    
                write-log -itabs 5 "Deleted!" -bConsole $true -sColor Green
            }
            catch{
                write-log -itabs 5 "Error while deleting $($sug.LocalizedDisplayName) SUG!" -bConsole $true -sColor Yellow -bEventLog $true -iEventID 7001 -sSource $sEventSource
            }
        }
    }     
}
function Remove-OldDeployments{
    Param(
        $SiteServerName,
        $SiteCode,               
        $sugName,
        $sugID,
        $CollectiontemplateName)   
    #list all deployments
        Write-Log -iTabs 4 "Getting all deployments from Software Update Group" -bConsole $true
        $deployments = Get-CMUpdateGroupDeployment | Where-Object {$_.AssignedUpdateGroup -eq "$sugID"}
        $collectionIDs = Get-CMCollection -Name $CollectiontemplateName* | Select CollectionID
        foreach ($deployment in $deployments){
            if ($deployment.TargetCollectionID -notin $collectionIDs.CollectionID){
                Write-Log -iTabs 5 "$($deployment.AssignmentName) was found as old deployment" -bConsole $true
                try{
                    if ($action -like "*Run"){
                        Remove-CMUpdateGroupDeployment -DeploymentId $deployment.AssignmentUniqueID -Force
                    }
                    Write-Log -iTabs 6 "Deployment removed" -bConsole $true
                }
                catch{
                    Write-Log -iTabs 6 "Error while Deployment removed" -bConsole $true -sColor red
                }
            }
        }
        Write-Log -iTabs 4 "Deployment clean-up is complete" -bConsole $true
}
#endregion
# --------------------------------------------------------------------------------------------
#region VARIABLES
# Standard Variables
    # *****  Change Logging Path and File Name Here  *****    
    $sOutFileName	= "Optimize-DeployedSUGs.log" # Log File Name    
    $sEventSource   = "ToolBox" # Event Source Name
    # ****************************************************
    $sScriptName 	= $MyInvocation.MyCommand
    $sScriptPath 	= Split-Path -Parent $MyInvocation.MyCommand.Path
    $sLogRoot		= Get-ChildItem -Path HKLM:\SOFTWARE\Microsoft\SMS\Tracing\
    $sLogRoot       = $sLogRoot[0].GetValue('Tracefilename')
    $sLogRoot       = $sLogRoot.Substring(0,$SLogRoot.LastIndexOf('\')+1)    
    $sOutFilePath   = $sLogRoot
    $sLogFile		= Join-Path -Path $SLogRoot -ChildPath $sOutFileName
    $global:iExitCode = 0
    $sUserName		= $env:username
    $sUserDomain	= $env:userdomain
    $sMachineName	= $env:computername
    $sCMDArgs		= $MyInvocation.Line    
    $iLogFileSize 	= 10485760
    # ****************************************************
    # Script Specific Variables
    $timeMonthSuperseded = 45 # Defines how long a Monthly SUG will have its superseded KBs preserved.
    $timeAgedUpd = 365 # Defines how long a Monthly SUG will retain valid KBs before having them migrated into a Sustainer deployment    
    switch ($Scope){
        #IF CAS
        "CAS"{
            $SMSProvider = "sccm01.zlab.varandas.com"            
            $SCCMSite = "CAS"            
            $TemplateName = "WKS-SecurityUpdates-"    
            $finalCollection = "DG4"   
            $timeMonthSuperseded = 45                          
            $timeAgedUpd = 365
        }          
        #IF VAR
        "VAR"{
            $SMSProvider = "sccm01.vlab.varandas.com"
            $SCCMSite = "VAR"
            $TemplateName = "VAR-"            
            $finalCollection = "All Desktop and Server Clients"      
            $timeMonthSuperseded = 15
            $timeAgedUpd = 270
        }       
        #IF PVA
        "PVA"{
            $SMSProvider = "sccm01.plab.varandas.com"
            $SCCMSite = "PVA"            
            $TemplateName = "VAR-"               
            $finalCollection = "All Desktop and Server Clients"    
            $timeMonthSuperseded = 20
            $timeAgedUpd = 180
        }        
        default{
            $SMSProvider,$SCCMSite,$TemplateName,$finalCollection = $null
        }
    }      
#endregion 
# --------------------------------------------------------------------------------------------
#region MAIN_SUB

Function MainSub{
# ===============================================================================================================================================================================
#region 1_PRE-CHECKS            
    Write-Log -iTabs 1 "Starting 1 - Pre-Checks." -bConsole $true -scolor Cyan
    #region 1.0 Checking/Loading SCCM Powershell Module                
        Write-Log -iTabs 2 "1.0 Checking/Loading SCCM Powershell module from $($Env:SMS_ADMIN_UI_PATH.Substring(0,$Env:SMS_ADMIN_UI_PATH.Length-5) + '\ConfigurationManager.psd1')" -bConsole $true -scolor Cyan
        if (Get-Module | Where-Object {$_.Name -like "*ConfigurationManager*"}){            
            Write-Log -iTabs 3 "SCCM PS Module was found loaded in this session!" -bConsole $true -scolor Green
        }
        else{            
            Write-Log -iTabs 3 "SCCM PS Module was not found in this session! Loading Module. This might take a few minutes..." -bConsole $true
            Try{                            
                Write-Log  -iTabs 4 "Looking for Module in $(($Env:SMS_ADMIN_UI_PATH.Substring(0,$Env:SMS_ADMIN_UI_PATH.Length-5) + '\ConfigurationManager.psd1'))" -bConsole $true
                Import-module ($Env:SMS_ADMIN_UI_PATH.Substring(0,$Env:SMS_ADMIN_UI_PATH.Length-5) + '\ConfigurationManager.psd1')                
                Write-Log  -iTabs 4 "Successfully loaded SCCM Powershell module"  -bConsole $true -scolor Green
            }
            catch{                
                Write-Log -iTabs 4 "Unable to Load SCCM Powershell module." -bConsole $true -scolor Red                
                Write-Log -iTabs 4 "Aborting script." -iTabs 4 -bConsole $true -scolor Red
                $global:iExitCode = 9001
                return $global:iExitCode
            }                      
        }
    #endregion    
    #region 1.1 Confirm Script Arguments            
        Write-Log -iTabs 2 "1.1 Checking Script arguments" -bConsole $TRUE -sColor Cyan
        Write-Log -iTabs 3 "Script is running with Command Line: $sCMDArgs" -bConsole $true -bTxtLog $false        
        if (($Action -eq "Auto-Run") -and ($Scope -eq "Other")){                
            Write-Log -itabs 3 "Action 'Auto-Run' is not supported with Scope 'Other'." -bConsole $true
            Write-Log -itabs 4 "----------------------------------------------" -bConsole $true -sColor red
            HowTo-Script                
            Write-Log -itabs 4 "----------------------------------------------" -bConsole $true -sColor red
            Write-Log -itabs 4 "Aborting script." -bConsole $true -sColor red
            $global:iExitCode = 9002
            return $global:iExitCode
        }
        if ($Scope -eq "Other"){                        
            Write-Log -iTabs 3 "Scope 'Other' requires data to be collected from User." -bConsole $true
            #Setting SMS Provider
            if ($null -eq $SMSProvider){                                
                $smsProvTest = $false
                do{
                    $SMSProvider = Read-Host "                                      SMS Provider [<ServerFQDN>/Abort] "                    
                    if ($SMSProvider -eq "Abort"){                        
                        Write-Log -iTabs 5 "Aborting script." -bConsole $true -sColor red
                        $global:iExitCode = 5001
                        return $global:iExitCode
                    }
                    Write-Log -iTabs 5 "User set '$SMSProvider' as SMSProvider"
                    Write-Log -iTabs 5 "Testing '$SMSProvider' connection..." -bConsole $true
                    if (Test-Connection -ComputerName $SMSProvider -Count 1 -Quiet){
                        Write-Log -iTabs 5 "$SMSProvider was found and set as SMSProvider" -bConsole $true -sColor green                        
                        $smsProvTest = $true
                    }
                    else{
                        Write-Log -iTabs 5 "Unable to reach $SMSProvider. Ensure server FQDN is valid" -bConsole $true -sColor red                                                
                        $smsProvTest = $false
                    }                
                }while(!$smsProvTest)                
            }  
            #Setting SCCM Site        
            if ($null -eq $SCCMSite){
                $sccmSiteTest = $false
                do{
                    $SCCMSite = Read-Host "                                      SCCM Site [<SITECODE>/Abort] "
                    if ($SCCMSite -eq "Abort"){
                        Write-Log -iTabs 5 "Aborting script." -bConsole $true -sColor red
                        $global:iExitCode = 5001
                        return $global:iExitCode
                    }
                    Write-Log -iTabs 5 "User set '$SCCMSite' as SCCM Site..."
                    Write-Log -iTabs 5 "Testing '$SCCMSite' as SCCM Site..." -bConsole $true
                    try{
                        $qrySccmSite = $(get-WMIObject -ComputerName $SMSProvider -Namespace "root\SMS" -Class "SMS_ProviderLocation" | Where-Object {$_.ProviderForLocalSite -eq "True"} | Select-Object Sitecode).Sitecode
                    }
                    catch{
                        Write-Log -iTabs 5 "Unable to reach $SMSProvider SiteCode via WMI. Ensure user permissions are present for this operation." -bConsole $true -sColor red
                        $sccmSiteTest=$false
                    }
                    if ($qrySccmSite -eq $SCCMSite){
                        Write-Log -iTabs 5 "SCCM Site $SCCMSite found in $SMSProvider. Setting as SCCM Site Code" -bConsole $true -sColor green                        
                        $sccmSiteTest=$true
                    }
                    else{
                        Write-Log -iTabs 5 "SCCM Site $SCCMSite not found in $SMSProvider. Verify Site is valid" -bConsole $true -sColor red                        
                        $sccmSiteTest=$false
                    }                
                }while(!$sccmSiteTest)                  
            }
            #Setting Template Name
            if ($null -eq $TemplateName){
                $sugTest = $false
                do{
                    $TemplateName = Read-Host "                                      Template Name [<SUGName>/Abort] "
                    if ($TemplateName -eq "Abort"){
                        Write-Log -iTabs 5 "Aborting script." -bConsole $true -sColor red
                        $global:iExitCode = 5001
                        return $global:iExitCode
                    }       
                    else{       
                        Write-Log -iTabs 5 "Template Name was set as '$TemplateName'" -bConsole $true
                        $answer = Read-Host "                                          Do you confirm? [Y/n] "                
                        if ($answer -eq "Y"){
                            Write-Log -iTabs 6 "User confirmed Template Name"
                            $sugTest=$true
                        }
                        else{
                            Write-Log -iTabs 6 "User cleared Template Name"
                        }
                    }      
                }while(!$sugTest)                            
            }
            #Setting Final Collection Name
            if ($null -eq $finalCollection){
                $colTest = $false
                do{
                    $finalCollection = Read-Host "                                      Collection Name Template [<SUGName>/Abort] "
                    if ($finalCollection -eq "Abort"){
                        Write-Log -iTabs 5 "Aborting script." -bConsole $true -sColor red
                        $global:iExitCode = 5001
                        return $global:iExitCode
                    }       
                    else{       
                        Write-Log -iTabs 5 "Collection Name Template was set as '$finalCollection'" -bConsole $true
                        $answer = Read-Host "                                          Do you confirm? [Y/n] "                
                        if ($answer -eq "Y"){
                            Write-Log -iTabs 6 "User confirmed Collection Name Template. Testing..." -bConsole $true
                            $finalCol = Get-CMCollection -Name "*$finalCollection*"                            
                            if ($finalCol.count -gt 0){
                                Write-Log -iTabs 6 "Found collections matching template" -bConsole $true -sColor Green
                                $colTest=$true
                            }
                            else{
                                Write-Log -iTabs 6 "Unable to find collections matching template" -bConsole $true -sColor red
                                $colTest=$false
                            }
                        }
                        else{
                            Write-Log -iTabs 6 "User cleared Template Name"
                        }
                    }      
                }while(!$colTest)                            
            }
        }
        # Testing SCCM Drive
        try{
            $originalLocation = Get-Location
            Write-Log -iTabs 3 "Connecting to SCCM PS Location at $($SCCMSite):\" -bConsole $true -bTxtLog $false        
            Set-Location $SCCMSite":"            
            Write-Log -iTabs 4 "Connected to SCCM PS Location at $($SCCMSite):\" -bConsole $true -sColor Green      
        }
        catch{
            Write-Log -iTabs 4 "Unable to connect to SCCM PSDrive. Aborting Script" -bConsole $true -sColor red
            Write-Log -iTabs 4 "Aborting script." -bConsole $true -sColor red
            $global:iExitCode = 9003            
            return $global:iExitCode
        }            
        #Confirming Settings                              
        Write-Log -iTabs 3 "Setings were defined as:" -bConsole $true        
        Write-Log -iTabs 4 "SCCM Scope:                  $Scope" -bConsole $true -sColor Yellow        
        Write-Log -iTabs 4 "SMSProvider:                 $SMSProvider" -bConsole $true                
        Write-Log -iTabs 4 "SCCM Site Code:              $SCCMSite" -bConsole $true         
        Write-Log -iTabs 4 "Final Collection Name:       $finalCollection" -bConsole $true
        Write-Log -iTabs 4 "Superseded Update Threshold: $timeMonthSuperseded" -bConsole $true
        Write-Log -iTabs 4 "Aged Update Threshold:       $timeAgedUpd" -bConsole $true

    #endregion  
    #region 1.2 Is this SCCM Admin User?            
        Write-Log -iTabs 2 "1.2 Checking if user has permissions in SCCM to run this script..." -bConsole $true -sColor Cyan        
        <#    
        $userRoles = (Get-CMAdministrativeUser -Name $($sUserDomain+"\"+$sUserName)).RoleNames
        foreach ($role in $userRoles){
            If (($role -eq "Full Administrator") -or ($role -eq "Software Update Manager")){
                $userRoleTest = $true
            }
        }
        if ($userRoleTest){
            Write-Host  "        User has permissions to execute this script." -ForegroundColor Green            
            Write-Log           "User has permissions to execute this script." -iTabs 3
        }
        else{
            Write-Host "        User does not have permissions to execute this script." -ForegroundColor Red
            Write-Log          "User does not have permissions to execute this script." -iTabs 3
            Write-Host "        Aborting script." -ForegroundColor Red
            Write-Log          "Aborting script." -iTabs 3
            $global:iExitCode = 9002
            return $global:iExitCode
        }    
        #>                    
        Write-Log  -iTabs 3 "Pre-Check to be implemented" -bConsole $true
    #endregion    
    #region 1.3 Querying Software Update Information        
        Write-Log -iTabs 2 "1.3 Getting Software Update Process Information" -bConsole $true -sColor Cyan
            #region Checking ADR                
                Write-Log -iTabs 3 "Checking if ADR Named ($($TemplateName)ADR) is present." -bConsole $true
                try{
                    $defaultAdr = Get-CMAutoDeploymentRule -fast -Name "$($TemplateName)ADR"
                    if ($defaultAdr.Count -gt 0){                        
                        Write-Log -iTabs 4 "ADR ($($TemplateName)ADR) was found in SCCM Environment." -bConsole $true
                    }
                    else{                        
                        Write-Log -iTabs 4 "ADR ($($TemplateName)ADR) was not found in SCCM Environment." -bConsole $true -sColor yellow
                        Write-Log -iTabs 4 "It is strongly recomended to have an ADR responsible for creating Monhtly updates." -bConsole $true -sColor yellow
                    }
                }
                catch{                    
                    Write-Log -iTabs 4 "Unable to verify existing ADRs. Permission Error. Ensure script is running with SCCM Full Admin permissionts and access to SCCM WMI Provider." -bConsole $true -sColor red                    
                    Write-Log -iTabs 4 "Aborting script." -bConsole $true -sColor red
                    $global:iExitCode = 9004
                    return $global:iExitCode
                }
            #endregion
            #region Checking SUGs           
                Write-Log -iTabs 3 "Checking if SUGs are present." -bConsole $true
                #region Gettings SUG Info         
                try{
                        $sugs = Get-CMSoftwareUpdateGroup | Where-Object {$_.LocalizedDisplayName -like "$TemplateName*"} | ConvertTo-Array                                               
                    }
                #Error while getting SUG Info
                catch{                                                                        
                        Write-Log -iTabs 4 "Unable to query Software Update Groups. Permission Error. Ensure script is running with SCCM Full Admin permissionts and access to SCCM WMI Provider." -bConsole $true -sColor red                        
                        Write-Log -iTabs 4 "Aborting script." -bConsole $true -sColor red
                        $global:iExitCode = 9005
                        return $global:iExitCode
                    }      
                #endregion             
                #region sugAged
                #sugAged was found
                if (($sugs | Where-Object {$_.LocalizedDisplayName -eq $TemplateName+"Aged"}).Count -gt 0){                        
                    Write-Log -iTabs 4 "$($TemplateName)Aged was found." -bConsole $true
                    $AgedSUG = $sugs | Where-Object {$_.LocalizedDisplayName -eq $TemplateName+"Aged"}
                }
                #sugAged was not found
                else{
                    Write-Log -iTabs 4 "$($TemplateName)Aged wasn't found. This SUG is required to proceed with script execution." -bConsole $true -sColor yellow
                    do{
                        if($action -like "*Run"){$answer = "Y"}
                        else{
                            $answer = Read-Host "                                      Do you want to create Software Update Group '$($TemplateName)Aged'? [Y/n] "                
                        }
                    } while (($answer -ne "Y") -and ($answer -ne "n"))
                    #aborting script
                    if ($answer -eq "n"){                
                        Write-Log -iTabs 5 "User don't want to create Software Update Group $($TemplateName)Aged at this moment"-bConsole $true -sColor red
                        Write-Log -iTabs 5 "Aborting script." -bConsole $true -sColor red
                        $global:iExitCode = 5002
                        return $global:iExitCode
                    }   
                    # Creating sugAged
                    if ($answer -eq "y"){                                            
                        Write-Log -iTabs 4 "Creating $($TemplateName)Aged..." -bConsole $true
                        try{
                            New-CMSoftwareUpdateGroup -Name "$($TemplateName)Aged" | Out-Null                                
                            Write-Log -iTabs 4 "$($TemplateName)Aged was created" -bConsole $true -sColor green                                                                
                        }    
                        catch{                                
                            Write-Log -iTabs 4 "Error while creating $($TemplateName)Aged. Ensure script is running with SCCM Full Admin permissionts and access to SCCM WMI Provider." -bConsole $true -sColor red
                            Write-Log -iTabs 4 "Aborting script." -bConsole $true -sColor red
                            $global:iExitCode = 9006
                            return $global:iExitCode                            
                        }
                        Write-Log -iTabs 4 "Reloading SUG Array." -bConsole $true      
                        $sugs = Get-CMSoftwareUpdateGroup | Where-Object {$_.LocalizedDisplayName -like "$TemplateName*"} | Sort LocalizedDisplayName | ConvertTo-Array                                            
                        $AgedSUG = $sugs | Where-Object {$_.LocalizedDisplayName -eq $TemplateName+"Aged"} #All Aged, but valid Updates                     
                    } 
                }
                #endregion                    
            #endregion
            #region Checking Packages (Monthly and Sustainer)                
                Write-Log -iTabs 3 "Checking if required Deployment Packages are present." -bConsole $true
                #region Getting Deployment Package Info 
                try{                        
                        $pkgMonth = Get-CMSoftwareUpdateDeploymentPackage | Where-Object {$_.Name -eq "$($TemplateName)Monthly"}                                                
                        $pkgAged = Get-CMSoftwareUpdateDeploymentPackage | Where-Object {$_.Name -eq "$($TemplateName)Aged"}
                        
                    }                
                catch{                        
                        Write-Log -iTabs 4 "Unable to query Deployment Packages. Permission Error. Ensure script is running with SCCM Full Admin permissionts and access to SCCM WMI Provider." -bConsole $true -sColor red                        
                        Write-Log -iTabs 4 "Aborting script."  -bConsole $true -sColor red
                        $global:iExitCode = 9007
                        return $global:iExitCode
                    }
                #endregion
                #region Monthly Package                
                if ($pkgMonth.Count -gt 0){                        
                        Write-Log -iTabs 4 "$($pkgMonth.Name) was found." -bConsole $true -sColor green                    
                        #Loading CI_IDs from Monthly Package                                        
                        Write-Log -iTabs 4 "Loading CI_ID List from $($pkgMonth.Name)" -bConsole $true                        
                        $PkgID = [System.Convert]::ToString($pkgMonth.PackageID)
                        # The query pulls a list of all software updates in the current package.  This query doesn't pull back a clean value so will store it and then manipulate the string to just get the CI information we need a bit later.
                        $Query="SELECT DISTINCT su.* FROM SMS_SoftwareUpdate AS su JOIN SMS_CIToContent AS cc ON  SU.CI_ID = CC.CI_ID JOIN SMS_PackageToContent AS  pc ON pc.ContentID=cc.ContentID  WHERE  pc.PackageID='$PkgID' AND su.IsContentProvisioned=1 ORDER BY su.DateRevised Desc"
                        $QueryResults=@(Get-WmiObject -ComputerName $SMSProvider -Namespace root\sms\site_$($sccmsite) -Query $Query)                    
                        $pkgMonthlyList = @()
                        # Work one by one through every CI that is part of the package adding each to the array to be stored in the hash table.
                        ForEach ($CI in $QueryResults){                
                            # Need to convert the CI information to a string
                            $IndividualCIinDeploymentPackage = [System.Convert]::ToString($CI)
                            # Since the converted string has more text than just the CI value need to manipulate it to strip off the unneeded parts.
                            $Index = $IndividualCIinDeploymentPackage.IndexOf("=")
                            $IndividualCIinDeploymentPackage = $IndividualCIinDeploymentPackage.remove(0, ($Index + 1))
                            $age = (((get-date -uformat %Y)-[int]$ci.DatePosted.Substring(0,4))*365)+(((get-date -uformat %m)-[int]$ci.DatePosted.Substring(4,2))*30)                            
                            $ciInPkg = [pscustomobject]@{"CI_ID"="";"Age"=""}
                            $ciInPkg.CI_ID = $IndividualCIinDeploymentPackage
                            $ciInPkg.Age = $age
                            $pkgMonthlyList += $ciInPkg                        
                        }
                        Write-Log -iTabs 5 "Total Updates: $($pkgMonthlyList.Count)" -bConsole $true -sColor Green                        
                    }                
                else{                        
                        Write-Log -iTabs 4 "$($TemplateName)Monthly was not found. This Package is Required to proceed with script execution." -bConsole $true -sColor red
                        do{
                            if($action -like "*run"){
                                $answer = "Abort"
                            }
                            else{
                                $answer = Read-Host "                                      Do you want to create Deployment Package '$($TemplateName)Monthly'? [Y/n] "                
                            }
                        } while (($answer -ne "Y") -and ($answer -ne "n"))
                        #aborting script
                        if ($answer -eq "n"){                                            
                            Write-Log -iTabs 5 "User don't want to create $($TemplateName)Monthly at this moment." -bConsole $true -sColor red
                            Write-Log -iTabs 5 "Aborting script."  -bConsole $true -sColor red
                            $global:iExitCode = 5001
                            return $global:iExitCode
                        }   
                        # Creating Monthly PKG
                        if ($answer -eq "y"){
                            $pathTest=$false
                            do{
                                Write-Log -iTabs 0 -bTxtLog $false -bConsole $true
                                Write-Log -iTabs 4 "Collecting Network Share path from user"
                                Write-Log -iTabs 4 "Enter a valid Network Share Path to store Updates" -bTxtLog $false -bConsole $true
                                Write-Log -iTabs 4 "Both SCCM Server Account and your ID must have Read/Write access to target location" -bTxtLog $false -bConsole $true
                                $sharePath = Read-Host "                                      Network Share Path (\\<SERVERNAME>\PATH or Abort) "                
                                Write-Log -iTabs 4 "Network Share: $sharePath"                                                               
                                Write-Log -iTabs 5 "Testing Network Share..." -bConsole $true                              
                                $pathTest = Test-Path $("filesystem::$sharePath") 
                                if (!($pathTest)){
                                    Write-Log -iTabs 5 "Network Share Invalid!" -bConsole $true -sColor red
                                }
                                else{
                                    Write-Log -iTabs 5 "Network Share Valid!" -bConsole $true -sColor green
                                }
                            } while (($sharePath -ne "Abort") -and (!($pathTest)))                                      
                            Write-Log -iTabs 4 "Creating $($TemplateName)Monthly..." -bConsole $true
                            try{
                                New-CMSoftwareUpdateDeploymentPackage -Name "$($TemplateName)Monthly" -Path "$sharePath" -Priority High | Out-Null                                
                                Write-Log -iTabs 4 "$($TemplateName)Monthly was created" -bConsole $true -sColor Green                                
                                Write-Log -iTabs 4 "Updating Package Array" -bConsole $true
                                $pkgs = Get-CMSoftwareUpdateDeploymentPackage | Where-Object {$_.Name -like "$TemplateName*"} | ConvertTo-Array
                            }    
                            catch{                                
                                Write-Log -iTabs 4 "Error while creating $($TemplateName)Monthly. Ensure script is running with SCCM Full Admin permissionts and access to SCCM WMI Provider." -bConsole $true -sColor red                                
                                Write-Log -iTabs 4 "Aborting script." -bConsole $true -sColor red
                                $global:iExitCode = 9008
                                return $global:iExitCode                            
                            }
                        }                      
                    }
                #endregion
                #region Aged Package                
                #Sustainer Deployment Package was found
                if ($pkgAged.Count -gt 0){                        
                        Write-Log -iTabs 4 "$($pkgAged.Name) was found." -bConsole $true -sColor green                        
                        #Loading CI_IDs from Monthly Package                                        
                        Write-Log -iTabs 4 "Loading CI_ID List from $($pkgAged.Name)" -bConsole $true
                        $upCount =0
                        $PkgID = [System.Convert]::ToString($pkgAged.PackageID)
                        # The query pulls a list of all software updates in the current package.  This query doesn't pull back a clean value so will store it and then manipulate the string to just get the CI information we need a bit later.
                        $Query="SELECT DISTINCT su.* FROM SMS_SoftwareUpdate AS su JOIN SMS_CIToContent AS cc ON  SU.CI_ID = CC.CI_ID JOIN SMS_PackageToContent AS  pc ON pc.ContentID=cc.ContentID  WHERE  pc.PackageID='$PkgID' AND su.IsContentProvisioned=1 ORDER BY su.DateRevised Desc"
                        $QueryResults=@(Get-WmiObject -ComputerName $SMSProvider -Namespace root\sms\site_$($sccmsite) -Query $Query)                    
                        $pkgAgedList = @()
                        # Work one by one through every CI that is part of the package adding each to the array to be stored in the hash table.
                        ForEach ($CI in $QueryResults){                
                            # Need to convert the CI information to a string
                            $IndividualCIinDeploymentPackage = [System.Convert]::ToString($CI)
                            # Since the converted string has more text than just the CI value need to manipulate it to strip off the unneeded parts.
                            $Index = $IndividualCIinDeploymentPackage.IndexOf("=")
                            $IndividualCIinDeploymentPackage = $IndividualCIinDeploymentPackage.remove(0, ($Index + 1))                            
                            $age = (((get-date -uformat %Y)-[int]$ci.DatePosted.Substring(0,4))*365)+(((get-date -uformat %m)-[int]$ci.DatePosted.Substring(4,2))*30)                            
                            $ciInPkg = [pscustomobject]@{"CI_ID"="";"Age"=""}
                            $ciInPkg.CI_ID = $IndividualCIinDeploymentPackage
                            $ciInPkg.Age = $age                            
                            $pkgAgedList += $ciInPkg      
                        }
                        Write-Log -iTabs 5 "Total Updates: $($pkgAgedList.Count)" -bConsole $true -sColor Green          
                    }
                #Sustainer Deployment Package was not found
                else{                        
                        Write-Log -iTabs 4 "$($TemplateName)Aged was not found. This Package is Required to proceed with script execution." -bConsole $true -sColor red
                        do{
                            if($action -like "*run"){
                                $answer = "Abort"
                            }
                            else{
                                $answer = Read-Host "                                      Do you want to create Deployment Package '$($TemplateName)Monthly'? [Y/n] "                
                            }
                        } while (($answer -ne "Y") -and ($answer -ne "n"))
                        #aborting script
                        if ($answer -eq "n"){                                            
                            Write-Log -iTabs 4 "Create $($TemplateName)Aged before executing this script again." -bConsole $true -sColor red                            
                            Write-Log -iTabs 4 "Aborting script." -bConsole $true -sColor red
                            $global:iExitCode = 5001
                            return $global:iExitCode
                        }   
                        # Creating Sustainer PKG
                        if ($answer -eq "y"){
                            $pathTest=$false
                            do{
                                Write-Log -iTabs 0 -bTxtLog $false -bConsole $true
                                Write-Log -iTabs 4 "Collecting Network Share path from user"
                                Write-Log -iTabs 4 "Enter a valid Network Share Path to store Updates" -bTxtLog $false -bConsole $true
                                Write-Log -iTabs 4 "Both SCCM Server Account and your ID must have Read/Write access to target location" -bTxtLog $false -bConsole $true
                                $sharePath = Read-Host "                                      Network Share Path (\\<SERVERNAME>\PATH or Abort) "                
                                Write-Log -iTabs 4 "Network Share: $sharePath"                                                               
                                Write-Log -iTabs 5 "Testing Network Share..." -bConsole $true                              
                                $pathTest = Test-Path $("filesystem::$sharePath") 
                                if (!($pathTest)){
                                    Write-Log -iTabs 5 "Network Share Invalid!" -bConsole $true -sColor red
                                }
                                else{
                                    Write-Log -iTabs 5 "Network Share Valid!" -bConsole $true -sColor green
                                }
                            } while (($sharePath -ne "Abort") -and (!($pathTest)))                                                                      
                            Write-Log -iTabs 4 "Creating $($TemplateName)Aged..." -bConsole $true
                            try{
                                New-CMSoftwareUpdateDeploymentPackage -Name "$($TemplateName)Aged" -Path $sharePath -Priority High | Out-Null                                
                                Write-Log -iTabs 4 "$($TemplateName)Aged was created" -bConsole $true -sColor green
                                Write-Log -iTabs 4 "Updating Package Array" -bConsole $true
                                $pkgs = Get-CMSoftwareUpdateDeploymentPackage | Where-Object {$_.Name -like "$TemplateName*"} | ConvertTo-Array
                            }    
                            catch{                                
                                Write-Log -iTabs 4 "Error while creating $($TemplateName)Aged. Ensure script is running with SCCM Full Admin permissionts and access to SCCM WMI Provider." -bConsole $true -sColor red                                
                                Write-Log -iTabs 4 "Aborting script." -bConsole $true -sColor red
                                $global:iExitCode = 9008
                                return $global:iExitCode                            
                            }
                        }                      
                    }                                    
                #endregion
            #endregion  
            #region Query all Expired Updates            
            Write-Log -iTabs 3 "Getting all Expired KBs from SCCM WMI." -bConsole $true
            try{
                $ExpiredUpdates = Get-CMSoftwareUpdate -IsExpired $true -fast | Select-Object -Property CI_ID
                Write-Log -iTabs 4 "Expired KBs: $($ExpiredUpdates.Count)" -bConsole $true
            }
            catch{
                Write-Log -iTabs 4 "Error getting Update info from SCCM WMI." -bConsole $true -sColor red
                Write-Log -iTabs 4 "Aborting script."  -bConsole $true -sColor red
                $global:iExitCode = 9009
                return $global:iExitCode
            }
            #endregion
            #region Query All Superseded Updates
            Write-Log -iTabs 3 "Getting all Superseded KBs from SCCM WMI." -bConsole $true
            try{
                $SupersededUpdates = Get-CMSoftwareUpdate -IsSuperseded $true -fast | Select-Object -Property CI_ID
                Write-Log -iTabs 4 "Superseded KBs: $($SupersededUpdates.Count)" -bConsole $true
            }
            catch{
                Write-Log -iTabs 4 "Error getting Update info from SCCM WMI." -bConsole $true -sColor red
                Write-Log -iTabs 4 "Aborting script."  -bConsole $true -sColor red
                $global:iExitCode = 9009
                return $global:iExitCode
            }
            #endregion
            #region Query All Aged Updates            
            Write-Log -iTabs 3 "Getting all Aged KBs from SCCM WMI." -bConsole $true
            try{
                $AgedUpdates = Get-CMSoftwareUpdate -DatePostedMax $(Get-Date).AddDays(-$timeAgedUpd) -IsSuperseded $false -IsExpired $false -fast | Select-Object -Property CI_ID
                Write-Log -iTabs 4 "Aged KBs: $($AgedUpdates.Count)" -bConsole $true
            }
            catch{
                Write-Log -iTabs 4 "Error getting Update info from SCCM WMI." -bConsole $true -sColor red
                Write-Log -iTabs 4 "Aborting script."  -bConsole $true -sColor red
                $global:iExitCode = 9009
                return $global:iExitCode
            }
            #endregion
    #endregion    
    #region 1.4 Finalizing Pre-Checks      
    Write-Log -iTabs 2 "1.4 - Finalizing Pre-Checks:" -bConsole $true -sColor cyan    
    Write-Log -itabs 3 "SUG Information - These SUGs will be evaluated/changed by this script." -bConsole $true
    $initNumUpdates=0 
    $initNumSugs=0
    foreach ($sug in $sugs | where {($sugs.LocalizedDisplayName -like $TemplateName -and $sugs.IsDeployed -eq $true) -or $sugs.LocalizedDisplayName -eq $TemplateName+"Aged"} | Sort-Object $sugs.LocalizedDisplayName){
        #$sugName = $sug.LocalizedDisplayName
        Write-Log -itabs 4 $sug.LocalizedDisplayName -bConsole $true
        $initNumUpdates+=$($sug.Updates).Count
        $initNumSugs+=1
    }    
    Write-Log -itabs 3 "Package Information - These PKGs will be evaluated/changed by this script." -bConsole $true            
    $initPkgSize=0
    $initPkgSize+=$pkgMonth.PackageSize/1024/1024
    Write-Log -itabs 4 "$($pkgMonth.PackageID) - $($pkgMonth.Name) - $([math]::Round($pkgMonth.PackageSize/1024/1024,2)) GB." -bConsole $true    
    Write-Log -itabs 4 "$($pkgAged.PackageID) - $($pkgAged.Name) - $([math]::Round($pkgAged.PackageSize/1024/1024,2)) GB." -bConsole $true
    $initPkgSize+=$pkgAged.PackageSize/1024/1024
            
    #$initNumUpdates = ($sugs | Where-Object {$_.LocalizedDisplayName -ne $SUGTemplateName+"Report" -and $_.LocalizedDisplayName -ne $SUGTemplateName+"Tracked" -and $_.LocalizedDisplayName -ne $SUGTemplateName+"MSFT"} | Measure-Object -Property NumberofUpdates -Sum).Sum
    Write-Log -itabs 3 "Number of Updates: $initNumUpdates" -bConsole $true
    #$initNumSugs = $sugs.Count
    Write-Log -itabs 3 "Number of SUGs: $initNumSugs" -bConsole $true    
    #$initPkgSize = ($pkgs | Measure-Object -Property PackageSize -Sum).Sum/1024/1024
    Write-Log -itabs 3 "Space used by Packages: $([math]::Round($initPkgSize,2)) GB" -bConsole $true    
    Write-Log -itabs 2 "Pre-Checks are complete. Script will make environment changes in the next interaction." -bConsole $true
    Write-Log -itabs 2 "Getting User confirmation to proceed"
    do{
        Write-Log -iTabs 3 "Above you have the list of Packages and Software Update Groups which will be managed by this script." -bConsole $true
        Write-Log -iTabs 3 "Review the list above and make sureare indeed the right targets for actions." -bConsole $true
        if ($action -eq "Check"){
            Write-Log -iTabs 3 "Script would make environment changes in the next interaction. Action Check identified. Script will log but not execute actions." -bConsole $true        
        }
        else{
            Write-Log -iTabs 3 "Script will make environment changes in the next interaction" -bConsole $true -scolor Yellow        
        }
        if($action -like "*run"){
            $answer = "Y"
        }
        else{
            $answer = Read-Host "                                  |Do you want to proceed? [Y/n]"     
        }   
    } while (($answer -ne "Y") -and ($answer -ne "n"))
    if ($answer -eq "n"){
        Write-Log -iTabs 3 "User Aborting script." -bConsole $true -sColor red
        $global:iExitCode = 8001
        return $global:iExitCode
    }
    else{
        Write-Log -iTabs 2 "User confirmation received." 
    }
    #endregion
    Write-Log -iTabs 1 "Completed 1 - Pre-Checks." -bConsole $true -sColor Cyan    
    Write-Log -iTabs 0 -bConsole $true
#endregion
# ===============================================================================================================================================================================

# ===============================================================================================================================================================================
#region 2_EXECUTION
    Write-Log -iTabs 1 "Starting 2 - Execution."   -bConsole $true -sColor cyan    
    #region 2.1 Review all Monthly SUGs, removing Expired or Superseded KBs. KBs older than 1 year will be moved to Sustainer.        
        Write-Log -iTabs 2 "2.1 - Review all Monthly SUGs, removing Expired or Superseded KBs. KBs older than 1 year will be moved to Sustainer"-bConsole $true -sColor cyan        
        $timeMonthSuperseded=$(Get-Date).AddDays(-$timeMonthSuperseded)        
        $sugCount=1
        foreach ($sug in $sugs | where {($sugs.LocalizedDisplayName -like $TemplateName -and $sugs.IsDeployed -eq $true) -or $sugs.LocalizedDisplayName -eq $TemplateName+"Aged"} | Sort-Object $sugs.LocalizedDisplayName){                    
            Write-Log -iTabs 3 "($sugCount/$($sugs.Count)) Evaluating SUG: $($sug.LocalizedDisplayName)." -bConsole $true
            #Skiping non-std SUGs
            if($sug.LocalizedDisplayName -eq $($TemplateName+"Aged")){                
                Write-Log -iTabs 4 "Skipping $($sug.LocalizedDisplayName) at this moment. No Action will be taken." -bConsole $true
            }            
            #if SUG is new (less than $timeMonthSuperseded days) remove Expired KBs Only
            elseif ($sug.DateCreated -gt $timeMonthSuperseded){                                                
                Write-Log -iTabs 4 "New SUG - Script will only remove Expired KBs."  -bConsole $true                
                try{
                    Set-SUGPair -SiteProviderServerName $SMSProvider -SiteCode $SCCMSite -CurrentUpdateGroup $sug.LocalizedDisplayName -CurUpdList $sug.Updates -PersistentUpdateGroup $($SUGTemplateName+"Aged") -PerUpdList $AgedSUG.Updates -HandleAgedUpdates $false -aAgedUpdates $AgedUpdates -PurgeExpired $true -aExpUpdates $ExpiredUpdates -PurgeSuperseded $false -aSupersededUpdates $SupersededUpdates -pkgSusName $pkgAged.Name -pkgSusList $pkgAgedList                
                }
                catch{
                     Write-Log -iTabs 5 "Error while processing new SUG" -sColor Red -bConsole $true
                     $global:iExitCode = 9011
                     return $global:iExitCode
                }
            }
            #if SUG is stable (DateCreate is lesser than 365 days and greater than 35 days) remove Expired and Superseded KBs Only. Delete Deployments to initial DGs
            elseif ($sug.DateCreated -lt $timeMonthSuperseded){                                
                Write-Log -iTabs 4 "Removing Expired and Superseeded KBs. Deployments to initial DGs will be deleted."  -bConsole $true
                try{                
                    Set-SUGPair -SiteProviderServerName $SMSProvider -SiteCode $SCCMSite -CurrentUpdateGroup $sug.LocalizedDisplayName -CurUpdList $sug.Updates -PersistentUpdateGroup $($TemplateName+"Aged") -PerUpdList $AgedSUG.Updates -HandleAgedUpdates $false -aAgedUpdates $AgedUpdates -PurgeExpired $true -aExpUpdates $ExpiredUpdates -PurgeSuperseded $true -aSupersededUpdates $SupersededUpdates -pkgSusName $pkgAged.Name -pkgSusList $pkgAgedList  
                    Remove-OldDeployments -SiteServerName $SMSProvider -SiteCode $SCCMSite -sugID $sug.CI_ID -sugName $sug.LocalizedDisplayName -CollectiontemplateName $finalCollection
                }
                catch{
                     Write-Log -iTabs 5 "Error while processing stable SUG" -sColor Red -bConsole $true
                     $global:iExitCode = 9012
                     return $global:iExitCode
                }
            }
            #if SUG is old (DateCreate is greater than 365 days) remove Expired and Superseded KBs. Move valid KBs to Sustainer and Delete SUG
            elseif ($sug.DateCreated -gt $tSustainerAge){                                
                Write-Log -iTabs 4 "Removing Expired KBs and Superseeded KBs, Moving year-old Valid KBs into Sustainer SUG. SUG will be deleted" -bConsole $true
                try{     
                    Set-SUGPair -SiteProviderServerName $SMSProvider -SiteCode $SCCMSite -CurrentUpdateGroup $sug.LocalizedDisplayName -CurUpdList $sug.Updates -PersistentUpdateGroup $($SUGTemplateName+"Sustainer") -PerUpdList $sugSustainer.Updates -HandleAgedUpdates $true -aAgedUpdates $AgedUpdates -PurgeExpired $true -aExpUpdates $ExpiredUpdates -PurgeSuperseded $true -aSupersededUpdates $SupersededUpdates  -pkgSusName $pkgSustainer.Name -pkgSusList $pkgSustainerList               
                }
                catch{
                     Write-Log -iTabs 5 "Error while processing aged SUG" -sColor Red -bConsole $true
                     $global:iExitCode = 9013
                     return $global:iExitCode
                }
            }            
            $sugcount++
        }        
    #endregion    
    #region 2.2 Review Aged SUG, removing Expired or Superseded KBs.        
        Write-Log -iTabs 2 "2.2 - Review Aged SUG, removing Expired or Superseded KBs." -bConsole $true -sColor cyan        
        try{
            Write-Log -iTabs 3 "Reviewing $($TemplateName+"Aged") SUG, removing Superseded and Expired KBs."  -bConsole $true                
            Set-SUGPair -SiteProviderServerName $SMSProvider -SiteCode $SCCMSite -CurrentUpdateGroup $($TemplateName+"Aged") -CurUpdList $AgedSug.Updates -PurgeSuperseded $true -PurgeExpired $true -HandleAgedUpdates $false -aExpUpdates $ExpiredUpdates -aSupersededUpdates $SupersededUpdates
            Write-Log -iTabs 3 "Review is complete."  -bConsole $true                
        }
        catch {            
            Write-Log -iTabs 4 "Error while processing Sustainer Eval. Aborting script." -bConsole $true -sColor red
            $global:iExitCode = 9010
            return $global:iExitCode
        }                     
    #endregion      
    #region 2.3 Remove unused KBs from Packages and download required KBs    
    Write-Log -iTabs 2 "2.3 Remove unused KBs from Packages and download required KBs" -bConsole $true -sColor cyan    
    try{
        Write-Log -iTabs 3 "Reviewing $($TemplateName+"Monthly") and $($TemplateName+"Aged"). Extra KBs will be removed, needed  will be downloaded"  -bConsole $true           
        $monUpdList = $($sugs | Where-Object {$_.LocalizedDisplayName -like "$($TemplateName)ADR 20*"}).Updates
        $susUpdList = $($sugs | Where-Object {$_.LocalizedDisplayName -eq "$($TemplateName)Aged"}).Updates        
        Set-DeploymentPackages -SiteProviderServerName $SMSProvider -SiteCode $SCCMSite -monUpdList $monUpdList -susUpdList $susUpdList -pkgMonthlyList $pkgMonthlyList -pkgSustainerList $pkgAgedList -pkgMonthly $pkgMonth.Name -pkgSustainer $pkgAged.Name
    }
    catch{     
        Write-Log -iTabs 3 "Error while handling packages" -bConsole $true -sColor red
    }    
    #endregion          
    #region 2.4 EvaluateNumberofUpdatesinGroups checking if SUGs are over 900 KBs limit    
    Write-Log -iTabs 2 "2.4 EvaluateNumberofUpdatesinGroups checking if SUGs are over 900 KBs limit" -bConsole $true -sColor cyan    
    # Gettings SUG Info         
    try{
        Write-Log -iTabs 3 "Renewing SUG information..." -bConsole $true                        
        $sugs = Get-CMSoftwareUpdateGroup | Where-Object {$_.LocalizedDisplayName -like "$TemplateName*"} | ConvertTo-Array                                               
    }
    #Error while getting SUG Info
    catch{                                                                        
        Write-Log -iTabs 4 "Unable to query Software Update Groups. Permission Error. Ensure script is running with SCCM Full Admin permissionts and access to SCCM WMI Provider." -bConsole $true -sColor red                        
        Write-Log -iTabs 4 "Aborting script." -bConsole $true -sColor red
        $global:iExitCode = 9005
        return $global:iExitCode
    } 
    try{
        Get-NumUpdInGroups -SiteServerName $SMSProvider -SiteCode $SCCMSite -sugs $sugs
    }
    catch{        
        Write-Log -iTabs 3 "Error while evaliating SUGs" -bConsole $true -sColor red
    }    
    #endregion    
    Write-Log -iTabs 1 "Completed 2 - Execution." -bConsole $true -sColor cyan
    Write-Log -iTabs 0 -bConsole $true
#endregion
# ===============================================================================================================================================================================
        
# ===============================================================================================================================================================================
#region 3_POST-CHECKS
# ===============================================================================================================================================================================
    Write-Log -iTabs 1 "Starting 3 - Post-Checks." -bConsole $true -sColor cyan
    #getting current software update information
    Write-Log -itabs 2 "Refreshing SUG and PKG array" -bConsole $true
    try{
        $sugs = Get-CMSoftwareUpdateGroup | Where-Object {$_.LocalizedDisplayName -like "$TemplateName*"} | ConvertTo-Array                                               
        $pkgs = Get-CMSoftwareUpdateDeploymentPackage | Where-Object {$_.Name -eq $TemplateName+"Monthly" -or $_.Name -eq $TemplateName+"Aged"} | ConvertTo-Array
    }
    catch{
        Write-Log -itabs 2 "Error while refreshign arrays. Post-Checks won't be possible/reliable" -bConsole $true -sColor $red
        $global:iExitCode = 9012
        return $global:iExitCode
    }
    $finalNumUpdates = ($sugs | Measure-Object -Property NumberofUpdates -Sum).Sum
    Write-Log -itabs 3 "Initial Number of Updates: $initNumUpdates" -bConsole $true -sColor Darkyellow
    Write-Log -itabs 3 "Final Number of Updates: $finalNumUpdates" -bConsole $true -sColor yellow
    $finalNumSugs = $sugs.Count
    Write-Log -itabs 3 "Initial Number of SUGs: $initNumSugs" -bConsole $true -sColor Darkyellow
    Write-Log -itabs 3 "Final Number of SUGs: $finalNumSugs" -bConsole $true -sColor yellow
    $finalPkgSize = ($pkgs | Measure-Object -Property PackageSize -Sum).Sum/1024/1024
    Write-Log -itabs 3 "Initial Space used by Packages: $([math]::Round($initPkgSize,2)) GB" -bConsole $true -sColor Darkyellow
    Write-Log -itabs 3 "Final Space used by Packages: $([math]::Round($finalPkgSize,2)) GB" -bConsole $true -sColor yellow 
    #>       
    Write-Log -iTabs 1 "Completed 3 - Post-Checks." -bConsole $true -sColor cyan
    Write-Log -iTabs 0 "" -bConsole $true
#endregion
# ===============================================================================================================================================================================

} #End of MainSub

#endregion
# --------------------------------------------------------------------------------------------

# --------------------------------------------------------------------------------------------
#region MAIN_PROCESSING

# Starting log
$global:original = Get-Location
Start-Log

Try {
	MainSub    
}
Catch {
	# Log a general exception error
	Write-Log -sMessage "Error running script" -iTabs 0        
    if ($global:iExitCode -eq 0){
	    $global:iExitCode = 9999
    }                
}
# Stopping the log
Stop-Log
Set-Location $global:original

# Quiting with exit code
Exit $global:iExitCode
#endregion
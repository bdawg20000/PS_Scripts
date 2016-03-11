#-----------------------------------------------------------------------------------
#-----------------------------------------------------------------------------------
#Chained reboot script for XenApp 6 Citrix Farms
#Cycles through all servers in a XenApp farm and if the server is online, processes the reboot procedure
#Server will wait for all users to logoff before rebooting.
#Once the reboot has completed, the process will start on the next server in the farm
#GLOBAL variables of NOLOGONLOADEVALUATOR, REBOOTINTERVAL, FARMLOOPINTERVAL, REBOOTTHISSERVER, EXCLUDESERVERS, WORKERGROUPS, MAXSERVERS, and ENABLESMTP
#must be defined prior to deployment
#
#This script can be run as a schedule task from the Zone Data Collector to process reboots for all other application servers
#Created by Dane Young, CTP, Entisys Solutions Copyright 2010, 2011, 2012, 2013
#Check http://blog.itvce.com/?p=79 for updates
#Build 2013.12.09 Revision 7
#-----------------------------------------------------------------------------------
#-----------------------------------------------------------------------------------

$Global:NoLogonLoadEvaluator = "NoLogon" # Define the load evaluator you intend to use for no logons
[int]$Global:REBOOTINTERVAL = "30" # Define the reboot interval (in minutes) for processing subsequent servers in the farm
[int]$Global:FARMLOOPINTERVAL = "24" # Define the Farm Loop reboot interval (in hours) for processing ALL servers in the farm
$Global:REBOOTTHISSERVER = $false # Defines whether or not to reboot this server after processing ALL servers in the farm
$Global:EXCLUDESERVERS = "" #Define which servers should be excluded from processing. Comma seperated list, short names only, case insensitive (for example "CORPCTX01,CORPCTX02,CORPCTX05")
$Global:WORKERGROUPS = "" #Define which worker groups should be processed. Comma seperated list, spaces acceptable, case insensitive (for example "Zone Data Collectors,Productivity Apps"). Leaving blank will process all servers in the farm as in previous revisions
[int]$Global:MAXSERVERS = "1" # Define the number of servers to remove for processing at any time. If defining worker groups, this setting will remove the defined number of servers from each workergroup (for example, "2")
$Global:ENABLESMTP = $false #Define if SMTP notifications should be sent indicating progress throughout the script. If $false, only Event Log entries will be written. If $true, the next section of variables must be defined for SMTP relay
#-----------------------------------------------------------------------------------
#-----------------------------------------------------------------------------------
#By default, SMTP notifications will use secure authenticated SMTP over port 587
#Since there are many options for SMTP relay, I decided to focus on the most secure for the provided script. 
#This configuration even worked using smtp.gmail.com and my Gmail account for authentication
#If you want to change this to either unsecure or unauthenticated SMTP relay, research PowerShell and Net.Mail.SmtpClient for examples
#Then, change the five lines below and search for SmtpClient within this script to update the necessary SMTP configuration lines
#-----------------------------------------------------------------------------------
#-----------------------------------------------------------------------------------
$Global:EmailFrom = "example@domain.com"
$Global:EmailTo = "example@domain.com" 
$Global:SMTPServer = "smtp.domain.com" 
$Global:SMTPUsername = "serviceaccountusername"
$Global:SMTPPassword = "serviceaccountpassword"
#-----------------------------------------------------------------------------------
#-----------------------------------------------------------------------------------
$Global:EventLog = New-Object -type System.Diagnostics.Eventlog -argumentlist Application # Creates a global object for logging to the Application event log
$Global:EventLog.Source = "Citrix Chained Reboot" # All event logs will be entered with the source of Citrix Chained Reboot
if ($EnableSMTP -eq $true){$Global:SMTPClient = New-Object Net.Mail.SmtpClient($SmtpServer, 587);$Global:SMTPClient.EnableSsl = $true;$Global:SMTPClient.Credentials = New-Object System.Net.NetworkCredential($SMTPUsername, $SMTPPassword)}
Add-PSSnapin "Citrix.XenApp.Commands"
$processes=0
$powershells = @(get-process | Where {$_.ProcessName -eq "powershell"}) # Query all running processes to see if Powershell is running
foreach ($p in $powershells) {$processes+=1} # Validate that there is already a powershell instance running
if ($processes -gt 1) {$EventLog.WriteEntry("PowerShell is already running.  Terminating this instance.","Information","011");exit} # Powershell is already running, terminate this instance.
if ($EnableSMTP -eq $true){
try {
$SMTPClient.Send($EmailFrom, $EmailTo, "Starting scheduled task Citrix Chained Reboot.", "")
 } catch {
 $EventLog.WriteEntry("Fatal error attempting to send e-mail using SMTP. Please resolve the issue or disable SMTP in global variables. " + $error[0],"Error") # Brute force error handling method to catch all errors
 }
}
$EventLog.WriteEntry("Starting scheduled task Citrix Chained Reboot.","Information","111") # Create test event entry to note the start time of the script
#-----------------------------------------------------------------------------------
$NoLogonLEExists="False"
$NoLogonQuery = @(get-xaloadevaluator | Where {$_.LoadEvaluatorName -eq $Global:NoLogonLoadEvaluator}) # Query to see if NoLogonLoadEvaluator exists
foreach ($nl in $NoLogonQuery) {$NoLogonLEExists="True"} # Validate that the NoLogonLoadEvaluator exists or not
if ($NoLogonLEExists -eq "False") {$EventLog.WriteEntry($Global:NoLogonLoadEvaluator + " Load Evaluator does not exist. Creating " + $Global:NoLogonLoadEvaluator + " Load Evaluator.","Information","141");new-xaloadevaluator $Global:NoLogonLoadEvaluator -description "Temporary Load Evaluator used to report a full load for Citrix Chained Reboot task" -ContextSwitches 0,1
} else {$EventLog.WriteEntry($Global:NoLogonLoadEvaluator + " Load Evaluator already exists.","Information","141")} # Load Evaluator does not exists, creating NoLogonLoadEvaluator
#-----------------------------------------------------------------------------------
#Beginning of scriptblock for Start-job sequence called below
#-----------------------------------------------------------------------------------
$GetWorkerGroupServers = {
param ([string] $workergroupname,$Global:NoLogonLoadEvaluator,[int]$Global:REBOOTINTERVAL,[int]$Global:FARMLOOPINTERVAL,$Global:REBOOTTHISSERVER,$Global:EXCLUDESERVERS,[int]$Global:MAXSERVERS,$Global:ENABLESMTP,$Global:EmailFrom,$Global:EmailTo,$Global:SMTPServer,$Global:SMTPUsername,$Global:SMTPPassword)
$Global:NoUsers = $False # Create a global variable for assessing active sessions
$infiniteLoop = $true # Create an infinite loop variable
$Global:EventLog = New-Object -type System.Diagnostics.Eventlog -argumentlist Application # Creates a global object for logging to the Application event log
$Global:EventLog.Source = "Citrix Chained Reboot" # All event logs will be entered with the source of Citrix Chained Reboot
if ($EnableSMTP -eq $true){$Global:SMTPClient = New-Object Net.Mail.SmtpClient($SmtpServer, 587);$Global:SMTPClient.EnableSsl = $true;$Global:SMTPClient.Credentials = New-Object System.Net.NetworkCredential($SMTPUsername, $SMTPPassword)}
try {
 Add-PSSnapin "Citrix.XenApp.Commands"

 #-----------------------------------------------------------------------------------

 function ServerOnline {
  $server = "$args" # Create a variable named server from the first passed variable
  $serverload = @(get-xaserverload | Where {$_.ServerName -eq $server}) # Create a query to validate the server is online before proceeding
  foreach ($result in $serverload){
   return $true
  }
 }

 #-----------------------------------------------------------------------------------

 } catch {
 if ($EnableSMTP -eq $true){$SMTPClient.Send($EmailFrom, $EmailTo, "Unhandled error has occurred in main program: " + $error[0], "")}
 $EventLog.WriteEntry("Unhandled error has occurred in main program: " + $error[0],"Information") # Brute force error handling method to catch all errors
 }

 #-----------------------------------------------------------------------------------
 #Beginning of scriptblock for ProcessServer job
 #-----------------------------------------------------------------------------------

 $ProcessServer = {
  param ([string]$server,$Global:NoLogonLoadEvaluator,$Global:ENABLESMTP,$Global:EmailFrom,$Global:EmailTo,$Global:SMTPServer,$Global:SMTPUsername,$Global:SMTPPassword)
  try {
  Add-PSSnapin "Citrix.XenApp.Commands"
  $Global:EventLog = New-Object -type System.Diagnostics.Eventlog -argumentlist Application # Creates a global object for logging to the Application event log
  $Global:EventLog.Source = "Citrix Chained Reboot" # All event logs will be entered with the source of Citrix Chained Reboot
  if ($EnableSMTP -eq $true){$Global:SMTPClient = New-Object Net.Mail.SmtpClient($SmtpServer, 587);$Global:SMTPClient.EnableSsl = $true;$Global:SMTPClient.Credentials = New-Object System.Net.NetworkCredential($SMTPUsername, $SMTPPassword)}
  [string]$Global:ServerLoadEvaluator # Create a global load evaluator placeholder to be used for re-assigning the server's LE

  #-----------------------------------------------------------------------------------
  function AssignLE {
   set-xaServerLoadEvaluator -LoadEvaluatorName $args[0] -ServerName $args[1] # Assign Load Evaluator as passed through as first variable to server as passed through as second variable
  }
  #-----------------------------------------------------------------------------------
  function GetLE {
   $Global:ServerLoadEvaluator = (Get-xaLoadEvaluator -ServerName $args[0]).LoadEvaluatorName # Get Load Evaluator for server as passed as first variable
  }
  #-----------------------------------------------------------------------------------

  function CheckConnections {
   $i=0 # Create a zero valued integer to count number of concurrent sessions
   $server = "$args" # Create a variable named server from the first passed variable
   $serveronline = @(get-xaserverload | Where {$_.ServerName -eq $server}) # Create a query to validate the server is online before attempting to reboot
   foreach ($s in $serveronline) {
    $sessions = @(get-xasession | Where {$_.ServerName -eq $server} | Where {$_.State -ne "Listening"} | Where {$_.State -ne "Disconnected"} | Where {$_.SessionName -ne "Console"}) # Create a query against server passed through as first variable where protocol is Ica. Disregard disconnected or listening sessions
    foreach ($session in $sessions) {$i+=1} # Count number of sessions, if there are any active sessions, go to sleep for 5 minutes
    if ($i -eq 0) {
     $Global:NoUsers = $True
     if ($EnableSMTP -eq $true){$SMTPClient.Send($EmailFrom, $EmailTo, "Server " + $server + " has no active sessions." + $error[0], "")}
      $EventLog.WriteEntry("Server " + $server + " has no active sessions.","Information","311")
     } else { 
      Start-Sleep -s 300 }
     
   }
  }

  #-----------------------------------------------------------------------------------
  function StartReboot {
   $server = "$args" # Create a variable named server from the first passed variable
   AssignLE $ServerLoadEvaluator $server # Assign load evaluator
   if ($EnableSMTP -eq $true){$SMTPClient.Send($EmailFrom, $EmailTo, "Assigning " + $ServerLoadEvaluator + " Load Evaluator to " + $server + ".", "")}
   $EventLog.WriteEntry("Assigning " + $ServerLoadEvaluator + " Load Evaluator to " + $server + ".","Information","411")
   Start-Sleep -s 10 # Wait for 10 seconds after assigning load evaluator before initiating shutdown sequence
   Invoke-Expression "Shutdown.exe /m $server /r /t 0 /c ""Shutdown scheduled by Citrix farm chained reboot.""" # Initiate shutdown on remote server
   if ($EnableSMTP -eq $true){$SMTPClient.Send($EmailFrom, $EmailTo, "Initiating reboot process on " + $server + ".", "")}
   $EventLog.WriteEntry("Initiating reboot process on " + $server + ".","Information","911")
   do {
    $rebooted = $false # Reset variable back to false before checking for reboot
    # $EventLog.WriteEntry($server + " has not yet rebooted. Going to sleep for 60 seconds.","Information")
    start-sleep -s 60 # Wait for 60 seconds between checking for reboot completion
    $serverload = @(get-xaserverload | Where {$_.Load -lt "5000"} | Where {$_.ServerName -eq $server}) # Create a query to validate the server is online and load evaluator has reset less than 5000 before proceeding
    foreach ($result in $serverload){
     $rebooted = $true # Server has rebooted and the load evaluator is less than 5000, proceed to next server
     if ($EnableSMTP -eq $true){$SMTPClient.Send($EmailFrom, $EmailTo, $server + " rebooted properly, load rebalanced. Proceeding with subsequent servers.", "")}
     $EventLog.WriteEntry($server + " rebooted properly, load rebalanced. Proceeding with subsequent servers.","Information","811")
    }
   } while ($rebooted -eq $false) # Loop until the server has completed its reboot and load evaluator has returned to idle state
  }

  #-----------------------------------------------------------------------------------
  #Start of main program for ProcessServer job
  #-----------------------------------------------------------------------------------
  $Global:NoUsers = $False # Reset the nousers variable to False
  GetLE $server # Assign ServerLoadEvaluator variable the current load evaluator value
  AssignLE $NoLogonLoadEvaluator $server # Assign the nologon load evaluator before processing each server
  if ($EnableSMTP -eq $true){$SMTPClient.Send($EmailFrom, $EmailTo, "Assigning " + $NoLogonLoadEvaluator + " Load Evaluator to " + $server + ".", "")}
  $EventLog.WriteEntry("Assigning " + $NoLogonLoadEvaluator + " Load Evaluator to " + $server + ".","Information","411")
  Do {CheckConnections $server} while ($NoUsers -eq $False) # Check for active sessions using the CheckConnections function above
  if ($NoUsers -eq $True) { # Continue processing if there are no active sessions
   StartReboot $server # Initialize the StartReboot function 
  }
  } catch {
  if ($EnableSMTP -eq $true){$SMTPClient.Send($EmailFrom, $EmailTo, "Unhandled error has occurred in main program: " + $error[0], "")}
  $EventLog.WriteEntry("Unhandled error has occurred in main program: " + $error[0],"Information") # Brute force error handling method to catch all errors
  }
 }
 #-----------------------------------------------------------------------------------
 #End of scriptblock for ProcessServer job
 #-----------------------------------------------------------------------------------
 #-----------------------------------------------------------------------------------
 #Throttle the total number of jobs
 #-----------------------------------------------------------------------------------
 function ThrottleJobs {
  $jobs = $args[0]
  $max = $args[1]
  $running = @($jobs | ? {$_.State -eq 'Running'})
  while ($running.Count -ge $max) {
   $finished = Wait-Job -Job $jobs -Any
   $running = @($jobs | ? {$_.State -eq 'Running'})
   start-sleep -s 60
  }
 }
 #-----------------------------------------------------------------------------------
 #Start of Main Program
 #-----------------------------------------------------------------------------------
 try {
 if ($workergroupname -eq "AllServers"){
  $workergroupservers = get-xaserver | sort-object -property ServerName # Create an array with all servers sorted alphabetically
 } else {
  $workergroupservers = @(get-xaworkergroupserver -workergroupname $workergroupname | sort-object -property ServerName) # Create a query to pull the Worker Group membership
 }
 $excludedservers = $GLOBAL:EXCLUDESERVERS.Split(',')
 do { # Create an infinite loop
 $jobs = @()
 $lastRun = Get-Date # Create a date in time to compare using the farmloopinterval below
 $intHours = New-Timespan $lastRun $(Get-Date)  # Create a zero integer to compare using the farmloopinterval below
 foreach ($workergroupserver in $workergroupservers){
  $server = $workergroupserver.ServerName
  if (($excludedservers -notcontains $server) -and (ServerOnline $server)) {
   if ("$server" -eq "$env:COMPUTERNAME") { # Bypass local server
    } else {
     if ($EnableSMTP -eq $true){
      try {
       $SMTPClient.Send($EmailFrom, $EmailTo, "Processing server '" + $server + "' from delivery group '" + $deliverygroupname + "'.", "")
      } catch {
       $EventLog.WriteEntry("Fatal error attempting to send e-mail using SMTP. Please resolve the issue or disable SMTP in global variables. " + $error[0],"Error") # Brute force error handling method to catch all errors
      }
     }
     $EventLog.WriteEntry("Processing server '" + $server + "' from worker group '" + $workergroupname + "'.","Information","211")
     $jobs += Start-Job -ScriptBlock $ProcessServer -ArgumentList ($server,$Global:NoLogonLoadEvaluator,$Global:ENABLESMTP,$Global:EmailFrom,$Global:EmailTo,$Global:SMTPServer,$Global:SMTPUsername,$Global:SMTPPassword ) -Name $server
     ThrottleJobs $jobs $MAXSERVERS
     start-sleep -s ($REBOOTINTERVAL * 60) # Sleep for RebootInterval converted to seconds
#     ProcessServer $server
    }
   }
  }
 Wait-Job -Job $jobs > $null
 if ($REBOOTTHISSERVER -eq $true) {
  $jobs += Start-Job -ScriptBlock $ProcessServer -ArgumentList ( $env:COMPUTERNAME,$Global:NoLogonLoadEvaluator,$Global:ENABLESMTP,$Global:EmailFrom,$Global:EmailTo,$Global:SMTPServer,$Global:SMTPUsername,$Global:SMTPPassword ) -Name $env:COMPUTERNAME
  start-sleep -s ($REBOOTINTERVAL * 60) # Sleep for RebootInterval converted to seconds
#  ProcessServer $env:COMPUTERNAME
 }
 do { # Loop until the farmloopinterval has elapsed
  if ($EnableSMTP -eq $true){$SMTPClient.Send($EmailFrom, $EmailTo, "It has been " + $intHours.hours + " hours since last loop for '" + $workergroupname + "'. Waiting for another " + [string]($FARMLOOPINTERVAL-$intHours.hours) + " hours.", "")}
  $EventLog.WriteEntry("It has been " + $intHours.hours + " hours since last loop for '" + $workergroupname + "'. Waiting for another " + [string]($FARMLOOPINTERVAL-$intHours.hours) + " hours.","Information","511")
  start-sleep -s 3600 # Go to sleep for an hour
  $intHours = New-Timespan $lastRun $(Get-Date) # Create IntHours value for comparing against the farmloopinterval
 } while ($intHours.Hours -lt $FARMLOOPINTERVAL) # Compare to see if the time elapsed is less than the farm loop interval
 if ($EnableSMTP -eq $true){$SMTPClient.Send($EmailFrom, $EmailTo, "Worker group '" + $workergroupname + "' loop completed successfully. Relooping through worker group servers.", "")}
 $EventLog.WriteEntry("Worker group '" + $workergroupname + "' loop completed successfully. Relooping through worker group servers.","Information","611")
 }
 while ($infiniteLoop -eq $true) # Infinite loop
 } catch {
 if ($EnableSMTP -eq $true){$SMTPClient.Send($EmailFrom, $EmailTo, "Unhandled error has occurred in main program: " + $error[0], "")}
 $EventLog.WriteEntry("Unhandled error has occurred in main program: " + $error[0],"Information") # Brute force error handling method to catch all errors
 }
}
#-----------------------------------------------------------------------------------
#End of scriptblock for Start-job sequence called below
#-----------------------------------------------------------------------------------
if($Global:WORKERGROUPS -eq ""){
 Start-Job -ScriptBlock $GetWorkerGroupServers -ArgumentList ("AllServers",$Global:NoLogonLoadEvaluator,[int]$Global:REBOOTINTERVAL,[int]$Global:FARMLOOPINTERVAL,$Global:REBOOTTHISSERVER,$Global:EXCLUDESERVERS,[int]$Global:MAXSERVERS,$Global:ENABLESMTP,$Global:EmailFrom,$Global:EmailTo,$Global:SMTPServer,$Global:SMTPUsername,$Global:SMTPPassword) -Name AllServers
} else {
 $workergroups = $GLOBAL:WORKERGROUPS.Split(',') # Split the global WORKERGROUPS variable defined above
 foreach ($workergroup in $workergroups){
 $checkworkergroup = @(get-xaworkergroup | where-object {$_.WorkerGroupName -eq $workergroup})
 if ($checkworkergroup.count -eq 0){
  if ($EnableSMTP -eq $true){$SMTPClient.Send($EmailFrom, $EmailTo, "Worker group name '" + $workergroup + "' is invalid. Check worker group definitions and try again.", "")}
  $EventLog.WriteEntry("Worker group name '" + $workergroup + "' is invalid. Check worker group definitions and try again.","Information","411")
  }
 else {
  Start-Job -ScriptBlock $GetWorkerGroupServers -ArgumentList ( $workergroup ,$Global:NoLogonLoadEvaluator,[int]$Global:REBOOTINTERVAL,[int]$Global:FARMLOOPINTERVAL,$Global:REBOOTTHISSERVER,$Global:EXCLUDESERVERS,[int]$Global:MAXSERVERS,$Global:ENABLESMTP,$Global:EmailFrom,$Global:EmailTo,$Global:SMTPServer,$Global:SMTPUsername,$Global:SMTPPassword) -Name $workergroup
  }
 }
}
$infiniteloop = $true
do {start-sleep -s 3600} while ($infiniteLoop -eq $true)
#-----------------------------------------------------------------------------------
#-----------------------------------------------------------------------------------
#Created by Dane Young, CTP, Entisys Solutions Copyright 2010, 2011, 2012, 2013
#Check http://blog.itvce.com/?p=79 for updates
#Build 2013.12.09 Revision 7
#-----------------------------------------------------------------------------------
#-----------------------------------------------------------------------------------
#THIS POWERSHELL SCRIPT AND ANY RELATED INFORMATION ARE PROVIDED "AS IS" WITHOUT
#WARRANTY OF ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
#IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A PARTICULAR PURPOSE. We
#grant You a nonexclusive, royalty-free right to use and modify the PowerShell Script
#and to reproduce and distribute the object code form of the PowerShell Script,
#provided that You agree: (i) to not use this script in part or in whole for
#profitable gain; (ii) to not change parts of this script including owner information
#and copyright statements without crediting the author; (iii) to not market Your
#software product in which this PowerShell Script is embedded; (iv) to include a
#valid copyright and disclaimer notice wherever this PowerShell Script is embedded;
#and (v) to indemnify, hold harmless, and defend Us and Our suppliers from and
#against any claims or lawsuits, including attorneys’ fees, that arise or result from
#the use or distribution of the PowerShell Script. This posting is provided "AS IS"
#with no warranties, and confers no rights. Use of included script samples are
#subject to the terms specified at http://blog.itvce.com/?page_id=4934.
#-----------------------------------------------------------------------------------
#----------------------------------------------------------------------------------- 

# Authors: William Lam and Deji Akomolafe (Broadcom)
# Description: Example PowerShell script for enabling and detecting vMotion notification operation on a VM and triggering application-specific response
# When launched, this Script will run in a loop every 1 second, querying for the status of the vMotion App-notification process

# The use-case scenario addressed in this Script is a clustered Microsoft SQL Server node
# The objective is to drain the Node first before the vMotion operation proceeds
# When a vMotion operation notification is detected, the Script invokes the native "Suspend-ClusterNode -Drain" command
# The "Suspend-ClusterNode -Drain" command REQUIRES elevated (Admin) privileges, so this Script must be instantiated as an Admin or SYSTEM
# The Script then returns to monitoring for the next vMotion operation notification

# It assumes that the App-Notification feature has been enabled on both the VM and all potential vMotion targets (ESXi Hosts)
# See https://docs.vmware.com/en/VMware-vSphere/8.0/vsphere-vcenter-esxi-management/GUID-0540DF43-9963-4AF9-A4DB-254414DC00DA.html and https://core.vmware.com/resource/vsphere-vmotion-notifications#sec21823-sub1

# User Configurable Variables

# "uniqueToken" ID
# The "UniqueToken" is auto-generated everytime you successfully register vMotion App-Notification on the VM
# vMotion App-notification is registered with the vmtoolsd.exe (so, the VM has to have VMware Tools installed)
# Sample App Registration: vmtoolsd --cmd "vm-operation-notification.register {\"appName\": \"WSFC-vMotion-App\", \"notificationTypes\": [\"sla-miss\"]} "

# First, we set the path to vmtoolsd.exe
$vmtoolsdPath = 'C:\Program Files\VMware\VMware Tools\vmtoolsd.exe'

# You could also just the path to vmtoolsd.exe (usually "C:\Program Files\VMware\VMware Tools\") to the System's environment variable and set $vmtoolsdPath as follows:
# $vmtoolsdPath = 'vmtoolsd.exe'

# Seconds to wait between checks for vMotion App-notification
$vmotionNotifyCheckDuration = "1"

# Log File - Just for reporting purposes
# When a vMotion operation notification is received and the "Suspend-ClusterNode -Drain" command is invoked, we log this to a file
# We also include an option to just continuously log the status of the App-Notification process to a file, even when no vMotion operation notification is received.
# It is not essential for the Script or App-Notification process. The file can also get very large because we are polling and writing logs every 1 second.
# If you prefer to log everything, consider enabling this option in the lines indicated
$vmotionNotifyLogFile = "E:\Install-Files\vMotion-App-Notification\WSFC-vMotion-App-Notification.logs"

### DO NOT EDIT BEYOND HERE, EXCEPT TO ENABLE FULL LOGGING ###

# Now, we register the VM for App-notification and obtain our "uniqueToken"
# Note: This Token does not persist when the VM is rebooted, so we must do this on every reboot (Hint: Add this Script to Windows Task Scheduler as a Startup Script")
$TokenArg = "--cmd `"vm-operation-notification.register {\`"appName\`": \`"WSFC-vMotion-App\`", \`"notificationTypes\`": [\`"sla-miss\`"]}`""

# We now extract the "uniqueToken" from the result of our registration
# Run command to process stdout
$tinfo = New-Object System.Diagnostics.ProcessStartInfo
$tinfo.FileName = $vmtoolsdPath
$tinfo.RedirectStandardError = $true
$tinfo.RedirectStandardOutput = $true
$tinfo.UseShellExecute = $false
$tinfo.Arguments = $TokenArg
$t = New-Object System.Diagnostics.Process
$t.StartInfo = $tinfo
$t.Start() | Out-Null
$t.WaitForExit()
$stdout = $t.StandardOutput.ReadToEnd()
$stderr = $t.StandardError.ReadToEnd()

$jsonResults = $stdout | ConvertFrom-Json
$vmotionNotifyTokenID = $jsonResults.uniqueToken

# Write an entry to the Log File to indicate when we started this run
# Write-Host -ForegroundColor Cyan "`nStarting vMotion Notification Script, please refer to $vmotionNotifyLogFile for more details ...`n"
$message = "$(Get-Date -Format "dddd MM/dd/yyyy HH:mm:ss") Starting vMotion App Notification Monitoring Log"
$message| Out-File -Append -FilePath $vmotionNotifyLogFile

# We have our "uniqueToken" ID now, so let's start querying for its Status
# Run script forever
while(1) {

# Argument to vmtooldsd
$checkArg = "--cmd `"vm-operation-notification.check-for-event {\`"uniqueToken\`": \`"$vmotionNotifyTokenID\`"}`""

# Run command to process stdout
$pinfo = New-Object System.Diagnostics.ProcessStartInfo
$pinfo.FileName = $vmtoolsdPath
$pinfo.RedirectStandardError = $true
$pinfo.RedirectStandardOutput = $true
$pinfo.UseShellExecute = $false
$pinfo.Arguments = $checkArg
$p = New-Object System.Diagnostics.Process
$p.StartInfo = $pinfo
$p.Start() | Out-Null
$p.WaitForExit()
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()

    # Convert results to JSON object
    $jsonResults = $stdout | ConvertFrom-Json

    # We're going to extract the operationId of this current Notification. We will use it to send an acknowledgment back to the vMotion operation
    $vmotionNotifyOpID = $jsonResults.operationId
    # Write-Host -Foregroundcolor White "We extracted this operationId " $vmotionNotifyOpID

    # When App-Notification is received by the VM, a vMotion operation is about to be performed on the VM, so the value of the "eventType" attribute will be "start"
    # When this happens, we need to tell the Windows to prepare the VM for vMotion by failing over its resources
    # In reality, the cluster is paused on the VM so that it can't host an active clustered resource

    if($jsonResults.eventType -eq "start") {
        # The vMotion event has started, so we'll get our Application/VM ready
        $message = "$(Get-Date -Format "dddd MM/dd/yyyy HH:mm:ss") Received vMotion Notification. Draining WSFC Node now"
        Write-Host -ForegroundColor Yellow $message
        # We write a entry into the Log File to show that we detected a notification and drained the cluster.
        $message | Out-File -Append -FilePath $vmotionNotifyLogFile
        # This is a clustered MS SQL Server workload and we just need to failover its resources
        Suspend-ClusterNode -Drain
        # Suspend-ClusterNode command is relatively fast. It should be completed in under 15 seconds.
        Start-Sleep -Seconds 15
#############################################################################################################################################################################################################
# Code Snippet for Event Acknowledgement
            # Once we are done preparing the Application/VM for vMotion, we send an acknowledgement back for vMotion Operation to proceed
            $ackArg = "--cmd `"vm-operation-notification.ack-event {\`"uniqueToken\`": \`"$vmotionNotifyTokenID\`", \`"operationId\`": $vmotionNotifyOpID }`""
            $ainfo = New-Object System.Diagnostics.ProcessStartInfo
            $ainfo.FileName = $vmtoolsdPath
            $ainfo.RedirectStandardError = $true
            $ainfo.RedirectStandardOutput = $true
            $ainfo.UseShellExecute = $false
            $ainfo.Arguments = $ackArg
            $a = New-Object System.Diagnostics.Process
            $a.StartInfo = $ainfo
            $a.Start() #| Out-Null
            $a.WaitForExit()
            $stdout = $a.StandardOutput.ReadToEnd()
            $stderr = $a.StandardError.ReadToEnd()
            
            # We log our App-Notification acknowledgement 
            $message = "$(Get-Date -Format "dddd MM/dd/yyyy HH:mm:ss") Informing App-Notification that we are ready for vMotion now"
            Write-Host -ForegroundColor White $message
            # We write a entry into the Log File to show that we resumed cluster services on the Node.
            $message | Out-File -Append -FilePath $vmotionNotifyLogFile

#############################################################################################################################################################################################################


    } elseif($jsonResults.eventType -eq "end") {
        # The vMotion event is now over, so we are going to resume WSFC on the Node
        $message = "$(Get-Date -Format "dddd MM/dd/yyyy HH:mm:ss") Received notification that vMotion operation has completed. Un-pausing WSFC Node now"
        Write-Host -ForegroundColor Yellow $message
        # We write a entry into the Log File to show that we resumed cluster services on the Node.
        $message | Out-File -Append -FilePath $vmotionNotifyLogFile
        Resume-ClusterNode
    }

     else {
        $message = "$(Get-Date -Format "dddd MM/dd/yyyy HH:mm:ss") No pending vMotion operation detected"
        Write-Host -ForegroundColor Green $message
        # If you would like to keep a log of the Script's running state even when it detects no vMotion operation notification, uncomment the following line
        # $message| Out-File -Append -FilePath $vmotionNotifyLogFile
    }

    # Sleep for n seconds
    $message = "$(Get-Date -Format "dddd MM/dd/yyyy HH:mm:ss") Sleeping for $vmotionNotifyCheckDuration second(s)"
    # If you would like to keep a log of the Script's running state even when its sleeping, uncomment the following line. The File can get quite large if you do this.
    # $message| Out-File -Append -FilePath $vmotionNotifyLogFile
    Start-Sleep -Seconds $vmotionNotifyCheckDuration
}
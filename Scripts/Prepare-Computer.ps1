[CmdletBinding()]
Param()

Function Get-DCName
{
    (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\History' -Name DCName).DCName
}

Function Test-NetWorkConnection 
{
    [CmdletBinding()]
    Param(
        [string]$ComputerName,
        [int32]$Port
    )
    
    Try 
    {
        $TCPClient = New-Object -TypeName System.Net.Sockets.Tcpclient -ErrorAction stop
        $TCPClient.Connect($ComputerName,$port)
        $Result = $TCPClient.Connected
    } 
    Catch 
    {
        $Result = $false
    }
    Finally
    {
        If($Result)
        {
            $TCPClient.Close()
        }
    }

    Return $Result
}

Function Get-TSVariable 
{
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$TSVariable
    )

    $TSEnvironment = New-Object -COMObject Microsoft.SMS.TSEnvironment
    $TSEnvironment.Value($TSVariable)
}

Function Register-ComputerRenameInfo
{
    [CmdletBinding()]
    Param()

    Try
    {
        # Create new WMI class
        $NewClassName = 'CM_ComputerRenameInfo'
        Remove-WmiObject $NewClassName -ErrorAction SilentlyContinue

        $newClass = New-Object System.Management.ManagementClass ("root\cimv2", [String]::Empty, $null) -ErrorAction Stop
        $newClass["__CLASS"] = $NewClassName
        $newClass.Qualifiers.Add("Static", $true)
        $newClass.Properties.Add("OldComputerName", [System.Management.CimType]::String, $false)
        $newClass.Properties.Add("NewComputerName", [System.Management.CimType]::String, $false)
        $newClass.Properties.Add("RenameDate", [System.Management.CimType]::DateTime, $false)
        $newClass.Properties.Add("RenameStatus", [System.Management.CimType]::String, $false)
        $newClass.Properties["NewComputerName"].Qualifiers.Add("Key", $true)
        $newClass.Put() | Out-Null
        Write-Output "***************`n[register-ComputerRenameInfo] Successfully Created WMI Class`n***************"
    }
    Catch
    {
        "***************`n[register-ComputerRenameInfo] Could not create wmi class. Error: $($_.Exception.Message)`n***************"
        Exit
    }
}

Function Set-ComputerRenameInfo
{
    [CmdletBinding()]
    Param(
        [string]$OldComputerName,
        [string]$NewComputerName,
        [string]$RenameStatus,
        [string]$RenameDate
    )

    $FilteredProperties = $MyInvocation.BoundParameters.GetEnumerator() | Where-Object{$_.Key -ne "ErrorAction"}

    $Properties = @{}
    $FilteredProperties | Foreach { $Properties.Add($_.Key,$_.Value) }

    #$Properties = @{
    #                OldComputerName = $OldComputerName
    #                NewComputerName = $NewComputerName
    #                RenameStatus = $RenameStatus
    #                RenameDate = $RenameDate
    #                }

    Try 
    {
        # Set information in new class
        Set-WmiInstance -Namespace root\cimv2 -Class 'CM_ComputerRenameInfo' -Arguments $Properties -ErrorAction Stop | Out-Null
        Write-Output "***************`n[Set-ComputerRenameInfo] Successfully added values to ComputerRenameInfo object`n***************"
    } 
    Catch 
    {
        "***************`n[Set-ComputerRenameInfo] Could not set Set-ComputerRenameInfo Instance. Error: $($_.Exception.Message)`n***************"
    }

    Try 
    {
        "***************`n[Set-ComputerRenameInfo] Successfully sent HWInventory Info`n***************"
    } 
    Catch 
    {
        "***************`n[Set-ComputerRenameInfo] Could not send HW Inventory. Error: $($_.Exception.Message)`n***************"
    }
}

Function Get-CIMDateTime 
{
    <#
    HighLEvel Steps

    1) Get String with UTC ofsset pattern. Ie: 20200408115224.000000+03:00 while doing so get the UTCSign and the UTCHour
    2) Split the the hour and make calculatations to convert to 3 digit minutes
    3) Replace the +3:00 with the calculated 180
    #>

    $CimDateString= get-date -Format "yyyyMMddHHmmss.000000K"

    If ($CimDateString -match '(?<UTCSign>\+|-)(?<UTC>.+)')
    {
        $UTCArray = $Matches['UTC'] -split ':'
        $UTCMinutes =  "{0:d3}" -f  ([int]$UTCArray[0] *60 + [int]$UTCArray[1])
        $CimDateString -replace '\+(.+)' ,"$($Matches['UTCSign'])$UTCMinutes"
    }
}

Function Test-DCConnection 
{
    [CmdletBinding()]
    Param()

    # remove the \\ from logonserver variable
    $(Get-DCName) -match '\\\\(?<LogonServer>.+)' | Out-Null

    If (Test-NetWorkConnection -ComputerName ($Matches['LogonServer']) -Port 389) 
    {
        <#
        add if gui issue resolves
        $TSEnvironment.Value('DCConnection') = $true
        #>
        $true
    } 
    Else 
    {
        <#
        add if gui issue resolves
        $TSEnvironment.Value('DCConnection') = $false
        #>
        $false
    }
}

Function Test-ComputerNameCompliancy 
{
    [Cmdletbinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$NewComputerName
    )

    if ($env:COMPUTERNAME -eq $NewComputerName) 
    {
        <#
        add if gui issue resolves
        $TSEnvironment.Value('ComputerNameCompliancy') = $true
        #>
        $true
    } 
    Else 
    {
        <#
        add if gui issue resolves
        $TSEnvironment.Value('ComputerNameCompliancy') = $false
        #>
        $false
    }
}

# Script Main #############################
# Get Computer name
Try 
{
    $TSEnvironment = New-Object -COMObject Microsoft.SMS.TSEnvironment
    $NewComputerName = $TSEnvironment.Value('TSRenameCompName')
    Register-ComputerRenameInfo -ErrorAction Stop
    Write-Output "***************`n[Script Main] Succesfully Prepared environment.`n***************"
}
Catch 
{
    "***************`n[register-ComputerRenameInfo] Prepare computer (Get newcomputer name or prepare wmi) initally: $($_.Exception.Message)`n***************"
    Exit
}

$DCConnectionResult = Test-DCConnection
$ComputerNameCompliancyResult = Test-ComputerNameCompliancy -NewComputerName $NewComputerName

If ($ComputerNameCompliancyResult) 
{
    $RenameStatus = 'Compliant'
} 
Else 
{ 
    If ($DCConnectionResult) 
    {
        $RenameStatus = 'ReadyToRename'
        $TSEnvironment.Value("RenameStatus") = 'ReadyToRename'
    } 
    Else 
    {
        # not compliant and cannot connect to dc
        $RenameStatus = 'Cannot connect to dc'
    }
}

Set-ComputerRenameInfo -NewComputerName $NewComputerName -OldComputerName $Env:COMPUTERNAME -RenameStatus $RenameStatus 

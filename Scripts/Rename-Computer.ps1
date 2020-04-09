[CmdletBinding()]
Param()

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
        Get-WMIObject -Namespace root\cimv2 -Class 'CM_ComputerRenameInfo' | Set-WmiInstance -Arguments $Properties | Out-Null
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

# Script Main #############################
Try 
{
    $NewComputerName = (Get-WmiObject -Class CM_ComputerRenameInfo -ErrorAction Stop).NewComputerName

    If(-not([string]::IsNullOrEmpty($NewComputerName))) 
    {
        Try 
        {
            $Object = Get-WmiObject -Class win32_computersystem -ErrorAction Stop
            $RenameResult = $Object.Rename($NewComputerName)

            If ($RenameResult.ReturnValue -eq 0) 
            {
                Write-Output "***************`n[Rename-LocalComputer] Successfully renamed computer name to $NewComputerName`n***************"
                Set-ComputerRenameInfo -NewComputerName $NewComputerName -RenameStatus 'OK' -RenameDate $(Get-CIMDateTime) -ErrorAction stop
            } 
            Else 
            {
                Write-Output "***************`n[Rename-LocalComputer] Could not rename to $NewComputerName. Error occured during rename operation. Errorcode: $($RenameResult.ReturnValue)`n***************"
                Set-ComputerRenameInfo -NewComputerName $NewComputerName -RenameStatus 'Failed' -RenameDate $(Get-CIMDateTime) -ErrorAction Stop
            }
        } 
        Catch 
        {
             "***************`n[Rename-LocalComputer] Could rename to $NewComputerName. Error: $($_.Exception.Message)`n***************"
        }
    }
}
Catch
{
     "***************`n[Rename-Computer] Could read to NewComputerName variable. Error: $($_.Exception.Message)`n***************"
}

[CmdledBinding()]
Param()

try {

$NewComputerName = (Get-WmiObject -Class CM_ComputerRenameInfo -ErrorAction Stop).NewComputerName
if(-not([string]::IsNullOrEmpty($NewComputerName))) {


try {

$Object = Get-WmiObject -Class win32_computersystem -ErrorAction Stop
$RenameResult = $Object.Rename($NewComputerName)
if ($RenameResult.ReturnValue -eq 0) {

Write-Output "***************`n[Rename-LocalComputer] Successfully renamed computer name to $NewComputerName`n***************"
Set-ComputerRenameInfo -NewComputerName $NewComputerName -RenameStatus 'Compliant' -RenameDate Get-CIMDateTime -ErrorAction stop
} else {

Write-Output "***************`n[Rename-LocalComputer] Could not rename to $NewComputerName. Error occured during rename operation. Errorcode: $($RenameResult.ReturnValue)`n***************"

$Script:TSEnvironment.Value('RenameFailed') = $true
Set-ComputerRenameInfo -NewComputerName $NewComputerName -RenameStatus 'Failed' -RenameDate Get-CIMDateTime -ErrorAction Stop

}

} catch {

 "***************`n[Rename-LocalComputer] Could rename to $NewComputerName. Error: $($_.Exception.Message)`n***************"

}

}

}
catch{


 "***************`n[Rename-Computer] Could read to NewComputerName variable. Error: $($_.Exception.Message)`n***************"

}

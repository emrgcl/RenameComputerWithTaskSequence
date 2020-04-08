Param(
    [string]$SiteCode = "TER",                         # Site code 
    [string]$ProviderMachineName = "TCM01.terzi.local" # SMS Provider machine name

)
# Main ###############################

# Import ConfigMgr Module
Import-Module "$($ENV:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1"
If((Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue) -eq $null) 
{ 
    New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName 
}
Set-Location "$($SiteCode):\" 

# Import CVS file
$Data = Import-Csv -Path "$PSScriptRoot\ComputerNameList.csv" -Delimiter ";"

ForEach($Computer in $Data)
{
    If((Get-CMDevice -Name $Computer.OldName).isClient -eq $true)
    {
        New-CMDeviceVariable -DeviceName $Computer.OldName -VariableName "TSRenameCompName" -VariableValue $Computer.NewName | Out-Null
        Write-Output "$($Computer.OldName): Tamam." 
    }
    Else
    {
        Write-Output "$($Computer.OldName): Ajan yok."
    }
}



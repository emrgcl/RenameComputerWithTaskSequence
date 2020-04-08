[CmdletBinding()]
Param()

class NetRouteDiagnostics
{
    #Remote hostname used for routing
    [String] $ComputerName

    #Remote IP address used for routing
    [System.Net.IPAddress] $RemoteAddress

    #Resolved IP addresses for ComputerName
    [System.Net.IPAddress[]] $ResolvedAddresses

    #SourceAddress constraint used for routing
    [System.Net.IPAddress] $ConstrainSourceAddress

    #Interface constraint used for routing
    [UInt32] $ConstrainInterfaceIndex

    #SourceAddress selected for routing
    [Microsoft.Management.Infrastructure.CimInstance] $SelectedSourceAddress

    #Outgoing interface information selected for routing
    [String] $OutgoingInterfaceAlias
    [UInt32] $OutgoingInterfaceIndex
    [String] $OutgoingInterfaceDescription
    [Microsoft.Management.Infrastructure.CimInstance] $OutgoingNetAdapter

    #NetRoute selected for routing
    [Microsoft.Management.Infrastructure.CimInstance] $SelectedNetRoute

    #Log file used for logging route events
    [String] $LogFile

    #Events logged during routing
    [String[]] $RouteSelectionEvents
    [String[]] $SourceAddressSelectionEvents
    [String[]] $DestinationAddressSelectionEvents

    #An indicator to the formatter that details should be shown
    [Bool] $Detailed

    #If diagnostics succeeded
    [Bool] $RouteDiagnosticsSucceeded
}

class TestNetConnectionResult
{
    [String] $ComputerName

    #The Remote IP address used for connectivity
    [System.Net.IPAddress] $RemoteAddress

    #Resolved IP addresses for ComputerName
    [System.Net.IPAddress[]] $ResolvedAddresses

    #Indicates if the Ping was successful
    [Bool] $PingSucceeded

    #Details of the ping
    [System.Net.NetworkInformation.PingReply] $PingReplyDetails

    #The TCP socket
    [System.Net.Sockets.Socket] $TcpClientSocket

    #If the test succeeded
    [Bool] $TcpTestSucceeded

    #Remote port used
    [UInt32] $RemotePort

    #The results of the traceroute
    [String[]] $TraceRoute

    #An indicator to the formatter that details should be shown
    [Bool] $Detailed

    #Information on the interface used for connectivity
    [String] $InterfaceAlias
    [UInt32] $InterfaceIndex
    [String] $InterfaceDescription
    [Microsoft.Management.Infrastructure.CimInstance] $NetAdapter
    [Microsoft.Management.Infrastructure.CimInstance] $NetRoute

    #Source IP address
    [Microsoft.Management.Infrastructure.CimInstance] $SourceAddress

    #DNS information
    [Bool] $NameResolutionSucceeded
    [Object] $BasicNameResolution
    [Object] $LLMNRNetbiosRecords
    [Object] $DNSOnlyRecords
    [Object] $AllNameResolutionResults

    #NetSec Info
    [Bool] $IsAdmin #If the test succeeded
    [String] $NetworkIsolationContext
    [Microsoft.Management.Infrastructure.CimInstance[]] $MatchingIPsecRules	
}

Function Test-NetWorkConnection {
    [CmdletBinding( )]
    Param(
        [Parameter(Mandatory = $false, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true, Position = 0)]
        [Alias('RemoteAddress','cn')]
        [String] $ComputerName = "internetbeacon.msedge.net",

        [Parameter(ParameterSetName = "ICMP", Mandatory = $False)]
        [Switch] $TraceRoute,

        [Parameter(ParameterSetName = "ICMP", Mandatory = $False)]
        [ValidateRange(1,120)]
        [Int] $Hops = 30,

        [Parameter(ParameterSetName = "CommonTCPPort", Mandatory = $True, Position = 1)]
        [ValidateSet("HTTP", "RDP", "SMB", "WINRM")]
        [String] $CommonTCPPort = "",

        [Parameter(ParameterSetName = "RemotePort", Mandatory = $True, ValueFromPipelineByPropertyName = $true)]
        [Alias('RemotePort')] [ValidateRange(1,65535)]
        [Int] $Port = 0,

        [Parameter(ParameterSetName = "NetRouteDiagnostics", Mandatory = $True)]
        [Switch] $DiagnoseRouting,

        [Parameter(ParameterSetName = "NetRouteDiagnostics", Mandatory = $False)]
        [String] $ConstrainSourceAddress = "",

        [Parameter(ParameterSetName = "NetRouteDiagnostics", Mandatory = $False)]
        [UInt32] $ConstrainInterface = 0,

        [ValidateSet("Quiet", "Detailed")]
        [String] $InformationLevel = "Standard"
    )

    Begin
    {

        ##Description: Checks if the local execution context is elevated
        ##Input: None
        ##Output: Boolean. True if the local execution context is elevated.
        function CheckIfAdmin 
        {
            $CurrentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
            $CurrentSecurityPrincipal = [System.Security.Principal.WindowsPrincipal]::new($CurrentIdentity)
            $AdminPrincipal = [System.Security.Principal.WindowsBuiltInRole]::Administrator
            return $CurrentSecurityPrincipal.IsInRole($AdminPrincipal)
        }

        ##Description: Resolves a hostname.
        ##Input: The user-provided computername that will be pinged/tested
        ##Output: The resolved IP addresses for computername
        function ResolveTargetName
        {
            param ($TargetName)

            $Addresses = $null
            try
            {
                $Addresses = [System.Net.Dns]::GetHostAddressesAsync($TargetName).GetAwaiter().GetResult()
            }
            catch
            {
                Write-Debug "Name resolution of $TargetName threw exception: $($_.Exception.Message)"
            }

            if ($Addresses -eq $null) 
            {
                Write-Warning "Name resolution of $TargetName failed"
            }

            return $Addresses
        }

        ##Description: Pings a specified host
        ##Input: IP address to ping
        ##Output: PingReplyDetails for the ping attempt to host
        function PingTest
        {
            param ($TargetIPAddress)

            $Ping = [System.Net.NetworkInformation.Ping]::new()
            $PingReplyDetails = $null

            ##Indeterminate progress indication
            Write-Progress  -Activity "Test-NetConnection :: $TargetIPAddress" -Status "Ping/ICMP Test" -CurrentOperation "Waiting for echo reply" -SecondsRemaining -1 -PercentComplete -1

            try
            {
                $PingReplyDetails = $Ping.SendPingAsync($TargetIPAddress).GetAwaiter().Getresult()
            }
            catch
            {
                Write-Debug "Ping to $TargetIPAddress threw exception: $($_.Exception.Message)"
            }
            finally
            {
                $Ping.Dispose()
            }

            return $PingReplyDetails
        }

        ##Description: Traces a route to a specified IP address using repetitive echo requests
        ##Input: IP address to trace against
        ##Output: Array of IP addresses representing the traced route. The message from the ping reply status is emmited, if there is no response.
        function TraceRoute
        {
            param ($TargetIPAddress,$Hops)

            $Ping = [System.Net.NetworkInformation.Ping]::new()
            $PingOptions = [System.Net.NetworkInformation.PingOptions]::new()
            $PingOptions.Ttl = 1
            [Byte[]]$DataBuffer = @()
            1..10 | foreach {$DataBuffer += [Byte]0}
            $ReturnTrace = @()
             
            do
            {
                try
                {
                    $CurrentHop = [int] $PingOptions.Ttl
                    write-progress -CurrentOperation "TTL = $CurrentHop" -Status "ICMP Echo Request (Max TTL = $Hops)" -Activity "TraceRoute" -PercentComplete -1 -SecondsRemaining -1
                    $PingReplyDetails = $Ping.SendPingAsync($TargetIPAddress, 4000, $DataBuffer, $PingOptions).GetAwaiter().Getresult()

                    if ($PingReplyDetails.Address -eq $null)
                    {
                        $ReturnTrace += $PingReplyDetails.Status.ToString()
                    }
                    else
                    {
                        $ReturnTrace += $PingReplyDetails.Address.IPAddressToString
                    }
                }
                catch
                {
                    Write-Debug "Ping to $TargetIPAddress threw exception: $($_.Exception.Message)"
                    $ReturnTrace += "..."
                }
                $PingOptions.Ttl++
            }
            while (($PingReplyDetails.Status -ne 'Success') -and ($PingOptions.Ttl -le $Hops))

            ##If the last entry in the trace does not equal the target, then the trace did not successfully complete
            if ($ReturnTrace[-1] -ne $TargetIPAddress)
            {
                $OutputString = "Trace route to destination " + $TargetIPAddress + " did not complete. Trace terminated :: " + $ReturnTrace[-1]
                Write-Warning $OutputString
            }

            $Ping.Dispose()
            return $ReturnTrace
        }

        ##Description: Attempts a TCP connection against a specified IP address
        ##Input: IP address and port to connect to
        ##Output: If the connection succeeded (as a boolean)
        function TestTCP
        {
            param ($TargetIPAddress,$TargetPort)
            
            $ProgressString = "Test-NetConnection - " + $TargetIPAddress + ":" + $TargetPort
            Write-Progress -Activity $ProgressString -Status "Attempting TCP connect" -CurrentOperation "Waiting for response" -SecondsRemaining -1 -PercentComplete -1                      
            
            $Success = $False
            $TCPClient = [System.Net.Sockets.TcpClient]::new($TargetIPAddress.AddressFamily)
            try
            {
                $null = $TCPClient.ConnectAsync($TargetIPAddress, $TargetPort).GetAwaiter().Getresult()
                $Success = $TCPClient.Connected;
            }
            catch
            {
                Write-Debug "TCP connect to ($TargetIPAddress : $TargetPort) threw exception: $($_.Exception.Message)"
            }
            finally
            {
                $TCPClient.Dispose()
            }

            return $Success
        }

        ##Description: Modifies the provided object with the correct local connectivty information
        ##Input: TestNetConnectionResults object that will be modified
        ##Output: Modified TestNetConnectionResult object
        function ResolveRoutingandAdapterWMIObjects
        {
            param ($TestNetConnectionResult)

            try
            {
                $TestNetConnectionResult.SourceAddress, $TestNetConnectionResult.NetRoute = Find-NetRoute -RemoteIPAddress $TestNetConnectionResult.RemoteAddress -ErrorAction SilentlyContinue
                $TestNetConnectionResult.NetAdapter = $TestNetConnectionResult.NetRoute | Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue

                $TestNetConnectionResult.InterfaceAlias = $TestNetConnectionResult.NetRoute.InterfaceAlias
                $TestNetConnectionResult.InterfaceIndex = $TestNetConnectionResult.NetRoute.InterfaceIndex
                $TestNetConnectionResult.InterfaceDescription =  $TestNetConnectionResult.NetAdapter.InterfaceDescription
            }
            catch
            {
                Write-Debug "ResolveRoutingandAdapterWMIObjects threw exception: $($_.Exception.Message)"
            }
            return $TestNetConnectionResult
        }

        ##Description: Resolves the DNS details for the computername
        ##Input: The TestNetConnectionResults object that will be "filled in" with DNS information
        ##Output: The modified TestNetConnectionResults object
        function ResolveDNSDetails
        {
            param ($TestNetConnectionResult)

            $TestNetConnectionResult.DNSOnlyRecords = @( Resolve-DnsName $ComputerName -DnsOnly -NoHostsFile -Type A_AAAA -ErrorAction SilentlyContinue | where-object {($_.QueryType -eq "A") -or ($_.QueryType -eq "AAAA") } )
            $TestNetConnectionResult.LLMNRNetbiosRecords = @( Resolve-DnsName $ComputerName -LlmnrNetbiosOnly   -NoHostsFile -ErrorAction SilentlyContinue | where-object {($_.QueryType -eq "A") -or ($_.QueryType -eq "AAAA") } )
            $TestNetConnectionResult.BasicNameResolution = @(Resolve-DnsName $ComputerName -ErrorAction SilentlyContinue | where-object {($_.QueryType -eq "A") -or ($_.QueryType -eq "AAAA")} )

            $TestNetConnectionResult.AllNameResolutionResults = $Return.BasicNameResolution  + $Return.DNSOnlyRecords + $Return.LLMNRNetbiosRecords | Sort-Object -Unique -Property Address
            return $TestNetConnectionResult
        }

        ##Description: Resolves the network security details for the computername
        ##Input: The TestNetConnectionResults object that will be "filled in" with network security information
        ##Output: Teh modified TestNetConnectionResults object
        function ResolveNetworkSecurityDetails
        {
            param ($TestNetConnectionResult)

            $TestNetConnectionResult.IsAdmin  = CheckIfAdmin
            $NetworkIsolationInfo = Invoke-CimMethod -Namespace root\standardcimv2 -ClassName MSFT_NetAddressFilter -MethodName QueryIsolationType -Arguments @{InterfaceIndex = [uint32]$TestNetConnectionResult.InterfaceIndex; RemoteAddress = [string]$TestNetConnectionResult.RemoteAddress} -ErrorAction SilentlyContinue

            switch ($NetworkIsolationInfo.IsolationType)
            {
                1 {$TestNetConnectionResult.NetworkIsolationContext = "Private Network";}
                0 {$TestNetConnectionResult.NetworkIsolationContext = "Loopback";}
                2 {$TestNetConnectionResult.NetworkIsolationContext = "Internet";}
            }

            ##Elevation is required to read IPsec information for the connection.
            if ($TestNetConnectionResult.IsAdmin)
            {
                $TestNetConnectionResult.MatchingIPsecRules = Find-NetIPsecRule -RemoteAddress $TestNetConnectionResult.RemoteAddress  -RemotePort $TestNetConnectionResult.RemotePort -Protocol TCP -ErrorAction SilentlyContinue
            }

            return $TestNetConnectionResult
        }

        ##Description: Diagnose route selection for a destination
        ##Input: RouteDiagnosticsResults object that will be filled on with route diagnostics information.
        ##Output: None
        function DiagnoseRouteSelection
        {
            param ([NetRouteDiagnostics] $RouteDiagnostics)
            
            $RouteDiagnostics.RouteDiagnosticsSucceeded = $False

            if ($RouteDiagnostics.Detailed) 
            {
                Write-Progress  -Activity "Test-NetConnection :: $($RouteDiagnostics.RemoteAddress)" -Status "RouteDiagnostics" -CurrentOperation "Starting Route Event Tracing" -SecondsRemaining -1 -PercentComplete -1

                $LogFile = ""
                do 
                {
                    $LogFile = [System.IO.Path]::GetTempFileName().split(".")[0] + "Test-NetConnection.etl"
                } 
                while (Test-Path -Path $LogFile -ErrorAction SilentlyContinue)

                $TraceResults = netsh trace start tracefile=$LogFile provider=Microsoft-Windows-TCPIP keywords=ut:TcpipRoute report=di perfmerge=no correlation=di         
            }

            Write-Progress  -Activity "Test-NetConnection :: $($RouteDiagnostics.ComputerName)" -Status "RouteDiagnostics" -CurrentOperation "Resolving name" -SecondsRemaining -1 -PercentComplete -1

            $RouteDiagnostics.ResolvedAddresses = ResolveTargetName -TargetName $RouteDiagnostics.ComputerName
            if ($RouteDiagnostics.ResolvedAddresses -eq $null)
            {
                netsh trace stop | out-null
                return
            }

            $RouteDiagnostics.RemoteAddress = $RouteDiagnostics.ResolvedAddresses[0]

            if ($RouteDiagnostics.ConstrainSourceAddress -eq $null) 
            {
                if ($RouteDiagnostics.RemoteAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork)
                {
                    $RouteDiagnostics.ConstrainSourceAddress = [System.Net.IPAddress]::Any
                }
                else 
                {
                    $RouteDiagnostics.ConstrainSourceAddress = [System.Net.IPAddress]::IPv6Any
                }
            }

            if ($RouteDiagnostics.Detailed -and (Test-Path -Path $LogFile))
            {
                ##Flush the destination cache to trigger a new route route lookup
                if ($RouteDiagnostics.RemoteAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork)
                {
                    netsh int ipv4 delete destinationcache | out-null
                }
                else
                {
                    netsh int ipv6 delete destinationcache | out-null
                }
            }

            Write-Progress  -Activity "Test-NetConnection :: $($RouteDiagnostics.RemoteAddress)" -Status "RouteDiagnostics" -CurrentOperation "Finding route" -SecondsRemaining -1 -PercentComplete -1

            try
            {
                $RouteDiagnostics.SelectedSourceAddress, $RouteDiagnostics.SelectedNetRoute = `
                    Find-NetRoute -RemoteIPAddress $RouteDiagnostics.RemoteAddress -LocalIPAddress $RouteDiagnostics.ConstrainSourceAddress -InterfaceIndex $RouteDiagnostics.ConstrainInterfaceIndex -ErrorAction SilentlyContinue

                $RouteDiagnostics.OutgoingNetAdapter = $RouteDiagnostics.SelectedNetRoute | Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue

                $RouteDiagnostics.OutgoingInterfaceAlias = $RouteDiagnostics.SelectedNetRoute.InterfaceAlias
                $RouteDiagnostics.OutgoingInterfaceIndex = $RouteDiagnostics.SelectedNetRoute.InterfaceIndex
                $RouteDiagnostics.OutgoingInterfaceDescription =  $RouteDiagnostics.OutgoingNetAdapter.InterfaceDescription
            }
            catch
            {
                Write-Debug "Error occured while finding route information. Exception: $($_.Exception.Message)"
                netsh trace stop | out-null
                return
            }

            if ($RouteDiagnostics.Detailed) 
            {
                Write-Progress  -Activity "Test-NetConnection :: $($RouteDiagnostics.RemoteAddress)" -Status "RouteDiagnostics" -CurrentOperation "Parsing Route Events" -SecondsRemaining -1 -PercentComplete -1

                $TraceResults += netsh trace stop

                if (-not (Test-Path -Path $LogFile)) 
                {
                    $Message = "Error occured while collection routing events. Error: " + $TraceResults
                    Write-Warning $Message
                    return
                }

                ##Get route selection events: [IpRouteSelection (task:1378) and IpRouteBlocked (task:1379)] containing the remote IP
                $RouteEvents = Get-WinEvent -Path $LogFile -Oldest | Where-Object {(($_.task -eq "1379") -or ($_.task -eq "1378")) -and (($_.Message -ne $null) -and $_.Message.Contains("$($RouteDiagnostics.RemoteAddress) "))}
                foreach ($event in $RouteEvents) 
                {
                    if ($RouteDiagnostics.RouteSelectionEvents -notcontains $($event.Message))
                    {
                        $RouteDiagnostics.RouteSelectionEvents += "$($event.Message)"
                    }
                }

                ##Get source address selection events: [IpSourceAddressSelection (task:1326)] containing the remote IP
                $SrcAddrEvents = Get-WinEvent -Path $LogFile -Oldest | Where-Object {($_.task -eq "1326") -and (($_.Message -ne $null) -and $_.Message.Contains("$($RouteDiagnostics.RemoteAddress) "))}
                foreach ($event in $SrcAddrEvents) 
                {
                    if ($RouteDiagnostics.SourceAddressSelectionEvents -notcontains $($event.Message))
                    {                    
                        $RouteDiagnostics.SourceAddressSelectionEvents += "$($event.Message)"
                    }
                }

                ##Get destination address selection events: [IpSortedAddressPairs (task:1327)] containing the resolved IPs
                $DstAddrEvents = Get-WinEvent -Path $LogFile -Oldest | Where-Object {($_.task -eq "1327") -and ((($Message = $_.Message) -ne $null) -and (@(($RouteDiagnostics.ResolvedAddresses | ForEach-Object {$_.IPAddressToString}) | where {$Message.Contains("$_)")}) -ne $null))}
                foreach ($event in $DstAddrEvents)
                {
                    if ($RouteDiagnostics.DestinationAddressSelectionEvents -notcontains $($event.Message))
                    {                    
                        $RouteDiagnostics.DestinationAddressSelectionEvents += "$($event.Message)"
                    }
                }

                $RouteDiagnostics.LogFile = $LogFile
            }

            $RouteDiagnostics.RouteDiagnosticsSucceeded = $True

            return
        }
    }

    Process
    {
        switch ($PSCmdlet.ParameterSetName) 
        {

        ##Route diagnostics parameterset
        "NetRouteDiagnostics" 
        {
            $Return = [NetRouteDiagnostics]::new()
            $Return.ComputerName = $ComputerName

            if ($ConstrainSourceAddress -ne "")
            {
                $Return.ConstrainSourceAddress = $ConstrainSourceAddress
            }

            $Return.ConstrainInterfaceIndex = $ConstrainInterface

            $Return.Detailed = ($InformationLevel -eq "Detailed")
            if ($Return.Detailed -and (-not (CheckIfAdmin))) {
                Write-Warning "'-InformationLevel Detailed' requires elevation (Run as administrator)."
                $Return.Detailed = $False
            }

            DiagnoseRouteSelection -RouteDiagnostics $Return

            return $Return
        }

        ##Test connection parametersets
        default 
        {
            ##Construct the return object and fill basic details
            $Return = [TestNetConnectionResult]::new()
            $Return.ComputerName = $ComputerName
            $Return.Detailed = ($InformationLevel -eq "Detailed")

            #### Begin Name Resolution ####

            $Return.ResolvedAddresses = ResolveTargetName -TargetName $ComputerName
            if ($Return.ResolvedAddresses -eq $null)
            {
                if ($InformationLevel -eq "Quiet")
                {
                    return $False
                }

                $Return.NameResolutionSucceeded = $False
                return $Return
            }

            $Return.RemoteAddress = $Return.ResolvedAddresses[0]
            $Return.NameResolutionSucceeded = $True
            #### End of Name Resolution ####

            #### Begin TCP test ####

            ##Attempt TCP test only if Port or CommonTCPPort is specified
            $AttemptTcpTest = ($PSCmdlet.ParameterSetName -eq "CommonTCPPort") -or ($PSCmdlet.ParameterSetName -eq "RemotePort")
            if ($AttemptTcpTest)
            { 
                $Return.TcpTestSucceeded = $False

                switch ($CommonTCPPort)
                {
                ""      {$Return.RemotePort = $Port}
                "HTTP"  {$Return.RemotePort = 80}
                "RDP"   {$Return.RemotePort = 3389}
                "SMB"   {$Return.RemotePort = 445}
                "WINRM" {$Return.RemotePort = 5985}
                }
            
                ##Try TCP connect using all resolved addresses until it succeeds
                $Iter = 0
                while (($Iter -lt $Return.ResolvedAddresses.Count) -and (-not $Return.TcpTestSucceeded))
                {
                    $Return.TcpTestSucceeded = TestTCP -TargetIPAddress $Return.ResolvedAddresses[$Iter] -TargetPort $Return.RemotePort
                    ##Output a warning message if the TCP test didn't succeed
                    if (-not $Return.TcpTestSucceeded)
                    {
                        Write-Warning "TCP connect to ($($Return.ResolvedAddresses[$Iter]) : $($Return.RemotePort)) failed"
                    }
                    $Iter++
                }
                
                if ($Return.TcpTestSucceeded)
                {
                    ##Get the remote address that was actually used for connection
                    $Return.RemoteAddress = $Return.ResolvedAddresses[$Iter - 1]
                }

                ##If the user specified "quiet" then we should only return a boolean
                if ($InformationLevel -eq "Quiet")
                {
                    return $Return.TcpTestSucceeded
                }
            }
            #### End of TCP test ####

            #### Begin Ping test ####

            ##Attempt Ping test only if TCP test is not attempted or TCP test failed
            $AttemptPingTest = (-not $AttemptTcpTest) -or (-not $Return.TcpTestSucceeded)
            if ($AttemptPingTest) 
            {
                $Return.PingSucceeded = $False

                ##Try Ping using all resolved addresses until it succeeds
                $Iter = 0
                while (($Iter -lt $Return.ResolvedAddresses.Count) -and (-not $Return.PingSucceeded))
                {
                    $Return.PingReplyDetails = PingTest -TargetIPAddress $Return.ResolvedAddresses[$Iter]
                    if ($Return.PingReplyDetails -ne $null)
                    {
                        $Return.PingSucceeded = ($Return.PingReplyDetails.Status -eq [System.Net.NetworkInformation.IPStatus]::Success)
                    }

                    ##Output a warning message if Ping didn't succeed
                    if (-not $Return.PingSucceeded)
                    {
                        $WarningString = "Ping to $($Return.ResolvedAddresses[$Iter]) failed"
                        if ($Return.PingReplyDetails -ne $null)
                        {
                            $WarningString += " with status: $($Return.PingReplyDetails.Status)"
                        }
                        Write-Warning $WarningString
                    }
                    $Iter++
                }
 
                if ($Return.PingSucceeded)
                {
                    ##Get the remote address that was actually used for Ping
                    $Return.RemoteAddress = $Return.ResolvedAddresses[$Iter - 1]
                }

                ##If the user specified "quiet" then we should only return a boolean
                if ($InformationLevel -eq "Quiet")
                {
                    return $Return.PingSucceeded
                }
            }
            #### End of Ping test ####

            #### Begin TraceRoute ####

            ##TraceRoute, only occurs if switched by the user
            if ($TraceRoute -eq $True)
            {
                $Return.TraceRoute = TraceRoute -TargetIPAddress $Return.RemoteAddress -Hops $Hops
            }
            #### End of TraceRoute ####

            $Return = ResolveDNSDetails -TestNetConnectionResult $Return
            $Return = ResolveNetworkSecurityDetails -TestNetConnectionResult $Return
            $Return = ResolveRoutingandAdapterWMIObjects -TestNetConnectionResult $Return

            return $Return
        }
        }
    }

}

Function Get-TSVariable {

[CmdletBinding()]
Param(
[Parameter(Mandatory = $true)]
[string]$TSVariable

)
$TSEnvironment = New-Object -COMObject Microsoft.SMS.TSEnvironment
$TSEnvironment.Value($TSVariable)


}

function register-ComputerRenameInfo{

[CmdletBinding()]
Param()
Try{
    

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

Function Set-ComputerRenameInfo{
[CmdletBinding()]
Param(

[Parameter(Mandatory=$true)]
[string]$OldComputerName,
[Parameter(Mandatory=$true)]
[string]$NewComputerName,
[Parameter(Mandatory=$true)]
[string]$RenameStatus,
[string]$RenameDate,
[boolean]$ComputerPrepared = $false


)
$Properties = @{
                OldComputerName = $OldComputerName
                NewComputerName = $NewComputerName
                RenameStatus = $RenameStatus
                RenameDate = $RenameDate
                }


            try {
            # Set information in new class
            Set-WmiInstance -Namespace root\cimv2 -Class 'CM_ComputerRenameInfo' -Arguments $Properties -ErrorAction Stop | Out-Null
            Write-Output "***************`n[Set-ComputerRenameInfo] Successfully added values to ComputerRenameInfo object`n***************"
            } catch {
            
            "`n***************`n[Set-ComputerRenameInfo] Could not set Set-ComputerRenameInfo Instance. Error: $($_.Exception.Message)`n***************"
            
            }

            Try {
            # Send WHI
            Invoke-HWInventory -ErrorAction Stop
            "***************`n[Set-ComputerRenameInfo] Successfully sent HWInventory Info`n***************"
            } Catch {
            
            "***************`n[Set-ComputerRenameInfo] Could not send HW Inventory. Error: $($_.Exception.Message)`n***************"
            
            }

}

Function Invoke-HWInventory {

[CmdletBinding()]
Param()

            $SWIID = '{00000000-0000-0000-0000-000000000001}'
            $SMSCli = [wmiclass] "root\ccm:SMS_Client"
            $SMSCli.TriggerSchedule($SWIID) | Out-Null
            

}

Function Get-CIMDateTime {

<#



HighLEvel Steps

1) Get String with UTC ofsset pattern. Ie: 20200408115224.000000+03:00 while doing so get the UTCSign and the UTCHour
2) Split the the hour and make calculatations to convert to 3 digit minutes
3) Replace the +3:00 with the calculated 180


#>
$CimDateString= get-date -Format "yyyyMMddHHmmss.000000K"
if ($CimDateString -match '(?<UTCSign>\+|-)(?<UTC>.+)')

{

$UTCArray = $Matches['UTC'] -split ':'

$UTCMinutes =  "{0:d3}" -f  ([int]$UTCArray[0] *60 + [int]$UTCArray[1])

$CimDateString -replace '\+(.+)' ,"$($Matches['UTCSign'])$UTCMinutes"
}

}

<#

1) 

check if name is  $TSEnvironment.Value("TSRenameCompName") if so set RenameStatus 'Compliant', 

2) check dc test-networkconnection if not 

3) 

$TSEnvironment = New-Object -COMObject Microsoft.SMS.TSEnvironment
 $TSEnvironment.Value("TSRenameReq") = "Ok"
#>

Function Test-DCConnection {

[CmdletBinding()]
Param()

# remove the \\ from logonserver variable
$env:COMPUTERNAME -match '\\\\(?<LogonServer>.+)' | Out-Null

if ((Test-NetWorkConnection -ComputerName $Matches['LogonServer'] -port 389).TcpTestSucceeded) {
<#
add if gui issue resolves
$TSEnvironment.Value('DCConnection') = $true
#>
$true


} else {
<#
add if gui issue resolves
$TSEnvironment.Value('DCConnection') = $false
#>
$false

}

}

Function Test-ComputerNameCompliancy {

[Cmdletbinding()]
Param(
[Parameter(Mandatory = $true)]
[string]$NewComputerName
)

if ($env:COMPUTERNAME -eq $NewComputerName) {
 
<#
add if gui issue resolves
$TSEnvironment.Value('ComputerNameCompliancy') = $true
#>
$true
 
 
} else {

<#
add if gui issue resolves
$TSEnvironment.Value('ComputerNameCompliancy') = $false
#>
$false


}

}

# Script Main

# Get Computer name

try {

$TSEnvironment = New-Object -COMObject Microsoft.SMS.TSEnvironment
$NewComputerName = $TSEnvironment.Value('TSRenameCompName')
register-ComputerRenameInfo -ErrorAction Stop
Set-ComputerRenameInfo -OldComputerName $Env:COMPUTERNAME -NewComputerName $NewComputerName -ErrorAction Stop
Write-Output "***************`n[Script Main] Succesfully Prepared environment.`n***************"


}
Catch {

    "***************`n[register-ComputerRenameInfo] Prepare computer (Get newcomputer name or prepare wmi) initally: $($_.Exception.Message)`n***************"
    Exit
}


$DCConnectionResult = Test-DCConnection
$ComputerNameCompliancyResult = Test-ComputerNameCompliancy -NewComputerName $NewComputerName

if ($ComputerNameCompliancyResult) {

Set-ComputerRenameInfo -RenameStatus 'Compliant'

} else { 

if ($DCConnectionResult) {

Set-ComputerRenameInfo -RenameStatus 'ReadyToRename'


} else {
# not compliant and cannot connect to dc

Set-ComputerRenameInfo -RenameStatus 'Cannot connect to dc'

}


}

Invoke-HWInventory 



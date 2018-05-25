<#
    Version cmdlets
#>
function Get-VHMVersion {
	return (Get-Module VeeamHubModule).Version.ToString()
}
function Get-VHMVBRVersion {
	$versionstring = "Unknown Version"

    $pssversion = (Get-PSSnapin VeeamPSSnapin -ErrorAction SilentlyContinue)
    if ($pssversion -ne $null) {
        $versionstring = ("{0}.{1}" -f $pssversion.Version.Major,$pssversion.Version.Minor)
    }

    $corePath = Get-ItemProperty -Path "HKLM:\Software\Veeam\Veeam Backup and Replication\" -Name "CorePath" -ErrorAction SilentlyContinue
    if ($corePath -ne $null) {
        $depDLLPath = Join-Path -Path $corePath.CorePath -ChildPath "Packages\VeeamDeploymentDll.dll" -Resolve -ErrorAction SilentlyContinue
        if ($depDLLPath -ne $null -and (Test-Path -Path $depDLLPath)) {
            $file = Get-Item -Path $depDLLPath -ErrorAction SilentlyContinue
            if ($file -ne $null) {
                $versionstring = $file.VersionInfo.ProductVersion
            }
        }
    }
    $clientPath = Get-ItemProperty -Path "HKLM:\Software\Veeam\Veeam Mount Service\" -name "installationpath" -ErrorAction SilentlyContinue
    if ($clientPath -ne $null) {
        $depDLLPath = Join-Path -Path $clientPath.installationpath -ChildPath  "Packages\VeeamDeploymentDll.dll" -Resolve -ErrorAction SilentlyContinue
        if ($depDLLPath -ne $null -and (Test-Path -Path $depDLLPath)) {
            $file = Get-Item -Path $depDLLPath -ErrorAction SilentlyContinue
            if ($file -ne $null) {
                $versionstring = $file.VersionInfo.ProductVersion
            }
        }
    }
	return $versionstring
}

<#
    SQL Direct Query support
#>

function New-VHMSQLConnection {
    <#
        securestring from plaintext : ConvertTo-SecureString -String "mypassword" -AsPlainText -Force
    #>
    [cmdletbinding()]
    param(
        [string]$SQLLogin=$null,
        [System.Security.SecureString]$SQLPassword=$null,
        [string]$SQLServer="localhost",
        [string]$SQLInstance="VEEAMSQL2012",
        [string]$SQLDB="VeeamBackup"
    )


    $VHMSQLConnection = $null
    $conn = $null
    <#
        if null try windows basic authenication, otherwise failover to sql authentication
    #>
    $connstring = ("Persist Security Info=true;Integrated Security=true;Initial Catalog={2};server={0}\{1}" -f $SQLServer,$SQLInstance,$SQLDB)

    if($SQLLogin -eq $null) {
        write-Verbose "Login not set, trying Integrated Security"
        $conn = [System.Data.SqlClient.SqlConnection]::new($connstring)
    } else {
        write-Verbose "Using SQL Authentication"
        $connstring = ("Persist Security Info=true;Integrated Security=False;Initial Catalog={2};server={0}\{1}" -f $SQLServer,$SQLInstance,$SQLDB)
        $SQLPassword.MakeReadOnly()
        $sqlauth = [System.Data.SqlClient.SqlCredential]::new($SQLLogin,$SQLPassword)
        $conn = [System.Data.SqlClient.SqlConnection]::new($connstring,$sqlauth)
    }

    if ($conn -eq $null) {
        throw [System.Exception]::New("Connection was not set up")
    }
    
    write-verbose "Trying to connect to DB"
    try {
        $command = [System.Data.SqlClient.SqlCommand]::new("SELECT [VeeamProductID] FROM [VeeamBackup].[dbo].[VeeamProductVersion]",$conn)
        $conn.Open()
        write-verbose ("Opened connection, trying to query version hash")
        $result = $command.ExecuteScalar()
        if ($result -ne $null) {
            write-verbose ("Version hash queried succesfully, returning connection")
            $VHMSQLConnection = New-Object -TypeName psobject -Property @{Version=$result;Connection=$conn}
        }
        $conn.Close()
    } catch {
        throw [System.Exception]::New(("Connection was not set up, {0}" -f $_.Exception.Message))
    }
    return $VHMSQLConnection
}

function Invoke-VHMSQLQuery {
    [cmdletbinding()]
    param(
        [Parameter(Mandatory=$true)]$VHMSQLConnection=$null,
        [Parameter(Mandatory=$true)][string]$query=$null,
        [switch]$scalar=$false,
        $columns=@("id","name")
    )

    $result = $null
    [System.Data.SqlClient.SqlConnection]$conn = $VHMSQLConnection.Connection
    $command = [System.Data.SqlClient.SqlCommand]::new($query,$conn)
    if($conn.State -ne "Open") {
        $conn.Open()
    }
    
    if($scalar) {
        <#if you just one to have a single value (1row/1column) returned#>
        $result = $command.ExecuteScalar()
    } else {
        $result = @()
        $reader = $command.ExecuteReader()
        $c = 0
        while($reader.Read()) {
           $row = [object[]]::new($reader.FieldCount)
           $colcount = $reader.getvalues($row)
           <#Wrapping so that powershell does not try to convert it to one large array#>
           $result += New-Object -TypeName psobject -Property @{row=$c++;colcount=$colcount;rowdata=$row}
           
        }
        $reader.Close()
    }
    $conn.Close()
    return $result
}

<#
    0 id - id of repo
    1 name - name of repository
    2 host_id - server hosting the repository
    3 path - path to the backup files
    4 meta_repo_id - id of the cluster, this means this repository is an extent
    5 type - if type is 10, it seems to be a scale-out backup repository
    6 custom - if is sobr cluster or not, instead of checking type, use this so changes can be checked in this module
#>
function Get-VHMSQLRepository {
    [cmdletbinding()]
    param(
        [Parameter(Mandatory=$true)]$VHMSQLConnection=$null,
        $name=$null,
        $id=$null,
        $columns=@("[repo].[id]","[repo].[name]","[host_id]","[host].[name]","[path]","[extrarepo].[meta_repo_id]","[repo].[type]","CAST(CASE WHEN [repo].[type] = '10' THEN 1 ELSE 0 END AS int) as ScaleOut")
    )
    $query = (@"
SELECT {0}
FROM [VeeamBackup].[dbo].[BackupRepositories] as repo
LEFT JOIN [VeeamBackup].[dbo].[Backup.ExtRepo.ExtRepos] AS extrarepo ON [repo].[id] = [extrarepo].[dependant_repo_id]
LEFT JOIN [VeeamBackup].[dbo].[Hosts] as host ON [repo].[host_id] = [host].[id] 
"@ -f ($columns -join ","))

    
    if ($name -ne $null) { $query += ("WHERE [repo].[name] = '{0}'" -f $name)}
    elseif ($id -ne $null) { $query += ("WHERE [repo].[id] = CAST('{0}' AS UNIQUEIDENTIFIER) " -f $id)}

    write-verbose $query

    return Invoke-VHMSQLQuery -VHMSQLConnection $VHMSQLConnection -query $query
}

<#
    0 id - file_id
    1 file_path - as in db, please use scripted path for sobr overview
    2 dir_path - as in db, please use scripted path for sobr overview
    3 repo_id - if it is a regular repository, id of the repo, if it is on a scaleout cluster, it is cluster id 
    4 ext_id - if the file is on a cluster, this is the repository id it is really located on, otherwise $null
    5 physical_repo_id - id of the repository the file is physically located on regardless if it is on sobr
    6 physical_repo_name - name of the repository the file is physically located on regardless if it is on sobr
    7 physical_repo_host_id - id of the host hosting the physical repo, in case of cifs, will be empty
    8 physical_repo_host_name - name of the host hosting the physical repo, in case of cifs, will be empty
    9 full_file_path - scripted full path that should work on both regular repositories as extends
#>
function Get-VHMSQLStoragesOnRepository {
       [cmdletbinding()]
    param(
        [Parameter(Mandatory=$true)]$VHMSQLConnection=$null,
        $physrepoid=$null,
        $physreponame=$null,
        $hostid=$null,
        $hostname=$null,
        $where=$null,
        $columns=@("[stgs].[id]",
            "[stgs].[file_path]",
            "[dir_path]",
            "[repository_id]",
            "[extrepos].[dependant_repo_id]",
            "[physrepo].[id]  as [physical_backup_repository_id]",
            "[physrepo].[name] as [physical_backup_repository_name]",
            "[physrepohost].[id]",
            "[physrepohost].[name]",
            "(CASE WHEN [extrepos].dependant_repo_id IS NULL THEN file_path ELSE CONCAT(physrepo.path,'\',dir_path,'\',file_path) END) as full_file_path")
    )
    $query = (@"
select {0}
from [VeeamBackup].[dbo].[Backup.Model.Storages] AS stgs
LEFT JOIN [VeeamBackup].[dbo].[Backup.Model.Backups] AS backups ON [backups].[id] = [stgs].[backup_id]
LEFT JOIN [VeeamBackup].[dbo].[Backup.ExtRepo.Storages] AS extstgs ON [extstgs].[storage_id] = [stgs].[id]
LEFT JOIN [VeeamBackup].[dbo].[Backup.ExtRepo.ExtRepos] AS extrepos ON [extrepos].[id] = [extstgs].[dependant_repo_id]
LEFT JOIN [VeeamBackup].[dbo].[BackupRepositories] AS physrepo ON (ISNULL ([extrepos].dependant_repo_id,[repository_id])) = physrepo.id
LEFT JOIN [VeeamBackup].[dbo].[Hosts] AS physrepohost ON physrepo.host_id = physrepohost.id 
"@ -f ($columns -join ","))

    
    if ($physrepoid -ne $null) { $query += ("WHERE physrepo.id = '{0}'" -f  $physrepoid)}
    if ($physreponame -ne $null) { $query += ("WHERE physrepo.name = '{0}'" -f $physreponame)}
    if ($hostid -ne $null) { $query += ("WHERE physrepo.host_id = '{0}'" -f $hostid)}
    if ($hostname -ne $null) { $query += ("WHERE physrepohost.name = '{0}'" -f $hostname)}
    if ($where -ne $null) { $query += ("WHERE {0}") -f $where}
    write-verbose $query

    return Invoke-VHMSQLQuery -VHMSQLConnection $VHMSQLConnection -query $query 
}


<#
    Remove-Module veeamhubmodule;Import-Module .\veeamhubmodule.psd1
    $vhmsql = New-VHMSQLConnection -SQLLogin "veeamquery" -SQLPassword (ConvertTo-SecureString -String "mypassword" -AsPlainText -Force) -SQLServer "127.0.0.1" -Verbose
    Get-VHMSQLRepository -VHMSQLConnection $vhmsql -verbose | % { write-host ("{0} | {1}" -f $_.rowdata[0],$_.rowdata[1] )}
    Get-VHMSQLStoragesOnRepository -VHMSQLConnection $vhmsql -physreponame sobr02 -verbose | % { write-host ("{0,-20} | {1}" -f $_.rowdata[8],$_.rowdata[9] )}
#>
<#
    Generic functions
#>
function Get-VHMVBRWinServer {
    return [Veeam.Backup.Core.CWinServer]::GetAll($true)
}

<#
    Schedule Info  
#>

function New-VHM24x7Array {
    param([int]$defaultvalue=0)
    $a = (New-Object 'int[][]' 7,24) 
    foreach($d in (0..6)) {
        foreach($h in (0..23)) {
            $a[$d][$h] = $defaultvalue
        }
    }
    return $a
}
function Format-VHMVBRScheduleInfo {
    param([parameter(ValueFromPipeline,Mandatory=$true)][Veeam.Backup.Common.UI.Controls.Scheduler.ScheduleInfo]$schedule)
    $days = 'S','M','T','W','T','F','S'

    $cells = $schedule.GetCells()
    foreach($d in (0..6)) {
        write-host ("{0} | {1} |" -f $days[$d],($cells[$d] -join " | ")) 
    }
}

function New-VHMVBRScheduleInfo {
    param(
        [ValidateSet("Anytime","BusinessHours","WeekDays","Weekend","Custom","Never")]$option,
        [int[]]$hours = (0..23),
        [int[]]$days = (0..6)
    )
    $result = $null
    switch($option) {
        "Anytime" {
            $result = [Veeam.Backup.Common.UI.Controls.Scheduler.ScheduleInfo]::CreateAllPermitted()
        }
        "BusinessHours" {
            $a = New-VHM24x7Array -defaultvalue 1
            foreach($d in (1..5)) {
                foreach($h in (8..17)) {
                    $a[$d][$h] = 0
                }
            }
            $result = [Veeam.Backup.Common.UI.Controls.Scheduler.ScheduleInfo]::new($a)
        }
        "WeekDays" {
            $a = New-VHM24x7Array -defaultvalue 1
            foreach($d in (1..5)) {
                foreach($h in (0..23)) {
                    $a[$d][$h] = 0
                }
            }
            $result = [Veeam.Backup.Common.UI.Controls.Scheduler.ScheduleInfo]::new($a)
        }
        "Weekend" {
            $a = New-VHM24x7Array -defaultvalue 1
            foreach($d in @(0,6)) {
                foreach($h in (0..23)) {
                    $a[$d][$h] = 0
                }
            }
            $result = [Veeam.Backup.Common.UI.Controls.Scheduler.ScheduleInfo]::new($a)
        }
        "Custom" {
            $a = New-VHM24x7Array -defaultvalue 1
            foreach($d in $days) {
                foreach($h in $hours) {
                    $a[$d][$h] = 0
                }
            }
            $result = [Veeam.Backup.Common.UI.Controls.Scheduler.ScheduleInfo]::new($a)
        }
        "Never" {
            $a = New-VHM24x7Array -defaultvalue 1
            $result = [Veeam.Backup.Common.UI.Controls.Scheduler.ScheduleInfo]::new($a)
        }
    }
    return $result
}

<#
    Traffic rules
    //Implementing hacks from Tom Sightler on : https://forums.veeam.com/powershell-f26/backup-proxy-traffic-throttling-rules-t31732.html#p228501
#>

function Get-VHMVBRTrafficRule {
    param(
        $ruleId=$null
    )
    $rls = [Veeam.Backup.Core.SBackupOptions]::GetTrafficThrottlingRules().GetRules()
    if($ruleId -ne $null) {
        $rls = $rls | ? { $_.RuleId -eq $ruleId }
    }
    return $rls
}


function Update-VHMVBRTrafficRule {
    [cmdletbinding()]
    param(
        [parameter(ValueFromPipeline)][Veeam.Backup.Model.CTrafficThrottlingRule]$TrafficRule
    )
    #Seems like the object needs to be removed by the same instance that returned them 
    begin {
        $ttr = [Veeam.Backup.Core.SBackupOptions]::GetTrafficThrottlingRules()
        $rules = $ttr.GetRules()
    }
    process {
        $m = $rules | ? { $_.RuleId -eq $TrafficRule.RuleId } 
        if ($m -ne $null) {
            Write-Verbose ("Updated rule {0}" -f $TrafficRule.RuleId)
            $m.SpeedLimit = $TrafficRule.SpeedLimit
            $m.SpeedUnit = $TrafficRule.SpeedUnit
            $m.AlwaysEnabled = $TrafficRule.AlwaysEnabled
            $m.EncryptionEnabled = $TrafficRule.EncryptionEnabled
            $m.ThrottlingEnabled = $TrafficRule.ThrottlingEnabled
            $m.SetScheduleInfo($TrafficRule.GetScheduleInfo())
            $m.FirstDiapason.FirstIp = $TrafficRule.FirstDiapason.FirstIp
            $m.FirstDiapason.LastIp = $TrafficRule.FirstDiapason.LastIp
            $m.SecondDiapason.FirstIp = $TrafficRule.SecondDiapason.FirstIp
            $m.SecondDiapason.LastIp = $TrafficRule.SecondDiapason.LastIp
            
        } else {
            Write-Verbose ("Did not found match for {0}" -f $TrafficRule.RuleId)
        }
    }
    end {
        [Veeam.Backup.Core.SBackupOptions]::SaveTrafficThrottlingRules($ttr)
    }
}
function New-VHMVBRTrafficRule {
    param(
        [Parameter(Mandatory=$true)][ValidateScript({$_ -match [IPAddress]$_ })]$SourceFirstIp="",
        [Parameter(Mandatory=$true)][ValidateScript({$_ -match [IPAddress]$_ })]$SourceLastIp="",
        [Parameter(Mandatory=$true)][ValidateScript({$_ -match [IPAddress]$_ })]$TargetFirstIp="",
        [Parameter(Mandatory=$true)][ValidateScript({$_ -match [IPAddress]$_ })]$TargetLastIp="",
        $SpeedLimit=10,
        $SpeedUnit="Mbps",
        $AlwaysEnabled=$true,
        $EncryptionEnabled=$false,
        $ThrottlingEnabled=$true,
        [Veeam.Backup.Common.UI.Controls.Scheduler.ScheduleInfo]$Schedule=[Veeam.Backup.Common.UI.Controls.Scheduler.ScheduleInfo]::CreateAllPermitted()
    )
    $ttr = [Veeam.Backup.Core.SBackupOptions]::GetTrafficThrottlingRules()

    # Add a new default traffic throttling rule to existing rules
    $nttr = $ttr.AddRule()

    # Set options for the new traffic throttling rule
    $nttr.SpeedLimit = $SpeedLimit
    $nttr.SpeedUnit = $SpeedUnit
    $nttr.AlwaysEnabled = $AlwaysEnabled
    $nttr.EncryptionEnabled = $EncryptionEnabled
    $nttr.ThrottlingEnabled = $ThrottlingEnabled
    $nttr.SetScheduleInfo($schedule)
    $nttr.FirstDiapason.FirstIp = $SourceFirstIp
    $nttr.FirstDiapason.LastIp = $SourceLastIp
    $nttr.SecondDiapason.FirstIp = $TargetFirstIp
    $nttr.SecondDiapason.LastIp = $TargetLastIp

    # Save new traffic throttiling rules
    [Veeam.Backup.Core.SBackupOptions]::SaveTrafficThrottlingRules($ttr)
    return $nttr
}

function Remove-VHMVBRTrafficRule {
    [cmdletbinding()]
    param(
        [parameter(ValueFromPipeline)][Veeam.Backup.Model.CTrafficThrottlingRule]$TrafficRule
    )
    #Seems like the object needs to be removed by the same instance that returned them 
    begin {
        $ttr = [Veeam.Backup.Core.SBackupOptions]::GetTrafficThrottlingRules()
        $rules = $ttr.GetRules()
    }
    process {
        $m = $rules | ? { $_.RuleId -eq $TrafficRule.RuleId } 
        if ($m -ne $null) {
            Write-Verbose ("Removed rule {0}" -f $TrafficRule.RuleId)
            $ttr.RemoveRule($m)
        } else {
            Write-Verbose ("Did not found match for {0}" -f $TrafficRule.RuleId)
        }
    }
    end {
        [Veeam.Backup.Core.SBackupOptions]::SaveTrafficThrottlingRules($ttr)
    }
}


<#
    Guest interaction proxies
    //Implementing hacks from Tom Sightler on :  https://forums.veeam.com/powershell-f26/set-guest-interaction-proxy-server-t35234.html#p272191
#>


function Add-VHMVBRViGuestProxy {
    param(
        [Parameter(Mandatory=$True)][Veeam.Backup.Core.CBackupJob]$job,
        [Parameter(Mandatory=$True)][Veeam.Backup.Core.CWinServer[]]$proxies= $null
    )  
    $gipspids = [Veeam.Backup.Core.CJobProxy]::GetJobProxies($job.id) | ? { $_.Type -eq "EGuest" } | % { $_.ProxyId }
    foreach($proxy in $proxies) {
            if($proxy.Id -notin $gipspids) {
                [Veeam.Backup.Core.CJobProxy]::Create($job.id,$proxy.Id,"EGuest")
            }
    }
}
function Remove-VHMVBRViGuestProxy {
    param(
        [Parameter(Mandatory=$True)][Veeam.Backup.Core.CBackupJob]$job,
        [Parameter(Mandatory=$True)][Veeam.Backup.Core.CWinServer[]]$proxies= $null
    )    
    $gips = [Veeam.Backup.Core.CJobProxy]::GetJobProxies($job.id) | ? { $_.Type -eq "EGuest" }
    $pids = $proxies.id

    foreach($gip in $gips) {
        if($gip.ProxyId -in $pids) {
            [Veeam.Backup.Core.CJobProxy]::Delete($gip.id)           
        }
    } 
}
function Set-VHMVBRViGuestProxy {
    [CmdletBinding(DefaultParameterSetName='Auto')]
    param(
        [Parameter(Mandatory=$True)][Veeam.Backup.Core.CBackupJob]$job,
        [Parameter(Mandatory = $true, ParameterSetName = 'Auto')][switch]$auto,
        [Parameter(Mandatory = $true, ParameterSetName = 'Manual')][switch]$manual,
        [Parameter(Mandatory = $true, ParameterSetName = 'Manual')][Veeam.Backup.Core.CWinServer[]]$proxies= $null
    )
    if($manual) {
        $o = $job.GetVssOptions()
        $o.GuestProxyAutoDetect = $false
        $job.SetVssOptions($o)
    }
    if($auto) {
        $o = $job.GetVssOptions()
        $o.GuestProxyAutoDetect = $true
        $job.SetVssOptions($o)
    }
    if($proxies -ne $null) {
        $gips = [Veeam.Backup.Core.CJobProxy]::GetJobProxies($job.id) | ? { $_.Type -eq "EGuest" }
        $pids = $proxies.id

        foreach($gip in $gips) {
            if($gip.ProxyId -notin $pids) {
                [Veeam.Backup.Core.CJobProxy]::Delete($gip.id)           
            }
        }
        $gipspids = [Veeam.Backup.Core.CJobProxy]::GetJobProxies($job.id) | ? { $_.Type -eq "EGuest" } | % { $_.ProxyId }
        foreach($proxy in $proxies) {
            if($proxy.Id -notin $gipspids) {
                [Veeam.Backup.Core.CJobProxy]::Create($job.id,$proxy.Id,"EGuest")
            }
        }

    }
}
function Get-VHMVBRViGuestProxy {
    param(
        [Parameter(Mandatory=$True)][Veeam.Backup.Core.CBackupJob]$job
    )
    return [Veeam.Backup.Core.CJobProxy]::GetJobProxies($job.id) | ? { $_.Type -eq "EGuest" }
}


<#
    User Roles
    //Implementing hacks from Tom Sightler on : https://forums.veeam.com/powershell-f26/add-user-to-users-and-roles-per-ps-t41011.html#p271679
#>

function Add-VHMVBRUserRoleMapping {
    Param (
        [string]$UserOrGroupName, 
        [ValidateSet('Veeam Restore Operator','Veeam Backup Operator','Veeam Backup Administrator','Veeam Backup Viewer')][string]$RoleName
     )

    $CDBManager = [Veeam.Backup.DBManager.CDBManager]::CreateNewInstance()

    # Find the SID for the named user/group
    $AccountSid = [Veeam.Backup.Common.CAccountHelper]::FindSid($UserOrGroupName)

    # Detect if account is a User or Group
    If ([Veeam.Backup.Common.CAccountHelper]::IsUser($AccountSid)) {
        $AccountType = [Veeam.Backup.Model.AccountTypes]::User
    } Else {
        $AccountType = [Veeam.Backup.Model.AccountTypes]::Group
    }

    # Parse out full name (with domain component) and short name
    $FullAccountName = [Veeam.Backup.Common.CAccountHelper]::GetNtAccount($AccountSid).Value;
    $ShortAccountName = [Veeam.Backup.Common.CAccountHelper]::ParseUserName($FullAccountName);

    # Check if account already exist in Veeam DB, add if required
    If ($CDBManager.UsersAndRoles.FindAccount($AccountSid.Value)) {
        $Account = $CDBManager.UsersAndRoles.FindAccount($AccountSid.Value)
    } else {
        $Account = $CDBManager.UsersAndRoles.CreateAccount($AccountSid.Value, $ShortAccountName, $FullAccountName, $AccountType);
    }

    # Get the Role object for the named Role
    $Role = $CDBManager.UsersAndRoles.GetRolesAll() | ?{$_.Name -eq $RoleName}

    # Check if account is already assigned to Role and assign if not
    if ($CDBManager.UsersAndRoles.GetRolesByAccountId($Account.Id)) {
        write-host "Account $UserOrGroupName is already assigned to role $RoleName"
    } else {
        $CDBManager.UsersAndRoles.CreateRoleAccount($Role.Id,$Account.Id)
    }

    $CDBManager.Dispose()
}

function Remove-VHMVBRUserRoleMapping {
    Param ([string]$UserOrGroupName, 
    [ValidateSet('Veeam Restore Operator','Veeam Backup Operator','Veeam Backup Administrator','Veeam Backup Viewer')][string]$RoleName)
    $CDBManager = [Veeam.Backup.DBManager.CDBManager]::CreateNewInstance()

    # Find the SID for the named user/group
    $AccountSid = ([Veeam.Backup.Common.CAccountHelper]::FindSid($UserOrGroupName)).Value

    # Get the Veeam account ID using the SID
    $Account = $CDBManager.UsersAndRoles.FindAccount($AccountSid)

    # Get the Role ID for the named Role
    $Role = $CDBManager.UsersAndRoles.GetRolesAll() | ?{$_.Name -eq $RoleName}

    # Check if name user/group is assigned to role and delete if so
    if ($CDBManager.UsersAndRoles.GetRoleAccountByAccountId($Account.Id)) {
        $CDBManager.UsersAndRoles.DeleteRoleAccount($Role.Id,$Account.Id)
    } else {
        write-host "Account $UserOrGroupName is not assigned to role $RoleName"
    }

    $CDBManager.Dispose()
}

function Get-VHMVBRUserRoleMapping {
    $CDBManager = [Veeam.Backup.DBManager.CDBManager]::CreateNewInstance()

    $mappings = @()
    $accounts = $CDBManager.UsersAndRoles.GetAccountsAll()

    foreach( $r in ($CDBManager.UsersAndRoles.GetRolesAll())) {
        $roleaccounts = $CDBManager.UsersAndRoles.GetRoleAccountByRoleId($r.Id)
        foreach($ra in $roleaccounts) {
            $account = $accounts | ? { $ra.AccountId -eq $_.Id }
            $mappings += (New-Object -TypeName psobject -Property @{
                AccountName=$account.Nt4Name
                RoleName=$r.Name;
                RoleAccount=$ra;
                Role=$r;
                Account=$account
            })
        }
    }
    return $mappings
}



<#
gc .\veeamhubmodule.psm1 | Select-String "^function (.*) {"  | % { "Export-ModuleMember -Function {0}" -f $_.Matches.groups[1].value }
gc .\veeamhubmodule.psm1 | Select-String "^Export-ModuleMember -Function (.*)"  | % { "`t'{0}'," -f $_.Matches.groups[1].value }
#>
Export-ModuleMember -Function Get-VHMVersion
Export-ModuleMember -Function Get-VHMVBRVersion
Export-ModuleMember -Function New-VHMSQLConnection
Export-ModuleMember -Function Invoke-VHMSQLQuery
Export-ModuleMember -Function Get-VHMSQLRepository
Export-ModuleMember -Function Get-VHMSQLStoragesOnRepository
Export-ModuleMember -Function Get-VHMVBRWinServer
Export-ModuleMember -Function New-VHM24x7Array
Export-ModuleMember -Function Format-VHMVBRScheduleInfo
Export-ModuleMember -Function New-VHMVBRScheduleInfo
Export-ModuleMember -Function Get-VHMVBRTrafficRule
Export-ModuleMember -Function Update-VHMVBRTrafficRule
Export-ModuleMember -Function New-VHMVBRTrafficRule
Export-ModuleMember -Function Remove-VHMVBRTrafficRule
Export-ModuleMember -Function Add-VHMVBRViGuestProxy
Export-ModuleMember -Function Remove-VHMVBRViGuestProxy
Export-ModuleMember -Function Set-VHMVBRViGuestProxy
Export-ModuleMember -Function Get-VHMVBRViGuestProxy
Export-ModuleMember -Function Add-VHMVBRUserRoleMapping
Export-ModuleMember -Function Remove-VHMVBRUserRoleMapping
Export-ModuleMember -Function Get-VHMVBRUserRoleMapping
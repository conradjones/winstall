param(  [Parameter(Mandatory=$true)][String]$ComponentPath,
        $Parameters,
        [switch] $DetectOnly)

$ErrorActionPreference = “Stop”

enum LogLevel
{
    Info
    Debug
    Error
    Warn
}

function Log ($RunFolder, [LogLevel]$LogLevel, $Line)
{
    $LogFile = Join-Path -Path $RunFolder -ChildPath "PackageInstall.log"
    $Line = $LogLevel.ToString() + ":" + $Line
    $Line | Out-File -FilePath $LogFile -Append
    switch ($LogLevel) {
        Info    { Write-Verbose  -Message $Line -Verbose }
        Debug   { Write-Debug    -Message $Line }
        Error   { Write-Error    -Message $Line }
        Warn    { Write-Warning  -Message $Line }
    }
}

function Get-ParsedNodeValue($Value, $Parameters)
{
    if ($null -eq $Value) {
        return $null
    }
    foreach ($Key in $Parameters.Keys) {
        $PlaceHolder = '${' + $($Key) + '}'
        $Value = $Value.Replace($PlaceHolder, $Parameters[$Key])
    }
    return $Value
}

function Get-RunFolder($ComponentName)
{
    $Folder = "C:\.winstall\install\$ComponentName"
    if (Test-Path -Path $Folder) {
        Remove-Item -Path $Folder -Recurse -Force | Out-Null
    }
    New-Item -Path $Folder -ItemType Directory | Out-Null
    return $Folder
}

function Step-Download($XmlNode, $RunFolder, $Parameters)
{
    $Url = Get-ParsedNodeValue -Value $XmlNode.InnerText -Parameters $Parameters

    $FileName = $Url | Split-Path -Leaf
    $Output = Join-Path -Path $RunFolder -ChildPath $FileName
    $WebClient = New-Object System.Net.WebClient
    Log -RunFolder $RunFolder -LogLevel Info -Line "Downloading:$Url)"
    $WebClient.DownloadFile($Url, $Output)

    if (!(Test-Path -Path $Output)) {
        Log -RunFolder $RunFolder -LogLevel Error -Line "Failed to download $Url to $Output"
        return $False
    }

    return $True
}

function Step-CreateDir($XmlNode, $RunFolder, $Parameters)
{
    $FolderName = Get-ParsedNodeValue -Value $XmlNode.InnerText -Parameters $Parameters
    if (Test-Path -Path $FolderName) {
       if ((Get-Item $FolderName) -is [System.IO.DirectoryInfo]) {
           return $true
       }
       Log -RunFolder $RunFolder -LogLevel Error -Line "$FolderName already exists and is not a folder"
       return $False
    }
    New-Item -Path $FolderName -ItemType Directory | Out-Null
    if (!(Test-Path -Path $FolderName)) {
        Log -RunFolder $RunFolder -LogLevel Error -Line "Failed to create $FolderName"
        return $False
    }
    return $True
}

function Step-CopyFile($XmlNode, $RunFolder, $Parameters)
{
    $SourceNode = Get-ParsedNodeValue -Value $XmlNode.source -Parameters $Parameters
    if ($Null -eq $SourceNode) {
       Log -RunFolder $RunFolder -LogLevel Error -Line "source node is missing from copy_file step"
       return $False
    }

    $DestNode = Get-ParsedNodeValue -Value $XmlNode.dest -Parameters $Parameters
    if ($Null -eq $DestNode) {
       Log -RunFolder $RunFolder -LogLevel Error -Line "dest node is missing from copy_file step"
       return $False
    }

    $SourcePath = Join-Path -Path $RunFolder -ChildPath $SourceNode
    $DestPath = $DestNode
    Copy-Item -Path $SourcePath -Destination $DestPath
    if (!(Test-Path -Path $DestPath)) {
        Log -RunFolder $RunFolder -LogLevel Error -Line "Failed to copy $SourcePath to $DestPath"
        return $False
    }
    return $True
}


function Step-ConfigureFile($XmlNode, $RunFolder, $Parameters)
{
    $SourceNode = Get-ParsedNodeValue -Value $XmlNode.source -Parameters $Parameters
    if ($Null -eq $SourceNode) {
       Log -RunFolder $RunFolder -LogLevel Error -Line "source node is missing from copy_file step"
       return $False
    }

    $DestPath = Get-ParsedNodeValue -Value $XmlNode.dest -Parameters $Parameters
    if ($Null -eq $DestPath) {
       Log -RunFolder $RunFolder -LogLevel Error -Line "dest node is missing from copy_file step"
       return $False
    }

    $SourcePath = Join-Path -Path $RunFolder -ChildPath $SourceNode

    $AsText = Get-Content -Path $SourcePath
    foreach ($Key in $Parameters.Keys) {
        $PlaceHolder = '${' + $($Key) + '}'
        $AsText = $AsText.Replace($PlaceHolder, $Parameters[$Key])
    }

    $AsText | Out-File -FilePath $DestPath
    if (!(Test-Path -Path $DestPath)) {
        Log -RunFolder $RunFolder -LogLevel Error -Line "Failed to configure file $SourcePath to $DestPath"
        return $False
    }
    return $True
}

function Step-Path($XmlNode, $RunFolder, $Parameters)
{
    $PathToAdd = Get-ParsedNodeValue -Value $XmlNode.InnerText -Parameters $Parameters

    $PathKeyValue = (Get-ItemProperty -Path 'Registry::HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\Session Manager\Environment' -Name PATH).path
    $AllPaths = $PathKeyValue.split(";")
    if ($AllPaths.Contains($PathToAdd)) {
        Log -RunFolder $RunFolder -LogLevel Info -Line "System path variable already includes:$PathToAdd"
        return $True
    }
    $AllPaths += $PathToAdd
    $PathKeyValue = $AllPaths -join ';'
    Set-ItemProperty -Path 'Registry::HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\Session Manager\Environment' -Name PATH -Value $PathKeyValue -Force
    $PathKeyValue = (Get-ItemProperty -Path 'Registry::HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\Session Manager\Environment' -Name PATH).path
    if (!($PathKeyValue.Contains($PathToAdd))) {
        Log -RunFolder $RunFolder -LogLevel Info -Line "Failed to add:$PathToAdd to System path variable"
        return $False
    }
    return $True
}

function Step-Command($XmlNode, $RunFolder, $Parameters)
{
    Push-Location -Path $RunFolder
    $command = Get-ParsedNodeValue -Value $XmlNode.commandLine -Parameters $Parameters
    $args = @()
    foreach ($ArgNode in $XmlNode.args.arg) {
        $args += Get-ParsedNodeValue -Value $ArgNode -Parameters $Parameters
    }
    $argString = $args -join " "
    Log -RunFolder $RunFolder -LogLevel Info -Line "Executing:$command $argString"
    $process = (Start-Process –PassThru -FilePath $command -ArgumentList $args -Wait)
    Pop-Location

    $process_exit_code = $process.ExitCode

    $exit_codes = $XmlNode.exit_codes
    if ($null -eq $exit_codes) {
        if ([Int32]$process_exit_code -ne [Int32]0) {
            Log -RunFolder $RunFolder -LogLevel Error -Line "Process returned non-permitted exit code:$process_exit_code"
            return $False
        }
        return $True
    }

    foreach ($exit_code in $exit_codes.exit_code) {
        if ([Int32]$process_exit_code -eq [Int32]$exit_code) {
            return $true
        }
    }

    Log -RunFolder $RunFolder -LogLevel Error -Line "Process returned non-permitted exit code:$process_exit_code"
    return $False
}

function Step-RegSet($XmlNode, $RunFolder, $Parameters)
{
    $RegKey = Get-ParsedNodeValue -Value $XmlNode.key -Parameters $Parameters
    $RegValue = Get-ParsedNodeValue -Value $XmlNode.value -Parameters $Parameters
    $RegValueName = Get-ParsedNodeValue -Value $XmlNode.value_name -Parameters $Parameters
    $RegValueType = Get-ParsedNodeValue -Value $XmlNode.value_type -Parameters $Parameters

    switch ($RegValueType) {
        "REG_DWORD" { $Type = [Microsoft.Win32.RegistryValueKind]::DWord}
        "REG_SZ"    { $Type = [Microsoft.Win32.RegistryValueKind]::String}
        default     { return $false }
    }

    [Microsoft.Win32.Registry]::SetValue($RegKey,$RegValueName,$RegValue,$Type)

    return $True
}

function Step-Powershell($XmlNode, $RunFolder, $Parameters)
{
    $scriptBlock = Get-ParsedNodeValue -Value $XmlNode.scriptblock -Parameters $Parameters

    if ($null -eq $scriptBlock) {
        Log -RunFolder $RunFolder -LogLevel Error -Line "scriptblock node is missing from powershell step"
        exit 1
    }

    Invoke-Expression -Command $scriptBlock

    return $True
}

function Step-Unzip($XmlNode, $RunFolder, $Parameters)
{
    $zipfile = Get-ParsedNodeValue -Value $XmlNode.zipfile -Parameters $Parameters
    if ($null -eq $zipfile) {
        Log -RunFolder $RunFolder -LogLevel Error -Line "zipfile node is missing from unzip step"
        exit 1
    }

    $destination = Get-ParsedNodeValue -Value $XmlNode.destination -Parameters $Parameters
    if ($null -eq $destination) {
        Log -RunFolder $RunFolder -LogLevel Error -Line "destination node is missing from unzip step"
        exit 1
    }

    Expand-Archive -Path $zipfile -Destination $destination -Verbose

    return $True
}

function Step-KillProcess($XmlNode, $RunFolder, $Parameters)
{
    $process_name = Get-ParsedNodeValue -Value $XmlNode.InnerText -Parameters $Parameters
    Get-Process -Name $process_name | Stop-Process -Force -Verbose

    return $True
}

function Step-WaitProcess($XmlNode, $RunFolder, $Parameters)
{
    $process_name = Get-ParsedNodeValue -Value $XmlNode.InnerText -Parameters $Parameters
    $Process = @(Get-Process -Name $process_name -ErrorAction SilentlyContinue)

    while ($Process.Count -gt 0) {

        Log -RunFolder $RunFolder -LogLevel Info -Line "Waiting for process:$XmlNode"
        Start-Sleep -Seconds 1
        $Process = @(Get-Process -Name $process_name -ErrorAction SilentlyContinue)
    }

    return $True
}

function Step-EnvVar($XmlNode, $RunFolder, $Parameters)
{
    $Name = Get-ParsedNodeValue -Value $XmlNode.name -Parameters $Parameters
    if ($Null -eq $Name) {
       Log -RunFolder $RunFolder -LogLevel Error -Line "name node is missing from env step"
       return $False
    }

    $Value = Get-ParsedNodeValue -Value $XmlNode.value -Parameters $Parameters
    if ($Null -eq $Value) {
       Log -RunFolder $RunFolder -LogLevel Error -Line "value node is missing from env step"
       return $False
    }

    [System.Environment]::SetEnvironmentVariable($Name,$Value,[System.EnvironmentVariableTarget]::Machine)

    return $True
}

function Confirm-FileDetected($DetectionNode, $RunFolder, $Parameters)
{
    $path = Get-ParsedNodeValue -Value $DetectionNode.path -Parameters $Parameters

    Log -RunFolder $RunFolder -LogLevel Info -Line "(Detection):checking existence of $path"
    if (!(Test-Path -Path $path)) {
        Log -RunFolder $RunFolder -LogLevel Info -Line "(Detection):$path not found"
        return $False
    }

    Log -RunFolder $RunFolder -LogLevel Info -Line "(Detection):checking $path is a file"
    if (!((Get-Item $path) -is [System.IO.FileInfo])) {
        Log -RunFolder $RunFolder -LogLevel Info -Line "(Detection):$path found but is not a file"
        return $False
    }


    $expectedVersion = Get-ParsedNodeValue -Value $DetectionNode.version -Parameters $Parameters
    if ($null -ne $expectedVersion) {
        Log -RunFolder $RunFolder -LogLevel Info -Line "(Detection):checking $path is version $expectedVersion"
        $foundVersion = (Get-Command $path).Version
        if ($foundVersion -ne [version]$expectedVersion) {
            Log -RunFolder $RunFolder -LogLevel Info -Line "(Detection):$path found but version is:$foundVersion (expected:$expectedVersion)"
            return $False
        }
    }

    Log -RunFolder $RunFolder -LogLevel Info -Line "(Detection):$path is detected"
    return $True
}

function Confirm-PowershellDetected($DetectionNode, $RunFolder, $Parameters)
{
    $scriptBlock = Get-ParsedNodeValue -Value $DetectionNode.scriptblock -Parameters $Parameters
    if ($null -eq $scriptBlock) {
        Log -RunFolder $RunFolder -LogLevel Error -Line "Powershell detection node missing scriptblock"
        exit 1
    }

    $expected = Get-ParsedNodeValue -Value $DetectionNode.expected -Parameters $Parameters
    if ($null -eq $expected) {
        Log -RunFolder $RunFolder -LogLevel Error -Line "Powershell detection node missing expected"
        exit 1
    }

    $Result = Invoke-Expression -Command $scriptBlock

    $success = ($Result -eq $expected)
    if (!$success)
    {
        Log -RunFolder $RunFolder -LogLevel Info -Line "Powershell detection rule failed expected:$expected got:$result`n$scriptBlock"
    }
    return $success
}

function Confirm-IsDetected($XmlNode, $RunFolder, $Parameters)
{
    foreach ($DetectionNode in $XmlNode.ChildNodes) {
        switch ($DetectionNode.LocalName) {
            "file"          { if (!(Confirm-FileDetected        -DetectionNode $DetectionNode -RunFolder $RunFolder -Parameters $Parameters)) {return $false} ; break}
            "powershell"    { if (!(Confirm-PowershellDetected  -DetectionNode $DetectionNode -RunFolder $RunFolder -Parameters $Parameters)) {return $false} ; break}
            default  {Log -RunFolder $RunFolder -LogLevel Warn -Line "Unknown detection step in XML $($DetectionNode.LocalName)"; exit 1}
        }
    }
    Log -RunFolder $RunFolder -LogLevel Info -Line "(Detection):Confirm-IsDetected returning true"
    return $True
}

function Copy-FolderContents($SourcePath, $DestinationPath)
{
    $ChildItems = Get-ChildItem -Path $SourcePath -Recurse
    ForEach ($ChildItem in $ChildItems) {
        $Dest = $ChildItem.FullName.Substring($SourcePath.Length + 1)
        $Dest = Join-Path -Path $DestinationPath -ChildPath $Dest
        if ($ChildItem.PSIsContainer)
        {
            New-Item -Path $Dest -ItemType Directory -Verbose | Out-Null
        }
        else
        {
            Copy-Item -Path $ChildItem.FullName -Destination $Dest -Verbose
        }
    }
}

function Install-Component($ComponentPath, $DetectOnly, $Parameters)
{
    $ComponentName = Split-Path -Path $ComponentPath -Leaf

    if (!(Test-Path -Path $ComponentPath)) {
        Log -RunFolder $RunFolder -LogLevel Error  -Line "Failed to find $ComponentPath"
        return "Fail"
    }
    $ComponentXMLPath = Join-Path -Path $ComponentPath -ChildPath "install.xml"
    if (!(Test-Path -Path $ComponentXMLPath)) {
        Log -RunFolder $RunFolder -LogLevel Error  -Line "Failed to find $ComponentXMLPath"
        return "Fail"
    }
    [xml]$XmlDocument = Get-Content -Path $ComponentXMLPath
    if ($null -eq $XmlDocument) {
        Log -RunFolder $RunFolder -LogLevel Error  -Line "Failed to find parse $ComponentXMLPath"
        return "Fail"
    }

    $PackageNode = $XmlDocument.package
    if ($null -eq $PackageNode) {
        Log -RunFolder $RunFolder -LogLevel Error  -Line "Failed to find package node in $ComponentXMLPath"
        return "Fail"
    }

    $RunFolder = Get-RunFolder -ComponentName $ComponentName
    Log -RunFolder $RunFolder -LogLevel Info  -Line "Package:$ComponentName runfolder:$RunFolder"


    $ParametersNode = $PackageNode.parameters
    if ($null -ne $ParametersNode) {
        foreach ($ParameterNode in $ParametersNode.ChildNodes) {
            if (!($Parameters.ContainsKey($ParameterNode.LocalName)))
            {
                $Parameters[$ParameterNode.LocalName] = $ParameterNode.InnerText
            }
        }
    }


    $DetectionNode = $PackageNode.detect
    if ($null -ne $DetectionNode ) {
        if (Confirm-IsDetected -XmlNode $DetectionNode -RunFolder $RunFolder -Parameters $Parameters) {
            Log -RunFolder $RunFolder -LogLevel Info  -Line "Package is detected:$ComponentName"
            return "AlreadyInstalled"
        }
        if ($DetectOnly) {
            Log -RunFolder $RunFolder -LogLevel Info  -Line "Package is not detected:$ComponentName"
            return "Fail"
        }
    }

    if ($DetectOnly) {
        return "Success"
    }

    $FilesPath = Join-Path -Path $ComponentPath -ChildPath "files"
    if (Test-Path -Path $FilesPath) {
        Copy-FolderContents -SourcePath $FilesPath -DestinationPath $RunFolder
    }

    Log -RunFolder $RunFolder -LogLevel Info  -Line "Installing package:$ComponentName"

    foreach ($StepNode in $PackageNode.steps.ChildNodes) {
        switch ($StepNode.LocalName) {
            "download"       { if (!(Step-Download      -XmlNode $StepNode -RunFolder $RunFolder -Parameters $Parameters )) {return "Fail"} ; break}
            "create_dir"     { if (!(Step-CreateDir     -XmlNode $StepNode -RunFolder $RunFolder -Parameters $Parameters )) {return "Fail"} ; break}
            "copy_file"      { if (!(Step-CopyFile      -XmlNode $StepNode -RunFolder $RunFolder -Parameters $Parameters )) {return "Fail"} ; break}
            "configure_file" { if (!(Step-ConfigureFile -XmlNode $StepNode -RunFolder $RunFolder -Parameters $Parameters )) {return "Fail"} ; break}
            "path"           { if (!(Step-Path          -XmlNode $StepNode -RunFolder $RunFolder -Parameters $Parameters )) {return "Fail"} ; break}
            "command"        { if (!(Step-Command       -XmlNode $StepNode -RunFolder $RunFolder -Parameters $Parameters )) {return "Fail"} ; break}
            "reg_set"        { if (!(Step-RegSet        -XmlNode $StepNode -RunFolder $RunFolder -Parameters $Parameters )) {return "Fail"} ; break}
            "powershell"     { if (!(Step-Powershell    -XmlNode $StepNode -RunFolder $RunFolder -Parameters $Parameters )) {return "Fail"} ; break}
            "unzip"          { if (!(Step-Unzip         -XmlNode $StepNode -RunFolder $RunFolder -Parameters $Parameters )) {return "Fail"} ; break}
            "kill_process"   { if (!(Step-KillProcess   -XmlNode $StepNode -RunFolder $RunFolder -Parameters $Parameters )) {return "Fail"} ; break}
            "wait_process"   { if (!(Step-WaitProcess   -XmlNode $StepNode -RunFolder $RunFolder -Parameters $Parameters )) {return "Fail"} ; break}
            "env"            { if (!(Step-EnvVar   -XmlNode $StepNode -RunFolder $RunFolder -Parameters $Parameters )) {return "Fail"} ; break}
            default {Log -RunFolder $RunFolder -LogLevel Error -Line "Unknown step in XML $($StepNode.LocalName)"; break}
        }
    }

    $RebootNode = $PackageNode.reboot
    if ($null -ne $RebootNode) {
        Log -RunFolder $RunFolder -LogLevel Info  -Line "Reboot required $ComponentName"
        return "Reboot"
    }

    if ($null -ne $DetectionNode ) {
        if (!(Confirm-IsDetected -XmlNode $DetectionNode -RunFolder $RunFolder -Parameters $Parameters)) {
            Log -RunFolder $RunFolder -LogLevel Error  -Line "Package is not detected after install $ComponentName"
            return "Fail"
        }
        Log -RunFolder $RunFolder -LogLevel Info  -Line "Post install package is detected $ComponentName"
    }

    return "Success"
}


Install-Component -ComponentPath $ComponentPath -DetectOnly:$DetectOnly -Parameters $Parameters
